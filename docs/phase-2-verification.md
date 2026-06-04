# Phase 2 — E2E parity verification vs the real catalog

**Bead:** `nae-1sz.4` (P2-D) · **Verified commit:** `6e5fa2c` (main, post P2-A/B/C merge) · **Date:** 2026-06-04

Verifies `/runs/:run_id` (candlestick chart + trade overlays + navigator + trades
table) against the **real** NautilusTrader catalog and the existing Python/React
page it is meant to match.

- **Run:** `e4599dab-fd51-4758-9564-c2061bc2104e` (EMACross on `XAUUSD.IBCFD`)
- **Catalog:** `/Users/mordrax/code/nautilus_automatron/backtest_catalog`
- **Elixir app:** `CATALOG_PATH=<catalog> PORT=4000 mix phx.server` → `http://localhost:4000/runs/<run>`
  (ports 4100/8080 left untouched — mayor's demo/dashboard)
- **Python reference:** `NAUTILUS_STORE_PATH=<catalog>` uvicorn server `:8000` + Vite client `:5173`
  → `http://localhost:5173/runs/<run>`

## Method

1. Booted the Elixir app on the real catalog; drove the live page in Chrome
   (LiveView websocket connected), inspecting the DOM and the rendered eCharts canvas.
2. Booted the Python server + React client on the same catalog; opened the same run.
3. Compared header counts, bar data, trade data, colors, and chart behavior.
4. Ran `mix test --include parity` (field-by-field Elixir reader vs Python projection).
5. Pulled the Python `/api` JSON directly for an exact numeric side-by-side.

## Data parity — `mix test --include parity`

```
Including tags: [:parity]
87 tests, 0 failures
```

The parity suite asserts `read_trades` and `read_bars` are **field-by-field identical**
to the Python `/trades` and `/bars` projections for run `e4599dab`, over the **real**
catalog, for **both** bar types. PASS — zero field mismatches.

## Side-by-side (run `e4599dab`)

| Field | Elixir `/runs/:id` (`:4000`) | Python/React (`:8000`/`:5173`) | Match |
|---|---|---|---|
| total_positions | 204 | 204 | ✅ |
| total_fills | 408 | 408 | ✅ |
| trade count (table) | 204 | 204 | ✅ |
| trade #1 | Long, `2026-02-26T00:40:00Z`→`02:35:00Z`, 5182.76→5178.98, qty 1.0, pnl **-3.98**, USD | identical (UTC) | ✅ |
| trade #204 | (n/a in default view) | Short, `2026-03-26T12:55Z`→`2026-03-27T05:47Z`, 4432.94→4464.48, pnl **-31.72** | ✅ (data) |
| 5-MIN bar count | 4673 | 4673 | ✅ |
| 1-MIN bar count | 29754 (data parity ✅) | 29754 | ✅ |
| candle colors | up `#7FD373` / down `#F68EA3`, borders `#2B6D22`/`#970C28` | same `CHART_COLORS` (`chart-config.ts`) | ✅ |
| trade markLine colors | win `#7FD373` / loss `#F68EA3` | same | ✅ |
| **bar_types list** | `[5-MIN]` (config-derived) | `[1-MIN, 5-MIN]` (data-derived, sorted) | ❌ `nae-e6u` |
| **default chart bar type** (`bar_types[0]`) | **5-MIN** (4673 bars) | **1-MIN** (29754 bars) | ❌ `nae-e6u` |
| **bar-type chips** | 5-MIN only | both (1-MIN + 5-MIN) | ❌ `nae-e6u` |
| **trade datetime display** | UTC (`2026-02-26 00:40`) | local browser time (`Feb-26 11:40`, +11h) | ❌ `nae-t2x` |
| **chart focus on load** | most-recent ~50 bars (Mar 26–27) | centered on selected trade #1 (Feb 26) | ❌ `nae-g9c` |
| **chart after navigating a trade** | **canvas destroyed → blank** | navigates fine | ❌ `nae-ji0` |

## What matched (parity confirmed)

- **Counts:** 204 positions, 408 fills, 204 trades — exact.
- **Per-trade fields:** relative_id, position_id, instrument_id, direction, currency,
  entry/exit datetime (UTC value), entry/exit price, quantity, pnl — exact (parity suite
  + direct `/api/.../trades` JSON comparison; trade #1 identical to the byte).
- **Per-bar OHLCV + datetime:** exact for both bar types (parity suite, 4673 + 29754 bars).
- **Colors:** the hook's constants are the same `CHART_COLORS` the React app uses
  (`assets/js/hooks/candlestick_chart.js` ⟷ `packages/client/src/lib/chart-config.ts`).
- **Candlestick + trade markLines render** on the Elixir page on initial load (verified
  visually: green/pink candles, entry→exit markLines with `#N` labels and triangle ends,
  dataZoom slider). Header counts + bar-type chip render server-side.

## Visual observations

- **Elixir (`:4000`)** — dark (daisyUI) theme. On load: header "204 positions · 408 fills",
  one chip `XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL`, candlestick chart defaulting to the most
  recent ~50 bars (markLines `#201`/`#202`/`#203` visible), navigator "Trade 1 / 204",
  204-row trades table, inert "Phase 3" indicator sidebar. eCharts canvas 1344×960.
- **React (`:5173`)** — light theme. On load: "204 positions", "408 fills", **two** chips
  (1-MIN + 5-MIN), 1-MINUTE candlestick chart **centered on trade #1** with SMA/EMA
  indicator overlays + RSI subpanel + tooltip, navigator "Trade #1 … Feb-26 11:40 →
  Feb-26 13:35 … −3.98 USD", "Trades (204)" table. (Indicators / secondary panels / tabs /
  categorisation / hotkeys are **out of Phase 2 scope** — deferred to Phase 3 per the spec
  — and are *not* counted as discrepancies.)

## Discrepancies filed (NOT silently fixed)

Per the bead, each discrepancy is a bug bead for review — none were patched on this branch.

| Bead | Pri | Summary |
|---|---|---|
| `nae-ji0` | P1 | **Chart canvas destroyed on trade navigation.** `#run-chart` has `phx-hook` but no `phx-update="ignore"`, so the LiveView re-render on a Prev/Next/select (when `current_index` changes) makes morphdom wipe the hook-created eCharts canvas (`childCount 2→0`, plot goes blank, no console error). Breaks the navigator + zoom-to-trade after the first interaction. `run_detail_live.ex:160`. |
| `nae-e6u` | P2 | **Default chart bar type differs (5-MIN vs 1-MIN) + missing chip.** Elixir derives `bar_types` from the strategy config (`[5-MIN]`); Python derives from the data stream, sorted (`[1-MIN, 5-MIN]`). Both use `bar_types[0]`, so the default charts show different granularity (4673 vs 29754 bars) and Elixir omits the 1-MIN chip. Bar **data** parity is exact; only the `bar_types` set/order differs. |
| `nae-t2x` | P3 | **Trade datetimes in UTC (Elixir) vs local time (React)**, and inconsistent with the Elixir chart x-axis (which uses local time via the ported `formatDatetime`). Timezone-dependent. |
| `nae-g9c` | P3 | **Chart not focused on the selected trade at load.** React centers on trade #1; Elixir shows the latest bars while the navigator points at trade #1. (Entangled with `nae-ji0`.) |

## Verdict

**Data layer: PASS.** Counts and every per-bar/per-trade field are exact vs the Python
reference (`mix test --include parity` 87/0, plus direct `/api` JSON comparison). The
Elixir page renders the candlestick + trade overlays with the correct colors on load.

**UI parity: PASS WITH DISCREPANCIES.** Four behavioral mismatches vs the React page are
filed as bug beads above — most importantly `nae-ji0` (P1), where navigating a trade
destroys the chart. None were silently fixed; the branch is left for review.
