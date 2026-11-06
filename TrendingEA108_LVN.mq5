//+------------------------------------------------------------------+
//|                                              TrendingEA100_LVN.mq5|
//| LVN Hedge + Loop Reentry EA (v10) - XAUUSD + XAGUSD               |
//|                                                                   |
//| Logic (har symbol ke liye alag-alag):                             |
//|  - Session (New York local time, US DST auto) shuru hote hi       |
//|    volume profile se LVN (Low Volume Node) nikalte hain:          |
//|       SUPPORT LVN    = price ke NICHE sabse paas wala valid LVN   |
//|       RESISTANCE LVN = price ke UPAR sabse paas wala valid LVN    |
//|  - Candle S/R filter: M5, M15, M30, M45, H1 ke candle swing       |
//|    high/low ke paas jo LVN ho, use skip karke agla LVN liya jata. |
//|  - LVN touch par BUY + SELL dono (same lot, default 0.40).        |
//|  - XAUUSD: SL = $1.4, TP = $10 (fixed price distance).            |
//|  - XAGUSD: SL = entry price ka 0.070%, TP = entry price ka        |
//|    0.500% (lumpsum percent).                                      |
//|  - SL hit -> price wapas LVN par aaye toh leg dobara khulti hai   |
//|    (reentry). Kisi leg ka SL InpMaxSLHits (7) se zyada baar hit   |
//|    ho jaye toh wo leg hamesha ke liye band.                       |
//|  - Entry/reentry sirf session window me. Window ke baad khuli     |
//|    positions apne SL/TP par chalti hain.                          |
//|                                                                   |
//| ZAROORI: Account HEDGING type ka hona chahiye.                    |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "10.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//----------------- INPUTS -----------------
input group "=== Symbols ==="
input bool   InpTradeXAU         = true;        // XAUUSD trade karo
input string InpXAUSymbol        = "XAUUSD";    // Broker ka gold symbol (suffix ho toh yahan likho, e.g. XAUUSDm)
input bool   InpTradeXAG         = true;        // XAGUSD trade karo
input string InpXAGSymbol        = "XAGUSD";    // Broker ka silver symbol (suffix ho toh yahan likho, e.g. XAGUSDm)

input group "=== Trade (dono symbols ke liye) ==="
input double InpLotSize          = 0.40;        // Har leg ka lot (XAU aur XAG, BUY aur SELL sab same)
input int    InpMaxSLHits        = 7;           // Ek leg ka SL is se ZYADA baar hit ho toh wo leg band (8vi baar par)
input bool   InpSendSLToBroker   = true;        // true: SL broker ko bhi bheja jata hai. Reject ho toh EA khud monitor karega

input group "=== XAUUSD SL/TP (price units, gold me $1 = 1.00) ==="
input double InpSLDollars        = 1.4;         // Loop SL distance - fill price se
input double InpTPDollars        = 10.0;        // TP distance - fill price se

input group "=== XAGUSD SL/TP (entry price ka %) ==="
input double InpXAGSLPercent     = 0.070;       // SL = entry price ka itna % (0.070 = 0.070%)
input double InpXAGTPPercent     = 0.500;       // TP = entry price ka itna % (0.500 = 0.500%)

input group "=== Session (New York local time, DST auto) ==="
input string InpSessionStartNY   = "08:00";     // New York session start (NY local, HH:MM)
input string InpSessionEndNY     = "17:00";     // New York session end   (NY local, HH:MM)

input group "=== LVN (Volume Profile) - dono symbols ke liye common ==="
input ENUM_TIMEFRAMES InpProfileTF = PERIOD_M5; // Profile kis timeframe ke bars se bane
input int    InpProfileDays      = 5;           // Kitne din (24h) ke bars ka profile
input int    InpSmoothBins       = 2;           // Profile smoothing (+/- bins)
input int    InpNodeWindowBins   = 5;           // Local minimum window (+/- bins)
input int    InpPeakWindowBins   = 15;          // Valley ke dono taraf peak dhundhne ki window (bins)
input double InpLVNDepth         = 0.6;         // Valley volume <= is ratio x chhota neighbouring peak (kam = zyada gehra LVN)

input group "=== LVN scale: XAUUSD (price units) ==="
input double InpBinSize          = 1.0;         // Price bin size
input double InpMinLevelDistance = 2.0;         // LVN current price se kam se kam itna door ho
input double InpSRTolerance      = 0.5;         // LVN candle S/R se itna paas ho toh "S/R par" maana jayega

input group "=== LVN scale: XAGUSD (price ka %, price ke hisaab se khud scale hota hai) ==="
input double InpXAGBinPercent    = 0.040;       // Price bin size (% of price)
input double InpXAGMinDistPercent= 0.080;       // LVN current price se kam se kam itna door (% of price)
input double InpXAGSRTolPercent  = 0.020;       // Candle S/R tolerance (% of price)

input group "=== Candle S/R filter (M5, M15, M30, M45, H1) ==="
input bool   InpUseSRFilter      = true;        // true: candle S/R ke paas wale LVN par entry nahi
input int    InpSRLookbackBars   = 100;         // Har timeframe ke kitne closed candles dekhne hain
input int    InpSRSwingBars      = 3;           // Swing high/low: apne +/- itne candles me sabse bada/chhota

input group "=== Execution ==="
input int    InpSlippagePoints   = 20;          // Slippage (points)
input long   InpMagicNumber      = 20260708;    // Base magic (har symbol/level ke liye base + 0..3)
input int    InpMaxSpreadPoints  = 100;         // XAUUSD: is se zyada spread par entry/reentry skip (agla tick retry)
input int    InpXAGMaxSpreadPoints = 100;       // XAGUSD: is se zyada spread par entry/reentry skip (agla tick retry)
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

struct SlotSetup          // slot = ek symbol ka ek level (support ya resistance)
  {
   bool   active;
   bool   triggered;      // pehli touch ho chuki
   bool   isSupport;
   int    symIdx;         // 0 = XAUUSD, 1 = XAGUSD
   string symbol;
   double entry;          // LVN price
   double lastPrice;      // pehli touch detect karne ke liye (mid price)
   long   magic;
  };

string     g_SymName[2];
bool       g_SymEnabled[2];
long       g_ComputedDay[2];
long       g_ErrLoggedDay[2];
ulong      g_NextComputeTryMs[2];

int        g_SessStartMin = 0;
int        g_SessEndMin   = 0;
bool       g_InSession    = false;
bool       g_NYDST        = false;     // US DST abhi chal raha hai?
int        g_NYNowMin     = 0;         // New York local time (minutes since midnight)
long       g_NYDay        = 0;         // New York local din ka number
long       g_SessionLoggedDay = -1;

double     g_SRPrice[];                // candle S/R levels (ek symbol ke sab timeframes)
string     g_SRName[];                 // har level ka timeframe naam

SlotSetup  g_Slot[4];    // slot = symIdx*2 + (support ? 0 : 1)
HedgeLeg   g_Leg[8];     // index = slot*2 + (BUY ? 0 : 1)

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
void LogErr(string msg)
  {
   if(InpLogErrors)
      Print("[ERROR] ", msg);
  }

string PxS(string symbol, double value)
  {
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return DoubleToString(value, digits);
  }

string SlotName(int s)
  {
   return g_Slot[s].symbol + " " + (g_Slot[s].isSupport ? "SUPPORT" : "RESISTANCE");
  }

string Side(HedgeLeg &leg)
  {
   return leg.isBuy ? "BUY" : "SELL";
  }

double LegPrice(int s, HedgeLeg &leg)
  {
   return leg.isBuy ? SymbolInfoDouble(g_Slot[s].symbol, SYMBOL_ASK)
                    : SymbolInfoDouble(g_Slot[s].symbol, SYMBOL_BID);
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

//--- Symbol-wise parameters (symIdx 0 = XAUUSD absolute, 1 = XAGUSD percent-of-price) ---
bool IsXAG(int symIdx)
  {
   return (symIdx == 1);
  }

double SLDistance(int symIdx, double refPrice)
  {
   return IsXAG(symIdx) ? refPrice * InpXAGSLPercent / 100.0 : InpSLDollars;
  }

double TPDistance(int symIdx, double refPrice)
  {
   return IsXAG(symIdx) ? refPrice * InpXAGTPPercent / 100.0 : InpTPDollars;
  }

double BinSizeFor(int symIdx, double price)
  {
   return IsXAG(symIdx) ? price * InpXAGBinPercent / 100.0 : InpBinSize;
  }

double MinLevelDistFor(int symIdx, double price)
  {
   return IsXAG(symIdx) ? price * InpXAGMinDistPercent / 100.0 : InpMinLevelDistance;
  }

double SRTolFor(int symIdx, double price)
  {
   return IsXAG(symIdx) ? price * InpXAGSRTolPercent / 100.0 : InpSRTolerance;
  }

int MaxSpreadFor(int symIdx)
  {
   return IsXAG(symIdx) ? InpXAGMaxSpreadPoints : InpMaxSpreadPoints;
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

   if(InpXAGSLPercent <= 0 || InpXAGTPPercent <= 0)
     {
      Print("[FATAL] InpXAGSLPercent / InpXAGTPPercent 0 se bade hone chahiye.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpBinSize <= 0 || InpXAGBinPercent <= 0 || InpSmoothBins < 0 || InpNodeWindowBins < 1 || InpPeakWindowBins < 1 ||
      InpLVNDepth <= 0 || InpLVNDepth > 1 || InpProfileDays < 1 || InpMinLevelDistance < 0 || InpXAGMinDistPercent < 0)
     {
      Print("[FATAL] LVN inputs galat hain (bin>0, windows>=1, 0<depth<=1, days>=1).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpSRLookbackBars < 20 || InpSRSwingBars < 1 || InpSRTolerance < 0 || InpXAGSRTolPercent < 0)
     {
      Print("[FATAL] S/R inputs galat hain (lookback>=20, swing>=1, tolerance>=0).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_SessStartMin = ParseHHMM(InpSessionStartNY);
   g_SessEndMin   = ParseHHMM(InpSessionEndNY);
   if(g_SessStartMin < 0 || g_SessEndMin < 0 || g_SessStartMin >= g_SessEndMin)
     {
      Print("[FATAL] Session time galat. Format HH:MM aur start < end hona chahiye (same din, New York time).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_SymName[0]    = InpXAUSymbol;
   g_SymName[1]    = InpXAGSymbol;
   g_SymEnabled[0] = InpTradeXAU;
   g_SymEnabled[1] = InpTradeXAG;

   int enabledCount = 0;
   for(int y = 0; y < 2; y++)
     {
      g_ComputedDay[y]       = -1;
      g_ErrLoggedDay[y]      = -1;
      g_NextComputeTryMs[y]  = 0;

      if(!g_SymEnabled[y])
         continue;

      if(!SymbolSelect(g_SymName[y], true))
        {
         Print("[ERROR] Symbol Market Watch me nahi mila: '", g_SymName[y], "' - ye symbol disable kar diya.");
         g_SymEnabled[y] = false;
         continue;
        }
      enabledCount++;
     }

   if(enabledCount == 0)
     {
      Print("[FATAL] Koi bhi symbol enable nahi hai (symbol naam / suffix check karo).");
      return(INIT_FAILED);
     }

   trade.SetDeviationInPoints(InpSlippagePoints);

   for(int s = 0; s < 4; s++)
     {
      int y = s / 2;
      g_Slot[s].active    = false;
      g_Slot[s].triggered = false;
      g_Slot[s].isSupport = (s % 2 == 0);
      g_Slot[s].symIdx    = y;
      g_Slot[s].symbol    = g_SymName[y];
      g_Slot[s].entry     = 0;
      g_Slot[s].lastPrice = 0;
      g_Slot[s].magic     = InpMagicNumber + s;
      ResetLeg(g_Leg[s * 2],     true);
      ResetLeg(g_Leg[s * 2 + 1], false);
     }

   EventSetMillisecondTimer(InpPriceCheckMillis);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();

   for(int i = 0; i < 8; i++)
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

   if(g_InSession)
     {
      for(int y = 0; y < 2; y++)
        {
         if(g_SymEnabled[y] && g_ComputedDay[y] != g_NYDay)
            TryArmSession(y);
        }
     }

   for(int s = 0; s < 4; s++)
      ManageSlot(s);
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
//| Session ke din me ek baar (har symbol ke liye): LVN nikalo aur    |
//| us symbol ke dono levels arm karo                                 |
//+------------------------------------------------------------------+
void TryArmSession(int symIdx)
  {
   ulong nowMs = GetTickCount64();
   if(nowMs < g_NextComputeTryMs[symIdx])
      return;
   g_NextComputeTryMs[symIdx] = nowMs + 10000;   // fail hone par 10 sec baad retry

   string symbol = g_SymName[symIdx];

   double support = 0, resistance = 0, price = 0;
   string why = "";
   if(!ComputeLVN(symIdx, support, resistance, price, why))
     {
      if(g_ErrLoggedDay[symIdx] != g_NYDay)
        {
         LogErr(symbol + " LVN calculate nahi ho paya: " + why);
         g_ErrLoggedDay[symIdx] = g_NYDay;
        }
      return;
     }

   g_ComputedDay[symIdx] = g_NYDay;

   if(g_SessionLoggedDay != g_NYDay)
     {
      g_SessionLoggedDay = g_NYDay;
      Print("[SESSION] New York session | NY time ", StringFormat("%02d:%02d", g_NYNowMin / 60, g_NYNowMin % 60),
            (g_NYDST ? " EDT (UTC-4, DST ON)" : " EST (UTC-5, DST OFF)"),
            " | window ", InpSessionStartNY, "-", InpSessionEndNY, " NY");
     }

   Print("[LVN] ", symbol, " price=", PxS(symbol, price),
         " | Support LVN=",    (support > 0    ? PxS(symbol, support)    : "nahi mila"),
         " | Resistance LVN=", (resistance > 0 ? PxS(symbol, resistance) : "nahi mila"));

   ArmSlot(symIdx * 2,     support,    price);
   ArmSlot(symIdx * 2 + 1, resistance, price);
  }

//+------------------------------------------------------------------+
void ArmSlot(int s, double level, double price)
  {
   if(level <= 0)
      return;

   // Is level ka pichhla trade khuli position ke saath chal raha hai -> disturb nahi karte
   if(g_Slot[s].active && (g_Leg[s * 2].opened || g_Leg[s * 2 + 1].opened))
     {
      Print("[LVN] ", SlotName(s), " level skip - pichhla trade abhi khuli position ke saath chal raha hai.");
      return;
     }

   ResetLeg(g_Leg[s * 2],     true);
   ResetLeg(g_Leg[s * 2 + 1], false);

   g_Slot[s].active    = true;
   g_Slot[s].triggered = false;
   g_Slot[s].entry     = level;
   g_Slot[s].lastPrice = price;
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
bool BuildM45Pivots(string symbol)
  {
   int need = (InpSRLookbackBars + 4) * 9 + 18;
   MqlRates m5[];
   int got = CopyRates(symbol, PERIOD_M5, 1, need, m5);
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
int BuildSRLevels(string symbol)
  {
   ArrayResize(g_SRPrice, 0);
   ArrayResize(g_SRName, 0);

   ENUM_TIMEFRAMES tfs[4]   = {PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1};
   string          names[4] = {"M5", "M15", "M30", "H1"};

   int okTF = 0;
   for(int t = 0; t < 4; t++)
     {
      MqlRates r[];
      int got = CopyRates(symbol, tfs[t], 1, InpSRLookbackBars, r);   // start=1 -> chalti candle shamil nahi
      if(got < 2 * InpSRSwingBars + 3)
         continue;
      AddPivots(r, got, names[t]);
      okTF++;
     }

   if(BuildM45Pivots(symbol))
      okTF++;

   return okTF;
  }

bool NearSR(string symbol, double price, double tol, string &which)
  {
   int n = ArraySize(g_SRPrice);
   for(int i = 0; i < n; i++)
     {
      if(MathAbs(price - g_SRPrice[i]) <= tol)
        {
         which = g_SRName[i] + " candle S/R " + PxS(symbol, g_SRPrice[i]) + " ke paas";
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
bool ComputeLVN(int symIdx, double &support, double &resistance, double &curPrice, string &why)
  {
   support    = 0;
   resistance = 0;

   string symbol = g_SymName[symIdx];

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick) || tick.bid <= 0 || tick.ask <= 0)
     {
      why = "current price nahi mili";
      return false;
     }
   curPrice = (tick.bid + tick.ask) / 2.0;

   double bin     = BinSizeFor(symIdx, curPrice);
   double minDist = MinLevelDistFor(symIdx, curPrice);
   double srTol   = SRTolFor(symIdx, curPrice);

   int secs  = PeriodSeconds(InpProfileTF);
   int count = (int)MathMax(100.0, (double)InpProfileDays * 86400.0 / (double)secs);

   MqlRates rates[];
   int got = CopyRates(symbol, InpProfileTF, 0, count, rates);
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

   int n = (int)MathFloor((maxP - minP) / bin) + 1;
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
      int i0 = (int)MathFloor((rates[k].low  - minP) / bin);
      int i1 = (int)MathFloor((rates[k].high - minP) / bin);
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
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
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

      double lvnPrice = minP + ((double)i + 0.5) * bin;

      if(lvnPrice <= curPrice - minDist)
        {
         ArrayResize(suppC, nS + 1);
         suppC[nS] = lvnPrice;
         nS++;
        }
      else if(lvnPrice >= curPrice + minDist)
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
      int okTF = BuildSRLevels(symbol);
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
         if(useSR && NearSR(symbol, c, srTol, which))
           {
            Print("[LVN] ", symbol, " SUPPORT LVN ", PxS(symbol, c), " skip - ", which);
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
         if(useSR && NearSR(symbol, c, srTol, which))
           {
            Print("[LVN] ", symbol, " RESISTANCE LVN ", PxS(symbol, c), " skip - ", which);
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
//| Ek slot (symbol + level) ka poora kaam: pehli touch -> dono legs  |
//| -> dono legs done hone par slot khatam                            |
//+------------------------------------------------------------------+
void ManageSlot(int s)
  {
   if(!g_Slot[s].active)
      return;

   string symbol = g_Slot[s].symbol;

   if(!g_Slot[s].triggered)
     {
      // Session ke bahar armed (untouched) level hata do
      if(!g_InSession)
        {
         g_Slot[s].active = false;
         return;
        }

      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      if(bid <= 0 || ask <= 0)
         return;

      double mid = (bid + ask) / 2.0;
      if(g_Slot[s].lastPrice <= 0)
        {
         g_Slot[s].lastPrice = mid;
         return;
        }

      double point    = SymbolInfoDouble(symbol, SYMBOL_POINT);
      double diffPrev = g_Slot[s].lastPrice - g_Slot[s].entry;
      double diffNow  = mid - g_Slot[s].entry;

      bool touched = false;
      if(MathAbs(diffNow) <= point * 2)
         touched = true;
      else if(diffPrev == 0)
         touched = true;
      else if((diffPrev > 0 && diffNow < 0) || (diffPrev < 0 && diffNow > 0))
         touched = true;

      g_Slot[s].lastPrice = mid;

      if(!touched)
         return;

      g_Slot[s].triggered = true;
      g_Leg[s * 2].wantOpen     = true;
      g_Leg[s * 2].attempts     = 0;
      g_Leg[s * 2 + 1].wantOpen = true;
      g_Leg[s * 2 + 1].attempts = 0;
     }

   ProcessLeg(s, g_Leg[s * 2],     g_Leg[s * 2 + 1]);
   ProcessLeg(s, g_Leg[s * 2 + 1], g_Leg[s * 2]);

   if(g_Leg[s * 2].done && g_Leg[s * 2 + 1].done)
     {
      g_Slot[s].active    = false;
      g_Slot[s].triggered = false;
     }
  }

//+------------------------------------------------------------------+
//| Har leg ki states:                                                |
//|   opened   -> position monitor (SL / TP / close detect)           |
//|   session ke bahar flat -> leg done (nayi entry nahi)             |
//|   wantOpen -> order kholne ki koshish                             |
//|   baaki    -> flat, price ke wapas LVN par aane ka wait           |
//+------------------------------------------------------------------+
void ProcessLeg(int s, HedgeLeg &leg, HedgeLeg &other)
  {
   if(leg.done)
      return;

   if(leg.opened)
     {
      MonitorLeg(s, leg);
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
      TryOpenLeg(s, leg, other);
      return;
     }

   CheckReentryTouch(s, leg, other);
  }

//+------------------------------------------------------------------+
//| Flat leg: price (BUY=ASK, SELL=BID) LVN par wapas aaye toh        |
//| reentry                                                           |
//+------------------------------------------------------------------+
void CheckReentryTouch(int s, HedgeLeg &leg, HedgeLeg &other)
  {
   double price = LegPrice(s, leg);
   if(price <= 0)
      return;

   if(leg.lastPrice <= 0)
     {
      leg.lastPrice = price;
      return;
     }

   double point    = SymbolInfoDouble(g_Slot[s].symbol, SYMBOL_POINT);
   double diffPrev = leg.lastPrice - g_Slot[s].entry;
   double diffNow  = price - g_Slot[s].entry;

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

   leg.wantOpen = true;
   leg.attempts = 0;
   TryOpenLeg(s, leg, other);
  }

//+------------------------------------------------------------------+
void OpenFailed(int s, HedgeLeg &leg, string why)
  {
   leg.attempts++;
   if(leg.attempts == 1)
      LogErr(SlotName(s) + " " + Side(leg) + " order fail: " + why);

   if(leg.attempts >= InpMaxLegRetries)
     {
      LogErr(SlotName(s) + " " + Side(leg) + " " + IntegerToString(InpMaxLegRetries) +
             " attempts fail hue, agli touch ka wait karenge.");
      leg.wantOpen  = false;
      leg.attempts  = 0;
      leg.lastPrice = 0;
     }
  }

//+------------------------------------------------------------------+
ulong FindPositionTicket(string symbol, long magic, bool isBuy)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
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
//| XAUUSD: SL/TP fixed $ distance. XAGUSD: SL/TP entry price ka %.   |
//+------------------------------------------------------------------+
void TryOpenLeg(int s, HedgeLeg &leg, HedgeLeg &other)
  {
   string symbol = g_Slot[s].symbol;
   int    symIdx = g_Slot[s].symIdx;
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   // Spread gate. Pehli entry me dusri leg ko hedge complete karne ke liye turant kholte hain.
   bool completingHedge = (leg.entries == 0 && other.entries > 0);
   if(!completingHedge && SymbolInfoInteger(symbol, SYMBOL_SPREAD) > MaxSpreadFor(symIdx))
      return;

   double price = LegPrice(s, leg);
   if(price <= 0)
     {
      OpenFailed(s, leg, "valid price nahi mili");
      return;
     }

   double tpDist = TPDistance(symIdx, price);
   double tp     = leg.isBuy ? price + tpDist : price - tpDist;
   tp = NormalizeDouble(tp, digits);

   trade.SetExpertMagicNumber(g_Slot[s].magic);

   bool ok;
   if(leg.isBuy)
      ok = trade.Buy(InpLotSize, symbol, 0, 0, tp, "");
   else
      ok = trade.Sell(InpLotSize, symbol, 0, 0, tp, "");

   if(!ok)
     {
      OpenFailed(s, leg, "RetCode=" + IntegerToString((int)trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
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
      positionId = FindPositionTicket(symbol, g_Slot[s].magic, leg.isBuy);

   if(positionId == 0)
     {
      LogErr(SlotName(s) + " " + Side(leg) + " position khuli par ticket track nahi ho paya - is leg ko manually dekho.");
      leg.wantOpen = false;
      leg.done     = true;
      return;
     }

   if(PositionSelectByTicket(positionId))
      fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);

   double slDist = SLDistance(symIdx, fillPrice);

   leg.opened       = true;
   leg.wantOpen     = false;
   leg.attempts     = 0;
   leg.ticket       = positionId;
   leg.brokerSL     = false;
   leg.slClosing    = false;
   leg.historyTries = 0;
   leg.entries++;
   leg.slLevel      = NormalizeDouble(leg.isBuy ? fillPrice - slDist : fillPrice + slDist, digits);

   if(InpSendSLToBroker && trade.PositionModify(positionId, leg.slLevel, tp))
      leg.brokerSL = true;

   string tag;
   if(leg.entries == 1)
      tag = "[ENTRY]";
   else
      tag = "[REENTRY #" + IntegerToString(leg.entries - 1) + "]";

   Print(tag, " ", SlotName(s), " ", Side(leg), " lot=", DoubleToString(InpLotSize, 2),
         " price=", PxS(symbol, fillPrice), " SL=", PxS(symbol, leg.slLevel), " TP=", PxS(symbol, tp),
         " | LVN=", PxS(symbol, g_Slot[s].entry));
  }

//+------------------------------------------------------------------+
//| Khuli leg: position gayab ho gayi toh reason dekho, warna         |
//| broker SL na ho toh EA khud SL check kare                         |
//+------------------------------------------------------------------+
void MonitorLeg(int s, HedgeLeg &leg)
  {
   if(!PositionSelectByTicket(leg.ticket))
     {
      HandleLegClosed(s, leg);
      return;
     }

   if(leg.brokerSL)
      return;

   string symbol = g_Slot[s].symbol;

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
      HandleLegClosed(s, leg);
   else
     {
      leg.slClosing = false;
      LogErr(SlotName(s) + " " + Side(leg) + " SL close fail: RetCode=" +
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
void HandleLegClosed(int s, HedgeLeg &leg)
  {
   string symbol    = g_Slot[s].symbol;
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
      leg.slHits++;

      if(leg.slHits > InpMaxSLHits)
        {
         leg.done = true;
         Print("[LEG STOPPED] ", SlotName(s), " ", Side(leg), " price=", PxS(symbol, exitPrice),
               " - SL ", leg.slHits, " baar hit (limit ", InpMaxSLHits, "), ye trade ab continue nahi hoga.");
         return;
        }

      if(!g_InSession)
        {
         leg.done = true;
         Print("[SL HIT] ", SlotName(s), " ", Side(leg), " price=", PxS(symbol, exitPrice),
               " (", leg.slHits, "/", InpMaxSLHits, ") - session khatam, reentry nahi hogi.");
         return;
        }

      leg.lastPrice = LegPrice(s, leg);
      Print("[SL HIT] ", SlotName(s), " ", Side(leg), " price=", PxS(symbol, exitPrice),
            " (", leg.slHits, "/", InpMaxSLHits, ") - reentry ka wait @ ", PxS(symbol, g_Slot[s].entry));
      return;
     }

   leg.done = true;
   if(isTP)
      Print("[TP HIT] ", SlotName(s), " ", Side(leg), " price=", PxS(symbol, exitPrice),
            " - ye leg complete, reentry nahi hogi.");
   else
      Print("[LEG DONE] ", SlotName(s), " ", Side(leg), " - manual/other close, reentry nahi hogi.");
  }
//+------------------------------------------------------------------+
