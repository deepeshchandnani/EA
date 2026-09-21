//+------------------------------------------------------------------+
//|                                          SignalCopierEA_v2.mq5    |
//| Telegram -> MT5 Signal Copier (v7 - Simple: Real Broker SL/TP)    |
//| Loop/reentry/kill-switch/dual-leg SAB hata diya gaya hai. Ab bas: |
//|   Entry (signal se) -> SL (signal ka asli SL, broker-side)        |
//|   -> TP (signal ka exact TP1, broker-side)                        |
//| Martingale wapas: loss par lot double, win par lot reset.         |
//| Naya signal aaye toh purana (agar abhi khuli/wait me hai) cancel  |
//| hoke naya shuru hota hai.                                         |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "7.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//----------------- INPUTS -----------------
input string InpSignalFolder    = "Signals";   // MQL5\Files\ ke andar folder ka naam
input double InpLotSize         = 0.10;        // Base lot size (martingale isi se start hota hai)
input double InpMartingaleMultiplier = 2.0;    // Loss ke baad lot isse multiply hoga (uncapped)
input int    InpSlippagePoints  = 20;          // Slippage (points)
input long   InpMagicNumber     = 20260708;    // Magic number
input string InpSymbolSuffix    = "";          // Broker symbol suffix, e.g. ".m" or "!"
input int    InpMaxSpreadPoints = 100;         // Is se zyada spread ho toh attempt skip (agla tick retry karega)
input int    InpPriceCheckMillis = 200;        // Entry-touch monitor kitni fast check ho (milliseconds)
input int    InpFolderScanSeconds = 2;         // Signal folder kitni der me scan ho (seconds)
input bool   InpVerboseLogging  = true;        // Detailed scan logs

string ProcessedFolder;
int    ScanCounter = 0;
int    g_FolderScanEveryNTicks = 10;
int    g_HeartbeatEveryNTicks = 150;
double g_CurrentLot;
string g_LotGlobalVarName;
double g_LastProcessedDealTicket;
string g_LastDealGlobalVarName;

//----------------- TRADE SEQUENCE (simple, single leg) -----------------
struct TradeSequence
  {
   bool     active;
   string   symbol;
   bool     isBuy;
   double   entry;
   double   sl;             // asli signal ka SL - broker ko jata hai
   double   tp;              // exact TP1 - broker ko jata hai
   double   lot;             // is sequence ke liye fixed (martingale se locked)
   bool     positionOpen;
   ulong    currentTicket;
   double   lastPrice;       // entry touch detect karne ke liye
  };

TradeSequence g_Sequence;

//+------------------------------------------------------------------+
//| MARTINGALE                                                       |
//+------------------------------------------------------------------+
void ApplyMartingaleResult(bool isWin, string reasonNote)
  {
   double previousLot = g_CurrentLot;

   if(isWin)
     {
      g_CurrentLot = InpLotSize;
      Print("[MARTINGALE] WIN (", reasonNote, "). Lot size reset: ", previousLot, " -> ", g_CurrentLot);
     }
   else
     {
      g_CurrentLot = g_CurrentLot * InpMartingaleMultiplier;
      Print("[MARTINGALE] LOSS (", reasonNote, "). Lot size ", previousLot, " -> ", g_CurrentLot,
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
//| Agar sequence abhi active hai (khuli ya wait state me), turant   |
//| cancel karta hai - naya signal aane par ya manual reset ke liye  |
//+------------------------------------------------------------------+
void CancelActiveSequence(string reason)
  {
   if(!g_Sequence.active)
      return;

   if(g_Sequence.positionOpen && g_Sequence.currentTicket != 0)
     {
      if(PositionSelectByTicket(g_Sequence.currentTicket))
        {
         if(trade.PositionClose(g_Sequence.currentTicket))
            Print("[CANCEL] Purani position close ki (", reason, "), ticket=", g_Sequence.currentTicket);
         else
            Print("[ERROR] Purani position close FAILED: ", GetLastError());
        }
     }
   else
      Print("[CANCEL] Purana sequence (wait state me tha) cancel kiya (", reason, ").");

   EndSequence();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   ProcessedFolder = InpSignalFolder + "\\Processed";
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   Print("=====================================================");
   Print("SignalCopierEA v7 (Simple - Real Broker SL/TP + Martingale) starting up");
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
   Print("SL/TP dono broker-side hain (signal ke exact values). Koi loop/reentry/kill-switch nahi hai.");

   g_Sequence.active = false;
   g_Sequence.positionOpen = false;
   g_Sequence.currentTicket = 0;

   if(!FileIsExist(InpSignalFolder))
      Print("WARNING: '", InpSignalFolder, "' folder abhi MQL5\\Files\\ ke andar nahi mil raha.");
   else
      Print("OK: Signal folder mil gaya.");

   g_FolderScanEveryNTicks = (int)MathMax(1, MathRound((InpFolderScanSeconds * 1000.0) / InpPriceCheckMillis));
   g_HeartbeatEveryNTicks  = (int)MathMax(1, MathRound(30000.0 / InpPriceCheckMillis));

   EventSetMillisecondTimer(InpPriceCheckMillis);
   Print("Fast timer set: har ", InpPriceCheckMillis, "ms entry-touch monitor hoga. Folder scan har ~", InpFolderScanSeconds, " sec.");
   Print("=====================================================");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Print("SignalCopierEA v7 stopped. Reason code: ", reason);
  }

//+------------------------------------------------------------------+
//| Trade history poll karta hai - asli broker SL/TP hi decide karta  |
//| hai win/loss (DEAL_REASON_TP = win, baaki sab profit-sign se)     |
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
         bool isWin = (profit >= 0);
         string reasonTxt = (dealReason == DEAL_REASON_TP) ? "TP hit" :
                             (dealReason == DEAL_REASON_SL) ? "SL hit" : "manual/other close";
         Print("[SEQUENCE RESOLVED] Deal #", dTicket, " profit=", profit, " reason=", reasonTxt);
         ApplyMartingaleResult(isWin, reasonTxt);
         EndSequence();
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
   if(InpVerboseLogging && ScanCounter % g_HeartbeatEveryNTicks == 0)
      Print("[HEARTBEAT] scan #", ScanCounter, " | Sequence active: ", (g_Sequence.active ? "YES" : "NO"));

   CheckClosedTrades();
   CheckActiveSequence();

   if(ScanCounter % g_FolderScanEveryNTicks == 0)
      ScanSignalFolder();
  }

//+------------------------------------------------------------------+
//| Entry-touch ka wait karta hai (agar position abhi khuli nahi hai)|
//+------------------------------------------------------------------+
void CheckActiveSequence()
  {
   if(!g_Sequence.active || g_Sequence.positionOpen)
      return;

   string symbol = g_Sequence.symbol;
   if(!SymbolSelect(symbol, true))
      return;

   double currentPrice = g_Sequence.isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
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
      OpenSequencePosition();
     }
  }

//+------------------------------------------------------------------+
//| Position kholta hai - SL/TP DONO broker-side (signal ke exact    |
//| values), koi monitoring/loop nahi.                                |
//+------------------------------------------------------------------+
void OpenSequencePosition()
  {
   string symbol = g_Sequence.symbol;

   long spreadPoints = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   if(spreadPoints > InpMaxSpreadPoints)
     {
      Print("[SKIP ATTEMPT] Spread zyada hai (", spreadPoints, " points), order nahi bheja - agla tick retry hoga.");
      return;
     }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double finalSL = NormalizeDouble(g_Sequence.sl, digits);
   double finalTP = NormalizeDouble(g_Sequence.tp, digits);

   bool result;
   if(g_Sequence.isBuy)
      result = trade.Buy(g_Sequence.lot, symbol, 0, finalSL, finalTP, "");
   else
      result = trade.Sell(g_Sequence.lot, symbol, 0, finalSL, finalTP, "");

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

      Print("[SUCCESS] Order executed: ", (g_Sequence.isBuy ? "BUY" : "SELL"), " ", symbol,
            " Lot=", g_Sequence.lot, " SL=", finalSL, " TP=", finalTP, " PositionID=", positionId);
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

   string symbolRaw = JsonGetString(content, "symbol");
   string direction = JsonGetString(content, "direction");
   double entry = JsonGetDouble(content, "entry");
   double sl    = JsonGetDouble(content, "sl");   // asli signal ka SL - broker ko jayega
   double tp    = JsonGetDouble(content, "tp");   // exact TP1 - broker ko jayega

   Print("[PARSED] symbol=", symbolRaw, " direction=", direction, " entry=", entry, " sl=", sl, " tp1=", tp);

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
      Print("[SKIP] SL signal me nahi mila - is system me SL zaroori hai (broker ko jaata hai). File: ", fileName);
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

   // Naya signal aaya - agar purana sequence active hai, cancel karo
   if(g_Sequence.active)
      CancelActiveSequence("naya signal aaya");

   bool isBuy = (direction == "BUY");
   double currentPrice = isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);

   g_Sequence.active        = true;
   g_Sequence.symbol        = symbol;
   g_Sequence.isBuy         = isBuy;
   g_Sequence.entry         = entry;
   g_Sequence.sl            = sl;
   g_Sequence.tp            = tp;
   g_Sequence.lot           = g_CurrentLot;
   g_Sequence.positionOpen  = false;
   g_Sequence.currentTicket = 0;
   g_Sequence.lastPrice     = currentPrice;

   Print("[SEQUENCE STARTED] ", direction, " ", symbol, " | Entry=", entry, " | SL=", sl, " | TP1=", tp,
         " | Lot(fixed)=", g_Sequence.lot, " | Current price=", currentPrice);

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
