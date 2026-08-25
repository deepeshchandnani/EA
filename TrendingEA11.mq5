//+------------------------------------------------------------------+
//|                                          SignalCopierEA_v2.mq5    |
//| Telegram -> MT5 Signal Copier (v2 - Reentry Sequence System)      |
//| Har signal ek "Trade Sequence" banata hai: entry price par bar-bar|
//| reentry hoti hai (1-pip SL ke saath) jab tak TP hit na ho jaye,   |
//| ya price signal ke SL tak na pahunch jaye, ya Telegram par image  |
//| na aa jaye. Har step detailed log karta hai (Experts tab).       |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//----------------- INPUTS -----------------
input string InpSignalFolder   = "Signals";   // MQL5\Files\ ke andar folder ka naam
input double InpLotSize        = 0.20;        // Base lot size (martingale isi se start hota hai)
input double InpMartingaleMultiplier = 2.0;   // Signal-SL breach (poora sequence fail) par lot isse multiply hoga (uncapped)
input int    InpSlippagePoints = 20;          // Slippage (points)
input long   InpMagicNumber    = 20260708;    // Magic number
input string InpSymbolSuffix   = "";          // Broker symbol suffix, e.g. ".m" or "!"
input double InpFixedSLDollars = 1.0;         // Har reentry attempt ka SL - entry se itne $ door (1 pip = $1 maan kar)
input int    InpMaxSpreadPoints= 100;         // Is se zyada spread ho toh attempt skip (agla tick retry karega)
input int    InpPollSeconds    = 2;           // Folder/price check interval (seconds)
input bool   InpOneTradePerDay = true;        // True = din ka sirf ek sequence (signal) chalega, baaki us din ignore
input bool   InpVerboseLogging = true;        // Detailed scan logs

string ProcessedFolder;
int    ScanCounter = 0;
double g_CurrentLot;
string g_LotGlobalVarName;
double g_LastProcessedDealTicket;
string g_LastDealGlobalVarName;
double g_LastTradeDay;
string g_LastTradeDayGlobalVarName;

//----------------- TRADE SEQUENCE -----------------
// Ek signal aane par ek "sequence" shuru hoti hai. Us sequence ke andar
// EA bar-bar entry price par reentry try karta hai (tight $1 SL ke saath)
// jab tak in me se koi ek na ho:
//   1. TP hit ho jaye              -> sequence SUCCESS, martingale WIN
//   2. Price signal ke SL tak pahunche -> sequence FAIL, martingale LOSS
//   3. Telegram par image aaye      -> sequence turant band (manual close)
struct TradeSequence
  {
   bool     active;         // sequence chal rahi hai ya nahi
   string   symbol;
   bool     isBuy;
   double   entry;          // fixed entry price (kabhi change nahi hoti reentries ke beech)
   double   signalSL;       // signal ka diya hua SL - sirf "kill switch" reference ke liye
   double   tp;             // exact TP1 price (signal se, koi default nahi)
   double   lot;            // is poore sequence ke liye fixed lot (reentries ke beech change nahi hoti)
   bool     positionOpen;   // abhi koi position khuli hai kya
   ulong    currentTicket;  // khuli position ka ticket (position ID)
   double   lastPrice;      // pichhli tick ka price (crossing detect karne ke liye)
  };

TradeSequence g_Sequence;

//+------------------------------------------------------------------+
//| ONE TRADE PER DAY LOGIC                                          |
//+------------------------------------------------------------------+
double TodayAsInt()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (double)(dt.year * 10000 + dt.mon * 100 + dt.day);
  }

bool AlreadyTradedToday()
  {
   if(!InpOneTradePerDay)
      return false;
   return (g_LastTradeDay == TodayAsInt());
  }

void MarkTradedToday()
  {
   if(!InpOneTradePerDay)
      return;
   g_LastTradeDay = TodayAsInt();
   GlobalVariableSet(g_LastTradeDayGlobalVarName, g_LastTradeDay);
   Print("[DAILY LIMIT] Aaj (", g_LastTradeDay, ") ka signal accept ho gaya. Ab kal tak koi naya signal nahi lega.");
  }

//+------------------------------------------------------------------+
//| MARTINGALE - sirf tab call hota hai jab POORA sequence resolve   |
//| ho (TP hit ya signal-SL breach ya image-close) - reentry ke      |
//| individual 1-pip stopouts is se BILKUL touch nahi karte.         |
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
   Print("[SEQUENCE END] ", g_Sequence.symbol, " sequence complete ho gaya.");
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   ProcessedFolder = InpSignalFolder + "\\Processed";
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   Print("=====================================================");
   Print("SignalCopierEA v3 (Reentry Sequence System) starting up");
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
   Print("Reentry SL per attempt: $", InpFixedSLDollars, " | TP: hamesha signal ke exact TP1 se");

   g_LastTradeDayGlobalVarName = "TGSignalCopier_LastTradeDay_" + (string)InpMagicNumber;
   if(GlobalVariableCheck(g_LastTradeDayGlobalVarName))
     {
      g_LastTradeDay = GlobalVariableGet(g_LastTradeDayGlobalVarName);
      Print("Last trade day restore hua: ", g_LastTradeDay, " | One trade per day: ", (InpOneTradePerDay ? "ENABLED" : "DISABLED"));
     }
   else
     {
      g_LastTradeDay = 0;
      Print("Last trade day: koi record nahi (fresh start) | One trade per day: ", (InpOneTradePerDay ? "ENABLED" : "DISABLED"));
     }

   g_Sequence.active = false;
   g_Sequence.positionOpen = false;
   g_Sequence.currentTicket = 0;

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
   Print("SignalCopierEA v3 stopped. Reason code: ", reason);
  }

//+------------------------------------------------------------------+
//| Trade history poll karta hai. Sequence se related closing deal   |
//| ko sequence logic handle karta hai (reentry ya conclusion),      |
//| baaki koi stray matching-magic deal ho toh legacy fallback.      |
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
         if(dealReason == DEAL_REASON_SL)
           {
            // 1-pip reentry stopout - martingale ko BILKUL touch mat karo, wapas wait state me jao
            Print("[REENTRY] Stop-out (1-pip SL) deal #", dTicket, " profit=", profit,
                  " - martingale untouched. Wapas entry (", g_Sequence.entry, ") ke liye wait kar rahe hain.");
            g_Sequence.positionOpen = false;
            g_Sequence.currentTicket = 0;
            g_Sequence.lastPrice = g_Sequence.isBuy ? SymbolInfoDouble(g_Sequence.symbol, SYMBOL_ASK)
                                                     : SymbolInfoDouble(g_Sequence.symbol, SYMBOL_BID);
           }
         else
           {
            // TP hit, ya manual/image close (DEAL_REASON_CLIENT), ya koi aur - sequence conclude hoti hai
            bool isWin = (profit >= 0);
            Print("[SEQUENCE RESOLVED] Deal #", dTicket, " profit=", profit, " reason=", dealReason);
            ApplyMartingaleResult(isWin, isWin ? "TP hit / manual close in profit" : "closed in loss");
            EndSequence();
           }
        }
      else
        {
         // Legacy/stray deal jo current sequence se match nahi hui - safety fallback
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
//| Active sequence ke liye har tick check karta hai:                |
//|  1. Kill switch - price signal SL tak pahunchi?                  |
//|  2. Entry touch - price entry tak pahunchi (reentry ke liye)?    |
//+------------------------------------------------------------------+
void CheckActiveSequence()
  {
   if(!g_Sequence.active)
      return;

   if(g_Sequence.positionOpen)
      return; // position already khuli hai, close hone ka wait karo (CheckClosedTrades handle karega)

   string symbol = g_Sequence.symbol;
   if(!SymbolSelect(symbol, true))
      return;

   double currentPrice = g_Sequence.isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);

   // 1. KILL SWITCH check - agar signal ka SL diya hua tha
   if(g_Sequence.signalSL > 0)
     {
      bool killed = g_Sequence.isBuy ? (currentPrice <= g_Sequence.signalSL) : (currentPrice >= g_Sequence.signalSL);
      if(killed)
        {
         Print("[SEQUENCE KILLED] ", (g_Sequence.isBuy ? "BUY" : "SELL"), " ", symbol,
               " - price (", currentPrice, ") signal ke SL (", g_Sequence.signalSL, ") tak pahunch gayi. Reentry band.");
         ApplyMartingaleResult(false, "signal SL breach - poora sequence fail");
         EndSequence();
         return;
        }
     }

   // 2. ENTRY TOUCH check (crossing-based, taaki koi tick miss na ho)
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
      Print("[REENTRY TRIGGER] ", (g_Sequence.isBuy ? "BUY" : "SELL"), " ", symbol,
            " - price entry (", g_Sequence.entry, ") tak pahunch gayi. Current=", currentPrice, ". Order fire ho raha hai.");
      OpenSequencePosition();
     }
  }

//+------------------------------------------------------------------+
//| Sequence ke liye ek market order kholta hai - SL entry se fixed  |
//| $ distance par, TP sequence ka exact target                      |
//+------------------------------------------------------------------+
void OpenSequencePosition()
  {
   string symbol = g_Sequence.symbol;

   long spreadPoints = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   if(spreadPoints > InpMaxSpreadPoints)
     {
      Print("[SKIP ATTEMPT] Spread zyada hai (", spreadPoints, " points), is tick pe order nahi bhejenge - agla tick retry hoga.");
      return;
     }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double entry = g_Sequence.entry;
   double finalSL = g_Sequence.isBuy ? entry - InpFixedSLDollars : entry + InpFixedSLDollars;
   double finalTP = g_Sequence.tp;

   finalSL = NormalizeDouble(finalSL, digits);
   finalTP = NormalizeDouble(finalTP, digits);

   bool result;
   if(g_Sequence.isBuy)
      result = trade.Buy(g_Sequence.lot, symbol, 0, finalSL, finalTP, "EMA movement detected!");
   else
      result = trade.Sell(g_Sequence.lot, symbol, 0, finalSL, finalTP, "EMA movement detected!");

   if(result)
     {
      ulong dealTicket = trade.ResultDeal();
      ulong positionId = 0;
      if(dealTicket > 0 && HistoryDealSelect(dealTicket))
         positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(positionId == 0)
         positionId = trade.ResultOrder(); // fallback

      g_Sequence.positionOpen = true;
      g_Sequence.currentTicket = positionId;

      Print("[SUCCESS] Reentry order executed: ", (g_Sequence.isBuy ? "BUY" : "SELL"), " ", symbol,
            " Lot=", g_Sequence.lot, " SL=", finalSL, " TP=", finalTP, " PositionID=", positionId);
     }
   else
      Print("[FAILED] Reentry order FAILED: ", (g_Sequence.isBuy ? "BUY" : "SELL"), " ", symbol,
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
         ProcessCloseSignal(fileName);
      else
         ProcessSignalFile(fileName);
     }
   while(FileFindNext(searchHandle, fileName));

   FileFindClose(searchHandle);

   if(filesFound > 0)
      Print("[SCAN] Is round me total ", filesFound, " file(s) process hui.");
  }

//+------------------------------------------------------------------+
//| Telegram par image aane par Python isi tarah ki file banata hai  |
//| (naam "CLOSE_..." se shuru hota hai) - EA isse dekhte hi active  |
//| sequence ko turant band kar deta hai.                            |
//+------------------------------------------------------------------+
void ProcessCloseSignal(string fileName)
  {
   Print("[IMAGE CLOSE] Telegram par image mili - active trade/sequence band kar rahe hain.");

   if(!g_Sequence.active)
     {
      Print("[IMAGE CLOSE] Koi active sequence nahi thi, kuch nahi karna.");
      MoveToProcessed(fileName);
      return;
     }

   if(g_Sequence.positionOpen && g_Sequence.currentTicket != 0)
     {
      if(PositionSelectByTicket(g_Sequence.currentTicket))
        {
         if(trade.PositionClose(g_Sequence.currentTicket))
            Print("[IMAGE CLOSE] Position #", g_Sequence.currentTicket, " close kar diya. Result martingale me agle CheckClosedTrades scan me count hoga.");
         else
            Print("[IMAGE CLOSE] Position close karne me FAILED. Error: ", GetLastError());
        }
      else
        {
         Print("[IMAGE CLOSE] Position ticket select nahi hui (shayad already close ho chuki thi).");
         EndSequence();
        }
      // Note: sequence yahi khatam nahi kar rahe agar position abhi close ki - CheckClosedTrades
      // agle scan me deal dekh kar khud EndSequence() + martingale apply kar dega (DEAL_REASON_CLIENT se)
     }
   else
     {
      Print("[IMAGE CLOSE] Koi open position nahi thi (reentry wait state me thi) - sequence cancel, martingale untouched.");
      EndSequence();
     }

   MoveToProcessed(fileName);
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

   if(AlreadyTradedToday())
     {
      Print("[DAILY LIMIT] Aaj (", TodayAsInt(), ") ka signal already accept ho chuka hai, ignore: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   if(g_Sequence.active)
     {
      Print("[SEQUENCE ACTIVE] Ek sequence already chal rahi hai (", g_Sequence.symbol, "), naya signal ignore: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   string symbolRaw = JsonGetString(content, "symbol");
   string direction = JsonGetString(content, "direction");
   double entry = JsonGetDouble(content, "entry");
   double sl    = JsonGetDouble(content, "sl");   // ab sirf "kill switch" reference ke liye
   double tp    = JsonGetDouble(content, "tp");   // exact TP1 - REQUIRED, koi default nahi

   Print("[PARSED] symbol=", symbolRaw, " direction=", direction, " entry=", entry, " sl(kill-switch)=", sl, " tp(exact)=", tp);

   if(symbolRaw == "" || direction == "")
     {
      Print("[SKIP] Invalid signal (symbol/direction missing), file: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   if(entry <= 0)
     {
      Print("[SKIP] Entry price signal me nahi mili - is system me entry zaroori hai (reentry isi price par hoti hai). File: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   if(tp <= 0)
     {
      Print("[SKIP] TP1 signal me nahi mila - koi default TP nahi hai is system me, trade skip. File: ", fileName);
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

   // Naya sequence shuru karo
   g_Sequence.active        = true;
   g_Sequence.symbol        = symbol;
   g_Sequence.isBuy         = isBuy;
   g_Sequence.entry         = entry;
   g_Sequence.signalSL      = sl;
   g_Sequence.tp            = tp;
   g_Sequence.lot           = g_CurrentLot; // is poore sequence ke liye fixed rahegi
   g_Sequence.positionOpen  = false;
   g_Sequence.currentTicket = 0;
   g_Sequence.lastPrice     = currentPrice;

   MarkTradedToday();

   Print("[SEQUENCE STARTED] ", direction, " ", symbol, " | Entry=", entry, " | Signal-SL(kill)=", sl,
         " | TP(exact)=", tp, " | Lot(fixed)=", g_Sequence.lot, " | Current price=", currentPrice);

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
