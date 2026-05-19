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
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| ENUM & STRUCTURES                                                |
//+------------------------------------------------------------------+
enum TIMEFRAME_MODE
{
   TF_1M = 1,      // 1 Minute
   TF_5M = 5,      // 5 Minutes
   TF_15M = 15     // 15 Minutes
};

struct TradeRecord
{
   double entry_price;
   double sl_price;
   double tp_price;
   int direction;    // 1 = BUY, -1 = SELL
   ulong ticket;
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
input bool           ShowWatermark = true;        // Show Watermark

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade trade;
CSymbolInfo symbol_info;

int digits = 0;
double point = 0;
int handle_ema = INVALID_HANDLE;
int handle_adx = INVALID_HANDLE;
int handle_ha = INVALID_HANDLE;

ENUM_TIMEFRAMES chart_tf;
TradeRecord current_trade;

// Statistics
int total_trades = 0;
int winning_trades = 0;
int losing_trades = 0;
double total_profit = 0.0;
double daily_profit = 0.0;
double monthly_profit = 0.0;
double max_drawdown = 0.0;
double peak_equity = 0.0;
datetime last_reset_day;
datetime last_reset_month;

// Signal tracking
int last_signal_bar = 0;
bool pending_signal = false;
int pending_direction = 0;

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set trading object parameters
   trade.SetExpertMagicNumber(202405);
   trade.SetDeviationInPoints(10);
   
   // Get symbol info
   if (!symbol_info.Name(_Symbol))
   {
      Print("Failed to get symbol info");
      return INIT_FAILED;
   }
   
   digits = _Digits;
   point = _Point;
   
   // Convert timeframe
   chart_tf = ConvertTimeframe(Timeframe);
   
   // Create indicators
   handle_ema = iMA(_Symbol, chart_tf, EMA_Length, 0, MODE_EMA, PRICE_CLOSE);
   if (handle_ema == INVALID_HANDLE)
   {
      Print("Failed to create EMA indicator");
      return INIT_FAILED;
   }
   
   handle_adx = iADX(_Symbol, chart_tf, ADX_Length);
   if (handle_adx == INVALID_HANDLE)
   {
      Print("Failed to create ADX indicator");
      return INIT_FAILED;
   }
   
   // Heikin Ashi setup will be done in OnTick
   
   Print("TradeNova Ragnarok v6.4 initialized successfully");
   Print("Timeframe: ", GetTimeframeString(Timeframe));
   Print("Fixed Profit: $", FixedProfit);
   Print("Fixed Loss: $", FixedLoss);
   Print("Lot Size: ", LotSize);
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if (handle_ema != INVALID_HANDLE)
      IndicatorRelease(handle_ema);
   if (handle_adx != INVALID_HANDLE)
      IndicatorRelease(handle_adx);
      
   Print("TradeNova Expert Advisor stopped");
}

//+------------------------------------------------------------------+
//| EXPERT ON TICK                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   static datetime last_bar_time = 0;
   
   // Execute only on new bar
   if (iTime(_Symbol, chart_tf, 0) == last_bar_time)
      return;
   
   last_bar_time = iTime(_Symbol, chart_tf, 0);
   
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
   
   if (ShowWatermark)
      DrawWatermark();
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
      
      if (PositionGetInteger(POSITION_MAGIC) != trade.Magic())
         continue;
      
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double current_price = (bid + ask) / 2;
      
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      
      // Calculate P&L
      double pnl = 0;
      if (type == POSITION_TYPE_BUY)
      {
         pnl = (current_price - PositionGetDouble(POSITION_PRICE_OPEN)) * PositionGetDouble(POSITION_VOLUME) * 100000;
      }
      else
      {
         pnl = (PositionGetDouble(POSITION_PRICE_OPEN) - current_price) * PositionGetDouble(POSITION_VOLUME) * 100000;
      }
      
      // Check if TP or SL is hit
      if (type == POSITION_TYPE_BUY && current_price >= tp)
      {
         trade.PositionClose(ticket);
         total_trades++;
         winning_trades++;
         total_profit += FixedProfit;
         daily_profit += FixedProfit;
         monthly_profit += FixedProfit;
         Print("BUY TP HIT: +$", FixedProfit);
      }
      else if (type == POSITION_TYPE_SELL && current_price <= tp)
      {
         trade.PositionClose(ticket);
         total_trades++;
         winning_trades++;
         total_profit += FixedProfit;
         daily_profit += FixedProfit;
         monthly_profit += FixedProfit;
         Print("SELL TP HIT: +$", FixedProfit);
      }
      else if (type == POSITION_TYPE_BUY && current_price <= sl)
      {
         trade.PositionClose(ticket);
         total_trades++;
         losing_trades++;
         total_profit -= FixedLoss;
         daily_profit -= FixedLoss;
         monthly_profit -= FixedLoss;
         Print("BUY SL HIT: -$", FixedLoss);
      }
      else if (type == POSITION_TYPE_SELL && current_price >= sl)
      {
         trade.PositionClose(ticket);
         total_trades++;
         losing_trades++;
         total_profit -= FixedLoss;
         daily_profit -= FixedLoss;
         monthly_profit -= FixedLoss;
         Print("SELL SL HIT: -$", FixedLoss);
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
   if (iTime(_Symbol, chart_tf, 0) - last_signal_bar < (WaitBars * PeriodSeconds(chart_tf)))
      return;
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry_price = ask;
   
   // Calculate TP and SL based on fixed profit/loss
   double sl_price = entry_price - CalculateSLPips();
   double tp_price = entry_price + CalculateTPPips();
   
   // Place BUY order
   if (trade.Buy(LotSize, _Symbol, entry_price, sl_price, tp_price, "BUY Signal"))
   {
      last_signal_bar = iTime(_Symbol, chart_tf, 0);
      Print("BUY Signal executed at ", entry_price, " SL: ", sl_price, " TP: ", tp_price);
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
   if (iTime(_Symbol, chart_tf, 0) - last_signal_bar < (WaitBars * PeriodSeconds(chart_tf)))
      return;
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry_price = bid;
   
   // Calculate TP and SL based on fixed profit/loss
   double sl_price = entry_price + CalculateSLPips();
   double tp_price = entry_price - CalculateTPPips();
   
   // Place SELL order
   if (trade.Sell(LotSize, _Symbol, entry_price, sl_price, tp_price, "SELL Signal"))
   {
      last_signal_bar = iTime(_Symbol, chart_tf, 0);
      Print("SELL Signal executed at ", entry_price, " SL: ", sl_price, " TP: ", tp_price);
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
   
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if (CopyRates(_Symbol, chart_tf, 0, 2, rates) < 2)
   {
      ha.is_bullish_reversal = false;
      ha.is_bearish_reversal = false;
      return ha;
   }
   
   // Current bar
   double ha_close_curr = (rates[0].open + rates[0].high + rates[0].low + rates[0].close) / 4.0;
   double ha_open_curr = (rates[1].open + rates[1].close) / 2.0;
   double ha_high_curr = MathMax(rates[0].high, MathMax(ha_open_curr, ha_close_curr));
   double ha_low_curr = MathMin(rates[0].low, MathMin(ha_open_curr, ha_close_curr));
   
   // Previous bar
   double ha_close_prev = (rates[1].open + rates[1].high + rates[1].low + rates[1].close) / 4.0;
   double ha_open_prev = (rates[2].open + rates[2].close) / 2.0;
   
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
      double close = iClose(_Symbol, chart_tf, 0);
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
      double close = iClose(_Symbol, chart_tf, 0);
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
   // Formula: pips = (loss_usd / (lot_size * 100000)) * (1 / point)
   
   double pips = (FixedLoss / (LotSize * 100000)) / point;
   return pips * point;
}

//+------------------------------------------------------------------+
//| CALCULATE TP PIPS FROM FIXED PROFIT                              |
//+------------------------------------------------------------------+
double CalculateTPPips()
{
   // Convert fixed profit in USD to pips
   // Formula: pips = (profit_usd / (lot_size * 100000)) * (1 / point)
   
   double pips = (FixedProfit / (LotSize * 100000)) / point;
   return pips * point;
}

//+------------------------------------------------------------------+
//| GET EMA VALUE                                                     |
//+------------------------------------------------------------------+
double GetEMAValue()
{
   double ema_values[];
   ArraySetAsSeries(ema_values, true);
   
   if (CopyBuffer(handle_ema, 0, 0, 1, ema_values) < 1)
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
   
   if (CopyBuffer(handle_adx, 0, 0, 1, adx_values) < 1)
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
      
      if (PositionGetInteger(POSITION_MAGIC) == trade.Magic() &&
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
   // Reset daily stats at 1 AM UTC+3
   datetime now = TimeCurrent();
   
   if (TimeHour(now) >= 1 && (last_reset_day == 0 || TimeDay(last_reset_day) != TimeDay(now)))
   {
      daily_profit = 0.0;
      last_reset_day = now;
   }
   
   // Reset monthly stats on the 1st of each month
   if (TimeDay(now) == 1 && (last_reset_month == 0 || TimeMonth(last_reset_month) != TimeMonth(now)))
   {
      monthly_profit = 0.0;
      last_reset_month = now;
   }
   
   // Update peak equity and max drawdown
   double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if (current_equity > peak_equity)
      peak_equity = current_equity;
   
   double current_dd = peak_equity - current_equity;
   if (current_dd > max_drawdown)
      max_drawdown = current_dd;
}

//+------------------------------------------------------------------+
//| DRAW DASHBOARD                                                    |
//+------------------------------------------------------------------+
void DrawDashboard(double ema_value, double adx_value)
{
   string dashboard_text = "";
   
   dashboard_text += "╔════════════════════════════╗\n";
   dashboard_text += "║  ◈ RAGNAROK v6.4          ║\n";
   dashboard_text += "╠════════════════════════════╣\n";
   
   // Win Rate
   float win_rate = total_trades > 0 ? (float)winning_trades / total_trades * 100 : 0;
   dashboard_text += "║ Win Rate: " + DoubleToString(win_rate, 1) + " %\n";
   
   // Total Trades
   dashboard_text += "║ Total Trades: " + IntegerToString(total_trades) + "\n";
   dashboard_text += "║ Wins: " + IntegerToString(winning_trades) + " | Losses: " + IntegerToString(losing_trades) + "\n";
   
   // Profits
   dashboard_text += "║ Daily P&L: $" + DoubleToString(daily_profit, 2) + "\n";
   dashboard_text += "║ Monthly P&L: $" + DoubleToString(monthly_profit, 2) + "\n";
   dashboard_text += "║ Total P&L: $" + DoubleToString(total_profit, 2) + "\n";
   
   // Risk Management
   dashboard_text += "║ Max Drawdown: $" + DoubleToString(max_drawdown, 2) + "\n";
   
   // Trend
   bool is_bullish = iClose(_Symbol, chart_tf, 0) > ema_value;
   string trend = is_bullish ? "▲ BULLISH" : "▼ BEARISH";
   dashboard_text += "║ Trend: " + trend + "\n";
   
   // ADX
   dashboard_text += "║ ADX: " + DoubleToString(adx_value, 2) + "\n";
   
   dashboard_text += "║ Timeframe: " + GetTimeframeString(Timeframe) + "\n";
   dashboard_text += "║ Profit Target: $" + DoubleToString(FixedProfit, 2) + "\n";
   dashboard_text += "║ Loss Limit: $" + DoubleToString(FixedLoss, 2) + "\n";
   dashboard_text += "╚════════════════════════════╝\n";
   
   // Print to Journal (visible in MT5 Terminal)
   static datetime last_dashboard_print = 0;
   if (TimeCurrent() - last_dashboard_print > 3600) // Print every hour
   {
      Print(dashboard_text);
      last_dashboard_print = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| DRAW WATERMARK                                                    |
//+------------------------------------------------------------------+
void DrawWatermark()
{
   // This can be extended for chart drawing if needed
   // For now, we just use Print for MT5 Terminal
}

//+------------------------------------------------------------------+
// END OF EXPERT ADVISOR
//+------------------------------------------------------------------+
