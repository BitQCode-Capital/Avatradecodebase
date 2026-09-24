//+------------------------------------------------------------------+
//|                                    SB_XT341v0HO680m_BOTH_fixed   |
//|                                                                  |
//|  Combined LONG + SHORT MT5 EA based on the MultiCharts signal    |
//|  "SB_XT341v0HO680m" / "RangeExpansionV1.1".                      |
//|                                                                  |
//|  Long rule:  Condition1 = Range < Average(Range, Length*len_L)   |
//|              Buy Next Bar at Highest(High,Length) stop           |
//|                                                                  |
//|  Short rule: Condition2 = Range > Average(Range, Length*len_S)   |
//|              Sell Short Next Bar at Lowest(Low,Length) stop      |
//|                                                                  |
//|  This combined version allows long and/or short trading through  |
//|  inputs, but keeps ONLY ONE live position at a time for this EA  |
//|  (same symbol + same magic).                                     |
//|                                                                  |
//|  It also includes the broker-safe SL/TP checks and the           |
//|  non-loosening trailing-stop logic from the fixed variants.      |
//+------------------------------------------------------------------+
#property copyright "MC -> MT5 port (combined long+short)"
#property version   "1.03"
#property strict
#property description "Combined long+short SB_XT341v0HO680m with symbol-wide one-entry protection."

#include <Trade\Trade.mqh>

input group             "=== The PowerLanguage inputs (same names, same defaults) ==="
input int      Length               = 3;       // Length
input int      ShareOrPosition      = 1;       // 1 = per share/contract, 2 = per position
input double   ProfitTargetAmtL     = 2100;    // ProfitTargetAmtL (0 = none)
input double   StopLossAmtL         = 650;     // StopLossAmtL (0 = none)
input double   BreakevenFloorAmt    = 0;       // BreakevenFloorAmt (unused by the original)
input double   DollarTrailingAmt    = 0;       // DollarTrailingAmt (unused by the original)
input double   PctTrailingFloorAmtL = 650;     // trailing activates after this profit per contract
input double   PctTrailingPctL      = 20;      // give back this % of peak profit
input bool     ExitOnClose          = false;   // ExitOnClose
input double   len_L                = 1.8;     // len_L
input double   len_S                = 1.65;    // len_S

input group             "=== Direction control ==="
input bool     EnableLong           = true;    // trade long entries
input bool     EnableShort          = true;    // trade short entries

input group             "=== Trading ==="
input double   InpLots              = 1.0;     // contracts / lots per entry
input long     InpMagic             = 74104;   // magic number for this EA
input int      InpSlippagePoints    = 20;      // max deviation, points

input group             "=== MultiCharts semantics ==="
input int      InpTimeShiftMin      = 0;       // server -> exchange time shift, minutes
input int      InpSessionGapMin     = 0;       // 0 = auto: max(4 x timeframe, 15) minutes

CTrade   trade;
datetime g_lastBar  = 0;
double   g_mfePrice = 0.0;
double   g_entry    = 0.0;

// Internal stop-entry state. No broker pending orders are used.
bool     g_entryArmed   = false;
int      g_entryDir     = 0;      // +1 long, -1 short
double   g_triggerPrice = 0.0;
datetime g_signalBar    = 0;

// Terminal-wide atomic entry lock. This protects against two copies of the EA
// (or two charts/timeframes) submitting the same entry on the same symbol/bar.
string EntryLockName()
  {
   return StringFormat("SBXT341_ENTRY_%s", _Symbol);
  }

bool AcquireEntryLock(const datetime barTime)
  {
   string key = EntryLockName();

   // Ensure the terminal global variable exists.
   if(!GlobalVariableCheck(key))
      GlobalVariableSet(key, 0.0);

   // If this bar was already claimed by another EA instance, do not submit.
   double cur = GlobalVariableGet(key);
   if((datetime)cur == barTime)
      return false;

   // Atomically change the old value to this bar time. Only one instance can win.
   if(!GlobalVariableSetOnCondition(key, (double)barTime, cur))
      return false;

   return true;
  }

void ReleaseEntryLock(const datetime barTime)
  {
   string key = EntryLockName();
   if(!GlobalVariableCheck(key))
      return;
   double cur = GlobalVariableGet(key);
   if((datetime)cur == barTime)
      GlobalVariableSet(key, 0.0);
  }

//+------------------------------------------------------------------+
double TickSize()  { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); }
double TickValue() { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); }
double StopsLevel(){ return SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point; }

//--- money per contract -> price distance, rounded UP to a whole tick the way
//--- MultiCharts does (mc2py engine.py _bracket_offset, away_from_entry)
double MoneyToPrice(const double amount)
  {
   double ts = TickSize(), tv = TickValue();
   if(amount <= 0.0 || ts <= 0.0 || tv <= 0.0)
      return 0.0;
   double perPrice = tv / ts;
   double dist     = amount / perPrice;
   double eps      = 0.0125;
   return MathCeil(dist / ts - eps) * ts;
  }

datetime BarCloseTime(const int shift)
  {
   return iTime(_Symbol, _Period, shift) + PeriodSeconds() + InpTimeShiftMin * 60;
  }

bool SessionChanged(const int shift)
  {
   if(iTime(_Symbol, _Period, shift + 1) <= 0)
      return true;
   datetime a = BarCloseTime(shift), b = BarCloseTime(shift + 1);
   MqlDateTime da, db;
   TimeToStruct(a, da);
   TimeToStruct(b, db);
   if(da.day != db.day || da.mon != db.mon || da.year != db.year)
      return true;
   int limit = InpSessionGapMin > 0 ? InpSessionGapMin
               : (int)MathMax(4 * PeriodSeconds() / 60, 15);
   return (int)((a - b) / 60) > limit;
  }

bool SelectOurPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(!PositionSelectByTicket(tk))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
     }
   return false;
  }

int PositionCountOurEA()
  {
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(!PositionSelectByTicket(tk))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         cnt++;
     }
   return cnt;
  }


//--- true if ANY position already exists on this symbol, regardless of magic.
bool AnyPositionOnSymbol()
  {
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(!PositionSelectByTicket(tk))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
     }
   return false;
  }

//--- true if this EA already has a pending order on this symbol.
bool HasOurPendingOrder()
  {
   for(int i = OrdersTotal() - 1; i >= 0; --i)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0 || !OrderSelect(tk))
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == InpMagic)
         return true;
     }
   return false;
  }

//--- true if ANY pending order exists on this symbol, regardless of magic.
//--- This prevents different EA copies/versions from stacking entries.
bool AnyPendingOrderOnSymbol()
  {
   for(int i = OrdersTotal() - 1; i >= 0; --i)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0 || !OrderSelect(tk))
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol)
         return true;
     }
   return false;
  }

int MarketPosition()
  {
   if(!SelectOurPosition())
      return 0;
   return PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1;
  }

void CancelPendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0 || !OrderSelect(tk))
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == InpMagic)
         trade.OrderDelete(tk);
     }
  }

//--- Average(Range, n) with n truncated, over the n bars ending at `shift`
double AvgRange(const int shift, const double rawLen)
  {
   int n = (int)rawLen;
   if(n < 1)
      return 0.0;
   double s = 0.0;
   for(int k = n - 1; k >= 0; k--)
      s += iHigh(_Symbol, _Period, shift + k) - iLow(_Symbol, _Period, shift + k);
   return s * (1.0 / n);
  }

double LowestLow(const int shift, const int n)
  {
   double lo = iLow(_Symbol, _Period, shift);
   for(int k = 1; k < n; k++)
      lo = MathMin(lo, iLow(_Symbol, _Period, shift + k));
   return lo;
  }

double HighestHigh(const int shift, const int n)
  {
   double hi = iHigh(_Symbol, _Period, shift);
   for(int k = 1; k < n; k++)
      hi = MathMax(hi, iHigh(_Symbol, _Period, shift + k));
   return hi;
  }

void ManagePosition(const int s)
  {
   int mp = MarketPosition();
   if(mp == 0 || !SelectOurPosition())
     {
      g_entry = 0.0;
      g_mfePrice = 0.0;
      return;
     }

   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   if(entry != g_entry)
     {
      g_entry = entry;
      g_mfePrice = entry;
     }

   // Track best price from the bar that just closed.
   if(mp < 0)
      g_mfePrice = MathMin(g_mfePrice, iLow(_Symbol, _Period, s));
   else
      g_mfePrice = MathMax(g_mfePrice, iHigh(_Symbol, _Period, s));

   double slDist = MoneyToPrice(StopLossAmtL);
   double tpDist = MoneyToPrice(ProfitTargetAmtL);
   double sl = 0.0, tp = 0.0;

   if(mp < 0)
     {
      if(slDist > 0.0)
         sl = entry + slDist;
      if(tpDist > 0.0)
         tp = entry - tpDist;

      double armDist = MoneyToPrice(PctTrailingFloorAmtL);
      if(armDist > 0.0 && PctTrailingPctL > 0.0)
        {
         double gain = entry - g_mfePrice;
         if(gain >= armDist)
           {
            double give  = MathCeil((gain * PctTrailingPctL / 100.0) / TickSize() - 0.0125) * TickSize();
            double trail = g_mfePrice + give;
            if(sl <= 0.0 || trail < sl)
               sl = trail;
           }
        }
     }
   else
     {
      if(slDist > 0.0)
         sl = entry - slDist;
      if(tpDist > 0.0)
         tp = entry + tpDist;

      double armDist = MoneyToPrice(PctTrailingFloorAmtL);
      if(armDist > 0.0 && PctTrailingPctL > 0.0)
        {
         double gain = g_mfePrice - entry;
         if(gain >= armDist)
           {
            double give  = MathCeil((gain * PctTrailingPctL / 100.0) / TickSize() - 0.0125) * TickSize();
            double trail = g_mfePrice - give;
            if(sl <= 0.0 || trail > sl)
               sl = trail;
           }
        }
     }

   double tick       = TickSize();
   double stopsDist  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double freezeDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;
   double minDist    = MathMax(stopsDist, freezeDist);

   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double oldSL = PositionGetDouble(POSITION_SL);
   double oldTP = PositionGetDouble(POSITION_TP);

   if(mp < 0)
     {
      if(oldSL > 0.0 && sl > oldSL)
         sl = oldSL;

      if(sl > 0.0)
        {
         double minSL = ask + minDist;
         if(sl < minSL)
            sl = MathCeil((minSL / tick) - 1e-12) * tick;
        }

      if(tp > 0.0)
        {
         double maxTP = ask - minDist;
         if(tp > maxTP)
            tp = MathFloor((maxTP / tick) + 1e-12) * tick;
        }
     }
   else
     {
      if(oldSL > 0.0 && sl < oldSL)
         sl = oldSL;

      if(sl > 0.0)
        {
         double maxSL = bid - minDist;
         if(sl > maxSL)
            sl = MathFloor((maxSL / tick) + 1e-12) * tick;
        }

      if(tp > 0.0)
        {
         double minTP = bid + minDist;
         if(tp < minTP)
            tp = MathCeil((minTP / tick) - 1e-12) * tick;
        }
     }

   sl = sl > 0.0 ? NormalizeDouble(sl, _Digits) : 0.0;
   tp = tp > 0.0 ? NormalizeDouble(tp, _Digits) : 0.0;

   if(MathAbs(oldSL - sl) > tick / 2 ||
      MathAbs(oldTP - tp) > tick / 2)
     {
      if(!trade.PositionModify(_Symbol, sl, tp))
         PrintFormat("Modify failed | ret=%u %s | bid=%.*f ask=%.*f oldSL=%.*f newSL=%.*f oldTP=%.*f newTP=%.*f stops=%.5f freeze=%.5f",
                     trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                     _Digits, bid, _Digits, ask,
                     _Digits, oldSL, _Digits, sl,
                     _Digits, oldTP, _Digits, tp,
                     stopsDist, freezeDist);
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(Length < 1)
     {
      Print("Length must be at least 1");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(!EnableLong && !EnableShort)
     {
      Print("At least one of EnableLong / EnableShort must be true.");
      return INIT_PARAMETERS_INCORRECT;
     }

   // Create the shared entry-lock variable once for this symbol/magic.
   string lockName = EntryLockName();
   if(!GlobalVariableCheck(lockName))
      GlobalVariableSet(lockName, 0.0);

   PrintFormat("SB_XT341 BOTH on %s %s | long=%s short=%s | INTERNAL one-shot trigger; no broker pending entries | avg lengths %d / %d | target %.0f stop %.0f trail floor %.0f / giveback %.1f%% per contract",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
               EnableLong ? "on" : "off", EnableShort ? "on" : "off",
               (int)(Length * len_L), (int)(Length * len_S),
               ProfitTargetAmtL, StopLossAmtL, PctTrailingFloorAmtL, PctTrailingPctL);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   int need = (int)MathMax(Length, MathMax(Length * len_L, Length * len_S)) + 3;
   if(Bars(_Symbol, _Period) < need)
      return;

   //===============================================================
   // 1) ACTIVE POSITION MANAGEMENT -- EVERY TICK
   //===============================================================
   int mp_now = MarketPosition();
   if(mp_now != 0)
     {
      // Once a position exists, any internal entry trigger is dead.
      g_entryArmed = false;
      g_entryDir = 0;
      g_triggerPrice = 0.0;

      if(!SelectOurPosition())
         return;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      if(entry != g_entry)
        {
         g_entry = entry;
         g_mfePrice = entry;
        }

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(mp_now > 0)
         g_mfePrice = MathMax(g_mfePrice, bid);
      else
         g_mfePrice = MathMin(g_mfePrice, ask);

      double slDist = MoneyToPrice(StopLossAmtL);
      double tpDist = MoneyToPrice(ProfitTargetAmtL);
      double sl = 0.0, tp = 0.0;

      if(mp_now < 0)
        {
         if(slDist > 0.0) sl = entry + slDist;
         if(tpDist > 0.0) tp = entry - tpDist;

         double armDist = MoneyToPrice(PctTrailingFloorAmtL);
         if(armDist > 0.0 && PctTrailingPctL > 0.0)
           {
            double gain = entry - g_mfePrice;
            if(gain >= armDist)
              {
               double give  = MathCeil((gain * PctTrailingPctL / 100.0) / TickSize() - 0.0125) * TickSize();
               double trail = g_mfePrice + give;
               if(sl <= 0.0 || trail < sl) sl = trail;
              }
           }
        }
      else
        {
         if(slDist > 0.0) sl = entry - slDist;
         if(tpDist > 0.0) tp = entry + tpDist;

         double armDist = MoneyToPrice(PctTrailingFloorAmtL);
         if(armDist > 0.0 && PctTrailingPctL > 0.0)
           {
            double gain = g_mfePrice - entry;
            if(gain >= armDist)
              {
               double give  = MathCeil((gain * PctTrailingPctL / 100.0) / TickSize() - 0.0125) * TickSize();
               double trail = g_mfePrice - give;
               if(sl <= 0.0 || trail > sl) sl = trail;
              }
           }
        }

      double tick       = TickSize();
      double stopsDist  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      double freezeDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;
      double minDist    = MathMax(stopsDist, freezeDist);
      double oldSL      = PositionGetDouble(POSITION_SL);
      double oldTP      = PositionGetDouble(POSITION_TP);

      if(mp_now < 0)
        {
         if(oldSL > 0.0 && sl > oldSL) sl = oldSL;
         if(sl > 0.0)
           {
            double minSL = ask + minDist;
            if(sl < minSL) sl = MathCeil((minSL / tick) - 1e-12) * tick;
           }
         if(tp > 0.0)
           {
            double maxTP = ask - minDist;
            if(tp > maxTP) tp = MathFloor((maxTP / tick) + 1e-12) * tick;
           }
        }
      else
        {
         if(oldSL > 0.0 && sl < oldSL) sl = oldSL;
         if(sl > 0.0)
           {
            double maxSL = bid - minDist;
            if(sl > maxSL) sl = MathFloor((maxSL / tick) + 1e-12) * tick;
           }
         if(tp > 0.0)
           {
            double minTP = bid + minDist;
            if(tp < minTP) tp = MathCeil((minTP / tick) - 1e-12) * tick;
           }
        }

      sl = sl > 0.0 ? NormalizeDouble(sl, _Digits) : 0.0;
      tp = tp > 0.0 ? NormalizeDouble(tp, _Digits) : 0.0;

      if(MathAbs(oldSL - sl) > tick / 2 || MathAbs(oldTP - tp) > tick / 2)
        {
         if(!trade.PositionModify(_Symbol, sl, tp))
            PrintFormat("Modify failed | ret=%u %s | oldSL=%.*f newSL=%.*f oldTP=%.*f newTP=%.*f",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                        _Digits, oldSL, _Digits, sl, _Digits, oldTP, _Digits, tp);
        }

      return;  // ABSOLUTELY NO ENTRY WORK WHILE A POSITION EXISTS
     }
   else
     {
      g_entry = 0.0;
      g_mfePrice = 0.0;
     }

   //===============================================================
   // 2) FIRE AN ALREADY-ARMED ENTRY -- EVERY TICK
   //===============================================================
   // Symbol-wide rule: any position or any broker pending order blocks us.
   if(g_entryArmed && !AnyPositionOnSymbol() && !AnyPendingOrderOnSymbol())
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      bool fire = (g_entryDir > 0 && ask >= g_triggerPrice) ||
                  (g_entryDir < 0 && bid <= g_triggerPrice);

      if(fire)
        {
         // Disarm BEFORE sending. This makes the submission one-shot even if
         // another tick arrives immediately after the trade request.
         int dir = g_entryDir;
         double trigger = g_triggerPrice;
         g_entryArmed = false;
         g_entryDir = 0;
         g_triggerPrice = 0.0;

         bool ok = false;
         if(dir > 0)
            ok = trade.Buy(InpLots, _Symbol, 0.0, 0.0, 0.0, "SB_XT341 LE");
         else
            ok = trade.Sell(InpLots, _Symbol, 0.0, 0.0, 0.0, "SB_XT341 SE");

         if(ok)
            PrintFormat("ONE-SHOT entry fired | dir=%s volume=%.2f trigger=%.*f order=%I64u deal=%I64u",
                        dir > 0 ? "LONG" : "SHORT", InpLots, _Digits, trigger,
                        trade.ResultOrder(), trade.ResultDeal());
         else
            PrintFormat("Entry failed | dir=%s ret=%u %s",
                        dir > 0 ? "LONG" : "SHORT",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());

         return;
        }
     }

   //===============================================================
   // 3) BUILD A NEW SIGNAL -- ONLY ON A NEW CANDLE
   //===============================================================
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == g_lastBar)
      return;
   g_lastBar = t0;

   const int s = 1;

   // The previous bar's internal trigger expires here if it never fired.
   g_entryArmed = false;
   g_entryDir = 0;
   g_triggerPrice = 0.0;
   g_signalBar = t0;

   if(ExitOnClose && SessionChanged(s) && MarketPosition() != 0)
     {
      trade.PositionClose(_Symbol, InpSlippagePoints);
      return;
     }

   if(AnyPositionOnSymbol() || AnyPendingOrderOnSymbol())
      return;

   double rng = iHigh(_Symbol, _Period, s) - iLow(_Symbol, _Period, s);
   bool Condition1 = rng < AvgRange(s, Length * len_L);
   bool Condition2 = rng > AvgRange(s, Length * len_S);
   bool longSignal  = EnableLong  && Condition1;
   bool shortSignal = EnableShort && Condition2;

   if(longSignal && shortSignal)
     {
      Print("Both long and short signals true; no entry armed.");
      return;
     }

   if(longSignal)
     {
      g_entryDir = +1;
      g_triggerPrice = NormalizeDouble(HighestHigh(s, Length), _Digits);
      g_entryArmed = true;
      PrintFormat("Long trigger armed ONCE for this bar at %.*f", _Digits, g_triggerPrice);
     }
   else if(shortSignal)
     {
      g_entryDir = -1;
      g_triggerPrice = NormalizeDouble(LowestLow(s, Length), _Digits);
      g_entryArmed = true;
      PrintFormat("Short trigger armed ONCE for this bar at %.*f", _Digits, g_triggerPrice);
     }
  }
//+------------------------------------------------------------------+
