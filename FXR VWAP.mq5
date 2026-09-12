//+------------------------------------------------------------------+
//|                                                   FXR VWAP.mq5   |
//|      FXR VWAP — session / weekly / monthly / anchored VWAP       |
//|      with volume-weighted σ bands                                |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, FXrepo.com"
#property link "https://fxrepo.com/resources/vwap-indicator-mt5/"
#property description "FXR VWAP — session / weekly / monthly / anchored VWAP with volume-weighted bands. MIT licence."
#property version   "1.0.1"

#property indicator_chart_window
#property indicator_buffers 5
#property indicator_plots   5

//--- plots
#property indicator_label1  "VWAP"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrAqua
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "+1σ"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrGray
#property indicator_style2  STYLE_SOLID
#property indicator_width2  1

#property indicator_label3  "-1σ"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrGray
#property indicator_style3  STYLE_SOLID
#property indicator_width3  1

#property indicator_label4  "+2σ"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrDarkGray
#property indicator_style4  STYLE_SOLID
#property indicator_width4  1

#property indicator_label5  "-2σ"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrDarkGray
#property indicator_style5  STYLE_SOLID
#property indicator_width5  1

#include <Trade\Trade.mqh>

//--- enums
enum ENUM_RESET_MODE
  {
   RESET_SESSION  = 0, // Session
   RESET_WEEKLY   = 1, // Weekly
   RESET_MONTHLY  = 2, // Monthly
   RESET_ANCHORED = 3  // Anchored
  };

enum ENUM_FXR_PRICE_SOURCE
  {
   FXR_PRICE_TYPICAL  = 0, // Typical (H+L+C)/3
   FXR_PRICE_CLOSE    = 1, // Close
   FXR_PRICE_MEDIAN   = 2, // Median (H+L)/2
   FXR_PRICE_WEIGHTED = 3  // Weighted (H+L+2C)/4
  };

enum ENUM_FXR_VOLUME_SOURCE
  {
   FXR_VOLUME_AUTO = 0, // Auto (real if available else tick)
   FXR_VOLUME_TICK = 1, // Tick volume
   FXR_VOLUME_REAL = 2  // Real volume
  };

//--- inputs
input group "=== Reset ==="
input ENUM_RESET_MODE   InpResetMode   = RESET_SESSION; // Reset mode
input string            InpSessionStart= "00:00";        // Session start HH:MM (server time)
input datetime          InpAnchorTime  = 0;              // Anchored VWAP start (0 = use draggable line)

input group "=== Calculation ==="
input ENUM_FXR_PRICE_SOURCE InpPriceSource = FXR_PRICE_TYPICAL;  // Price source
input ENUM_FXR_VOLUME_SOURCE InpVolumeSource= FXR_VOLUME_AUTO;   // Volume source
input int               InpMaxBarsBack = 5000;           // Max bars to compute (perf cap)

input group "=== Bands ==="
input bool              InpShowBands   = true;           // Show σ bands
input double            InpBand1Mult   = 1.0;            // Band 1 multiplier
input double            InpBand2Mult   = 2.0;            // Band 2 multiplier

input group "=== Alerts ==="
input bool              InpAlertOnCross= false;          // Enable cross alerts (once per bar close)
input bool              InpAlertPush   = false;          // Send push notification
input bool              InpAlertEmail  = false;          // Send e-mail

input group "=== Style ==="
input int               InpLineWidth   = 2;              // VWAP line width
input color             InpColorVWAP   = clrAqua;        // VWAP color
input color             InpColorBand1  = clrGray;        // ±1σ color
input color             InpColorBand2  = clrDarkGray;    // ±2σ color

//--- buffers
double ExtVWAP[];
double ExtBand1Up[];
double ExtBand1Down[];
double ExtBand2Up[];
double ExtBand2Down[];

//--- globals
#define ANCHOR_NAME "FXR_VWAP_Anchor"

int    g_sessionHour = 0;
int    g_sessionMinute = 0;
bool   g_sessionParsed = false;
bool   g_warnedSessionHTF = false;
bool   g_warnedZeroVol = false;
bool   g_anchorMoved = false;
datetime g_lastAnchorTime = 0;
datetime g_effectiveAnchorTime = 0;
int    g_anchorIndex = -1;
datetime g_lastBarTime = 0;
datetime g_lastAlertBarTime = 0;
int    g_lastRatesTotal = 0;

//+------------------------------------------------------------------+
//| Parse HH:MM                                                      |
//+------------------------------------------------------------------+
bool ParseSessionTime(const string s, int &hour, int &minute)
  {
   hour=0; minute=0;
   string parts[];
   int n = StringSplit(s, ':', parts);
   if(n<2)
     {
      // try also without colon? allow "HHMM" ?
      if(StringLen(s)>=3)
        {
         // fallback: try to parse as HH:MM
         hour = (int)StringToInteger(StringSubstr(s,0,2));
         minute = (int)StringToInteger(StringSubstr(s,3));
        }
      else
         return(false);
     }
   else
     {
      hour = (int)StringToInteger(parts[0]);
      minute = (int)StringToInteger(parts[1]);
     }
   if(hour<0 || hour>23 || minute<0 || minute>59) return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Get price by source                                              |
//+------------------------------------------------------------------+
double GetPriceBySource(int i, ENUM_FXR_PRICE_SOURCE src, const double &open[], const double &high[], const double &low[], const double &close[])
  {
   switch(src)
     {
      case FXR_PRICE_CLOSE:    return(close[i]);
      case FXR_PRICE_MEDIAN:   return((high[i]+low[i])*0.5);
      case FXR_PRICE_WEIGHTED: return((high[i]+low[i]+2.0*close[i])*0.25);
      case FXR_PRICE_TYPICAL:
      default:                 return((high[i]+low[i]+close[i])/3.0);
     }
  }

//+------------------------------------------------------------------+
//| Get volume by source                                             |
//+------------------------------------------------------------------+
double GetVolumeBySource(int i, ENUM_FXR_VOLUME_SOURCE vsrc, const long &tick_volume[], const long &real_volume[])
  {
   long v=0;
   bool hasReal = (real_volume[i] > 0);

   switch(vsrc)
     {
      case FXR_VOLUME_TICK:
         v = tick_volume[i];
         break;
      case FXR_VOLUME_REAL:
         v = real_volume[i];
         if(v<=0) v = tick_volume[i]; // fallback
         break;
      case FXR_VOLUME_AUTO:
      default:
         if(hasReal && real_volume[i]>0)
            v = real_volume[i];
         else
            v = tick_volume[i];
         break;
     }
   if(v<=0)
     {
      if(!g_warnedZeroVol)
        {
         Print("FXR VWAP: zero volume on bar ", i, " time ", TimeToString(iTime(_Symbol,_Period,i)), " -> using v=1 (CFD feed?). This message shown once.");
         g_warnedZeroVol=true;
        }
      return(1.0);
     }
   return((double)v);
  }

//+------------------------------------------------------------------+
//| Get W1 start time for a given time                               |
//+------------------------------------------------------------------+
datetime GetW1Start(datetime t)
  {
   int shift = iBarShift(_Symbol, PERIOD_W1, t, true);
   if(shift < 0) return(0);
   datetime w1 = iTime(_Symbol, PERIOD_W1, shift);
   return(w1);
  }

//+------------------------------------------------------------------+
//| Create / update anchor line                                      |
//+------------------------------------------------------------------+
void CreateAnchorLine(datetime t)
  {
   if(ObjectFind(0, ANCHOR_NAME) < 0)
      ObjectCreate(0, ANCHOR_NAME, OBJ_VLINE, 0, t, 0);
   ObjectSetInteger(0, ANCHOR_NAME, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, ANCHOR_NAME, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, ANCHOR_NAME, OBJPROP_COLOR, InpColorVWAP);
   ObjectSetInteger(0, ANCHOR_NAME, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, ANCHOR_NAME, OBJPROP_WIDTH, 1);
   ObjectSetString(0, ANCHOR_NAME, OBJPROP_TOOLTIP, "FXR VWAP Anchor - drag to re-anchor");
   ObjectSetInteger(0, ANCHOR_NAME, OBJPROP_TIME, 0, t);
   ObjectSetInteger(0, ANCHOR_NAME, OBJPROP_ZORDER, 100);
  }

void EnsureAnchorLine(const datetime &time[], int rates_total)
  {
   datetime target=0;
   if(InpAnchorTime!=0)
      target = InpAnchorTime;
   else if(g_effectiveAnchorTime!=0)
      target = g_effectiveAnchorTime;
   else
     {
      // default to bar 200 from end if possible
      int idx = rates_total - 200;
      if(idx<0) idx=0;
      target = time[idx];
     }

   if(ObjectFind(0, ANCHOR_NAME) < 0)
     {
      CreateAnchorLine(target);
      g_effectiveAnchorTime = target;
     }
   else
     {
      // if anchor time input changed, move line
      if(InpAnchorTime!=0 && InpAnchorTime!=g_lastAnchorTime)
        {
         ObjectSetInteger(0, ANCHOR_NAME, OBJPROP_TIME, 0, InpAnchorTime);
         g_effectiveAnchorTime = InpAnchorTime;
        }
     }
   g_lastAnchorTime = InpAnchorTime;
  }

//+------------------------------------------------------------------+
//| Find anchor index from time array (v1.01 optimized)              |
//+------------------------------------------------------------------+
int FindAnchorIndex(const datetime &time[], int rates_total, datetime anchorTime)
  {
   if(anchorTime==0) return(-1);
   int shift = iBarShift(_Symbol, _Period, anchorTime, false);
   if(shift<0) return(-1);
   // iBarShift: 0 = newest bar, convert to 0 = oldest indexing used in time[]
   int idx = rates_total - 1 - shift;
   if(idx<0) idx=0;
   if(idx>=rates_total) idx=rates_total-1;
   return(idx);
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- parse session
   g_sessionParsed = ParseSessionTime(InpSessionStart, g_sessionHour, g_sessionMinute);
   if(!g_sessionParsed)
     {
      Print("FXR VWAP: Invalid SessionStart '", InpSessionStart, "' - using 00:00");
      g_sessionHour=0; g_sessionMinute=0;
      g_sessionParsed=true;
     }

   //--- buffers
   SetIndexBuffer(0, ExtVWAP, INDICATOR_DATA);
   SetIndexBuffer(1, ExtBand1Up, INDICATOR_DATA);
   SetIndexBuffer(2, ExtBand1Down, INDICATOR_DATA);
   SetIndexBuffer(3, ExtBand2Up, INDICATOR_DATA);
   SetIndexBuffer(4, ExtBand2Down, INDICATOR_DATA);

   ArraySetAsSeries(ExtVWAP, false);
   ArraySetAsSeries(ExtBand1Up, false);
   ArraySetAsSeries(ExtBand1Down, false);
   ArraySetAsSeries(ExtBand2Up, false);
   ArraySetAsSeries(ExtBand2Down, false);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(4, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   PlotIndexSetInteger(0, PLOT_LINE_COLOR, InpColorVWAP);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, InpColorBand1);
   PlotIndexSetInteger(2, PLOT_LINE_COLOR, InpColorBand1);
   PlotIndexSetInteger(3, PLOT_LINE_COLOR, InpColorBand2);
   PlotIndexSetInteger(4, PLOT_LINE_COLOR, InpColorBand2);

   PlotIndexSetInteger(0, PLOT_LINE_WIDTH, InpLineWidth);
   PlotIndexSetInteger(1, PLOT_LINE_WIDTH, 1);
   PlotIndexSetInteger(2, PLOT_LINE_WIDTH, 1);
   PlotIndexSetInteger(3, PLOT_LINE_WIDTH, 1);
   PlotIndexSetInteger(4, PLOT_LINE_WIDTH, 1);

   IndicatorSetString(INDICATOR_SHORTNAME, "FXR VWAP ("+EnumToString(InpResetMode)+")");

   g_warnedSessionHTF=false;
   g_warnedZeroVol=false;
   g_anchorMoved=false;
   // v1.01: keep dragged anchor across TF changes
   if(InpAnchorTime!=0 || g_effectiveAnchorTime==0)
      g_effectiveAnchorTime = InpAnchorTime;
   g_lastAnchorTime = InpAnchorTime;
   if(InpResetMode==RESET_ANCHORED && ObjectFind(0, ANCHOR_NAME)<0)
      CreateAnchorLine(g_effectiveAnchorTime!=0 ? g_effectiveAnchorTime : TimeCurrent());

   Print("FXR VWAP initialized: Reset=", EnumToString(InpResetMode), " SessionStart=", InpSessionStart,
         " Price=", EnumToString(InpPriceSource), " Vol=", EnumToString(InpVolumeSource),
         " MaxBarsBack=", InpMaxBarsBack);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit  v1.01: keep anchor on TF change / param change / recompile |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(reason==REASON_CHARTCHANGE || reason==REASON_PARAMETERS || reason==REASON_RECOMPILE)
      return; // line stays; EnsureAnchorLine() reads it back on next init
   if(ObjectFind(0, ANCHOR_NAME)>=0)
      ObjectDelete(0, ANCHOR_NAME);
  }

//+------------------------------------------------------------------+
//| OnChartEvent                                                     |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id==CHARTEVENT_OBJECT_DRAG && sparam==ANCHOR_NAME)
     {
      datetime t = (datetime)ObjectGetInteger(0, ANCHOR_NAME, OBJPROP_TIME, 0);
      // snap to bar time
      int shift = iBarShift(_Symbol, _Period, t, true);
      if(shift>=0)
        {
         datetime barTime = iTime(_Symbol, _Period, shift);
         // update line to exact bar time
         ObjectSetInteger(0, ANCHOR_NAME, OBJPROP_TIME, 0, barTime);
         g_effectiveAnchorTime = barTime;
         g_anchorMoved = true;
         ChartRedraw();
         // force recalc on next tick - we will do full recompute when g_anchorMoved true
        }
     }
   else if(id==CHARTEVENT_OBJECT_DELETE)
     {
      // not reliable for our line? But spec: if deleted recreate
      // We handle in OnCalculate EnsureAnchorLine
     }
  }

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < 2) return(0);

   // enforce non-series for our logic (0=oldest)
   ArraySetAsSeries(time, false);
   ArraySetAsSeries(open, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(tick_volume, false);
   ArraySetAsSeries(volume, false);

   //--- check SessionStart parse if changed? (input change triggers OnInit? but just in case)
   //--- MaxBarsBack cap
   int maxBack = InpMaxBarsBack;
   if(maxBack < 100) maxBack = 100;
   if(maxBack > 100000) maxBack = 100000;

   int calcStart = rates_total - maxBack;
   if(calcStart < 0) calcStart = 0;

   //--- empty older bars
   for(int i=0; i<calcStart; i++)
     {
      ExtVWAP[i]=EMPTY_VALUE;
      ExtBand1Up[i]=EMPTY_VALUE;
      ExtBand1Down[i]=EMPTY_VALUE;
      ExtBand2Up[i]=EMPTY_VALUE;
      ExtBand2Down[i]=EMPTY_VALUE;
     }

   //--- anchor handling
   if(InpResetMode==RESET_ANCHORED)
     {
      EnsureAnchorLine(time, rates_total);
      datetime anchorTime = g_effectiveAnchorTime;
      if(InpAnchorTime!=0) anchorTime = InpAnchorTime;
      // if anchor line exists, its time overrides unless input is non-zero?
      // Spec: AnchorTime 0 = use draggable line
      if(InpAnchorTime==0 && ObjectFind(0, ANCHOR_NAME)>=0)
        {
         anchorTime = (datetime)ObjectGetInteger(0, ANCHOR_NAME, OBJPROP_TIME, 0);
         g_effectiveAnchorTime = anchorTime;
        }
      else if(InpAnchorTime!=0)
        {
         g_effectiveAnchorTime = InpAnchorTime;
         anchorTime = InpAnchorTime;
        }

      g_anchorIndex = FindAnchorIndex(time, rates_total, anchorTime);
     }
   else
     {
      // not anchored, hide anchor line if exists
      if(ObjectFind(0, ANCHOR_NAME)>=0 && InpResetMode!=RESET_ANCHORED)
        {
         // keep it? spec says anchored mode only. Remove when not anchored
         ObjectDelete(0, ANCHOR_NAME);
        }
      g_anchorIndex = -1;
     }

   //--- warn session on high TF once
   if(!g_warnedSessionHTF && InpResetMode==RESET_SESSION && _Period >= PERIOD_H4)
     {
      Print("FXR VWAP: Session VWAP on H4/D1 is degenerate — use Weekly/Monthly. This warning shown once.");
      g_warnedSessionHTF=true;
     }

   //--- determine full recompute needed
   bool fullRecalc = false;
   if(prev_calculated==0 || g_anchorMoved || rates_total != g_lastRatesTotal)
     {
      // if rates_total changed significantly (history gap) or anchor moved, full recalc from calcStart
      fullRecalc = true;
      if(g_anchorMoved) g_anchorMoved=false;
     }

   //--- for incremental, find last segment start
   // We will recalc from current segment start to end if not full recalc, to satisfy spec
   int recalcFrom = calcStart;
   if(!fullRecalc && prev_calculated>1)
     {
      // find last reset index
      // we need to scan backwards from rates_total-1 to calcStart to find last reset
      // To avoid double scan, we will first find last reset index in a quick backward scan
      int lastResetIdx = calcStart;
      for(int i=rates_total-1; i>calcStart; i--)
        {
         bool isReset=false;
         if(InpResetMode==RESET_ANCHORED)
           {
            if(i==g_anchorIndex) { isReset=true; }
           }
         else if(InpResetMode==RESET_SESSION)
           {
            // session boundary between i-1 and i
            datetime t_prev = time[i-1];
            datetime t_curr = time[i];
            // build session time for day of t_curr
            MqlDateTime dt_curr;
            TimeToStruct(t_curr, dt_curr);
            dt_curr.hour = g_sessionHour;
            dt_curr.min  = g_sessionMinute;
            dt_curr.sec  = 0;
            datetime sess = StructToTime(dt_curr);
            // if sess > t_curr (e.g., session 22:00 but bar 10:00), sess is today 22:00 which is after current bar, so previous day's session is the one
            // For reset detection, we need to check if sess is between t_prev and t_curr
            // Also need to handle case where sess is exactly at midnight next day? Our check handles it
            if(t_prev < sess && sess <= t_curr)
               isReset=true;
            // also if day changed and session is 00:00, the above works
           }
         else if(InpResetMode==RESET_WEEKLY)
           {
            datetime w1_curr = GetW1Start(time[i]);
            datetime w1_prev = GetW1Start(time[i-1]);
            if(w1_curr!=w1_prev && w1_curr!=0) isReset=true;
           }
         else if(InpResetMode==RESET_MONTHLY)
           {
            MqlDateTime d1,d2;
            TimeToStruct(time[i-1], d1);
            TimeToStruct(time[i], d2);
            if(d1.mon!=d2.mon || d1.year!=d2.year) isReset=true;
           }
         if(isReset)
           {
            lastResetIdx=i;
            break;
           }
        }
      // if last reset is after prev_calculated, recalc from there, else from prev_calculated-1
      if(lastResetIdx >= prev_calculated-1)
         recalcFrom = lastResetIdx;
      else
         recalcFrom = prev_calculated-1;
      if(recalcFrom < calcStart) recalcFrom = calcStart;
     }
   else
     {
      recalcFrom = calcStart;
     }

   //--- cumulative sums
   // If we are doing incremental from recalcFrom > calcStart, we need to restore sums up to recalcFrom-1
   // To restore, we can recompute sums from the start of the current segment up to recalcFrom-1
   // Simpler: if recalcFrom > calcStart and not fullRecalc, we need to find the segment start for recalcFrom and compute sums up to recalcFrom-1
   // We'll do a pre-loop to compute sums for the segment containing recalcFrom

   double PV=0.0, V=0.0, PV2=0.0;
   int segStart = calcStart;

   // Find segment start for recalcFrom
   if(recalcFrom > calcStart)
     {
      // walk backwards to find last reset before recalcFrom
      segStart = calcStart;
      for(int i=recalcFrom; i>calcStart; i--)
        {
         bool isReset=false;
         if(InpResetMode==RESET_ANCHORED)
           {
            if(i==g_anchorIndex) { isReset=true; segStart=i; break; }
            // if we passed anchor, segment starts at anchor
            if(i-1 < g_anchorIndex && g_anchorIndex < recalcFrom) { segStart=g_anchorIndex; break; }
           }
         else if(InpResetMode==RESET_SESSION)
           {
            datetime t_prev = time[i-1];
            datetime t_curr = time[i];
            MqlDateTime dt_curr;
            TimeToStruct(t_curr, dt_curr);
            dt_curr.hour = g_sessionHour;
            dt_curr.min  = g_sessionMinute;
            dt_curr.sec  = 0;
            datetime sess = StructToTime(dt_curr);
            if(t_prev < sess && sess <= t_curr) { segStart=i; break; }
           }
         else if(InpResetMode==RESET_WEEKLY)
           {
            datetime w1_curr = GetW1Start(time[i]);
            datetime w1_prev = GetW1Start(time[i-1]);
            if(w1_curr!=w1_prev && w1_curr!=0) { segStart=i; break; }
           }
         else if(InpResetMode==RESET_MONTHLY)
           {
            MqlDateTime d1,d2;
            TimeToStruct(time[i-1], d1);
            TimeToStruct(time[i], d2);
            if(d1.mon!=d2.mon || d1.year!=d2.year) { segStart=i; break; }
           }
        }
      // now accumulate from segStart to recalcFrom-1 to restore PV,V,PV2
      PV=0; V=0; PV2=0;
      for(int i=segStart; i<recalcFrom; i++)
        {
         if(InpResetMode==RESET_ANCHORED && i < g_anchorIndex) continue;
         double p = GetPriceBySource(i, InpPriceSource, open, high, low, close);
         double vol = GetVolumeBySource(i, InpVolumeSource, tick_volume, volume);
         PV  += p*vol;
         V   += vol;
         PV2 += p*p*vol;
        }
     }
   else
     {
      // full recalc from calcStart, reset sums
      PV=0; V=0; PV2=0;
      segStart=calcStart;
     }

   //--- main loop from recalcFrom to end
   for(int i=recalcFrom; i<rates_total; i++)
     {
      bool isReset=false;

      if(i==calcStart)
        {
         isReset=true;
         // but for anchored, first bar is not necessarily reset unless it's anchor
         if(InpResetMode==RESET_ANCHORED)
            isReset = (i==g_anchorIndex);
         // for session/weekly/monthly, we treat calcStart as segment start to avoid empty
         // actually we want true reset detection, but for first bar in window we start fresh
         if(InpResetMode!=RESET_ANCHORED)
            isReset=true;
        }
      else
        {
         if(InpResetMode==RESET_ANCHORED)
           {
            if(i==g_anchorIndex) isReset=true;
           }
         else if(InpResetMode==RESET_SESSION)
           {
            datetime t_prev = time[i-1];
            datetime t_curr = time[i];
            MqlDateTime dt_curr;
            TimeToStruct(t_curr, dt_curr);
            dt_curr.hour = g_sessionHour;
            dt_curr.min  = g_sessionMinute;
            dt_curr.sec  = 0;
            datetime sess = StructToTime(dt_curr);
            if(t_prev < sess && sess <= t_curr)
               isReset=true;
           }
         else if(InpResetMode==RESET_WEEKLY)
           {
            datetime w1_curr = GetW1Start(time[i]);
            datetime w1_prev = GetW1Start(time[i-1]);
            if(w1_curr!=w1_prev && w1_curr!=0) isReset=true;
           }
         else if(InpResetMode==RESET_MONTHLY)
           {
            MqlDateTime d1,d2;
            TimeToStruct(time[i-1], d1);
            TimeToStruct(time[i], d2);
            if(d1.mon!=d2.mon || d1.year!=d2.year) isReset=true;
           }
        }

      if(isReset)
        {
         PV=0; V=0; PV2=0;
         segStart=i;
        }

      // anchored: before anchor, empty
      if(InpResetMode==RESET_ANCHORED && (g_anchorIndex<0 || i < g_anchorIndex))
        {
         ExtVWAP[i]=EMPTY_VALUE;
         ExtBand1Up[i]=EMPTY_VALUE;
         ExtBand1Down[i]=EMPTY_VALUE;
         ExtBand2Up[i]=EMPTY_VALUE;
         ExtBand2Down[i]=EMPTY_VALUE;
         continue;
        }

      double price = GetPriceBySource(i, InpPriceSource, open, high, low, close);
      double vol   = GetVolumeBySource(i, InpVolumeSource, tick_volume, volume);

      PV  += price*vol;
      V   += vol;
      PV2 += price*price*vol;

      if(V<=0)
        {
         ExtVWAP[i]=EMPTY_VALUE;
         ExtBand1Up[i]=EMPTY_VALUE;
         ExtBand1Down[i]=EMPTY_VALUE;
         ExtBand2Up[i]=EMPTY_VALUE;
         ExtBand2Down[i]=EMPTY_VALUE;
         continue;
        }

      double vwap = PV / V;
      ExtVWAP[i]=vwap;

      if(InpShowBands)
        {
         // first bar after reset: bands 0 width
         if(i==segStart)
           {
            ExtBand1Up[i]=vwap;
            ExtBand1Down[i]=vwap;
            ExtBand2Up[i]=vwap;
            ExtBand2Down[i]=vwap;
           }
         else
           {
            double var = PV2 / V - vwap*vwap;
            if(var<0) var=0; // clamp
            double sigma = MathSqrt(var);
            ExtBand1Up[i]   = vwap + InpBand1Mult*sigma;
            ExtBand1Down[i] = vwap - InpBand1Mult*sigma;
            ExtBand2Up[i]   = vwap + InpBand2Mult*sigma;
            ExtBand2Down[i] = vwap - InpBand2Mult*sigma;
           }
        }
      else
        {
         ExtBand1Up[i]=EMPTY_VALUE;
         ExtBand1Down[i]=EMPTY_VALUE;
         ExtBand2Up[i]=EMPTY_VALUE;
         ExtBand2Down[i]=EMPTY_VALUE;
        }
     }

   //--- alerts: once per bar close
   if(InpAlertOnCross)
     {
      datetime currBarTime = time[rates_total-1];
      if(currBarTime != g_lastBarTime)
        {
         // new bar formed, check previous closed bar
         g_lastBarTime = currBarTime;
         int closedIdx = rates_total-2;
         if(closedIdx >= calcStart && closedIdx>=1)
           {
            double closePrev = close[closedIdx];
            double closePrev2= close[closedIdx-1];
            double vwapPrev  = ExtVWAP[closedIdx];
            double vwapPrev2 = ExtVWAP[closedIdx-1];
            if(vwapPrev!=EMPTY_VALUE && vwapPrev2!=EMPTY_VALUE)
              {
               bool crossAbove = (closePrev2 <= vwapPrev2 && closePrev > vwapPrev);
               bool crossBelow = (closePrev2 >= vwapPrev2 && closePrev < vwapPrev);
               if((crossAbove || crossBelow) && time[closedIdx] != g_lastAlertBarTime)
                 {
                  g_lastAlertBarTime = time[closedIdx];
                  string dir = crossAbove ? "above" : "below";
                  string tf = StringSubstr(EnumToString(_Period), 7);
                  string msg = StringFormat("FXR VWAP: %s %s close %s VWAP %.5f", _Symbol, tf, dir, vwapPrev);
                  Alert(msg);
                  Print(msg);
                  if(InpAlertPush) SendNotification(msg);
                  if(InpAlertEmail) SendMail("FXR VWAP Cross Alert", msg);
                 }
              }
           }
        }
     }

   g_lastRatesTotal = rates_total;
   return(rates_total);
  }
//+------------------------------------------------------------------+
