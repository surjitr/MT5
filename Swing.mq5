//+------------------------------------------------------------------+
//|                                                       Swing.mq5  |
//|                        Multi-pair Swing Trader (Forex)           |
//|                Capital: 900 AUD | Target: ~5% / month            |
//+------------------------------------------------------------------+
#property copyright "Swing EA"
#property version   "1.00"
#property description "Swing trader for Forex majors, minors, exotics."
#property description "D1 trend + ADX filter, H4 pullback or Donchian breakout entries."
#property description "ATR-based SL/TP, breakeven + trailing, 2% risk per trade."
#property description "Targets ~5% monthly (not guaranteed). Backtest before live."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Trend Filter (D1) ==="
input int    InpD1EMAFast              = 50;            // D1 Fast EMA
input int    InpD1EMASlow              = 200;           // D1 Slow EMA
input int    InpD1ADXPeriod            = 14;            // D1 ADX Period
input double InpD1ADXMin               = 20.0;          // Min ADX to confirm trend

input group "=== Entry Timing (H4) ==="
input ENUM_TIMEFRAMES InpEntryTF       = PERIOD_H4;     // Entry Timeframe
input int    InpEntryEMA               = 20;            // H4 Pullback EMA
input int    InpRSIPeriod              = 14;            // H4 RSI Period
input int    InpATRPeriod              = 14;            // H4 ATR Period
input int    InpDonchianPeriod         = 20;            // Donchian Breakout Period
input int    InpMACDFast               = 12;            // MACD Fast
input int    InpMACDSlow               = 26;            // MACD Slow
input int    InpMACDSignal             = 9;             // MACD Signal
input double InpRSILongPullback        = 45.0;          // RSI must cross up through this for longs
input double InpRSIShortPullback       = 55.0;          // RSI must cross down through this for shorts
input double InpBreakoutADXMin         = 25.0;          // Min ADX for breakout entries
input double InpPullbackMaxATR         = 0.8;           // Max distance from EMA in ATR for pullback entry

input group "=== Risk Management ==="
input double InpRiskPercent            = 2.0;           // Risk % per Trade
input double InpSL_ATR                 = 2.5;           // Stop Loss = x * ATR (H4)
input double InpTP_ATR                 = 6.0;           // Take Profit = x * ATR (H4)
input double InpBE_ATR                 = 2.0;           // Breakeven trigger at x * ATR profit
input double InpTrailTrigger_ATR       = 3.0;           // Trailing start at x * ATR profit
input double InpTrailDist_ATR          = 2.0;           // Trail distance = x * ATR
input int    InpMaxTrades              = 4;             // Max Concurrent Trades
input int    InpMaxPerCurrency         = 1;             // Max trades exposed to one currency
input double InpMaxLot                 = 0.20;          // Max Lot Size (safety cap)
input double InpMaxDailyLossPct        = 5.0;           // Daily Loss Limit %
input double InpMaxDrawdownPct         = 15.0;          // Hard equity drawdown halt %
input int    InpCooldownBars           = 6;             // Min H4 bars between entries per symbol
input int    InpMaxHoldBars            = 120;           // Max H4 bars to hold (~20 trading days)

input group "=== Session & Weekend ==="
input int    InpSessionStart           = 7;             // Entry Session Start Hour (GMT)
input int    InpSessionEnd             = 20;            // Entry Session End Hour (GMT)
input int    InpLocalGMTOffset         = 10;            // Local GMT Offset (Melbourne=10)
input bool   InpCloseBeforeWeekend     = true;          // Close all positions before weekend
input int    InpFridayCloseHourGMT     = 20;            // Friday close hour (GMT)

input group "=== Symbols ==="
input string InpSuffix                 = "";            // Broker Symbol Suffix
input double InpMaxSpreadPips          = 4.0;           // Max Spread (pips) - swing tolerates wider
input double InpMaxSpreadPipsExotic    = 15.0;          // Max spread for exotics (TRY/ZAR/MXN etc.)

input group "=== General ==="
input long   InpMagic                  = 820515;        // Magic Number
input bool   InpAlerts                 = false;         // Enable Alerts
input bool   InpPushNotify             = false;         // Enable Push Notifications
input bool   InpVerboseLog             = false;         // Verbose per-bar logging

//+------------------------------------------------------------------+
//| Per-symbol data                                                   |
//+------------------------------------------------------------------+
struct SSymbolData
{
   string   name;
   int      hD1EMAFast;
   int      hD1EMASlow;
   int      hD1ADX;
   int      hEntryEMA;
   int      hRSI;
   int      hATR;
   int      hADX;
   int      hMACD;
   datetime lastBarTime;
   datetime lastEntryTime;
   double   pipSize;
   bool     active;
   bool     isExotic;
};

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
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
   // Majors
   "EURUSD","GBPUSD","USDJPY","USDCHF","AUDUSD","NZDUSD","USDCAD",
   // Minors (crosses)
   "EURGBP","EURJPY","EURCHF","EURAUD","EURNZD","EURCAD",
   "GBPJPY","GBPCHF","GBPAUD","GBPNZD","GBPCAD",
   "AUDJPY","AUDNZD","AUDCAD","AUDCHF",
   "NZDJPY","NZDCAD","NZDCHF",
   "CADJPY","CADCHF","CHFJPY",
   // Exotics
   "USDTRY","USDZAR","USDMXN","USDSGD","USDHKD","USDNOK","USDSEK","USDDKK","USDPLN","USDCZK","USDHUF",
   "EURTRY","EURZAR","EURMXN","EURNOK","EURSEK","EURDKK","EURPLN","EURHUF",
   "GBPTRY","GBPZAR","GBPNOK","GBPSEK"
};

string EXOTIC_QUOTES[] = { "TRY","ZAR","MXN","SGD","HKD","NOK","SEK","DKK","PLN","CZK","HUF" };

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);

   int total = ArraySize(BASE_SYMBOLS);
   ArrayResize(g_symbols, total);
   g_numSymbols = 0;

   for(int i = 0; i < total; i++)
   {
      string sym = BASE_SYMBOLS[i] + InpSuffix;

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
      g_symbols[idx].isExotic      = IsExoticPair(BASE_SYMBOLS[i]);

      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(digits == 3 || digits == 5)
         g_symbols[idx].pipSize = 10.0 * SymbolInfoDouble(sym, SYMBOL_POINT);
      else
         g_symbols[idx].pipSize = SymbolInfoDouble(sym, SYMBOL_POINT);

      g_symbols[idx].hD1EMAFast = iMA(sym,  PERIOD_D1,    InpD1EMAFast, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hD1EMASlow = iMA(sym,  PERIOD_D1,    InpD1EMASlow, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hD1ADX     = iADX(sym, PERIOD_D1,    InpD1ADXPeriod);
      g_symbols[idx].hEntryEMA  = iMA(sym,  InpEntryTF,   InpEntryEMA,  0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hRSI       = iRSI(sym, InpEntryTF,   InpRSIPeriod, PRICE_CLOSE);
      g_symbols[idx].hATR       = iATR(sym, InpEntryTF,   InpATRPeriod);
      g_symbols[idx].hADX       = iADX(sym, InpEntryTF,   InpD1ADXPeriod);
      g_symbols[idx].hMACD      = iMACD(sym, InpEntryTF,  InpMACDFast, InpMACDSlow, InpMACDSignal, PRICE_CLOSE);

      if(g_symbols[idx].hD1EMAFast == INVALID_HANDLE ||
         g_symbols[idx].hD1EMASlow == INVALID_HANDLE ||
         g_symbols[idx].hD1ADX     == INVALID_HANDLE ||
         g_symbols[idx].hEntryEMA  == INVALID_HANDLE ||
         g_symbols[idx].hRSI       == INVALID_HANDLE ||
         g_symbols[idx].hATR       == INVALID_HANDLE ||
         g_symbols[idx].hADX       == INVALID_HANDLE ||
         g_symbols[idx].hMACD      == INVALID_HANDLE)
      {
         PrintFormat("[INIT] Failed indicators for %s, error %d", sym, GetLastError());
         g_symbols[idx].active = false;
      }

      g_numSymbols++;
   }

   if(g_numSymbols == 0)
   {
      Alert("No valid symbols! Check broker suffix.");
      return INIT_FAILED;
   }

   ArrayResize(g_symbols, g_numSymbols);

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastDay         = iTime(_Symbol, PERIOD_D1, 0);
   g_todayTrades     = 0;
   g_drawdownHalted  = false;

   EventSetTimer(30);

   PrintFormat("[INIT] Swing EA started: %d symbols, Magic=%d, Risk=%.1f%%, MaxTrades=%d, EntryTF=%s",
               g_numSymbols, InpMagic, InpRiskPercent, InpMaxTrades, EnumToString(InpEntryTF));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   for(int i = 0; i < g_numSymbols; i++)
   {
      if(g_symbols[i].hD1EMAFast != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hD1EMAFast);
      if(g_symbols[i].hD1EMASlow != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hD1EMASlow);
      if(g_symbols[i].hD1ADX     != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hD1ADX);
      if(g_symbols[i].hEntryEMA  != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hEntryEMA);
      if(g_symbols[i].hRSI       != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hRSI);
      if(g_symbols[i].hATR       != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hATR);
      if(g_symbols[i].hADX       != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hADX);
      if(g_symbols[i].hMACD      != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hMACD);
   }

   Comment("");
}

//+------------------------------------------------------------------+
//| Timer scan (swing doesn't need tick-level speed)                  |
//+------------------------------------------------------------------+
void OnTimer()
{
   MainLogic();
}

void OnTick()
{
   MainLogic();
}

//+------------------------------------------------------------------+
//| Main trading logic                                                |
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
      DisplayDashboard("!! HARD DRAWDOWN HALT !!");
      return;
   }

   if(CheckDailyLossExceeded())
   {
      DisplayDashboard("!! DAILY LOSS LIMIT - TRADING PAUSED !!");
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

   int openCount = CountOpenTrades();

   for(int i = 0; i < g_numSymbols; i++)
   {
      if(!g_symbols[i].active) continue;
      if(!IsNewBar(i)) continue;

      if(InpVerboseLog) LogBarCheck(i);

      if(openCount >= InpMaxTrades) continue;
      if(HasPosition(g_symbols[i].name)) continue;
      if(!IsSessionActive()) continue;
      if(!CheckCurrencyExposure(g_symbols[i].name)) continue;
      if(!CheckCooldown(i)) continue;

      double spreadLimit = g_symbols[i].isExotic ? InpMaxSpreadPipsExotic : InpMaxSpreadPips;
      if(GetSpreadPips(i) > spreadLimit) continue;

      int sigType = 0;
      int signal = CheckSignal(i, sigType);

      if(signal == 1)
      {
         if(OpenBuy(i, sigType)) { openCount++; g_todayTrades++; }
      }
      else if(signal == -1)
      {
         if(OpenSell(i, sigType)) { openCount++; g_todayTrades++; }
      }
   }

   DisplayDashboard("");
}

//+------------------------------------------------------------------+
//| Signal engine                                                     |
//| sigType: 1=Pullback continuation, 2=Donchian breakout             |
//| Returns: 1=Buy, -1=Sell, 0=None                                   |
//+------------------------------------------------------------------+
int CheckSignal(int idx, int &sigType)
{
   sigType = 0;
   string sym = g_symbols[idx].name;

   // --- D1 trend filter ---
   double d1Fast[2], d1Slow[2], d1AdxMain[2];
   if(CopyBuffer(g_symbols[idx].hD1EMAFast, 0, 0, 2, d1Fast)    != 2) return 0;
   if(CopyBuffer(g_symbols[idx].hD1EMASlow, 0, 0, 2, d1Slow)    != 2) return 0;
   if(CopyBuffer(g_symbols[idx].hD1ADX,     0, 0, 2, d1AdxMain) != 2) return 0;
   ArraySetAsSeries(d1Fast, true);
   ArraySetAsSeries(d1Slow, true);
   ArraySetAsSeries(d1AdxMain, true);

   int d1Trend = 0;
   if(d1Fast[1] > d1Slow[1] && d1AdxMain[1] >= InpD1ADXMin)      d1Trend = 1;
   else if(d1Fast[1] < d1Slow[1] && d1AdxMain[1] >= InpD1ADXMin) d1Trend = -1;
   if(d1Trend == 0) return 0;

   // --- H4 indicators ---
   double ema[3], rsi[3], atr[3], adxMain[3];
   double macdMain[3], macdSig[3];

   if(CopyBuffer(g_symbols[idx].hEntryEMA, 0, 0, 3, ema)     != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hRSI,      0, 0, 3, rsi)     != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hATR,      0, 0, 3, atr)     != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hADX,      0, 0, 3, adxMain) != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hMACD,     0, 0, 3, macdMain) != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hMACD,     1, 0, 3, macdSig)  != 3) return 0;

   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(adxMain, true);
   ArraySetAsSeries(macdMain, true);
   ArraySetAsSeries(macdSig, true);

   double close1 = iClose(sym, InpEntryTF, 1);
   double close2 = iClose(sym, InpEntryTF, 2);
   if(close1 == 0 || close2 == 0) return 0;

   // Dead market filter (ATR too small relative to pip size)
   if(atr[1] < g_symbols[idx].pipSize * 5) return 0;

   double macdHist1 = macdMain[1] - macdSig[1];
   double macdHist2 = macdMain[2] - macdSig[2];

   // === SIGNAL 1: PULLBACK CONTINUATION ===
   // Price pulls back to EMA20, RSI crosses back through threshold, MACD hist turns in trend dir
   double emaDist = MathAbs(close1 - ema[1]);
   bool nearEMA = (emaDist <= InpPullbackMaxATR * atr[1]);

   if(d1Trend == 1 && nearEMA)
   {
      bool touchedEMA    = (iLow(sym, InpEntryTF, 1) <= ema[1] ||
                            iLow(sym, InpEntryTF, 2) <= ema[2]);
      bool rsiCrossUp    = (rsi[2] < InpRSILongPullback && rsi[1] >= InpRSILongPullback);
      bool macdTurnUp    = (macdHist1 > macdHist2 && macdHist1 > 0);
      bool closeAboveEMA = (close1 > ema[1]);

      if(touchedEMA && rsiCrossUp && macdTurnUp && closeAboveEMA)
      {
         sigType = 1;
         return 1;
      }
   }

   if(d1Trend == -1 && nearEMA)
   {
      bool touchedEMA    = (iHigh(sym, InpEntryTF, 1) >= ema[1] ||
                            iHigh(sym, InpEntryTF, 2) >= ema[2]);
      bool rsiCrossDn    = (rsi[2] > InpRSIShortPullback && rsi[1] <= InpRSIShortPullback);
      bool macdTurnDn    = (macdHist1 < macdHist2 && macdHist1 < 0);
      bool closeBelowEMA = (close1 < ema[1]);

      if(touchedEMA && rsiCrossDn && macdTurnDn && closeBelowEMA)
      {
         sigType = 1;
         return -1;
      }
   }

   // === SIGNAL 2: DONCHIAN BREAKOUT (strong trends that don't pull back) ===
   if(adxMain[1] >= InpBreakoutADXMin)
   {
      double highestHigh = iHigh(sym, InpEntryTF, iHighest(sym, InpEntryTF, MODE_HIGH, InpDonchianPeriod, 2));
      double lowestLow   = iLow(sym,  InpEntryTF, iLowest(sym,  InpEntryTF, MODE_LOW,  InpDonchianPeriod, 2));

      if(d1Trend == 1 && close1 > highestHigh && rsi[1] < 75 && macdMain[1] > macdSig[1])
      {
         sigType = 2;
         return 1;
      }
      if(d1Trend == -1 && close1 < lowestLow && rsi[1] > 25 && macdMain[1] < macdSig[1])
      {
         sigType = 2;
         return -1;
      }
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Open Buy                                                          |
//+------------------------------------------------------------------+
bool OpenBuy(int idx, int sigType)
{
   string sym = g_symbols[idx].name;

   double atr[];
   if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atr) != 2) return false;
   ArraySetAsSeries(atr, true);
   double atrVal = atr[1];

   double ask     = SymbolInfoDouble(sym, SYMBOL_ASK);
   double sl_dist = InpSL_ATR * atrVal;
   double tp_dist = InpTP_ATR * atrVal;

   // Ensure SL respects broker's stop level
   double stopLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) *
                    SymbolInfoDouble(sym, SYMBOL_POINT);
   if(sl_dist < stopLvl * 1.2) sl_dist = stopLvl * 1.2;
   if(tp_dist < stopLvl * 1.2) tp_dist = stopLvl * 1.2;

   double sl = NormalizeDouble(ask - sl_dist, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
   double tp = NormalizeDouble(ask + tp_dist, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));

   double lots = CalculateLotSize(sym, sl_dist);
   if(lots <= 0)
   {
      PrintFormat("[SKIP] %s BUY | Lot calc zero", sym);
      return false;
   }

   double marginReq = 0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, sym, lots, ask, marginReq))
   {
      PrintFormat("[SKIP] %s BUY | Margin calc failed", sym);
      return false;
   }
   if(marginReq > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      PrintFormat("[SKIP] %s BUY | Insufficient margin (need %.2f, free %.2f)",
                  sym, marginReq, AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      return false;
   }

   g_trade.SetTypeFilling(GetFillingType(sym));
   string sigName = (sigType == 1) ? "PB" : "BO";

   if(g_trade.Buy(lots, sym, ask, sl, tp, StringFormat("SWG_%s_%s", sigName, sym)))
   {
      g_symbols[idx].lastEntryTime = TimeCurrent();
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      PrintFormat("[TRADE] BUY %s | %s | Lots:%.2f | Entry:%.*f | SL:%.*f | TP:%.*f | ATR:%.*f",
                  sym, sigName, lots, digits, ask, digits, sl, digits, tp, digits, atrVal);
      if(InpAlerts) Alert(StringFormat("SWING BUY %s (%s) %.2f lots", sym, sigName, lots));
      if(InpPushNotify) SendNotification(StringFormat("SWING BUY %s (%s) %.2f", sym, sigName, lots));
      return true;
   }
   PrintFormat("[ERROR] Buy failed %s: %d - %s", sym, GetLastError(), g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
//| Open Sell                                                         |
//+------------------------------------------------------------------+
bool OpenSell(int idx, int sigType)
{
   string sym = g_symbols[idx].name;

   double atr[];
   if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atr) != 2) return false;
   ArraySetAsSeries(atr, true);
   double atrVal = atr[1];

   double bid     = SymbolInfoDouble(sym, SYMBOL_BID);
   double sl_dist = InpSL_ATR * atrVal;
   double tp_dist = InpTP_ATR * atrVal;

   double stopLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) *
                    SymbolInfoDouble(sym, SYMBOL_POINT);
   if(sl_dist < stopLvl * 1.2) sl_dist = stopLvl * 1.2;
   if(tp_dist < stopLvl * 1.2) tp_dist = stopLvl * 1.2;

   double sl = NormalizeDouble(bid + sl_dist, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
   double tp = NormalizeDouble(bid - tp_dist, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));

   double lots = CalculateLotSize(sym, sl_dist);
   if(lots <= 0)
   {
      PrintFormat("[SKIP] %s SELL | Lot calc zero", sym);
      return false;
   }

   double marginReq = 0;
   if(!OrderCalcMargin(ORDER_TYPE_SELL, sym, lots, bid, marginReq))
   {
      PrintFormat("[SKIP] %s SELL | Margin calc failed", sym);
      return false;
   }
   if(marginReq > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      PrintFormat("[SKIP] %s SELL | Insufficient margin", sym);
      return false;
   }

   g_trade.SetTypeFilling(GetFillingType(sym));
   string sigName = (sigType == 1) ? "PB" : "BO";

   if(g_trade.Sell(lots, sym, bid, sl, tp, StringFormat("SWG_%s_%s", sigName, sym)))
   {
      g_symbols[idx].lastEntryTime = TimeCurrent();
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      PrintFormat("[TRADE] SELL %s | %s | Lots:%.2f | Entry:%.*f | SL:%.*f | TP:%.*f | ATR:%.*f",
                  sym, sigName, lots, digits, bid, digits, sl, digits, tp, digits, atrVal);
      if(InpAlerts) Alert(StringFormat("SWING SELL %s (%s) %.2f lots", sym, sigName, lots));
      if(InpPushNotify) SendNotification(StringFormat("SWING SELL %s (%s) %.2f", sym, sigName, lots));
      return true;
   }
   PrintFormat("[ERROR] Sell failed %s: %d - %s", sym, GetLastError(), g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
//| Position sizing from risk % and SL distance                       |
//+------------------------------------------------------------------+
double CalculateLotSize(string sym, double sl_distance)
{
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;

   double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);

   if(tickVal <= 0 || tickSize <= 0 || sl_distance <= 0) return 0;

   double slTicks    = sl_distance / tickSize;
   double riskPerLot = slTicks * tickVal;
   if(riskPerLot <= 0) return 0;

   double lots = riskMoney / riskPerLot;

   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = MathMin(lots, InpMaxLot);

   // Guard: skip entry if even minLot would exceed the risk budget by >50%
   double minLotRisk = minLot * riskPerLot;
   if(lots == minLot && minLotRisk > riskMoney * 1.5) return 0;

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Manage positions: trailing, breakeven, time exit                  |
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
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long   posType   = PositionGetInteger(POSITION_TYPE);
      int    digits    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double point     = SymbolInfoDouble(sym, SYMBOL_POINT);

      int idx = GetSymbolIndex(sym);
      if(idx < 0) continue;

      double atr[];
      if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atr) != 2) continue;
      ArraySetAsSeries(atr, true);
      double atrVal = atr[1];

      // Time-based exit: swing trade that overstays its welcome
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

      double currentPrice, profitDist;
      if(posType == POSITION_TYPE_BUY)
      {
         currentPrice = SymbolInfoDouble(sym, SYMBOL_BID);
         profitDist   = currentPrice - openPrice;

         if(profitDist >= InpTrailTrigger_ATR * atrVal)
         {
            double newSL = NormalizeDouble(currentPrice - InpTrailDist_ATR * atrVal, digits);
            if(newSL > currentSL + point)
            {
               g_trade.SetTypeFilling(GetFillingType(sym));
               g_trade.PositionModify(ticket, newSL, currentTP);
            }
         }
         else if(profitDist >= InpBE_ATR * atrVal)
         {
            double beSL = NormalizeDouble(openPrice + 2 * point, digits);
            if(beSL > currentSL + point)
            {
               g_trade.SetTypeFilling(GetFillingType(sym));
               g_trade.PositionModify(ticket, beSL, currentTP);
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         currentPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
         profitDist   = openPrice - currentPrice;

         if(profitDist >= InpTrailTrigger_ATR * atrVal)
         {
            double newSL = NormalizeDouble(currentPrice + InpTrailDist_ATR * atrVal, digits);
            if(newSL < currentSL - point || currentSL == 0)
            {
               g_trade.SetTypeFilling(GetFillingType(sym));
               g_trade.PositionModify(ticket, newSL, currentTP);
            }
         }
         else if(profitDist >= InpBE_ATR * atrVal)
         {
            double beSL = NormalizeDouble(openPrice - 2 * point, digits);
            if(beSL < currentSL - point || currentSL == 0)
            {
               g_trade.SetTypeFilling(GetFillingType(sym));
               g_trade.PositionModify(ticket, beSL, currentTP);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close all positions with our magic                                |
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
//| Currency exposure cap — max N positions per base/quote            |
//+------------------------------------------------------------------+
bool CheckCurrencyExposure(string sym)
{
   if(InpMaxPerCurrency <= 0) return true;

   string base  = StringSubstr(sym, 0, 3);
   string quote = StringSubstr(sym, 3, 3);

   int baseCount = 0, quoteCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string posSym = PositionGetString(POSITION_SYMBOL);
      string pb = StringSubstr(posSym, 0, 3);
      string pq = StringSubstr(posSym, 3, 3);
      if(pb == base || pq == base)   baseCount++;
      if(pb == quote || pq == quote) quoteCount++;
   }
   return (baseCount < InpMaxPerCurrency && quoteCount < InpMaxPerCurrency);
}

//+------------------------------------------------------------------+
//| Cooldown: min bars since last entry on this symbol                |
//+------------------------------------------------------------------+
bool CheckCooldown(int idx)
{
   if(InpCooldownBars <= 0) return true;
   if(g_symbols[idx].lastEntryTime == 0) return true;
   int barsSince = Bars(g_symbols[idx].name, InpEntryTF,
                        g_symbols[idx].lastEntryTime, TimeCurrent());
   return (barsSince >= InpCooldownBars);
}

//+------------------------------------------------------------------+
//| Session filter (GMT)                                              |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeLocal(dt);
   int gmtHour = (dt.hour - InpLocalGMTOffset + 24) % 24;

   if(InpSessionStart < InpSessionEnd)
      return (gmtHour >= InpSessionStart && gmtHour < InpSessionEnd);
   else
      return (gmtHour >= InpSessionStart || gmtHour < InpSessionEnd);
}

//+------------------------------------------------------------------+
//| Friday close window (GMT)                                         |
//+------------------------------------------------------------------+
bool IsFridayCloseTime()
{
   MqlDateTime dt;
   TimeLocal(dt);
   int gmtHour = (dt.hour - InpLocalGMTOffset + 24) % 24;
   // dt.day_of_week: 0=Sun..6=Sat. TimeLocal is local; convert to GMT day if hour rolls.
   int gmtDow = dt.day_of_week;
   int hourDelta = dt.hour - InpLocalGMTOffset;
   if(hourDelta < 0)       gmtDow = (gmtDow + 6) % 7;
   else if(hourDelta >= 24) gmtDow = (gmtDow + 1) % 7;

   return (gmtDow == 5 && gmtHour >= InpFridayCloseHourGMT); // 5 = Friday
}

//+------------------------------------------------------------------+
//| New bar detection per symbol (on entry timeframe)                 |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Count open trades with our magic                                  |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check if position exists on symbol                                |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Find symbol index                                                 |
//+------------------------------------------------------------------+
int GetSymbolIndex(string sym)
{
   for(int i = 0; i < g_numSymbols; i++)
      if(g_symbols[i].name == sym) return i;
   return -1;
}

//+------------------------------------------------------------------+
//| Spread in pips                                                    |
//+------------------------------------------------------------------+
double GetSpreadPips(int idx)
{
   string sym = g_symbols[idx].name;
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(g_symbols[idx].pipSize <= 0) return 999;
   return (ask - bid) / g_symbols[idx].pipSize;
}

//+------------------------------------------------------------------+
//| Daily loss circuit breaker                                        |
//+------------------------------------------------------------------+
bool CheckDailyLossExceeded()
{
   if(g_dayStartBalance <= 0) return false;
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dayStartBalance - equity) / g_dayStartBalance * 100.0;
   return (lossPct >= InpMaxDailyLossPct);
}

//+------------------------------------------------------------------+
//| Hard drawdown halt from equity peak                               |
//+------------------------------------------------------------------+
bool CheckDrawdownHalted()
{
   if(g_peakEquity <= 0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct  = (g_peakEquity - equity) / g_peakEquity * 100.0;
   if(ddPct >= InpMaxDrawdownPct) g_drawdownHalted = true;
   return g_drawdownHalted;
}

//+------------------------------------------------------------------+
//| Order filling type                                                |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingType(string sym)
{
   long filling = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Exotic detection                                                  |
//+------------------------------------------------------------------+
bool IsExoticPair(string baseName)
{
   for(int i = 0; i < ArraySize(EXOTIC_QUOTES); i++)
   {
      if(StringFind(baseName, EXOTIC_QUOTES[i]) >= 0) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Log bar snapshot (verbose)                                        |
//+------------------------------------------------------------------+
void LogBarCheck(int idx)
{
   string sym = g_symbols[idx].name;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double d1Fast[2], d1Slow[2], d1Adx[2];
   double ema[2], rsi[2], atr[2], adx[2];

   if(CopyBuffer(g_symbols[idx].hD1EMAFast, 0, 0, 2, d1Fast) != 2) return;
   if(CopyBuffer(g_symbols[idx].hD1EMASlow, 0, 0, 2, d1Slow) != 2) return;
   if(CopyBuffer(g_symbols[idx].hD1ADX,     0, 0, 2, d1Adx)  != 2) return;
   if(CopyBuffer(g_symbols[idx].hEntryEMA,  0, 0, 2, ema)    != 2) return;
   if(CopyBuffer(g_symbols[idx].hRSI,       0, 0, 2, rsi)    != 2) return;
   if(CopyBuffer(g_symbols[idx].hATR,       0, 0, 2, atr)    != 2) return;
   if(CopyBuffer(g_symbols[idx].hADX,       0, 0, 2, adx)    != 2) return;

   ArraySetAsSeries(d1Fast, true); ArraySetAsSeries(d1Slow, true); ArraySetAsSeries(d1Adx, true);
   ArraySetAsSeries(ema, true);    ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);    ArraySetAsSeries(adx, true);

   string trend = (d1Fast[1] > d1Slow[1] && d1Adx[1] >= InpD1ADXMin) ? "UP" :
                  (d1Fast[1] < d1Slow[1] && d1Adx[1] >= InpD1ADXMin) ? "DOWN" : "FLAT";

   PrintFormat("[SCAN] %s | D1:%s ADX:%.1f | H4 EMA:%.*f RSI:%.1f ADX:%.1f ATR:%.*f | Sprd:%.1f",
      sym, trend, d1Adx[1],
      digits, ema[1], rsi[1], adx[1],
      digits, atr[1],
      GetSpreadPips(idx));
}

//+------------------------------------------------------------------+
//| Dashboard                                                         |
//+------------------------------------------------------------------+
void DisplayDashboard(string extra)
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyPL = equity - g_dayStartBalance;
   double ddPct   = g_peakEquity > 0 ? (g_peakEquity - equity) / g_peakEquity * 100.0 : 0;
   int    trades  = CountOpenTrades();

   string dash = "\n";
   dash += "========= SWING TRADER =========\n";
   dash += StringFormat("Balance : %.2f %s\n", balance, AccountInfoString(ACCOUNT_CURRENCY));
   dash += StringFormat("Equity  : %.2f (peak %.2f)\n", equity, g_peakEquity);
   dash += StringFormat("Daily PL: %+.2f (%.1f%%)\n", dailyPL,
           g_dayStartBalance > 0 ? (dailyPL / g_dayStartBalance) * 100.0 : 0);
   dash += StringFormat("Drawdown: %.1f%% / %.1f%%\n", ddPct, InpMaxDrawdownPct);
   dash += StringFormat("Open    : %d / %d\n", trades, InpMaxTrades);
   dash += StringFormat("Today   : %d entries\n", g_todayTrades);
   dash += StringFormat("Risk    : %.1f%% | R:R 1:%.1f\n", InpRiskPercent, InpTP_ATR / InpSL_ATR);
   dash += StringFormat("Session : %s\n", IsSessionActive() ? "ACTIVE" : "CLOSED");
   dash += StringFormat("Entry TF: %s | Trend: D1\n", EnumToString(InpEntryTF));

   int posCount = 0;
   string posList = "";
   for(int i = 0; i < g_numSymbols; i++)
   {
      if(HasPosition(g_symbols[i].name))
      {
         if(posCount > 0) posList += ", ";
         posList += g_symbols[i].name;
         posCount++;
      }
   }
   if(posCount > 0) dash += "Active  : " + posList + "\n";

   if(extra != "") dash += "\n>> " + extra + "\n";
   dash += "================================";

   Comment(dash);
}
//+------------------------------------------------------------------+
