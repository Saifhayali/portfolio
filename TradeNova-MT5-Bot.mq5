//+------------------------------------------------------------------+
//| TradeNova Ragnarok v6.4 - MT5 Expert Advisor                    |
//| Adapted from TradingView Pine Script                             |
//| Strategy: OB Detection + Heikin Ashi + EMA Trend Filter          |
//+------------------------------------------------------------------+
#property copyright "TradeNova Academy"
#property link      "https://tradenova.academy"
#property version   "6.4"
#property strict
#property description "Automated Trading Bot with Heikin Ashi Analysis"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| ENUM & STRUCTURES                                                |
//+------------------------------------------------------------------+
enum TIMEFRAME_MODE
{
   TF_1M = 1,      // 1 Minute
   TF_5M = 5,      // 5 Minutes
   TF_15M = 15     // 15 Minutes
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input TIMEFRAME_MODE Timeframe = TF_1M;           // Timeframe Mode
input double         FixedProfit = 2.0;           // Fixed Profit in USD
input double         FixedLoss = 3.0;             // Fixed Loss in USD
input double         LotSize = 0.01;              // Lot Size
input int            EMA_Length = 34;             // EMA Length
input int            ADX_Length = 10;             // ADX Length
input int            ADXThreshold = 15;           // ADX Threshold
input bool           UseTrendFilter = true;       // Use Trend Filter
input bool           UseADXFilter = true;         // Use ADX Filter
input int            WaitBars = 1;                // Wait Bars After Signal
input bool           ShowDashboard = true;        // Show Dashboard

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade trade;

int g_digits = 0;
double g_point = 0;
int g_handle_ema = INVALID_HANDLE;
int g_handle_adx = INVALID_HANDLE;
ENUM_TIMEFRAMES g_chart_tf;

// Statistics
int g_total_trades = 0;
int g_winning_trades = 0;
int g_losing_trades = 0;
double g_total_profit = 0.0;
double g_daily_profit = 0.0;
double g_monthly_profit = 0.0;
double g_max_drawdown = 0.0;
double g_peak_equity = 0.0;
int g_last_reset_day = 0;
int g_last_reset_month = 0;

// Signal tracking
datetime g_last_signal_time = 0;

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set trading object parameters
   trade.SetExpertMagicNumber(202405);
   trade.SetDeviationInPoints(10);
   
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // Convert timeframe
   g_chart_tf = ConvertTimeframe(Timeframe);
   
   // Create indicators
   g_handle_ema = iMA(_Symbol, g_chart_tf, EMA_Length, 0, MODE_EMA, PRICE_CLOSE);
   if (g_handle_ema == INVALID_HANDLE)
   {
      Print("Failed to create EMA indicator");
      return INIT_FAILED;
   }
   
   g_handle_adx = iADX(_Symbol, g_chart_tf, ADX_Length);
   if (g_handle_adx == INVALID_HANDLE)
   {
      Print("Failed to create ADX indicator");
      return INIT_FAILED;
   }
   
   // Initialize day and month
   datetime current_time = TimeCurrent();
   g_last_reset_day = (int)TimeDay(current_time);
   g_last_reset_month = (int)TimeMonth(current_time);
   
   Print("TradeNova Ragnarok v6.4 initialized successfully");
   Print("Timeframe: ", GetTimeframeString(Timeframe));
   Print("Fixed Profit: $", DoubleToString(FixedProfit, 2));
   Print("Fixed Loss: $", DoubleToString(FixedLoss, 2));
   Print("Lot Size: ", DoubleToString(LotSize, 4));
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if (g_handle_ema != INVALID_HANDLE)
      IndicatorRelease(g_handle_ema);
   if (g_handle_adx != INVALID_HANDLE)
      IndicatorRelease(g_handle_adx);
      
   Print("TradeNova Expert Advisor stopped");
}

//+------------------------------------------------------------------+
//| EXPERT ON TICK                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   static datetime last_bar_time = 0;
   
   // Execute only on new bar
   datetime bar_time = iTime(_Symbol, g_chart_tf, 0);
   if (bar_time == last_bar_time)
      return;
   
   last_bar_time = bar_time;
   
   // Update statistics
   UpdateStatistics();
   
   // Check for active trades
   CheckActiveTradesForTP_SL();
   
   // Get technical indicators
   double ema_value = GetEMAValue();
   double adx_value = GetADXValue();
   bool is_trending = !UseADXFilter || adx_value > ADXThreshold;
   
   // Get Heikin Ashi data
   HeikinAshiData ha_data = GetHeikinAshiData();
   
   // Trading logic
   if (is_trending)
   {
      // Check for BUY signal
      if (ha_data.is_bullish_reversal && CheckBuyConditions(ema_value))
      {
         ExecuteBuySignal(ema_value);
      }
      
      // Check for SELL signal
      if (ha_data.is_bearish_reversal && CheckSellConditions(ema_value))
      {
         ExecuteSellSignal(ema_value);
      }
   }
   
   // Draw dashboard
   if (ShowDashboard)
      DrawDashboard(ema_value, adx_value);
}

//+------------------------------------------------------------------+
//| CHECK ACTIVE TRADES FOR TP/SL                                    |
//+------------------------------------------------------------------+
void CheckActiveTradesForTP_SL()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0)
         continue;
      
      if (PositionGetInteger(POSITION_MAGIC) != 202405)
         continue;
      
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double current_price = (bid + ask) / 2.0;
      
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double volume = PositionGetDouble(POSITION_VOLUME);
      
      // Check if TP or SL is hit
      if (type == POSITION_TYPE_BUY)
      {
         double pnl = (current_price - entry_price) * volume * 100000;
         
         if (pnl >= FixedProfit)
         {
            trade.PositionClose(ticket);
            g_total_trades++;
            g_winning_trades++;
            g_total_profit += FixedProfit;
            g_daily_profit += FixedProfit;
            g_monthly_profit += FixedProfit;
            Print("BUY TP HIT: +$", DoubleToString(FixedProfit, 2));
         }
         else if (pnl <= -FixedLoss)
         {
            trade.PositionClose(ticket);
            g_total_trades++;
            g_losing_trades++;
            g_total_profit -= FixedLoss;
            g_daily_profit -= FixedLoss;
            g_monthly_profit -= FixedLoss;
            Print("BUY SL HIT: -$", DoubleToString(FixedLoss, 2));
         }
      }
      else if (type == POSITION_TYPE_SELL)
      {
         double pnl = (entry_price - current_price) * volume * 100000;
         
         if (pnl >= FixedProfit)
         {
            trade.PositionClose(ticket);
            g_total_trades++;
            g_winning_trades++;
            g_total_profit += FixedProfit;
            g_daily_profit += FixedProfit;
            g_monthly_profit += FixedProfit;
            Print("SELL TP HIT: +$", DoubleToString(FixedProfit, 2));
         }
         else if (pnl <= -FixedLoss)
         {
            trade.PositionClose(ticket);
            g_total_trades++;
            g_losing_trades++;
            g_total_profit -= FixedLoss;
            g_daily_profit -= FixedLoss;
            g_monthly_profit -= FixedLoss;
            Print("SELL SL HIT: -$", DoubleToString(FixedLoss, 2));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| EXECUTE BUY SIGNAL                                               |
//+------------------------------------------------------------------+
void ExecuteBuySignal(double ema_value)
{
   // Check if already in trade
   if (HasOpenPosition())
      return;
   
   // Check wait bars
   datetime current_time = iTime(_Symbol, g_chart_tf, 0);
   int wait_seconds = WaitBars * PeriodSeconds(g_chart_tf);
   
   if ((int)(current_time - g_last_signal_time) < wait_seconds)
      return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // Calculate TP and SL based on fixed profit/loss
   double sl_price = ask - CalculateSLPips();
   double tp_price = ask + CalculateTPPips();
   
   // Place BUY order
   if (trade.Buy(LotSize, _Symbol, ask, sl_price, tp_price, "BUY Signal"))
   {
      g_last_signal_time = current_time;
      Print("BUY Signal executed at ", DoubleToString(ask, g_digits), 
            " SL: ", DoubleToString(sl_price, g_digits), 
            " TP: ", DoubleToString(tp_price, g_digits));
   }
}

//+------------------------------------------------------------------+
//| EXECUTE SELL SIGNAL                                              |
//+------------------------------------------------------------------+
void ExecuteSellSignal(double ema_value)
{
   // Check if already in trade
   if (HasOpenPosition())
      return;
   
   // Check wait bars
   datetime current_time = iTime(_Symbol, g_chart_tf, 0);
   int wait_seconds = WaitBars * PeriodSeconds(g_chart_tf);
   
   if ((int)(current_time - g_last_signal_time) < wait_seconds)
      return;
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Calculate TP and SL based on fixed profit/loss
   double sl_price = bid + CalculateSLPips();
   double tp_price = bid - CalculateTPPips();
   
   // Place SELL order
   if (trade.Sell(LotSize, _Symbol, bid, sl_price, tp_price, "SELL Signal"))
   {
      g_last_signal_time = current_time;
      Print("SELL Signal executed at ", DoubleToString(bid, g_digits), 
            " SL: ", DoubleToString(sl_price, g_digits), 
            " TP: ", DoubleToString(tp_price, g_digits));
   }
}

//+------------------------------------------------------------------+
//| HEIKIN ASHI DATA STRUCTURE                                       |
//+------------------------------------------------------------------+
struct HeikinAshiData
{
   double open;
   double high;
   double low;
   double close;
   bool is_bullish_reversal;
   bool is_bearish_reversal;
};

//+------------------------------------------------------------------+
//| GET HEIKIN ASHI DATA                                              |
//+------------------------------------------------------------------+
HeikinAshiData GetHeikinAshiData()
{
   HeikinAshiData ha;
   ha.is_bullish_reversal = false;
   ha.is_bearish_reversal = false;
   
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if (CopyRates(_Symbol, g_chart_tf, 0, 3, rates) < 3)
   {
      return ha;
   }
   
   // Current bar HA
   double ha_close_curr = (rates[0].open + rates[0].high + rates[0].low + rates[0].close) / 4.0;
   double ha_open_curr = (rates[1].open + rates[1].close) / 2.0;
   double ha_high_curr = MathMax(rates[0].high, MathMax(ha_open_curr, ha_close_curr));
   double ha_low_curr = MathMin(rates[0].low, MathMin(ha_open_curr, ha_close_curr));
   
   ha.open = ha_open_curr;
   ha.close = ha_close_curr;
   ha.high = ha_high_curr;
   ha.low = ha_low_curr;
   
   // Bullish reversal: close > open AND close > high[1]
   ha.is_bullish_reversal = (ha_close_curr > ha_open_curr) && (ha_close_curr > rates[1].high);
   
   // Bearish reversal: close < open AND close < low[1]
   ha.is_bearish_reversal = (ha_close_curr < ha_open_curr) && (ha_close_curr < rates[1].low);
   
   return ha;
}

//+------------------------------------------------------------------+
//| CHECK BUY CONDITIONS                                              |
//+------------------------------------------------------------------+
bool CheckBuyConditions(double ema_value)
{
   if (UseTrendFilter)
   {
      double close = iClose(_Symbol, g_chart_tf, 0);
      if (close < ema_value)
         return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| CHECK SELL CONDITIONS                                             |
//+------------------------------------------------------------------+
bool CheckSellConditions(double ema_value)
{
   if (UseTrendFilter)
   {
      double close = iClose(_Symbol, g_chart_tf, 0);
      if (close > ema_value)
         return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| CALCULATE SL PIPS FROM FIXED LOSS                                |
//+------------------------------------------------------------------+
double CalculateSLPips()
{
   // Convert fixed loss in USD to pips
   double pips = (FixedLoss / (LotSize * 100000)) / g_point;
   return pips * g_point;
}

//+------------------------------------------------------------------+
//| CALCULATE TP PIPS FROM FIXED PROFIT                              |
//+------------------------------------------------------------------+
double CalculateTPPips()
{
   // Convert fixed profit in USD to pips
   double pips = (FixedProfit / (LotSize * 100000)) / g_point;
   return pips * g_point;
}

//+------------------------------------------------------------------+
//| GET EMA VALUE                                                     |
//+------------------------------------------------------------------+
double GetEMAValue()
{
   double ema_values[];
   ArraySetAsSeries(ema_values, true);
   
   if (CopyBuffer(g_handle_ema, 0, 0, 1, ema_values) < 1)
      return 0;
   
   return ema_values[0];
}

//+------------------------------------------------------------------+
//| GET ADX VALUE                                                     |
//+------------------------------------------------------------------+
double GetADXValue()
{
   double adx_values[];
   ArraySetAsSeries(adx_values, true);
   
   if (CopyBuffer(g_handle_adx, 0, 0, 1, adx_values) < 1)
      return 0;
   
   return adx_values[0];
}

//+------------------------------------------------------------------+
//| CHECK IF HAS OPEN POSITION                                        |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0)
         continue;
      
      if (PositionGetInteger(POSITION_MAGIC) == 202405 &&
          PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| CONVERT TIMEFRAME                                                 |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES ConvertTimeframe(TIMEFRAME_MODE mode)
{
   switch (mode)
   {
      case TF_1M:
         return PERIOD_M1;
      case TF_5M:
         return PERIOD_M5;
      case TF_15M:
         return PERIOD_M15;
      default:
         return PERIOD_M1;
   }
}

//+------------------------------------------------------------------+
//| GET TIMEFRAME STRING                                              |
//+------------------------------------------------------------------+
string GetTimeframeString(TIMEFRAME_MODE mode)
{
   switch (mode)
   {
      case TF_1M:
         return "1M";
      case TF_5M:
         return "5M";
      case TF_15M:
         return "15M";
      default:
         return "1M";
   }
}

//+------------------------------------------------------------------+
//| UPDATE STATISTICS                                                 |
//+------------------------------------------------------------------+
void UpdateStatistics()
{
   // Get current time
   datetime now = TimeCurrent();
   int current_day = (int)TimeDay(now);
   int current_month = (int)TimeMonth(now);
   
   // Reset daily stats
   if (current_day != g_last_reset_day)
   {
      g_daily_profit = 0.0;
      g_last_reset_day = current_day;
   }
   
   // Reset monthly stats
   if (current_month != g_last_reset_month)
   {
      g_monthly_profit = 0.0;
      g_last_reset_month = current_month;
   }
   
   // Update peak equity and max drawdown
   double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if (current_equity > g_peak_equity)
      g_peak_equity = current_equity;
   
   double current_dd = g_peak_equity - current_equity;
   if (current_dd > g_max_drawdown)
      g_max_drawdown = current_dd;
}

//+------------------------------------------------------------------+
//| DRAW DASHBOARD                                                    |
//+------------------------------------------------------------------+
void DrawDashboard(double ema_value, double adx_value)
{
   // Update only on last bar
   static datetime last_dashboard_update = 0;
   datetime current_bar_time = iTime(_Symbol, g_chart_tf, 0);
   
   if (current_bar_time == last_dashboard_update)
      return;
   
   last_dashboard_update = current_bar_time;
   
   // Calculate win rate
   float win_rate = g_total_trades > 0 ? (float)g_winning_trades / g_total_trades * 100 : 0;
   
   // Build dashboard text
   string dashboard_text = "\n╔════════════════════════════╗\n";
   dashboard_text += "║  ◈ RAGNAROK v6.4 MT5      ║\n";
   dashboard_text += "╠════════════════════════════╣\n";
   dashboard_text += "║ Win Rate: " + DoubleToString(win_rate, 1) + " %\n";
   dashboard_text += "║ Total Trades: " + IntegerToString(g_total_trades) + "\n";
   dashboard_text += "║ Wins: " + IntegerToString(g_winning_trades) + " | Losses: " + IntegerToString(g_losing_trades) + "\n";
   dashboard_text += "║ Daily P&L: $" + DoubleToString(g_daily_profit, 2) + "\n";
   dashboard_text += "║ Monthly P&L: $" + DoubleToString(g_monthly_profit, 2) + "\n";
   dashboard_text += "║ Total P&L: $" + DoubleToString(g_total_profit, 2) + "\n";
   dashboard_text += "║ Max Drawdown: $" + DoubleToString(g_max_drawdown, 2) + "\n";
   
   bool is_bullish = iClose(_Symbol, g_chart_tf, 0) > ema_value;
   string trend = is_bullish ? "▲ BULLISH" : "▼ BEARISH";
   dashboard_text += "║ Trend: " + trend + "\n";
   
   dashboard_text += "║ ADX: " + DoubleToString(adx_value, 2) + "\n";
   dashboard_text += "║ Timeframe: " + GetTimeframeString(Timeframe) + "\n";
   dashboard_text += "║ Profit Target: $" + DoubleToString(FixedProfit, 2) + "\n";
   dashboard_text += "║ Loss Limit: $" + DoubleToString(FixedLoss, 2) + "\n";
   dashboard_text += "╚════════════════════════════╝\n";
   
   Print(dashboard_text);
}

//+------------------------------------------------------------------+
// END OF EXPERT ADVISOR
//+------------------------------------------------------------------+
```

```

