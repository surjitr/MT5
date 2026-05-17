//+------------------------------------------------------------------+
//|                                                   SwingPro.mq5   |
//|            Aggressive swing / trend-extension EA (Forex)         |
//|                Capital: 900-9000 AUD | Higher frequency          |
//+------------------------------------------------------------------+
#property copyright "SwingPro EA"
#property version   "1.00"
#property description "Higher-frequency swing trading with pyramiding."
#property description "H4 trend + H1 pullback entries. Partial TP + trail."
#property description "NO guarantees — aggressive params increase both upside and drawdown."
#property description "Backtest on your broker's data before going live."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "=== Trend Filter (H4) ==="
input ENUM_TIMEFRAMES InpTrendTF       = PERIOD_D1;     // Trend Timeframe
input int    InpTrendEMAFast           = 50;            // D1 Fast EMA
input int    InpTrendEMASlow           = 200;           // D1 Slow EMA
input int    InpTrendADXPeriod         = 14;            // D1 ADX Period
input double InpTrendADXMin            = 18.0;          // Min ADX to confirm trend
input bool   InpUseD1Context           = false;         // Now redundant — trend TF is D1
input int    InpD1EMA                  = 50;            // D1 EMA (kept for back-compat, unused)

input group "=== Entry Timing (H4) ==="
input ENUM_TIMEFRAMES InpEntryTF       = PERIOD_H4;     // Entry Timeframe
input int    InpEntryEMA               = 20;            // H4 Pullback EMA
input int    InpRSIPeriod              = 14;            // H4 RSI Period
input int    InpATRPeriod              = 14;            // H4 ATR Period
input int    InpDonchianPeriod         = 20;            // Donchian Breakout Period
input int    InpMACDFast               = 12;            // MACD Fast
input int    InpMACDSlow               = 26;            // MACD Slow
input int    InpMACDSignal             = 9;             // MACD Signal
input double InpRSILongMin             = 40.0;          // Long RSI zone min
input double InpRSILongMax             = 70.0;          // Long RSI zone max
input double InpRSIShortMin            = 30.0;          // Short RSI zone min
input double InpRSIShortMax            = 60.0;          // Short RSI zone max
input double InpBreakoutADXMin         = 20.0;          // Min ADX for breakout entries
input double InpPullbackMaxATR         = 1.5;           // Max distance from EMA in ATR

input group "=== Risk Management ==="
input double InpRiskPercent            = 1.5;           // Risk % per initial trade (lowered)
input double InpAddRiskPercent         = 0.75;          // Risk % per pyramid add (lowered)
input double InpSL_ATR                 = 2.0;           // SL = x * ATR (H4)
input double InpPartialTP_R            = 2.0;           // Partial TP at x * R (raised — let R:R work)
input double InpPartialClosePct        = 50.0;          // % of position to close at partial TP
input double InpTrailStart_R           = 2.0;           // Start trail at x * R profit (raised)
input double InpTrailDist_ATR          = 2.5;           // Trail distance = x * ATR (looser)
input int    InpMaxTrades              = 4;             // Max concurrent positions (lowered)
input int    InpMaxPerCurrency         = 1;             // Max positions per currency (lowered)
input int    InpMaxPyramidAdds         = 1;             // Max pyramid adds per symbol (lowered)
input double InpPyramidTrigger_R       = 2.0;           // Add when running trade is +x*R (raised)
input double InpMaxLot                 = 0.50;          // Max total lots per symbol
input double InpMaxDailyLossPct        = 4.0;           // Daily loss halt (tighter)
input double InpMaxDrawdownPct         = 15.0;          // Hard drawdown halt (tighter)
input int    InpCooldownBars           = 4;             // Min H4 bars between entries per symbol
input int    InpMaxHoldBars            = 60;            // Max H4 bars to hold (~10 trading days)

input group "=== Session & Weekend ==="
input int    InpSessionStart           = 0;             // Session Start (GMT)
input int    InpSessionEnd             = 23;            // Session End (GMT)
input bool   InpCloseBeforeWeekend     = false;         // Force close Friday
input int    InpFridayCloseHourGMT     = 20;

input group "=== Symbols ==="
input string InpSuffix                 = "";            // Broker Symbol Suffix
input bool   InpSingleSymbol           = false;         // true = chart symbol only; false = all pairs
input double InpMaxSpreadPips          = 3.0;           // Max spread majors/minors
input double InpMaxSpreadPipsExotic    = 15.0;

input group "=== General ==="
input long   InpMagic                  = 931010;        // Magic Number
input bool   InpAlerts                 = false;
input bool   InpPushNotify             = false;
input bool   InpVerboseLog             = false;
input bool   InpLogEveryCheck          = false;

//+------------------------------------------------------------------+
//| Per-symbol data                                                   |
//+------------------------------------------------------------------+
struct SSymbolData
{
   string   name;
   int      hTrendEMAFast;
   int      hTrendEMASlow;
   int      hTrendADX;
   int      hD1EMA;
   int      hEntryEMA;
   int      hRSI;
   int      hATR;
   int      hMACD;
   datetime lastBarTime;
   datetime lastEntryTime;
   double   pipSize;
   bool     active;
   bool     isExotic;
};

SSymbolData g_symbols[];
int         g_numSymbols       = 0;
CTrade      g_trade;
double      g_dayStartBalance  = 0;
double      g_peakEquity       = 0;
datetime    g_lastDay          = 0;
int         g_todayTrades      = 0;
bool        g_drawdownHalted   = false;

string BASE_SYMBOLS[] =
{
   "EURUSD","GBPUSD","USDJPY","USDCHF","AUDUSD","NZDUSD","USDCAD",
   "EURGBP","EURJPY","EURCHF","EURAUD","EURNZD","EURCAD",
   "GBPJPY","GBPCHF","GBPAUD","GBPNZD","GBPCAD",
   "AUDJPY","AUDNZD","AUDCAD","AUDCHF",
   "NZDJPY","NZDCAD","NZDCHF",
   "CADJPY","CADCHF","CHFJPY",
   "USDTRY","USDZAR","USDMXN","USDSGD","USDHKD","USDNOK","USDSEK","USDDKK","USDPLN","USDCZK","USDHUF",
   "EURTRY","EURZAR","EURMXN","EURNOK","EURSEK","EURDKK","EURPLN","EURHUF",
   "GBPTRY","GBPZAR","GBPNOK","GBPSEK"
};

string EXOTIC_QUOTES[] = { "TRY","ZAR","MXN","SGD","HKD","NOK","SEK","DKK","PLN","CZK","HUF" };

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);

   // Build symbol list
   string symList[];
   if(InpSingleSymbol)
   {
      ArrayResize(symList, 1);
      symList[0] = _Symbol;
      // Strip suffix if present so pipSize logic still matches BASE_SYMBOLS-style parsing
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
      g_symbols[idx].name          = sym;
      g_symbols[idx].lastBarTime   = 0;
      g_symbols[idx].lastEntryTime = 0;
      g_symbols[idx].active        = true;
      g_symbols[idx].isExotic      = IsExoticPair(sym);

      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(digits == 3 || digits == 5)
         g_symbols[idx].pipSize = 10.0 * SymbolInfoDouble(sym, SYMBOL_POINT);
      else
         g_symbols[idx].pipSize = SymbolInfoDouble(sym, SYMBOL_POINT);

      // Prime history
      datetime dummy[];
      CopyTime(sym, PERIOD_D1,     0, InpD1EMA + 20, dummy);
      CopyTime(sym, InpTrendTF,    0, InpTrendEMASlow + 20, dummy);
      CopyTime(sym, InpEntryTF,    0, 200, dummy);

      g_symbols[idx].hTrendEMAFast = iMA(sym,  InpTrendTF,  InpTrendEMAFast, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hTrendEMASlow = iMA(sym,  InpTrendTF,  InpTrendEMASlow, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hTrendADX     = iADX(sym, InpTrendTF,  InpTrendADXPeriod);
      g_symbols[idx].hD1EMA        = iMA(sym,  PERIOD_D1,   InpD1EMA, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hEntryEMA     = iMA(sym,  InpEntryTF,  InpEntryEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hRSI          = iRSI(sym, InpEntryTF,  InpRSIPeriod, PRICE_CLOSE);
      g_symbols[idx].hATR          = iATR(sym, InpEntryTF,  InpATRPeriod);
      g_symbols[idx].hMACD         = iMACD(sym, InpEntryTF, InpMACDFast, InpMACDSlow, InpMACDSignal, PRICE_CLOSE);

      if(g_symbols[idx].hTrendEMAFast == INVALID_HANDLE ||
         g_symbols[idx].hTrendEMASlow == INVALID_HANDLE ||
         g_symbols[idx].hTrendADX     == INVALID_HANDLE ||
         g_symbols[idx].hD1EMA        == INVALID_HANDLE ||
         g_symbols[idx].hEntryEMA     == INVALID_HANDLE ||
         g_symbols[idx].hRSI          == INVALID_HANDLE ||
         g_symbols[idx].hATR          == INVALID_HANDLE ||
         g_symbols[idx].hMACD         == INVALID_HANDLE)
      {
         PrintFormat("[INIT] Failed indicators for %s, error %d", sym, GetLastError());
         g_symbols[idx].active = false;
      }

      g_numSymbols++;
   }

   if(g_numSymbols == 0) { Alert("No symbols!"); return INIT_FAILED; }
   ArrayResize(g_symbols, g_numSymbols);

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastDay         = iTime(_Symbol, PERIOD_D1, 0);
   g_todayTrades     = 0;
   g_drawdownHalted  = false;

   EventSetTimer(15);

   PrintFormat("[INIT] SwingPro started: %d symbols, Magic=%d, Risk=%.1f%%, TrendTF=%s EntryTF=%s",
               g_numSymbols, InpMagic, InpRiskPercent,
               EnumToString(InpTrendTF), EnumToString(InpEntryTF));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < g_numSymbols; i++)
   {
      if(g_symbols[i].hTrendEMAFast != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hTrendEMAFast);
      if(g_symbols[i].hTrendEMASlow != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hTrendEMASlow);
      if(g_symbols[i].hTrendADX     != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hTrendADX);
      if(g_symbols[i].hD1EMA        != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hD1EMA);
      if(g_symbols[i].hEntryEMA     != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hEntryEMA);
      if(g_symbols[i].hRSI          != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hRSI);
      if(g_symbols[i].hATR          != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hATR);
      if(g_symbols[i].hMACD         != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hMACD);
   }
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
      g_todayTrades = 0;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity) g_peakEquity = equity;

   if(CheckDrawdownHalted())
   {
      DisplayDashboard("!! DRAWDOWN HALT !!");
      return;
   }
   if(CheckDailyLossExceeded())
   {
      DisplayDashboard("!! DAILY LOSS LIMIT !!");
      ManagePositions();
      return;
   }
   if(InpCloseBeforeWeekend && IsFridayCloseTime())
   {
      CloseAllPositions("Weekend flat");
      DisplayDashboard("Weekend close");
      return;
   }

   ManagePositions();
   TryPyramidAdds();

   int openCount = CountOpenTrades();

   for(int i = 0; i < g_numSymbols; i++)
   {
      if(!g_symbols[i].active) continue;
      if(!IsNewBar(i)) continue;

      string sym = g_symbols[i].name;
      if(InpVerboseLog) LogBarCheck(i);

      if(openCount >= InpMaxTrades) continue;
      if(HasPosition(sym)) continue;  // pyramiding handled separately
      if(!IsSessionActive()) continue;
      if(!CheckCurrencyExposure(sym)) continue;
      if(!CheckCooldown(i)) continue;

      double spreadLimit = g_symbols[i].isExotic ? InpMaxSpreadPipsExotic : InpMaxSpreadPips;
      if(GetSpreadPips(i) > spreadLimit) continue;

      int sigType = 0;
      int signal = CheckSignal(i, sigType);

      if(signal == 1)       { if(OpenBuy(i, sigType, InpRiskPercent))  { openCount++; g_todayTrades++; } }
      else if(signal == -1) { if(OpenSell(i, sigType, InpRiskPercent)) { openCount++; g_todayTrades++; } }
   }

   DisplayDashboard("");
}

//+------------------------------------------------------------------+
bool IndicatorsReady(int idx)
{
   int minH1 = MathMax(InpEntryEMA, MathMax(InpMACDSlow + InpMACDSignal, InpDonchianPeriod + 2)) + 2;
   int minHT = InpTrendEMASlow + 2;
   int minD1 = InpD1EMA + 2;

   if(BarsCalculated(g_symbols[idx].hTrendEMAFast) < minHT) return false;
   if(BarsCalculated(g_symbols[idx].hTrendEMASlow) < minHT) return false;
   if(BarsCalculated(g_symbols[idx].hTrendADX)     < minHT) return false;
   if(BarsCalculated(g_symbols[idx].hD1EMA)        < minD1) return false;
   if(BarsCalculated(g_symbols[idx].hEntryEMA)     < minH1) return false;
   if(BarsCalculated(g_symbols[idx].hRSI)          < minH1) return false;
   if(BarsCalculated(g_symbols[idx].hATR)          < minH1) return false;
   if(BarsCalculated(g_symbols[idx].hMACD)         < minH1) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Signal: 1=pullback, 2=breakout   Returns 1=Buy -1=Sell 0=None     |
//+------------------------------------------------------------------+
int CheckSignal(int idx, int &sigType)
{
   sigType = 0;
   string sym = g_symbols[idx].name;

   if(!IndicatorsReady(idx)) return 0;

   // Trend filter (H4)
   double tFast[2], tSlow[2], tAdx[2];
   if(CopyBuffer(g_symbols[idx].hTrendEMAFast, 0, 0, 2, tFast) != 2) return 0;
   if(CopyBuffer(g_symbols[idx].hTrendEMASlow, 0, 0, 2, tSlow) != 2) return 0;
   if(CopyBuffer(g_symbols[idx].hTrendADX,     0, 0, 2, tAdx)  != 2) return 0;
   ArraySetAsSeries(tFast, true);
   ArraySetAsSeries(tSlow, true);
   ArraySetAsSeries(tAdx, true);

   int trend = 0;
   if(tFast[1] > tSlow[1] && tAdx[1] >= InpTrendADXMin)      trend = 1;
   else if(tFast[1] < tSlow[1] && tAdx[1] >= InpTrendADXMin) trend = -1;
   if(trend == 0) return 0;

   // Optional D1 context
   if(InpUseD1Context)
   {
      double d1[2];
      if(CopyBuffer(g_symbols[idx].hD1EMA, 0, 0, 2, d1) != 2) return 0;
      ArraySetAsSeries(d1, true);
      double d1Close = iClose(sym, PERIOD_D1, 1);
      if(trend == 1 && d1Close < d1[1]) return 0;
      if(trend == -1 && d1Close > d1[1]) return 0;
   }

   // Entry TF indicators
   double ema[3], rsi[3], atr[3];
   double macdM[3], macdS[3];
   if(CopyBuffer(g_symbols[idx].hEntryEMA, 0, 0, 3, ema)   != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hRSI,      0, 0, 3, rsi)   != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hATR,      0, 0, 3, atr)   != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hMACD,     0, 0, 3, macdM) != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hMACD,     1, 0, 3, macdS) != 3) return 0;
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(macdM, true);
   ArraySetAsSeries(macdS, true);

   double close1 = iClose(sym, InpEntryTF, 1);
   double close2 = iClose(sym, InpEntryTF, 2);
   if(close1 == 0 || close2 == 0) return 0;
   if(atr[1] < g_symbols[idx].pipSize * 2) return 0;

   double hist1 = macdM[1] - macdS[1];
   double hist2 = macdM[2] - macdS[2];
   double emaDist = MathAbs(close1 - ema[1]);
   bool nearEMA = (emaDist <= InpPullbackMaxATR * atr[1]);

   // === PULLBACK ===
   if(trend == 1 && nearEMA)
   {
      // Pullback: bar 2 low came within 0.3 ATR of EMA, current bar shows momentum back up
      bool pulled  = (iLow(sym, InpEntryTF, 2) <= ema[2] + atr[1] * 0.3);
      bool rsiZone = (rsi[1] >= InpRSILongMin && rsi[1] <= InpRSILongMax);
      bool rsiUp   = (rsi[1] > rsi[2]);
      bool macdUp  = (hist1 > hist2);
      bool bullish = (close1 > close2);
      if(pulled && rsiZone && rsiUp && macdUp && bullish)
      {
         sigType = 1;
         PrintFormat("[SIGNAL] %s | >> BUY PULLBACK << RSI=%.1f MACDh=%.5f close=%.5f",
                     sym, rsi[1], hist1, close1);
         return 1;
      }
   }
   if(trend == -1 && nearEMA)
   {
      bool pulled  = (iHigh(sym, InpEntryTF, 2) >= ema[2] - atr[1] * 0.3);
      bool rsiZone = (rsi[1] >= InpRSIShortMin && rsi[1] <= InpRSIShortMax);
      bool rsiDn   = (rsi[1] < rsi[2]);
      bool macdDn  = (hist1 < hist2);
      bool bearish = (close1 < close2);
      if(pulled && rsiZone && rsiDn && macdDn && bearish)
      {
         sigType = 1;
         PrintFormat("[SIGNAL] %s | >> SELL PULLBACK << RSI=%.1f MACDh=%.5f close=%.5f",
                     sym, rsi[1], hist1, close1);
         return -1;
      }
   }

   // === BREAKOUT ===
   double adx1 = tAdx[1];
   if(adx1 >= InpBreakoutADXMin)
   {
      double hh = iHigh(sym, InpEntryTF, iHighest(sym, InpEntryTF, MODE_HIGH, InpDonchianPeriod, 2));
      double ll = iLow(sym,  InpEntryTF, iLowest(sym,  InpEntryTF, MODE_LOW,  InpDonchianPeriod, 2));
      if(trend == 1 && close1 > hh && rsi[1] < 80 && macdM[1] > macdS[1])
      {
         sigType = 2;
         PrintFormat("[SIGNAL] %s | >> BUY BREAKOUT << close=%.5f > HH=%.5f", sym, close1, hh);
         return 1;
      }
      if(trend == -1 && close1 < ll && rsi[1] > 20 && macdM[1] < macdS[1])
      {
         sigType = 2;
         PrintFormat("[SIGNAL] %s | >> SELL BREAKOUT << close=%.5f < LL=%.5f", sym, close1, ll);
         return -1;
      }
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Pyramid adds: for each winning position at +1.5R, add more        |
//+------------------------------------------------------------------+
void TryPyramidAdds()
{
   if(InpMaxPyramidAdds <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      int idx = GetSymbolIndex(sym);
      if(idx < 0) continue;

      // Count existing positions on this symbol — skip if already at cap
      int countSym = CountPositionsOnSymbol(sym);
      if(countSym > InpMaxPyramidAdds) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      long   posType   = PositionGetInteger(POSITION_TYPE);
      double slDist    = MathAbs(openPrice - sl);
      if(slDist <= 0) continue;

      double curPrice = (posType == POSITION_TYPE_BUY)
                        ? SymbolInfoDouble(sym, SYMBOL_BID)
                        : SymbolInfoDouble(sym, SYMBOL_ASK);
      double rProfit = (posType == POSITION_TYPE_BUY)
                       ? (curPrice - openPrice) / slDist
                       : (openPrice - curPrice) / slDist;

      if(rProfit < InpPyramidTrigger_R) continue;

      // Check if a new add would exceed InpMaxLot cumulative
      double totalLots = TotalLotsOnSymbol(sym);
      if(totalLots >= InpMaxLot) continue;

      // Re-evaluate: signal must still be in same direction
      int sigType = 0;
      int signal = CheckSignal(idx, sigType);
      if(posType == POSITION_TYPE_BUY && signal != 1) continue;
      if(posType == POSITION_TYPE_SELL && signal != -1) continue;

      // Use a separate time-gate so we don't spam adds on every tick
      if(!CheckCooldown(idx)) continue;

      bool ok = false;
      if(posType == POSITION_TYPE_BUY)  ok = OpenBuy(idx, sigType, InpAddRiskPercent);
      if(posType == POSITION_TYPE_SELL) ok = OpenSell(idx, sigType, InpAddRiskPercent);
      if(ok) PrintFormat("[PYRAMID] %s +%.1fR triggered add", sym, rProfit);
   }
}

//+------------------------------------------------------------------+
bool OpenBuy(int idx, int sigType, double riskPct)
{
   string sym = g_symbols[idx].name;
   double atr[];
   if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atr) != 2) return false;
   ArraySetAsSeries(atr, true);
   double atrVal = atr[1];

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double sl_dist = InpSL_ATR * atrVal;
   double stopLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(sym, SYMBOL_POINT);
   if(sl_dist < stopLvl * 1.2) sl_dist = stopLvl * 1.2;

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double sl = NormalizeDouble(ask - sl_dist, digits);
   // No hard TP — managed dynamically via partial + trail
   double tp = 0;

   double lots = CalculateLotSize(sym, sl_dist, riskPct);
   if(lots <= 0) return false;

   // Cap total lots on symbol
   double existing = TotalLotsOnSymbol(sym);
   if(existing + lots > InpMaxLot)
   {
      lots = InpMaxLot - existing;
      double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      lots = MathFloor(lots / lotStep) * lotStep;
      double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      if(lots < minLot) return false;
   }

   double marginReq = 0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, sym, lots, ask, marginReq)) return false;
   if(marginReq > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) return false;

   g_trade.SetTypeFilling(GetFillingType(sym));
   string sig = (sigType == 1) ? "PB" : "BO";
   if(g_trade.Buy(lots, sym, ask, sl, tp, StringFormat("SWP_%s_%s", sig, sym)))
   {
      g_symbols[idx].lastEntryTime = TimeCurrent();
      PrintFormat("[TRADE] BUY %s %s | Lots:%.2f | Entry:%.*f | SL:%.*f | ATR:%.*f",
                  sym, sig, lots, digits, ask, digits, sl, digits, atrVal);
      return true;
   }
   PrintFormat("[ERROR] Buy failed %s: %s", sym, g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
bool OpenSell(int idx, int sigType, double riskPct)
{
   string sym = g_symbols[idx].name;
   double atr[];
   if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atr) != 2) return false;
   ArraySetAsSeries(atr, true);
   double atrVal = atr[1];

   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double sl_dist = InpSL_ATR * atrVal;
   double stopLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(sym, SYMBOL_POINT);
   if(sl_dist < stopLvl * 1.2) sl_dist = stopLvl * 1.2;

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double sl = NormalizeDouble(bid + sl_dist, digits);
   double tp = 0;

   double lots = CalculateLotSize(sym, sl_dist, riskPct);
   if(lots <= 0) return false;

   double existing = TotalLotsOnSymbol(sym);
   if(existing + lots > InpMaxLot)
   {
      lots = InpMaxLot - existing;
      double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      lots = MathFloor(lots / lotStep) * lotStep;
      double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      if(lots < minLot) return false;
   }

   double marginReq = 0;
   if(!OrderCalcMargin(ORDER_TYPE_SELL, sym, lots, bid, marginReq)) return false;
   if(marginReq > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) return false;

   g_trade.SetTypeFilling(GetFillingType(sym));
   string sig = (sigType == 1) ? "PB" : "BO";
   if(g_trade.Sell(lots, sym, bid, sl, tp, StringFormat("SWP_%s_%s", sig, sym)))
   {
      g_symbols[idx].lastEntryTime = TimeCurrent();
      PrintFormat("[TRADE] SELL %s %s | Lots:%.2f | Entry:%.*f | SL:%.*f | ATR:%.*f",
                  sym, sig, lots, digits, bid, digits, sl, digits, atrVal);
      return true;
   }
   PrintFormat("[ERROR] Sell failed %s: %s", sym, g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
double CalculateLotSize(string sym, double sl_distance, double riskPct)
{
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * riskPct / 100.0;
   double tickVal   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
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
//| Manage positions: partial TP, breakeven, ATR trail, time exit     |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      string sym       = PositionGetString(POSITION_SYMBOL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      double vol       = PositionGetDouble(POSITION_VOLUME);
      long   posType   = PositionGetInteger(POSITION_TYPE);
      int    digits    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double point     = SymbolInfoDouble(sym, SYMBOL_POINT);
      string comment   = PositionGetString(POSITION_COMMENT);

      int idx = GetSymbolIndex(sym);
      if(idx < 0) continue;

      double atr[];
      if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atr) != 2) continue;
      ArraySetAsSeries(atr, true);
      double atrVal = atr[1];

      // Time exit
      if(InpMaxHoldBars > 0)
      {
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         int barsHeld = Bars(sym, InpEntryTF, openTime, TimeCurrent());
         if(barsHeld >= InpMaxHoldBars)
         {
            g_trade.SetTypeFilling(GetFillingType(sym));
            if(g_trade.PositionClose(ticket))
               PrintFormat("[EXIT] Time exit %s after %d bars", sym, barsHeld);
            continue;
         }
      }

      double slDistInit = MathAbs(openPrice - sl);
      if(slDistInit <= 0) continue;

      double curPrice = (posType == POSITION_TYPE_BUY)
                        ? SymbolInfoDouble(sym, SYMBOL_BID)
                        : SymbolInfoDouble(sym, SYMBOL_ASK);
      double rProfit = (posType == POSITION_TYPE_BUY)
                       ? (curPrice - openPrice) / slDistInit
                       : (openPrice - curPrice) / slDistInit;

      // Partial TP: close N% at +PartialTP_R, move SL to breakeven on remainder.
      // Detect "already partialed" by checking if SL is at-or-better-than entry (i.e. BE move done).
      double pad = 5 * point;
      bool partialTaken = (posType == POSITION_TYPE_BUY)
                          ? (sl >= openPrice - pad)
                          : (sl != 0 && sl <= openPrice + pad);
      if(!partialTaken && rProfit >= InpPartialTP_R && InpPartialClosePct > 0 && InpPartialClosePct < 100)
      {
         double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
         double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
         double closeVol = vol * InpPartialClosePct / 100.0;
         closeVol = MathFloor(closeVol / lotStep) * lotStep;
         if(closeVol >= minLot && (vol - closeVol) >= minLot)
         {
            g_trade.SetTypeFilling(GetFillingType(sym));
            if(g_trade.PositionClosePartial(ticket, closeVol))
            {
               // After partial, move SL to breakeven and tag it in comment
               double beSL = (posType == POSITION_TYPE_BUY)
                             ? NormalizeDouble(openPrice + 2 * point, digits)
                             : NormalizeDouble(openPrice - 2 * point, digits);
               g_trade.PositionModify(ticket, beSL, tp);
               PrintFormat("[PARTIAL] %s closed %.2f lots at +%.1fR, SL->BE", sym, closeVol, rProfit);
            }
         }
      }

      // ATR trailing after InpTrailStart_R
      if(rProfit >= InpTrailStart_R)
      {
         if(posType == POSITION_TYPE_BUY)
         {
            double newSL = NormalizeDouble(curPrice - InpTrailDist_ATR * atrVal, digits);
            if(newSL > sl + point)
            {
               g_trade.SetTypeFilling(GetFillingType(sym));
               g_trade.PositionModify(ticket, newSL, tp);
            }
         }
         else if(posType == POSITION_TYPE_SELL)
         {
            double newSL = NormalizeDouble(curPrice + InpTrailDist_ATR * atrVal, digits);
            if(newSL < sl - point || sl == 0)
            {
               g_trade.SetTypeFilling(GetFillingType(sym));
               g_trade.PositionModify(ticket, newSL, tp);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      g_trade.SetTypeFilling(GetFillingType(sym));
      if(g_trade.PositionClose(ticket))
         PrintFormat("[EXIT] %s closed — %s", sym, reason);
   }
}

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
int CountPositionsOnSymbol(string sym)
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym) c++;
   }
   return c;
}

double TotalLotsOnSymbol(string sym)
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym)
         total += PositionGetDouble(POSITION_VOLUME);
   }
   return total;
}

bool CheckCurrencyExposure(string sym)
{
   if(InpMaxPerCurrency <= 0) return true;
   string base  = StringSubstr(sym, 0, 3);
   string quote = StringSubstr(sym, 3, 3);
   int b = 0, q = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string p = PositionGetString(POSITION_SYMBOL);
      string pb = StringSubstr(p, 0, 3), pq = StringSubstr(p, 3, 3);
      if(pb == base || pq == base)   b++;
      if(pb == quote || pq == quote) q++;
   }
   return (b < InpMaxPerCurrency && q < InpMaxPerCurrency);
}

bool CheckCooldown(int idx)
{
   if(InpCooldownBars <= 0) return true;
   if(g_symbols[idx].lastEntryTime == 0) return true;
   int barsSince = Bars(g_symbols[idx].name, InpEntryTF,
                        g_symbols[idx].lastEntryTime, TimeCurrent());
   return (barsSince >= InpCooldownBars);
}

bool IsSessionActive()
{
   MqlDateTime dt;
   TimeGMT(dt);
   int h = dt.hour;
   if(InpSessionStart < InpSessionEnd)
      return (h >= InpSessionStart && h < InpSessionEnd);
   return (h >= InpSessionStart || h < InpSessionEnd);
}

bool IsFridayCloseTime()
{
   MqlDateTime dt;
   TimeGMT(dt);
   return (dt.day_of_week == 5 && dt.hour >= InpFridayCloseHourGMT);
}

bool IsNewBar(int idx)
{
   datetime t = iTime(g_symbols[idx].name, InpEntryTF, 0);
   if(t == 0) return false;
   if(t != g_symbols[idx].lastBarTime)
   {
      g_symbols[idx].lastBarTime = t;
      return true;
   }
   return false;
}

int CountOpenTrades()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic) c++;
   }
   return c;
}

bool HasPosition(string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == sym)
         return true;
   }
   return false;
}

int GetSymbolIndex(string sym)
{
   for(int i = 0; i < g_numSymbols; i++)
      if(g_symbols[i].name == sym) return i;
   return -1;
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
   double ddPct = (g_peakEquity - equity) / g_peakEquity * 100.0;
   if(ddPct >= InpMaxDrawdownPct) g_drawdownHalted = true;
   return g_drawdownHalted;
}

ENUM_ORDER_TYPE_FILLING GetFillingType(string sym)
{
   long f = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((f & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

bool IsExoticPair(string sym)
{
   for(int i = 0; i < ArraySize(EXOTIC_QUOTES); i++)
      if(StringFind(sym, EXOTIC_QUOTES[i]) >= 0) return true;
   return false;
}

void LogBarCheck(int idx)
{
   string sym = g_symbols[idx].name;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double tf[2], ts[2], ta[2], ema[2], rsi[2], atr[2];
   if(CopyBuffer(g_symbols[idx].hTrendEMAFast, 0, 0, 2, tf)  != 2) return;
   if(CopyBuffer(g_symbols[idx].hTrendEMASlow, 0, 0, 2, ts)  != 2) return;
   if(CopyBuffer(g_symbols[idx].hTrendADX,     0, 0, 2, ta)  != 2) return;
   if(CopyBuffer(g_symbols[idx].hEntryEMA,     0, 0, 2, ema) != 2) return;
   if(CopyBuffer(g_symbols[idx].hRSI,          0, 0, 2, rsi) != 2) return;
   if(CopyBuffer(g_symbols[idx].hATR,          0, 0, 2, atr) != 2) return;
   ArraySetAsSeries(tf, true); ArraySetAsSeries(ts, true); ArraySetAsSeries(ta, true);
   ArraySetAsSeries(ema, true); ArraySetAsSeries(rsi, true); ArraySetAsSeries(atr, true);
   string tr = (tf[1] > ts[1] && ta[1] >= InpTrendADXMin) ? "UP" :
               (tf[1] < ts[1] && ta[1] >= InpTrendADXMin) ? "DOWN" : "FLAT";
   PrintFormat("[SCAN] %s | H4:%s ADX:%.1f | H1 EMA:%.*f RSI:%.1f ATR:%.*f | Sprd:%.1f",
      sym, tr, ta[1], digits, ema[1], rsi[1], digits, atr[1], GetSpreadPips(idx));
}

void DisplayDashboard(string extra)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyPL = equity - g_dayStartBalance;
   double ddPct = g_peakEquity > 0 ? (g_peakEquity - equity) / g_peakEquity * 100.0 : 0;

   string dash = "\n========= SWING PRO =========\n";
   dash += StringFormat("Balance : %.2f %s\n", balance, AccountInfoString(ACCOUNT_CURRENCY));
   dash += StringFormat("Equity  : %.2f (peak %.2f)\n", equity, g_peakEquity);
   dash += StringFormat("Daily PL: %+.2f (%.1f%%)\n", dailyPL,
           g_dayStartBalance > 0 ? dailyPL / g_dayStartBalance * 100.0 : 0);
   dash += StringFormat("Drawdown: %.1f%% / %.1f%%\n", ddPct, InpMaxDrawdownPct);
   dash += StringFormat("Open    : %d / %d\n", CountOpenTrades(), InpMaxTrades);
   dash += StringFormat("Today   : %d entries\n", g_todayTrades);
   dash += StringFormat("Risk    : %.1f%% initial + %.1f%% per add\n", InpRiskPercent, InpAddRiskPercent);
   dash += StringFormat("Mode    : %s | TrendTF:%s EntryTF:%s\n",
           InpSingleSymbol ? "SINGLE" : "MULTI",
           EnumToString(InpTrendTF), EnumToString(InpEntryTF));
   dash += StringFormat("Pyramid : max %d adds @ %.1fR\n", InpMaxPyramidAdds, InpPyramidTrigger_R);

   int c = 0; string list = "";
   for(int i = 0; i < g_numSymbols; i++)
   {
      if(HasPosition(g_symbols[i].name))
      {
         if(c > 0) list += ", ";
         list += g_symbols[i].name;
         c++;
      }
   }
   if(c > 0) dash += "Active  : " + list + "\n";
   if(extra != "") dash += "\n>> " + extra + "\n";
   dash += "=============================";
   Comment(dash);
}
//+------------------------------------------------------------------+
