//+------------------------------------------------------------------+
//|                                              HFT_noTrailingTP.mq5 |
//|                  High-Frequency Micro Scalper (No Trailing SL)    |
//|                         Capital: 900 AUD | Target: 2-3% per trade |
//+------------------------------------------------------------------+
#property copyright "HFT Micro Scalper EA"
#property version   "1.00"
#property description "High-frequency micro scalper for Forex pairs."
#property description "Dual signal: EMA momentum crossover + BB mean reversion."
#property description "M1 timeframe, targets 2-3% per winning trade."
#property description "Scans majors, minors, and exotics from a single chart."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Strategy ==="
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_M1;    // Trading Timeframe
input int    InpEMAFast                = 3;             // Fast EMA Period
input int    InpEMAMid                 = 8;             // Mid EMA Period
input int    InpEMATrend               = 21;            // Trend Filter EMA Period
input int    InpRSIPeriod              = 5;             // RSI Period
input int    InpATRPeriod              = 7;             // ATR Period
input int    InpBBPeriod               = 14;            // Bollinger Bands Period
input double InpBBDeviation            = 2.0;           // Bollinger Bands Deviation
input double InpRSILongLower           = 35.0;          // RSI Min for Longs (EMA signal)
input double InpRSILongUpper           = 70.0;          // RSI Max for Longs (EMA signal)
input double InpRSIShortLower          = 30.0;          // RSI Min for Shorts (EMA signal)
input double InpRSIShortUpper          = 65.0;          // RSI Max for Shorts (EMA signal)

input group "=== Risk Management ==="
input double InpRiskPercent            = 10.0;          // Risk % per Trade (aggressive)
input double InpSL_ATR                 = 15.0;          // Stop Loss = x * ATR (wide safety net)
input double InpTP_ATR                 = 4.5;           // Take Profit = x * ATR (~3% profit)
input int    InpMaxTrades              = 20;            // Max Concurrent Trades
input double InpMaxLot                 = 0.50;          // Max Lot Size (safety cap)
input double InpMaxDailyLossPct        = 15.0;          // Daily Loss Limit % (relaxed)
input int    InpCooldownBars           = 3;             // Min Bars Between Entries Per Symbol
input int    InpMaxHoldBars            = 1440;          // Max Hold Duration (M1 bars, 0=off)

input group "=== Session Filter (GMT) ==="
input int    InpSessionStart           = 7;             // Session Start Hour (GMT)
input int    InpSessionEnd             = 20;            // Session End Hour (GMT)
input int    InpLocalGMTOffset         = 10;            // Your Local GMT Offset (Melbourne=10)

input group "=== Symbols ==="
input string InpSuffix                 = "";            // Broker Symbol Suffix (e.g. ".raw", "m")
input double InpMaxSpreadPips          = 3.0;           // Max Spread (pips) - tight for HFT

input group "=== General ==="
input long   InpMagic                  = 547824;        // Magic Number
input bool   InpAlerts                 = false;         // Enable Alerts
input bool   InpPushNotify             = false;         // Enable Push Notifications
input bool   InpVerboseLog             = false;         // Verbose Scan Logging (every bar)

//+------------------------------------------------------------------+
//| Per-symbol data                                                   |
//+------------------------------------------------------------------+
struct SSymbolData
{
   string   name;
   int      hEMAFast;
   int      hEMAMid;
   int      hEMATrend;
   int      hRSI;
   int      hATR;
   int      hBB;
   datetime lastBarTime;
   datetime lastEntryTime;
   double   pipSize;
   bool     active;
};

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
SSymbolData g_symbols[];
int         g_numSymbols       = 0;
CTrade      g_trade;
double      g_dayStartBalance  = 0;
datetime    g_lastDay          = 0;
int         g_todayTrades      = 0;

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

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(10);

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

      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(digits == 3 || digits == 5)
         g_symbols[idx].pipSize = 10.0 * SymbolInfoDouble(sym, SYMBOL_POINT);
      else
         g_symbols[idx].pipSize = SymbolInfoDouble(sym, SYMBOL_POINT);

      g_symbols[idx].hEMAFast  = iMA(sym, InpTimeframe, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hEMAMid   = iMA(sym, InpTimeframe, InpEMAMid, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hEMATrend = iMA(sym, InpTimeframe, InpEMATrend, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hRSI      = iRSI(sym, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
      g_symbols[idx].hATR      = iATR(sym, InpTimeframe, InpATRPeriod);
      g_symbols[idx].hBB       = iBands(sym, InpTimeframe, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);

      if(g_symbols[idx].hEMAFast  == INVALID_HANDLE ||
         g_symbols[idx].hEMAMid   == INVALID_HANDLE ||
         g_symbols[idx].hEMATrend == INVALID_HANDLE ||
         g_symbols[idx].hRSI      == INVALID_HANDLE ||
         g_symbols[idx].hATR      == INVALID_HANDLE ||
         g_symbols[idx].hBB       == INVALID_HANDLE)
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
   g_lastDay = iTime(_Symbol, PERIOD_D1, 0);
   g_todayTrades = 0;

   EventSetTimer(1);

   PrintFormat("[INIT] HFT EA started: %d symbols, Magic=%d, Risk=%.1f%%, MaxTrades=%d, TF=M%d",
               g_numSymbols, InpMagic, InpRiskPercent, InpMaxTrades, PeriodSeconds(InpTimeframe)/60);
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
      if(g_symbols[i].hEMAFast  != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hEMAFast);
      if(g_symbols[i].hEMAMid   != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hEMAMid);
      if(g_symbols[i].hEMATrend != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hEMATrend);
      if(g_symbols[i].hRSI      != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hRSI);
      if(g_symbols[i].hATR      != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hATR);
      if(g_symbols[i].hBB       != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hBB);
   }

   Comment("");
}

//+------------------------------------------------------------------+
//| Timer - 1 second scan for HFT responsiveness                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   MainLogic();
}

//+------------------------------------------------------------------+
//| Tick                                                              |
//+------------------------------------------------------------------+
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

   if(CheckDailyLossExceeded())
   {
      DisplayDashboard("!! DAILY LOSS LIMIT - TRADING PAUSED !!");
      return;
   }

   ManagePositions();

   int openCount = CountOpenTrades();

   for(int i = 0; i < g_numSymbols; i++)
   {
      if(!g_symbols[i].active) continue;
      if(!IsNewBar(i)) continue;

      if(InpVerboseLog)
         LogBarCheck(i);

      if(openCount >= InpMaxTrades) continue;
      if(HasPosition(g_symbols[i].name)) continue;
      if(!IsSessionActive()) continue;

      double spread = GetSpreadPips(i);
      if(spread > InpMaxSpreadPips) continue;
      if(!CheckCooldown(i)) continue;

      int sigType = 0;
      int signal = CheckSignal(i, sigType);

      if(signal == 1)
      {
         if(OpenBuy(i, sigType))
         {
            openCount++;
            g_todayTrades++;
         }
      }
      else if(signal == -1)
      {
         if(OpenSell(i, sigType))
         {
            openCount++;
            g_todayTrades++;
         }
      }
   }

   DisplayDashboard("");
}

//+------------------------------------------------------------------+
//| Dual signal engine                                                |
//| sigType: 1=EMA crossover, 2=BB bounce                            |
//| Returns: 1=Buy, -1=Sell, 0=None                                  |
//+------------------------------------------------------------------+
int CheckSignal(int idx, int &sigType)
{
   sigType = 0;

   double emaFast[3], emaMid[3], emaTrend[3], rsi[3], atr[3];
   double bbUpper[3], bbLower[3];

   if(CopyBuffer(g_symbols[idx].hEMAFast,  0, 0, 3, emaFast)  != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hEMAMid,   0, 0, 3, emaMid)   != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hEMATrend, 0, 0, 3, emaTrend) != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hRSI,      0, 0, 3, rsi)      != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hATR,      0, 0, 3, atr)      != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hBB,       1, 0, 3, bbUpper)  != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hBB,       2, 0, 3, bbLower)  != 3) return 0;

   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaMid, true);
   ArraySetAsSeries(emaTrend, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);

   string sym = g_symbols[idx].name;
   double close1 = iClose(sym, InpTimeframe, 1);
   double close2 = iClose(sym, InpTimeframe, 2);
   if(close1 == 0 || close2 == 0) return 0;

   // Dead market filter
   if(atr[1] < g_symbols[idx].pipSize * 2) return 0;

   // === SIGNAL 1: EMA MOMENTUM CROSSOVER ===

   // Bullish crossover
   if(emaFast[2] < emaMid[2] && emaFast[1] >= emaMid[1])
   {
      if(close1 > emaTrend[1])
      {
         if(rsi[1] >= InpRSILongLower && rsi[1] <= InpRSILongUpper)
         {
            sigType = 1;
            return 1;
         }
      }
   }

   // Bearish crossover
   if(emaFast[2] > emaMid[2] && emaFast[1] <= emaMid[1])
   {
      if(close1 < emaTrend[1])
      {
         if(rsi[1] >= InpRSIShortLower && rsi[1] <= InpRSIShortUpper)
         {
            sigType = 1;
            return -1;
         }
      }
   }

   // === SIGNAL 2: BOLLINGER BAND MEAN REVERSION ===

   // Bullish bounce off lower band
   if(close2 <= bbLower[2] && close1 > bbLower[1])
   {
      if(rsi[1] >= 25 && rsi[1] <= 55)
      {
         sigType = 2;
         return 1;
      }
   }

   // Bearish rejection from upper band
   if(close2 >= bbUpper[2] && close1 < bbUpper[1])
   {
      if(rsi[1] >= 45 && rsi[1] <= 75)
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
   double sl      = ask - sl_dist;
   double tp      = ask + tp_dist;

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

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

   string sigName = (sigType == 1) ? "EMA" : "BB";

   if(g_trade.Buy(lots, sym, ask, sl, tp, StringFormat("HFT_%s_%s", sigName, sym)))
   {
      g_symbols[idx].lastEntryTime = TimeCurrent();
      PrintFormat("[TRADE] BUY %s | %s | Lots:%.2f | Entry:%.*f | SL:%.*f | TP:%.*f | ATR:%.*f",
                  sym, sigName, lots, digits, ask, digits, sl, digits, tp, digits, atrVal);
      if(InpAlerts) Alert(StringFormat("HFT BUY %s (%s) | Lots:%.2f", sym, sigName, lots));
      if(InpPushNotify) SendNotification(StringFormat("HFT BUY %s (%s) %.2f", sym, sigName, lots));
      return true;
   }
   else
   {
      PrintFormat("[ERROR] Buy failed %s: %d - %s", sym, GetLastError(), g_trade.ResultRetcodeDescription());
      return false;
   }
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
   double sl      = bid + sl_dist;
   double tp      = bid - tp_dist;

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

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
      PrintFormat("[SKIP] %s SELL | Insufficient margin (need %.2f, free %.2f)",
                  sym, marginReq, AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      return false;
   }

   g_trade.SetTypeFilling(GetFillingType(sym));

   string sigName = (sigType == 1) ? "EMA" : "BB";

   if(g_trade.Sell(lots, sym, bid, sl, tp, StringFormat("HFT_%s_%s", sigName, sym)))
   {
      g_symbols[idx].lastEntryTime = TimeCurrent();
      PrintFormat("[TRADE] SELL %s | %s | Lots:%.2f | Entry:%.*f | SL:%.*f | TP:%.*f | ATR:%.*f",
                  sym, sigName, lots, digits, bid, digits, sl, digits, tp, digits, atrVal);
      if(InpAlerts) Alert(StringFormat("HFT SELL %s (%s) | Lots:%.2f", sym, sigName, lots));
      if(InpPushNotify) SendNotification(StringFormat("HFT SELL %s (%s) %.2f", sym, sigName, lots));
      return true;
   }
   else
   {
      PrintFormat("[ERROR] Sell failed %s: %d - %s", sym, GetLastError(), g_trade.ResultRetcodeDescription());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Lot size from risk % and ATR stop distance                        |
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

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Manage positions: time exit only                                  |
//+------------------------------------------------------------------+
void ManagePositions()
{
   if(InpMaxHoldBars <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      string sym = PositionGetString(POSITION_SYMBOL);

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int barsHeld = Bars(sym, InpTimeframe, openTime, TimeCurrent());

      if(barsHeld >= InpMaxHoldBars)
      {
         g_trade.SetTypeFilling(GetFillingType(sym));
         if(g_trade.PositionClose(ticket))
            PrintFormat("[EXIT] Time exit %s after %d bars", sym, barsHeld);
      }
   }
}

//+------------------------------------------------------------------+
//| Cooldown: min bars since last entry on this symbol                |
//+------------------------------------------------------------------+
bool CheckCooldown(int idx)
{
   if(InpCooldownBars <= 0) return true;
   if(g_symbols[idx].lastEntryTime == 0) return true;

   int barsSince = Bars(g_symbols[idx].name, InpTimeframe,
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
//| New bar detection per symbol                                      |
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
//| Order filling type                                                |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingType(string sym)
{
   long filling = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Log bar snapshot (verbose mode)                                   |
//+------------------------------------------------------------------+
void LogBarCheck(int idx)
{
   string sym = g_symbols[idx].name;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double emaFast[3], emaMid[3], emaTrend[3], rsi[3], atr[3];
   double bbUpper[3], bbLower[3];

   if(CopyBuffer(g_symbols[idx].hEMAFast,  0, 0, 3, emaFast)  != 3) return;
   if(CopyBuffer(g_symbols[idx].hEMAMid,   0, 0, 3, emaMid)   != 3) return;
   if(CopyBuffer(g_symbols[idx].hEMATrend, 0, 0, 3, emaTrend) != 3) return;
   if(CopyBuffer(g_symbols[idx].hRSI,      0, 0, 3, rsi)      != 3) return;
   if(CopyBuffer(g_symbols[idx].hATR,      0, 0, 3, atr)      != 3) return;
   if(CopyBuffer(g_symbols[idx].hBB,       1, 0, 3, bbUpper)  != 3) return;
   if(CopyBuffer(g_symbols[idx].hBB,       2, 0, 3, bbLower)  != 3) return;

   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaMid, true);
   ArraySetAsSeries(emaTrend, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);

   double close1 = iClose(sym, InpTimeframe, 1);
   double close2 = iClose(sym, InpTimeframe, 2);
   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   double spread = GetSpreadPips(idx);
   bool   hasPos = HasPosition(sym);
   bool   session = IsSessionActive();

   // Determine signal label (mirrors CheckSignal logic including all filters)
   string signalStr = "NONE";
   bool   deadMkt   = (atr[1] < g_symbols[idx].pipSize * 2);

   if(deadMkt)
   {
      signalStr = "DEAD_MKT";
   }
   else
   {
      bool bullCross = (emaFast[2] < emaMid[2] && emaFast[1] >= emaMid[1]);
      bool bearCross = (emaFast[2] > emaMid[2] && emaFast[1] <= emaMid[1]);
      bool bbBuyBounce  = (close2 <= bbLower[2] && close1 > bbLower[1]);
      bool bbSellBounce = (close2 >= bbUpper[2] && close1 < bbUpper[1]);

      if(bullCross && close1 > emaTrend[1] && rsi[1] >= InpRSILongLower && rsi[1] <= InpRSILongUpper)
         signalStr = ">> BUY EMA <<";
      else if(bearCross && close1 < emaTrend[1] && rsi[1] >= InpRSIShortLower && rsi[1] <= InpRSIShortUpper)
         signalStr = ">> SELL EMA <<";
      else if(bbBuyBounce && rsi[1] >= 25 && rsi[1] <= 55)
         signalStr = ">> BUY BB <<";
      else if(bbSellBounce && rsi[1] >= 45 && rsi[1] <= 75)
         signalStr = ">> SELL BB <<";
      else if(bullCross)
         signalStr = "Bull cross (filtered)";
      else if(bearCross)
         signalStr = "Bear cross (filtered)";
      else if(bbBuyBounce || bbSellBounce)
         signalStr = "BB touch (filtered)";
   }

   string trend = (close1 > emaTrend[1]) ? "UP" : "DOWN";

   PrintFormat("[SCAN] %s | Bid:%.*f | EMA3:%.*f EMA8:%.*f EMA21:%.*f | RSI:%.1f | ATR:%.*f | Sprd:%.1f | Trend:%s | Pos:%s | Sess:%s | %s",
      sym,
      digits, bid,
      digits, emaFast[1],
      digits, emaMid[1],
      digits, emaTrend[1],
      rsi[1],
      digits, atr[1],
      spread,
      trend,
      hasPos ? "YES" : "no",
      session ? "ON" : "OFF",
      signalStr
   );
}

//+------------------------------------------------------------------+
//| Dashboard                                                         |
//+------------------------------------------------------------------+
void DisplayDashboard(string extra)
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyPL = equity - g_dayStartBalance;
   int    trades  = CountOpenTrades();

   string dash = "\n";
   dash += "======= HFT MICRO SCALPER =======\n";
   dash += StringFormat("Balance : %.2f AUD\n", balance);
   dash += StringFormat("Equity  : %.2f AUD\n", equity);
   dash += StringFormat("Daily PL: %+.2f AUD (%.1f%%)\n", dailyPL,
           g_dayStartBalance > 0 ? (dailyPL / g_dayStartBalance) * 100.0 : 0);
   dash += StringFormat("Open    : %d / %d\n", trades, InpMaxTrades);
   dash += StringFormat("Today   : %d trades\n", g_todayTrades);
   dash += StringFormat("Risk    : %.1f%% | R:R 1:%.1f\n", InpRiskPercent, InpTP_ATR / InpSL_ATR);
   dash += StringFormat("Session : %s\n", IsSessionActive() ? "ACTIVE" : "CLOSED");
   dash += StringFormat("Signals : EMA(%d/%d) + BB(%d,%.1f)\n",
           InpEMAFast, InpEMAMid, InpBBPeriod, InpBBDeviation);

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
   if(posCount > 0)
      dash += "Active  : " + posList + "\n";

   if(extra != "")
      dash += "\n>> " + extra + "\n";

   dash += "==================================";

   Comment(dash);
}
//+------------------------------------------------------------------+
