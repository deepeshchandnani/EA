//+------------------------------------------------------------------+
//|                                              TrendingEA100_LVN.mq5|
//| LVN Hedge + Loop Reentry EA (v15) - sirf XAUUSD                   |
//|                                                                   |
//| Logic:                                                            |
//|  - NY session (US DST auto) shuru hote hi volume profile se LVN   |
//|    (Low Volume Node) nikalte hain, har 2 minute me dobara, jab    |
//|    tak aaj ka pehla trade shuru na ho:                            |
//|       SUPPORT LVN    = price ke NICHE sabse paas wala LVN         |
//|       RESISTANCE LVN = price ke UPAR sabse paas wala LVN          |
//|    Trade shuru hote hi us din ke liye LVN update band.            |
//|  - LVN touch par BUY + SELL dono. SL = $1.4, TP = $10.            |
//|  - SL hit -> price wapas LVN par aaye toh leg dobara khulti hai   |
//|    (reentry).                                                     |
//|  - Lot: shuru 0.40 (BUY aur SELL dono). Us level ke TOTAL SL      |
//|    (BUY + SELL milake) har 4 hit ke baad dono legs ka lot +0.40   |
//|    (0.40 -> 0.80 -> 1.20).                                        |
//|  - Total SL (BUY + SELL milake) 10 ho jaye toh us level ki trade  |
//|    aage nahi badhti: koi reentry nahi (jo leg khuli ho wo apne    |
//|    SL/TP tak chalti hai).                                         |
//|  - Entry/reentry sirf NY session window me. Window ke baad khuli  |
//|    positions apne SL/TP par chalti hain.                          |
//|  - SL WATCHDOG: har 200ms broker ki asli positions scan hoti hain.|
//|    Jis XAUUSD position par SL nahi, uspar default SL ($1.4) laga  |
//|    diya jata hai. Price pehle hi SL level paar kar chuka ho toh   |
//|    position turant close.                                         |
//|                                                                   |
//| ZAROORI: Account HEDGING type ka hona chahiye.                    |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "15.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//----------------- INPUTS -----------------
input group "=== Symbol ==="
input string InpSymbol           = "XAUUSD";    // Broker ka gold symbol (suffix ho toh yahan likho, e.g. XAUUSDm)

input group "=== Trade ==="
input double InpLotSize          = 0.40;        // Shuruaati lot (BUY aur SELL dono same)
input double InpLotStep          = 0.40;        // Har InpLotStepEverySL total SL (BUY+SELL milake) ke baad lot me itna badhao
input int    InpLotStepEverySL   = 4;           // Kitne total SL (BUY + SELL milake, is level ke) ke baad lot badhana hai
input int    InpMaxSLHits        = 10;          // Total SL (BUY + SELL milake, is level ke) itne ho jayein toh trade aage nahi badhegi (10th SL ke baad reentry nahi)
input double InpSLDollars        = 1.4;         // Loop SL distance (price units, gold me $1 = 1.00) - fill price se
input double InpTPDollars        = 10.0;        // TP distance - fill price se
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
input int    InpLVNRefreshSeconds = 120;        // LVN kitne second me dobara nikalna hai (120 = har 2 minute)

input group "=== SL Watchdog ==="
input bool   InpUseWatchdog      = true;        // true: XAUUSD position bina SL ke mile toh default SL laga do
input bool   InpProtectAllPositions = false;    // false: sirf is EA ki positions (magic). true: is symbol ki SABHI positions (manual/dusre EA bhi)

input group "=== Execution ==="
input int    InpSlippagePoints   = 20;          // Slippage (points)
input long   InpMagicNumber      = 20260708;    // Base magic (Support = base, Resistance = base+1)
input int    InpMaxSpreadPoints  = 100;         // Is se zyada spread par entry/reentry skip (agla tick retry)
input int    InpMaxLegRetries    = 20;          // Order fail hone par max attempts, uske baad agli touch ka wait
input int    InpPriceCheckMillis = 200;         // Price monitor interval (milliseconds)
input bool   InpLogErrors        = true;        // true: errors (order fail etc.) Experts me dikhein
input bool   InpLogLVNUpdates    = true;        // true: LVN level arm/change/remove hone par [LVN] line Experts me aaye

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
   int    historyTries;  // close ke baad history reason dhundhne ki koshish
  };

struct SlotSetup          // slot = ek level (support ya resistance)
  {
   bool   active;
   bool   triggered;      // pehli touch ho chuki
   bool   isSupport;
   double entry;          // LVN price
   double lastPrice;      // pehli touch detect karne ke liye (mid price)
   long   magic;
   int    slTotal;        // is level ke BUY + SELL milake total SL hit
   bool   stopped;        // slTotal limit tak pahunch gaya: ab koi reentry nahi
  };

string     g_Symbol;
int        g_SessStartMin = 0;
int        g_SessEndMin   = 0;
bool       g_InSession    = false;
bool       g_NYDST        = false;     // US DST abhi chal raha hai?
int        g_NYNowMin     = 0;         // New York local time (minutes since midnight)
long       g_NYDay        = 0;         // New York local din ka number
long       g_SessionLoggedDay = -1;
long       g_StartedDay   = -1;        // jis NY din ka pehla trade shuru hua (us din LVN refresh band)
long       g_ErrLoggedDay = -1;
ulong      g_NextComputeTryMs = 0;

ulong      g_WdTicket[];               // watchdog: jis position par modify/close fail hua uska ticket
ulong      g_WdNextMs[];               // watchdog: us ticket par agli koshish kab (GetTickCount64 ms)

SlotSetup  g_Slot[2];    // 0 = SUPPORT LVN, 1 = RESISTANCE LVN
HedgeLeg   g_Leg[4];     // index = slot*2 + (BUY ? 0 : 1)

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

string SlotName(int s)
  {
   return g_Symbol + " " + (g_Slot[s].isSupport ? "SUPPORT" : "RESISTANCE");
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

// Broker ke volume step / min / max ke hisaab se lot theek karo
double NormalizeLot(double lot)
  {
   double minLot = SymbolInfoDouble(g_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(g_Symbol, SYMBOL_VOLUME_STEP);

   if(step > 0)
      lot = MathFloor(lot / step + 1e-9) * step;
   if(maxLot > 0 && lot > maxLot)
      lot = maxLot;
   if(lot < minLot)
      lot = minLot;
   return NormalizeDouble(lot, 3);
  }

// Is level ki agli entry (BUY aur SELL dono) ka lot:
// shuruaati lot + (total SL [BUY+SELL] / InpLotStepEverySL) x InpLotStep
double LotForSlot(int s)
  {
   int steps = (InpLotStepEverySL > 0) ? g_Slot[s].slTotal / InpLotStepEverySL : 0;
   return NormalizeLot(InpLotSize + (double)steps * InpLotStep);
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

   if(InpLotSize <= 0 || InpLotStep < 0 || InpLotStepEverySL < 1 || InpSLDollars <= 0 || InpTPDollars <= 0 || InpMaxSLHits < 1)
     {
      Print("[FATAL] Lot/SL/TP inputs galat hain (lot>0, lot step>=0, step-every>=1, SL>0, TP>0, max SL hits>=1).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpBinSize <= 0 || InpSmoothBins < 0 || InpNodeWindowBins < 1 || InpPeakWindowBins < 1 ||
      InpLVNDepth <= 0 || InpLVNDepth > 1 || InpProfileDays < 1 || InpMinLevelDistance < 0)
     {
      Print("[FATAL] LVN inputs galat hain (bin>0, windows>=1, 0<depth<=1, days>=1).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpLVNRefreshSeconds < 10)
     {
      Print("[FATAL] InpLVNRefreshSeconds kam se kam 10 hona chahiye.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_SessStartMin = ParseHHMM(InpSessionStartNY);
   g_SessEndMin   = ParseHHMM(InpSessionEndNY);
   if(g_SessStartMin < 0 || g_SessEndMin < 0 || g_SessStartMin >= g_SessEndMin)
     {
      Print("[FATAL] Session time galat. Format HH:MM aur start < end hona chahiye (same din, New York time).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_Symbol = InpSymbol;
   if(!SymbolSelect(g_Symbol, true))
     {
      Print("[FATAL] Symbol Market Watch me nahi mila: '", g_Symbol, "' (symbol naam / suffix check karo).");
      return(INIT_FAILED);
     }

   trade.SetDeviationInPoints(InpSlippagePoints);

   for(int s = 0; s < 2; s++)
     {
      g_Slot[s].active    = false;
      g_Slot[s].triggered = false;
      g_Slot[s].isSupport = (s == 0);
      g_Slot[s].entry     = 0;
      g_Slot[s].lastPrice = 0;
      g_Slot[s].magic     = InpMagicNumber + s;
      g_Slot[s].slTotal   = 0;
      g_Slot[s].stopped   = false;
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

   if(LevelRefreshAllowed())
      RefreshLevels();

   ManageSlot(0);
   ManageSlot(1);

   ProtectPositions();   // legs ke baad: jo position bina SL ke bachi ho use protect karo
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
//| LVN refresh: NY session me, jab tak aaj ka pehla trade shuru na   |
//| ho. Trade shuru hote hi us din ke liye band.                      |
//+------------------------------------------------------------------+
bool LevelRefreshAllowed()
  {
   return (g_InSession && g_StartedDay != g_NYDay);
  }

//+------------------------------------------------------------------+
//| Har InpLVNRefreshSeconds (2 min) me LVN dobara nikalo aur support |
//| / resistance slots update karo                                    |
//+------------------------------------------------------------------+
void RefreshLevels()
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
         LogErr(g_Symbol + " LVN calculate nahi ho paya: " + why);
         g_ErrLoggedDay = g_NYDay;
        }
      return;
     }

   g_NextComputeTryMs = nowMs + (ulong)InpLVNRefreshSeconds * 1000;   // agla refresh

   if(g_SessionLoggedDay != g_NYDay)
     {
      g_SessionLoggedDay = g_NYDay;
      Print("[SESSION] New York session | NY time ", StringFormat("%02d:%02d", g_NYNowMin / 60, g_NYNowMin % 60),
            (g_NYDST ? " EDT (UTC-4, DST ON)" : " EST (UTC-5, DST OFF)"),
            " | window ", InpSessionStartNY, "-", InpSessionEndNY, " NY");
     }

   ApplyLevel(0, support,    price);
   ApplyLevel(1, resistance, price);
  }

//+------------------------------------------------------------------+
//| Naya nikla hua LVN slot par lagao.                                |
//|  - Trade/loop chal chuka: level nahi chhedna                      |
//|  - Armed (touch ka wait) aur price level ke InpMinLevelDistance   |
//|    ke andar: level pakad ke rakho (warna price jaise hi paas aaye |
//|    level "bahut paas" hone se hat jata aur kabhi touch na hota)   |
//|  - Armed aur price door: nearest LVN ke hisaab se badlo           |
//+------------------------------------------------------------------+
void ApplyLevel(int s, double level, double price)
  {
   bool armed   = (g_Slot[s].active && !g_Slot[s].triggered);
   bool running = (g_Slot[s].active && g_Slot[s].triggered);

   if(running)
      return;

   if(armed)
     {
      if(MathAbs(price - g_Slot[s].entry) <= InpMinLevelDistance)
         return;                         // level ke bahut paas: pakad ke rakho

      if(level <= 0)
        {
         g_Slot[s].active = false;
         if(InpLogLVNUpdates)
            Print("[LVN] ", SlotName(s), " LVN ", Px(g_Slot[s].entry), " hata diya - ab koi valid LVN nahi (price=", Px(price), ").");
         return;
        }

      if(MathAbs(level - g_Slot[s].entry) < InpBinSize)
         return;                         // wahi level (profile ka halka sa hilna) - kuch nahi badalna
     }

   if(level <= 0)
      return;

   double oldEntry = g_Slot[s].entry;

   ResetLeg(g_Leg[s * 2],     true);
   ResetLeg(g_Leg[s * 2 + 1], false);

   g_Slot[s].active    = true;
   g_Slot[s].triggered = false;
   g_Slot[s].entry     = level;
   g_Slot[s].lastPrice = price;
   g_Slot[s].slTotal   = 0;
   g_Slot[s].stopped   = false;

   if(InpLogLVNUpdates)
     {
      if(armed)
         Print("[LVN] ", SlotName(s), " LVN ", Px(oldEntry), " -> ", Px(level), " (price=", Px(price), ")");
      else
         Print("[LVN] ", SlotName(s), " LVN armed @ ", Px(level), " (price=", Px(price), ")");
     }
  }

//+------------------------------------------------------------------+
//| Volume profile (tick volume, bar ke high-low range me barabar     |
//| baanta hua) -> smooth -> local minimum + valley depth se LVN.     |
//| Support = price ke neeche sabse paas wala LVN, Resistance = upar  |
//| sabse paas wala LVN.                                              |
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

   // ---- LVN: local minimum + valley depth. Price ke neeche sabse paas = support, upar sabse paas = resistance ----
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
//| Ek slot (level) ka poora kaam: pehli touch -> dono legs -> dono   |
//| legs done hone par slot khatam                                    |
//+------------------------------------------------------------------+
void ManageSlot(int s)
  {
   if(!g_Slot[s].active)
      return;

   if(!g_Slot[s].triggered)
     {
      // Session ke bahar armed (untouched) level hata do
      if(!g_InSession)
        {
         g_Slot[s].active = false;
         return;
        }

      double bid = SymbolInfoDouble(g_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(g_Symbol, SYMBOL_ASK);
      if(bid <= 0 || ask <= 0)
         return;

      double mid = (bid + ask) / 2.0;
      if(g_Slot[s].lastPrice <= 0)
        {
         g_Slot[s].lastPrice = mid;
         return;
        }

      double point    = SymbolInfoDouble(g_Symbol, SYMBOL_POINT);
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

   if(!g_InSession || g_Slot[s].stopped)
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
   double price = LegPrice(leg);
   if(price <= 0)
      return;

   if(leg.lastPrice <= 0)
     {
      leg.lastPrice = price;
      return;
     }

   double point    = SymbolInfoDouble(g_Symbol, SYMBOL_POINT);
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
//| Lot = LotForSlot(): shuru 0.40, total SL (BUY+SELL) ke har 4 ke  |
//| baad +0.40 (dono legs ke liye).                                   |
//+------------------------------------------------------------------+
void TryOpenLeg(int s, HedgeLeg &leg, HedgeLeg &other)
  {
   int digits = (int)SymbolInfoInteger(g_Symbol, SYMBOL_DIGITS);

   // Spread gate. Pehli entry me dusri leg ko hedge complete karne ke liye turant kholte hain.
   bool completingHedge = (leg.entries == 0 && other.entries > 0);
   if(!completingHedge && SymbolInfoInteger(g_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints)
      return;

   double price = LegPrice(leg);
   if(price <= 0)
     {
      OpenFailed(s, leg, "valid price nahi mili");
      return;
     }

   double lot = LotForSlot(s);
   double tp  = leg.isBuy ? price + InpTPDollars : price - InpTPDollars;
   tp = NormalizeDouble(tp, digits);

   trade.SetExpertMagicNumber(g_Slot[s].magic);

   bool ok;
   if(leg.isBuy)
      ok = trade.Buy(lot, g_Symbol, 0, 0, tp, "");
   else
      ok = trade.Sell(lot, g_Symbol, 0, 0, tp, "");

   if(!ok)
     {
      OpenFailed(s, leg, "lot=" + DoubleToString(lot, 2) + " RetCode=" + IntegerToString((int)trade.ResultRetcode()) +
                         " " + trade.ResultRetcodeDescription());
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
      positionId = FindPositionTicket(g_Slot[s].magic, leg.isBuy);

   if(positionId == 0)
     {
      LogErr(SlotName(s) + " " + Side(leg) + " position khuli par ticket track nahi ho paya - watchdog SL lagayega, is leg ko manually dekho.");
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

   // Aaj ka pehla trade shuru: us din ke liye LVN refresh band
   if(g_StartedDay != g_NYDay)
     {
      g_StartedDay = g_NYDay;
      if(InpLogLVNUpdates)
         Print("[LVN] ", g_Symbol, " trade shuru ho gaya - aaj ke liye LVN levels ab update nahi honge.");
     }

   string tag;
   if(leg.entries == 1)
      tag = "[ENTRY]";
   else
      tag = "[REENTRY #" + IntegerToString(leg.entries - 1) + "]";

   Print(tag, " ", SlotName(s), " ", Side(leg), " lot=", DoubleToString(lot, 2),
         " price=", Px(fillPrice), " SL=", Px(leg.slLevel), " TP=", Px(tp),
         " | LVN=", Px(g_Slot[s].entry));
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
//|   SL  -> slTotal++ (BUY+SELL milake). Limit (10) tak pahunch gaye |
//|          ya session khatam: leg done. Warna price LVN par wapas   |
//|          aane par reentry (agla lot LotForSlot() se: har 4 total  |
//|          SL par +0.40)                                            |
//|   TP / manual -> leg hamesha ke liye done                         |
//+------------------------------------------------------------------+
void HandleLegClosed(int s, HedgeLeg &leg)
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
      g_Slot[s].slTotal++;   // BUY + SELL milake is level ke total SL

      if(g_Slot[s].stopped)
        {
         // Limit pehle hi paar ho chuki thi (doosri leg ka SL) - ye leg bhi ab band
         leg.done = true;
         Print("[SL HIT] ", SlotName(s), " ", Side(leg), " price=", Px(exitPrice),
               " (total SL ", g_Slot[s].slTotal, ") - trade band, reentry nahi hogi.");
         return;
        }

      if(g_Slot[s].slTotal >= InpMaxSLHits)
        {
         g_Slot[s].stopped = true;
         leg.done = true;
         Print("[TRADE STOPPED] ", SlotName(s), " ", Side(leg), " price=", Px(exitPrice),
               " - total SL (BUY+SELL) ", g_Slot[s].slTotal, " ho gaye (limit ", InpMaxSLHits,
               "), ye trade ab aage nahi badhega. Koi reentry nahi (jo leg khuli hai wo apne SL/TP tak chalegi).");
         return;
        }

      if(!g_InSession)
        {
         leg.done = true;
         Print("[SL HIT] ", SlotName(s), " ", Side(leg), " price=", Px(exitPrice),
               " (total SL ", g_Slot[s].slTotal, "/", InpMaxSLHits, ") - session khatam, reentry nahi hogi.");
         return;
        }

      leg.lastPrice = LegPrice(leg);
      Print("[SL HIT] ", SlotName(s), " ", Side(leg), " price=", Px(exitPrice),
            " (total SL ", g_Slot[s].slTotal, "/", InpMaxSLHits, ") - reentry ka wait @ ", Px(g_Slot[s].entry),
            " | agla lot=", DoubleToString(LotForSlot(s), 2));
      return;
     }

   leg.done = true;
   if(isTP)
      Print("[TP HIT] ", SlotName(s), " ", Side(leg), " price=", Px(exitPrice),
            " - ye leg complete, reentry nahi hogi.");
   else
      Print("[LEG DONE] ", SlotName(s), " ", Side(leg), " - manual/other close, reentry nahi hogi.");
  }

//+------------------------------------------------------------------+
//| SL WATCHDOG                                                       |
//| EA ke andar ki state (legs) par depend nahi karta: seedha broker  |
//| ki positions dekhta hai. Isse ye in sab cases me bhi kaam karega: |
//|  - SL modify broker ne reject kar diya / busy tha                 |
//|  - EA restart / recompile / input change (state reset)            |
//|  - ticket track nahi ho paya                                      |
//+------------------------------------------------------------------+
int LegIndexOfTicket(ulong ticket)
  {
   for(int i = 0; i < 4; i++)
     {
      if(g_Leg[i].opened && g_Leg[i].ticket == ticket)
         return i;
     }
   return -1;
  }

bool WdThrottled(ulong ticket)
  {
   ulong now = GetTickCount64();
   int   n   = ArraySize(g_WdTicket);
   for(int i = 0; i < n; i++)
     {
      if(g_WdTicket[i] == ticket)
         return (now < g_WdNextMs[i]);
     }
   return false;
  }

void WdSetBackoff(ulong ticket, ulong ms)
  {
   ulong now = GetTickCount64();
   int   n   = ArraySize(g_WdTicket);
   for(int i = 0; i < n; i++)
     {
      if(g_WdTicket[i] == ticket)
        {
         g_WdNextMs[i] = now + ms;
         return;
        }
     }

   if(n >= 50)   // cache bada ho gaya -> saaf kar do
     {
      ArrayResize(g_WdTicket, 0);
      ArrayResize(g_WdNextMs, 0);
      n = 0;
     }
   ArrayResize(g_WdTicket, n + 1);
   ArrayResize(g_WdNextMs, n + 1);
   g_WdTicket[n] = ticket;
   g_WdNextMs[n] = now + ms;
  }

void ProtectPositions()
  {
   if(!InpUseWatchdog)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != g_Symbol)
         continue;   // sirf XAUUSD

      long magic = PositionGetInteger(POSITION_MAGIC);
      bool ours  = (magic >= InpMagicNumber && magic <= InpMagicNumber + 1);
      if(!ours && !InpProtectAllPositions)
         continue;

      if(PositionGetDouble(POSITION_SL) > 0)
         continue;   // SL pehle se laga hai

      if(WdThrottled(ticket))
         continue;   // pichhli koshish fail hui thi, thoda ruko

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool   isBuy     = (type == POSITION_TYPE_BUY);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curTP     = PositionGetDouble(POSITION_TP);
      int    digits    = (int)SymbolInfoInteger(g_Symbol, SYMBOL_DIGITS);

      double slLevel = NormalizeDouble(isBuy ? openPrice - InpSLDollars : openPrice + InpSLDollars, digits);

      double bid = SymbolInfoDouble(g_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(g_Symbol, SYMBOL_ASK);
      if(bid <= 0 || ask <= 0)
         continue;

      string label = g_Symbol + " " + (isBuy ? "BUY" : "SELL") + " #" + (string)ticket;
      int    li    = LegIndexOfTicket(ticket);   // is EA ki tracked leg hai toh uska state bhi sahi rakhna hai

      // Price pehle hi default SL level paar kar chuka -> SL lagana possible nahi (broker reject karega),
      // SL hit ho chuka hota, isliye position close.
      bool breached = isBuy ? (bid <= slLevel) : (ask >= slLevel);
      if(breached)
        {
         if(li >= 0)
            g_Leg[li].slClosing = true;   // leg logic isse SL hit ginega (reentry/SL count/lot step sahi chalega)

         if(trade.PositionClose(ticket))
            Print("[WATCHDOG] ", label, " par SL nahi tha aur price default SL (", Px(slLevel),
                  ") paar kar chuka tha (bid=", Px(bid), " ask=", Px(ask), ") - position close ki.");
         else
           {
            if(li >= 0)
               g_Leg[li].slClosing = false;
            LogErr("WATCHDOG " + label + " close fail: RetCode=" + IntegerToString((int)trade.ResultRetcode()) +
                   " " + trade.ResultRetcodeDescription() + " - dobara koshish karenge.");
            WdSetBackoff(ticket, 1000);
           }
         continue;
        }

      // Normal case: default SL laga do (existing TP waisa hi rehta hai)
      if(trade.PositionModify(ticket, slLevel, curTP))
        {
         Print("[WATCHDOG] ", label, " par SL nahi tha - default SL laga diya @ ", Px(slLevel),
               " (open ", Px(openPrice), ")");
         if(li >= 0)
           {
            g_Leg[li].brokerSL = true;
            g_Leg[li].slLevel  = slLevel;
           }
        }
      else
        {
         LogErr("WATCHDOG " + label + " SL modify fail: RetCode=" + IntegerToString((int)trade.ResultRetcode()) +
                " " + trade.ResultRetcodeDescription() + " - dobara koshish karenge.");
         WdSetBackoff(ticket, 2000);
        }
     }
  }
//+------------------------------------------------------------------+
