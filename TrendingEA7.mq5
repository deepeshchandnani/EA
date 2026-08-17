//+------------------------------------------------------------------+
//|                                          SignalCopierEA_v2.mq5    |
//| Telegram -> MT5 Signal Copier (v2 - verbose logging)              |
//| Har step par detailed log print karta hai taaki debugging aasan  |
//| ho: folder scan ho raha hai ya nahi, file mili ya nahi, parse    |
//| sahi hua ya nahi, trade gaya ya fail hua - sab kuch Experts tab   |
//| (Toolbox) me dikhega.                                             |
//+------------------------------------------------------------------+
#property copyright "Signal Copier v2"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//----------------- INPUTS -----------------
input string InpSignalFolder   = "Signals";   // MQL5\Files\ ke andar folder ka naam (bina slash ke, e.g. "Signals")
input double InpLotSize        = 0.10;        // Base lot size (martingale isi se start hota hai)
input double InpMartingaleMultiplier = 2.0;   // Har loss ke baad lot size isse multiply hoga (uncapped, koi max limit nahi)
input int    InpSlippagePoints = 20;          // Slippage (points)
input long   InpMagicNumber    = 20260708;    // Magic number
input string InpSymbolSuffix   = "";          // Broker symbol suffix, e.g. ".m" or "!"
input int    InpDefaultSLPips  = 50;          // Default SL pips agar signal me na ho
input int    InpDefaultTPPips  = 100;         // Default TP pips agar signal me na ho
input bool   InpSkipIfNoSL     = true;        // True = SL na mile toh trade skip
input int    InpMaxSpreadPoints= 100;         // Is se zyada spread ho toh trade skip
input int    InpPollSeconds    = 2;           // Folder check interval (seconds)
input int    InpEntryTolerancePips = 3;       // Itne pips ke andar ho toh market order, warna pending
input int    InpPendingExpiryMinutes = 60;    // Virtual pending expiry (0 = kabhi expire nahi hoga)
input bool   InpUseVirtualPending = true;     // True = EA khud RAM me price monitor karega (broker pending order use nahi hoga - Wine ke liye zyada reliable)
input bool   InpOneTradePerDay = true;        // True = din ka sirf pehla trade execute hoga, baaki us din ke saare signals ignore honge
input bool   InpVerboseLogging = true;        // Detailed scan logs (debugging ke liye - band karne ke liye false karo)

string ProcessedFolder;
int    ScanCounter = 0;
double g_CurrentLot;
string g_LotGlobalVarName;
double g_LastProcessedDealTicket;
string g_LastDealGlobalVarName;
double g_LastTradeDay;
string g_LastTradeDayGlobalVarName;

//----------------- VIRTUAL PENDING ORDER SYSTEM -----------------
// Broker-side pending order (Buy/Sell Limit/Stop) lagane ke bajaye,
// EA khud is array me signal store karta hai aur har timer tick pe
// price check karta hai. Jaise hi price entry level touch kare,
// turant MARKET order fire ho jata hai. Isse "Invalid price" jaisi
// broker/Wine errors bilkul nahi aati, kyunki koi pending order
// broker ko bheja hi nahi jata.
struct VirtualSignal
  {
   string   symbol;
   bool     isBuy;
   double   entry;
   double   sl;
   double   tp;
   bool     waitingForRise; // true = price ko upar jaana hai entry tak, false = neeche
   datetime expiryTime;     // 0 = kabhi expire nahi
  };

VirtualSignal g_VirtualSignals[];

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| ONE TRADE PER DAY LOGIC                                          |
//| Aaj ka date ek integer (YYYYMMDD) me convert karta hai, taaki    |
//| compare kiya ja sake ki aaj already trade ho chuka hai ya nahi.  |
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

//+------------------------------------------------------------------+
//| Jab bhi ek trade successfully execute ho, isse call karo - aaj ka|
//| din "done" mark ho jata hai, aur baaki saare pending virtual     |
//| signals bhi cancel ho jate hain (kyunki sirf pehla trade allowed)|
//+------------------------------------------------------------------+
void MarkTradedToday()
  {
   if(!InpOneTradePerDay)
      return;

   g_LastTradeDay = TodayAsInt();
   GlobalVariableSet(g_LastTradeDayGlobalVarName, g_LastTradeDay);

   int pendingCount = ArraySize(g_VirtualSignals);
   if(pendingCount > 0)
     {
      ArrayResize(g_VirtualSignals, 0);
      Print("[DAILY LIMIT] Aaj ka trade ho gaya - ", pendingCount, " baaki virtual pending signal(s) bhi cancel kar diye gaye.");
     }

   Print("[DAILY LIMIT] Aaj (", g_LastTradeDay, ") ka trade complete ho gaya. Ab kal tak koi naya trade nahi lega.");
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   ProcessedFolder = InpSignalFolder + "\\Processed";
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   Print("=====================================================");
   Print("SignalCopierEA v2 starting up");
   Print("Watching folder (relative to MQL5\\Files\\): ", InpSignalFolder);
   Print("Processed folder: ", ProcessedFolder);

   // Martingale lot tracking - GlobalVariable se persist hota hai taaki EA/terminal
   // restart hone par bhi current lot size yaad rahe (reset nahi hoga)
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

   // Last processed deal ticket bhi restore/initialize karo - isse pata chalta hai
   // ki kaunse trades already martingale calculation me count ho chuke hain
   g_LastDealGlobalVarName = "TGSignalCopier_LastDeal_" + (string)InpMagicNumber;
   if(GlobalVariableCheck(g_LastDealGlobalVarName))
     {
      g_LastProcessedDealTicket = GlobalVariableGet(g_LastDealGlobalVarName);
      Print("Last processed deal ticket restore hua: ", g_LastProcessedDealTicket);
     }
   else
     {
      // Fresh start - purani history ko martingale me count mat karo, sirf ab se aage wale trades count honge
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
      Print("Fresh start - baseline deal ticket set: ", g_LastProcessedDealTicket, " (isse purani history martingale me count nahi hogi)");
     }

   Print("Base lot: ", InpLotSize, " | Martingale multiplier: ", InpMartingaleMultiplier,
         " | Magic: ", InpMagicNumber, " | Suffix: '", InpSymbolSuffix, "'");

   // One-trade-per-day tracking - GlobalVariable se persist hota hai
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

   // Startup par hi ek baar check karo ki folder accessible hai ya nahi
   if(!FileIsExist(InpSignalFolder))
     {
      Print("WARNING: '", InpSignalFolder, "' folder abhi MQL5\\Files\\ ke andar nahi mil raha. ",
            "Confirm karo Python script isi naam ke folder me files likh raha hai (MQL5\\Files\\", InpSignalFolder, ").");
     }
   else
     {
      Print("OK: Signal folder mil gaya.");
     }

   EventSetTimer(InpPollSeconds);
   ArrayResize(g_VirtualSignals, 0);
   Print("Pending order mode: ", (InpUseVirtualPending ? "VIRTUAL (EA RAM me price monitor karega, broker pending order use nahi hoga)" : "BROKER (traditional Buy/Sell Limit/Stop order)"));
   Print("Timer set: har ", InpPollSeconds, " second me folder scan hoga.");
   Print("=====================================================");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Print("SignalCopierEA v2 stopped. Reason code: ", reason);
  }

//+------------------------------------------------------------------+
//| MARTINGALE LOGIC (uncapped - koi max limit nahi)                 |
//| OnTimer se polling ke through check karta hai ki koi naya trade  |
//| close hua ya nahi (event-based OnTradeTransaction ke bajaye,     |
//| kyunki Wine environment me events kabhi reliably fire nahi hote) |
//|   Loss hua  -> lot size = current lot * InpMartingaleMultiplier  |
//|   Win hua   -> lot size reset ho jata hai InpLotSize (base) par  |
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
         continue; // already process ho chuka hai

      if((double)dTicket > highestTicketSeen)
         highestTicketSeen = (double)dTicket;

      long dealMagic = HistoryDealGetInteger(dTicket, DEAL_MAGIC);
      long dealEntry = HistoryDealGetInteger(dTicket, DEAL_ENTRY);

      // Sirf apne EA ke closing deals consider karo
      if(dealMagic != InpMagicNumber || dealEntry != DEAL_ENTRY_OUT)
         continue;

      double profit = HistoryDealGetDouble(dTicket, DEAL_PROFIT)
                     + HistoryDealGetDouble(dTicket, DEAL_SWAP)
                     + HistoryDealGetDouble(dTicket, DEAL_COMMISSION);

      double previousLot = g_CurrentLot;

      if(profit < 0)
        {
         g_CurrentLot = g_CurrentLot * InpMartingaleMultiplier;
         Print("[MARTINGALE] Trade LOSS (deal #", dTicket, ", profit=", profit, "). Lot size ",
               previousLot, " -> ", g_CurrentLot, " (multiplier: ", InpMartingaleMultiplier, ", uncapped)");
        }
      else
        {
         g_CurrentLot = InpLotSize;
         Print("[MARTINGALE] Trade WIN/BREAKEVEN (deal #", dTicket, ", profit=", profit, "). Lot size reset: ",
               previousLot, " -> ", g_CurrentLot);
        }

      GlobalVariableSet(g_LotGlobalVarName, g_CurrentLot);
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
   if(InpVerboseLogging && ScanCounter % 15 == 0) // har ~30 sec (15 * 2 sec) me ek "alive" log
      Print("[HEARTBEAT] EA chal raha hai, scan #", ScanCounter, " - folder check ho raha hai...");

   CheckClosedTrades();
   CheckVirtualSignals();
   ScanSignalFolder();
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
         Print("[SCAN] Koi .txt file nahi mili folder me (ya folder exist nahi karta): ", searchPath);
      return;
     }

   int filesFound = 0;
   do
     {
      filesFound++;
      Print("[FOUND] Signal file mili: ", fileName);
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

   // ONE TRADE PER DAY check - agar aaj already trade ho chuka hai, ye signal ignore karo
   if(AlreadyTradedToday())
     {
      Print("[DAILY LIMIT] Aaj (", TodayAsInt(), ") ka trade already ho chuka hai, signal ignore: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   string symbolRaw = JsonGetString(content, "symbol");
   string direction = JsonGetString(content, "direction");
   double entry = JsonGetDouble(content, "entry");
   double sl    = JsonGetDouble(content, "sl");
   double tp    = JsonGetDouble(content, "tp");

   Print("[PARSED] symbol=", symbolRaw, " direction=", direction, " entry=", entry, " sl=", sl, " tp=", tp);

   if(symbolRaw == "" || direction == "")
     {
      Print("[SKIP] Invalid signal (symbol/direction missing), file: ", fileName);
      MoveToProcessed(fileName);
      return;
     }

   string symbol = symbolRaw + InpSymbolSuffix;

   if(!SymbolSelect(symbol, true))
     {
      Print("[ERROR] Symbol Market Watch me nahi mila: '", symbol, "'. ",
            "Check karo broker me exact symbol naam kya hai (Market Watch me right-click -> Symbols), ",
            "aur InpSymbolSuffix sahi set hai ya nahi.");
      MoveToProcessed(fileName);
      return;
     }

   long spreadPoints = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   if(spreadPoints > InpMaxSpreadPoints)
     {
      Print("[SKIP] Spread zyada hai (", spreadPoints, " points > limit ", InpMaxSpreadPoints, ") for ", symbol);
      MoveToProcessed(fileName);
      return;
     }

   ExecuteTrade(symbol, direction, entry, sl, tp);
   MoveToProcessed(fileName);
  }

//+------------------------------------------------------------------+
void ExecuteTrade(string symbol, string direction, double entry, double sl, double tp)
  {
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double pip = point * 10;

   double finalSL = sl;
   double finalTP = tp;

   bool isBuy = (direction == "BUY");
   double currentPrice = isBuy ? ask : bid;
   double refPrice = (entry > 0) ? entry : currentPrice;

   if(finalSL == 0 && InpDefaultSLPips > 0)
      finalSL = isBuy ? refPrice - InpDefaultSLPips * pip : refPrice + InpDefaultSLPips * pip;

   if(finalTP == 0 && InpDefaultTPPips > 0)
      finalTP = isBuy ? refPrice + InpDefaultTPPips * pip : refPrice - InpDefaultTPPips * pip;

   finalSL = NormalizeDouble(finalSL, digits);
   finalTP = NormalizeDouble(finalTP, digits);

   Print("[TRADE PLAN] ", direction, " ", symbol, " | ask=", ask, " bid=", bid,
         " | finalSL=", finalSL, " finalTP=", finalTP, " | entry(from signal)=", entry);

   if(finalSL == 0 && InpSkipIfNoSL)
     {
      Print("[SKIP] SL 0 hai aur InpSkipIfNoSL=true, trade skip: ", direction, " ", symbol);
      return;
     }

   if(entry <= 0)
     {
      Print("[ACTION] Entry price signal me nahi tha -> market order jayega.");
      PlaceMarketOrder(symbol, isBuy, finalSL, finalTP);
      return;
     }

   double diffPips = MathAbs(currentPrice - entry) / pip;
   Print("[CHECK] Current price se entry ka farak: ", diffPips, " pips (tolerance=", InpEntryTolerancePips, ")");

   if(diffPips <= InpEntryTolerancePips)
     {
      Print("[ACTION] Farak tolerance ke andar hai -> market order jayega.");
      PlaceMarketOrder(symbol, isBuy, finalSL, finalTP);
     }
   else if(InpUseVirtualPending)
     {
      Print("[ACTION] Farak tolerance se zyada hai -> VIRTUAL pending register hoga, EA khud price monitor karega.");
      RegisterVirtualSignal(symbol, isBuy, entry, finalSL, finalTP, currentPrice);
     }
   else
     {
      Print("[ACTION] Farak tolerance se zyada hai -> broker pending order lagega entry price par.");
      PlacePendingOrder(symbol, isBuy, entry, currentPrice, finalSL, finalTP, digits);
     }
  }

//+------------------------------------------------------------------+
void PlaceMarketOrder(string symbol, bool isBuy, double finalSL, double finalTP)
  {
   bool result;
   if(isBuy)
      result = trade.Buy(g_CurrentLot, symbol, 0, finalSL, finalTP, "TG Signal");
   else
      result = trade.Sell(g_CurrentLot, symbol, 0, finalSL, finalTP, "TG Signal");

   if(result)
     {
      Print("[SUCCESS] Market trade executed: ", (isBuy ? "BUY" : "SELL"), " ", symbol,
            " Lot=", g_CurrentLot, " SL=", finalSL, " TP=", finalTP, " Ticket=", trade.ResultOrder());
      MarkTradedToday();
     }
   else
      Print("[FAILED] Market trade FAILED: ", (isBuy ? "BUY" : "SELL"), " ", symbol,
            " | GetLastError=", GetLastError(), " | RetCode=", trade.ResultRetcode(),
            " | RetCodeDescription=", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Pending order lagata hai - lekin pehle FRESH price le kar aur     |
//| broker ke minimum stop distance (StopsLevel/FreezeLevel) check   |
//| karke, taaki "Invalid price" error na aaye (jo price move hone   |
//| se ya price bahut paas hone se hoti hai)                          |
//+------------------------------------------------------------------+
void PlacePendingOrder(string symbol, bool isBuy, double entry, double currentPrice, double finalSL, double finalTP, int digits)
  {
   entry = NormalizeDouble(entry, digits);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   // FRESH price lo - jo currentPrice pehle pass hua tha wo stale ho sakta hai
   // (ExecuteTrade se yahan tak aane me kuch milliseconds/seconds beet chuke honge)
   double freshAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double freshBid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double freshPrice = isBuy ? freshAsk : freshBid;

   // Broker ka minimum distance check karo (StopsLevel aur FreezeLevel dono me se jo zyada ho)
   long stopsLevelPoints = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPoints = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long minDistPoints = MathMax(stopsLevelPoints, freezeLevelPoints);
   double minDistPrice = minDistPoints * point;

   double diffFromFresh = MathAbs(freshPrice - entry);

   Print("[PENDING CHECK] Fresh price=", freshPrice, " | Entry=", entry, " | Diff=", diffFromFresh,
         " | Broker min distance required=", minDistPrice, " (", minDistPoints, " points)");

   // Agar price ab entry ke bahut paas aa chuki hai (broker ki min distance se kam),
   // toh pending order "Invalid price" degi - iski jagah seedha market order laga do
   if(diffFromFresh < minDistPrice || diffFromFresh < point) // point wali check zero-distance ke liye safety
     {
      Print("[FALLBACK] Price entry ke bahut paas hai (broker min distance violate hoga) -> market order jayega instead.");
      PlaceMarketOrder(symbol, isBuy, finalSL, finalTP);
      return;
     }

   // Order type bhi FRESH price se decide karo (stale currentPrice se nahi)
   datetime expiration = 0;
   ENUM_ORDER_TYPE_TIME timeType = ORDER_TIME_GTC;

   if(InpPendingExpiryMinutes > 0)
     {
      timeType = ORDER_TIME_SPECIFIED;
      expiration = TimeCurrent() + InpPendingExpiryMinutes * 60;
     }

   bool result;
   string orderLabel;

   if(isBuy)
     {
      if(entry > freshPrice)
        {
         result = trade.BuyStop(g_CurrentLot, entry, symbol, finalSL, finalTP, timeType, expiration, "TG Signal");
         orderLabel = "BUY STOP";
        }
      else
        {
         result = trade.BuyLimit(g_CurrentLot, entry, symbol, finalSL, finalTP, timeType, expiration, "TG Signal");
         orderLabel = "BUY LIMIT";
        }
     }
   else
     {
      if(entry < freshPrice)
        {
         result = trade.SellStop(g_CurrentLot, entry, symbol, finalSL, finalTP, timeType, expiration, "TG Signal");
         orderLabel = "SELL STOP";
        }
      else
        {
         result = trade.SellLimit(g_CurrentLot, entry, symbol, finalSL, finalTP, timeType, expiration, "TG Signal");
         orderLabel = "SELL LIMIT";
        }
     }

   if(result)
      Print("[SUCCESS] ", orderLabel, " pending order placed: ", symbol, " Entry=", entry,
            " Lot=", g_CurrentLot, " SL=", finalSL, " TP=", finalTP, " Ticket=", trade.ResultOrder());
   else
     {
      Print("[FAILED] ", orderLabel, " pending order FAILED: ", symbol,
            " | GetLastError=", GetLastError(), " | RetCode=", trade.ResultRetcode(),
            " | RetCodeDescription=", trade.ResultRetcodeDescription());
      Print("[FALLBACK] Pending order fail hui -> market order try karte hain instead.");
      PlaceMarketOrder(symbol, isBuy, finalSL, finalTP);
     }
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
//| Ek naya virtual pending signal register karta hai (array me add) |
//+------------------------------------------------------------------+
void RegisterVirtualSignal(string symbol, bool isBuy, double entry, double sl, double tp, double currentPrice)
  {
   int size = ArraySize(g_VirtualSignals);
   ArrayResize(g_VirtualSignals, size + 1);

   g_VirtualSignals[size].symbol = symbol;
   g_VirtualSignals[size].isBuy  = isBuy;
   g_VirtualSignals[size].entry  = entry;
   g_VirtualSignals[size].sl     = sl;
   g_VirtualSignals[size].tp     = tp;
   g_VirtualSignals[size].waitingForRise = (entry > currentPrice); // price ko upar jaana hai ya neeche, entry tak pahunchne ke liye

   if(InpPendingExpiryMinutes > 0)
      g_VirtualSignals[size].expiryTime = TimeCurrent() + InpPendingExpiryMinutes * 60;
   else
      g_VirtualSignals[size].expiryTime = 0; // kabhi expire nahi

   Print("[VIRTUAL REGISTERED] ", (isBuy ? "BUY" : "SELL"), " ", symbol, " @ ", entry,
         " | Current=", currentPrice, " | Waiting for price to ", (g_VirtualSignals[size].waitingForRise ? "RISE" : "FALL"),
         " to entry | Active virtual signals: ", size + 1);
  }

//+------------------------------------------------------------------+
//| Har timer tick pe saare virtual pending signals check karta hai  |
//| - price entry tak pahunchi -> market order fire                  |
//| - expire ho gaya -> silently remove kar deta hai                 |
//+------------------------------------------------------------------+
void CheckVirtualSignals()
  {
   int total = ArraySize(g_VirtualSignals);
   if(total == 0)
      return;

   if(InpVerboseLogging && ScanCounter % 15 == 0)
      Print("[HEARTBEAT] Active virtual pending signals: ", total);

   // Peeche se aage jao taaki remove karte waqt index shift ka issue na ho
   for(int i = total - 1; i >= 0; i--)
     {
      string symbol = g_VirtualSignals[i].symbol;

      // Expiry check
      if(g_VirtualSignals[i].expiryTime > 0 && TimeCurrent() >= g_VirtualSignals[i].expiryTime)
        {
         Print("[VIRTUAL EXPIRED] ", (g_VirtualSignals[i].isBuy ? "BUY" : "SELL"), " ", symbol,
               " @ ", g_VirtualSignals[i].entry, " - price kabhi entry tak nahi pahunchi, order cancel.");
         RemoveVirtualSignal(i);
         continue;
        }

      if(!SymbolSelect(symbol, true))
         continue;

      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double currentPrice = g_VirtualSignals[i].isBuy ? ask : bid;
      double entry = g_VirtualSignals[i].entry;

      bool triggered = false;
      if(g_VirtualSignals[i].waitingForRise && currentPrice >= entry)
         triggered = true;
      else if(!g_VirtualSignals[i].waitingForRise && currentPrice <= entry)
         triggered = true;

      if(triggered)
        {
         Print("[VIRTUAL TRIGGERED] ", (g_VirtualSignals[i].isBuy ? "BUY" : "SELL"), " ", symbol,
               " - Price pahunch gayi entry (", entry, ") tak. Current=", currentPrice, ". Market order fire ho raha hai.");

         PlaceMarketOrder(symbol, g_VirtualSignals[i].isBuy, g_VirtualSignals[i].sl, g_VirtualSignals[i].tp);

         // PlaceMarketOrder ke andar MarkTradedToday() poora array clear kar sakta hai
         // (agar InpOneTradePerDay=true aur trade success hui) - isliye index safety check zaroori hai
         if(i < ArraySize(g_VirtualSignals))
            RemoveVirtualSignal(i);
         else
            break; // array already clear ho chuka hai, loop yahi rok do
        }
     }
  }

//+------------------------------------------------------------------+
//| Array se ek virtual signal remove karta hai (index se)           |
//+------------------------------------------------------------------+
void RemoveVirtualSignal(int index)
  {
   int total = ArraySize(g_VirtualSignals);
   if(index < 0 || index >= total)
      return;

   // Last element ko is index par copy karke array chhota kar do (order matter nahi karta)
   g_VirtualSignals[index] = g_VirtualSignals[total - 1];
   ArrayResize(g_VirtualSignals, total - 1);
  }
//+------------------------------------------------------------------+
