"""
Telegram signal -> Kotak Neo options auto-trader (NSE F&O)

Rules:
- Sirf din ka FIRST signal liya jaata hai (state.json me save hota hai, restart par bhi 2nd trade nahi)
- Entry: LTP signal-entry se entry+SLIPPAGE ke beech aaye to buy (limit cap = entry+SLIPPAGE)
- SL = fill price ka 1%, Target = signal entry ka +20%
- SL lagne par jab price wapas entry zone me aaye to RE-ENTRY, target hone tak (max 10 entries total)
- LIVE MODE: real orders jaate hain. Har trade me sirf 1 lot. Max 10 entries/din.

DISCLAIMER: Ye code real paisa se trade karta hai, nuksan ho sakta hai. Pehle din
broker app khula rakho aur dhyan se dekho. Kotak API ke response fields version ke hisaab se
badal sakte hain - NEO_API docs se verify karo.
"""
import os, re, json, time, threading, asyncio, datetime as dt
from zoneinfo import ZoneInfo

import pandas as pd
from telethon import TelegramClient, events
from neo_api_client import NeoAPI

try:
    import pyotp
except ImportError:
    pyotp = None

# ============================ CONFIG ============================
SL_PCT = 0.01                               # 1%
TGT_PCT = 0.20                              # 20%
SLIPPAGE = 10.0                             # entry se max itne rupay upar tak entry le lo
LOTS = 1                                    # har trade me hamesha 1 lot (isko change mat karna)
MAX_ENTRIES = 10                            # HARD LIMIT: total entries (pehli + re-entries) = 10
NO_NEW_ENTRY_AFTER = dt.time(15, 10)
SQUAREOFF_AT = dt.time(15, 15)
PRODUCT = "MIS"                             # intraday
STATE_FILE = "state.json"

# Secrets environment variables se (code me mat likho)
TG_API_ID = int(os.environ["TG_API_ID"])
TG_API_HASH = os.environ["TG_API_HASH"]
TG_CHANNEL = os.environ["TG_CHANNEL"]       # username (@name) ya numeric id (-100...)
NEO_CONSUMER_KEY = os.environ["NEO_CONSUMER_KEY"]
NEO_MOBILE = os.environ["NEO_MOBILE"]       # +91XXXXXXXXXX
NEO_UCC = os.environ["NEO_UCC"]
NEO_MPIN = os.environ["NEO_MPIN"]
NEO_TOTP_SECRET = os.getenv("NEO_TOTP_SECRET")  # optional, auto TOTP ke liye
# optional: group me sirf in senders ke signal lo (comma separated username / numeric id)
ALLOWED_SENDERS = {x.strip().lower() for x in os.getenv("TG_ALLOWED_SENDERS", "").split(",") if x.strip()}

IST = ZoneInfo("Asia/Kolkata")
TICK = 0.05


def now():
    return dt.datetime.now(IST)


def rt(p):
    return round(round(p / TICK) * TICK, 2)


def log(*a):
    print(now().strftime("%H:%M:%S.%f")[:-3], *a, flush=True)


def load_state():
    try:
        return json.load(open(STATE_FILE))
    except Exception:
        return {}


def save_state(s):
    json.dump(s, open(STATE_FILE, "w"))


def dig(o, key):
    """Response ke andar se key dhundta hai (API format change se bachne ke liye)."""
    if isinstance(o, dict):
        if key in o:
            return o[key]
        for v in o.values():
            r = dig(v, key)
            if r is not None:
                return r
    elif isinstance(o, list):
        for v in o:
            r = dig(v, key)
            if r is not None:
                return r
    return None


# ============================ SIGNAL PARSER ============================
MONTHS = {m: i for i, m in enumerate(
    ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"], 1)}
BSE_UNDERLYINGS = {"SENSEX", "BANKEX"}

# Signal format (teeno lines zaruri, warna message ignore):
#   NIFTY 17 NOV 25350 CE
#   ABOVE :- 152
#   STOPLOSS :- VIP
SIG_CONTRACT = re.compile(
    r"^\s*(NIFTY|BANKNIFTY|FINNIFTY|MIDCPNIFTY|SENSEX|BANKEX)\s+(\d{1,2})\s+([A-Z]{3})\s+(\d{4,6})\s+(CE|PE)\b",
    re.M)
SIG_ABOVE = re.compile(r"^\s*ABOVE\s*:?\s*-?\s*(\d+(?:\.\d+)?)", re.M)
SIG_SL = re.compile(r"^\s*STOP\s*LOSS\s*:?\s*-?\s*VIP\b", re.M)


def parse(text):
    t = text.upper().replace("\u200b", "")
    c, a, s = SIG_CONTRACT.search(t), SIG_ABOVE.search(t), SIG_SL.search(t)
    if not (c and a and s):
        return None                      # signal format nahi hai -> ignore
    mon = MONTHS.get(c.group(3))
    if not mon:
        return None
    today = now().date()
    try:
        exp = dt.date(today.year, mon, int(c.group(2)))
        if exp < today:
            exp = dt.date(today.year + 1, mon, int(c.group(2)))
    except ValueError:
        return None
    return dict(und=c.group(1), strike=float(c.group(4)), ot=c.group(5),
                expiry=exp, entry=float(a.group(1)))


# ============================ BROKER ============================
class Broker:
    def __init__(self):
        self.c = NeoAPI(environment="prod", access_token=None, neo_fin_key=None,
                        consumer_key=NEO_CONSUMER_KEY)
        if NEO_TOTP_SECRET and pyotp:
            totp = pyotp.TOTP(NEO_TOTP_SECRET).now()
        else:
            totp = input("Kotak TOTP: ").strip()
        self.c.totp_login(mobile_number=NEO_MOBILE, ucc=NEO_UCC, totp=totp)
        self.c.totp_validate(mpin=NEO_MPIN)
        log("Kotak login OK")
        self.df = None
        self.halt = False

    def load_contracts(self):
        frames = []
        for seg in ("nse_fo", "bse_fo"):
            try:
                res = self.c.scrip_master(exchange_segment=seg)
                df = pd.read_csv(res) if isinstance(res, str) else pd.DataFrame(res)
                df.columns = [c.strip().rstrip(";") for c in df.columns]
                df = df[df["pOptionType"].isin(["CE", "PE"])].copy()
                df["seg"] = seg
                df["name"] = df["pSymbolName"].astype(str).str.strip().str.upper()
                df["strike"] = df["dStrikePrice"].astype(float) / 100.0
                ep = df["lExpiryDate"].astype("int64")
                # epoch base exchange ke hisaab se alag ho sakta hai, isliye dono check karte hain
                df["exp_a"] = ep.apply(lambda x: dt.datetime.fromtimestamp(x + 315513000, IST).date())
                df["exp_b"] = ep.apply(lambda x: dt.datetime.fromtimestamp(x, IST).date())
                frames.append(df)
                log("Scrip master loaded:", seg, len(df), "option contracts")
            except Exception as ex:
                log("Scrip master load FAIL", seg, repr(ex))
        self.df = pd.concat(frames)

    def find(self, und, strike, ot, expiry):
        df = self.df
        seg = "bse_fo" if und in BSE_UNDERLYINGS else "nse_fo"
        m = df[(df["seg"] == seg) & (df["name"] == und) & (df["pOptionType"] == ot)
               & ((df["strike"] - strike).abs() < 0.01)
               & ((df["exp_a"] == expiry) | (df["exp_b"] == expiry))]
        if m.empty:
            return None
        r = m.iloc[0]
        return dict(token=str(r["pSymbol"]), sym=r["pTrdSymbol"], seg=seg,
                    lot=int(r["lLotSize"]), expiry=expiry)

    def place(self, side, sym, qty, price, seg):
        r = self.c.place_order(
            exchange_segment=seg, product=PRODUCT, price=str(price), order_type="L",
            quantity=str(qty), validity="DAY", trading_symbol=sym, transaction_type=side,
            amount="NA", disclosed_quantity="0", market_protection="0", pf="N",
            trigger_price="0", tag=None)
        oid = dig(r, "nOrdNo")
        log("ORDER", side, sym, qty, price, "->", r)
        return oid

    def wait_fill(self, oid, qty, ref_price, timeout=2.0):
        """returns (filled_qty, avg_price)"""
        t0 = time.time()
        filled, avg, found = 0, 0.0, False
        while time.time() - t0 < timeout:
            try:
                rep = self.c.order_report()
                rows = rep.get("data", []) if isinstance(rep, dict) else []
                for x in rows:
                    if str(x.get("nOrdNo")) == str(oid):
                        found = True
                        filled = int(float(x.get("fldQty") or 0))
                        avg = float(x.get("avgPrc") or 0)
                        if str(x.get("ordSt", "")).lower() in ("complete", "rejected", "cancelled"):
                            return filled, avg or ref_price
            except Exception as ex:
                log("order_report error", ex)
            time.sleep(0.15)
        if not found:
            self.halt = True
            log("!!! ORDER STATUS UNKNOWN (reject ya API issue). Algo ROK diya - broker app me position check karo !!!")
        return filled, avg or ref_price

    def cancel(self, oid):
        try:
            self.c.cancel_order(order_id=oid)
        except Exception as ex:
            log("cancel error", ex)


# ============================ TRADE ENGINE ============================
class Engine:
    def __init__(self, broker, sig, ct):
        self.b, self.sig, self.ct = broker, sig, ct
        self.entry = sig["entry"]
        self.target = rt(self.entry * (1 + TGT_PCT))
        self.cap = rt(self.entry + SLIPPAGE)
        self.qty = ct["lot"] * LOTS
        self.state = "WAIT"          # WAIT -> LONG -> WAIT (SL) ... -> DONE (target / EOD)
        self.entries = 0
        self.held = 0
        self.sl = 0.0
        self.last = None
        self.lock = threading.Lock()
        log(f"ENGINE {ct['sym']} entry={self.entry} zone<={self.cap} target={self.target} qty={self.qty}")

    def on_tick(self, ltp):
        with self.lock:
            self.last = ltp
            if self.state == "DONE" or self.b.halt:
                return
            t = now().time()
            if self.state == "WAIT":
                if t >= NO_NEW_ENTRY_AFTER or self.entries >= MAX_ENTRIES:
                    log("No more entries today. DONE")
                    self.state = "DONE"
                    return
                if self.entry <= ltp <= self.cap:
                    self._buy(ltp)
            elif self.state == "LONG":
                if ltp >= self.target:
                    self._sell(ltp, "TARGET")
                    self.state = "DONE"
                    log("TARGET HIT - trade complete")
                elif ltp <= self.sl:
                    self._sell(ltp, "SL")
                    self.state = "WAIT"       # re-entry ke liye wapas
                elif t >= SQUAREOFF_AT:
                    self._sell(ltp, "EOD")
                    self.state = "DONE"

    def watchdog(self):
        while self.state != "DONE":
            time.sleep(1)
            with self.lock:
                if self.state == "LONG" and now().time() >= SQUAREOFF_AT and self.last:
                    self._sell(self.last, "EOD")
                    self.state = "DONE"

    def _buy(self, ltp):
        self.entries += 1
        oid = self.b.place("B", self.ct["sym"], self.qty, self.cap, self.ct["seg"])
        filled, avg = self.b.wait_fill(oid, self.qty, ltp)
        if filled < self.qty:
            self.b.cancel(oid)
            time.sleep(0.2)
            filled, avg = self.b.wait_fill(oid, self.qty, ltp, timeout=0.5)
        if filled > 0:
            self.held = filled
            self.sl = rt(avg * (1 - SL_PCT))
            self.state = "LONG"
            log(f"ENTRY #{self.entries} qty={filled} avg={avg} SL={self.sl} TGT={self.target}")
        else:
            log("Entry fill nahi hui, wait karte hain")

    def _sell(self, ltp, why):
        price = ltp
        for attempt in range(4):
            price = rt(max(price * 0.95, TICK))
            oid = self.b.place("S", self.ct["sym"], self.held, price, self.ct["seg"])
            filled, avg = self.b.wait_fill(oid, self.held, ltp)
            if self.b.halt:
                return
            if filled >= self.held:
                log(f"EXIT({why}) avg={avg}")
                self.held = 0
                return
            self.b.cancel(oid)
            self.held -= filled
            if self.held <= 0:
                return
        log("!!! EXIT poora nahi hua - broker app me manually check karo !!!")


ENGINE = None


def on_message(msg):
    if ENGINE is None or not isinstance(msg, dict):
        return
    for d in msg.get("data") or []:
        try:
            if str(d.get("tk")) == ENGINE.ct["token"] and d.get("ltp") not in (None, ""):
                ENGINE.on_tick(float(d["ltp"]))
        except Exception as ex:
            log("tick error", ex)


# ============================ MAIN ============================
async def main():
    global ENGINE
    broker = Broker()
    broker.load_contracts()
    broker.c.on_message = on_message
    broker.c.on_error = lambda e: log("WS error", e)
    broker.c.on_close = lambda m: log("WS closed", m)
    broker.c.on_open = lambda m: log("WS open")

    tg = TelegramClient("tg_session", TG_API_ID, TG_API_HASH)
    await tg.start()
    chan = int(TG_CHANNEL) if TG_CHANNEL.lstrip("-").isdigit() else TG_CHANNEL
    log("Listening on", TG_CHANNEL, "| *** LIVE MODE: REAL ORDERS ***")

    @tg.on(events.NewMessage(chats=chan))
    async def handler(ev):
        global ENGINE
        t0 = time.perf_counter()
        today = str(now().date())
        if load_state().get("date") == today or ENGINE is not None:
            return                                  # aaj ka trade ho chuka
        age = (dt.datetime.now(dt.timezone.utc) - ev.message.date).total_seconds()
        if age > 120:
            return                                  # purana message (reconnect catch-up)
        if ALLOWED_SENDERS:
            snd = await ev.get_sender()
            ids = {str(ev.sender_id), (getattr(snd, "username", "") or "").lower()}
            if not ids & ALLOWED_SENDERS:
                return
        sig = parse(ev.raw_text or "")
        if not sig:
            return
        ct = broker.find(sig["und"], sig["strike"], sig["ot"], sig["expiry"])
        if not ct:
            log("Contract nahi mila:", sig)
            return
        save_state({"date": today, "signal": ev.raw_text, "symbol": ct["sym"]})
        ENGINE = Engine(broker, sig, ct)
        threading.Thread(target=ENGINE.watchdog, daemon=True).start()
        broker.c.subscribe(instrument_tokens=[{"instrument_token": ct["token"],
                                               "exchange_segment": ct["seg"]}],
                           isIndex=False, isDepth=False)
        log(f"Signal->subscribe in {(time.perf_counter() - t0) * 1000:.1f} ms", sig, ct["sym"], ct["expiry"])

    await tg.run_until_disconnected()


if __name__ == "__main__":
    asyncio.run(main())
