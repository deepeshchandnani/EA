//+------------------------------------------------------------------+
//|                                         TrendingEA100_Hedge.mq5   |
//| Telegram -> MT5 Signal Copier (v6 - Hedged Entry)                 |
//|                                                                   |
//| Logic:                                                            |
//|  - Signal me sirf ENTRY price (single number) use hota hai.       |
//|  - Price jab entry par pahunche -> BUY aur SELL DONO ek saath     |
//|    khulte hain (same lot, default 0.10).                          |
//|  - Har leg ka SL = fill price se $1.4 door, TP = $50 door         |
//|    (signal ke SL/TP ignore hote hain).                            |
//|  - Martingale nahi hai. Lot hamesha fixed.                        |
//|  - Dono legs band hone par sequence khatam, agla signal le sakte  |
//|    hain.                                                          |
//|                                                                   |
//| ZAROORI: Account HEDGING type ka hona chahiye, warna BUY aur SELL |
//| net ho jaate hain. EA netting account par start hi nahi hoga.     |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "6.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//----------------- INPUTS -----------------
input string InpSignalFolder     = "Signals";   // MQL5\Files\ ke andar folder ka naam
input double InpLotSize          = 0.10;        // Har leg ka lot (BUY aur SELL dono same)
input double InpSLDollars        = 1.4;         // SL distance (price units, gold me $1 = 1.00) - fill price se
input double InpTPDollars        = 50.0;        // TP distance (price units) - fill price se
input bool   InpSendSLToBroker   = true;        // true: position khulne ke baad SL broker ko bheja jata hai. Broker reject kare toh EA khud monitor karega
input int    InpSlippagePoints   = 20;          // Slippage (points)
input long   InpMagicNumber      = 20260708;    // Magic number
input string InpSymbolSuffix     = "";          // Broker symbol suffix, e.g. ".m" or "!"
input int    InpMaxSpreadPoints  = 100;         // Is se zyada spread ho toh pehli leg nahi kholega (agla tick retry)
input int    InpMaxLegRetries    = 20;          // Ek leg kholne ke max attempts (fail hone par), uske baad wo leg chhod di jaati hai
input int    InpPriceCheckMillis = 200;         // Price monitor kitni fast check ho (milliseconds)
input int    InpFolderScanSeconds= 2;           // Signal folder scan interval (seconds)
input bool   InpVerboseLogging   = true;        // Detailed logs

string ProcessedFolder;
int    ScanCounter = 0;
int    g_FolderScanEveryNTicks = 10;
int    g_HeartbeatEveryNTicks  = 150;

//----------------- STATE -----------------
struct HedgeLeg
  {
   bool   isBuy;
   bool   opened;      // position abhi khuli hai
   bool   done;        // leg khatam (close ho gayi ya chhod di gayi) - dobara nahi khulegi
   bool   brokerSL;    // true = SL broker-side laga hai, false = EA monitor karega
   ulong  ticket;      // position ID (close ke baad bhi record ke liye rakha jata hai)
   double openPrice;
   double slLevel;
   int    attempts;
  };

struct TradeSequence
  {
   bool   active;
   bool   triggered;   // entry touch ho chuki, legs khul rahi hain / khuli hain
   string symbol;
   bool   isBuy;       // signal ki direction - sirf trigger ke liye ASK/BID choose karne me kaam aati hai
   double entry;
   double lastPrice;   // entry touch/cross detect karne ke liye
  };

TradeSequence g_Sequence;
HedgeLeg      g_BuyLeg;
HedgeLeg      g_SellLeg;

//+------------------------------------------------------------------+
void ResetLeg(HedgeLeg &leg, bool isBuy)
  {
   leg.isBuy     = isBuy;
   leg.opened    = false;
   leg.done      = false;
   leg.brokerSL  = false;
   leg.ticket    = 0;
   leg.openPrice = 0;
   leg.slLevel   = 0;
   leg.attempts  = 0;
  }

//+------------------------------------------------------------------+
void EndSequence()
  {
   g_Sequence.active    = false;
   g_Sequence.triggered = false;
   Print("[SEQUENCE END] ", g_Sequence.symbol, " - dono legs complete, agla signal le sakte hain.");
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   ProcessedFolder = InpSignalFolder + "\\Processed";

   Print("=====================================================");
   Print("TrendingEA100_Hedge v6 starting up");

   // Hedging account check - BUY + SELL same symbol par sirf hedging account me alag-alag rehte hain
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("[FATAL] Ye account HEDGING type ka nahi hai. BUY aur SELL net ho jayenge, isliye EA start nahi hoga.");
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

   Print("Watching folder (relative to MQL5\\Files\\): ", InpSignalFolder);
   Print("Processed folder: ", ProcessedFolder);
   Print("Lot (fixed, har leg): ", InpLotSize, " | SL distance: $", InpSLDollars, " | TP distance: $", InpTPDollars,
         " | Broker SL: ", (InpSendSLToBroker ? "YES (fallback: EA-monitored)" : "NO (EA-monitored)"));
   Print("Magic: ", InpMagicNumber, " | Suffix: '", InpSymbolSuffix, "' | Martingale: REMOVED");

   g_Sequence.active    = false;
   g_Sequence.triggered = false;
   g_Sequence.symbol    = "";
   g_Sequence.isBuy     = true;
   g_Sequence.entry     = 0;
   g_Sequence.lastPrice = 0;
   ResetLeg(g_BuyLeg, true);
   ResetLeg(g_SellLeg, false);

   if(!FileIsExist(InpSignalFolder))
      Print("WARNING: '", InpSignalFolder, "' folder abhi MQL5\\Files\\ ke andar nahi mil raha.");
   else
      Print("OK: Signal folder mil gaya.");

   g_FolderScanEveryNTicks = (int)MathMax(1, MathRound((InpFolderScanSeconds * 1000.0) / InpPriceCheckMillis));
   g_HeartbeatEveryNTicks  = (int)MathMax(1, MathRound(30000.0 / InpPriceCheckMillis)); // ~30 sec heartbeat

   EventSetMillisecondTimer(InpPriceCheckMillis);
   Print("Timer: har ", InpPriceCheckMillis, "ms price monitor. Folder scan har ~", InpFolderScanSeconds, " sec.");
   Print("=====================================================");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_Sequence.active && g_Sequence.triggered)
     {
      if((g_BuyLeg.opened && !g_BuyLeg.brokerSL) || (g_SellLeg.opened && !g_SellLeg.brokerSL))
         Print("[WARNING] EA band ho raha hai par kuch positions ka SL EA-monitored tha - ab unka SL monitor nahi hoga! Manually check karo.");
     }
   Print("TrendingEA100_Hedge stopped. Reason code: ", reason);
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   ScanCounter++;
   if(InpVerboseLogging && ScanCounter % g_HeartbeatEveryNTicks == 0)
      Print("[HEARTBEAT] EA chal raha hai, scan #", ScanCounter,
            " | Sequence active: ", (g_Sequence.active ? "YES" : "NO"),
            " | triggered: ", (g_Sequence.triggered ? "YES" : "NO"));

   // Price monitoring HAR tick pe (fast reaction ke liye)
   CheckActiveSequence();

   // Folder scan sirf har N ticks pe
   if(ScanCounter % g_FolderScanEveryNTicks == 0)
      ScanSignalFolder();
  }

//+------------------------------------------------------------------+
//| Wait state: entry touch hone ka intezaar. Touch hote hi legs      |
//| manage karna shuru.                                               |
//+------------------------------------------------------------------+
void CheckActiveSequence()
  {
   if(!g_Sequence.active)
      return;

   string symbol = g_Sequence.symbol;
   if(!SymbolSelect(symbol, true))
      return;

   // Entry touch ho chuki -> ab legs kholna / monitor karna
   if(g_Sequence.triggered)
     {
      ManageLegs();
      return;
     }

   // Entry ka wait
   double currentPrice = g_Sequence.isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   if(currentPrice <= 0)
      return;

   if(g_Sequence.lastPrice <= 0)
     {
      g_Sequence.lastPrice = currentPrice;   // pehla valid price - reference set
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
      Print("[ENTRY TRIGGER] ", symbol, " - price entry (", g_Sequence.entry, ") tak pahunch gayi. Current=", currentPrice,
            ". BUY + SELL dono khol rahe hain.");
      g_Sequence.triggered = true;
      ManageLegs();
     }
  }

//+------------------------------------------------------------------+
//| Trigger ke baad har tick:                                         |
//|  A) Jo leg abhi tak nahi khuli use kholo (retry ke saath)         |
//|  B) Khuli legs ka close detect + (zaroorat par) software SL       |
//|  C) Dono legs khatam -> sequence end                              |
//+------------------------------------------------------------------+
void ManageLegs()
  {
   string symbol = g_Sequence.symbol;

   // Spread check sirf tab jab abhi tak koi leg khuli hi nahi.
   // Ek leg khul jaye toh dusri turant kholte hain (hedge complete karne ke liye).
   bool anyLegEverOpened = (g_BuyLeg.ticket != 0 || g_SellLeg.ticket != 0);
   bool needOpening = (!g_BuyLeg.opened && !g_BuyLeg.done) || (!g_SellLeg.opened && !g_SellLeg.done);

   if(needOpening)
     {
      bool spreadOK = true;
      if(!anyLegEverOpened)
        {
         long spreadPoints = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
         if(spreadPoints > InpMaxSpreadPoints)
           {
            spreadOK = false;
            if(InpVerboseLogging && ScanCounter % g_HeartbeatEveryNTicks == 0)
               Print("[SKIP ATTEMPT] Spread zyada hai (", spreadPoints, " points) - agla tick retry hoga.");
           }
        }

      if(spreadOK)
        {
         if(!g_BuyLeg.opened && !g_BuyLeg.done)
            OpenLeg(g_BuyLeg);
         if(!g_SellLeg.opened && !g_SellLeg.done)
            OpenLeg(g_SellLeg);
        }
     }

   MonitorLeg(g_BuyLeg);
   MonitorLeg(g_SellLeg);

   if(g_BuyLeg.done && g_SellLeg.done)
      EndSequence();
  }

//+------------------------------------------------------------------+
//| Ek leg kholta hai: pehle TP ke saath market order, phir (agar     |
//| enabled) actual fill price se SL broker ko attach karta hai.      |
//| Order me SL nahi jaata, isliye min-distance rejection se trade    |
//| miss nahi hota.                                                   |
//+------------------------------------------------------------------+
void OpenLeg(HedgeLeg &leg)
  {
   string symbol = g_Sequence.symbol;
   string label  = leg.isBuy ? "BUY" : "SELL";
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   leg.attempts++;

   double price = leg.isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   if(price <= 0)
     {
      Print("[FAILED] ", label, " ", symbol, " - valid price nahi mili (attempt ", leg.attempts, "/", InpMaxLegRetries, ").");
      if(leg.attempts >= InpMaxLegRetries)
        {
         leg.done = true;
         Print("[ABANDON] ", label, " leg chhod di gayi (max retries).");
        }
      return;
     }

   double tp = leg.isBuy ? price + InpTPDollars : price - InpTPDollars;
   tp = NormalizeDouble(tp, digits);

   bool result;
   if(leg.isBuy)
      result = trade.Buy(InpLotSize, symbol, 0, 0, tp, "");    // SL = 0 -> order ke saath nahi jaata
   else
      result = trade.Sell(InpLotSize, symbol, 0, 0, tp, "");

   if(!result)
     {
      Print("[FAILED] Order FAILED: ", label, " ", symbol,
            " | GetLastError=", GetLastError(), " | RetCode=", trade.ResultRetcode(),
            " | RetCodeDescription=", trade.ResultRetcodeDescription(),
            " | attempt ", leg.attempts, "/", InpMaxLegRetries);
      if(leg.attempts >= InpMaxLegRetries)
        {
         leg.done = true;
         Print("[ABANDON] ", label, " leg chhod di gayi (max retries).");
        }
      return;
     }

   // ---- Position ID aur actual fill price nikalo ----
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

   if(positionId != 0 && PositionSelectByTicket(positionId))
      fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);

   leg.opened    = true;
   leg.ticket    = positionId;
   leg.openPrice = fillPrice;
   leg.brokerSL  = false;
   leg.slLevel   = NormalizeDouble(leg.isBuy ? fillPrice - InpSLDollars : fillPrice + InpSLDollars, digits);

   Print("[SUCCESS] ", label, " ", symbol, " Lot=", InpLotSize, " Fill=", fillPrice,
         " SL=", leg.slLevel, " TP=", tp, " PositionID=", positionId);

   // ---- SL broker ko attach karne ki koshish (optional) ----
   if(InpSendSLToBroker)
     {
      if(trade.PositionModify(positionId, leg.slLevel, tp))
        {
         leg.brokerSL = true;
         Print("[SL ATTACHED] ", label, " PositionID=", positionId, " broker-side SL=", leg.slLevel);
        }
      else
         Print("[SL FALLBACK] ", label, " PositionID=", positionId, " broker ne SL reject kiya (RetCode=",
               trade.ResultRetcode(), " ", trade.ResultRetcodeDescription(),
               ") - EA khud SL monitor karega @ ", leg.slLevel);
     }
  }

//+------------------------------------------------------------------+
//| Khuli leg ka status check:                                        |
//|  - Position ab nahi hai (TP/SL/manual) -> leg done                |
//|  - Broker SL nahi laga toh EA khud SL level check karke close     |
//+------------------------------------------------------------------+
void MonitorLeg(HedgeLeg &leg)
  {
   if(!leg.opened || leg.done)
      return;

   string symbol = g_Sequence.symbol;
   string label  = leg.isBuy ? "BUY" : "SELL";

   // Position gayab ho gayi -> broker TP/SL ya manual close
   if(!PositionSelectByTicket(leg.ticket))
     {
      LogClosedLeg(leg, "broker/manual close");
      leg.opened = false;
      leg.done   = true;
      return;
     }

   if(leg.brokerSL)
      return;   // broker khud SL handle kar raha hai

   // Software SL: BUY ka exit BID par hota hai, SELL ka ASK par (broker jaisa hi)
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0)
      return;

   bool slHit = leg.isBuy ? (bid <= leg.slLevel) : (ask >= leg.slLevel);
   if(!slHit)
      return;

   Print("[SL HIT - EA monitored] ", label, " ", symbol, " bid=", bid, " ask=", ask,
         " SL=", leg.slLevel, ". Close kar rahe hain.");

   if(trade.PositionClose(leg.ticket))
     {
      LogClosedLeg(leg, "EA-monitored SL");
      leg.opened = false;
      leg.done   = true;
     }
   else
      Print("[ERROR] SL close FAILED: ", label, " PositionID=", leg.ticket, " | RetCode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription(), " - agla tick retry hoga.");
  }

//+------------------------------------------------------------------+
string DealReasonText(long reasonValue)
  {
   ENUM_DEAL_REASON r = (ENUM_DEAL_REASON)reasonValue;
   if(r == DEAL_REASON_TP)
      return "TP";
   if(r == DEAL_REASON_SL)
      return "SL (broker)";
   if(r == DEAL_REASON_CLIENT || r == DEAL_REASON_MOBILE || r == DEAL_REASON_WEB)
      return "MANUAL";
   if(r == DEAL_REASON_EXPERT)
      return "EA";
   return "code " + (string)reasonValue;
  }

//+------------------------------------------------------------------+
void LogClosedLeg(HedgeLeg &leg, string note)
  {
   string label = leg.isBuy ? "BUY" : "SELL";
   string info  = "history details abhi available nahi";

   if(HistorySelectByPosition(leg.ticket))
     {
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         ulong dTicket = HistoryDealGetTicket(i);
         if(dTicket == 0)
            continue;
         if(HistoryDealGetInteger(dTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
            continue;

         double profit = HistoryDealGetDouble(dTicket, DEAL_PROFIT)
                       + HistoryDealGetDouble(dTicket, DEAL_SWAP)
                       + HistoryDealGetDouble(dTicket, DEAL_COMMISSION);
         info = "reason=" + DealReasonText(HistoryDealGetInteger(dTicket, DEAL_REASON))
              + " | net profit=" + DoubleToString(profit, 2);
         break;
        }
     }

   Print("[LEG CLOSED] ", label, " ", g_Sequence.symbol, " PositionID=", leg.ticket, " | ", note, " | ", info);
  }

//+------------------------------------------------------------------+
void ScanSignalFolder()
  {
   string searchPath = InpSignalFolder + "\\*.txt";
   string fileName;
   long   searchHandle = FileFindFirst(searchPath, fileName);

   if(searchHandle == INVALID_HANDLE)
     {
      if(InpVerboseLogging && ScanCounter % g_HeartbeatEveryNTicks == 0)
         Print("[SCAN] Koi .txt file nahi mili folder me: ", searchPath);
      return;
     }

   int filesFound = 0;
   do
     {
      filesFound++;
      Print("[FOUND] File mili: ", fileName);

      if(StringFind(fileName, "CLOSE_") == 0)
         MoveToProcessed(fileName); // image-close logic is EA me nahi hai - ignore
      else
         ProcessSignalFile(fileName);
     }
   while(FileFindNext(searchHandle, fileName));

   FileFindClose(searchHandle);

   if(filesFound > 0)
      Print("[SCAN] Is round me total ", filesFound, " file(s) process hui.");
  }

//+------------------------------------------------------------------+
void ProcessSignalFile(string fileName)
  {
   string fullPath = InpSignalFolder + "\\" + fileName;

   int handle = FileOpen(fullPath, FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      Print("[ERROR] File open nahi ho payi: ", fullPath, " | Error code: ", GetLastError());
      return;
     }

   string content = "";
   while(!FileIsEnding(handle))
      content += FileReadString(handle);
   FileClose(handle);

   Print("[CONTENT] ", fileName, " => ", content);

   // Legs khuli hain / khul rahi hain -> naya signal ignore
   if(g_Sequence.active && g_Sequence.triggered)
     {
      Print("[SEQUENCE ACTIVE] Hedge trade chal raha hai (", g_Sequence.symbol, "), naya signal ignore: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   string symbolRaw = JsonGetString(content, "symbol");
   string direction = JsonGetString(content, "direction");
   double entry     = JsonGetDouble(content, "entry");

   Print("[PARSED] symbol=", symbolRaw, " direction=", direction, " entry=", entry,
         " (signal ke SL/TP ignore - EA fixed SL $", InpSLDollars, " / TP $", InpTPDollars, " use karta hai)");

   if(symbolRaw == "" || direction == "")
     {
      Print("[SKIP] Invalid signal (symbol/direction missing), file: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   if(entry <= 0)
     {
      Print("[SKIP] Entry price signal me nahi mili. File: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   string symbol = symbolRaw + InpSymbolSuffix;

   if(!SymbolSelect(symbol, true))
     {
      Print("[ERROR] Symbol Market Watch me nahi mila: '", symbol, "'.");
      MoveToProcessed(fileName);
      return;
     }

   // Purana sequence sirf entry ke wait me tha (koi trade nahi khula) -> naye signal se replace
   if(g_Sequence.active && !g_Sequence.triggered)
      Print("[SIGNAL REPLACED] Pichhla signal (", g_Sequence.symbol, " @ ", g_Sequence.entry,
            ") entry ke wait me tha, naye signal se replace kar rahe hain.");

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

   Print("[SEQUENCE STARTED] ", direction, " ", symbol, " | Entry=", entry,
         " | Entry par BUY + SELL dono khulenge | Lot=", InpLotSize, " har leg",
         " | SL=$", InpSLDollars, " | TP=$", InpTPDollars, " | Current price=", currentPrice);

   MoveToProcessed(fileName);
  }

//+------------------------------------------------------------------+
void MoveToProcessed(string fileName)
  {
   if(!FileIsExist(ProcessedFolder))
     {
      FolderCreate(ProcessedFolder);
      Print("[INFO] Processed folder banaya gaya: ", ProcessedFolder);
     }

   string src = InpSignalFolder + "\\" + fileName;
   string dst = ProcessedFolder + "\\" + fileName;

   if(FileMove(src, 0, dst, FILE_REWRITE))
      Print("[INFO] File processed folder me move ho gayi: ", fileName);
   else
      Print("[ERROR] File move nahi ho payi: ", fileName, " | Error: ", GetLastError());
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
