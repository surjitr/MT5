//+------------------------------------------------------------------+
//|                                                       trendy.mq5  |
//|         D1 Trendline Reversal — auto-detect pivots, hold trade   |
//|         until trendline is broken, then reverse direction.        |
//+------------------------------------------------------------------+
#property copyright "Trendy EA"
#property version   "1.00"
#property description "D1 trendline-break reversal strategy."
#property description "Detects swing pivots, draws supporting/resisting trendline,"
#property description "reverses position when D1 closes through the line."
#property description "Position is held until next trendline break."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "=== Pivot / Trendline ==="
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_D1;     // Working Timeframe
input int    InpPivotLookback          = 3;             // Bars each side for swing pivot
input int    InpMinPivotSpacing        = 5;             // Min bars between pivots used for line
input int    InpScanBars               = 200;           // History bars scanned for pivots
input double InpBreakBufferATR         = 0.5;           // Break must exceed line by x * ATR

input group "=== Trend Strength Filter ==="
input bool   InpUseADXFilter           = true;          // Skip reversals when market is ranging
input int    InpADXPeriod              = 14;            // ADX period
input double InpADXMin                 = 20.0;          // Min ADX to trade (range-filter)

input group "=== Risk Management ==="
input double InpRiskPercent            = 2.0;           // Risk % per trade (SL = pivot beyond)
input int    InpATRPeriod              = 14;            // ATR period
input double InpMinSL_ATR              = 1.0;           // Min SL distance = x * ATR floor
input double InpMaxLot                 = 0.50;          // Max lot size cap
input double InpMaxDailyLossPct        = 6.0;           // Daily loss halt %
input double InpMaxDrawdownPct         = 20.0;          // Hard drawdown halt %

input group "=== Symbols ==="
input bool   InpSingleSymbol           = true;          // true=chart symbol only, false=multi-pair
input string InpSuffix                 = "";            // Broker symbol suffix
input double InpMaxSpreadPips          = 5.0;           // Max spread (pips)

input group "=== Visual ==="
input bool   InpDrawTrendlines         = true;          // Draw active trendlines on chart
input bool   InpDrawPivots             = true;          // Draw pivot dots on chart
input color  InpUpLineColor            = clrLime;       // Up-trendline color
input color  InpDownLineColor          = clrRed;        // Down-trendline color
input color  InpPivotColor             = clrYellow;     // Pivot dot color

input group "=== General ==="
input long   InpMagic                  = 990511;        // Magic Number
input bool   InpAlerts                 = false;
input bool   InpVerboseLog             = true;          // Per-bar reasoning logs

//+------------------------------------------------------------------+
//| Trend mode                                                        |
//+------------------------------------------------------------------+
enum ENUM_TREND_MODE
{
   MODE_FLAT  = 0,   // No active trend yet (bootstrap)
   MODE_LONG  = 1,   // In uptrend: line through swing lows; break below = reverse short
   MODE_SHORT = -1   // In downtrend: line through swing highs; break above = reverse long
};

//+------------------------------------------------------------------+
//| Per-symbol data                                                   |
//+------------------------------------------------------------------+
struct SPivot
{
   datetime time;
   double   price;
   int      shift;   // bar index back from current (rolling)
};

struct SSymbolData
{
   string          name;
   int             hATR;
   int             hADX;
   datetime        lastBarTime;
   double          pipSize;
   bool            active;
   ENUM_TREND_MODE mode;
   // Pivots (most recent first, index 0 = newest)
   SPivot          pivotHighs[];
   SPivot          pivotLows[];
};

SSymbolData g_symbols[];
int         g_numSymbols       = 0;
CTrade      g_trade;
double      g_dayStartBalance  = 0;
double      g_peakEquity       = 0;
datetime    g_lastDay          = 0;
bool        g_drawdownHalted   = false;

string BASE_SYMBOLS[] =
{
   "EURUSD","GBPUSD","USDJPY","USDCHF","AUDUSD","NZDUSD","USDCAD",
   "EURGBP","EURJPY","GBPJPY","AUDJPY","EURAUD","GBPAUD"
};

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);

   string symList[];
   if(InpSingleSymbol)
   {
      ArrayResize(symList, 1);
      symList[0] = _Symbol;
   }
   else
   {
      int total = ArraySize(BASE_SYMBOLS);
      ArrayResize(symList, total);
      for(int i = 0; i < total; i++) symList[i] = BASE_SYMBOLS[i] + InpSuffix;
   }

   int total = ArraySize(symList);
   ArrayResize(g_symbols, total);
   g_numSymbols = 0;

   for(int i = 0; i < total; i++)
   {
      string sym = symList[i];
      if(!SymbolSelect(sym, true))
      {
         PrintFormat("[INIT] %s not available, skipping", sym);
         continue;
      }

      int idx = g_numSymbols;
      g_symbols[idx].name        = sym;
      g_symbols[idx].lastBarTime = 0;
      g_symbols[idx].active      = true;
      g_symbols[idx].mode        = MODE_FLAT;

      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      g_symbols[idx].pipSize = (digits == 3 || digits == 5)
                               ? 10.0 * SymbolInfoDouble(sym, SYMBOL_POINT)
                               : SymbolInfoDouble(sym, SYMBOL_POINT);

      datetime dummy[];
      CopyTime(sym, InpTimeframe, 0, InpScanBars + 20, dummy);

      g_symbols[idx].hATR = iATR(sym, InpTimeframe, InpATRPeriod);
      g_symbols[idx].hADX = iADX(sym, InpTimeframe, InpADXPeriod);
      if(g_symbols[idx].hATR == INVALID_HANDLE || g_symbols[idx].hADX == INVALID_HANDLE)
      {
         PrintFormat("[INIT] Indicator handle failed for %s", sym);
         g_symbols[idx].active = false;
      }

      g_numSymbols++;
   }

   if(g_numSymbols == 0)
   {
      Alert("Trendy: no valid symbols");
      return INIT_FAILED;
   }
   ArrayResize(g_symbols, g_numSymbols);

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastDay         = iTime(_Symbol, PERIOD_D1, 0);

   EventSetTimer(60);

   PrintFormat("[INIT] Trendy started: %d symbols, Magic=%d, Risk=%.1f%%, TF=%s",
               g_numSymbols, InpMagic, InpRiskPercent, EnumToString(InpTimeframe));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < g_numSymbols; i++)
   {
      if(g_symbols[i].hATR != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hATR);
      if(g_symbols[i].hADX != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hADX);
   }
   if(InpSingleSymbol) ClearChartObjects(_Symbol);
   Comment("");
}

void OnTimer() { MainLogic(); }
void OnTick()  { MainLogic(); }

//+------------------------------------------------------------------+
void MainLogic()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;

   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != g_lastDay)
   {
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_lastDay = today;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity) g_peakEquity = equity;

   if(CheckDrawdownHalted())  { DisplayDashboard("!! DRAWDOWN HALT !!"); return; }
   if(CheckDailyLossExceeded()){ DisplayDashboard("!! DAILY LOSS LIMIT !!"); return; }

   for(int i = 0; i < g_numSymbols; i++)
   {
      if(!g_symbols[i].active) continue;
      if(!IsNewBar(i)) continue;

      ProcessSymbol(i);
   }

   DisplayDashboard("");
}

//+------------------------------------------------------------------+
//| Process a single symbol on its new bar close                     |
//+------------------------------------------------------------------+
void ProcessSymbol(int idx)
{
   string sym = g_symbols[idx].name;

   // 1. Refresh confirmed pivots from history
   DetectPivots(idx);

   // ADX trend-strength check (range filter)
   bool adxOK = IsADXStrong(idx);

   // 2. Bootstrap mode if FLAT
   if(g_symbols[idx].mode == MODE_FLAT)
   {
      BootstrapMode(idx);
      if(g_symbols[idx].mode == MODE_FLAT)
      {
         if(InpVerboseLog) PrintFormat("[%s] Bootstrapping — not enough pivots yet (H:%d L:%d)",
                                       sym, ArraySize(g_symbols[idx].pivotHighs),
                                       ArraySize(g_symbols[idx].pivotLows));
         return;
      }
      // Bootstrapped — open initial position only if trend strong enough
      if(adxOK)
         OpenPosition(idx, g_symbols[idx].mode);
      else
         PrintFormat("[%s] Bootstrap %s — skipping initial entry (ADX too low)",
                     sym, ModeStr(g_symbols[idx].mode));
   }

   // 3. Build trendline for current mode and check break
   double lineNow;
   bool   haveLine = BuildTrendline(idx, g_symbols[idx].mode, lineNow);
   if(!haveLine)
   {
      if(InpVerboseLog) PrintFormat("[%s] No valid trendline for %s mode",
                                    sym, ModeStr(g_symbols[idx].mode));
      DrawTrendline(idx);
      return;
   }

   double atr[2];
   if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atr) != 2) return;
   ArraySetAsSeries(atr, true);
   double buffer = InpBreakBufferATR * atr[1];

   // We check the just-closed bar (shift 1) for the break
   double close1 = iClose(sym, InpTimeframe, 1);
   if(close1 == 0) return;

   bool broken = false;
   if(g_symbols[idx].mode == MODE_LONG)
   {
      if(close1 < lineNow - buffer)
      {
         broken = true;
         PrintFormat("[%s] BREAK DOWN: close=%.5f < line=%.5f - buf=%.5f -> reversing to SHORT",
                     sym, close1, lineNow, buffer);
      }
      else if(InpVerboseLog)
      {
         PrintFormat("[%s] LONG holding: close=%.5f >= line=%.5f - buf=%.5f (ATR=%.5f)",
                     sym, close1, lineNow, buffer, atr[1]);
      }
   }
   else if(g_symbols[idx].mode == MODE_SHORT)
   {
      if(close1 > lineNow + buffer)
      {
         broken = true;
         PrintFormat("[%s] BREAK UP: close=%.5f > line=%.5f + buf=%.5f -> reversing to LONG",
                     sym, close1, lineNow, buffer);
      }
      else if(InpVerboseLog)
      {
         PrintFormat("[%s] SHORT holding: close=%.5f <= line=%.5f + buf=%.5f (ATR=%.5f)",
                     sym, close1, lineNow, buffer, atr[1]);
      }
   }

   if(broken)
   {
      ClosePosition(sym);
      ENUM_TREND_MODE newMode = (g_symbols[idx].mode == MODE_LONG) ? MODE_SHORT : MODE_LONG;
      g_symbols[idx].mode = newMode;
      // Range-filter: only re-enter in the new direction if ADX confirms strong trend
      if(adxOK)
         OpenPosition(idx, newMode);
      else
         PrintFormat("[%s] Reversal to %s skipped — ADX below %.1f (ranging)",
                     sym, ModeStr(newMode), InpADXMin);
   }

   DrawTrendline(idx);
}

//+------------------------------------------------------------------+
//| ADX range filter                                                  |
//+------------------------------------------------------------------+
bool IsADXStrong(int idx)
{
   if(!InpUseADXFilter) return true;
   double adx[2];
   if(CopyBuffer(g_symbols[idx].hADX, 0, 0, 2, adx) != 2) return false;
   ArraySetAsSeries(adx, true);
   bool ok = (adx[1] >= InpADXMin);
   if(!ok && InpVerboseLog)
      PrintFormat("[%s] ADX=%.1f < %.1f (ranging — entries blocked)",
                  g_symbols[idx].name, adx[1], InpADXMin);
   return ok;
}

//+------------------------------------------------------------------+
//| Detect swing pivots over last InpScanBars                         |
//| Pivot high at shift k: high[k] > high[k-N..k-1] && high[k] > high[k+1..k+N]
//| Pivot low: mirror                                                 |
//+------------------------------------------------------------------+
void DetectPivots(int idx)
{
   string sym = g_symbols[idx].name;
   int N = InpPivotLookback;
   int scan = InpScanBars;

   ArrayResize(g_symbols[idx].pivotHighs, 0);
   ArrayResize(g_symbols[idx].pivotLows,  0);

   // We need bars at least N to the right of the candidate (newer); shift candidate
   // ranges from N+1 (just-confirmed) up to scan bars back.
   int barsAvail = Bars(sym, InpTimeframe);
   int maxShift  = MathMin(scan, barsAvail - N - 1);

   for(int k = N + 1; k <= maxShift; k++)
   {
      double hk = iHigh(sym, InpTimeframe, k);
      double lk = iLow(sym,  InpTimeframe, k);
      if(hk == 0 || lk == 0) continue;

      bool isHigh = true, isLow = true;
      for(int j = 1; j <= N; j++)
      {
         double hL = iHigh(sym, InpTimeframe, k + j);
         double hR = iHigh(sym, InpTimeframe, k - j);
         double lL = iLow(sym,  InpTimeframe, k + j);
         double lR = iLow(sym,  InpTimeframe, k - j);
         if(hL >= hk || hR >= hk) isHigh = false;
         if(lL <= lk || lR <= lk) isLow  = false;
         if(!isHigh && !isLow) break;
      }

      if(isHigh)
      {
         SPivot p;
         p.time  = iTime(sym, InpTimeframe, k);
         p.price = hk;
         p.shift = k;
         AppendPivot(g_symbols[idx].pivotHighs, p);
      }
      if(isLow)
      {
         SPivot p;
         p.time  = iTime(sym, InpTimeframe, k);
         p.price = lk;
         p.shift = k;
         AppendPivot(g_symbols[idx].pivotLows, p);
      }
   }

   // pivotHighs/Lows are in shift order (newest = smallest shift = first added)
}

void AppendPivot(SPivot &arr[], SPivot &p)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = p;
}

//+------------------------------------------------------------------+
//| Bootstrap initial trend mode from most recent pivot pattern       |
//+------------------------------------------------------------------+
void BootstrapMode(int idx)
{
   int hN = ArraySize(g_symbols[idx].pivotHighs);
   int lN = ArraySize(g_symbols[idx].pivotLows);
   if(hN < 2 || lN < 2) return;

   SPivot h0 = g_symbols[idx].pivotHighs[0]; // newest high
   SPivot h1 = g_symbols[idx].pivotHighs[1];
   SPivot l0 = g_symbols[idx].pivotLows[0];
   SPivot l1 = g_symbols[idx].pivotLows[1];

   // If newest high is more recent (smaller shift) than newest low and is descending → likely down
   // Strict: ascending lows → up; descending highs → down
   bool ascendingLows  = (l0.price > l1.price);
   bool descendingHighs= (h0.price < h1.price);

   if(ascendingLows && !descendingHighs)
      g_symbols[idx].mode = MODE_LONG;
   else if(descendingHighs && !ascendingLows)
      g_symbols[idx].mode = MODE_SHORT;
   else if(ascendingLows && descendingHighs)
   {
      // Conflict — pick by which pivot is more recent
      g_symbols[idx].mode = (l0.shift < h0.shift) ? MODE_LONG : MODE_SHORT;
   }
   // else: indeterminate, stay FLAT

   if(g_symbols[idx].mode != MODE_FLAT)
      PrintFormat("[%s] Bootstrap mode = %s (lows %.5f->%.5f highs %.5f->%.5f)",
                  g_symbols[idx].name, ModeStr(g_symbols[idx].mode),
                  l1.price, l0.price, h1.price, h0.price);
}

//+------------------------------------------------------------------+
//| Build trendline value at current bar (shift=1, just-closed)       |
//| Uptrend line: through 2 most recent ascending lows                |
//| Downtrend line: through 2 most recent descending highs            |
//+------------------------------------------------------------------+
bool BuildTrendline(int idx, ENUM_TREND_MODE mode, double &lineNow)
{
   if(mode == MODE_LONG)
   {
      SPivot a, b;
      if(!FindLineLows(idx, a, b)) return false;
      // a = older, b = newer (smaller shift). We want line value at shift=1.
      // Slope per bar = (b.price - a.price) / (a.shift - b.shift)
      int dx = a.shift - b.shift;
      if(dx <= 0) return false;
      double slope = (b.price - a.price) / dx;
      // Line value at shift=1 (just-closed bar): start from b, extrapolate forward (b.shift -> 1)
      lineNow = b.price + slope * (b.shift - 1);
      return true;
   }
   else if(mode == MODE_SHORT)
   {
      SPivot a, b;
      if(!FindLineHighs(idx, a, b)) return false;
      int dx = a.shift - b.shift;
      if(dx <= 0) return false;
      double slope = (b.price - a.price) / dx;
      lineNow = b.price + slope * (b.shift - 1);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find 2 most recent ASCENDING swing lows for uptrend support line  |
//| b = newer, a = older. b.price > a.price. Spacing >= InpMinPivotSpacing
//+------------------------------------------------------------------+
bool FindLineLows(int idx, SPivot &a, SPivot &b)
{
   int n = ArraySize(g_symbols[idx].pivotLows);
   if(n < 2) return false;
   for(int j = 0; j < n; j++)
   {
      SPivot bn = g_symbols[idx].pivotLows[j];
      for(int k = j + 1; k < n; k++)
      {
         SPivot an = g_symbols[idx].pivotLows[k];
         if(an.shift - bn.shift < InpMinPivotSpacing) continue;
         if(bn.price > an.price)  // ascending
         {
            a = an; b = bn;
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find 2 most recent DESCENDING swing highs for downtrend line      |
//+------------------------------------------------------------------+
bool FindLineHighs(int idx, SPivot &a, SPivot &b)
{
   int n = ArraySize(g_symbols[idx].pivotHighs);
   if(n < 2) return false;
   for(int j = 0; j < n; j++)
   {
      SPivot bn = g_symbols[idx].pivotHighs[j];
      for(int k = j + 1; k < n; k++)
      {
         SPivot an = g_symbols[idx].pivotHighs[k];
         if(an.shift - bn.shift < InpMinPivotSpacing) continue;
         if(bn.price < an.price)  // descending
         {
            a = an; b = bn;
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Open a position in the given direction                            |
//+------------------------------------------------------------------+
bool OpenPosition(int idx, ENUM_TREND_MODE direction)
{
   if(direction == MODE_FLAT) return false;
   string sym = g_symbols[idx].name;

   if(GetSpreadPips(idx) > InpMaxSpreadPips)
   {
      PrintFormat("[%s] SKIP open: spread too wide", sym);
      return false;
   }

   double atr[2];
   if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atr) != 2) return false;
   ArraySetAsSeries(atr, true);
   double atrVal = atr[1];

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   // SL: beyond the most recent opposite pivot, with ATR floor
   double sl, slDist, entry;
   if(direction == MODE_LONG)
   {
      entry = SymbolInfoDouble(sym, SYMBOL_ASK);
      double pivotSL = entry - atrVal * InpMinSL_ATR;
      int n = ArraySize(g_symbols[idx].pivotLows);
      if(n > 0) pivotSL = MathMin(pivotSL, g_symbols[idx].pivotLows[0].price - atrVal * 0.2);
      sl = pivotSL;
      slDist = entry - sl;
   }
   else
   {
      entry = SymbolInfoDouble(sym, SYMBOL_BID);
      double pivotSL = entry + atrVal * InpMinSL_ATR;
      int n = ArraySize(g_symbols[idx].pivotHighs);
      if(n > 0) pivotSL = MathMax(pivotSL, g_symbols[idx].pivotHighs[0].price + atrVal * 0.2);
      sl = pivotSL;
      slDist = sl - entry;
   }

   if(slDist <= 0)
   {
      PrintFormat("[%s] SKIP open: SL distance <= 0", sym);
      return false;
   }

   double stopLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) *
                    SymbolInfoDouble(sym, SYMBOL_POINT);
   if(slDist < stopLvl * 1.2)
   {
      slDist = stopLvl * 1.2;
      sl = (direction == MODE_LONG) ? entry - slDist : entry + slDist;
   }
   sl = NormalizeDouble(sl, digits);

   double lots = CalculateLotSize(sym, slDist);
   if(lots <= 0)
   {
      PrintFormat("[%s] SKIP open: lot calc zero", sym);
      return false;
   }

   double marginReq = 0;
   ENUM_ORDER_TYPE ot = (direction == MODE_LONG) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(ot, sym, lots, entry, marginReq)) return false;
   if(marginReq > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      PrintFormat("[%s] SKIP open: insufficient margin", sym);
      return false;
   }

   g_trade.SetTypeFilling(GetFillingType(sym));
   bool ok = false;
   string comment = StringFormat("TRENDY_%s", sym);
   if(direction == MODE_LONG)  ok = g_trade.Buy(lots, sym, entry, sl, 0, comment);
   else                        ok = g_trade.Sell(lots, sym, entry, sl, 0, comment);

   if(ok)
   {
      PrintFormat("[%s] %s opened | lots=%.2f entry=%.*f SL=%.*f slDist=%.5f",
                  sym, (direction == MODE_LONG) ? "LONG" : "SHORT",
                  lots, digits, entry, digits, sl, slDist);
      if(InpAlerts) Alert(StringFormat("Trendy %s %s %.2f", sym,
                          (direction == MODE_LONG) ? "BUY" : "SELL", lots));
   }
   else
   {
      PrintFormat("[%s] OPEN FAILED: %s", sym, g_trade.ResultRetcodeDescription());
   }
   return ok;
}

//+------------------------------------------------------------------+
void ClosePosition(string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      g_trade.SetTypeFilling(GetFillingType(sym));
      if(g_trade.PositionClose(t))
         PrintFormat("[%s] Position closed (reversal)", sym);
   }
}

//+------------------------------------------------------------------+
double CalculateLotSize(string sym, double sl_distance)
{
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney= equity * InpRiskPercent / 100.0;
   double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0 || sl_distance <= 0) return 0;

   double slTicks    = sl_distance / tickSize;
   double riskPerLot = slTicks * tickVal;
   if(riskPerLot <= 0) return 0;

   double lots    = riskMoney / riskPerLot;
   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = MathMin(lots, InpMaxLot);

   double minLotRisk = minLot * riskPerLot;
   if(lots == minLot && minLotRisk > riskMoney * 1.5) return 0;

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Chart drawing                                                     |
//+------------------------------------------------------------------+
void DrawTrendline(int idx)
{
   if(!InpDrawTrendlines) return;
   string sym = g_symbols[idx].name;
   if(sym != _Symbol) return;  // only draw on the chart we're attached to

   ClearChartObjects(sym);

   // Pivot dots
   if(InpDrawPivots)
   {
      int hN = ArraySize(g_symbols[idx].pivotHighs);
      int lN = ArraySize(g_symbols[idx].pivotLows);
      for(int j = 0; j < hN && j < 10; j++)
         DrawPivotDot("trendy_ph_" + IntegerToString(j),
                      g_symbols[idx].pivotHighs[j].time,
                      g_symbols[idx].pivotHighs[j].price);
      for(int j = 0; j < lN && j < 10; j++)
         DrawPivotDot("trendy_pl_" + IntegerToString(j),
                      g_symbols[idx].pivotLows[j].time,
                      g_symbols[idx].pivotLows[j].price);
   }

   ENUM_TREND_MODE mode = g_symbols[idx].mode;
   if(mode == MODE_FLAT) return;

   SPivot a, b;
   bool found = (mode == MODE_LONG) ? FindLineLows(idx, a, b) : FindLineHighs(idx, a, b);
   if(!found) return;

   color clr = (mode == MODE_LONG) ? InpUpLineColor : InpDownLineColor;
   string name = "trendy_line";
   ObjectDelete(0, name);
   if(ObjectCreate(0, name, OBJ_TREND, 0, a.time, a.price, b.time, b.price))
   {
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }
}

void DrawPivotDot(string name, datetime t, double price)
{
   ObjectDelete(0, name);
   if(ObjectCreate(0, name, OBJ_ARROW, 0, t, price))
   {
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 159);
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpPivotColor);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   }
}

void ClearChartObjects(string sym)
{
   if(sym != _Symbol) return;
   ObjectsDeleteAll(0, "trendy_");
}

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
bool IsNewBar(int idx)
{
   datetime t = iTime(g_symbols[idx].name, InpTimeframe, 0);
   if(t == 0) return false;
   if(t != g_symbols[idx].lastBarTime)
   {
      g_symbols[idx].lastBarTime = t;
      return true;
   }
   return false;
}

double GetSpreadPips(int idx)
{
   string sym = g_symbols[idx].name;
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(g_symbols[idx].pipSize <= 0) return 999;
   return (ask - bid) / g_symbols[idx].pipSize;
}

bool CheckDailyLossExceeded()
{
   if(g_dayStartBalance <= 0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return ((g_dayStartBalance - equity) / g_dayStartBalance * 100.0 >= InpMaxDailyLossPct);
}

bool CheckDrawdownHalted()
{
   if(g_peakEquity <= 0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_peakEquity - equity) / g_peakEquity * 100.0;
   if(dd >= InpMaxDrawdownPct) g_drawdownHalted = true;
   return g_drawdownHalted;
}

ENUM_ORDER_TYPE_FILLING GetFillingType(string sym)
{
   long f = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((f & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

string ModeStr(ENUM_TREND_MODE m)
{
   if(m == MODE_LONG)  return "LONG";
   if(m == MODE_SHORT) return "SHORT";
   return "FLAT";
}

//+------------------------------------------------------------------+
void DisplayDashboard(string extra)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd = g_peakEquity > 0 ? (g_peakEquity - equity) / g_peakEquity * 100.0 : 0;

   string dash = "\n========== TRENDY ==========\n";
   dash += StringFormat("Balance : %.2f %s\n", balance, AccountInfoString(ACCOUNT_CURRENCY));
   dash += StringFormat("Equity  : %.2f (peak %.2f)\n", equity, g_peakEquity);
   dash += StringFormat("Drawdown: %.1f%% / %.1f%%\n", dd, InpMaxDrawdownPct);
   dash += StringFormat("Risk    : %.1f%% | TF: %s\n", InpRiskPercent, EnumToString(InpTimeframe));
   dash += StringFormat("Pivot   : N=%d | break=%.2fxATR\n", InpPivotLookback, InpBreakBufferATR);

   for(int i = 0; i < g_numSymbols; i++)
   {
      dash += StringFormat("%s: %s | H:%d L:%d\n",
              g_symbols[i].name, ModeStr(g_symbols[i].mode),
              ArraySize(g_symbols[i].pivotHighs),
              ArraySize(g_symbols[i].pivotLows));
   }

   if(extra != "") dash += "\n>> " + extra + "\n";
   dash += "============================";
   Comment(dash);
}
//+------------------------------------------------------------------+
