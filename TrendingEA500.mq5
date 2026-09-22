//+------------------------------------------------------------------+
//|                                          SignalCopierEA_v2.mq5    |
//| Telegram -> MT5 Signal Copier (v8 - Clean Logging + Close-All)    |
//| Entry (signal se) -> SL (signal ka asli SL, broker-side)          |
//| -> TP (signal ka exact TP1, broker-side). Martingale: loss par    |
//| lot double, win par lot reset. Naya signal purana cancel karta    |
//| hai. "TP1 CLEAR" Telegram message aane par saari positions close  |
//| ho jaati hain. Logging minimal - sirf entry/SL/TP/martingale.     |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "8.00"
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

string ProcessedFolder;
int    ScanCounter = 0;
int    g_FolderScanEveryNTicks = 10;
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

//----------------- MARTINGALE LEDGER -----------------
// Independent tracking - koi bhi position jo humne kabhi open ki, uska ticket yahan
// pending rehta hai jab tak uska closing deal na mil jaye. Ye g_Sequence se ALAG hai
// isliye agar naya signal aane se purani sequence cancel/overwrite ho jaye, tab bhi
// purani position ka martingale result MISS nahi hota.
ulong g_PendingTickets[];

//+------------------------------------------------------------------+
void AddPendingTicket(ulong ticket)
  {
   int n = ArraySize(g_PendingTickets);
   ArrayResize(g_PendingTickets, n + 1);
   g_PendingTickets[n] = ticket;
  }

//+------------------------------------------------------------------+
//| Agar ye ticket pending list me hai, use nikal deta hai aur true   |
//| return karta hai (matlab ye humari hi position thi)               |
//+------------------------------------------------------------------+
bool ConsumePendingTicket(ulong ticket)
  {
   int n = ArraySize(g_PendingTickets);
   for(int i = 0; i < n; i++)
     {
      if(g_PendingTickets[i] == ticket)
        {
         for(int j = i; j < n - 1; j++)
            g_PendingTickets[j] = g_PendingTickets[j + 1];
         ArrayResize(g_PendingTickets, n - 1);
         return true;
        }
     }
   return false;
  }

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
         if(!trade.PositionClose(g_Sequence.currentTicket))
            Print("[ERROR] Position close FAILED: ", GetLastError());
        }
     }

   EndSequence();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   ProcessedFolder = InpSignalFolder + "\\Processed";
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   Print("SignalCopierEA v8 started.");

   g_LotGlobalVarName = "TGSignalCopier_CurrentLot_" + (string)InpMagicNumber;
   if(GlobalVariableCheck(g_LotGlobalVarName))
      g_CurrentLot = GlobalVariableGet(g_LotGlobalVarName);
   else
     {
      g_CurrentLot = InpLotSize;
      GlobalVariableSet(g_LotGlobalVarName, g_CurrentLot);
     }
   Print("[MARTINGALE] Current lot: ", g_CurrentLot, " (base: ", InpLotSize, ", multiplier: ", InpMartingaleMultiplier, ")");

   g_LastDealGlobalVarName = "TGSignalCopier_LastDeal_" + (string)InpMagicNumber;
   if(GlobalVariableCheck(g_LastDealGlobalVarName))
      g_LastProcessedDealTicket = GlobalVariableGet(g_LastDealGlobalVarName);
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
     }

   g_Sequence.active = false;
   g_Sequence.positionOpen = false;
   g_Sequence.currentTicket = 0;

   // Restart resilience - agar EA restart hua jab koi position khuli thi, use
   // pending ledger me wapas daal do taaki martingale uska result miss na kare
   ArrayResize(g_PendingTickets, 0);
   int totalPositions = PositionsTotal();
   for(int i = 0; i < totalPositions; i++)
     {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0)
         continue;
      if(!PositionSelectByTicket(posTicket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         AddPendingTicket(posTicket);
     }

   g_FolderScanEveryNTicks = (int)MathMax(1, MathRound((InpFolderScanSeconds * 1000.0) / InpPriceCheckMillis));

   EventSetMillisecondTimer(InpPriceCheckMillis);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Print("SignalCopierEA v8 stopped. Reason code: ", reason);
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

      ulong positionId = (ulong)HistoryDealGetInteger(dTicket, DEAL_POSITION_ID);
      long dealReason = HistoryDealGetInteger(dTicket, DEAL_REASON);
      double profit = HistoryDealGetDouble(dTicket, DEAL_PROFIT)
                     + HistoryDealGetDouble(dTicket, DEAL_SWAP)
                     + HistoryDealGetDouble(dTicket, DEAL_COMMISSION);

      // Independent ledger check - ye position humne kabhi bhi open ki thi (chahe
      // uski sequence baad me cancel/overwrite ho gayi ho), toh martingale ZAROOR lagega
      if(ConsumePendingTicket(positionId))
        {
         bool isWin = (profit >= 0);
         string reasonTxt = (dealReason == DEAL_REASON_TP) ? "TP hit" :
                             (dealReason == DEAL_REASON_SL) ? "SL hit" : "manual/other close";
         ApplyMartingaleResult(isWin, reasonTxt);

         // Agar ye ticket abhi bhi current active sequence ka hai, use bhi resolve karo
         if(g_Sequence.active && (ulong)positionId == g_Sequence.currentTicket)
            EndSequence();
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
      AddPendingTicket(positionId);

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
      return;

   do
     {
      if(StringFind(fileName, "CLOSE_") == 0)
         ProcessCloseAllSignal(fileName);
      else
         ProcessSignalFile(fileName);
     }
   while(FileFindNext(searchHandle, fileName));

   FileFindClose(searchHandle);
  }

//+------------------------------------------------------------------+
//| "TP1 CLEAR" message Telegram par aane par ye call hota hai -     |
//| saari open positions (is EA ke magic number wali) turant close   |
//| kar deta hai.                                                     |
//+------------------------------------------------------------------+
void ProcessCloseAllSignal(string fileName)
  {
   Print("[CLOSE ALL] 'TP1 CLEAR' signal mila - saari open positions close kar rahe hain.");

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if(!trade.PositionClose(ticket))
         Print("[ERROR] Position #", ticket, " close FAILED: ", GetLastError());
     }

   if(g_Sequence.active && !g_Sequence.positionOpen)
      EndSequence(); // wait state me thi, koi position close karne ki zaroorat nahi thi

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

   string symbolRaw = JsonGetString(content, "symbol");
   string direction = JsonGetString(content, "direction");
   double entry = JsonGetDouble(content, "entry");
   double sl    = JsonGetDouble(content, "sl");   // asli signal ka SL - broker ko jayega
   double tp    = JsonGetDouble(content, "tp");   // exact TP1 - broker ko jayega

   if(symbolRaw == "" || direction == "" || entry <= 0 || sl <= 0 || tp <= 0)
     {
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

   Print("[NEW SIGNAL] ", direction, " ", symbol, " | Entry=", entry, " | SL=", sl, " | TP1=", tp, " | Lot=", g_Sequence.lot);

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
