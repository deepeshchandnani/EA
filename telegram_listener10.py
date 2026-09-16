"""
Telegram -> MT5 Signal Bridge
------------------------------
Ye script Telegram channel/group ko monitor karta hai, trade signals ko parse
karta hai, aur unhe ek folder me .txt files ke roop me save karta hai.
MT5 EA (SignalCopierEA.mq5) us folder ko poll karke trades execute karega.

SETUP STEPS:
1. pip install telethon
2. https://my.telegram.org par jaakar api_id aur api_hash generate karo
   (Login > API Development Tools > create app)
3. Neeche API_ID, API_HASH, PHONE_NUMBER, CHANNEL fill karo
4. SIGNAL_FOLDER ko apne MT5 "Files" folder ke andar wale path par set karo
   (MT5 me: File > Open Data Folder > MQL5 > Files > yahan ek "Signals" folder bana lo)
5. Script chalao: python telegram_listener.py
   Pehli baar chalane par phone/OTP maangega login ke liye (one-time).
"""

import re
import json
import os
import time
from telethon import TelegramClient, events

# ============ CONFIG - YAHAN APNI DETAILS DAALO ============
API_ID = 32914590                     # my.telegram.org se milega
API_HASH = "9de61faff71fa85be58150e4bbd647cd"       # my.telegram.org se milega
PHONE_NUMBER = "+919521268740"        # tumhara Telegram number

# Channel/Group identify karne ke 2 tarike:
#   PUBLIC channel/group: username string daalo, jaise "your_channel_username"
#   PRIVATE channel/group: numeric ID daalo (list_dialogs.py chala ke pata karo), jaise -1001234567890
#   Numeric ID daalte waqt quotes MAT lagao (number hai, string nahi)
CHANNEL = -1004413000552

# MT5 ke "MQL5/Files/Signals" folder ka FULL path
# Example (Windows): r"C:\Users\<YourName>\AppData\Roaming\MetaQuotes\Terminal\<TERMINAL_ID>\MQL5\Files\Signals"
SIGNAL_FOLDER = "/home/mt5/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Files/Signals"

# Binance ke liye alag folder (binance_executor.py isko poll karega)
# Agar Binance nahi use karna, ENABLE_BINANCE_BRIDGE = False kar do
ENABLE_BINANCE_BRIDGE = True
BINANCE_SIGNAL_FOLDER = r"C:\Path\To\BinanceSignals"   # koi bhi normal folder, MT5 se related nahi hai

# LOG_ONLY = True -> sirf detect + log karega, file nahi likhega (testing ke liye)
LOG_ONLY = False
# =============================================================

# Common symbol name mappings (Telegram groups often use casual names)
SYMBOL_MAP = {
    "GOLD": "XAUUSD",
    "SILVER": "XAGUSD",
    "OIL": "USOIL",
    "BTC": "BTCUSD",
}

VALID_SYMBOLS = r"(XAUUSD|GOLD|XAGUSD|SILVER|EURUSD|GBPUSD|USDJPY|USDCHF|" \
                r"AUDUSD|NZDUSD|USDCAD|BTCUSD|BTC|ETHUSD|USOIL|OIL|NAS100|US30|SPX500)"


def parse_signal(text: str):
    """Message text se signal nikalta hai. Agar valid signal nahi mila, None return karta hai."""
    if not text:
        return None

    original_text = text
    text = text.upper()

    # Update/notification messages ko filter karo - ye naye signals NAHI hain,
    # ye purane trade ke baare me status update hote hain (jaise "TP1 Hit!", "Move SL to BE")
    # In messages me bhi direction/symbol keywords hote hain, isliye inhe explicitly exclude karna zaroori hai
    UPDATE_KEYWORDS = [
        "HIT", "HIT!", "CLOSED", "CLOSE NOW", "MANAGE YOUR TRADE", "MANAGE TRADE",
        "BREAKEVEN", "BREAK EVEN", "MOVE SL", "MOVE STOP", "TRAIL", "TARGET REACHED",
        "TARGET HIT", "SECURE PROFIT", "BOOK PROFIT", "PARTIAL CLOSE", "RUNNING",
        "UPDATE:", "SL HIT", "STOPPED OUT", "ACHIEVED", "REACHED", "BOOKED", "DONE"
    ]
    for keyword in UPDATE_KEYWORDS:
        if keyword in text:
            return None  # ye ek update/notification hai, naya signal nahi

    # Extra safety net: "TP1", "TP 2", "TP3" etc ke turant baad/paas koi status
    # word ho (chahe wo upar wali list me na ho), toh bhi ise update maano, naya signal nahi
    if re.search(r'\bTP\s?\d\b', text) and re.search(r'\b(HIT|DONE|ACHIEVED|REACHED|BOOKED|CLOSED|TAKEN)\b', text):
        return None

    direction_match = re.search(r'\b(BUY|SELL|LONG|SHORT)\b', text)
    symbol_match = re.search(r'\b' + VALID_SYMBOLS + r'\b', text)

    # Signal ke liye direction aur symbol dono zaroori hain
    if not (direction_match and symbol_match):
        return None

    direction_raw = direction_match.group(1)
    direction = "BUY" if direction_raw in ("BUY", "LONG") else "SELL"

    symbol_raw = symbol_match.group(1)
    symbol = SYMBOL_MAP.get(symbol_raw, symbol_raw)

    # ENTRY PRICE - ab hamesha DO entries banti hain (dual-leg system):
    #   "Deeper" price (BUY ka chota, SELL ka bada) -> 0.3 lot wali position
    #   "Nearer" price (BUY ka bada, SELL ka chota) -> 0.1 lot wali position
    # Kill-switch (dono ka shared exit) = Deeper price se $5 aur door
    #   BUY:  kill = deeper - 5
    #   SELL: kill = deeper + 5
    # Agar range na mile (sirf ek number diya ho), dono legs usi price par ban jate hain.
    range_match = re.search(r'(?:@|NEAR)\D{0,4}([\d.]+)\s*(?:[-–—−]|TO)\s*([\d.]+)', text)
    entry_debug = ""
    if range_match:
        num1 = float(range_match.group(1))
        num2 = float(range_match.group(2))
        entry_deep = min(num1, num2) if direction == "BUY" else max(num1, num2)
        entry_near = max(num1, num2) if direction == "BUY" else min(num1, num2)
        entry_debug = f"RANGE detected ({num1} - {num2}), {direction} -> deep={entry_deep} near={entry_near}"
    else:
        entry_match = re.search(r'ENTRY\D{0,6}([\d.]+)', text)
        if not entry_match:
            entry_match = re.search(r'(?:@|NEAR)\D{0,4}([\d.]+)', text)
        if entry_match:
            single = float(entry_match.group(1))
            entry_deep = single
            entry_near = single
            entry_debug = f"SINGLE number detected -> {single} (dono legs isi price par)"
        else:
            entry_deep = None
            entry_near = None
            entry_debug = "NOT FOUND"

    kill_switch = None
    if entry_deep is not None:
        kill_switch = entry_deep - 5 if direction == "BUY" else entry_deep + 5

    sl_match = re.search(r'STOP\D{0,3}LOSS\D{0,10}([\d.]+)', text)
    if not sl_match:
        sl_match = re.search(r'\bSL\D{0,10}([\d.]+)', text)

    tp_match = re.search(r'TP\D{0,3}1\b\D{0,6}([\d.]+)', text)
    if not tp_match:
        tp_match = re.search(r'\bTP\D{0,6}([\d.]+)', text)  # e.g. "TP: 3370" bina number ke

    signal = {
        "raw_text": original_text,
        "direction": direction,
        "symbol": symbol,
        "entry_deep": entry_deep,   # 0.3 lot wali position ki entry
        "entry_near": entry_near,   # 0.1 lot wali position ki entry
        "kill_switch": kill_switch, # dono ka shared exit level (deep se $5 aur door)
        "entry_debug": entry_debug,
        "sl_raw": float(sl_match.group(1)) if sl_match else None,  # ab sirf reference/log ke liye, EA use nahi karta
        "tp": float(tp_match.group(1)) if tp_match else None,  # sirf TP1 - EA isko EXACT use karega
        "timestamp": int(time.time()),
    }
    return signal


def save_signal(signal: dict, message_id: int):
    os.makedirs(SIGNAL_FOLDER, exist_ok=True)
    filename = f"signal_{message_id}_{signal['timestamp']}.txt"
    filepath = os.path.join(SIGNAL_FOLDER, filename)
    with open(filepath, "w") as f:
        json.dump(signal, f)
    print(f"[SAVED - MT5] {filepath} -> {signal}")


def save_signal_binance(signal: dict, message_id: int):
    os.makedirs(BINANCE_SIGNAL_FOLDER, exist_ok=True)
    filename = f"signal_{message_id}_{signal['timestamp']}.txt"
    filepath = os.path.join(BINANCE_SIGNAL_FOLDER, filename)
    with open(filepath, "w") as f:
        json.dump(signal, f)
    print(f"[SAVED - BINANCE] {filepath} -> {signal}")


def save_close_signal():
    """Telegram par image aane par ye file banti hai - EA isse dekhte hi active trade/sequence band kar deta hai."""
    os.makedirs(SIGNAL_FOLDER, exist_ok=True)
    filename = f"CLOSE_{int(time.time())}.txt"
    filepath = os.path.join(SIGNAL_FOLDER, filename)
    with open(filepath, "w") as f:
        f.write("CLOSE")
    print(f"[CLOSE SIGNAL SAVED] {filepath}")


client = TelegramClient("mt5_signal_session", API_ID, API_HASH)


async def handler(event):
    # IMAGE DETECTION - agar message me photo hai, ye ek "close trade" trigger hai,
    # signal text parsing ki koi zaroorat nahi, turant close signal bhej do
    if event.photo:
        print("[IMAGE DETECTED] Telegram par image aayi - trade close trigger bhej rahe hain.")
        if not LOG_ONLY:
            save_close_signal()
        else:
            print("[LOG_ONLY MODE] Close signal file nahi likhi gayi (testing mode).")
        return

    text = event.raw_text
    signal = parse_signal(text)

    if signal is None:
        print(f"[IGNORED] Not a signal: {text[:60]!r}")
        return

    print(f"[DETECTED] {signal}")

    # Debug warning - agar entry ya TP1 parse nahi hui, raw text repr dikhao taaki
    # hidden/special characters turant pakde ja sakein (future troubleshooting ke liye)
    if signal['entry_deep'] is None or signal['tp'] is None:
        missing = []
        if signal['entry_deep'] is None:
            missing.append('ENTRY')
        if signal['tp'] is None:
            missing.append('TP1')
        print(f"[WARNING] {', '.join(missing)} parse nahi hui is signal me. Raw text: {text!r}")

    if LOG_ONLY:
        print("[LOG_ONLY MODE] Trade file nahi likha gaya (testing mode).")
        return

    save_signal(signal, event.message.id)
    if ENABLE_BINANCE_BRIDGE:
        # Binance executor purane format (single "entry" + "sl") expect karta hai -
        # backward-compatible dict banao taaki wo bina modify kiye chalta rahe
        binance_signal = dict(signal)
        binance_signal["entry"] = signal["entry_deep"]  # = purane single-entry logic ke barabar
        binance_signal["sl"] = signal["sl_raw"]
        save_signal_binance(binance_signal, event.message.id)


async def run():
    # Zaroori: numeric channel/group ID resolve karne ke liye Telethon ko
    # pehle ek baar dialogs fetch karne dete hain (entity cache populate hota hai).
    print("Syncing dialogs (entity cache)...")
    await client.get_dialogs()

    # Entity ko explicitly resolve karke object ke roop me event handler ko dete hain,
    # sirf raw numeric ID dene se private/basic groups ke liye resolution fail ho sakta hai.
    try:
        entity = await client.get_entity(CHANNEL)
    except Exception as e:
        print(f"ERROR: CHANNEL ko resolve nahi kar paya ({CHANNEL}). Detail: {e}")
        print("Check karo: (1) numeric ID sahi hai, (2) is account se us channel/group ko join/open kiya hai.")
        return

    client.add_event_handler(handler, events.NewMessage(chats=entity))
    print(f"Listening to: {getattr(entity, 'title', None) or getattr(entity, 'username', None) or CHANNEL}")

    await client.run_until_disconnected()


def main():
    print("Starting Telegram listener...")
    print(f"Mode: {'LOG ONLY (no trades)' if LOG_ONLY else 'LIVE (writing signal files)'}")
    with client:
        client.start(phone=PHONE_NUMBER)
        client.loop.run_until_complete(run())


if __name__ == "__main__":
    main()
