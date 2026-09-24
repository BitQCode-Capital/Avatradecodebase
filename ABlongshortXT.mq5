//+------------------------------------------------------------------+
//|                                             XT342v0PL890m.mq5    |
//|                                                                  |
//|  Line-for-line port of the MultiCharts signal "XT342v0PL890m"    |
//|  (PLA_VM_BQC.pla) -- "Intraday range expansion and contraction :  |
//|  RangeExpansionV1.1", Bhavya Arnav, 11.03.2010.                   |
//|                                                                  |
//|  Same family as SB_XT341v0HO680m, and it shares that EA's exit    |
//|  machinery -- but it trades BOTH SIDES and its numbers differ:    |
//|                                                                  |
//|              SB_XT341v0HO680m      XT342v0PL890m                 |
//|    target            2100                1900                    |
//|    stop               650                 850                    |
//|    trail floor        750                 600                    |
//|    len_L              1.8                 1.5   -> Average over 4 |
//|    len_S             1.65                 2     -> Average over 6 |
//|    long entry    commented out        ACTIVE                     |
//|                                                                  |
//|  The study in full:                                              |
//|                                                                  |
//|    Condition1 = Range < Average(Range, Length*len_L);   { 4 }    |
//|    Condition2 = Range > Average(Range, Length*len_S);   { 6 }    |
//|    IF MarketPosition = 0 then begin                              |
//|       if Condition1 then Buy       Next Bar at Highest(High,3) stop;
//|       if Condition2 then Sell Short Next Bar at Lowest(Low,3) stop;
//|    end;                                                          |
//|    SetStopShare / SetProfitTarget / SetStopLoss                  |
//|    SetPercentTrailing( 600, 3 )                                  |
//|                                                                  |
//|  BOTH STOPS CAN BE LIVE AT ONCE.  Condition1 (contraction) and    |
//|  Condition2 (expansion) are measured over different lookbacks, so |
//|  both are true on about 4% of bars -- measured over 49,285 @ES    |
//|  5-minute bars.  MultiCharts then rests a buy stop above and a    |
//|  sell stop below and lets the bar decide.  Whichever fills wins:  |
//|  the other is pulled at once (see the OCO check in OnTick), which |
//|  is what keeps this from opening two positions on one bar --      |
//|  mc2py's 2,079-trade reference has no bar with two entries.       |
//|                                                                  |
//|  WHAT IS DELIBERATELY NOT PORTED                                  |
//|                                                                  |
//|    value80 = mreg( totalup, ... );                                |
//|    value81 = EmpDecomp( C, 20, ... , peak, valley, trend );        |
//|                                                                  |
//|  These two lines are live in the original and drag in 24 further  |
//|  functions (MarketRegime_Daily / _W / _I, MR_VWAP, MR_Channel,    |
//|  EMD_Peaks ...).  Every one of their outputs -- value80, value81, |
//|  and all twelve numericref variables -- is written and then never |
//|  read: each name occurs exactly twice in the source, once in the  |
//|  vars: block and once as a call argument.  They cannot reach an   |
//|  order, so porting them would change nothing but the run time.    |
//|  They do raise MaxBarsBack in MultiCharts, which shifts where the |
//|  strategy starts trading; mc2py pins that with [strategy]         |
//|  max_bars_back = 100.                                             |
//|                                                                  |
//|  Two details that decide whether the numbers match mc2py:        |
//|  * Average() TRUNCATES its length, so Length*len_L = 4.5 averages |
//|    4 bars and Length*len_S = 6.0 averages 6.                      |
//|  * The money-management amounts are PER CONTRACT (SetStopShare),  |
//|    so each becomes a price distance via the contract's own tick   |
//|    value, rounded UP to a whole tick as mc2py does.               |
//+------------------------------------------------------------------+
#property copyright "MC -> MT5 port (mc2py)"
#property version   "1.00"
#property strict
#property description "MultiCharts XT342v0PL890m: range expansion/contraction, both sides, per-contract brackets."

#include <Trade\Trade.mqh>

input group             "=== The PowerLanguage inputs (same names, same defaults) ==="
input int      Length               = 3;       // Length
input int      ShareOrPosition      = 1;       // 1 = per share/contract, 2 = per position
input double   ProfitTargetAmtL     = 1900;    // ProfitTargetAmtL (0 = none)
input double   StopLossAmtL         = 850;     // StopLossAmtL (0 = none)
input double   BreakevenFloorAmt    = 0;       // BreakevenFloorAmt (unused by the original)
input double   DollarTrailingAmt    = 0;       // DollarTrailingAmt (unused by the original)
input double   PctTrailingFloorAmtL = 600;     // PctTrailingFloorAmtL (0 = none)
input double   PctTrailingPctL      = 3;       // PctTrailingPctL, percent
input bool     ExitOnClose          = false;   // ExitOnClose
input double   len_L                = 1.5;     // len_L  (Length*len_L = 4.5 -> Average over 4)
input double   len_S                = 2;       // len_S  (Length*len_S = 6.0 -> Average over 6)

input group             "=== Direction ==="
input bool     EnableLong  = true;    // take Condition1 breakouts (the original does)
input bool     EnableShort = true;    // take Condition2 breakdowns (the original does)

input group             "=== Trading ==="
input double   InpLots            = 1.0;    // contracts / lots per entry
input long     InpMagic           = 74105;  // magic number for this EA
input int      InpSlippagePoints  = 20;     // max deviation, points

input group             "=== Broker stop handling ==="
input int      InpSpreadMult        = 3;     // min stop distance = this x the current spread
input int      InpExtraStopPoints   = 0;     // extra min stop distance, points (broker padding)
input int      InpMinModifyTicks    = 1;     // only re-send a level once it has moved this many ticks
input bool     InpMarketExitOnTouch = true;  // a level already through the market -> close at market
input bool     InpLogStopErrors     = true;  // print why a modify was rejected


input group             "=== Trailing stop ==="
input int      InpTrailMode        = 0;  // 0 = SetPercentTrailing exactly as MultiCharts (default), 1 = lock whole steps of profit
input double   InpTrailGiveBackPct = 10; // mode 1 only: give back this % of each step
input bool     InpTrailFromEntryBar = false; // mode 0 only: does the entry bar arm the trail (mc2py trail_mfe_from_entry_bar)
input bool     InpShowTrailLine     = true;  // draw the exact trail level on the chart

input group             "=== MultiCharts semantics ==="
input int      InpTimeShiftMin    = 0;      // server -> exchange time shift, minutes
input int      InpSessionGapMin   = 0;      // 0 = auto: max(4 x timeframe, 15) minutes
input int      InpSessionStartHHMM = 0;      // 0 = detect sessions from gaps; else a fixed daily start (exchange time)

CTrade   trade;
datetime g_lastBar = 0;
double   g_mfePrice = 0.0;        // best price seen since entry (a low, for a short)
double   g_entry    = 0.0;
double   g_lockedSL = 0.0;        // best stop locked in by the ratchet
datetime g_entryBar = 0;          // bar the position opened on (it does not arm the trail)
double   g_trailSent = 0.0;       // the trail level the broker was last given

//+------------------------------------------------------------------+
double TickSize()   { double t = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
                      return t > 0.0 ? t : _Point; }
double TickValue()  { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); }
double StopsLevel() { return (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL)  * _Point; }
double FreezeLevel(){ return (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point; }
double Spread()     { return SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID); }

//--- How far from the market the broker will actually hold a level.
//--- SYMBOL_TRADE_STOPS_LEVEL is 0 on most futures/CFD feeds, and 0 does NOT
//--- mean "any distance": the server then applies a floating rule off the
//--- current spread, so a modify a few ticks from the market comes back
//--- [Invalid stops] -- exactly the EPZ26/MQOZ26 rejections in the log, where
//--- the trail was tightening into a wide quote.  Take the widest rule we can
//--- see, and let InpExtraStopPoints pad it if a particular broker wants more.
double MinStopDist()
  {
   double d = MathMax(StopsLevel(), FreezeLevel());
   d = MathMax(d, Spread() * InpSpreadMult);
   d = MathMax(d, InpExtraStopPoints * _Point);
   return MathMax(d, TickSize());
  }

//--- snap to a whole tick, away from the market (a clamped level must stay legal)
double ToTick(const double price, const bool up)
  {
   double ts = TickSize();
   double n  = up ? MathCeil(price / ts - 0.0125) : MathFloor(price / ts + 0.0125);
   return NormalizeDouble(n * ts, _Digits);
  }

//--- Send only levels a broker can hold -- without ever giving up protection
//--- to do it.  Three different things go wrong on a live feed:
//---   * the level is on the WRONG side of the market.  MultiCharts would have
//---     filled it on this bar, so close at market instead of arguing.
//---   * the level is on the right side but inside the minimum distance.  Hold
//---     it at the closest level the broker WILL take -- the old code dropped
//---     the stop to 0 here, which traded "Invalid stops" for no stop at all.
//---   * the level is impossible (<= 0).  That is MultiCharts placing an order
//---     the market can never reach, i.e. the same as no order.
//--- `trailOwnsStop` says the caller (ManageTrail) has already decided, against
//--- the same Bid series MultiCharts uses, that the trailing level is NOT yet
//--- hit.  A stop that then looks "through" here is only inside the spread, so
//--- it is parked at the nearest legal price instead of closing the position a
//--- spread early.  The profit target is unaffected either way.
void SafeModify(const int mp, double sl, double tp, const bool trailOwnsStop = false)
  {
   if(!PositionSelect(_Symbol))
      return;
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD  = MinStopDist();
   double frz   = FreezeLevel();
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   bool   through = false, clampSL = false, clampTP = false;

   if(sl < 0.0) sl = 0.0;
   if(tp < 0.0) tp = 0.0;

//--- MT5 triggers BOTH levels of a long from the Bid and both levels of a short
//--- from the Ask -- a short is closed by buying, so its stop and its target are
//--- measured against what it costs to buy.  Using the other side of the quote
//--- puts every target one spread out.
   double px = (mp > 0) ? bid : ask;

   if(mp > 0)                                        // long: stop below, target above
     {
      if(sl > 0.0 && sl > px - minD)                 // nearer than the broker allows
        {
         if(sl >= px && !trailOwnsStop) through = true;
         else { sl = ToTick(px - minD, false); clampSL = true; }
        }
      if(tp > 0.0 && tp < px + minD)
        {
         if(tp <= px) through = true;
         else { tp = ToTick(px + minD, true); clampTP = true; }
        }
     }
   else                                              // short: stop above, target below
     {
      if(sl > 0.0 && sl < px + minD)
        {
         if(sl <= px && !trailOwnsStop) through = true;
         else { sl = ToTick(px + minD, true); clampSL = true; }
        }
      if(tp > 0.0 && tp > px - minD)
        {
         if(tp >= px) through = true;
         else { tp = ToTick(px - minD, false); clampTP = true; }
        }
     }

   if(through)
     {
      if(InpMarketExitOnTouch)
         trade.PositionClose(_Symbol, InpSlippagePoints);
      return;
     }

   //--- pushing a level out to the broker minimum must not undo a tighter one
   //--- that is already working: keep what the position has instead
   if(clampSL && curSL > 0.0 && ((mp > 0 && sl < curSL) || (mp < 0 && sl > curSL)))
      sl = curSL;
   if(clampTP && curTP > 0.0 && ((mp > 0 && tp > curTP) || (mp < 0 && tp < curTP)))
      tp = curTP;

   //--- inside the freeze level the server refuses every change; the level is
   //--- about to trigger anyway, so leave it alone rather than log a rejection
   if(frz > 0.0)
     {
      if(curSL > 0.0 && MathAbs((mp > 0 ? bid : ask) - curSL) < frz) return;
      if(curTP > 0.0 && MathAbs((mp > 0 ? ask : bid) - curTP) < frz) return;
     }

   //--- dead band: a level that has barely moved is not worth a server round trip
   double dead = MathMax(InpMinModifyTicks, 1) * TickSize() - TickSize() * 0.5;
   if(MathAbs(curSL - sl) < dead && MathAbs(curTP - tp) < dead)
      return;
   if(sl == 0.0 && tp == 0.0)
      return;

   if(!trade.PositionModify(_Symbol, sl, tp) && InpLogStopErrors)
      PrintFormat("modify rejected %u (%s) | sl %s tp %s | bid %s ask %s | "
                  "spread %s, stops level %s, freeze %s -> min distance %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                  DoubleToString(sl, _Digits),      DoubleToString(tp, _Digits),
                  DoubleToString(bid, _Digits),     DoubleToString(ask, _Digits),
                  DoubleToString(Spread(), _Digits),
                  DoubleToString(StopsLevel(), _Digits),
                  DoubleToString(FreezeLevel(), _Digits),
                  DoubleToString(minD, _Digits));
  }


//--- money per contract -> price distance, rounded UP to a whole tick the way
//--- MultiCharts does (mc2py engine.py _bracket_offset, away_from_entry)
//--- price distance -> money per contract (the inverse of MoneyToPrice)
double PriceToMoney(const double dist)
  {
   double ts = TickSize(), tv = TickValue();
   if(dist <= 0.0 || ts <= 0.0 || tv <= 0.0)
      return 0.0;
   return dist * (tv / ts);
  }

//--- Lock whole steps of profit, checked on the bar close.  The step is
//--- PctTrailingFloorAmtL -- 750/contract in the original -- and each step
//--- gives back InpTrailGiveBackPct of ITSELF:
//---
//---     P&L at the close >=  750  ->  stop locks  675   ( 750 - 10%)
//---     P&L at the close >= 1500  ->  stop locks 1350   (1500 - 10%)
//---     P&L at the close >= 2250  ->  stop locks 2025   ... until the target
//---
//--- Because the give-back scales with the step, the stop always sits at least
//--- one give-back away from the close that armed it -- 75/contract at the
//--- first step, 150 at the second.  On this contract that is 1.5 and 3.0
//--- points, far outside anything a broker calls too close, so the modify is
//--- accepted and the stop genuinely moves.  That breathing space is the whole
//--- point: SetPercentTrailing gives back 3% of the gain measured from the best
//--- price, which is 2-3 ticks and unplaceable.
//---
//--- Returns the locked profit in money per contract, 0 while unarmed.
double StepLock(const double profitMoney)
  {
   double step = PctTrailingFloorAmtL;
   if(step <= 0.0 || InpTrailGiveBackPct <= 0.0 || profitMoney < step)
      return 0.0;
   double rung = MathFloor(profitMoney / step) * step;
   return rung * (1.0 - InpTrailGiveBackPct / 100.0);
  }

double MoneyToPrice(const double amount)
  {
   double ts = TickSize(), tv = TickValue();
   if(amount <= 0.0 || ts <= 0.0 || tv <= 0.0)
      return 0.0;
   double perPrice = tv / ts;                       // money per 1.0 price unit
   double dist     = amount / perPrice;
   double eps      = 0.0125;                        // engine.py TICK_EPS
   return MathCeil(dist / ts - eps) * ts;
  }

datetime BarCloseTime(const int shift)
  {
   return iTime(_Symbol, _Period, shift) + PeriodSeconds() + InpTimeShiftMin * 60;
  }

bool SessionChanged(const int shift)
  {
   if(iTime(_Symbol, _Period, shift + 1) <= 0)
      return true;                                   // no earlier bar to compare
   datetime a = BarCloseTime(shift), b = BarCloseTime(shift + 1);
   MqlDateTime da, db;
   TimeToStruct(a, da);
   TimeToStruct(b, db);
   //--- a fixed daily session start, for lining this up with the exchange
   //--- session the mc2py data carries (e.g. 1700 for Globex)
   if(InpSessionStartHHMM > 0)
     {
      int ha = da.hour * 100 + da.min, hb = db.hour * 100 + db.min;
      int sa = (ha >= InpSessionStartHHMM) ? 1 : 0;
      int sb = (hb >= InpSessionStartHHMM) ? 1 : 0;
      if(da.day != db.day || da.mon != db.mon || da.year != db.year)
         return !(sa == 0 && sb == 1);               // same session across midnight
      return sa != sb;
     }
   if(da.day != db.day || da.mon != db.mon || da.year != db.year)
      return true;
   int limit = InpSessionGapMin > 0 ? InpSessionGapMin
               : (int)MathMax(4 * PeriodSeconds() / 60, 15);
   return (int)((a - b) / 60) > limit;
  }

int MarketPosition()
  {
   if(!PositionSelect(_Symbol))
      return 0;
   if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
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
   int n = (int)rawLen;                             // int() -- as mc2py does
   if(n < 1)
      return 0.0;
   double s = 0.0;
   for(int k = n - 1; k >= 0; k--)                  // oldest -> newest, as mc2py
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

//--- Both entry stops can be resting at once, and only one of them may fill.
//--- MultiCharts never opens two positions from one bar; MT5 happily would, so
//--- the moment either side fills the other is pulled.  Checked on every tick,
//--- because a bar that sweeps both levels does it in seconds.
void CancelOppositePendings()
  {
   if(MarketPosition() == 0)
      return;
   CancelPendings();
  }

//+------------------------------------------------------------------+
//| The trail level for the current MFE, or 0 while it is not armed.  |
//|                                                                   |
//| SetPercentTrailing is NOT a resting order.  MultiCharts holds the  |
//| level internally, lifts it with every new extreme, and fills when  |
//| the bar reaches it (mc2py engine.py _bracket_phase: trail_prev /   |
//| trail_now against the bar, MFE from the intrabar extreme).  That   |
//| is why the level may legitimately sit two ticks from the market -- |
//| nothing is ever sent to a broker, so nothing can be rejected.      |
//+------------------------------------------------------------------+
double TrailLevel(const int mp, const double entry, const double closePx)
  {
   if(PctTrailingFloorAmtL <= 0.0)
      return 0.0;

   if(InpTrailMode == 1)
     {
      //--- checked on the close, as the step rule asks
      double open_pl = (mp < 0) ? (entry - closePx) : (closePx - entry);
      if(open_pl <= 0.0)
         return 0.0;
      double lock = StepLock(PriceToMoney(open_pl));
      if(lock <= 0.0)
         return 0.0;
      double lockDist = MoneyToPrice(lock);
      return (mp < 0) ? entry - lockDist : entry + lockDist;
     }

   //--- mode 0: SetPercentTrailing exactly as MultiCharts runs it -- once the
   //--- open profit reaches `floor`, give back `pct` of the gain measured from
   //--- the best price, the give-back rounded up to a tick
   double gain = (mp < 0) ? (entry - g_mfePrice) : (g_mfePrice - entry);
   if(gain <= 0.0 || PctTrailingPctL <= 0.0)
      return 0.0;
   double armDist = MoneyToPrice(PctTrailingFloorAmtL);
   if(armDist <= 0.0 || gain < armDist)
      return 0.0;
   double give = ToTick(gain * PctTrailingPctL / 100.0, true);
   return (mp < 0) ? g_mfePrice + give : g_mfePrice - give;
  }

//+------------------------------------------------------------------+
//| Every exit level the position should be carrying, sent in one go. |
//|                                                                   |
//| SetStopLoss (650/contract) and SetProfitTarget (2100) are fixed    |
//| distances from the entry and always placeable.  The trail level is |
//| folded in whenever it is the tighter stop, so it is a REAL resting |
//| order the broker holds -- if it is closer to the market than the   |
//| broker allows, SafeModify parks it at the nearest legal price      |
//| instead of dropping it, and ManageTrail() below still exits at the |
//| exact MultiCharts level, which by then is the tighter of the two.  |
//+------------------------------------------------------------------+
void ApplyExits(const int mp, const double entry, const double closePx)
  {
   double slDist = MoneyToPrice(StopLossAmtL);
   double tpDist = MoneyToPrice(ProfitTargetAmtL);
   double sl = 0.0, tp = 0.0;
   bool   fromTrail = false;

   if(slDist > 0.0)
      sl = (mp < 0) ? entry + slDist : entry - slDist;
   if(tpDist > 0.0)
      tp = (mp < 0) ? entry - tpDist : entry + tpDist;

   double trail = TrailLevel(mp, entry, closePx);
   if(trail > 0.0 && (sl <= 0.0 || (mp < 0 && trail < sl) || (mp > 0 && trail > sl)))
     {
      sl = trail;
      fromTrail = true;
     }
//--- a locked step never gives itself back
   if(sl > 0.0 && g_lockedSL > 0.0)
      sl = (mp < 0) ? MathMin(sl, g_lockedSL) : MathMax(sl, g_lockedSL);
   if(trail > 0.0)
      g_lockedSL = sl;

   SafeModify(mp, sl > 0.0 ? NormalizeDouble(sl, _Digits) : 0.0,
                  tp > 0.0 ? NormalizeDouble(tp, _Digits) : 0.0, fromTrail);
  }

//+------------------------------------------------------------------+
//| Show the EXACT MultiCharts level on the chart.                    |
//|                                                                   |
//| The position's own stop-loss line is also moved (see ApplyExits),  |
//| but when the level is nearer the market than the broker will hold, |
//| what rests there is the nearest legal price -- a few ticks looser  |
//| than the real level.  This line is the real one, and it is the one |
//| that actually takes the trade out.                                 |
//+------------------------------------------------------------------+
void DrawTrail(const double lvl)
  {
   string nm = "XT342_trail";
   if(!InpShowTrailLine || lvl <= 0.0)
     {
      ObjectDelete(0, nm);
      return;
     }
   if(ObjectFind(0, nm) < 0)
     {
      ObjectCreate(0, nm, OBJ_HLINE, 0, 0, lvl);
      ObjectSetInteger(0, nm, OBJPROP_COLOR,      clrOrangeRed);
      ObjectSetInteger(0, nm, OBJPROP_STYLE,      STYLE_DOT);
      ObjectSetInteger(0, nm, OBJPROP_WIDTH,      1);
      ObjectSetInteger(0, nm, OBJPROP_BACK,       true);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
     }
   ObjectSetDouble(0, nm, OBJPROP_PRICE, lvl);
   ObjectSetString(0, nm, OBJPROP_TOOLTIP,
                   "trail level " + DoubleToString(lvl, _Digits));
  }

//+------------------------------------------------------------------+
//| Position bookkeeping, and -- in mode 0 only -- the MultiCharts    |
//| percent trail, which has to be watched tick by tick because its   |
//| level sits 2-3 ticks from the market and no broker will hold it.  |
//| Mode 1 needs none of this: its level is checked on the bar close  |
//| and simply rests at the broker.                                   |
//+------------------------------------------------------------------+
void ManageTrail()
  {
   int mp = MarketPosition();
   if(mp == 0)
     {
      g_entry = 0.0;
      g_mfePrice = 0.0;
      g_lockedSL = 0.0;
      g_entryBar = 0;
      g_trailSent = 0.0;
      DrawTrail(0.0);
      return;
     }

   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   if(entry != g_entry)                              // a new position
     {
      g_entry    = entry;
      g_mfePrice = entry;
      g_lockedSL = 0.0;
      g_trailSent = 0.0;
      datetime pt = (datetime)PositionGetInteger(POSITION_TIME);
      int sh = iBarShift(_Symbol, _Period, pt, false);
      g_entryBar = (sh >= 0) ? iTime(_Symbol, _Period, sh) : 0;
     }

   if(InpTrailMode != 0 || PctTrailingFloorAmtL <= 0.0)
      return;
   //--- MultiCharts does not accumulate MaxPositionProfit on the entry bar
   if(!InpTrailFromEntryBar && g_entryBar > 0 && iTime(_Symbol, _Period, 0) == g_entryBar)
      return;

   double px = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(px <= 0.0)
      return;
   g_mfePrice = (mp < 0) ? MathMin(g_mfePrice, px) : MathMax(g_mfePrice, px);

   double lvl = TrailLevel(mp, entry, px);
   if(lvl <= 0.0)
      return;
   DrawTrail(lvl);

   if((mp < 0 && px >= lvl) || (mp > 0 && px <= lvl))
     {
      if(trade.PositionClose(_Symbol, InpSlippagePoints))
         PrintFormat("trailing stop hit: level %s reached at %s (best %s, entry %s)",
                     DoubleToString(lvl, _Digits), DoubleToString(px, _Digits),
                     DoubleToString(g_mfePrice, _Digits), DoubleToString(entry, _Digits));
      DrawTrail(0.0);
      return;
     }

//--- Move the resting stop when the LEVEL has moved -- not when the quote has.
//--- A level inside the broker's minimum is placed at the nearest legal price,
//--- which is derived from the ask; without this guard every tick that made a
//--- new ask low would re-send the stop.  The level itself only moves on a new
//--- extreme: median 2 modifies per trade over the @ES run, 6 at worst.
   double band = MathMax(InpMinModifyTicks, 1) * TickSize();
   if(g_trailSent <= 0.0 || MathAbs(lvl - g_trailSent) >= band)
     {
      ApplyExits(mp, entry, px);
      g_trailSent = lvl;
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
   if(InpTrailMode == 1 && (InpTrailGiveBackPct <= 0.0 || InpTrailGiveBackPct >= 100.0))
     {
      Print("InpTrailGiveBackPct must be between 0 and 100");
      return INIT_PARAMETERS_INCORRECT;
     }
   string trailNote;
   if(PctTrailingFloorAmtL <= 0.0)
      trailNote = "trail off";
   else if(InpTrailMode == 1)
     {
      double gb = InpTrailGiveBackPct / 100.0;
      trailNote = StringFormat("trail: on close, P&L >= %.0f locks %.0f, >= %.0f locks %.0f, "
                               "every %.0f thereafter (give back %.0f%%)",
                               PctTrailingFloorAmtL,        PctTrailingFloorAmtL * (1.0 - gb),
                               PctTrailingFloorAmtL * 2.0, (PctTrailingFloorAmtL * 2.0) * (1.0 - gb),
                               PctTrailingFloorAmtL, InpTrailGiveBackPct);
     }
   else
      trailNote = StringFormat("trail %.0f / %.1f%% (SetPercentTrailing, MultiCharts exact, "
                               "watched tick by tick)",
                               PctTrailingFloorAmtL, PctTrailingPctL);
   PrintFormat("XT342v0PL890m on %s %s | %s | avg lengths %d / %d | "
               "target %.0f stop %.0f | %s | per contract",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
               (EnableLong && EnableShort) ? "both sides"
                  : EnableLong ? "long only" : EnableShort ? "short only" : "NO ENTRIES",
               (int)(Length * len_L), (int)(Length * len_S),
               ProfitTargetAmtL, StopLossAmtL, trailNote);
   PrintFormat("stops: tick %s, stops level %s, freeze %s, spread now %s -> min distance %s",
               DoubleToString(TickSize(), _Digits),  DoubleToString(StopsLevel(), _Digits),
               DoubleToString(FreezeLevel(), _Digits), DoubleToString(Spread(), _Digits),
               DoubleToString(MinStopDist(), _Digits));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectDelete(0, "XT342_trail");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
//--- One of the two entry stops filled -> the other must go, now, not at the
//--- next bar.  Then the trail, which is a MultiCharts-internal level and has
//--- to be watched continuously.  The study's own decisions below still happen
//--- once per closed bar.
   CancelOppositePendings();
   ManageTrail();

   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == g_lastBar)
      return;
   int need = (int)MathMax(Length, MathMax(Length * len_L, Length * len_S)) + 3;
   if(Bars(_Symbol, _Period) < need)
      return;
   g_lastBar = t0;

   const int s = 1;                                  // the bar that just closed
   double rng = iHigh(_Symbol, _Period, s) - iLow(_Symbol, _Period, s);

   CancelPendings();                                 // orders live one bar

   if(ExitOnClose && SessionChanged(s) && MarketPosition() != 0)
     {
      trade.PositionClose(_Symbol, InpSlippagePoints);
      g_entry = 0.0;
      g_mfePrice = 0.0;
      g_lockedSL = 0.0;
      g_entryBar = 0;
      g_trailSent = 0.0;
     }

//--- ------------------------- the study ------------------------------
   bool Condition1 = rng < AvgRange(s, Length * len_L);   // contraction -> long
   bool Condition2 = rng > AvgRange(s, Length * len_S);   // expansion   -> short

   int mp = MarketPosition();

   if(mp == 0)
     {
      //--- The original places BOTH when both are true, and lets the bar
      //--- decide.  Neither is an "instead of" the other.
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double minD = MinStopDist();

      if(Condition1 && EnableLong)
        {
         double at = NormalizeDouble(HighestHigh(s, Length), _Digits);
         //--- a buy stop already below the market gaps through in MultiCharts
         //--- and fills at the open; MT5 will not hold it, so go at market
         if(at <= ask + minD)
            trade.Buy(InpLots, _Symbol, 0.0, 0.0, 0.0, "XT342 LE");
         else
            trade.BuyStop(InpLots, at, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0,
                          "XT342 LE");
        }

      //--- re-read: a market Buy above may already have filled, and the
      //--- original only ever opens from flat
      if(Condition2 && EnableShort && MarketPosition() == 0)
        {
         double at = NormalizeDouble(LowestLow(s, Length), _Digits);
         if(at >= bid - minD)
            trade.Sell(InpLots, _Symbol, 0.0, 0.0, 0.0, "XT342 SE");
         else
            trade.SellStop(InpLots, at, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0,
                           "XT342 SE");
        }
     }

//--- --------------- money management, per contract -------------------
//--- ManageTrail() keeps these current tick by tick; this refreshes them on the
//--- bar boundary too, so a position that opened on this bar is protected
//--- immediately rather than on its next tick.
   mp = MarketPosition();
   if(mp == 0)
     {
      g_entry = 0.0;
      g_mfePrice = 0.0;
      g_lockedSL = 0.0;
      g_entryBar = 0;
      g_trailSent = 0.0;
      DrawTrail(0.0);
      return;
     }
   ApplyExits(mp, PositionGetDouble(POSITION_PRICE_OPEN),
              iClose(_Symbol, _Period, s));          // "check on close"
  }
//+------------------------------------------------------------------+
