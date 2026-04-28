//+------------------------------------------------------------------+
//|                                                 TrendRider4.mq5  |
//|              INVERSE of TrendRider3 — Counter-Trend Fader         |
//|                         Capital: 900 AUD                          |
//+------------------------------------------------------------------+
#property copyright "TrendRider4 EA"
#property version   "1.00"
#property description "Exact inverse of TrendRider3."
#property description "H1 uptrend detected = SELL the pullback bounce."
#property description "H1 downtrend detected = BUY the pullback rejection."
#property description "Fixed TP + tight trailing for counter-trend moves."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Trend Detection (H1) ==="
input int    InpH1EMAFast              = 20;            // H1 Fast EMA Period
input int    InpH1EMASlow              = 50;            // H1 Slow EMA Period

input group "=== Entry Timing (M15) ==="
input int    InpEntryEMA               = 20;            // M15 Entry EMA (pullback target)
input int    InpRSIPeriod              = 14;            // M15 RSI Period
input int    InpATRPeriod              = 14;            // M15 ATR Period

input group "=== Risk Management ==="
input double InpRiskPercent            = 1.5;           // Risk % per Trade
input double InpSL_ATR                 = 2.0;           // Initial SL = x * ATR
input double InpTP_ATR                 = 2.0;           // Take Profit = x * ATR (fixed)
input double InpBE_ATR                 = 1.0;           // Move SL to Breakeven at x * ATR profit
input double InpTrailTrigger_ATR       = 1.5;           // Start Trailing at x * ATR profit
input double InpTrailDist_ATR          = 1.0;           // Trail Distance = x * ATR
input int    InpMaxTrades              = 3;             // Max Concurrent Trades
input double InpMaxLot                 = 0.10;          // Max Lot Size
input double InpMaxDailyLossPct        = 5.0;           // Daily Loss Limit %
input int    InpCooldownBars           = 4;             // Min M15 Bars Between Entries Per Symbol

input group "=== Session Filter (GMT) ==="
input int    InpSessionStart           = 7;             // Session Start Hour (GMT)
input int    InpSessionEnd             = 20;            // Session End Hour (GMT)
input int    InpLocalGMTOffset         = 10;            // Your Local GMT Offset (Melbourne=10)

input group "=== Symbols ==="
input string InpSuffix                 = "";            // Broker Symbol Suffix
input double InpMaxSpreadPips          = 2.0;           // Max Spread (pips)

input group "=== General ==="
input long   InpMagic                  = 771156;        // Magic Number
input bool   InpAlerts                 = false;         // Enable Alerts
input bool   InpPushNotify             = false;         // Enable Push Notifications

//+------------------------------------------------------------------+
//| Per-symbol data                                                   |
//+------------------------------------------------------------------+
struct SSymbolData
{
   string   name;
   int      hH1EMAFast;
   int      hH1EMASlow;
   int      hM15EMA;
   int      hRSI;
   int      hATR;
   datetime lastBarTime;
   datetime lastEntryTime;
   int      trendDir;        // 1=up, -1=down, 0=none
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
   "EURUSD","GBPUSD","USDJPY","AUDUSD","NZDUSD","USDCAD","USDCHF"
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
      g_symbols[idx].trendDir      = 0;
      g_symbols[idx].active        = true;

      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(digits == 3 || digits == 5)
         g_symbols[idx].pipSize = 10.0 * SymbolInfoDouble(sym, SYMBOL_POINT);
      else
         g_symbols[idx].pipSize = SymbolInfoDouble(sym, SYMBOL_POINT);

      g_symbols[idx].hH1EMAFast = iMA(sym, PERIOD_H1, InpH1EMAFast, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hH1EMASlow = iMA(sym, PERIOD_H1, InpH1EMASlow, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hM15EMA    = iMA(sym, PERIOD_M15, InpEntryEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hRSI       = iRSI(sym, PERIOD_M15, InpRSIPeriod, PRICE_CLOSE);
      g_symbols[idx].hATR       = iATR(sym, PERIOD_M15, InpATRPeriod);

      if(g_symbols[idx].hH1EMAFast == INVALID_HANDLE ||
         g_symbols[idx].hH1EMASlow == INVALID_HANDLE ||
         g_symbols[idx].hM15EMA    == INVALID_HANDLE ||
         g_symbols[idx].hRSI       == INVALID_HANDLE ||
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
   g_lastDay = iTime(_Symbol, PERIOD_D1, 0);
   g_todayTrades = 0;

   EventSetTimer(5);

   PrintFormat("[INIT] TrendRider4 (INVERSE) started: %d symbols, Magic=%d, Risk=%.1f%%, MaxTrades=%d",
               g_numSymbols, InpMagic, InpRiskPercent, InpMaxTrades);
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
      if(g_symbols[i].hH1EMAFast != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hH1EMAFast);
      if(g_symbols[i].hH1EMASlow != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hH1EMASlow);
      if(g_symbols[i].hM15EMA    != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hM15EMA);
      if(g_symbols[i].hRSI       != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hRSI);
      if(g_symbols[i].hATR       != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hATR);
   }

   Comment("");
}

//+------------------------------------------------------------------+
//| Timer                                                             |
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
//| Main trading logic — INVERTED: signal 1 = Sell, signal -1 = Buy  |
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

   TrailPositions();

   for(int i = 0; i < g_numSymbols; i++)
   {
      if(!g_symbols[i].active) continue;

      UpdateTrend(i);

      if(!IsNewBar(i)) continue;

      int openCount = CountOpenTrades();
      if(openCount >= InpMaxTrades) continue;
      if(HasPosition(g_symbols[i].name)) continue;
      if(!IsSessionActive()) continue;

      double spread = GetSpreadPips(i);
      if(spread > InpMaxSpreadPips) continue;
      if(!CheckCooldown(i)) continue;

      int signal = CheckEntry(i);

      // INVERTED: original buy signal → sell, original sell signal → buy
      if(signal == 1)
      {
         if(OpenSell(i))
            g_todayTrades++;
      }
      else if(signal == -1)
      {
         if(OpenBuy(i))
            g_todayTrades++;
      }
   }

   DisplayDashboard("");
}

//+------------------------------------------------------------------+
//| Update H1 trend direction for symbol (same detection as TR3)      |
//+------------------------------------------------------------------+
void UpdateTrend(int idx)
{
   double h1Fast[2], h1Slow[2];

   if(CopyBuffer(g_symbols[idx].hH1EMAFast, 0, 0, 2, h1Fast) != 2) return;
   if(CopyBuffer(g_symbols[idx].hH1EMASlow, 0, 0, 2, h1Slow) != 2) return;

   ArraySetAsSeries(h1Fast, true);
   ArraySetAsSeries(h1Slow, true);

   if(h1Fast[1] > h1Slow[1])
      g_symbols[idx].trendDir = 1;
   else if(h1Fast[1] < h1Slow[1])
      g_symbols[idx].trendDir = -1;
   else
      g_symbols[idx].trendDir = 0;
}

//+------------------------------------------------------------------+
//| Check M15 pullback entry (same detection as TR3)                  |
//| Returns: 1=TR3 would buy, -1=TR3 would sell                      |
//| MainLogic inverts these before opening trades                     |
//+------------------------------------------------------------------+
int CheckEntry(int idx)
{
   if(g_symbols[idx].trendDir == 0) return 0;

   double m15EMA[3], rsi[2], atr[2];

   if(CopyBuffer(g_symbols[idx].hM15EMA, 0, 0, 3, m15EMA) != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hRSI,    0, 0, 2, rsi)    != 2) return 0;
   if(CopyBuffer(g_symbols[idx].hATR,    0, 0, 2, atr)    != 2) return 0;

   ArraySetAsSeries(m15EMA, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   string sym = g_symbols[idx].name;
   double close1 = iClose(sym, PERIOD_M15, 1);
   double close2 = iClose(sym, PERIOD_M15, 2);
   double open1  = iOpen(sym, PERIOD_M15, 1);
   double low2   = iLow(sym, PERIOD_M15, 2);
   double high2  = iHigh(sym, PERIOD_M15, 2);
   if(close1 == 0 || close2 == 0 || open1 == 0) return 0;

   if(atr[1] < g_symbols[idx].pipSize * 1) return 0;

   // Same conditions as TR3 — MainLogic flips the action
   if(g_symbols[idx].trendDir == 1)
   {
      bool pulledBack  = (low2 <= m15EMA[2] + atr[1] * 0.3);
      bool bounced     = (close1 > m15EMA[1] && close1 > open1);
      bool rsiOK       = (rsi[1] > 35 && rsi[1] < 70);

      if(pulledBack && bounced && rsiOK)
         return 1;
   }

   if(g_symbols[idx].trendDir == -1)
   {
      bool pulledBack  = (high2 >= m15EMA[2] - atr[1] * 0.3);
      bool rejected    = (close1 < m15EMA[1] && close1 < open1);
      bool rsiOK       = (rsi[1] > 30 && rsi[1] < 65);

      if(pulledBack && rejected && rsiOK)
         return -1;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Open Buy (called when TR3 would sell)                             |
//+------------------------------------------------------------------+
bool OpenBuy(int idx)
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
   if(lots <= 0) return false;

   double marginReq = 0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, sym, lots, ask, marginReq)) return false;
   if(marginReq > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) return false;

   g_trade.SetTypeFilling(GetFillingType(sym));

   if(g_trade.Buy(lots, sym, ask, sl, tp, StringFormat("TR4_BUY_%s", sym)))
   {
      g_symbols[idx].lastEntryTime = TimeCurrent();
      PrintFormat("[TRADE] INV BUY %s | Lots:%.2f | Entry:%.*f | SL:%.*f | TP:%.*f",
                  sym, lots, digits, ask, digits, sl, digits, tp);
      if(InpAlerts) Alert(StringFormat("TR4 BUY %s | Lots:%.2f", sym, lots));
      if(InpPushNotify) SendNotification(StringFormat("TR4 BUY %s %.2f", sym, lots));
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Open Sell (called when TR3 would buy)                             |
//+------------------------------------------------------------------+
bool OpenSell(int idx)
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
   if(lots <= 0) return false;

   double marginReq = 0;
   if(!OrderCalcMargin(ORDER_TYPE_SELL, sym, lots, bid, marginReq)) return false;
   if(marginReq > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) return false;

   g_trade.SetTypeFilling(GetFillingType(sym));

   if(g_trade.Sell(lots, sym, bid, sl, tp, StringFormat("TR4_SELL_%s", sym)))
   {
      g_symbols[idx].lastEntryTime = TimeCurrent();
      PrintFormat("[TRADE] INV SELL %s | Lots:%.2f | Entry:%.*f | SL:%.*f | TP:%.*f",
                  sym, lots, digits, bid, digits, sl, digits, tp);
      if(InpAlerts) Alert(StringFormat("TR4 SELL %s | Lots:%.2f", sym, lots));
      if(InpPushNotify) SendNotification(StringFormat("TR4 SELL %s %.2f", sym, lots));
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Trailing stop management (inverted trend reversal close)          |
//+------------------------------------------------------------------+
void TrailPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      string sym       = PositionGetString(POSITION_SYMBOL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      long   posType   = PositionGetInteger(POSITION_TYPE);
      int    digits    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double point     = SymbolInfoDouble(sym, SYMBOL_POINT);

      int idx = GetSymbolIndex(sym);
      if(idx < 0) continue;

      // INVERTED: we bought in downtrend, close if trend flips to down again (moved against us)
      // We sold in uptrend, close if trend flips to up again (moved against us)
      if((posType == POSITION_TYPE_BUY && g_symbols[idx].trendDir == 1) ||
         (posType == POSITION_TYPE_SELL && g_symbols[idx].trendDir == -1))
      {
         g_trade.SetTypeFilling(GetFillingType(sym));
         if(g_trade.PositionClose(ticket))
            PrintFormat("[EXIT] Trend confirmed close %s", sym);
         continue;
      }

      double atr[];
      if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atr) != 2) continue;
      ArraySetAsSeries(atr, true);
      double atrVal = atr[1];

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
               g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }
         else if(profitDist >= InpBE_ATR * atrVal)
         {
            double beSL = NormalizeDouble(openPrice + 2 * point, digits);
            if(beSL > currentSL + point)
            {
               g_trade.SetTypeFilling(GetFillingType(sym));
               g_trade.PositionModify(ticket, beSL, PositionGetDouble(POSITION_TP));
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
               g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }
         else if(profitDist >= InpBE_ATR * atrVal)
         {
            double beSL = NormalizeDouble(openPrice - 2 * point, digits);
            if(beSL < currentSL - point || currentSL == 0)
            {
               g_trade.SetTypeFilling(GetFillingType(sym));
               g_trade.PositionModify(ticket, beSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Lot size from risk % and SL distance                              |
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
//| Cooldown check                                                    |
//+------------------------------------------------------------------+
bool CheckCooldown(int idx)
{
   if(InpCooldownBars <= 0) return true;
   if(g_symbols[idx].lastEntryTime == 0) return true;

   int barsSince = Bars(g_symbols[idx].name, PERIOD_M15,
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
//| New M15 bar detection per symbol                                  |
//+------------------------------------------------------------------+
bool IsNewBar(int idx)
{
   datetime t = iTime(g_symbols[idx].name, PERIOD_M15, 0);
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
//| Dashboard                                                         |
//+------------------------------------------------------------------+
void DisplayDashboard(string extra)
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyPL = equity - g_dayStartBalance;
   int    trades  = CountOpenTrades();

   string dash = "\n";
   dash += "==== TREND RIDER 4 (INVERSE) ====\n";
   dash += StringFormat("Balance : %.2f AUD\n", balance);
   dash += StringFormat("Equity  : %.2f AUD\n", equity);
   dash += StringFormat("Daily PL: %+.2f AUD (%.1f%%)\n", dailyPL,
           g_dayStartBalance > 0 ? (dailyPL / g_dayStartBalance) * 100.0 : 0);
   dash += StringFormat("Open    : %d / %d\n", trades, InpMaxTrades);
   dash += StringFormat("Today   : %d trades\n", g_todayTrades);
   dash += StringFormat("Risk    : %.1f%% | TP:%.1f SL:%.1f ATR\n",
           InpRiskPercent, InpTP_ATR, InpSL_ATR);
   dash += StringFormat("Session : %s\n", IsSessionActive() ? "ACTIVE" : "CLOSED");

   int posCount = 0;
   string posList = "";
   for(int i = 0; i < g_numSymbols; i++)
   {
      string tDir = "---";
      if(g_symbols[i].trendDir == 1) tDir = "UP";
      else if(g_symbols[i].trendDir == -1) tDir = "DN";

      if(HasPosition(g_symbols[i].name))
      {
         if(posCount > 0) posList += ", ";
         posList += g_symbols[i].name + "(" + tDir + ")";
         posCount++;
      }
   }
   if(posCount > 0)
      dash += "Active  : " + posList + "\n";

   if(extra != "")
      dash += "\n>> " + extra + "\n";

   dash += "=================================";

   Comment(dash);
}
//+------------------------------------------------------------------+
