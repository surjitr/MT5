//+------------------------------------------------------------------+
//|                                                    ichimoku.mq5   |
//|              Ichimoku Kinko Hyo Swing Trader (multi-pair)         |
//|                         Capital: 900 AUD                          |
//+------------------------------------------------------------------+
#property copyright "Ichimoku EA"
#property version   "1.00"
#property description "Classic Ichimoku swing strategy for Forex."
#property description "D1 cloud trend filter + H4 TK cross entries with Chikou + cloud confirmation."
#property description "Kijun-sen trailing stop (natural Ichimoku exit)."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Ichimoku Settings ==="
input ENUM_TIMEFRAMES InpTrendTF       = PERIOD_D1;     // Trend Filter Timeframe
input ENUM_TIMEFRAMES InpEntryTF       = PERIOD_H4;     // Entry Timeframe
input int    InpTenkan                 = 9;             // Tenkan-sen period
input int    InpKijun                  = 26;            // Kijun-sen period
input int    InpSenkouB                = 52;            // Senkou Span B period
input int    InpChikouShift            = 26;            // Chikou lag (== Kijun by convention)

input group "=== Entry Filters ==="
input bool   InpRequireD1Trend         = true;          // Require D1 price above/below cloud
input bool   InpRequireCloudBreak      = true;          // H4 price must be above/below both Senkou lines
input bool   InpRequireChikouFree      = true;          // H4 Chikou free of price 26 bars ago
input bool   InpRequireKumoColor       = true;          // Future cloud color must match trade direction
input int    InpMaxTKCrossAgeBars      = 4;             // Max H4 bars since TK cross (freshness)

input group "=== Risk Management ==="
input double InpRiskPercent            = 2.0;           // Risk % per Trade
input int    InpATRPeriod              = 14;            // ATR Period (entry TF)
input double InpMinSL_ATR              = 1.5;           // Minimum SL = x * ATR (floor)
input double InpTP_R                   = 3.0;           // TP = x * risk distance (R multiple)
input double InpBE_R                   = 1.0;           // Breakeven trigger at x * R profit
input int    InpMaxTrades              = 4;             // Max Concurrent Trades
input int    InpMaxPerCurrency         = 1;             // Max trades exposed to one currency
input double InpMaxLot                 = 0.20;          // Max Lot Size (safety cap)
input double InpMaxDailyLossPct        = 5.0;           // Daily Loss Limit %
input double InpMaxDrawdownPct         = 15.0;          // Hard equity drawdown halt %
input int    InpCooldownBars           = 6;             // Min bars between entries per symbol
input int    InpMaxHoldBars            = 120;           // Max bars to hold (~20 H4 days)

input group "=== Session & Weekend ==="
input int    InpSessionStart           = 0;             // Session Start Hour (GMT)
input int    InpSessionEnd             = 23;            // Session End Hour (GMT)
input bool   InpCloseBeforeWeekend     = true;          // Close all positions before weekend
input int    InpFridayCloseHourGMT     = 20;            // Friday close hour (GMT)

input group "=== Symbols ==="
input string InpSuffix                 = "";            // Broker Symbol Suffix
input double InpMaxSpreadPips          = 4.0;           // Max Spread (pips) majors/minors
input double InpMaxSpreadPipsExotic    = 15.0;          // Max spread for exotics

input group "=== General ==="
input long   InpMagic                  = 930728;        // Magic Number
input bool   InpAlerts                 = false;         // Enable Alerts
input bool   InpPushNotify             = false;         // Enable Push Notifications
input bool   InpVerboseLog             = true;          // Per-symbol scan logging
input bool   InpLogEveryCheck          = true;          // Log every signal check with reason

//+------------------------------------------------------------------+
//| Ichimoku buffer indices                                           |
//+------------------------------------------------------------------+
#define ICH_TENKAN  0
#define ICH_KIJUN   1
#define ICH_SENKOUA 2
#define ICH_SENKOUB 3
#define ICH_CHIKOU  4

//+------------------------------------------------------------------+
//| Per-symbol data                                                   |
//+------------------------------------------------------------------+
struct SSymbolData
{
   string   name;
   int      hIchiTrend;   // trend TF Ichimoku
   int      hIchiEntry;   // entry TF Ichimoku
   int      hATR;
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
//| Init                                                              |
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

      // Prime history (Senkou B needs 52 bars + 26 shift + buffer)
      int trendBars = InpSenkouB + InpChikouShift + 20;
      int entryBars = InpSenkouB + InpChikouShift + 20;
      datetime dummy[];
      CopyTime(sym, InpTrendTF, 0, trendBars, dummy);
      CopyTime(sym, InpEntryTF, 0, entryBars, dummy);

      g_symbols[idx].hIchiTrend = iIchimoku(sym, InpTrendTF, InpTenkan, InpKijun, InpSenkouB);
      g_symbols[idx].hIchiEntry = iIchimoku(sym, InpEntryTF, InpTenkan, InpKijun, InpSenkouB);
      g_symbols[idx].hATR       = iATR(sym, InpEntryTF, InpATRPeriod);

      if(g_symbols[idx].hIchiTrend == INVALID_HANDLE ||
         g_symbols[idx].hIchiEntry == INVALID_HANDLE ||
         g_symbols[idx].hATR       == INVALID_HANDLE)
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

   PrintFormat("[INIT] Ichimoku EA started: %d symbols, Magic=%d, Risk=%.1f%%, MaxTrades=%d, TrendTF=%s, EntryTF=%s",
               g_numSymbols, InpMagic, InpRiskPercent, InpMaxTrades,
               EnumToString(InpTrendTF), EnumToString(InpEntryTF));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < g_numSymbols; i++)
   {
      if(g_symbols[i].hIchiTrend != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hIchiTrend);
      if(g_symbols[i].hIchiEntry != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hIchiEntry);
      if(g_symbols[i].hATR       != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hATR);
   }
   Comment("");
}

void OnTimer() { MainLogic(); }
void OnTick()  { MainLogic(); }

//+------------------------------------------------------------------+
//| Main logic                                                        |
//+------------------------------------------------------------------+
void MainLogic()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      if(InpLogEveryCheck) Print("[MAIN] SKIP: terminal not connected");
      return;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      if(InpLogEveryCheck) Print("[MAIN] SKIP: trading not allowed");
      return;
   }

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
   int scanned   = 0;

   for(int i = 0; i < g_numSymbols; i++)
   {
      if(!g_symbols[i].active) continue;
      if(!IsNewBar(i)) continue;

      scanned++;
      string sym = g_symbols[i].name;
      PrintFormat("[MAIN] >>> New %s bar on %s @ %s | openTrades=%d/%d",
                  EnumToString(InpEntryTF), sym,
                  TimeToString(iTime(sym, InpEntryTF, 0), TIME_DATE|TIME_MINUTES),
                  openCount, InpMaxTrades);

      if(InpVerboseLog) LogBarCheck(i);

      if(openCount >= InpMaxTrades)
      {
         if(InpLogEveryCheck) PrintFormat("[CHECK] %s | SKIP MaxTrades (%d/%d)", sym, openCount, InpMaxTrades);
         continue;
      }
      if(HasPosition(sym))
      {
         if(InpLogEveryCheck) PrintFormat("[CHECK] %s | SKIP HasPosition", sym);
         continue;
      }
      if(!IsSessionActive())
      {
         if(InpLogEveryCheck) PrintFormat("[CHECK] %s | SKIP SessionClosed", sym);
         continue;
      }
      if(!CheckCurrencyExposure(sym))
      {
         if(InpLogEveryCheck) PrintFormat("[CHECK] %s | SKIP CurrencyExposure", sym);
         continue;
      }
      if(!CheckCooldown(i))
      {
         if(InpLogEveryCheck) PrintFormat("[CHECK] %s | SKIP Cooldown", sym);
         continue;
      }

      double spreadLimit = g_symbols[i].isExotic ? InpMaxSpreadPipsExotic : InpMaxSpreadPips;
      double spread = GetSpreadPips(i);
      if(spread > spreadLimit)
      {
         if(InpLogEveryCheck) PrintFormat("[CHECK] %s | SKIP Spread %.1f > %.1f", sym, spread, spreadLimit);
         continue;
      }

      int signal = CheckSignal(i);
      if(InpLogEveryCheck && signal == 0)
         PrintFormat("[CHECK] %s | NO SIGNAL", sym);

      if(signal == 1)       { if(OpenBuy(i))  { openCount++; g_todayTrades++; } }
      else if(signal == -1) { if(OpenSell(i)) { openCount++; g_todayTrades++; } }
   }

   if(scanned > 0)
      PrintFormat("[MAIN] Cycle done: %d bars scanned, %d open", scanned, CountOpenTrades());

   DisplayDashboard("");
}

//+------------------------------------------------------------------+
//| Indicators ready?                                                 |
//+------------------------------------------------------------------+
bool IndicatorsReady(int idx)
{
   int need = InpSenkouB + InpChikouShift + 5;
   if(BarsCalculated(g_symbols[idx].hIchiTrend) < need) return false;
   if(BarsCalculated(g_symbols[idx].hIchiEntry) < need) return false;
   if(BarsCalculated(g_symbols[idx].hATR)       < InpATRPeriod + 5) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Signal engine: Ichimoku TK cross with confluence                  |
//| Returns: 1=Buy, -1=Sell, 0=None                                   |
//+------------------------------------------------------------------+
int CheckSignal(int idx)
{
   string sym = g_symbols[idx].name;

   if(!IndicatorsReady(idx))
   {
      if(InpLogEveryCheck) PrintFormat("[SIGNAL] %s | WARMUP", sym);
      datetime dummy[];
      CopyTime(sym, InpTrendTF, 0, InpSenkouB + InpChikouShift + 20, dummy);
      CopyTime(sym, InpEntryTF, 0, InpSenkouB + InpChikouShift + 20, dummy);
      return 0;
   }

   // --- Trend TF (D1) cloud filter ---
   double tSenA[2], tSenB[2];
   if(CopyBuffer(g_symbols[idx].hIchiTrend, ICH_SENKOUA, 0, 2, tSenA) != 2)
   { if(InpLogEveryCheck) PrintFormat("[SIGNAL] %s | WARMUP TrendSenkouA", sym); return 0; }
   if(CopyBuffer(g_symbols[idx].hIchiTrend, ICH_SENKOUB, 0, 2, tSenB) != 2)
   { if(InpLogEveryCheck) PrintFormat("[SIGNAL] %s | WARMUP TrendSenkouB", sym); return 0; }
   ArraySetAsSeries(tSenA, true);
   ArraySetAsSeries(tSenB, true);

   double trendClose = iClose(sym, InpTrendTF, 1);
   if(trendClose == 0)
   { if(InpLogEveryCheck) PrintFormat("[SIGNAL] %s | REJECT trendClose=0", sym); return 0; }

   double cloudTop_T = MathMax(tSenA[1], tSenB[1]);
   double cloudBot_T = MathMin(tSenA[1], tSenB[1]);

   int d1Trend = 0;
   if(trendClose > cloudTop_T)      d1Trend = 1;
   else if(trendClose < cloudBot_T) d1Trend = -1;

   if(InpRequireD1Trend && d1Trend == 0)
   {
      if(InpLogEveryCheck)
         PrintFormat("[SIGNAL] %s | REJECT D1 price in cloud (close=%.5f top=%.5f bot=%.5f)",
                     sym, trendClose, cloudTop_T, cloudBot_T);
      return 0;
   }

   // --- Entry TF (H4) Ichimoku ---
   int need = InpMaxTKCrossAgeBars + 2;
   double tenkan[], kijun[], senA[], senB[], chikou[];
   if(CopyBuffer(g_symbols[idx].hIchiEntry, ICH_TENKAN,  0, need, tenkan) != need)
   { if(InpLogEveryCheck) PrintFormat("[SIGNAL] %s | WARMUP Tenkan", sym); return 0; }
   if(CopyBuffer(g_symbols[idx].hIchiEntry, ICH_KIJUN,   0, need, kijun) != need)
   { if(InpLogEveryCheck) PrintFormat("[SIGNAL] %s | WARMUP Kijun", sym); return 0; }
   if(CopyBuffer(g_symbols[idx].hIchiEntry, ICH_SENKOUA, 0, 2,    senA) != 2)
   { if(InpLogEveryCheck) PrintFormat("[SIGNAL] %s | WARMUP SenkouA", sym); return 0; }
   if(CopyBuffer(g_symbols[idx].hIchiEntry, ICH_SENKOUB, 0, 2,    senB) != 2)
   { if(InpLogEveryCheck) PrintFormat("[SIGNAL] %s | WARMUP SenkouB", sym); return 0; }
   if(CopyBuffer(g_symbols[idx].hIchiEntry, ICH_CHIKOU,  0, 2,    chikou) != 2)
   { if(InpLogEveryCheck) PrintFormat("[SIGNAL] %s | WARMUP Chikou", sym); return 0; }

   ArraySetAsSeries(tenkan, true);
   ArraySetAsSeries(kijun, true);
   ArraySetAsSeries(senA, true);
   ArraySetAsSeries(senB, true);
   ArraySetAsSeries(chikou, true);

   double close1   = iClose(sym, InpEntryTF, 1);
   double closeLag = iClose(sym, InpEntryTF, 1 + InpChikouShift);
   if(close1 == 0 || closeLag == 0)
   { if(InpLogEveryCheck) PrintFormat("[SIGNAL] %s | REJECT close=0", sym); return 0; }

   double cloudTop_E = MathMax(senA[1], senB[1]);
   double cloudBot_E = MathMin(senA[1], senB[1]);
   bool   kumoGreen  = (senA[1] > senB[1]);

   // Find most recent TK cross within window
   int tkCrossDir = 0;  // 1=bullish, -1=bearish
   int tkCrossAge = -1;
   for(int k = 1; k <= InpMaxTKCrossAgeBars; k++)
   {
      bool bullCross = (tenkan[k + 1] <= kijun[k + 1] && tenkan[k] > kijun[k]);
      bool bearCross = (tenkan[k + 1] >= kijun[k + 1] && tenkan[k] < kijun[k]);
      if(bullCross) { tkCrossDir = 1;  tkCrossAge = k; break; }
      if(bearCross) { tkCrossDir = -1; tkCrossAge = k; break; }
   }

   // === LONG ===
   if(d1Trend >= 0 && tkCrossDir == 1)
   {
      bool cloudBreak  = (!InpRequireCloudBreak) || (close1 > cloudTop_E);
      bool chikouFree  = (!InpRequireChikouFree) || (close1 > closeLag);
      bool kumoOK      = (!InpRequireKumoColor) || kumoGreen;
      bool tkAbove     = (tenkan[1] > kijun[1]);

      if(tkAbove && cloudBreak && chikouFree && kumoOK)
      {
         PrintFormat("[SIGNAL] %s | >> BUY << TKage=%d T=%.5f K=%.5f close=%.5f cloudTop=%.5f kumo=%s chikou=%s",
                     sym, tkCrossAge, tenkan[1], kijun[1], close1, cloudTop_E,
                     kumoGreen ? "GREEN" : "RED",
                     (close1 > closeLag) ? "FREE" : "BLOCKED");
         return 1;
      }
      if(InpLogEveryCheck)
         PrintFormat("[SIGNAL] %s | LONG chk: TKage=%d tkAbove=%s cloudBreak=%s(close=%.5f top=%.5f) chikou=%s(close=%.5f lag=%.5f) kumo=%s",
                     sym, tkCrossAge,
                     tkAbove ? "Y" : "N",
                     cloudBreak ? "Y" : "N", close1, cloudTop_E,
                     chikouFree ? "Y" : "N", close1, closeLag,
                     kumoGreen ? "GREEN" : "RED");
   }

   // === SHORT ===
   if(d1Trend <= 0 && tkCrossDir == -1)
   {
      bool cloudBreak  = (!InpRequireCloudBreak) || (close1 < cloudBot_E);
      bool chikouFree  = (!InpRequireChikouFree) || (close1 < closeLag);
      bool kumoOK      = (!InpRequireKumoColor) || (!kumoGreen);
      bool tkBelow     = (tenkan[1] < kijun[1]);

      if(tkBelow && cloudBreak && chikouFree && kumoOK)
      {
         PrintFormat("[SIGNAL] %s | >> SELL << TKage=%d T=%.5f K=%.5f close=%.5f cloudBot=%.5f kumo=%s chikou=%s",
                     sym, tkCrossAge, tenkan[1], kijun[1], close1, cloudBot_E,
                     kumoGreen ? "GREEN" : "RED",
                     (close1 < closeLag) ? "FREE" : "BLOCKED");
         return -1;
      }
      if(InpLogEveryCheck)
         PrintFormat("[SIGNAL] %s | SHORT chk: TKage=%d tkBelow=%s cloudBreak=%s(close=%.5f bot=%.5f) chikou=%s(close=%.5f lag=%.5f) kumo=%s",
                     sym, tkCrossAge,
                     tkBelow ? "Y" : "N",
                     cloudBreak ? "Y" : "N", close1, cloudBot_E,
                     chikouFree ? "Y" : "N", close1, closeLag,
                     kumoGreen ? "GREEN" : "RED");
   }

   if(InpLogEveryCheck && tkCrossDir == 0)
      PrintFormat("[SIGNAL] %s | No recent TK cross within %d bars (D1=%s T=%.5f K=%.5f)",
                  sym, InpMaxTKCrossAgeBars,
                  (d1Trend == 1) ? "UP" : (d1Trend == -1) ? "DOWN" : "FLAT",
                  tenkan[1], kijun[1]);

   return 0;
}

//+------------------------------------------------------------------+
//| Open Buy                                                          |
//+------------------------------------------------------------------+
bool OpenBuy(int idx)
{
   string sym = g_symbols[idx].name;

   double atrBuf[], kijunBuf[];
   if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atrBuf) != 2) return false;
   if(CopyBuffer(g_symbols[idx].hIchiEntry, ICH_KIJUN, 0, 2, kijunBuf) != 2) return false;
   ArraySetAsSeries(atrBuf, true);
   ArraySetAsSeries(kijunBuf, true);
   double atrVal   = atrBuf[1];
   double kijunVal = kijunBuf[1];

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

   // SL: below Kijun minus small buffer, or ATR floor (whichever is wider from entry)
   double slByKijun = kijunVal - atrVal * 0.3;
   double slByATR   = ask - atrVal * InpMinSL_ATR;
   double sl        = MathMin(slByKijun, slByATR);  // further = safer for long
   double sl_dist   = ask - sl;

   if(sl_dist <= 0)
   {
      PrintFormat("[SKIP] %s BUY | SL dist <= 0 (kijun=%.5f atr=%.5f ask=%.5f)", sym, kijunVal, atrVal, ask);
      return false;
   }

   double stopLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) *
                    SymbolInfoDouble(sym, SYMBOL_POINT);
   if(sl_dist < stopLvl * 1.2) sl_dist = stopLvl * 1.2;

   double tp_dist = sl_dist * InpTP_R;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sl = NormalizeDouble(ask - sl_dist, digits);
   double tp = NormalizeDouble(ask + tp_dist, digits);

   double lots = CalculateLotSize(sym, sl_dist);
   if(lots <= 0) { PrintFormat("[SKIP] %s BUY | Lot calc zero", sym); return false; }

   double marginReq = 0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, sym, lots, ask, marginReq)) return false;
   if(marginReq > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      PrintFormat("[SKIP] %s BUY | Insufficient margin (need %.2f)", sym, marginReq);
      return false;
   }

   g_trade.SetTypeFilling(GetFillingType(sym));
   if(g_trade.Buy(lots, sym, ask, sl, tp, StringFormat("ICH_%s", sym)))
   {
      g_symbols[idx].lastEntryTime = TimeCurrent();
      PrintFormat("[TRADE] BUY %s | Lots:%.2f | Entry:%.*f | SL:%.*f | TP:%.*f | Kijun:%.*f | ATR:%.*f",
                  sym, lots, digits, ask, digits, sl, digits, tp, digits, kijunVal, digits, atrVal);
      if(InpAlerts) Alert(StringFormat("ICHI BUY %s %.2f", sym, lots));
      if(InpPushNotify) SendNotification(StringFormat("ICHI BUY %s %.2f", sym, lots));
      return true;
   }
   PrintFormat("[ERROR] Buy failed %s: %d - %s", sym, GetLastError(), g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
//| Open Sell                                                         |
//+------------------------------------------------------------------+
bool OpenSell(int idx)
{
   string sym = g_symbols[idx].name;

   double atrBuf[], kijunBuf[];
   if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atrBuf) != 2) return false;
   if(CopyBuffer(g_symbols[idx].hIchiEntry, ICH_KIJUN, 0, 2, kijunBuf) != 2) return false;
   ArraySetAsSeries(atrBuf, true);
   ArraySetAsSeries(kijunBuf, true);
   double atrVal   = atrBuf[1];
   double kijunVal = kijunBuf[1];

   double bid = SymbolInfoDouble(sym, SYMBOL_BID);

   double slByKijun = kijunVal + atrVal * 0.3;
   double slByATR   = bid + atrVal * InpMinSL_ATR;
   double sl        = MathMax(slByKijun, slByATR);
   double sl_dist   = sl - bid;

   if(sl_dist <= 0)
   {
      PrintFormat("[SKIP] %s SELL | SL dist <= 0", sym);
      return false;
   }

   double stopLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) *
                    SymbolInfoDouble(sym, SYMBOL_POINT);
   if(sl_dist < stopLvl * 1.2) sl_dist = stopLvl * 1.2;

   double tp_dist = sl_dist * InpTP_R;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sl = NormalizeDouble(bid + sl_dist, digits);
   double tp = NormalizeDouble(bid - tp_dist, digits);

   double lots = CalculateLotSize(sym, sl_dist);
   if(lots <= 0) { PrintFormat("[SKIP] %s SELL | Lot calc zero", sym); return false; }

   double marginReq = 0;
   if(!OrderCalcMargin(ORDER_TYPE_SELL, sym, lots, bid, marginReq)) return false;
   if(marginReq > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) return false;

   g_trade.SetTypeFilling(GetFillingType(sym));
   if(g_trade.Sell(lots, sym, bid, sl, tp, StringFormat("ICH_%s", sym)))
   {
      g_symbols[idx].lastEntryTime = TimeCurrent();
      PrintFormat("[TRADE] SELL %s | Lots:%.2f | Entry:%.*f | SL:%.*f | TP:%.*f | Kijun:%.*f | ATR:%.*f",
                  sym, lots, digits, bid, digits, sl, digits, tp, digits, kijunVal, digits, atrVal);
      if(InpAlerts) Alert(StringFormat("ICHI SELL %s %.2f", sym, lots));
      if(InpPushNotify) SendNotification(StringFormat("ICHI SELL %s %.2f", sym, lots));
      return true;
   }
   PrintFormat("[ERROR] Sell failed %s: %d - %s", sym, GetLastError(), g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
//| Lot sizing                                                        |
//+------------------------------------------------------------------+
double CalculateLotSize(string sym, double sl_distance)
{
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;
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
//| Manage positions: Kijun trail, breakeven, time exit               |
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

      double atrBuf[], kijunBuf[];
      if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atrBuf) != 2) continue;
      if(CopyBuffer(g_symbols[idx].hIchiEntry, ICH_KIJUN, 0, 2, kijunBuf) != 2) continue;
      ArraySetAsSeries(atrBuf, true);
      ArraySetAsSeries(kijunBuf, true);
      double atrVal   = atrBuf[1];
      double kijunVal = kijunBuf[1];

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

      double slDistInit = MathAbs(openPrice - currentSL);
      double rProfit;

      if(posType == POSITION_TYPE_BUY)
      {
         double curPrice = SymbolInfoDouble(sym, SYMBOL_BID);
         rProfit = (curPrice - openPrice) / slDistInit;

         // Kijun-based trailing stop: once in profit, trail below Kijun
         double kijunSL = NormalizeDouble(kijunVal - atrVal * 0.3, digits);
         if(rProfit >= InpBE_R && kijunSL > currentSL + point && kijunSL < curPrice)
         {
            g_trade.SetTypeFilling(GetFillingType(sym));
            g_trade.PositionModify(ticket, kijunSL, currentTP);
         }
         else if(rProfit >= InpBE_R)
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
         double curPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
         rProfit = (openPrice - curPrice) / slDistInit;

         double kijunSL = NormalizeDouble(kijunVal + atrVal * 0.3, digits);
         if(rProfit >= InpBE_R && (kijunSL < currentSL - point || currentSL == 0) && kijunSL > curPrice)
         {
            g_trade.SetTypeFilling(GetFillingType(sym));
            g_trade.PositionModify(ticket, kijunSL, currentTP);
         }
         else if(rProfit >= InpBE_R)
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
//| Close all our positions                                           |
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
//| Currency exposure cap                                             |
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
//| Cooldown                                                          |
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
//| Session                                                           |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeGMT(dt);
   int gmtHour = dt.hour;
   if(InpSessionStart < InpSessionEnd)
      return (gmtHour >= InpSessionStart && gmtHour < InpSessionEnd);
   return (gmtHour >= InpSessionStart || gmtHour < InpSessionEnd);
}

bool IsFridayCloseTime()
{
   MqlDateTime dt;
   TimeGMT(dt);
   return (dt.day_of_week == 5 && dt.hour >= InpFridayCloseHourGMT);
}

//+------------------------------------------------------------------+
//| New bar detection                                                 |
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
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dayStartBalance - equity) / g_dayStartBalance * 100.0;
   return (lossPct >= InpMaxDailyLossPct);
}

bool CheckDrawdownHalted()
{
   if(g_peakEquity <= 0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct  = (g_peakEquity - equity) / g_peakEquity * 100.0;
   if(ddPct >= InpMaxDrawdownPct) g_drawdownHalted = true;
   return g_drawdownHalted;
}

ENUM_ORDER_TYPE_FILLING GetFillingType(string sym)
{
   long filling = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

bool IsExoticPair(string baseName)
{
   for(int i = 0; i < ArraySize(EXOTIC_QUOTES); i++)
      if(StringFind(baseName, EXOTIC_QUOTES[i]) >= 0) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Verbose log                                                       |
//+------------------------------------------------------------------+
void LogBarCheck(int idx)
{
   string sym = g_symbols[idx].name;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double tenkan[2], kijun[2], senA[2], senB[2];
   if(CopyBuffer(g_symbols[idx].hIchiEntry, ICH_TENKAN,  0, 2, tenkan) != 2) return;
   if(CopyBuffer(g_symbols[idx].hIchiEntry, ICH_KIJUN,   0, 2, kijun)  != 2) return;
   if(CopyBuffer(g_symbols[idx].hIchiEntry, ICH_SENKOUA, 0, 2, senA)   != 2) return;
   if(CopyBuffer(g_symbols[idx].hIchiEntry, ICH_SENKOUB, 0, 2, senB)   != 2) return;
   ArraySetAsSeries(tenkan, true);
   ArraySetAsSeries(kijun, true);
   ArraySetAsSeries(senA, true);
   ArraySetAsSeries(senB, true);

   double close1 = iClose(sym, InpEntryTF, 1);
   double top    = MathMax(senA[1], senB[1]);
   double bot    = MathMin(senA[1], senB[1]);
   string kumo   = (senA[1] > senB[1]) ? "GREEN" : "RED";
   string pxPos  = (close1 > top) ? "ABOVE" : (close1 < bot) ? "BELOW" : "IN_CLOUD";
   string tk     = (tenkan[1] > kijun[1]) ? "T>K" : "T<K";

   PrintFormat("[SCAN] %s | Close:%.*f | T:%.*f K:%.*f | SpanA:%.*f SpanB:%.*f | %s | Kumo:%s | %s | Sprd:%.1f",
      sym, digits, close1,
      digits, tenkan[1], digits, kijun[1],
      digits, senA[1], digits, senB[1],
      pxPos, kumo, tk, GetSpreadPips(idx));
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
   dash += "========= ICHIMOKU SWING =========\n";
   dash += StringFormat("Balance : %.2f %s\n", balance, AccountInfoString(ACCOUNT_CURRENCY));
   dash += StringFormat("Equity  : %.2f (peak %.2f)\n", equity, g_peakEquity);
   dash += StringFormat("Daily PL: %+.2f (%.1f%%)\n", dailyPL,
           g_dayStartBalance > 0 ? (dailyPL / g_dayStartBalance) * 100.0 : 0);
   dash += StringFormat("Drawdown: %.1f%% / %.1f%%\n", ddPct, InpMaxDrawdownPct);
   dash += StringFormat("Open    : %d / %d\n", trades, InpMaxTrades);
   dash += StringFormat("Today   : %d entries\n", g_todayTrades);
   dash += StringFormat("Risk    : %.1f%% | TP=%.1fR\n", InpRiskPercent, InpTP_R);
   dash += StringFormat("Session : %s\n", IsSessionActive() ? "ACTIVE" : "CLOSED");
   dash += StringFormat("TrendTF : %s | EntryTF: %s\n",
           EnumToString(InpTrendTF), EnumToString(InpEntryTF));
   dash += StringFormat("Ichimoku: %d/%d/%d\n", InpTenkan, InpKijun, InpSenkouB);

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
   dash += "==================================";

   Comment(dash);
}
//+------------------------------------------------------------------+
