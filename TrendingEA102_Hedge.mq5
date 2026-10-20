//+------------------------------------------------------------------+
//|                                         TrendingEA100_Hedge.mq5   |
//| Telegram -> MT5 Signal Copier (v7 - Hedge + Loop Reentry)         |
//|                                                                   |
//| Logic:                                                            |
//|  - Signal se sirf ENTRY price (single number) use hota hai.       |
//|  - Price entry par pahunchte hi BUY + SELL dono khulte hain       |
//|    (same lot, default 0.10).                                      |
//|  - Har leg ka loop SL = fill price se $1.4. SL hit hone par leg   |
//|    band hoti hai aur price wapas entry par aate hi DOBARA khulti  |
//|    hai (reentry). Ye har leg ke liye alag-alag chalta hai.        |
//|  - Har leg ka TP = fill price se $50. TP hit hone par us leg ki   |
//|    loop khatam.                                                   |
//|  - Sequence SL nahi hai. Martingale nahi hai.                     |
//|  - Dono legs TP se khatam hon ya koi naya signal aaye (jab koi    |
//|    position khuli na ho) toh sequence badal jaati hai.            |
//|                                                                   |
//| ZAROORI: Account HEDGING type ka hona chahiye.                    |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "7.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//----------------- INPUTS -----------------
input string InpSignalFolder     = "Signals";   // MQL5\Files\ ke andar folder ka naam
input double InpLotSize          = 0.10;        // Har leg ka lot (BUY aur SELL dono same)
input double InpSLDollars        = 1.4;         // Loop SL distance (price units, gold me $1 = 1.00) - fill price se
input double InpTPDollars        = 50.0;        // TP distance (price units) - fill price se
input bool   InpSendSLToBroker   = true;        // true: SL broker ko bhi bheja jata hai. Reject ho toh EA khud monitor karega
input int    InpSlippagePoints   = 20;          // Slippage (points)
input long   InpMagicNumber      = 20260708;    // Magic number
input string InpSymbolSuffix     = "";          // Broker symbol suffix, e.g. ".m" or "!"
input int    InpMaxSpreadPoints  = 100;         // Is se zyada spread par entry/reentry skip (agla tick retry)
input int    InpMaxLegRetries    = 20;          // Order fail hone par max attempts, uske baad agli entry-touch ka wait
input int    InpPriceCheckMillis = 200;         // Price monitor interval (milliseconds)
input int    InpFolderScanSeconds= 2;           // Signal folder scan interval (seconds)
input bool   InpLogErrors        = true;        // true: sirf errors (order fail, file error) Experts me dikhein

string ProcessedFolder;
int    ScanCounter = 0;
int    g_FolderScanEveryNTicks = 10;

//----------------- STATE -----------------
struct HedgeLeg
  {
   bool   isBuy;
   bool   opened;        // position abhi khuli hai
   bool   wantOpen;      // entry/reentry touch ho chuki, order khulne ka intezaar (retry ke liye)
   bool   done;          // leg hamesha ke liye khatam (TP hit / manual close)
   bool   brokerSL;      // true = SL broker-side laga hai, false = EA monitor karega
   bool   slClosing;     // EA ne khud SL par close bheja
   ulong  ticket;        // position ID
   double slLevel;
   double lastPrice;     // reentry ke wait me entry cross detect karne ke liye
   int    attempts;      // current open attempt me kitni baar fail hua
   int    entries;       // is leg ne total kitni baar entry li
   int    historyTries;  // close ke baad history reason dhundhne ki koshish
  };

struct TradeSequence
  {
   bool   active;
   bool   triggered;     // pehli entry touch ho chuki
   string symbol;
   bool   isBuy;         // signal ki direction - sirf pehli entry trigger ke liye ASK/BID choose karne me kaam aati hai
   double entry;
   double lastPrice;     // pehli entry touch/cross detect karne ke liye
  };

TradeSequence g_Sequence;
HedgeLeg      g_BuyLeg;
HedgeLeg      g_SellLeg;

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
void LogErr(string msg)
  {
   if(InpLogErrors)
      Print("[ERROR] ", msg);
  }

string Px(double value)
  {
   int digits = (int)SymbolInfoInteger(g_Sequence.symbol, SYMBOL_DIGITS);
   return DoubleToString(value, digits);
  }

string Side(HedgeLeg &leg)
  {
   return leg.isBuy ? "BUY" : "SELL";
  }

double LegPrice(HedgeLeg &leg)
  {
   return leg.isBuy ? SymbolInfoDouble(g_Sequence.symbol, SYMBOL_ASK)
                    : SymbolInfoDouble(g_Sequence.symbol, SYMBOL_BID);
  }

void ResetLeg(HedgeLeg &leg, bool isBuy)
  {
   leg.isBuy        = isBuy;
   leg.opened       = false;
   leg.wantOpen     = false;
   leg.done         = false;
   leg.brokerSL     = false;
   leg.slClosing    = false;
   leg.ticket       = 0;
   leg.slLevel      = 0;
   leg.lastPrice    = 0;
   leg.attempts     = 0;
   leg.entries      = 0;
   leg.historyTries = 0;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   ProcessedFolder = InpSignalFolder + "\\Processed";

   // BUY + SELL same symbol par sirf hedging account me alag-alag rehte hain
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("[FATAL] Ye account HEDGING type ka nahi hai, BUY aur SELL net ho jayenge. EA start nahi hoga.");
      Alert("TrendingEA100_Hedge: account hedging type ka nahi hai - EA band.");
      return(INIT_FAILED);
     }

   if(InpLotSize <= 0 || InpSLDollars <= 0 || InpTPDollars <= 0)
     {
      Print("[FATAL] InpLotSize / InpSLDollars / InpTPDollars sab 0 se bade hone chahiye.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   g_Sequence.active    = false;
   g_Sequence.triggered = false;
   g_Sequence.symbol    = "";
   g_Sequence.isBuy     = true;
   g_Sequence.entry     = 0;
   g_Sequence.lastPrice = 0;
   ResetLeg(g_BuyLeg, true);
   ResetLeg(g_SellLeg, false);

   if(!FileIsExist(InpSignalFolder))
      LogErr("'" + InpSignalFolder + "' folder MQL5\\Files\\ ke andar nahi mila.");

   g_FolderScanEveryNTicks = (int)MathMax(1, MathRound((InpFolderScanSeconds * 1000.0) / InpPriceCheckMillis));

   EventSetMillisecondTimer(InpPriceCheckMillis);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_Sequence.active && ((g_BuyLeg.opened && !g_BuyLeg.brokerSL) || (g_SellLeg.opened && !g_SellLeg.brokerSL)))
      LogErr("EA band ho raha hai par kuch positions ka SL EA-monitored tha - ab unka SL monitor nahi hoga, manually check karo.");
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   ScanCounter++;

   CheckActiveSequence();

   if(ScanCounter % g_FolderScanEveryNTicks == 0)
      ScanSignalFolder();
  }

//+------------------------------------------------------------------+
//| Pehli entry ka wait. Touch hote hi dono legs kholne ka order      |
//| (wantOpen) set hota hai, uske baad har leg apni loop khud chalati |
//+------------------------------------------------------------------+
void CheckActiveSequence()
  {
   if(!g_Sequence.active)
      return;

   string symbol = g_Sequence.symbol;
   if(!SymbolSelect(symbol, true))
      return;

   if(g_Sequence.triggered)
     {
      ManageLegs();
      return;
     }

   double currentPrice = g_Sequence.isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   if(currentPrice <= 0)
      return;

   if(g_Sequence.lastPrice <= 0)
     {
      g_Sequence.lastPrice = currentPrice;
      return;
     }

   double point    = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double diffPrev = g_Sequence.lastPrice - g_Sequence.entry;
   double diffNow  = currentPrice - g_Sequence.entry;

   bool touched = false;
   if(MathAbs(diffNow) <= point * 2)
      touched = true;
   else if(diffPrev == 0)
      touched = true;
   else if((diffPrev > 0 && diffNow < 0) || (diffPrev < 0 && diffNow > 0))
      touched = true;

   g_Sequence.lastPrice = currentPrice;

   if(touched)
     {
      g_Sequence.triggered = true;
      g_BuyLeg.wantOpen    = true;
      g_BuyLeg.attempts    = 0;
      g_SellLeg.wantOpen   = true;
      g_SellLeg.attempts   = 0;
      ManageLegs();
     }
  }

//+------------------------------------------------------------------+
void ManageLegs()
  {
   ProcessLeg(g_BuyLeg, g_SellLeg);
   ProcessLeg(g_SellLeg, g_BuyLeg);

   if(g_BuyLeg.done && g_SellLeg.done)
     {
      g_Sequence.active    = false;
      g_Sequence.triggered = false;
     }
  }

//+------------------------------------------------------------------+
//| Har leg ki 3 states:                                              |
//|   opened   -> position monitor (SL / TP / close detect)           |
//|   wantOpen -> order kholne ki koshish                             |
//|   baaki    -> flat, price ke wapas entry par aane ka wait         |
//+------------------------------------------------------------------+
void ProcessLeg(HedgeLeg &leg, HedgeLeg &other)
  {
   if(leg.done)
      return;

   if(leg.opened)
     {
      MonitorLeg(leg);
      return;
     }

   if(leg.wantOpen)
     {
      TryOpenLeg(leg, other);
      return;
     }

   CheckReentryTouch(leg, other);
  }

//+------------------------------------------------------------------+
//| Flat leg: price (BUY=ASK, SELL=BID) entry par wapas aaye toh      |
//| reentry                                                           |
//+------------------------------------------------------------------+
void CheckReentryTouch(HedgeLeg &leg, HedgeLeg &other)
  {
   string symbol = g_Sequence.symbol;

   double price = LegPrice(leg);
   if(price <= 0)
      return;

   if(leg.lastPrice <= 0)
     {
      leg.lastPrice = price;
      return;
     }

   double point    = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double diffPrev = leg.lastPrice - g_Sequence.entry;
   double diffNow  = price - g_Sequence.entry;

   bool touched = false;
   if(MathAbs(diffNow) <= point * 2)
      touched = true;
   else if(diffPrev == 0)
      touched = true;
   else if((diffPrev > 0 && diffNow < 0) || (diffPrev < 0 && diffNow > 0))
      touched = true;

   leg.lastPrice = price;

   if(touched)
     {
      leg.wantOpen = true;
      leg.attempts = 0;
      TryOpenLeg(leg, other);
     }
  }

//+------------------------------------------------------------------+
void OpenFailed(HedgeLeg &leg, string why)
  {
   leg.attempts++;
   if(leg.attempts == 1)
      LogErr(Side(leg) + " " + g_Sequence.symbol + " order fail: " + why);

   if(leg.attempts >= InpMaxLegRetries)
     {
      LogErr(Side(leg) + " " + g_Sequence.symbol + " " + IntegerToString(InpMaxLegRetries) +
             " attempts fail hue, agli entry-touch ka wait karenge.");
      leg.wantOpen  = false;
      leg.attempts  = 0;
      leg.lastPrice = 0;
     }
  }

//+------------------------------------------------------------------+
ulong FindPositionTicket(string symbol, bool isBuy)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((isBuy && type == POSITION_TYPE_BUY) || (!isBuy && type == POSITION_TYPE_SELL))
         return t;
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| Leg kholta hai: market order TP ke saath, phir actual fill price  |
//| se SL attach (agar enabled). Order me SL nahi jaata, isliye       |
//| min-distance rejection se entry miss nahi hoti.                   |
//+------------------------------------------------------------------+
void TryOpenLeg(HedgeLeg &leg, HedgeLeg &other)
  {
   string symbol = g_Sequence.symbol;
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   // Spread gate. Pehli entry me dusri leg ko hedge complete karne ke liye turant kholte hain.
   bool completingHedge = (leg.entries == 0 && other.entries > 0);
   if(!completingHedge && SymbolInfoInteger(symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints)
      return;

   double price = LegPrice(leg);
   if(price <= 0)
     {
      OpenFailed(leg, "valid price nahi mili");
      return;
     }

   double tp = leg.isBuy ? price + InpTPDollars : price - InpTPDollars;
   tp = NormalizeDouble(tp, digits);

   bool ok;
   if(leg.isBuy)
      ok = trade.Buy(InpLotSize, symbol, 0, 0, tp, "");
   else
      ok = trade.Sell(InpLotSize, symbol, 0, 0, tp, "");

   if(!ok)
     {
      OpenFailed(leg, "RetCode=" + IntegerToString((int)trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
      return;
     }

   // ---- Position ID aur actual fill price ----
   ulong  dealTicket = trade.ResultDeal();
   ulong  positionId = 0;
   double fillPrice  = price;

   if(dealTicket > 0 && HistoryDealSelect(dealTicket))
     {
      positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      double dealPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      if(dealPrice > 0)
         fillPrice = dealPrice;
     }
   if(positionId == 0)
      positionId = trade.ResultOrder();
   if(positionId == 0 || !PositionSelectByTicket(positionId))
      positionId = FindPositionTicket(symbol, leg.isBuy);

   if(positionId == 0)
     {
      LogErr(Side(leg) + " " + symbol + " position khuli par ticket track nahi ho paya - is leg ko manually dekho.");
      leg.wantOpen = false;
      leg.done     = true;
      return;
     }

   if(PositionSelectByTicket(positionId))
      fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);

   leg.opened       = true;
   leg.wantOpen     = false;
   leg.attempts     = 0;
   leg.ticket       = positionId;
   leg.brokerSL     = false;
   leg.slClosing    = false;
   leg.historyTries = 0;
   leg.entries++;
   leg.slLevel      = NormalizeDouble(leg.isBuy ? fillPrice - InpSLDollars : fillPrice + InpSLDollars, digits);

   if(InpSendSLToBroker && trade.PositionModify(positionId, leg.slLevel, tp))
      leg.brokerSL = true;

   string tag = (leg.entries == 1) ? "[ENTRY]" : "[REENTRY #" + IntegerToString(leg.entries - 1) + "]";
   Print(tag, " ", Side(leg), " ", symbol, " lot=", DoubleToString(InpLotSize, 2),
         " price=", Px(fillPrice), " SL=", Px(leg.slLevel), " TP=", Px(tp));
  }

//+------------------------------------------------------------------+
//| Khuli leg: position gayab ho gayi toh reason dekho, warna         |
//| broker SL na ho toh EA khud SL check kare                         |
//+------------------------------------------------------------------+
void MonitorLeg(HedgeLeg &leg)
  {
   string symbol = g_Sequence.symbol;

   if(!PositionSelectByTicket(leg.ticket))
     {
      HandleLegClosed(leg);
      return;
     }

   if(leg.brokerSL)
      return;

   // Software SL: BUY ka exit BID par, SELL ka ASK par (broker jaisa)
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0)
      return;

   bool slHit = leg.isBuy ? (bid <= leg.slLevel) : (ask >= leg.slLevel);
   if(!slHit)
      return;

   leg.slClosing = true;
   if(trade.PositionClose(leg.ticket))
      HandleLegClosed(leg);
   else
     {
      leg.slClosing = false;
      LogErr(Side(leg) + " " + symbol + " SL close fail: RetCode=" + IntegerToString((int)trade.ResultRetcode()) +
             " " + trade.ResultRetcodeDescription() + " - agla tick retry.");
     }
  }

//+------------------------------------------------------------------+
bool GetExitDeal(ulong positionTicket, long &reason, double &price)
  {
   if(!HistorySelectByPosition(positionTicket))
      return false;

   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong dTicket = HistoryDealGetTicket(i);
      if(dTicket == 0)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      reason = HistoryDealGetInteger(dTicket, DEAL_REASON);
      price  = HistoryDealGetDouble(dTicket, DEAL_PRICE);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Position band ho chuki:                                           |
//|   SL  -> leg flat, price entry par wapas aane par reentry         |
//|   TP / manual -> leg hamesha ke liye done                         |
//+------------------------------------------------------------------+
void HandleLegClosed(HedgeLeg &leg)
  {
   string symbol    = g_Sequence.symbol;
   bool   isSL      = false;
   bool   isTP      = false;
   double exitPrice = 0;

   if(leg.slClosing)
     {
      isSL      = true;
      exitPrice = leg.isBuy ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
     }
   else
     {
      long reason = 0;
      if(!GetExitDeal(leg.ticket, reason, exitPrice))
        {
         leg.historyTries++;
         if(leg.historyTries < 50)
            return;   // history abhi update nahi hui - agle tick dobara check
        }
      else
        {
         ENUM_DEAL_REASON r = (ENUM_DEAL_REASON)reason;
         isSL = (r == DEAL_REASON_SL);
         isTP = (r == DEAL_REASON_TP);
        }
     }

   leg.opened       = false;
   leg.wantOpen     = false;
   leg.slClosing    = false;
   leg.historyTries = 0;

   if(isSL)
     {
      leg.lastPrice = LegPrice(leg);
      Print("[SL HIT] ", Side(leg), " ", symbol, " price=", Px(exitPrice),
            " - reentry ka wait @ ", Px(g_Sequence.entry));
      return;
     }

   leg.done = true;
   if(isTP)
      Print("[TP HIT] ", Side(leg), " ", symbol, " price=", Px(exitPrice), " - ye leg complete, reentry nahi hogi.");
   else
      Print("[LEG DONE] ", Side(leg), " ", symbol, " - manual/other close, reentry nahi hogi.");
  }

//+------------------------------------------------------------------+
void ScanSignalFolder()
  {
   string searchPath = InpSignalFolder + "\\*.txt";
   string fileName;
   long   searchHandle = FileFindFirst(searchPath, fileName);

   if(searchHandle == INVALID_HANDLE)
      return;

   do
     {
      if(StringFind(fileName, "CLOSE_") == 0)
         MoveToProcessed(fileName);   // image-close EA me use nahi hota - ignore
      else
         ProcessSignalFile(fileName);
     }
   while(FileFindNext(searchHandle, fileName));

   FileFindClose(searchHandle);
  }

//+------------------------------------------------------------------+
void ProcessSignalFile(string fileName)
  {
   string fullPath = InpSignalFolder + "\\" + fileName;

   int handle = FileOpen(fullPath, FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      LogErr("File open nahi ho payi: " + fullPath + " | code " + IntegerToString(GetLastError()));
      return;
     }

   string content = "";
   while(!FileIsEnding(handle))
      content += FileReadString(handle);
   FileClose(handle);

   string symbolRaw = JsonGetString(content, "symbol");
   string direction = JsonGetString(content, "direction");
   double entry     = JsonGetDouble(content, "entry");   // signal ke SL/TP ignore

   if(symbolRaw == "" || direction == "" || entry <= 0)
     {
      LogErr("Signal invalid (symbol/direction/entry me se kuch missing): " + fileName);
      MoveToProcessed(fileName);
      return;
     }

   string symbol = symbolRaw + InpSymbolSuffix;

   if(!SymbolSelect(symbol, true))
     {
      LogErr("Symbol Market Watch me nahi mila: '" + symbol + "'");
      MoveToProcessed(fileName);
      return;
     }

   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   string sigText = direction + " " + symbol + " entry=" + DoubleToString(entry, digits);

   // Koi position khuli hai -> naya signal ignore
   if(g_Sequence.active && (g_BuyLeg.opened || g_SellLeg.opened))
     {
      Print("[SIGNAL IGNORED] ", sigText, " - pichhla trade abhi chal raha hai.");
      MoveToProcessed(fileName);
      return;
     }

   bool   isBuy        = (direction == "BUY");
   double currentPrice = isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);

   g_Sequence.active    = true;
   g_Sequence.triggered = false;
   g_Sequence.symbol    = symbol;
   g_Sequence.isBuy     = isBuy;
   g_Sequence.entry     = entry;
   g_Sequence.lastPrice = currentPrice;

   ResetLeg(g_BuyLeg, true);
   ResetLeg(g_SellLeg, false);

   Print("[SIGNAL] ", sigText, " - entry par BUY + SELL dono khulenge (lot ", DoubleToString(InpLotSize, 2), " har leg).");

   MoveToProcessed(fileName);
  }

//+------------------------------------------------------------------+
void MoveToProcessed(string fileName)
  {
   if(!FileIsExist(ProcessedFolder))
      FolderCreate(ProcessedFolder);

   string src = InpSignalFolder + "\\" + fileName;
   string dst = ProcessedFolder + "\\" + fileName;

   if(!FileMove(src, 0, dst, FILE_REWRITE))
      LogErr("File move nahi ho payi: " + fileName + " | code " + IntegerToString(GetLastError()));
  }

//+------------------------------------------------------------------+
//| Simple flat-JSON string field extractor: "key": "value"          |
//+------------------------------------------------------------------+
string JsonGetString(string json, string key)
  {
   string pattern = "\"" + key + "\":";
   int pos = StringFind(json, pattern);
   if(pos < 0)
      return "";

   pos += StringLen(pattern);

   while(pos < StringLen(json) && StringGetCharacter(json, pos) == ' ')
      pos++;

   if(pos >= StringLen(json))
      return "";

   if(StringGetCharacter(json, pos) == '"')
     {
      int start = pos + 1;
      int end = StringFind(json, "\"", start);
      if(end < 0)
         return "";
      return StringSubstr(json, start, end - start);
     }

   return "";
  }

//+------------------------------------------------------------------+
//| Simple flat-JSON numeric field extractor: "key": 123.45 or null  |
//+------------------------------------------------------------------+
double JsonGetDouble(string json, string key)
  {
   string pattern = "\"" + key + "\":";
   int pos = StringFind(json, pattern);
   if(pos < 0)
      return 0;

   pos += StringLen(pattern);

   while(pos < StringLen(json) && StringGetCharacter(json, pos) == ' ')
      pos++;

   int end = pos;
   while(end < StringLen(json))
     {
      ushort ch = StringGetCharacter(json, end);
      if(ch == ',' || ch == '}')
         break;
      end++;
     }

   string valueStr = StringSubstr(json, pos, end - pos);
   StringTrimLeft(valueStr);
   StringTrimRight(valueStr);

   if(valueStr == "null" || valueStr == "")
      return 0;

   return StringToDouble(valueStr);
  }
//+------------------------------------------------------------------+
