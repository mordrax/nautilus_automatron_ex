# Design: Indicators Phase 3b — panel oscillators

**Date:** 2026-06-04
**Project:** `nautilus_automatron_ex`
**Status:** Scoped autonomously (Phase 3, continue unsupervised). Second slice of Phase 3.

## Purpose

Add the **panel oscillator indicators — RSI, MACD, ATR, Stochastics** — to the
run-detail page. Unlike the Phase 3a overlays (lines on the price axis), panel
indicators render in **separate chart grids below the candlesticks**, each with
its own y-axis. Reuses all of 3a's plumbing (registry, viewer-state, compute
dispatch, sidebar, `chart:set_indicators`); the new work is the four compute
functions and the chart's panel-grid layout.

## Scope

### In

- **Compute (pure):** `rsi`, `macd`, `atr`, `stochastics` added to
  `AutomatronEx.Indicators`, over the bar series (high/low/close as needed),
  `nil`-padded until initialized. Python parity.
- **Registry:** 4 new entries, `display: "panel"`, with params:
  - RSI — `period` int [2,100] default 14; outputs `["value"]`
  - MACD — `fast_period` int [2,200] default 12, `slow_period` int [2,500] default 26; outputs `["value"]`
  - ATR — `period` int [1,200] default 14; outputs `["value"]`
  - Stochastics — `period_k` int [1,200] default 14, `period_d` int [1,200] default 3; outputs `["value_k", "value_d"]`
- **`compute/2` extension:** dispatch the panel types; pass high/low/close (not
  just close) to the indicators that need them (ATR, Stochastics).
- **Chart panel rendering:** extend `candlestick_chart.js` so indicators with
  `display: "panel"` render in a new grid below the main chart (one grid per
  panel instance, own y-axis, shared x-axis + dataZoom), instead of as a price
  overlay. Multi-output indicators (Stochastics %K/%D) draw multiple lines in
  their panel.
- **Sidebar:** the existing add/remove/color UI already lists registry types, so
  RSI/MACD/ATR/Stochastics appear automatically once registered. Verify color +
  remove work for panels.
- **Parity tests** for the 4 new indicators vs Python `store.indicators`.

### Out (later slices)

- Envelope indicators BB/Donchian (3c), ZigZag/Spike (3d), key-level detectors
  (3e+). MACD signal/histogram (NautilusTrader's MACD class exposes only the
  MACD line; match that).

## Reference (parity source)

`/Users/mordrax/code/nautilus_automatron/packages/server/server/store/indicators.py`
(the `INDICATOR_TYPES` entries for RSI, MACD, ATR, Stochastics — NautilusTrader
indicator classes) and `client/.../CandlestickChart.tsx` (panel grid layout).

Formulas:
- **RSI:** `RS = AvgGain(period) / AvgLoss(period)`; `RSI = 100 − 100/(1+RS)`; bounded [0,100].
- **MACD:** `EMA(close, fast) − EMA(close, slow)` (line only).
- **ATR:** `TR = max(high−low, |high−prev_close|, |low−prev_close|)`; `ATR = EMA(TR, period)`.
- **Stochastics:** `%K = 100·(close − low[period_k]) / (high[period_k] − low[period_k])`; `%D = SMA(%K, period_d)`.

(Confirm NautilusTrader's exact averaging/seed via parity — RSI/ATR may use a
Wilder smoothing rather than plain EMA. The parity test is authoritative.)

## Components

### 1. `AutomatronEx.Indicators` (extend)

- `rsi(closes, period)`, `macd(closes, fast, slow)`, `atr(highs, lows, closes,
  period)`, `stochastics(highs, lows, closes, period_k, period_d) :: {k_list,
  d_list}` — each `[float | nil]`, `nil` until initialized.
- Add the 4 registry entries (display `"panel"`).
- Extend `compute(bars, instances)`: for ATR/Stochastics pass `bars.high`,
  `bars.low`, `bars.close`; multi-output indicators populate multiple keys in
  `outputs` (e.g. `%{"value_k" => …, "value_d" => …}`).

### 2. `candlestick_chart.js` (extend)

- On `chart:set_indicators`, split series by `display`: `"overlay"` → price axis
  (3a behavior, unchanged); `"panel"` → a dynamically-added grid below the main
  chart. Compute grids/x-axes/y-axes for N panels (height per panel + gap),
  shrinking the main grid; each panel gets its own `yAxis`; all share the
  category x-axis and `dataZoom`. Multi-output → multiple line series in the
  panel. Remove a panel (and reflow) when its instance is removed.

### 3. `RunDetailLive`

No structural change — the sidebar already drives add/remove/color via the
registry and pushes `chart:set_indicators`. Verify panel instances round-trip
through viewer-state like overlays.

## Data flow

Unchanged from 3a: catalog bars → `Indicators.compute` → `push_event
chart:set_indicators` → hook. The hook now routes by `display` (overlay vs
panel-grid). Selections persist via viewer-state.

## Error handling

Same as 3a: unknown type / bad params → skip with logged warning; missing bars →
no series.

## Testing

- **Unit + parity:** `rsi`/`macd`/`atr`/`stochastics` vs Python on the fixture
  5-MINUTE bars (field-by-field, `nil` alignment), via the established
  `read_bars`-decoded-closes-to-both-sides pattern. ATR/Stochastics parity feeds
  high/low/close.
- **LiveView:** add a panel indicator → `assert_push_event "chart:set_indicators"`
  carries `display: "panel"` series; remove drops it; persists.
- **E2E (3b.3):** browser, real catalog — add RSI + MACD, panels render below the
  chart with their own axes; values match the Python chart; parity passes.

## Success criteria

1. RSI, MACD, ATR, Stochastics are addable from the sidebar.
2. Each renders in its own panel grid below the candlesticks (Stochastics shows
   %K and %D).
3. Values match Python for the same bars.
4. Selections persist; overlays (3a) still work alongside panels.
5. Tests pass.

## Beads

| Bead | Content | Depends |
|---|---|---|
| 3b.1 | `Indicators` rsi/macd/atr/stochastics + registry + `compute` dispatch (h/l/c) + parity tests | — |
| 3b.2 | Panel-grid rendering in `candlestick_chart.js` (display-routed) + LiveView/viewer-state verification | 3b.1 |
| 3b.3 | E2E verify (browser + parity) | 3b.2 |

## Open questions / confirm during implementation

- RSI/ATR smoothing (Wilder vs EMA) — match NautilusTrader exactly via parity.
- MACD outputs — line only (no signal/histogram), matching the Python class.
- Panel grid sizing/reflow when multiple panels are active — keep the main chart
  usable; mirror the Python layout proportions.
