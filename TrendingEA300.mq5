//+------------------------------------------------------------------+
//|                                          SignalCopierEA_v2.mq5    |
//| Telegram -> MT5 Signal Copier (v6 - Dual-Leg Fixed-Lot System)    |
//| Har signal se DO positions banti hain:                            |
//|   LEG NEAR (0.1 lot) - nearer price par (BUY: bada, SELL: chota)  |
//|   LEG DEEP (0.3 lot) - deeper price par (BUY: chota, SELL: bada)  |
//| Dono ka SL broker ko NAHI jaata - EA khud monitor karta hai:      |
//|   - SHARED reentry-exit (deep price se $0.7 door) -> dono legs    |
//|     me se jo bhi khuli ho wo close, us leg ki reentry             |
//|   - SHARED kill-switch (deep se $5 aur door) -> DONO legs band    |
//| TP1 dono ke liye same, hamesha broker-side (signal ka exact TP1). |
//| Naya signal aaye toh purana poora sequence turant cancel hota hai.|
//+------------------------------------------------------------------+
#property copyright ""
#property version   "6.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//----------------- INPUTS -----------------
input string InpSignalFolder    = "Signals";   // MQL5\Files\ ke andar folder ka naam
input double InpLotNear         = 0.1;         // "Nearer" price wali leg ka fixed lot
input double InpLotDeep         = 0.3;         // "Deeper" price wali leg ka fixed lot
input int    InpSlippagePoints  = 20;          // Slippage (points)
input long   InpMagicNumber     = 20260708;    // Magic number
input string InpSymbolSuffix    = "";          // Broker symbol suffix, e.g. ".m" or "!"
input double InpReentryDollars  = 0.7;         // Har leg ka monitored exit - apne entry se itne $ door
input int    InpMaxSpreadPoints = 100;         // Is se zyada spread ho toh attempt skip (agla tick retry karega)
input int    InpPriceCheckMillis = 200;        // Price monitor kitni fast check ho (milliseconds)
input int    InpFolderScanSeconds = 2;         // Signal folder kitni der me scan ho (seconds)
input bool   InpVerboseLogging  = true;        // Detailed scan logs

string ProcessedFolder;
int    ScanCounter = 0;
int    g_FolderScanEveryNTicks = 10;
int    g_HeartbeatEveryNTicks = 150;
double g_LastProcessedDealTicket;
string g_LastDealGlobalVarName;

//----------------- TRADE LEG (ek position ka poora lifecycle) -----------------
struct TradeLeg
  {
   bool     legActive;      // is leg ka apna kaam complete ho chuka (TP hit ya kill) ya abhi chal raha hai
   double   entry;          // is leg ka fixed entry price
   double   lot;            // fixed lot (0.1 ya 0.3)
   bool     positionOpen;
   ulong    currentTicket;  // khuli position ka position ID
   double   lastPrice;      // entry touch detect karne ke liye
   string   closeIntent;    // "NONE" / "REENTRY_STOPOUT" / "COMBO_KILL" / "NEW_SIGNAL_CANCEL"
  };

//----------------- COMBO (dono legs + shared state) -----------------
bool    g_ComboActive = false;
string  g_Symbol;
bool    g_IsBuy;
double  g_KillSwitch;   // shared - dono legs isi par khatam
double  g_ReentryLevel; // shared - dono legs isi par reentry-exit karti hain
double  g_TP1;          // shared - dono ka broker TP

TradeLeg g_LegNear;
TradeLeg g_LegDeep;

//+------------------------------------------------------------------+
void EndLeg(TradeLeg &leg)
  {
   leg.legActive = false;
   leg.positionOpen = false;
   leg.currentTicket = 0;
   leg.closeIntent = "NONE";
  }

//+------------------------------------------------------------------+
void CheckComboCompletion()
  {
   if(!g_LegNear.legActive && !g_LegDeep.legActive)
     {
      g_ComboActive = false;
      Print("[COMBO END] ", g_Symbol, " - dono legs complete ho gayi, combo khatam.");
     }
  }

//+------------------------------------------------------------------+
//| Kisi bhi khuli leg ko turant close karta hai (naya signal aane   |
//| par, ya kill-switch lagne par) - closeIntent set karke.           |
//+------------------------------------------------------------------+
void CancelLeg(TradeLeg &leg, string intent)
  {
   if(!leg.legActive)
      return;

   if(leg.positionOpen && leg.currentTicket != 0)
     {
      leg.closeIntent = intent;
      if(!trade.PositionClose(leg.currentTicket))
        {
         Print("[ERROR] Leg close FAILED (ticket ", leg.currentTicket, "): ", GetLastError());
         leg.closeIntent = "NONE";
        }
      // Confirmation CheckClosedTrades() me hogi, wahi EndLeg() call karegi
     }
   else
     {
      // Position khuli hi nahi thi (wait state me thi) - seedha end kar do
      EndLeg(leg);
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   ProcessedFolder = InpSignalFolder + "\\Processed";
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   Print("=====================================================");
   Print("SignalCopierEA v6 (Dual-Leg Fixed-Lot System) starting up");
   Print("Watching folder (relative to MQL5\\Files\\): ", InpSignalFolder);
   Print("Processed folder: ", ProcessedFolder);
   Print("LotNear=", InpLotNear, " | LotDeep=", InpLotDeep, " | Magic=", InpMagicNumber, " | Suffix='", InpSymbolSuffix, "'");
   Print("Reentry exit (shared, deep price se): $", InpReentryDollars, " | Shared kill-switch/TP1: signal se milte hain");

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

   g_ComboActive = false;
   EndLeg(g_LegNear);
   EndLeg(g_LegDeep);

   if(!FileIsExist(InpSignalFolder))
      Print("WARNING: '", InpSignalFolder, "' folder abhi MQL5\\Files\\ ke andar nahi mil raha.");
   else
      Print("OK: Signal folder mil gaya.");

   g_FolderScanEveryNTicks = (int)MathMax(1, MathRound((InpFolderScanSeconds * 1000.0) / InpPriceCheckMillis));
   g_HeartbeatEveryNTicks  = (int)MathMax(1, MathRound(30000.0 / InpPriceCheckMillis));

   EventSetMillisecondTimer(InpPriceCheckMillis);
   Print("Fast timer set: har ", InpPriceCheckMillis, "ms price monitor hoga. Folder scan har ~", InpFolderScanSeconds, " sec.");
   Print("=====================================================");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Print("SignalCopierEA v6 stopped. Reason code: ", reason);
  }

//+------------------------------------------------------------------+
//| Trade history poll karta hai - dekh ta hai deal kis leg (NEAR ya |
//| DEEP) ki hai, aur uske closeIntent ke hisaab se decide karta hai  |
//+------------------------------------------------------------------+
void ProcessLegDeal(TradeLeg &leg, string legName, ulong dTicket, long dealReason, double profit)
  {
   if(dealReason == DEAL_REASON_TP)
     {
      Print("[LEG RESOLVED] ", legName, " - TP1 hit (deal #", dTicket, " profit=", profit, "). Ye leg complete.");
      EndLeg(leg);
      CheckComboCompletion();
      return;
     }

   if(leg.closeIntent == "REENTRY_STOPOUT")
     {
      Print("[REENTRY] ", legName, " - EA-monitored $", InpReentryDollars, " exit (deal #", dTicket, " profit=", profit,
            "). Wapas entry (", leg.entry, ") ke liye wait kar rahe hain.");
      leg.positionOpen = false;
      leg.currentTicket = 0;
      leg.closeIntent = "NONE";
      leg.lastPrice = g_IsBuy ? SymbolInfoDouble(g_Symbol, SYMBOL_ASK) : SymbolInfoDouble(g_Symbol, SYMBOL_BID);
     }
   else if(leg.closeIntent == "COMBO_KILL")
     {
      Print("[LEG RESOLVED] ", legName, " - kill-switch close confirm hua (deal #", dTicket, " profit=", profit, ").");
      EndLeg(leg);
      CheckComboCompletion();
     }
   else if(leg.closeIntent == "NEW_SIGNAL_CANCEL")
     {
      Print("[LEG CANCELLED] ", legName, " - naye signal ki wajah se cancel hui (deal #", dTicket, " profit=", profit, ").");
      EndLeg(leg);
      CheckComboCompletion();
     }
   else
     {
      // Unexpected/manual close - reentry jaisa treat hota hai, loop continue
      Print("[REENTRY] ", legName, " - unexpected/manual close (deal #", dTicket, " profit=", profit, " reason=", dealReason,
            "). Sequence continue, wapas entry (", leg.entry, ") ke liye wait kar rahe hain.");
      leg.positionOpen = false;
      leg.currentTicket = 0;
      leg.closeIntent = "NONE";
      leg.lastPrice = g_IsBuy ? SymbolInfoDouble(g_Symbol, SYMBOL_ASK) : SymbolInfoDouble(g_Symbol, SYMBOL_BID);
     }
  }

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

      if(g_LegNear.positionOpen && (ulong)positionId == g_LegNear.currentTicket)
         ProcessLegDeal(g_LegNear, "LEG-NEAR", dTicket, dealReason, profit);
      else if(g_LegDeep.positionOpen && (ulong)positionId == g_LegDeep.currentTicket)
         ProcessLegDeal(g_LegDeep, "LEG-DEEP", dTicket, dealReason, profit);
      else
         Print("[INFO] Stray deal #", dTicket, " (koi active leg se match nahi hui) profit=", profit, " - ignore.");
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
   if(InpVerboseLogging && ScanCounter % g_HeartbeatEveryNTicks == 0)
      Print("[HEARTBEAT] scan #", ScanCounter, " | Combo active: ", (g_ComboActive ? "YES" : "NO"));

   CheckClosedTrades();
   CheckActiveCombo();

   if(ScanCounter % g_FolderScanEveryNTicks == 0)
      ScanSignalFolder();
  }

//+------------------------------------------------------------------+
//| Har tick: pehle shared kill-switch check (dono legs ko affect     |
//| karta hai), fir har leg ka apna reentry-exit / entry-touch check  |
//+------------------------------------------------------------------+
void CheckActiveCombo()
  {
   if(!g_ComboActive)
      return;

   if(!SymbolSelect(g_Symbol, true))
      return;

   double currentPrice = g_IsBuy ? SymbolInfoDouble(g_Symbol, SYMBOL_ASK) : SymbolInfoDouble(g_Symbol, SYMBOL_BID);

   // SHARED KILL-SWITCH - dono legs ko ek saath khatam karta hai
   bool killed = g_IsBuy ? (currentPrice <= g_KillSwitch) : (currentPrice >= g_KillSwitch);
   if(killed)
     {
      Print("[COMBO KILLED] ", (g_IsBuy ? "BUY" : "SELL"), " ", g_Symbol,
            " - price (", currentPrice, ") kill-switch (", g_KillSwitch, ") tak pahunch gayi. Dono legs band kar rahe hain.");
      if(g_LegNear.legActive)
         CancelLeg(g_LegNear, "COMBO_KILL");
      if(g_LegDeep.legActive)
         CancelLeg(g_LegDeep, "COMBO_KILL");
      CheckComboCompletion();
      return;
     }

   // Har leg apna monitoring
   CheckOneLeg(g_LegNear, "LEG-NEAR");
   CheckOneLeg(g_LegDeep, "LEG-DEEP");
  }

//+------------------------------------------------------------------+
void CheckOneLeg(TradeLeg &leg, string legName)
  {
   if(!leg.legActive)
      return;

   double currentPrice = g_IsBuy ? SymbolInfoDouble(g_Symbol, SYMBOL_ASK) : SymbolInfoDouble(g_Symbol, SYMBOL_BID);

   if(leg.positionOpen)
     {
      bool reentryBreach = g_IsBuy ? (currentPrice <= g_ReentryLevel) : (currentPrice >= g_ReentryLevel);

      if(reentryBreach)
        {
         Print("[REENTRY EXIT] ", legName, " ", g_Symbol, " - price (", currentPrice, ") shared reentry-level (",
               g_ReentryLevel, ") tak pahunch gayi. Close kar rahe hain (reentry hogi).");
         CancelLeg(leg, "REENTRY_STOPOUT");
        }
      return;
     }

   // Wait state - entry touch check (crossing-based)
   double point = SymbolInfoDouble(g_Symbol, SYMBOL_POINT);
   double diffPrev = leg.lastPrice - leg.entry;
   double diffNow  = currentPrice - leg.entry;

   bool triggered = false;
   if(MathAbs(diffNow) <= point * 2)
      triggered = true;
   else if(diffPrev == 0)
      triggered = true;
   else if((diffPrev > 0 && diffNow < 0) || (diffPrev < 0 && diffNow > 0))
      triggered = true;

   leg.lastPrice = currentPrice;

   if(triggered)
     {
      Print("[ENTRY TRIGGER] ", legName, " ", g_Symbol, " - price entry (", leg.entry, ") tak pahunch gayi. Current=",
            currentPrice, ". Order fire ho raha hai.");
      OpenLegPosition(leg, legName);
     }
  }

//+------------------------------------------------------------------+
//| Position kholta hai - SL BROKER KO NAHI jaata (EA khud monitor    |
//| karta hai), sirf TP1 (shared) broker-side jaata hai.               |
//+------------------------------------------------------------------+
void OpenLegPosition(TradeLeg &leg, string legName)
  {
   long spreadPoints = SymbolInfoInteger(g_Symbol, SYMBOL_SPREAD);
   if(spreadPoints > InpMaxSpreadPoints)
     {
      Print("[SKIP ATTEMPT] ", legName, " - Spread zyada hai (", spreadPoints, " points), order nahi bheja - agla tick retry hoga.");
      return;
     }

   int digits = (int)SymbolInfoInteger(g_Symbol, SYMBOL_DIGITS);
   double finalTP = NormalizeDouble(g_TP1, digits);

   bool result;
   if(g_IsBuy)
      result = trade.Buy(leg.lot, g_Symbol, 0, 0, finalTP, "");
   else
      result = trade.Sell(leg.lot, g_Symbol, 0, 0, finalTP, "");

   if(result)
     {
      ulong dealTicket = trade.ResultDeal();
      ulong positionId = 0;
      if(dealTicket > 0 && HistoryDealSelect(dealTicket))
         positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(positionId == 0)
         positionId = trade.ResultOrder();

      leg.positionOpen = true;
      leg.currentTicket = positionId;
      leg.closeIntent = "NONE";

      Print("[SUCCESS] ", legName, " order executed: ", (g_IsBuy ? "BUY" : "SELL"), " ", g_Symbol,
            " Lot=", leg.lot, " Entry~", leg.entry, " SL=NONE(EA-monitored) TP1=", finalTP, " PositionID=", positionId);
     }
   else
      Print("[FAILED] ", legName, " order FAILED: ", (g_IsBuy ? "BUY" : "SELL"), " ", g_Symbol,
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

   string symbolRaw   = JsonGetString(content, "symbol");
   string direction   = JsonGetString(content, "direction");
   double entryDeep   = JsonGetDouble(content, "entry_deep");
   double entryNear   = JsonGetDouble(content, "entry_near");
   double killSwitch  = JsonGetDouble(content, "kill_switch");
   double tp          = JsonGetDouble(content, "tp");

   Print("[PARSED] symbol=", symbolRaw, " direction=", direction, " entry_deep=", entryDeep,
         " entry_near=", entryNear, " kill_switch=", killSwitch, " tp1=", tp);

   if(symbolRaw == "" || direction == "")
     {
      Print("[SKIP] Invalid signal (symbol/direction missing), file: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   if(entryDeep <= 0 || entryNear <= 0)
     {
      Print("[SKIP] Entry prices signal me nahi mili. File: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   if(killSwitch <= 0)
     {
      Print("[SKIP] Kill-switch calculate nahi ho paya. File: ", fileName);
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

   // NAYA SIGNAL AAYA - agar purana combo active hai, turant cancel karo
   if(g_ComboActive)
     {
      Print("[NEW SIGNAL] Purana combo (", g_Symbol, ") cancel kar rahe hain, naya signal shuru ho raha hai.");
      if(g_LegNear.legActive)
         CancelLeg(g_LegNear, "NEW_SIGNAL_CANCEL");
      if(g_LegDeep.legActive)
         CancelLeg(g_LegDeep, "NEW_SIGNAL_CANCEL");
      g_ComboActive = false;
     }

   bool isBuy = (direction == "BUY");
   double currentPrice = isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);

   g_Symbol     = symbol;
   g_IsBuy      = isBuy;
   g_KillSwitch = killSwitch;
   g_ReentryLevel = isBuy ? entryDeep - InpReentryDollars : entryDeep + InpReentryDollars;
   g_TP1        = tp;
   g_ComboActive = true;

   g_LegNear.legActive     = true;
   g_LegNear.entry         = entryNear;
   g_LegNear.lot           = InpLotNear;
   g_LegNear.positionOpen  = false;
   g_LegNear.currentTicket = 0;
   g_LegNear.lastPrice     = currentPrice;
   g_LegNear.closeIntent   = "NONE";

   g_LegDeep.legActive     = true;
   g_LegDeep.entry         = entryDeep;
   g_LegDeep.lot           = InpLotDeep;
   g_LegDeep.positionOpen  = false;
   g_LegDeep.currentTicket = 0;
   g_LegDeep.lastPrice     = currentPrice;
   g_LegDeep.closeIntent   = "NONE";

   Print("[COMBO STARTED] ", direction, " ", symbol, " | LegNear: entry=", entryNear, " lot=", InpLotNear,
         " | LegDeep: entry=", entryDeep, " lot=", InpLotDeep, " | KillSwitch=", killSwitch,
         " | SharedReentryLevel=", g_ReentryLevel, " | TP1=", tp, " | Current price=", currentPrice);

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
