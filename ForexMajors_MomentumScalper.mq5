//+------------------------------------------------------------------+
//|                         ForexMajors_MomentumScalper.mq5          |
//|                         Intraday EMA + RSI Momentum Strategy     |
//|                         Capital: 900 AUD | Risk: 2% per trade    |
//+------------------------------------------------------------------+
#property copyright "Momentum Scalper EA"
#property version   "1.00"
#property description "Intraday momentum scalper for Forex pairs."
#property description "EMA crossover + RSI confirmation + ATR risk mgmt."
#property description "Scans majors, minors, and exotics from a single chart."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Strategy ==="
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_M15;   // Trading Timeframe
input int    InpEMAFast                = 8;             // Fast EMA Period
input int    InpEMASlow                = 21;            // Slow EMA Period
input int    InpEMATrend               = 50;            // Trend Filter EMA Period
input int    InpRSIPeriod              = 14;            // RSI Period
input int    InpATRPeriod              = 14;            // ATR Period
input double InpRSILongLower           = 40.0;          // RSI Min for Longs
input double InpRSILongUpper           = 70.0;          // RSI Max for Longs
input double InpRSIShortLower          = 30.0;          // RSI Min for Shorts
input double InpRSIShortUpper          = 60.0;          // RSI Max for Shorts

input group "=== Risk Management ==="
input double InpRiskPercent            = 2.0;           // Risk % per Trade
input double InpSL_ATR                 = 1.5;           // Stop Loss = x * ATR
input double InpTP_ATR                 = 3.75;          // Take Profit = x * ATR (R:R 1:2.5)
input double InpBE_ATR                 = 1.5;           // Move SL to Breakeven at x*ATR profit
input double InpTrailTrigger_ATR       = 2.5;           // Start Trailing at x * ATR profit
input double InpTrailDist_ATR          = 1.0;           // Trail Distance = x * ATR
input int    InpMaxTrades              = 5;             // Max Concurrent Trades
input double InpMaxLot                 = 0.10;          // Max Lot Size (safety cap)
input double InpMaxDailyLossPct        = 5.0;           // Daily Loss Limit %
input int    InpMaxHoldBars            = 48;            // Max Hold Duration (bars, 0=off)

input group "=== Session Filter (GMT) ==="
input int    InpSessionStart           = 7;             // Session Start Hour (GMT)
input int    InpSessionEnd             = 20;            // Session End Hour (GMT)
input int    InpLocalGMTOffset         = 10;            // Your Local GMT Offset (Melbourne=10)

input group "=== Symbols ==="
input string InpSuffix                 = "";            // Broker Symbol Suffix (e.g. ".raw", "m")
input double InpMaxSpreadPips          = 8.0;           // Max Spread (pips)

input group "=== General ==="
input long   InpMagic                  = 547823;        // Magic Number
input bool   InpAlerts                 = true;          // Enable Alerts
input bool   InpPushNotify             = false;         // Enable Push Notifications

//+------------------------------------------------------------------+
//| Per-symbol data structure                                         |
//+------------------------------------------------------------------+
struct SSymbolData
{
   string   name;
   int      hEMAFast;
   int      hEMASlow;
   int      hEMATrend;
   int      hRSI;
   int      hATR;
   datetime lastBarTime;
   double   pipSize;
   bool     active;
};

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
SSymbolData g_symbols[];
int         g_numSymbols    = 0;
CTrade      g_trade;
double      g_dayStartBalance = 0;
datetime    g_lastDay       = 0;

string BASE_SYMBOLS[] =
{
   // === MAJORS ===
   "EURUSD","GBPUSD","USDJPY","USDCHF","AUDUSD","NZDUSD","USDCAD",
   // === MINORS (Crosses) ===
   "EURGBP","EURJPY","EURCHF","EURAUD","EURNZD","EURCAD",
   "GBPJPY","GBPCHF","GBPAUD","GBPNZD","GBPCAD",
   "AUDJPY","AUDNZD","AUDCAD","AUDCHF",
   "NZDJPY","NZDCAD","NZDCHF",
   "CADJPY","CADCHF","CHFJPY",
   // === EXOTICS ===
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
         PrintFormat("[INIT] Symbol %s not available, skipping", sym);
         continue;
      }

      int idx = g_numSymbols;
      g_symbols[idx].name        = sym;
      g_symbols[idx].lastBarTime = 0;
      g_symbols[idx].active      = true;

      // Pip size: 5-digit pairs use 10*point, 3-digit (JPY) use 10*point too
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(digits == 3 || digits == 5)
         g_symbols[idx].pipSize = 10.0 * SymbolInfoDouble(sym, SYMBOL_POINT);
      else
         g_symbols[idx].pipSize = SymbolInfoDouble(sym, SYMBOL_POINT);

      // Create indicator handles for this symbol
      g_symbols[idx].hEMAFast  = iMA(sym, InpTimeframe, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hEMASlow  = iMA(sym, InpTimeframe, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hEMATrend = iMA(sym, InpTimeframe, InpEMATrend, 0, MODE_EMA, PRICE_CLOSE);
      g_symbols[idx].hRSI      = iRSI(sym, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
      g_symbols[idx].hATR      = iATR(sym, InpTimeframe, InpATRPeriod);

      if(g_symbols[idx].hEMAFast  == INVALID_HANDLE ||
         g_symbols[idx].hEMASlow  == INVALID_HANDLE ||
         g_symbols[idx].hEMATrend == INVALID_HANDLE ||
         g_symbols[idx].hRSI      == INVALID_HANDLE ||
         g_symbols[idx].hATR      == INVALID_HANDLE)
      {
         PrintFormat("[INIT] Failed to create indicators for %s, error %d", sym, GetLastError());
         g_symbols[idx].active = false;
      }

      g_numSymbols++;
   }

   if(g_numSymbols == 0)
   {
      Alert("No valid symbols found! Check your broker suffix setting.");
      return INIT_FAILED;
   }

   ArrayResize(g_symbols, g_numSymbols);

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_lastDay = iTime(_Symbol, PERIOD_D1, 0);

   EventSetTimer(5);

   PrintFormat("[INIT] EA started: %d symbols active, Magic=%d, Risk=%.1f%%",
               g_numSymbols, InpMagic, InpRiskPercent);
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
      if(g_symbols[i].hEMASlow  != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hEMASlow);
      if(g_symbols[i].hEMATrend != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hEMATrend);
      if(g_symbols[i].hRSI      != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hRSI);
      if(g_symbols[i].hATR      != INVALID_HANDLE) IndicatorRelease(g_symbols[i].hATR);
   }

   Comment("");
}

//+------------------------------------------------------------------+
//| Timer - periodic scan of all symbols                              |
//+------------------------------------------------------------------+
void OnTimer()
{
   MainLogic();
}

//+------------------------------------------------------------------+
//| Tick - responsive processing for chart symbol                     |
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

   // Daily balance reset
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != g_lastDay)
   {
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_lastDay = today;
   }

   // Circuit breaker: daily loss limit
   if(CheckDailyLossExceeded())
   {
      DisplayDashboard("!! DAILY LOSS LIMIT - TRADING PAUSED !!");
      return;
   }

   // Manage existing positions (trailing stop, breakeven, time exit)
   ManagePositions();

   // Scan for new entries
   int openCount = CountOpenTrades();

   for(int i = 0; i < g_numSymbols; i++)
   {
      if(!g_symbols[i].active) continue;

      // Only evaluate on new bar close (avoids re-checking every tick)
      if(!IsNewBar(i)) continue;

      // Log indicator snapshot for this pair on every new bar
      LogBarCheck(i);

      if(openCount >= InpMaxTrades) continue;

      // One position per symbol
      if(HasPosition(g_symbols[i].name)) continue;

      // Session filter
      if(!IsSessionActive()) continue;

      // Spread filter
      if(GetSpreadPips(i) > InpMaxSpreadPips) continue;

      // Check entry signal
      int signal = CheckSignal(i);

      if(signal == 1)
      {
         if(OpenBuy(i)) openCount++;
      }
      else if(signal == -1)
      {
         if(OpenSell(i)) openCount++;
      }
   }

   DisplayDashboard("");
}

//+------------------------------------------------------------------+
//| Check entry signal: 1=Buy, -1=Sell, 0=None                       |
//+------------------------------------------------------------------+
int CheckSignal(int idx)
{
   double emaFast[3], emaSlow[3], emaTrend[3], rsi[3], atr[3];

   // Copy 3 most recent bars
   if(CopyBuffer(g_symbols[idx].hEMAFast,  0, 0, 3, emaFast)  != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hEMASlow,  0, 0, 3, emaSlow)  != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hEMATrend, 0, 0, 3, emaTrend) != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hRSI,      0, 0, 3, rsi)      != 3) return 0;
   if(CopyBuffer(g_symbols[idx].hATR,      0, 0, 3, atr)      != 3) return 0;

   // Set as series so [0]=newest, [1]=prev closed, [2]=two bars ago
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(emaTrend, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   // Skip if ATR is too low (dead market)
   if(atr[1] < g_symbols[idx].pipSize * 3) return 0;

   // Last closed bar's close price
   double close1 = iClose(g_symbols[idx].name, InpTimeframe, 1);
   if(close1 == 0) return 0;

   // === BULLISH CROSSOVER on bar[1] ===
   // Bar[2]: fast below slow  ->  Bar[1]: fast above slow
   if(emaFast[2] < emaSlow[2] && emaFast[1] >= emaSlow[1])
   {
      // Trend filter: price above the 50 EMA
      if(close1 > emaTrend[1])
      {
         // RSI momentum confirmation
         if(rsi[1] >= InpRSILongLower && rsi[1] <= InpRSILongUpper)
         {
            return 1;
         }
      }
   }

   // === BEARISH CROSSOVER on bar[1] ===
   if(emaFast[2] > emaSlow[2] && emaFast[1] <= emaSlow[1])
   {
      if(close1 < emaTrend[1])
      {
         if(rsi[1] >= InpRSIShortLower && rsi[1] <= InpRSIShortUpper)
         {
            return -1;
         }
      }
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Open Buy trade                                                    |
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

   g_trade.SetTypeFilling(GetFillingType(sym));

   if(g_trade.Buy(lots, sym, ask, sl, tp, StringFormat("MomScalp BUY %s", sym)))
   {
      PrintFormat("[TRADE] BUY %s | Lots: %.2f | Entry: %.*f | SL: %.*f | TP: %.*f | ATR: %.*f",
                  sym, lots, digits, ask, digits, sl, digits, tp, digits, atrVal);
      if(InpAlerts)
         Alert(StringFormat("BUY %s | Lots: %.2f | SL: %.*f | TP: %.*f",
               sym, lots, digits, sl, digits, tp));
      if(InpPushNotify)
         SendNotification(StringFormat("BUY %s @ %.*f | Lots: %.2f", sym, digits, ask, lots));
      return true;
   }
   else
   {
      PrintFormat("[ERROR] Buy failed %s: %d - %s",
                  sym, GetLastError(), g_trade.ResultRetcodeDescription());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Open Sell trade                                                   |
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

   g_trade.SetTypeFilling(GetFillingType(sym));

   if(g_trade.Sell(lots, sym, bid, sl, tp, StringFormat("MomScalp SELL %s", sym)))
   {
      PrintFormat("[TRADE] SELL %s | Lots: %.2f | Entry: %.*f | SL: %.*f | TP: %.*f | ATR: %.*f",
                  sym, lots, digits, bid, digits, sl, digits, tp, digits, atrVal);
      if(InpAlerts)
         Alert(StringFormat("SELL %s | Lots: %.2f | SL: %.*f | TP: %.*f",
               sym, lots, digits, sl, digits, tp));
      if(InpPushNotify)
         SendNotification(StringFormat("SELL %s @ %.*f | Lots: %.2f", sym, digits, bid, lots));
      return true;
   }
   else
   {
      PrintFormat("[ERROR] Sell failed %s: %d - %s",
                  sym, GetLastError(), g_trade.ResultRetcodeDescription());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Dynamic lot size based on risk % and ATR stop loss                |
//+------------------------------------------------------------------+
double CalculateLotSize(string sym, double sl_distance)
{
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;

   double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);

   if(tickVal <= 0 || tickSize <= 0 || sl_distance <= 0)
      return 0;

   double slTicks    = sl_distance / tickSize;
   double riskPerLot = slTicks * tickVal;

   if(riskPerLot <= 0) return 0;

   double lots = riskMoney / riskPerLot;

   // Clamp to broker and safety limits
   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = MathMin(lots, InpMaxLot);   // hard safety cap

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Manage open positions: trailing stop, breakeven, time exit        |
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

      // Get current ATR value
      double atr[];
      if(CopyBuffer(g_symbols[idx].hATR, 0, 0, 2, atr) != 2) continue;
      ArraySetAsSeries(atr, true);
      double atrVal = atr[1];

      // --- TIME-BASED EXIT ---
      if(InpMaxHoldBars > 0)
      {
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         int barsHeld = Bars(sym, InpTimeframe, openTime, TimeCurrent());

         if(barsHeld >= InpMaxHoldBars)
         {
            g_trade.SetTypeFilling(GetFillingType(sym));
            if(g_trade.PositionClose(ticket))
            {
               PrintFormat("[EXIT] Time exit %s after %d bars", sym, barsHeld);
               if(InpAlerts) Alert(StringFormat("TIME EXIT %s after %d bars", sym, barsHeld));
            }
            continue;
         }
      }

      // --- TRAILING STOP & BREAKEVEN ---
      double currentPrice, profitDist;

      if(posType == POSITION_TYPE_BUY)
      {
         currentPrice = SymbolInfoDouble(sym, SYMBOL_BID);
         profitDist   = currentPrice - openPrice;

         // Phase 2: Full trailing stop
         if(profitDist >= InpTrailTrigger_ATR * atrVal)
         {
            double newSL = NormalizeDouble(currentPrice - InpTrailDist_ATR * atrVal, digits);
            if(newSL > currentSL + point)
            {
               g_trade.SetTypeFilling(GetFillingType(sym));
               g_trade.PositionModify(ticket, newSL, currentTP);
            }
         }
         // Phase 1: Move to breakeven
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

         // Phase 2: Full trailing stop
         if(profitDist >= InpTrailTrigger_ATR * atrVal)
         {
            double newSL = NormalizeDouble(currentPrice + InpTrailDist_ATR * atrVal, digits);
            if(newSL < currentSL - point || currentSL == 0)
            {
               g_trade.SetTypeFilling(GetFillingType(sym));
               g_trade.PositionModify(ticket, newSL, currentTP);
            }
         }
         // Phase 1: Move to breakeven
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
//| Session filter (GMT hours)                                        |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeLocal(dt);
   // Convert local time to GMT: subtract offset, wrap around 24h
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
//| Count open trades with our magic number                           |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check if we already hold a position on this symbol                |
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
//| Find symbol index in our array                                    |
//+------------------------------------------------------------------+
int GetSymbolIndex(string sym)
{
   for(int i = 0; i < g_numSymbols; i++)
      if(g_symbols[i].name == sym) return i;
   return -1;
}

//+------------------------------------------------------------------+
//| Get spread in pips for a symbol                                   |
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
//| Check if daily loss limit is exceeded                             |
//+------------------------------------------------------------------+
bool CheckDailyLossExceeded()
{
   if(g_dayStartBalance <= 0) return false;
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dayStartBalance - equity) / g_dayStartBalance * 100.0;
   return (lossPct >= InpMaxDailyLossPct);
}

//+------------------------------------------------------------------+
//| Get the appropriate order filling type for a symbol               |
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
//| Log indicator snapshot on every 15-min bar check                  |
//+------------------------------------------------------------------+
void LogBarCheck(int idx)
{
   string sym = g_symbols[idx].name;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double emaFast[3], emaSlow[3], emaTrend[3], rsi[3], atr[3];

   if(CopyBuffer(g_symbols[idx].hEMAFast,  0, 0, 3, emaFast)  != 3) return;
   if(CopyBuffer(g_symbols[idx].hEMASlow,  0, 0, 3, emaSlow)  != 3) return;
   if(CopyBuffer(g_symbols[idx].hEMATrend, 0, 0, 3, emaTrend) != 3) return;
   if(CopyBuffer(g_symbols[idx].hRSI,      0, 0, 3, rsi)      != 3) return;
   if(CopyBuffer(g_symbols[idx].hATR,      0, 0, 3, atr)      != 3) return;

   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(emaTrend, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   double close1  = iClose(sym, InpTimeframe, 1);
   double bid     = SymbolInfoDouble(sym, SYMBOL_BID);
   double spread  = GetSpreadPips(idx);
   bool   hasPos  = HasPosition(sym);
   bool   session = IsSessionActive();

   // Determine signal status
   string signalStr = "NONE";
   bool bullCross = (emaFast[2] < emaSlow[2] && emaFast[1] >= emaSlow[1]);
   bool bearCross = (emaFast[2] > emaSlow[2] && emaFast[1] <= emaSlow[1]);

   if(bullCross && close1 > emaTrend[1] && rsi[1] >= InpRSILongLower && rsi[1] <= InpRSILongUpper)
      signalStr = ">> BUY SIGNAL <<";
   else if(bearCross && close1 < emaTrend[1] && rsi[1] >= InpRSIShortLower && rsi[1] <= InpRSIShortUpper)
      signalStr = ">> SELL SIGNAL <<";
   else if(bullCross)
      signalStr = "Bull cross (filtered)";
   else if(bearCross)
      signalStr = "Bear cross (filtered)";

   // Trend direction
   string trend = (close1 > emaTrend[1]) ? "UP" : "DOWN";

   PrintFormat("[SCAN] %s | Bid:%.*f | EMA8:%.*f EMA21:%.*f EMA50:%.*f | RSI:%.1f | ATR:%.*f | Spread:%.1f | Trend:%s | Pos:%s | Sess:%s | %s",
      sym,
      digits, bid,
      digits, emaFast[1],
      digits, emaSlow[1],
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
//| On-chart dashboard                                                |
//+------------------------------------------------------------------+
void DisplayDashboard(string extra)
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyPL = equity - g_dayStartBalance;
   int    trades  = CountOpenTrades();

   string dash = "\n";
   dash += "=== FOREX MOMENTUM SCALPER ===\n";
   dash += StringFormat("Balance : %.2f AUD\n", balance);
   dash += StringFormat("Equity  : %.2f AUD\n", equity);
   dash += StringFormat("Daily PL: %+.2f AUD (%.1f%%)\n", dailyPL,
           g_dayStartBalance > 0 ? (dailyPL / g_dayStartBalance) * 100.0 : 0);
   dash += StringFormat("Trades  : %d / %d\n", trades, InpMaxTrades);
   dash += StringFormat("Risk    : %.1f%% per trade\n", InpRiskPercent);
   dash += StringFormat("Session : %s\n", IsSessionActive() ? "ACTIVE" : "CLOSED");
   dash += "Pairs   : ";

   for(int i = 0; i < g_numSymbols; i++)
   {
      if(i > 0) dash += ", ";
      dash += g_symbols[i].name;
      if(HasPosition(g_symbols[i].name)) dash += " [*]";
   }
   dash += "\n";

   if(extra != "")
      dash += "\n>> " + extra + "\n";

   dash += "=====================================";

   Comment(dash);
}
//+------------------------------------------------------------------+
