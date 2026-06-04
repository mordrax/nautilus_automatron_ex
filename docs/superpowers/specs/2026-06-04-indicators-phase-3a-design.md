# Design: Indicators Phase 3a — overlay moving averages + functional sidebar

**Date:** 2026-06-04
**Project:** `nautilus_automatron_ex`
**Status:** Scoped autonomously (user approved Phase 3, "continue unsupervised"). First slice of Phase 3.

## Purpose

Make the inert indicator sidebar on `/runs/:run_id` functional end-to-end for
**overlay moving-average indicators (SMA, EMA, HMA)**: pick, parametrize, color,
persist per run, and render as overlay lines on the candlestick chart. This
establishes the full indicator client↔server flow plus a parity-tested compute
core, on which later slices build.

## Phase 3 decomposition (context)

The Python engine has 11 indicators + 25 key-level detectors. Phase 3 is sliced:

| Slice | Content |
|---|---|
| **3a (this spec)** | SMA, EMA, HMA overlays + functional sidebar + viewer-state + chart overlay rendering |
| 3b | Panel oscillators: RSI, MACD, ATR, Stochastics (separate chart grids) |
| 3c | Envelope: Bollinger Bands, Donchian (multi-output) |
| 3d | ZigZag, Spike (stateful, sparse series) |
| 3e+ | Key-level detectors, simple → heavy (pivots, psychological, equal-highs-lows … volume-profile, Wyckoff) |

Each later slice reuses 3a's registry, viewer-state, compute-dispatch, and chart
plumbing; it only adds compute functions + render modes.

## Scope (3a)

### In

- **Indicator compute (pure):** `sma`, `ema`, `hma` over a close series,
  `nil`-padded until initialized. Parity with the Python/NautilusTrader output.
- **Indicator registry:** the 3 types, `display: "overlay"`, `outputs: ["value"]`,
  param `period: int [2,500] default 20`.
- **Compute dispatch:** `compute(bars, instances)` where `instances = [%{id, type,
  params}]` → `[%{id, label, display, outputs: %{"value" => [...]}, datetime: [...]}]`
  (the Python `IndicatorResult` shape). Bars via `Reader.read_bars`.
- **Viewer-state:** per-run persistence of selected indicator instances (an Ash
  Postgres resource keyed on `run_id`). Loaded on mount, saved on change. This
  mirrors the Python `GET/PUT /viewer-state`.
- **Functional sidebar** in `RunDetailLive`: replace the inert shell — add /
  remove / set-period / color SMA/EMA/HMA; on change recompute, push overlay
  series to the chart hook, persist.
- **Chart overlay rendering:** extend `candlestick_chart.js` to add/update/remove
  overlay line series (one per indicator).
- **Parity tests** vs the Python compute on the fixture bars.

### Out (later slices)

- Panel / envelope / ZigZag / Spike indicators (3b–3d); all key-level detectors
  (3e+). Indicator color persisted in `localStorage` on the Python side — here
  color lives in viewer-state (documented minor divergence).

## Locked decisions

1. **Compute in pure Elixir** (`AutomatronEx.Indicators`), parity with Python.
   Match Python's initialization (`nil` until the window fills).
2. **Viewer-state is app-owned state → persisted in Postgres** (Ash), unlike the
   read-through catalog data. Keyed on `run_id`.
3. **Delivery via `push_event`** (same pattern as the chart): LiveView computes
   indicator series and pushes them to the hook. No REST API.
4. **Match the existing sidebar UX** (add indicator, edit period, color, remove).

## Components

### 1. `AutomatronEx.Indicators` (pure)

- `sma(closes, period)`, `ema(closes, period)`, `hma(closes, period)` →
  `[float | nil]` aligned to `closes`, `nil` until initialized.
  - SMA = mean of the last `period` closes.
  - EMA: `α = 2/(period+1)`; `EMA_i = α·close_i + (1-α)·EMA_{i-1}`; seed per
    NautilusTrader (confirm via parity).
  - HMA = `WMA(2·WMA(closes, period/2) − WMA(closes, period), round(√period))`.
- `registry/0` → the 3 indicator type specs (type, label_template, display,
  outputs, params).
- `compute(bars, instances)` → list of `IndicatorResult` maps; `label` formatted
  from the template + params (e.g. `"SMA(20)"`); `datetime` from `bars.datetime`.

### 2. Viewer-state resource (AshPostgres)

`AutomatronEx.Runs.ViewerState` (or `Runs.RunViewerState`): `run_id` (string,
identity), `indicators` (jsonb: `[%{id, type, params, color}]`). Actions:
`get_by_run`, `upsert`. Migration. (Detectors field reserved for 3e; omit now.)

### 3. `RunDetailLive` sidebar

On mount: load `Indicators.registry/0` + viewer-state for the run. Render an
indicator selector replacing the inert shell: a list of active instances (type,
period, color, remove), and an "add" control for SMA/EMA/HMA. On any change:
recompute via `Indicators.compute`, `push_event("chart:set_indicators", %{series:
…})`, and upsert viewer-state. Re-push indicators after `chart:init` on reconnect.

### 4. `candlestick_chart.js`

`handleEvent("chart:set_indicators", %{series})` → add/update overlay line series
(`type: "line"`, `xAxisIndex: 0`, `yAxisIndex: 0`, `connectNulls: true`,
per-instance color, `showSymbol: false`), keyed by instance id; remove series for
instances no longer present. Preserve the existing candlestick + trade markLines.

## Data flow

```
catalog bars → Reader.read_bars → Indicators.compute(instances)
  → RunDetailLive → push_event chart:set_indicators → hook overlay lines
selections ⇄ Postgres viewer-state (load on mount, upsert on change)
```

## Error handling

- Unknown indicator type / bad params → skip that instance with a logged warning;
  others still compute.
- No bars for the run's bar_type → sidebar still renders; no overlay series.

## Testing

- **Indicators unit + parity:** `sma`/`ema`/`hma` vs Python on the fixture
  5-MINUTE bars (field-by-field, `nil` alignment). Python reference via
  `server.store.indicators` compute (same approach as the metrics/reader parity).
- **Viewer-state:** upsert/get round-trip; persists across remount.
- **LiveView:** add an indicator → `assert_push_event "chart:set_indicators"` with
  the series; remove → series dropped; viewer-state persisted and reloaded.
- **E2E (3a.4):** browser, real catalog — add EMA(20), overlay line renders and
  matches the Python chart; parity suite passes.

## Beads

| Bead | Content | Depends |
|---|---|---|
| 3a.1 | `AutomatronEx.Indicators` (SMA/EMA/HMA) + registry + `compute/2` + parity tests | — |
| 3a.2 | Viewer-state Ash resource + migration + tests | — |
| 3a.3 | Functional sidebar in `RunDetailLive` + chart overlay rendering + wire compute/persist + LiveView tests | 3a.1, 3a.2 |
| 3a.4 | E2E verify (browser + parity) | 3a.3 |

## Success criteria

1. The sidebar adds SMA/EMA/HMA, sets period, sets color; an overlay line renders
   on the chart.
2. Selections persist per run (reload shows them).
3. SMA/EMA/HMA values match Python for the same bars.
4. Tests pass.

## Open questions / confirm during implementation

- EMA/HMA exact initialization semantics vs NautilusTrader — confirm via the
  parity test (fix `nil`-prefix length to match).
- Python indicator color source is `localStorage`; here color persists in
  viewer-state — documented divergence, not a parity break.
