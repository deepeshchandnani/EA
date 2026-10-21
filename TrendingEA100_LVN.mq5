//+------------------------------------------------------------------+
//|                                              TrendingEA100_LVN.mq5|
//| LVN Hedge + Loop Reentry EA (v8)                                  |
//|                                                                   |
//| Logic:                                                            |
//|  - Telegram signal nahi. Session shuru hote hi volume profile se  |
//|    do LVN (Low Volume Node) nikalte hain:                         |
//|       SUPPORT LVN    = current price ke NICHE sabse paas wala LVN |
//|       RESISTANCE LVN = current price ke UPAR sabse paas wala LVN  |
//|  - Har LVN par price touch hote hi BUY + SELL dono khulte hain    |
//|    (same lot, default 0.40).                                      |
//|  - Har leg ka loop SL = fill se $1.4, TP = fill se $10.           |
//|    SL hit -> price wapas LVN par aate hi leg dobara khulti hai.   |
//|  - Kisi leg ka SL InpMaxSLHits (7) se zyada baar hit ho jaye toh  |
//|    wo leg hamesha ke liye band, continue nahi hoti.               |
//|  - Entry/reentry sirf session window me (default 18:15-19:30 IST).|
//|    Window ke baad nayi entry/reentry nahi, khuli positions apne   |
//|    SL/TP par chalti rehti hain.                                   |
//|                                                                   |
//| ZAROORI: Account HEDGING type ka hona chahiye.                    |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "8.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//----------------- INPUTS -----------------
input group "=== Trade ==="
input string InpSymbol           = "";          // Khali = chart ka symbol (EA ko XAUUSD chart par lagao)
input double InpLotSize          = 0.40;        // Har leg ka lot (BUY aur SELL dono same)
input double InpSLDollars        = 1.4;         // Loop SL distance (price units, gold me $1 = 1.00) - fill price se
input double InpTPDollars        = 10.0;        // TP distance (price units) - fill price se
input int    InpMaxSLHits        = 7;           // Ek leg ka SL is se ZYADA baar hit ho toh wo leg band (8vi baar par)
input bool   InpSendSLToBroker   = true;        // true: SL broker ko bhi bheja jata hai. Reject ho toh EA khud monitor karega

input group "=== Session (IST) ==="
input string InpSessionStartIST  = "18:15";     // Entry window start (IST, HH:MM)
input string InpSessionEndIST    = "19:30";     // Entry window end   (IST, HH:MM)

input group "=== LVN (Volume Profile) ==="
input ENUM_TIMEFRAMES InpProfileTF = PERIOD_M5; // Profile kis timeframe ke bars se bane
input int    InpProfileDays      = 5;           // Kitne din (24h) ke bars ka profile
input double InpBinSize          = 1.0;         // Price bin size (price units)
input int    InpSmoothBins       = 2;           // Profile smoothing (+/- bins)
input int    InpNodeWindowBins   = 5;           // Local minimum window (+/- bins)
input int    InpPeakWindowBins   = 15;          // Valley ke dono taraf peak dhundhne ki window (bins)
input double InpLVNDepth         = 0.6;         // Valley volume <= is ratio x chhota neighbouring peak (kam = zyada gehra LVN)
input double InpMinLevelDistance = 2.0;         // LVN current price se kam se kam itna door ho

input group "=== Execution ==="
input int    InpSlippagePoints   = 20;          // Slippage (points)
input long   InpMagicNumber      = 20260708;    // Base magic (Support = base, Resistance = base+1)
input int    InpMaxSpreadPoints  = 100;         // Is se zyada spread par entry/reentry skip (agla tick retry)
input int    InpMaxLegRetries    = 20;          // Order fail hone par max attempts, uske baad agli touch ka wait
input int    InpPriceCheckMillis = 200;         // Price monitor interval (milliseconds)
input bool   InpLogErrors        = true;        // true: errors (order fail etc.) Experts me dikhein

//----------------- STATE -----------------
struct HedgeLeg
  {
   bool   isBuy;
   bool   opened;        // position abhi khuli hai
   bool   wantOpen;      // entry/reentry touch ho chuki, order khulne ka intezaar (retry ke liye)
   bool   done;          // leg hamesha ke liye khatam (TP / manual / SL limit / session over)
   bool   brokerSL;      // true = SL broker-side laga hai, false = EA monitor karega
   bool   slClosing;     // EA ne khud SL par close bheja
   ulong  ticket;        // position ID
   double slLevel;
   double lastPrice;     // reentry ke wait me level cross detect karne ke liye
   int    attempts;      // current open attempt me kitni baar fail hua
   int    entries;       // is leg ne total kitni baar entry li
   int    slHits;        // is leg ka SL kitni baar hit hua
   int    historyTries;  // close ke baad history reason dhundhne ki koshish
  };

struct LevelSetup
  {
   bool   active;
   bool   triggered;     // pehli touch ho chuki
   double entry;         // LVN price
   double lastPrice;     // pehli touch detect karne ke liye (mid price)
   long   magic;
  };

string     g_Symbol;
int        g_SessStartMin = 0;
int        g_SessEndMin   = 0;
bool       g_InSession    = false;
long       g_ISTDay       = 0;
long       g_ComputedDay  = -1;
long       g_ErrLoggedDay = -1;
ulong      g_NextComputeTryMs = 0;

LevelSetup g_Level[2];   // 0 = SUPPORT LVN, 1 = RESISTANCE LVN
HedgeLeg   g_Leg[4];     // index = level*2 + (BUY ? 0 : 1)

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
   int digits = (int)SymbolInfoInteger(g_Symbol, SYMBOL_DIGITS);
   return DoubleToString(value, digits);
  }

string LevelName(int L)
  {
   return (L == 0) ? "SUPPORT" : "RESISTANCE";
  }

string Side(HedgeLeg &leg)
  {
   return leg.isBuy ? "BUY" : "SELL";
  }

double LegPrice(HedgeLeg &leg)
  {
   return leg.isBuy ? SymbolInfoDouble(g_Symbol, SYMBOL_ASK)
                    : SymbolInfoDouble(g_Symbol, SYMBOL_BID);
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
   leg.slHits       = 0;
   leg.historyTries = 0;
  }

int ParseHHMM(string s)
  {
   string parts[];
   if(StringSplit(s, ':', parts) != 2)
      return -1;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return -1;
   return h * 60 + m;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   // BUY + SELL same symbol par sirf hedging account me alag-alag rehte hain
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("[FATAL] Ye account HEDGING type ka nahi hai, BUY aur SELL net ho jayenge. EA start nahi hoga.");
      Alert("TrendingEA100_LVN: account hedging type ka nahi hai - EA band.");
      return(INIT_FAILED);
     }

   if(InpLotSize <= 0 || InpSLDollars <= 0 || InpTPDollars <= 0 || InpMaxSLHits < 0)
     {
      Print("[FATAL] InpLotSize / InpSLDollars / InpTPDollars 0 se bade aur InpMaxSLHits >= 0 hone chahiye.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpBinSize <= 0 || InpSmoothBins < 0 || InpNodeWindowBins < 1 || InpPeakWindowBins < 1 ||
      InpLVNDepth <= 0 || InpLVNDepth > 1 || InpProfileDays < 1 || InpMinLevelDistance < 0)
     {
      Print("[FATAL] LVN inputs galat hain (bin>0, windows>=1, 0<depth<=1, days>=1).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_SessStartMin = ParseHHMM(InpSessionStartIST);
   g_SessEndMin   = ParseHHMM(InpSessionEndIST);
   if(g_SessStartMin < 0 || g_SessEndMin < 0 || g_SessStartMin >= g_SessEndMin)
     {
      Print("[FATAL] Session time galat. Format HH:MM aur start < end hona chahiye (same din).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_Symbol = (InpSymbol == "") ? _Symbol : InpSymbol;
   if(!SymbolSelect(g_Symbol, true))
     {
      Print("[FATAL] Symbol Market Watch me nahi mila: '", g_Symbol, "'");
      return(INIT_FAILED);
     }

   trade.SetDeviationInPoints(InpSlippagePoints);

   for(int L = 0; L < 2; L++)
     {
      g_Level[L].active    = false;
      g_Level[L].triggered = false;
      g_Level[L].entry     = 0;
      g_Level[L].lastPrice = 0;
      g_Level[L].magic     = InpMagicNumber + L;
      ResetLeg(g_Leg[L * 2],     true);
      ResetLeg(g_Leg[L * 2 + 1], false);
     }

   EventSetMillisecondTimer(InpPriceCheckMillis);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < 4; i++)
     {
      if(g_Leg[i].opened && !g_Leg[i].brokerSL)
        {
         LogErr("EA band ho raha hai par kuch positions ka SL EA-monitored tha - ab unka SL monitor nahi hoga, manually check karo.");
         break;
        }
     }
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   g_InSession = IsInSession();

   if(g_InSession && g_ComputedDay != g_ISTDay)
      TryArmSession();

   ManageLevel(0);
   ManageLevel(1);
  }

//+------------------------------------------------------------------+
//| Session check: IST = GMT + 5:30 (IST me DST nahi hota).           |
//| TimeGMT() PC ki clock/timezone se banta hai, isliye PC/VPS ka     |
//| time sahi hona chahiye. Sat/Sun IST me market band, session nahi. |
//+------------------------------------------------------------------+
bool IsInSession()
  {
   long ist = (long)TimeGMT() + 19800;
   g_ISTDay = ist / 86400;

   MqlDateTime dt;
   TimeToStruct((datetime)ist, dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;

   int minutes = (int)((ist % 86400) / 60);
   return (minutes >= g_SessStartMin && minutes < g_SessEndMin);
  }

//+------------------------------------------------------------------+
//| Session ke din me ek baar: LVN nikalo aur dono levels arm karo    |
//+------------------------------------------------------------------+
void TryArmSession()
  {
   ulong nowMs = GetTickCount64();
   if(nowMs < g_NextComputeTryMs)
      return;
   g_NextComputeTryMs = nowMs + 10000;   // fail hone par 10 sec baad retry

   double support = 0, resistance = 0, price = 0;
   string why = "";
   if(!ComputeLVN(support, resistance, price, why))
     {
      if(g_ErrLoggedDay != g_ISTDay)
        {
         LogErr("LVN calculate nahi ho paya: " + why);
         g_ErrLoggedDay = g_ISTDay;
        }
      return;
     }

   g_ComputedDay = g_ISTDay;

   Print("[LVN] ", g_Symbol, " price=", Px(price),
         " | Support LVN=",    (support > 0    ? Px(support)    : "nahi mila"),
         " | Resistance LVN=", (resistance > 0 ? Px(resistance) : "nahi mila"));

   ArmLevel(0, support, price);
   ArmLevel(1, resistance, price);
  }

//+------------------------------------------------------------------+
void ArmLevel(int L, double level, double price)
  {
   if(level <= 0)
      return;

   // Is level ka pichhla trade khuli position ke saath chal raha hai -> disturb nahi karte
   if(g_Level[L].active && (g_Leg[L * 2].opened || g_Leg[L * 2 + 1].opened))
     {
      Print("[LVN] ", LevelName(L), " level skip - pichhla trade abhi khuli position ke saath chal raha hai.");
      return;
     }

   ResetLeg(g_Leg[L * 2],     true);
   ResetLeg(g_Leg[L * 2 + 1], false);

   g_Level[L].active    = true;
   g_Level[L].triggered = false;
   g_Level[L].entry     = level;
   g_Level[L].lastPrice = price;
  }

//+------------------------------------------------------------------+
//| Volume profile (tick volume, bar ke high-low range me barabar     |
//| baanta hua) -> smooth -> local minimum + valley depth se LVN.     |
//| Support = price ke neeche sabse paas wala LVN, Resistance =       |
//| upar sabse paas wala LVN.                                         |
//+------------------------------------------------------------------+
bool ComputeLVN(double &support, double &resistance, double &curPrice, string &why)
  {
   support    = 0;
   resistance = 0;

   MqlTick tick;
   if(!SymbolInfoTick(g_Symbol, tick) || tick.bid <= 0 || tick.ask <= 0)
     {
      why = "current price nahi mili";
      return false;
     }
   curPrice = (tick.bid + tick.ask) / 2.0;

   int secs  = PeriodSeconds(InpProfileTF);
   int count = (int)MathMax(100.0, (double)InpProfileDays * 86400.0 / (double)secs);

   MqlRates rates[];
   int got = CopyRates(g_Symbol, InpProfileTF, 0, count, rates);
   if(got < 100)
     {
      why = "history bars kam mile (" + IntegerToString(got) + ") - chart par history load hone do";
      return false;
     }

   double minP = rates[0].low;
   double maxP = rates[0].high;
   for(int k = 1; k < got; k++)
     {
      minP = MathMin(minP, rates[k].low);
      maxP = MathMax(maxP, rates[k].high);
     }

   int n = (int)MathFloor((maxP - minP) / InpBinSize) + 1;
   int W = InpNodeWindowBins;
   int P = InpPeakWindowBins;
   if(n < 2 * W + 3 || n > 50000)
     {
      why = "profile range/bin size theek nahi (bins=" + IntegerToString(n) + ")";
      return false;
     }

   // ---- Volume histogram ----
   double vol[];
   ArrayResize(vol, n);
   ArrayInitialize(vol, 0.0);

   for(int k = 0; k < got; k++)
     {
      int i0 = (int)MathFloor((rates[k].low  - minP) / InpBinSize);
      int i1 = (int)MathFloor((rates[k].high - minP) / InpBinSize);
      i0 = (int)MathMax(0, MathMin(n - 1, i0));
      i1 = (int)MathMax(0, MathMin(n - 1, i1));
      double v = (double)rates[k].tick_volume / (double)(i1 - i0 + 1);
      for(int j = i0; j <= i1; j++)
         vol[j] += v;
     }

   // ---- Smoothing ----
   double sm[];
   ArrayResize(sm, n);
   for(int i = 0; i < n; i++)
     {
      int lo = (int)MathMax(0, i - InpSmoothBins);
      int hi = (int)MathMin(n - 1, i + InpSmoothBins);
      double sum = 0;
      for(int j = lo; j <= hi; j++)
         sum += vol[j];
      sm[i] = sum / (double)(hi - lo + 1);
     }

   // ---- LVN detect: local minimum + valley depth ----
   int    digits = (int)SymbolInfoInteger(g_Symbol, SYMBOL_DIGITS);
   double bestS  = 0;
   double bestR  = 0;

   for(int i = W; i < n - W; i++)
     {
      bool isMin = true;
      for(int j = i - W; j <= i + W; j++)
        {
         if(j == i)
            continue;
         if(j < i && sm[j] <= sm[i])   // left side strictly zyada
           {
            isMin = false;
            break;
           }
         if(j > i && sm[j] < sm[i])    // right side kam na ho
           {
            isMin = false;
            break;
           }
        }
      if(!isMin)
         continue;

      double leftMax  = 0;
      double rightMax = 0;
      for(int j = (int)MathMax(0, i - P); j < i; j++)
         leftMax = MathMax(leftMax, sm[j]);
      for(int j = i + 1; j <= (int)MathMin(n - 1, i + P); j++)
         rightMax = MathMax(rightMax, sm[j]);

      if(sm[i] > InpLVNDepth * MathMin(leftMax, rightMax))
         continue;

      double lvnPrice = minP + ((double)i + 0.5) * InpBinSize;

      if(lvnPrice <= curPrice - InpMinLevelDistance)
        {
         if(lvnPrice > bestS)
            bestS = lvnPrice;
        }
      else if(lvnPrice >= curPrice + InpMinLevelDistance)
        {
         if(bestR == 0 || lvnPrice < bestR)
            bestR = lvnPrice;
        }
     }

   support    = (bestS > 0) ? NormalizeDouble(bestS, digits) : 0;
   resistance = (bestR > 0) ? NormalizeDouble(bestR, digits) : 0;
   return true;
  }

//+------------------------------------------------------------------+
//| Ek level ka poora kaam: pehli touch ka wait -> dono legs ->       |
//| dono legs done hone par level khatam                              |
//+------------------------------------------------------------------+
void ManageLevel(int L)
  {
   if(!g_Level[L].active)
      return;

   if(!g_Level[L].triggered)
     {
      // Session ke bahar armed (untouched) level hata do
      if(!g_InSession)
        {
         g_Level[L].active = false;
         return;
        }

      double bid = SymbolInfoDouble(g_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(g_Symbol, SYMBOL_ASK);
      if(bid <= 0 || ask <= 0)
         return;

      double mid = (bid + ask) / 2.0;
      if(g_Level[L].lastPrice <= 0)
        {
         g_Level[L].lastPrice = mid;
         return;
        }

      double point    = SymbolInfoDouble(g_Symbol, SYMBOL_POINT);
      double diffPrev = g_Level[L].lastPrice - g_Level[L].entry;
      double diffNow  = mid - g_Level[L].entry;

      bool touched = false;
      if(MathAbs(diffNow) <= point * 2)
         touched = true;
      else if(diffPrev == 0)
         touched = true;
      else if((diffPrev > 0 && diffNow < 0) || (diffPrev < 0 && diffNow > 0))
         touched = true;

      g_Level[L].lastPrice = mid;

      if(!touched)
         return;

      g_Level[L].triggered = true;
      g_Leg[L * 2].wantOpen     = true;
      g_Leg[L * 2].attempts     = 0;
      g_Leg[L * 2 + 1].wantOpen = true;
      g_Leg[L * 2 + 1].attempts = 0;
     }

   ProcessLeg(L, g_Leg[L * 2],     g_Leg[L * 2 + 1]);
   ProcessLeg(L, g_Leg[L * 2 + 1], g_Leg[L * 2]);

   if(g_Leg[L * 2].done && g_Leg[L * 2 + 1].done)
     {
      g_Level[L].active    = false;
      g_Level[L].triggered = false;
     }
  }

//+------------------------------------------------------------------+
//| Har leg ki states:                                                |
//|   opened   -> position monitor (SL / TP / close detect)           |
//|   session ke bahar flat -> leg done (nayi entry nahi)             |
//|   wantOpen -> order kholne ki koshish                             |
//|   baaki    -> flat, price ke wapas LVN par aane ka wait           |
//+------------------------------------------------------------------+
void ProcessLeg(int L, HedgeLeg &leg, HedgeLeg &other)
  {
   if(leg.done)
      return;

   if(leg.opened)
     {
      MonitorLeg(L, leg);
      return;
     }

   if(!g_InSession)
     {
      leg.wantOpen = false;
      leg.done     = true;
      return;
     }

   if(leg.wantOpen)
     {
      TryOpenLeg(L, leg, other);
      return;
     }

   CheckReentryTouch(L, leg, other);
  }

//+------------------------------------------------------------------+
//| Flat leg: price (BUY=ASK, SELL=BID) LVN par wapas aaye toh        |
//| reentry                                                           |
//+------------------------------------------------------------------+
void CheckReentryTouch(int L, HedgeLeg &leg, HedgeLeg &other)
  {
   double price = LegPrice(leg);
   if(price <= 0)
      return;

   if(leg.lastPrice <= 0)
     {
      leg.lastPrice = price;
      return;
     }

   double point    = SymbolInfoDouble(g_Symbol, SYMBOL_POINT);
   double diffPrev = leg.lastPrice - g_Level[L].entry;
   double diffNow  = price - g_Level[L].entry;

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
      TryOpenLeg(L, leg, other);
     }
  }

//+------------------------------------------------------------------+
void OpenFailed(int L, HedgeLeg &leg, string why)
  {
   leg.attempts++;
   if(leg.attempts == 1)
      LogErr(LevelName(L) + " " + Side(leg) + " " + g_Symbol + " order fail: " + why);

   if(leg.attempts >= InpMaxLegRetries)
     {
      LogErr(LevelName(L) + " " + Side(leg) + " " + g_Symbol + " " + IntegerToString(InpMaxLegRetries) +
             " attempts fail hue, agli touch ka wait karenge.");
      leg.wantOpen  = false;
      leg.attempts  = 0;
      leg.lastPrice = 0;
     }
  }

//+------------------------------------------------------------------+
ulong FindPositionTicket(long magic, bool isBuy)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
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
void TryOpenLeg(int L, HedgeLeg &leg, HedgeLeg &other)
  {
   int digits = (int)SymbolInfoInteger(g_Symbol, SYMBOL_DIGITS);

   // Spread gate. Pehli entry me dusri leg ko hedge complete karne ke liye turant kholte hain.
   bool completingHedge = (leg.entries == 0 && other.entries > 0);
   if(!completingHedge && SymbolInfoInteger(g_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints)
      return;

   double price = LegPrice(leg);
   if(price <= 0)
     {
      OpenFailed(L, leg, "valid price nahi mili");
      return;
     }

   double tp = leg.isBuy ? price + InpTPDollars : price - InpTPDollars;
   tp = NormalizeDouble(tp, digits);

   trade.SetExpertMagicNumber(g_Level[L].magic);

   bool ok;
   if(leg.isBuy)
      ok = trade.Buy(InpLotSize, g_Symbol, 0, 0, tp, "");
   else
      ok = trade.Sell(InpLotSize, g_Symbol, 0, 0, tp, "");

   if(!ok)
     {
      OpenFailed(L, leg, "RetCode=" + IntegerToString((int)trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
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
      positionId = FindPositionTicket(g_Level[L].magic, leg.isBuy);

   if(positionId == 0)
     {
      LogErr(LevelName(L) + " " + Side(leg) + " " + g_Symbol + " position khuli par ticket track nahi ho paya - is leg ko manually dekho.");
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

   string tag;
   if(leg.entries == 1)
      tag = "[ENTRY]";
   else
      tag = "[REENTRY #" + IntegerToString(leg.entries - 1) + "]";

   Print(tag, " ", LevelName(L), " ", Side(leg), " ", g_Symbol, " lot=", DoubleToString(InpLotSize, 2),
         " price=", Px(fillPrice), " SL=", Px(leg.slLevel), " TP=", Px(tp), " | LVN=", Px(g_Level[L].entry));
  }

//+------------------------------------------------------------------+
//| Khuli leg: position gayab ho gayi toh reason dekho, warna         |
//| broker SL na ho toh EA khud SL check kare                         |
//+------------------------------------------------------------------+
void MonitorLeg(int L, HedgeLeg &leg)
  {
   if(!PositionSelectByTicket(leg.ticket))
     {
      HandleLegClosed(L, leg);
      return;
     }

   if(leg.brokerSL)
      return;

   // Software SL: BUY ka exit BID par, SELL ka ASK par (broker jaisa)
   double bid = SymbolInfoDouble(g_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0)
      return;

   bool slHit = leg.isBuy ? (bid <= leg.slLevel) : (ask >= leg.slLevel);
   if(!slHit)
      return;

   leg.slClosing = true;
   if(trade.PositionClose(leg.ticket))
      HandleLegClosed(L, leg);
   else
     {
      leg.slClosing = false;
      LogErr(LevelName(L) + " " + Side(leg) + " " + g_Symbol + " SL close fail: RetCode=" +
             IntegerToString((int)trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription() + " - agla tick retry.");
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
//|   SL  -> slHits++. Limit paar ho gayi ya session khatam: leg done |
//|          warna price LVN par wapas aane par reentry               |
//|   TP / manual -> leg hamesha ke liye done                         |
//+------------------------------------------------------------------+
void HandleLegClosed(int L, HedgeLeg &leg)
  {
   bool   isSL      = false;
   bool   isTP      = false;
   double exitPrice = 0;

   if(leg.slClosing)
     {
      isSL      = true;
      exitPrice = leg.isBuy ? SymbolInfoDouble(g_Symbol, SYMBOL_BID) : SymbolInfoDouble(g_Symbol, SYMBOL_ASK);
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
      leg.slHits++;

      if(leg.slHits > InpMaxSLHits)
        {
         leg.done = true;
         Print("[LEG STOPPED] ", LevelName(L), " ", Side(leg), " ", g_Symbol, " price=", Px(exitPrice),
               " - SL ", leg.slHits, " baar hit (limit ", InpMaxSLHits, "), ye trade ab continue nahi hoga.");
         return;
        }

      if(!g_InSession)
        {
         leg.done = true;
         Print("[SL HIT] ", LevelName(L), " ", Side(leg), " ", g_Symbol, " price=", Px(exitPrice),
               " (", leg.slHits, "/", InpMaxSLHits, ") - session khatam, reentry nahi hogi.");
         return;
        }

      leg.lastPrice = LegPrice(leg);
      Print("[SL HIT] ", LevelName(L), " ", Side(leg), " ", g_Symbol, " price=", Px(exitPrice),
            " (", leg.slHits, "/", InpMaxSLHits, ") - reentry ka wait @ ", Px(g_Level[L].entry));
      return;
     }

   leg.done = true;
   if(isTP)
      Print("[TP HIT] ", LevelName(L), " ", Side(leg), " ", g_Symbol, " price=", Px(exitPrice),
            " - ye leg complete, reentry nahi hogi.");
   else
      Print("[LEG DONE] ", LevelName(L), " ", Side(leg), " ", g_Symbol, " - manual/other close, reentry nahi hogi.");
  }
//+------------------------------------------------------------------+
