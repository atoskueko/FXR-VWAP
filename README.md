FXR VWAP.mq5 - Installation and Documentation
================================================

Concept credit: VWAP as used by institutional execution desks
Reference: https://www.investopedia.com/terms/v/vwap.asp
Closest third-party alternative: TradingView's built-in VWAP (session/anchored with σ bands) — MT5 ships no VWAP at all

Post URL: https://fxrepo.com/resources/vwap-indicator-mt5/
Licence: MIT (see below)

------------------------------------------------
INSTALLATION
------------------------------------------------
1. Copy FXR VWAP.mq5 to: [MT5 Data Folder]/MQL5/Indicators/
   - In MT5: File -> Open Data Folder -> MQL5 -> Indicators
2. Compile in MetaEditor (F7) or restart MT5 (auto-compile)
3. Attach to chart: Insert -> Indicators -> Custom -> FXR VWAP
4. For Anchored mode: a vertical line named FXR_VWAP_Anchor appears. Drag it to re-anchor. If you delete it, it recreates at AnchorTime or bar 200.

------------------------------------------------
PURPOSE
------------------------------------------------
A volume-weighted average price for MetaTrader 5 that resets by session, week or month or from any anchor you pick, with ±1σ/±2σ bands, so intraday traders can see the institutional reference price MT5 does not ship.

What it draws:
- Main VWAP line, recalculated cumulatively from reset point on every tick (price × volume / Σ volume)
- Optional ±1σ and ±2σ bands, volume-weighted (σ of price around VWAP, weighted by volume)

------------------------------------------------
INPUTS
------------------------------------------------
Input                  Default      What it does                                      Sensible range
----------------------------------------------------------------------------------------------------------------------------------
ResetMode (enum)       Session      Session / Weekly / Monthly / Anchored             —
SessionStart (string)  "00:00"      Reset time in server time for Session mode        any; use broker midnight or exchange open
AnchorTime (datetime)  0            Start of anchored VWAP; 0 = use draggable line    any past bar
PriceSource (enum)     Typical      Typical (H+L+C)/3 / Close / Median / Weighted     —
VolumeSource (enum)    Auto         Auto (real if available else tick) / Tick / Real  —
ShowBands (bool)       true         Draw σ bands                                      —
Band1Mult (double)     1.0          Multiplier for inner band                         0.5 – 2.0
Band2Mult (double)     2.0          Multiplier for outer band                         1.5 – 3.0
MaxBarsBack (int)      5000         Bars to compute on load (performance cap)         1000 – 50000
AlertOnCross (bool)    false        Enable cross alerts (close above/below VWAP)      —
AlertPush (bool)       false        Route alerts to mobile push                       —
AlertEmail (bool)      false        Route alerts to e-mail                            —
LineWidth (int)        2            VWAP line width                                   1 – 5
ColorVWAP (color)      aqua         VWAP line color                                   —
ColorBand1 (color)     grey         ±1σ band color                                    —
ColorBand2 (color)     dark grey    ±2σ band color                                    —

------------------------------------------------
CALCULATION
------------------------------------------------
Reset index r = first bar of current session/week/month, or anchor bar.
Cumulative sums from r to current bar i: PV = Σ p_k·v_k, V = Σ v_k, PV2 = Σ p_k²·v_k
VWAP_i = PV / V
Volume-weighted variance: var_i = PV2 / V − VWAP_i² (clamped at 0); σ_i = sqrt(var_i)
Bands: VWAP ± Band1Mult·σ, VWAP ± Band2Mult·σ
Recalculate only bars from current reset point on each tick (keep running sums per segment); full recompute on init and on anchor move.

------------------------------------------------
EDGE CASES HANDLED
------------------------------------------------
- First bar after reset: V = v_first (never divide by zero); bands start at 0 width, drawn from second bar
- Symbol with zero volume on a bar (some CFD feeds): treat v=1 for that bar and log once in Experts tab
- Session mode on TF ≥ H4: warn once ("Session VWAP on H4/D1 is degenerate — use Weekly/Monthly") and still draw
- Weekly reset uses PERIOD_W1 bar open time, so broker weeks starting Sunday 22:00 are handled by terminal, not DST guesses
- Anchor line deleted by user → recreate at AnchorTime (or bar 200 if 0) and recompute
- History gaps / missing bars: sums skip them naturally; no interpolation
- MaxBarsBack reached: earlier bars EMPTY_VALUE, not partial VWAP

------------------------------------------------
ALERTS
------------------------------------------------
Once per bar close; message: FXR VWAP: {symbol} {tf} close {above|below} VWAP {value}
Popup Alert() always, Push via SendNotification() if AlertPush, E-mail via SendMail() if AlertEmail

------------------------------------------------
CODING NOTES
------------------------------------------------
#property indicator_chart_window, 5 buffers (VWAP, +1σ, −1σ, +2σ, −2σ), DRAW_LINE each; colours via PlotIndexSetInteger
Anchor line: OBJ_VLINE named FXR_VWAP_Anchor, OBJPROP_SELECTABLE true; OnChartEvent drag → snap to bar, full recompute

------------------------------------------------
MIT LICENCE
------------------------------------------------
MIT License

Copyright (c) 2026 FXrepo.com

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

------------------------------------------------
CHANGELOG
------------------------------------------------
v1.00 - 2026-09-11
- Initial release: Session/Weekly/Monthly/Anchored VWAP with volume-weighted σ bands, price/volume source selection, draggable anchor line, cross alerts, MaxBarsBack cap, zero-volume handling, H4+ session warning
