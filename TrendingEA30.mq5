//+------------------------------------------------------------------+
//|                                          SignalCopierEA_v2.mq5    |
//| Telegram -> MT5 Signal Copier (v5 - Software-Monitored SL Reentry)|
//| SL broker ko kabhi nahi bheja jata (Invalid price / min-distance  |
//| rejection se bachne ke liye). EA khud har tick price monitor      |
//| karta hai:                                                        |
//|   - Entry se 1 pip($1) door ho -> position close, reentry wait    |
//|   - Signal ke diye SL tak pahunche -> sequence FAIL, reentry band |
//| TP hamesha broker-side rehta hai (signal ka exact TP1).           |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "5.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//----------------- INPUTS -----------------
input string InpSignalFolder   = "Signals";   // MQL5\Files\ ke andar folder ka naam
input double InpLotSize        = 0.03;        // Base lot size (martingale isi se start hota hai)
input double InpMartingaleMultiplier = 2.0;   // Signal-SL breach (poora sequence fail) par lot isse multiply hoga (uncapped)
input int    InpSlippagePoints = 20;          // Slippage (points)
input long   InpMagicNumber    = 20260708;    // Magic number
input string InpSymbolSuffix   = "";          // Broker symbol suffix, e.g. ".m" or "!"
input double InpReentryDollars = 1.0;         // Har reentry attempt ka monitored exit - entry se itne $ door (1 pip = $1)
input int    InpMaxSpreadPoints= 100;         // Is se zyada spread ho toh attempt skip (agla tick retry karega)
input int    InpPollSeconds    = 2;           // Folder/price check interval (seconds)
input bool   InpVerboseLogging = true;        // Detailed scan logs

string ProcessedFolder;
int    ScanCounter = 0;
double g_CurrentLot;
string g_LotGlobalVarName;
double g_LastProcessedDealTicket;
string g_LastDealGlobalVarName;

//----------------- TRADE SEQUENCE -----------------
struct TradeSequence
  {
   bool     active;
   string   symbol;
   bool     isBuy;
   double   entry;          // fixed entry price (reentries hamesha isi price par)
   double   signalSL;       // signal ka diya hua SL - kill switch (EA monitor karta hai, broker ko nahi bhejta)
   double   tp1;            // exact TP1 (broker-side TP order me jata hai)
   double   lot;            // poore sequence ke liye fixed lot
   bool     positionOpen;
   ulong    currentTicket;  // khuli position ka position ID
   double   lastPrice;      // entry touch detect karne ke liye (wait state me)
   string   closeIntent;    // "NONE" / "REENTRY_STOPOUT" / "SEQUENCE_KILL" - hume pata rahe humne kyun close kiya
  };

TradeSequence g_Sequence;

//+------------------------------------------------------------------+
//| MARTINGALE - sequence poori tarah conclude hone par hi lagta hai |
//+------------------------------------------------------------------+
void ApplyMartingaleResult(bool isWin, string reasonNote)
  {
   double previousLot = g_CurrentLot;

   if(isWin)
     {
      g_CurrentLot = InpLotSize;
      Print("[MARTINGALE] Sequence WIN (", reasonNote, "). Lot size reset: ", previousLot, " -> ", g_CurrentLot);
     }
   else
     {
      g_CurrentLot = g_CurrentLot * InpMartingaleMultiplier;
      Print("[MARTINGALE] Sequence LOSS (", reasonNote, "). Lot size ", previousLot, " -> ", g_CurrentLot,
            " (multiplier: ", InpMartingaleMultiplier, ", uncapped)");
     }

   GlobalVariableSet(g_LotGlobalVarName, g_CurrentLot);
  }

//+------------------------------------------------------------------+
void EndSequence()
  {
   g_Sequence.active = false;
   g_Sequence.positionOpen = false;
   g_Sequence.currentTicket = 0;
   g_Sequence.closeIntent = "NONE";
   Print("[SEQUENCE END] ", g_Sequence.symbol, " sequence complete ho gaya.");
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   ProcessedFolder = InpSignalFolder + "\\Processed";
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   Print("=====================================================");
   Print("SignalCopierEA v5 (Software-Monitored SL Reentry) starting up");
   Print("Watching folder (relative to MQL5\\Files\\): ", InpSignalFolder);
   Print("Processed folder: ", ProcessedFolder);

   g_LotGlobalVarName = "TGSignalCopier_CurrentLot_" + (string)InpMagicNumber;
   if(GlobalVariableCheck(g_LotGlobalVarName))
     {
      g_CurrentLot = GlobalVariableGet(g_LotGlobalVarName);
      Print("Martingale lot restore hui pichhle session se: ", g_CurrentLot);
     }
   else
     {
      g_CurrentLot = InpLotSize;
      GlobalVariableSet(g_LotGlobalVarName, g_CurrentLot);
      Print("Martingale lot fresh start: ", g_CurrentLot);
     }

   g_LastDealGlobalVarName = "TGSignalCopier_LastDeal_" + (string)InpMagicNumber;
   if(GlobalVariableCheck(g_LastDealGlobalVarName))
     {
      g_LastProcessedDealTicket = GlobalVariableGet(g_LastDealGlobalVarName);
      Print("Last processed deal ticket restore hua: ", g_LastProcessedDealTicket);
     }
   else
     {
      g_LastProcessedDealTicket = 0;
      HistorySelect(0, TimeCurrent());
      int totalDeals = HistoryDealsTotal();
      for(int i = 0; i < totalDeals; i++)
        {
         ulong dTicket = HistoryDealGetTicket(i);
         if((double)dTicket > g_LastProcessedDealTicket)
            g_LastProcessedDealTicket = (double)dTicket;
        }
      GlobalVariableSet(g_LastDealGlobalVarName, g_LastProcessedDealTicket);
      Print("Fresh start - baseline deal ticket set: ", g_LastProcessedDealTicket);
     }

   Print("Base lot: ", InpLotSize, " | Martingale multiplier: ", InpMartingaleMultiplier,
         " | Magic: ", InpMagicNumber, " | Suffix: '", InpSymbolSuffix, "'");
   Print("SL broker ko NAHI bheja jata - EA khud monitor karta hai. Reentry exit: $", InpReentryDollars,
         " | Sequence kill: signal ka SL | TP: hamesha broker-side, signal ka exact TP1");

   g_Sequence.active = false;
   g_Sequence.positionOpen = false;
   g_Sequence.currentTicket = 0;
   g_Sequence.closeIntent = "NONE";

   if(!FileIsExist(InpSignalFolder))
      Print("WARNING: '", InpSignalFolder, "' folder abhi MQL5\\Files\\ ke andar nahi mil raha.");
   else
      Print("OK: Signal folder mil gaya.");

   EventSetTimer(InpPollSeconds);
   Print("Timer set: har ", InpPollSeconds, " second me folder + price scan hoga.");
   Print("=====================================================");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Print("SignalCopierEA v5 stopped. Reason code: ", reason);
  }

//+------------------------------------------------------------------+
//| Trade history poll karta hai - closeIntent ke hisaab se decide   |
//| karta hai ki reentry karni hai ya sequence conclude karni hai     |
//+------------------------------------------------------------------+
void CheckClosedTrades()
  {
   HistorySelect(0, TimeCurrent());
   int totalDeals = HistoryDealsTotal();
   double highestTicketSeen = g_LastProcessedDealTicket;

   for(int i = 0; i < totalDeals; i++)
     {
      ulong dTicket = HistoryDealGetTicket(i);

      if((double)dTicket <= g_LastProcessedDealTicket)
         continue;

      if((double)dTicket > highestTicketSeen)
         highestTicketSeen = (double)dTicket;

      long dealMagic = HistoryDealGetInteger(dTicket, DEAL_MAGIC);
      long dealEntry = HistoryDealGetInteger(dTicket, DEAL_ENTRY);

      if(dealMagic != InpMagicNumber || dealEntry != DEAL_ENTRY_OUT)
         continue;

      long positionId = HistoryDealGetInteger(dTicket, DEAL_POSITION_ID);
      long dealReason = HistoryDealGetInteger(dTicket, DEAL_REASON);
      double profit = HistoryDealGetDouble(dTicket, DEAL_PROFIT)
                     + HistoryDealGetDouble(dTicket, DEAL_SWAP)
                     + HistoryDealGetDouble(dTicket, DEAL_COMMISSION);

      if(g_Sequence.active && g_Sequence.positionOpen && (ulong)positionId == g_Sequence.currentTicket)
        {
         if(dealReason == DEAL_REASON_TP)
           {
            // Asli broker TP1 hit hua - sequence SUCCESS
            Print("[SEQUENCE RESOLVED] TP1 hit (deal #", dTicket, " profit=", profit, ").");
            ApplyMartingaleResult(true, "TP1 hit");
            EndSequence();
           }
         else if(g_Sequence.closeIntent == "REENTRY_STOPOUT")
           {
            // Humne khud close kiya kyunki price entry se $1 door chali gayi - martingale untouched
            Print("[REENTRY] EA-monitored stop-out (deal #", dTicket, " profit=", profit,
                  ") - martingale untouched. Wapas entry (", g_Sequence.entry, ") ke liye wait kar rahe hain.");
            g_Sequence.positionOpen = false;
            g_Sequence.currentTicket = 0;
            g_Sequence.closeIntent = "NONE";
            g_Sequence.lastPrice = g_Sequence.isBuy ? SymbolInfoDouble(g_Sequence.symbol, SYMBOL_ASK)
                                                     : SymbolInfoDouble(g_Sequence.symbol, SYMBOL_BID);
           }
         else if(g_Sequence.closeIntent == "SEQUENCE_KILL")
           {
            // Humne khud close kiya kyunki price signal SL tak pahunch gayi - martingale already apply ho chuki
            // (detection ke waqt hi) - yahan sirf state clean karna hai
            Print("[SEQUENCE RESOLVED] EA-monitored kill-switch close confirm hua (deal #", dTicket, " profit=", profit, ").");
            EndSequence();
           }
         else
           {
            // Unexpected/manual close (jaise kisi ne terminal me manually close kar diya)
            bool isWin = (profit >= 0);
            Print("[SEQUENCE RESOLVED] Unexpected/manual close (deal #", dTicket, " profit=", profit, " reason=", dealReason, ").");
            ApplyMartingaleResult(isWin, "unexpected/manual close");
            EndSequence();
           }
        }
      else
        {
         // Legacy/stray deal - safety fallback
         double previousLot = g_CurrentLot;
         if(profit < 0)
           {
            g_CurrentLot = g_CurrentLot * InpMartingaleMultiplier;
            Print("[MARTINGALE-FALLBACK] Stray LOSS deal #", dTicket, ". Lot ", previousLot, " -> ", g_CurrentLot);
           }
         else
           {
            g_CurrentLot = InpLotSize;
            Print("[MARTINGALE-FALLBACK] Stray WIN deal #", dTicket, ". Lot reset: ", previousLot, " -> ", g_CurrentLot);
           }
         GlobalVariableSet(g_LotGlobalVarName, g_CurrentLot);
        }
     }

   if(highestTicketSeen > g_LastProcessedDealTicket)
     {
      g_LastProcessedDealTicket = highestTicketSeen;
      GlobalVariableSet(g_LastDealGlobalVarName, g_LastProcessedDealTicket);
     }
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   ScanCounter++;
   if(InpVerboseLogging && ScanCounter % 15 == 0)
      Print("[HEARTBEAT] EA chal raha hai, scan #", ScanCounter,
            " | Sequence active: ", (g_Sequence.active ? "YES" : "NO"));

   CheckClosedTrades();
   CheckActiveSequence();
   ScanSignalFolder();
  }

//+------------------------------------------------------------------+
//| Har tick price monitor karta hai:                                 |
//|  - Position khuli ho: dono exit levels check (reentry-exit aur     |
//|    kill-switch), zaroorat par khud PositionClose() call karta hai  |
//|  - Position band ho (wait state): kill-switch aur entry-touch check|
//+------------------------------------------------------------------+
void CheckActiveSequence()
  {
   if(!g_Sequence.active)
      return;

   string symbol = g_Sequence.symbol;
   if(!SymbolSelect(symbol, true))
      return;

   double currentPrice = g_Sequence.isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);

   if(g_Sequence.positionOpen)
     {
      // Position khuli hai - dono monitored exit levels check karo
      bool killed = g_Sequence.isBuy ? (currentPrice <= g_Sequence.signalSL) : (currentPrice >= g_Sequence.signalSL);
      double reentryLevel = g_Sequence.isBuy ? g_Sequence.entry - InpReentryDollars : g_Sequence.entry + InpReentryDollars;
      bool reentryBreach = g_Sequence.isBuy ? (currentPrice <= reentryLevel) : (currentPrice >= reentryLevel);

      if(killed)
        {
         Print("[SEQUENCE KILLED] ", (g_Sequence.isBuy ? "BUY" : "SELL"), " ", symbol,
               " - price (", currentPrice, ") signal ke SL (", g_Sequence.signalSL, ") tak pahunch gayi (position khuli thi). Close kar rahe hain.");
         ApplyMartingaleResult(false, "signal SL breach (position open) - poora sequence fail");
         g_Sequence.closeIntent = "SEQUENCE_KILL";
         if(!trade.PositionClose(g_Sequence.currentTicket))
           {
            Print("[ERROR] Kill-switch close FAILED: ", GetLastError(), " - agla tick retry hoga.");
            g_Sequence.closeIntent = "NONE"; // retry ke liye reset, martingale already apply ho chuki (dobara nahi lagega kyunki active ab bhi true hai par careful)
           }
        }
      else if(reentryBreach)
        {
         Print("[REENTRY EXIT] ", (g_Sequence.isBuy ? "BUY" : "SELL"), " ", symbol,
               " - price (", currentPrice, ") entry se $", InpReentryDollars, " door chali gayi. Close kar rahe hain (reentry hogi).");
         g_Sequence.closeIntent = "REENTRY_STOPOUT";
         if(!trade.PositionClose(g_Sequence.currentTicket))
           {
            Print("[ERROR] Reentry-exit close FAILED: ", GetLastError(), " - agla tick retry hoga.");
            g_Sequence.closeIntent = "NONE";
           }
        }
      return;
     }

   // Position band hai - wait state (fresh entry ya reentry ka wait)
   bool killedWaiting = g_Sequence.isBuy ? (currentPrice <= g_Sequence.signalSL) : (currentPrice >= g_Sequence.signalSL);
   if(killedWaiting)
     {
      Print("[SEQUENCE KILLED] ", (g_Sequence.isBuy ? "BUY" : "SELL"), " ", symbol,
            " - price (", currentPrice, ") signal ke SL (", g_Sequence.signalSL, ") tak pahunch gayi (wait state me thi). Reentry band.");
      ApplyMartingaleResult(false, "signal SL breach (waiting) - poora sequence fail");
      EndSequence();
      return;
     }

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double diffPrev = g_Sequence.lastPrice - g_Sequence.entry;
   double diffNow  = currentPrice - g_Sequence.entry;

   bool triggered = false;
   if(MathAbs(diffNow) <= point * 2)
      triggered = true;
   else if(diffPrev == 0)
      triggered = true;
   else if((diffPrev > 0 && diffNow < 0) || (diffPrev < 0 && diffNow > 0))
      triggered = true;

   g_Sequence.lastPrice = currentPrice;

   if(triggered)
     {
      Print("[ENTRY TRIGGER] ", (g_Sequence.isBuy ? "BUY" : "SELL"), " ", symbol,
            " - price entry (", g_Sequence.entry, ") tak pahunch gayi. Current=", currentPrice, ". Order fire ho raha hai.");
      OpenReentryPosition();
     }
  }

//+------------------------------------------------------------------+
//| Position kholta hai - SL BROKER KO NAHI BHEJI JAATI (0 pass hota  |
//| hai), sirf TP1 broker-side jaata hai. SL EA khud monitor karta   |
//| hai CheckActiveSequence() me.                                     |
//+------------------------------------------------------------------+
void OpenReentryPosition()
  {
   string symbol = g_Sequence.symbol;

   long spreadPoints = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   if(spreadPoints > InpMaxSpreadPoints)
     {
      Print("[SKIP ATTEMPT] Spread zyada hai (", spreadPoints, " points), order nahi bheja - agla tick retry hoga.");
      return;
     }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double finalTP = NormalizeDouble(g_Sequence.tp1, digits);

   bool result;
   if(g_Sequence.isBuy)
      result = trade.Buy(g_Sequence.lot, symbol, 0, 0, finalTP, "");   // SL = 0 -> broker ko bilkul nahi bheja
   else
      result = trade.Sell(g_Sequence.lot, symbol, 0, 0, finalTP, "");

   if(result)
     {
      ulong dealTicket = trade.ResultDeal();
      ulong positionId = 0;
      if(dealTicket > 0 && HistoryDealSelect(dealTicket))
         positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(positionId == 0)
         positionId = trade.ResultOrder();

      g_Sequence.positionOpen = true;
      g_Sequence.currentTicket = positionId;
      g_Sequence.closeIntent = "NONE";

      Print("[SUCCESS] Order executed: ", (g_Sequence.isBuy ? "BUY" : "SELL"), " ", symbol,
            " Lot=", g_Sequence.lot, " SL=NONE(EA-monitored) TP1=", finalTP, " PositionID=", positionId);
     }
   else
      Print("[FAILED] Order FAILED: ", (g_Sequence.isBuy ? "BUY" : "SELL"), " ", symbol,
            " | GetLastError=", GetLastError(), " | RetCode=", trade.ResultRetcode(),
            " | RetCodeDescription=", trade.ResultRetcodeDescription(), " - agla tick retry hoga.");
  }

//+------------------------------------------------------------------+
void ScanSignalFolder()
  {
   string searchPath = InpSignalFolder + "\\*.txt";
   string fileName;
   long   searchHandle = FileFindFirst(searchPath, fileName);

   if(searchHandle == INVALID_HANDLE)
     {
      if(InpVerboseLogging && ScanCounter % 15 == 0)
         Print("[SCAN] Koi .txt file nahi mili folder me: ", searchPath);
      return;
     }

   int filesFound = 0;
   do
     {
      filesFound++;
      Print("[FOUND] File mili: ", fileName);

      if(StringFind(fileName, "CLOSE_") == 0)
         MoveToProcessed(fileName); // image-close logic nahi hai - ignore
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

   if(g_Sequence.active)
     {
      Print("[SEQUENCE ACTIVE] Ek sequence already chal rahi hai (", g_Sequence.symbol, "), naya signal ignore: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   string symbolRaw = JsonGetString(content, "symbol");
   string direction = JsonGetString(content, "direction");
   double entry = JsonGetDouble(content, "entry");
   double sl    = JsonGetDouble(content, "sl");   // sequence-kill switch reference
   double tp    = JsonGetDouble(content, "tp");   // exact TP1 - broker-side target

   Print("[PARSED] symbol=", symbolRaw, " direction=", direction, " entry=", entry, " sl(kill-switch)=", sl, " tp1(broker TP)=", tp);

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

   if(sl <= 0)
     {
      Print("[SKIP] SL signal me nahi mila - kill-switch ke liye zaroori hai. File: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   if(tp <= 0)
     {
      Print("[SKIP] TP1 signal me nahi mila. File: ", fileName);
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

   bool isBuy = (direction == "BUY");
   double currentPrice = isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);

   g_Sequence.active        = true;
   g_Sequence.symbol        = symbol;
   g_Sequence.isBuy         = isBuy;
   g_Sequence.entry         = entry;
   g_Sequence.signalSL      = sl;
   g_Sequence.tp1           = tp;
   g_Sequence.lot           = g_CurrentLot;
   g_Sequence.positionOpen  = false;
   g_Sequence.currentTicket = 0;
   g_Sequence.lastPrice     = currentPrice;
   g_Sequence.closeIntent   = "NONE";

   Print("[SEQUENCE STARTED] ", direction, " ", symbol, " | Entry=", entry, " | Signal-SL(kill, EA-monitored)=", sl,
         " | TP1(broker)=", tp, " | Reentry-exit distance=$", InpReentryDollars, " | Lot(fixed)=", g_Sequence.lot,
         " | Current price=", currentPrice);

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
