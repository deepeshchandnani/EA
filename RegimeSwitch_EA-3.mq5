//+------------------------------------------------------------------+
//|                                            RegimeSwitch_EA.mq5    |
//|   Crypto Intraday EA - Market Regime Detection (Trend/Range)     |
//|   Strategy 1: Trend Following (EMA20/50 + ADX)                   |
//|   Strategy 2: Mean Reversion (Bollinger Bands + RSI)             |
//|                                                                    |
//|   Timeframe: M15 | One position per symbol | No Martingale/Grid  |
//|   Trades on candle close only.                                   |
//+------------------------------------------------------------------+
#property copyright "Generated for user - Regime Switching EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>

//======================================================================
// INPUTS
//======================================================================
input group "=== General ==="
input ulong   InpMagicNumber          = 20260701;   // Magic Number
input int     InpSlippagePoints       = 30;          // Max Slippage (points)
input string  InpSessionStart         = "00:00";     // Trading Session Start (server time HH:MM)
input string  InpSessionEnd           = "23:59";     // Trading Session End   (server time HH:MM)

input group "=== Regime Detection ==="
input int     InpEMAFast              = 20;          // EMA Fast Period
input int     InpEMASlow              = 50;          // EMA Slow Period
input double  InpMinEMADistPoints     = 50;          // Minimum EMA distance for trend (points)
input int     InpADXPeriod            = 14;          // ADX Period
input double  InpADXThresholdTrend    = 25.0;        // ADX Threshold - Trend regime (> value)
input double  InpADXThresholdRange    = 20.0;        // ADX Threshold - Range regime (< value)

input group "=== Strategy 1: Trend Following ==="
input int     InpVolumeAvgPeriod      = 20;          // Volume Average Period
input int     InpSwingLookback        = 10;          // Swing High/Low Lookback (bars)
input int     InpATRPeriod            = 14;          // ATR Period
input double  InpATRMultiplier        = 1.5;         // ATR Multiplier for Stop Loss
input double  InpRRRatioTrend         = 5.0;         // Final Risk:Reward Ratio (Trend)

input group "=== Strategy 2: Mean Reversion ==="
input int     InpRSIPeriod            = 14;          // RSI Period
input double  InpRSIBuyLevel          = 30.0;        // RSI Buy Level (oversold)
input double  InpRSISellLevel         = 70.0;        // RSI Sell Level (overbought)
input int     InpBBPeriod             = 20;          // Bollinger Bands Period
input double  InpBBDeviation          = 2.0;         // Bollinger Bands Deviation
input double  InpRRRatioRange         = 5.0;         // Final Risk:Reward Ratio (Range)

input group "=== Partial Take-Profit Booking (applies to both strategies) ==="
input double  InpTP1_RR               = 1.0;         // TP1: R-Multiple  (default 1:1)
input double  InpTP1_Pct              = 60.0;        // TP1: % of position to close
input double  InpTP2_RR               = 2.5;         // TP2: R-Multiple  (default 1:2.5)
input double  InpTP2_Pct              = 30.0;        // TP2: % of position to close
input double  InpTP3_RR               = 5.0;         // TP3 (final): R-Multiple (default 1:5) - remaining ~10% rides here via broker TP
input bool    InpMoveSLToBreakevenAfterTP1 = true;    // Move SL to entry after TP1 is booked

input group "=== Risk Management / Lot Sizing ==="
input double  InpBaseLot              = 0.25;        // Base (Starting) Lot Size
input bool    InpUseMartingale        = true;        // Enable Martingale after a loss
input double  InpMartingaleMultiplier = 2.0;         // Martingale Multiplier per consecutive loss
input int     InpMaxMartingaleSteps   = 4;           // Max consecutive martingale steps (caps lot growth)
input double  InpMaxSpreadPoints      = 50;          // Max Allowed Spread (points)
input int     InpMaxTradesPerDay      = 10;          // Max Trades Per Day
input double  InpDailyLossLimitPct    = 5.0;         // Daily Max Loss (% of day-start balance)
input double  InpMinLot               = 0.01;        // Minimum Lot Size (broker fallback)
input double  InpMaxLot               = 50.0;        // Maximum Lot Size cap

input group "=== Display / Alerts ==="
input bool    InpShowDashboard        = true;        // Show On-Chart Dashboard
input bool    InpDrawArrows           = true;        // Draw Buy/Sell Arrows
input bool    InpEnableAlerts         = true;        // Enable Alert() popups
input bool    InpEnablePushNotify     = false;       // Enable Push Notifications
input bool    InpVerboseLogging       = true;        // Verbose Logging to Journal

//======================================================================
// GLOBALS
//======================================================================
CTrade         trade;
CSymbolInfo    symInfo;
CPositionInfo  posInfo;

int h_emaFast, h_emaSlow, h_adx, h_rsi, h_bb, h_atr;

enum MarketRegime { REGIME_NONE = 0, REGIME_TREND = 1, REGIME_RANGE = 2 };
MarketRegime g_regime = REGIME_NONE;
string       g_strategyLabel = "NONE";

datetime g_lastBarTime      = 0;
datetime g_currentDay       = 0;
double   g_dayStartBalance  = 0.0;
int      g_dailyTradesCount = 0;
double   g_dailyRealizedPL  = 0.0;
int      g_dailyWins        = 0;
int      g_dailyLosses      = 0;
bool     g_dailyLossLimitHit= false;

datetime g_lastSignalBarTime = 0; // used to prevent duplicate signal processing per bar

int      g_martingaleStep = 0;    // consecutive loss counter, resets to 0 on a win

// --- Partial take-profit tracking for the currently open position ---
ulong    g_posTicket        = 0;
double   g_posEntryPrice    = 0.0;
double   g_posRDistance     = 0.0;   // initial SL distance in price units (= 1R)
double   g_posInitialVolume = 0.0;
int      g_posDirection     = 0;     // 1 = buy, -1 = sell
bool     g_tp1Done          = false;
bool     g_tp2Done          = false;

// --- Tracks NET profit across all partial closes of one position, so
//     martingale/win-loss is judged on the whole trade, not one partial leg ---
ulong    g_trackPositionID     = 0;
double   g_trackPositionProfit = 0.0;

//======================================================================
// UTILITY: STRING <-> TIME PARSING FOR SESSION FILTER
//======================================================================
bool ParseHHMM(const string s, int &hh, int &mm)
{
   string parts[];
   int n = StringSplit(s, ':', parts);
   if(n != 2) return false;
   hh = (int)StringToInteger(parts[0]);
   mm = (int)StringToInteger(parts[1]);
   if(hh < 0 || hh > 23 || mm < 0 || mm > 59) return false;
   return true;
}

bool IsWithinSession()
{
   int startH, startM, endH, endM;
   if(!ParseHHMM(InpSessionStart, startH, startM)) return true; // fail-open
   if(!ParseHHMM(InpSessionEnd,   endH,   endM))   return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMinutes   = dt.hour * 60 + dt.min;
   int startMinutes = startH * 60 + startM;
   int endMinutes   = endH * 60 + endM;

   if(startMinutes <= endMinutes)
      return (nowMinutes >= startMinutes && nowMinutes <= endMinutes);
   else
      // session wraps midnight
      return (nowMinutes >= startMinutes || nowMinutes <= endMinutes);
}

//======================================================================
// INIT
//======================================================================
int OnInit()
{
   if(!symInfo.Name(_Symbol))
   {
      Print("ERROR: Failed to initialize symbol info for ", _Symbol);
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   h_emaFast = iMA(_Symbol, PERIOD_M15, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_emaSlow = iMA(_Symbol, PERIOD_M15, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_adx     = iADX(_Symbol, PERIOD_M15, InpADXPeriod);
   h_rsi     = iRSI(_Symbol, PERIOD_M15, InpRSIPeriod, PRICE_CLOSE);
   h_bb      = iBands(_Symbol, PERIOD_M15, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   h_atr     = iATR(_Symbol, PERIOD_M15, InpATRPeriod);

   if(h_emaFast==INVALID_HANDLE || h_emaSlow==INVALID_HANDLE || h_adx==INVALID_HANDLE ||
      h_rsi==INVALID_HANDLE || h_bb==INVALID_HANDLE || h_atr==INVALID_HANDLE)
   {
      Print("ERROR: Failed to create one or more indicator handles.");
      return INIT_FAILED;
   }

   // Initialize daily tracking
   g_currentDay      = TodayMidnight();
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyTradesCount= 0;
   g_dailyRealizedPL = 0.0;
   g_dailyWins       = 0;
   g_dailyLosses     = 0;
   g_dailyLossLimitHit = false;

   if(InpVerboseLogging) Print("RegimeSwitch_EA initialized on ", _Symbol, " M15.");
   return INIT_SUCCEEDED;
}

//======================================================================
// DEINIT
//======================================================================
void OnDeinit(const int reason)
{
   IndicatorRelease(h_emaFast);
   IndicatorRelease(h_emaSlow);
   IndicatorRelease(h_adx);
   IndicatorRelease(h_rsi);
   IndicatorRelease(h_bb);
   IndicatorRelease(h_atr);
   Comment("");
   if(InpVerboseLogging) Print("RegimeSwitch_EA deinitialized. Reason: ", reason);
}

//======================================================================
// HELPERS
//======================================================================
datetime TodayMidnight()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

bool IsNewBar()
{
   datetime t0 = iTime(_Symbol, PERIOD_M15, 0);
   if(t0 != g_lastBarTime)
   {
      g_lastBarTime = t0;
      return true;
   }
   return false;
}

void CheckNewDay()
{
   datetime today = TodayMidnight();
   if(today != g_currentDay)
   {
      g_currentDay        = today;
      g_dayStartBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyTradesCount  = 0;
      g_dailyRealizedPL   = 0.0;
      g_dailyWins         = 0;
      g_dailyLosses       = 0;
      g_dailyLossLimitHit = false;
      g_martingaleStep    = 0;
      if(InpVerboseLogging) Print("New trading day started. Balance reference: ", g_dayStartBalance);
   }
}

bool HasOpenPosition()
{
   if(PositionSelect(_Symbol))
   {
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         return true;
   }
   return false;
}

int OpenPositionDirection() // 1 = buy, -1 = sell, 0 = none
{
   if(!HasOpenPosition()) return 0;
   long type = PositionGetInteger(POSITION_TYPE);
   if(type == POSITION_TYPE_BUY) return 1;
   if(type == POSITION_TYPE_SELL) return -1;
   return 0;
}

bool SpreadOK()
{
   symInfo.RefreshRates();
   double spreadPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spreadPoints <= InpMaxSpreadPoints);
}

bool DailyLimitsOK()
{
   if(g_dailyLossLimitHit) return false;
   if(g_dailyTradesCount >= InpMaxTradesPerDay) return false;

   double lossThreshold = g_dayStartBalance * (InpDailyLossLimitPct / 100.0);
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double drawdown = g_dayStartBalance - currentBalance;
   if(drawdown >= lossThreshold && lossThreshold > 0)
   {
      if(!g_dailyLossLimitHit)
      {
         g_dailyLossLimitHit = true;
         string msg = StringFormat("Daily loss limit reached (%.2f%%). Trading halted for today.", InpDailyLossLimitPct);
         LogAndNotify(msg);
      }
      return false;
   }
   return true;
}

void LogAndNotify(const string msg)
{
   if(InpVerboseLogging) Print(msg);
   if(InpEnableAlerts)      Alert(msg);
   if(InpEnablePushNotify)  SendNotification(msg);
}

//======================================================================
// LOT SIZE CALCULATION - Fixed base lot with optional Martingale step-up
// NOTE: slDistancePrice is no longer used for sizing (kept as a parameter
// for call-site compatibility / potential future use / logging).
//======================================================================
double CalculateLotSize(double slDistancePrice)
{
   double lot = InpBaseLot;

   if(InpUseMartingale && g_martingaleStep > 0)
   {
      int steps = MathMin(g_martingaleStep, InpMaxMartingaleSteps);
      lot = InpBaseLot * MathPow(InpMartingaleMultiplier, steps);
   }

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), InpMinLot);
   double maxLot  = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLot);

   if(lotStep > 0)
      lot = MathFloor(lot / lotStep) * lotStep;

   lot = MathMax(minLot, MathMin(maxLot, lot));
   return NormalizeDouble(lot, 2);
}

//======================================================================
// REGIME DETECTION
//======================================================================
bool GetIndicatorSnapshot(double &emaFast1, double &emaFast2,
                           double &emaSlow1, double &emaSlow2,
                           double &adxMain,
                           double &rsi1,
                           double &bbUpper1, double &bbLower1, double &bbMid1,
                           double &atr1)
{
   double bufEmaFast[], bufEmaSlow[], bufAdx[], bufRsi[], bufBbUp[], bufBbLo[], bufBbMid[], bufAtr[];
   ArraySetAsSeries(bufEmaFast, true);
   ArraySetAsSeries(bufEmaSlow, true);
   ArraySetAsSeries(bufAdx, true);
   ArraySetAsSeries(bufRsi, true);
   ArraySetAsSeries(bufBbUp, true);
   ArraySetAsSeries(bufBbLo, true);
   ArraySetAsSeries(bufBbMid, true);
   ArraySetAsSeries(bufAtr, true);

   if(CopyBuffer(h_emaFast, 0, 0, 3, bufEmaFast) < 3) return false;
   if(CopyBuffer(h_emaSlow, 0, 0, 3, bufEmaSlow) < 3) return false;
   if(CopyBuffer(h_adx, MAIN_LINE, 0, 3, bufAdx) < 3) return false;
   if(CopyBuffer(h_rsi, 0, 0, 3, bufRsi) < 3) return false;
   if(CopyBuffer(h_bb, UPPER_BAND, 0, 3, bufBbUp) < 3) return false;
   if(CopyBuffer(h_bb, LOWER_BAND, 0, 3, bufBbLo) < 3) return false;
   if(CopyBuffer(h_bb, BASE_LINE, 0, 3, bufBbMid) < 3) return false;
   if(CopyBuffer(h_atr, 0, 0, 3, bufAtr) < 3) return false;

   emaFast1 = bufEmaFast[1]; emaFast2 = bufEmaFast[2];
   emaSlow1 = bufEmaSlow[1]; emaSlow2 = bufEmaSlow[2];
   adxMain  = bufAdx[1];
   rsi1     = bufRsi[1];
   bbUpper1 = bufBbUp[1]; bbLower1 = bufBbLo[1]; bbMid1 = bufBbMid[1];
   atr1     = bufAtr[1];
   return true;
}

MarketRegime DetectRegime(double emaFast1, double emaSlow1, double adxMain)
{
   double point = symInfo.Point();
   double emaDistPoints = MathAbs(emaFast1 - emaSlow1) / point;

   bool trendUp   = (emaFast1 > emaSlow1) && (emaDistPoints >= InpMinEMADistPoints) && (adxMain > InpADXThresholdTrend);
   bool trendDown = (emaFast1 < emaSlow1) && (emaDistPoints >= InpMinEMADistPoints) && (adxMain > InpADXThresholdTrend);

   if(trendUp || trendDown)
      return REGIME_TREND;

   bool flatEMAs = (emaDistPoints < InpMinEMADistPoints);
   bool lowADX   = (adxMain < InpADXThresholdRange);

   if(lowADX && flatEMAs)
      return REGIME_RANGE;

   return REGIME_NONE; // transitional/unclear - no new entries
}

//======================================================================
// SIGNAL DETECTION - STRATEGY 1: TREND FOLLOWING (evaluated on closed bar[1])
//======================================================================
int TrendSignal(double emaFast1, double emaSlow1)
{
   double close1 = iClose(_Symbol, PERIOD_M15, 1);

   long volArr[];
   ArraySetAsSeries(volArr, true);
   if(CopyTickVolume(_Symbol, PERIOD_M15, 1, InpVolumeAvgPeriod + 1, volArr) < InpVolumeAvgPeriod + 1)
      return 0;

   long vol1 = volArr[0];
   double sumVol = 0;
   for(int i = 1; i <= InpVolumeAvgPeriod; i++) sumVol += (double)volArr[i];
   double avgVol = sumVol / InpVolumeAvgPeriod;

   bool volumeOK = ((double)vol1 > avgVol);

   if(emaFast1 > emaSlow1 && close1 > emaFast1 && volumeOK)
      return 1; // buy
   if(emaFast1 < emaSlow1 && close1 < emaFast1 && volumeOK)
      return -1; // sell

   return 0;
}

//======================================================================
// SIGNAL DETECTION - STRATEGY 2: MEAN REVERSION (evaluated on closed bar[1])
//======================================================================
int MeanReversionSignal(double rsi1, double bbUpper1, double bbLower1)
{
   double open1  = iOpen(_Symbol, PERIOD_M15, 1);
   double close1 = iClose(_Symbol, PERIOD_M15, 1);
   double low1   = iLow(_Symbol, PERIOD_M15, 1);
   double high1  = iHigh(_Symbol, PERIOD_M15, 1);

   bool touchedLower = (low1 <= bbLower1);
   bool touchedUpper = (high1 >= bbUpper1);
   bool bullishCandle = (close1 > open1);
   bool bearishCandle = (close1 < open1);

   if(touchedLower && rsi1 < InpRSIBuyLevel && bullishCandle)
      return 1; // buy
   if(touchedUpper && rsi1 > InpRSISellLevel && bearishCandle)
      return -1; // sell

   return 0;
}

//======================================================================
// SL / TP CALCULATION
//======================================================================
void CalcTrendSLTP(int direction, double entryPrice, double atr1, double &sl, double &tp)
{
   double point = symInfo.Point();
   int swingLowIdx  = iLowest(_Symbol, PERIOD_M15, MODE_LOW, InpSwingLookback, 1);
   int swingHighIdx = iHighest(_Symbol, PERIOD_M15, MODE_HIGH, InpSwingLookback, 1);
   double swingLow  = iLow(_Symbol, PERIOD_M15, swingLowIdx);
   double swingHigh = iHigh(_Symbol, PERIOD_M15, swingHighIdx);

   double atrSL = atr1 * InpATRMultiplier;

   if(direction == 1)
   {
      double slBySwing = entryPrice - swingLow;
      double slDist = MathMax(slBySwing, atrSL);
      sl = entryPrice - slDist;
      tp = entryPrice + slDist * InpRRRatioTrend;
   }
   else
   {
      double slBySwing = swingHigh - entryPrice;
      double slDist = MathMax(slBySwing, atrSL);
      sl = entryPrice + slDist;
      tp = entryPrice - slDist * InpRRRatioTrend;
   }
}

void CalcRangeSLTP(int direction, double entryPrice, double bbMid1, double &sl, double &tp)
{
   int swingLowIdx  = iLowest(_Symbol, PERIOD_M15, MODE_LOW, InpSwingLookback, 1);
   int swingHighIdx = iHighest(_Symbol, PERIOD_M15, MODE_HIGH, InpSwingLookback, 1);
   double swingLow  = iLow(_Symbol, PERIOD_M15, swingLowIdx);
   double swingHigh = iHigh(_Symbol, PERIOD_M15, swingHighIdx);

   if(direction == 1)
   {
      double slDist = entryPrice - swingLow;
      if(slDist <= 0) slDist = symInfo.Point() * 100;
      sl = swingLow;
      double tpByRR  = entryPrice + slDist * InpRRRatioRange;
      // Take the more conservative (closer) target between Mid-BB and RR target
      tp = MathMin(bbMid1, tpByRR);
      if(tp <= entryPrice) tp = tpByRR; // fallback if mid band is below entry
   }
   else
   {
      double slDist = swingHigh - entryPrice;
      if(slDist <= 0) slDist = symInfo.Point() * 100;
      sl = swingHigh;
      double tpByRR = entryPrice - slDist * InpRRRatioRange;
      tp = MathMax(bbMid1, tpByRR);
      if(tp >= entryPrice) tp = tpByRR; // fallback if mid band is above entry
   }
}

//======================================================================
// TRADE EXECUTION
//======================================================================
void DrawSignalArrow(int direction)
{
   if(!InpDrawArrows) return;
   datetime t = iTime(_Symbol, PERIOD_M15, 1);
   double price = (direction == 1) ? iLow(_Symbol, PERIOD_M15, 1) : iHigh(_Symbol, PERIOD_M15, 1);
   string name = StringFormat("Arrow_%s_%d", (direction==1?"BUY":"SELL"), (int)t);

   ObjectDelete(0, name);
   ObjectCreate(0, name, (direction==1)?OBJ_ARROW_UP:OBJ_ARROW_DOWN, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, (direction==1)?clrLime:clrRed);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, (direction==1)?ANCHOR_TOP:ANCHOR_BOTTOM);
}

bool OpenTrade(int direction, double sl, double tp, const string comment)
{
   symInfo.RefreshRates();
   double entryPrice = (direction == 1) ? symInfo.Ask() : symInfo.Bid();
   double slDist = MathAbs(entryPrice - sl);
   double lot = CalculateLotSize(slDist);

   bool result = false;
   if(direction == 1)
      result = trade.Buy(lot, _Symbol, entryPrice, sl, tp, comment);
   else
      result = trade.Sell(lot, _Symbol, entryPrice, sl, tp, comment);

   if(result)
   {
      g_dailyTradesCount++;
      DrawSignalArrow(direction);

      // --- Initialize partial take-profit tracking for this new position ---
      if(PositionSelect(_Symbol))
      {
         g_posTicket        = (ulong)PositionGetInteger(POSITION_TICKET);
         g_posEntryPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
         g_posInitialVolume = PositionGetDouble(POSITION_VOLUME);
         g_posDirection      = direction;
         g_posRDistance      = MathAbs(g_posEntryPrice - sl);
         g_tp1Done = false;
         g_tp2Done = false;
      }

      string msg = StringFormat("%s: %s opened | Lot=%.2f Entry=%.5f SL=%.5f Final TP=%.5f | Partial TP1=%.1fR(%.0f%%) TP2=%.1fR(%.0f%%) TP3(final)=%.1fR",
                          _Symbol, (direction==1?"BUY":"SELL"), lot, entryPrice, sl, tp,
                          InpTP1_RR, InpTP1_Pct, InpTP2_RR, InpTP2_Pct, InpTP3_RR);
      LogAndNotify(msg);
   }
   else
   {
      Print("ERROR: Order failed. Retcode=", trade.ResultRetcode(), " Desc=", trade.ResultRetcodeDescription());
   }
   return result;
}

void CloseCurrentPosition(const string reason)
{
   if(!HasOpenPosition()) return;
   ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   if(trade.PositionClose(ticket))
   {
      LogAndNotify(StringFormat("%s: Position closed. Reason: %s", _Symbol, reason));
   }
   else
   {
      Print("ERROR: Failed to close position. Retcode=", trade.ResultRetcode());
   }
}

//======================================================================
// PARTIAL TAKE-PROFIT MANAGEMENT
// Runs every tick (not just candle close) since intrabar price moves
// must trigger partial booking in real time.
// TP1 (default 1R / 60%) and TP2 (default 2.5R / 30%) are closed manually.
// The remaining ~10% rides the broker-level TP already set at trade open
// (default 5R), so no manual action is needed for the final leg.
//======================================================================
double RoundToLotStep(double volume)
{
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lotStep > 0)
      volume = MathFloor(volume / lotStep) * lotStep;
   return MathMax(volume, 0.0) >= minLot ? volume : 0.0;
}

void ManagePartialTakeProfits()
{
   if(!HasOpenPosition())
   {
      // No position open - reset tracking state
      g_posTicket = 0; g_tp1Done = false; g_tp2Done = false;
      return;
   }

   // Safety: if the currently selected position ticket doesn't match what we
   // are tracking (e.g. EA restarted mid-trade), re-sync tracking passively.
   ulong currentTicket = (ulong)PositionGetInteger(POSITION_TICKET);
   if(currentTicket != g_posTicket)
   {
      g_posTicket        = currentTicket;
      g_posEntryPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
      g_posInitialVolume = PositionGetDouble(POSITION_VOLUME);
      g_posDirection      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double curSL = PositionGetDouble(POSITION_SL);
      g_posRDistance = (curSL > 0) ? MathAbs(g_posEntryPrice - curSL) : 0.0;
      g_tp1Done = false; g_tp2Done = false;
   }

   if(g_posRDistance <= 0) return; // cannot compute R-multiples without a valid SL distance

   symInfo.RefreshRates();
   double curPrice = (g_posDirection == 1) ? symInfo.Bid() : symInfo.Ask();

   double tp1Price = (g_posDirection == 1) ? g_posEntryPrice + g_posRDistance * InpTP1_RR
                                            : g_posEntryPrice - g_posRDistance * InpTP1_RR;
   double tp2Price = (g_posDirection == 1) ? g_posEntryPrice + g_posRDistance * InpTP2_RR
                                            : g_posEntryPrice - g_posRDistance * InpTP2_RR;

   bool tp1Hit = (g_posDirection == 1) ? (curPrice >= tp1Price) : (curPrice <= tp1Price);
   bool tp2Hit = (g_posDirection == 1) ? (curPrice >= tp2Price) : (curPrice <= tp2Price);

   double currentVolume = PositionGetDouble(POSITION_VOLUME);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   // ---- TP1: book InpTP1_Pct of the ORIGINAL volume ----
   if(!g_tp1Done && tp1Hit)
   {
      double volToClose = RoundToLotStep(g_posInitialVolume * (InpTP1_Pct / 100.0));
      double remainder   = currentVolume - volToClose;
      if(volToClose > 0 && remainder >= minLot)
      {
         if(trade.PositionClosePartial(g_posTicket, volToClose))
         {
            g_tp1Done = true;
            LogAndNotify(StringFormat("%s: TP1 (%.1fR) hit - booked %.2f lots (%.0f%%).",
                                       _Symbol, InpTP1_RR, volToClose, InpTP1_Pct));

            if(InpMoveSLToBreakevenAfterTP1)
            {
               double curTP = PositionGetDouble(POSITION_TP);
               if(trade.PositionModify(g_posTicket, g_posEntryPrice, curTP))
                  LogAndNotify(StringFormat("%s: SL moved to breakeven (%.5f) after TP1.", _Symbol, g_posEntryPrice));
            }
         }
      }
      else
      {
         // Position too small to split further - treat as fully booked at TP1
         g_tp1Done = true;
      }
   }

   // ---- TP2: book InpTP2_Pct of the ORIGINAL volume ----
   if(g_tp1Done && !g_tp2Done && tp2Hit)
   {
      currentVolume = PositionGetDouble(POSITION_VOLUME); // refresh after TP1
      double volToClose = RoundToLotStep(g_posInitialVolume * (InpTP2_Pct / 100.0));
      double remainder   = currentVolume - volToClose;
      if(volToClose > 0 && remainder >= minLot)
      {
         if(trade.PositionClosePartial(g_posTicket, volToClose))
         {
            g_tp2Done = true;
            LogAndNotify(StringFormat("%s: TP2 (%.1fR) hit - booked %.2f lots (%.0f%%). Remainder rides to final TP (%.1fR).",
                                       _Symbol, InpTP2_RR, volToClose, InpTP2_Pct, InpTP3_RR));
         }
      }
      else
      {
         // Not enough volume left to split - let the rest ride to final TP
         g_tp2Done = true;
      }
   }
}


void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   if(!HistoryDealSelect(trans.deal)) return;

   long dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(dealMagic != (long)InpMagicNumber) return;

   long entryType = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_OUT_BY) return;

   double dealProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                      + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                      + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   CheckNewDay(); // ensure we're tallying into the correct day bucket
   g_dailyRealizedPL += dealProfit; // running daily total includes every partial close, always accurate

   // --- Accumulate this deal's profit against the position it belongs to ---
   ulong posID = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(posID != g_trackPositionID)
   {
      g_trackPositionID     = posID;
      g_trackPositionProfit = 0.0;
   }
   g_trackPositionProfit += dealProfit;

   // Check whether the position still has open volume (i.e. this was only a
   // partial close - TP1/TP2). If it no longer exists, this deal was the
   // FINAL leg, so we now judge the whole trade's NET result.
   bool positionStillOpen = PositionSelectByTicket(posID);

   if(positionStillOpen)
   {
      if(InpVerboseLogging)
         Print("Partial close booked. Deal P/L=", dealProfit, " | Running trade P/L=", g_trackPositionProfit, " (position still open)");
      return; // do not touch win/loss counters or martingale yet - trade isn't finished
   }

   // --- Position fully closed: evaluate NET result of the entire trade ---
   double netProfit = g_trackPositionProfit;
   if(netProfit > 0)
   {
      g_dailyWins++;
      g_martingaleStep = 0; // reset lot size to base after a net-winning trade
   }
   else if(netProfit < 0)
   {
      g_dailyLosses++;
      if(InpUseMartingale)
      {
         g_martingaleStep++;
         if(g_martingaleStep > InpMaxMartingaleSteps)
         {
            g_martingaleStep = InpMaxMartingaleSteps; // capped, does not reset itself
            LogAndNotify(StringFormat("%s: Max martingale steps (%d) reached. Lot size capped.", _Symbol, InpMaxMartingaleSteps));
         }
      }
   }
   // netProfit == 0 (exact breakeven) -> neither win nor loss, martingale step unchanged

   if(InpVerboseLogging)
      Print("Trade fully closed. NET Profit=", netProfit, " | Daily P/L=", g_dailyRealizedPL, " | Martingale step=", g_martingaleStep);

   g_trackPositionID     = 0;
   g_trackPositionProfit = 0.0;
}

//======================================================================
// DASHBOARD DISPLAY
//======================================================================
void UpdateDashboard()
{
   if(!InpShowDashboard) return;

   int totalClosed = g_dailyWins + g_dailyLosses;
   double winRate = (totalClosed > 0) ? (100.0 * g_dailyWins / totalClosed) : 0.0;

   string regimeStr = (g_regime == REGIME_TREND) ? "TREND" : (g_regime == REGIME_RANGE) ? "RANGE" : "NEUTRAL";
   int posDir = OpenPositionDirection();
   string posStr = (posDir == 1) ? "LONG" : (posDir == -1) ? "SHORT" : "FLAT";

   string txt = "";
   txt += "=== RegimeSwitch EA ===\n";
   txt += "Symbol: " + _Symbol + "  TF: M15\n";
   txt += "Market Regime : " + regimeStr + "\n";
   txt += "Active Strategy: " + g_strategyLabel + "\n";
   txt += "Current Position: " + posStr + "\n";
   txt += "Trades Today: " + IntegerToString(g_dailyTradesCount) + " / " + IntegerToString(InpMaxTradesPerDay) + "\n";
   txt += "Win Rate Today: " + DoubleToString(winRate, 1) + "% (" + IntegerToString(g_dailyWins) + "W/" + IntegerToString(g_dailyLosses) + "L)\n";
   txt += "Daily P/L: " + DoubleToString(g_dailyRealizedPL, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
   txt += "Daily Loss Limit Hit: " + (g_dailyLossLimitHit ? "YES" : "no") + "\n";
   txt += "Spread: " + IntegerToString((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) + " pts\n";
   txt += "Martingale Step: " + IntegerToString(g_martingaleStep) + " / " + IntegerToString(InpMaxMartingaleSteps) + "\n";
   txt += "Next Trade Lot: " + DoubleToString(CalculateLotSize(0), 2) + "\n";
   if(posDir != 0)
      txt += "Partial TP: TP1(" + (g_tp1Done?"DONE":"pending") + ")  TP2(" + (g_tp2Done?"DONE":"pending") + ")  TP3=final\n";

   Comment(txt);
}

//======================================================================
// MAIN LOGIC - EXECUTED ONCE PER NEW BAR (CANDLE CLOSE)
//======================================================================
void ProcessNewBar()
{
   // Prevent duplicate processing of the same closed bar
   datetime closedBarTime = iTime(_Symbol, PERIOD_M15, 1);
   if(closedBarTime == g_lastSignalBarTime) return;
   g_lastSignalBarTime = closedBarTime;

   double emaFast1, emaFast2, emaSlow1, emaSlow2, adxMain, rsi1, bbUp1, bbLo1, bbMid1, atr1;
   if(!GetIndicatorSnapshot(emaFast1, emaFast2, emaSlow1, emaSlow2, adxMain, rsi1, bbUp1, bbLo1, bbMid1, atr1))
   {
      if(InpVerboseLogging) Print("Indicator data not ready yet.");
      return;
   }

   g_regime = DetectRegime(emaFast1, emaSlow1, adxMain);

   int posDir = OpenPositionDirection();

   // ---------- Manage existing position: exit on opposite signal ----------
   if(posDir != 0)
   {
      if(g_regime == REGIME_TREND)
      {
         int sig = TrendSignal(emaFast1, emaSlow1);
         if(sig != 0 && sig != posDir)
         {
            CloseCurrentPosition("Opposite trend signal");
            posDir = 0;
         }
      }
      else if(g_regime == REGIME_RANGE)
      {
         int sig = MeanReversionSignal(rsi1, bbUp1, bbLo1);
         if(sig != 0 && sig != posDir)
         {
            CloseCurrentPosition("Opposite mean-reversion signal");
            posDir = 0;
         }
      }
   }

   // ---------- Update active strategy label ----------
   if(g_regime == REGIME_TREND)      g_strategyLabel = "TREND FOLLOWING";
   else if(g_regime == REGIME_RANGE) g_strategyLabel = "MEAN REVERSION";
   else                               g_strategyLabel = "NEUTRAL (no entries)";

   // ---------- Entry filters (applies to new entries only) ----------
   if(posDir != 0) return;               // one position per symbol rule
   if(!DailyLimitsOK()) return;          // daily loss / trade count limits
   if(!SpreadOK()) return;               // spread filter
   if(!IsWithinSession()) return;        // session filter

   // ---------- Generate & execute entry signal based on regime ----------
   if(g_regime == REGIME_TREND)
   {
      int sig = TrendSignal(emaFast1, emaSlow1);
      if(sig != 0)
      {
         symInfo.RefreshRates();
         double entryPrice = (sig == 1) ? symInfo.Ask() : symInfo.Bid();
         double sl, tp;
         CalcTrendSLTP(sig, entryPrice, atr1, sl, tp);
         OpenTrade(sig, sl, tp, "TrendFollow");
      }
   }
   else if(g_regime == REGIME_RANGE)
   {
      int sig = MeanReversionSignal(rsi1, bbUp1, bbLo1);
      if(sig != 0)
      {
         symInfo.RefreshRates();
         double entryPrice = (sig == 1) ? symInfo.Ask() : symInfo.Bid();
         double sl, tp;
         CalcRangeSLTP(sig, entryPrice, bbMid1, sl, tp);
         OpenTrade(sig, sl, tp, "MeanReversion");
      }
   }
   // REGIME_NONE -> no new entries (transitional market)
}

//======================================================================
// ON TICK
//======================================================================
void OnTick()
{
   CheckNewDay();

   ManagePartialTakeProfits(); // must run every tick for intrabar partial booking

   if(IsNewBar())
      ProcessNewBar();

   UpdateDashboard();
}
//+------------------------------------------------------------------+
