//+------------------------------------------------------------------+
//|                                              TrendingEA100_LVN.mq5|
//| LVN Hedge + Loop Reentry EA (v9)                                  |
//|                                                                   |
//| Logic:                                                            |
//|  - Session (New York local time, US DST apni aap handle hota hai) |
//|    shuru hote hi volume profile se LVN (Low Volume Node) nikalte  |
//|    hain:                                                          |
//|       SUPPORT LVN    = price ke NICHE sabse paas wala valid LVN   |
//|       RESISTANCE LVN = price ke UPAR sabse paas wala valid LVN    |
//|  - Candle S/R filter: M5, M15, M30, M45, H1 ke candle swing       |
//|    high/low (support/resistance) ke paas jo LVN ho, use skip      |
//|    karke agla LVN liya jata hai.                                  |
//|  - ADX filter: LVN touch par entry tabhi jab ADX > 25 ho aur      |
//|    lagaataar badh raha ho.                                        |
//|  - Entry par BUY + SELL dono (same lot, default 0.40).            |
//|  - Har leg: loop SL = fill se $1.4, TP = fill se $10. SL hit ->   |
//|    price wapas LVN par aaye (aur ADX filter pass ho) toh leg      |
//|    dobara khulti hai (reentry).                                   |
//|  - Kisi leg ka SL InpMaxSLHits (7) se zyada baar hit ho jaye toh  |
//|    wo leg hamesha ke liye band.                                   |
//|  - Entry/reentry sirf session window me. Window ke baad khuli     |
//|    positions apne SL/TP par chalti hain.                          |
//|                                                                   |
//| ZAROORI: Account HEDGING type ka hona chahiye.                    |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "9.00"
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

input group "=== Session (New York local time, DST auto) ==="
input string InpSessionStartNY   = "08:00";     // New York session start (NY local, HH:MM)
input string InpSessionEndNY     = "17:00";     // New York session end   (NY local, HH:MM)

input group "=== LVN (Volume Profile) ==="
input ENUM_TIMEFRAMES InpProfileTF = PERIOD_M5; // Profile kis timeframe ke bars se bane
input int    InpProfileDays      = 5;           // Kitne din (24h) ke bars ka profile
input double InpBinSize          = 1.0;         // Price bin size (price units)
input int    InpSmoothBins       = 2;           // Profile smoothing (+/- bins)
input int    InpNodeWindowBins   = 5;           // Local minimum window (+/- bins)
input int    InpPeakWindowBins   = 15;          // Valley ke dono taraf peak dhundhne ki window (bins)
input double InpLVNDepth         = 0.6;         // Valley volume <= is ratio x chhota neighbouring peak (kam = zyada gehra LVN)
input double InpMinLevelDistance = 2.0;         // LVN current price se kam se kam itna door ho

input group "=== Candle S/R filter (M5, M15, M30, M45, H1) ==="
input bool   InpUseSRFilter      = true;        // true: candle S/R ke paas wale LVN par entry nahi
input int    InpSRLookbackBars   = 100;         // Har timeframe ke kitne closed candles dekhne hain
input int    InpSRSwingBars      = 3;           // Swing high/low: apne +/- itne candles me sabse bada/chhota
input double InpSRTolerance      = 0.5;         // LVN is S/R level se itna paas ho toh "S/R par" maana jayega (price units)

input group "=== ADX filter ==="
input bool   InpUseADXFilter     = true;        // true: entry tabhi jab ADX > Min aur lagaataar badh raha ho
input ENUM_TIMEFRAMES InpADXTF   = PERIOD_M15;  // ADX kis timeframe par
input int    InpADXPeriod        = 14;          // ADX period
input double InpADXMin           = 25.0;        // ADX is se upar ho
input int    InpADXRisingBars    = 3;           // Itne closed bars lagaataar badhe (ADX[1]>ADX[2]>...)

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
   bool   triggered;     // pehli touch (ADX pass ke saath) ho chuki
   double entry;         // LVN price
   double lastPrice;     // pehli touch detect karne ke liye (mid price)
   long   magic;
  };

string     g_Symbol;
int        g_SessStartMin = 0;
int        g_SessEndMin   = 0;
bool       g_InSession    = false;
bool       g_NYDST        = false;     // US DST abhi chal raha hai?
int        g_NYNowMin     = 0;         // New York local time (minutes since midnight)
long       g_NYDay        = 0;         // New York local din ka number
long       g_ComputedDay  = -1;
long       g_ErrLoggedDay = -1;
ulong      g_NextComputeTryMs = 0;

int        g_ADXHandle    = INVALID_HANDLE;
datetime   g_LastADXLog[2];

double     g_SRPrice[];                // candle S/R levels (sab timeframes)
string     g_SRName[];                 // har level ka timeframe naam

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

   if(InpSRLookbackBars < 20 || InpSRSwingBars < 1 || InpSRTolerance < 0)
     {
      Print("[FATAL] S/R inputs galat hain (lookback>=20, swing>=1, tolerance>=0).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpADXPeriod < 1 || InpADXRisingBars < 1 || InpADXMin < 0)
     {
      Print("[FATAL] ADX inputs galat hain (period>=1, rising bars>=1, min>=0).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_SessStartMin = ParseHHMM(InpSessionStartNY);
   g_SessEndMin   = ParseHHMM(InpSessionEndNY);
   if(g_SessStartMin < 0 || g_SessEndMin < 0 || g_SessStartMin >= g_SessEndMin)
     {
      Print("[FATAL] Session time galat. Format HH:MM aur start < end hona chahiye (same din, New York time).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_Symbol = (InpSymbol == "") ? _Symbol : InpSymbol;
   if(!SymbolSelect(g_Symbol, true))
     {
      Print("[FATAL] Symbol Market Watch me nahi mila: '", g_Symbol, "'");
      return(INIT_FAILED);
     }

   if(InpUseADXFilter)
     {
      g_ADXHandle = iADX(g_Symbol, InpADXTF, InpADXPeriod);
      if(g_ADXHandle == INVALID_HANDLE)
        {
         Print("[FATAL] ADX indicator handle nahi ban paya. Error: ", GetLastError());
         return(INIT_FAILED);
        }
     }

   trade.SetDeviationInPoints(InpSlippagePoints);

   g_LastADXLog[0] = 0;
   g_LastADXLog[1] = 0;

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
   if(g_ADXHandle != INVALID_HANDLE)
      IndicatorRelease(g_ADXHandle);

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

   if(g_InSession && g_ComputedDay != g_NYDay)
      TryArmSession();

   ManageLevel(0);
   ManageLevel(1);
  }

//+------------------------------------------------------------------+
//| US DST (New York): 2nd Sunday of March 02:00 EST (07:00 UTC)      |
//| se 1st Sunday of November 02:00 EDT (06:00 UTC) tak.              |
//+------------------------------------------------------------------+
datetime MakeTime(int y, int m, int d, int hh)
  {
   MqlDateTime s;
   s.year        = y;
   s.mon         = m;
   s.day         = d;
   s.hour        = hh;
   s.min         = 0;
   s.sec         = 0;
   s.day_of_week = 0;
   s.day_of_year = 0;
   return StructToTime(s);
  }

int DayOfWeekOf(int y, int m, int d)
  {
   MqlDateTime s;
   TimeToStruct(MakeTime(y, m, d, 0), s);
   return s.day_of_week;   // 0 = Sunday
  }

bool IsUSDST(datetime utc)
  {
   MqlDateTime dt;
   TimeToStruct(utc, dt);
   int y = dt.year;

   int dowMar       = DayOfWeekOf(y, 3, 1);
   int secondSunMar = 1 + (7 - dowMar) % 7 + 7;
   int dowNov       = DayOfWeekOf(y, 11, 1);
   int firstSunNov  = 1 + (7 - dowNov) % 7;

   datetime dstStart = MakeTime(y, 3, secondSunMar, 7);   // 02:00 EST
   datetime dstEnd   = MakeTime(y, 11, firstSunNov, 6);   // 02:00 EDT

   return (utc >= dstStart && utc < dstEnd);
  }

//+------------------------------------------------------------------+
//| New York local time = GMT - 4h (EDT) ya GMT - 5h (EST).           |
//| TimeGMT() PC/VPS ki clock se banta hai, isliye uska time sahi     |
//| hona chahiye. NY local Sat/Sun ko session nahi.                   |
//+------------------------------------------------------------------+
bool IsInSession()
  {
   datetime utc = TimeGMT();
   g_NYDST = IsUSDST(utc);

   long ny = (long)utc + (g_NYDST ? -4 * 3600 : -5 * 3600);
   g_NYDay    = ny / 86400;
   g_NYNowMin = (int)((ny % 86400) / 60);

   MqlDateTime dt;
   TimeToStruct((datetime)ny, dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;

   return (g_NYNowMin >= g_SessStartMin && g_NYNowMin < g_SessEndMin);
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
      if(g_ErrLoggedDay != g_NYDay)
        {
         LogErr("LVN calculate nahi ho paya: " + why);
         g_ErrLoggedDay = g_NYDay;
        }
      return;
     }

   g_ComputedDay = g_NYDay;

   Print("[SESSION] New York session | NY time ", StringFormat("%02d:%02d", g_NYNowMin / 60, g_NYNowMin % 60),
         (g_NYDST ? " EDT (UTC-4, DST ON)" : " EST (UTC-5, DST OFF)"),
         " | window ", InpSessionStartNY, "-", InpSessionEndNY, " NY");

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
//| Candle S/R: swing high/low (pivot) levels                         |
//+------------------------------------------------------------------+
void PushSR(double price, string name)
  {
   int n = ArraySize(g_SRPrice);
   ArrayResize(g_SRPrice, n + 1);
   ArrayResize(g_SRName,  n + 1);
   g_SRPrice[n] = price;
   g_SRName[n]  = name;
  }

// r[] chronological (purana -> naya). Swing high = apne +/-K candles me sabse upar high,
// swing low = apne +/-K candles me sabse neeche low.
void AddPivots(MqlRates &r[], int n, string name)
  {
   int K = InpSRSwingBars;
   for(int i = K; i < n - K; i++)
     {
      bool isHigh = true;
      bool isLow  = true;
      for(int j = i - K; j <= i + K; j++)
        {
         if(j == i)
            continue;
         if(j < i)
           {
            if(r[j].high >= r[i].high)
               isHigh = false;
            if(r[j].low <= r[i].low)
               isLow = false;
           }
         else
           {
            if(r[j].high > r[i].high)
               isHigh = false;
            if(r[j].low < r[i].low)
               isLow = false;
           }
        }
      if(isHigh)
         PushSR(r[i].high, name);
      if(isLow)
         PushSR(r[i].low, name);
     }
  }

// MT5 me 45 minute ka timeframe nahi hota, isliye M5 bars ko 45-minute buckets me jodte hain
// (bucket = server time / 2700 sec, har din ke start se aligned).
bool BuildM45Pivots()
  {
   int need = (InpSRLookbackBars + 4) * 9 + 18;
   MqlRates m5[];
   int got = CopyRates(g_Symbol, PERIOD_M5, 1, need, m5);
   if(got < 60)
      return false;

   MqlRates b45[];
   int  nb         = 0;
   long lastBucket = -1;

   for(int i = 0; i < got; i++)
     {
      long bk = (long)m5[i].time / 2700;
      if(bk != lastBucket)
        {
         ArrayResize(b45, nb + 1);
         b45[nb].time = (datetime)(bk * 2700);
         b45[nb].high = m5[i].high;
         b45[nb].low  = m5[i].low;
         nb++;
         lastBucket = bk;
        }
      else
        {
         if(m5[i].high > b45[nb - 1].high)
            b45[nb - 1].high = m5[i].high;
         if(m5[i].low < b45[nb - 1].low)
            b45[nb - 1].low = m5[i].low;
        }
     }

   // Pehla bucket (adhura ho sakta hai) aur abhi chal raha bucket hata do
   long curBucket = (long)TimeCurrent() / 2700;
   int  startIdx  = 1;
   int  endIdx    = (lastBucket >= curBucket) ? nb - 2 : nb - 1;
   if(endIdx - startIdx + 1 > InpSRLookbackBars)
      startIdx = endIdx - InpSRLookbackBars + 1;

   int cnt = endIdx - startIdx + 1;
   if(cnt < 2 * InpSRSwingBars + 3)
      return false;

   MqlRates c45[];
   ArrayResize(c45, cnt);
   for(int k = 0; k < cnt; k++)
      c45[k] = b45[startIdx + k];

   AddPivots(c45, cnt, "M45");
   return true;
  }

// Sab timeframes ke S/R levels g_SRPrice[] me bharta hai. Return = kitne timeframes ka data mila (max 5).
int BuildSRLevels()
  {
   ArrayResize(g_SRPrice, 0);
   ArrayResize(g_SRName, 0);

   ENUM_TIMEFRAMES tfs[4]   = {PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1};
   string          names[4] = {"M5", "M15", "M30", "H1"};

   int okTF = 0;
   for(int t = 0; t < 4; t++)
     {
      MqlRates r[];
      int got = CopyRates(g_Symbol, tfs[t], 1, InpSRLookbackBars, r);   // start=1 -> chalti candle shamil nahi
      if(got < 2 * InpSRSwingBars + 3)
         continue;
      AddPivots(r, got, names[t]);
      okTF++;
     }

   if(BuildM45Pivots())
      okTF++;

   return okTF;
  }

bool NearSR(double price, string &which)
  {
   int n = ArraySize(g_SRPrice);
   for(int i = 0; i < n; i++)
     {
      if(MathAbs(price - g_SRPrice[i]) <= InpSRTolerance)
        {
         which = g_SRName[i] + " candle S/R " + Px(g_SRPrice[i]) + " ke paas";
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Volume profile (tick volume, bar ke high-low range me barabar     |
//| baanta hua) -> smooth -> local minimum + valley depth se LVN.     |
//| Candle S/R ke paas wale LVN hata kar: Support = price ke neeche   |
//| sabse paas wala, Resistance = upar sabse paas wala.               |
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

   // ---- LVN candidates: local minimum + valley depth ----
   int    digits = (int)SymbolInfoInteger(g_Symbol, SYMBOL_DIGITS);
   double suppC[];
   double resC[];
   int    nS = 0;
   int    nR = 0;

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
         ArrayResize(suppC, nS + 1);
         suppC[nS] = lvnPrice;
         nS++;
        }
      else if(lvnPrice >= curPrice + InpMinLevelDistance)
        {
         ArrayResize(resC, nR + 1);
         resC[nR] = lvnPrice;
         nR++;
        }
     }

   // ---- Candle S/R filter ----
   bool useSR = InpUseSRFilter;
   if(useSR)
     {
      int okTF = BuildSRLevels();
      if(okTF == 0)
        {
         why = "candle S/R ka data nahi mila (history load hone do)";
         return false;
        }
     }

   double bestS = 0;
   double bestR = 0;
   string which = "";

   if(nS > 0)
     {
      ArraySort(suppC);   // ascending -> sabse paas wala (sabse bada) peeche se
      for(int a = nS - 1; a >= 0; a--)
        {
         double c = NormalizeDouble(suppC[a], digits);
         if(useSR && NearSR(c, which))
           {
            Print("[LVN] SUPPORT LVN ", Px(c), " skip - ", which);
            continue;
           }
         bestS = c;
         break;
        }
     }

   if(nR > 0)
     {
      ArraySort(resC);    // ascending -> sabse paas wala (sabse chhota) shuru se
      for(int a = 0; a < nR; a++)
        {
         double c = NormalizeDouble(resC[a], digits);
         if(useSR && NearSR(c, which))
           {
            Print("[LVN] RESISTANCE LVN ", Px(c), " skip - ", which);
            continue;
           }
         bestR = c;
         break;
        }
     }

   support    = bestS;
   resistance = bestR;
   return true;
  }

//+------------------------------------------------------------------+
//| ADX filter: ADX > InpADXMin aur InpADXRisingBars closed bars      |
//| lagaataar badh raha ho.                                           |
//+------------------------------------------------------------------+
bool ADXAllows(string &info)
  {
   info = "";
   if(!InpUseADXFilter)
      return true;

   int    need = InpADXRisingBars + 1;
   double adx[];
   ArraySetAsSeries(adx, true);   // adx[0] = sabse recent closed bar
   if(CopyBuffer(g_ADXHandle, 0, 1, need, adx) < need)
     {
      info = "ADX data abhi ready nahi";
      return false;
     }

   bool above  = (adx[0] > InpADXMin);
   bool rising = true;
   for(int k = 0; k < InpADXRisingBars; k++)
     {
      if(!(adx[k] > adx[k + 1]))
        {
         rising = false;
         break;
        }
     }

   info = "ADX=" + DoubleToString(adx[0], 1) +
          " (min " + DoubleToString(InpADXMin, 0) + (above ? " OK" : " FAIL") + ")" +
          ", " + IntegerToString(InpADXRisingBars) + " bar rising" + (rising ? " OK" : " FAIL");

   return (above && rising);
  }

void LogADXSkip(int L, string what, string info)
  {
   datetime now = TimeCurrent();
   if((long)now - (long)g_LastADXLog[L] < 30)
      return;   // spam rokne ke liye har level ke liye 30 sec me ek hi baar
   g_LastADXLog[L] = now;
   Print("[ADX] ", LevelName(L), " ", what, " @ LVN ", Px(g_Level[L].entry), " touch hua par entry skip - ", info);
  }

//+------------------------------------------------------------------+
//| Ek level ka poora kaam: pehli touch (ADX pass) -> dono legs ->    |
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

      // LVN par aa gaye -> ADX filter pass ho toh turant entry, warna level armed rehta hai (agli touch ka wait)
      string adxInfo;
      if(!ADXAllows(adxInfo))
        {
         LogADXSkip(L, "entry", adxInfo);
         return;
        }

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
//| Flat leg: price (BUY=ASK, SELL=BID) LVN par wapas aaye aur ADX    |
//| filter pass ho toh reentry                                        |
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

   if(!touched)
      return;

   string adxInfo;
   if(!ADXAllows(adxInfo))
     {
      LogADXSkip(L, Side(leg) + " reentry", adxInfo);
      return;
     }

   leg.wantOpen = true;
   leg.attempts = 0;
   TryOpenLeg(L, leg, other);
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
