# Phase 3b — E2E verification: panel oscillators vs Python

**Bead:** `nae-7rs.3` · **Spec:** `docs/superpowers/specs/2026-06-04-indicators-phase-3b-design.md`
**Code under test:** `main` (3b.1 compute + 3b.2 panel rendering merged).

## Verdict

**PASS.** RSI, MACD, ATR, and Stochastics render as panel oscillators in their own
grids below the candlesticks, each with its own y-axis; the Phase 3a overlays
(SMA/EMA/HMA) continue to render on the price axis alongside; and the compute
matches the Python reference. No discrepancies; no bug beads filed.

| # | Success criterion | Result |
|---|---|---|
| 1 | RSI/MACD/ATR/Stochastics addable from the sidebar | ✅ |
| 2 | Each renders in its own panel grid below the candles (Stochastics %K + %D) | ✅ |
| 3 | Values match Python for the same bars | ✅ — parity 0 failures |
| 4 | Selections persist; overlays still work alongside panels | ✅ |
| 5 | Tests pass | ✅ — 134 tests, 0 failures (`--include parity`) |

## 1. Parity (compute matches Python)

`mix test --include parity` → **134 tests, 0 failures.** The
`indicators_parity_test.exs` suite feeds the `Reader.read_bars`-decoded
high/low/close series to **both** the Elixir `AutomatronEx.Indicators` and the
real Python `server.store.indicators.INDICATOR_TYPES` engine (NautilusTrader
classes) and asserts field-by-field equality (within 1e-6) for:

- RSI(14), MACD(12,26), ATR(14), Stochastics(14,3) — including the multi-output
  Stochastics `value_k` / `value_d`, and the `nil` initialization prefix.

The port matches NautilusTrader's actual conventions (verified via parity, not
assumed): **RSI is bounded [0,1]** (not [0,100]), ATR uses a simple moving
average, and %D is the native ratio form.

## 2. Panel rendering on the real catalog (mayor, first-hand)

Booted `CATALOG_PATH=…/backtest_catalog PORT=4100 mix phx.server`, opened
`/runs/e4599dab-…`, and added panel indicators via the sidebar. Observed:

- **RSI(14)** panel below the candles — own y-axis on **[0,1]** (0.2/0.4/0.6/0.8/1),
  orange line oscillating.
- **MACD(12,26)** panel — own y-axis centered on 0 (−2…6), line crossing zero.
- **ATR(14)** panel — own y-axis on the positive range (2…12), declining then flat.
- The three panels **stack** below the main chart, each with an independent
  y-axis, sharing the category x-axis and a single `dataZoom` slider.
- The **SMA/EMA overlays remain on the price axis** above the panels (3a still
  works alongside 3b).
- The trades table renders below all panels; the main candlestick + trade
  markLines are preserved.

## 3. Reflow + multi-output (3b verifier polecat, confirmed)

The `nae-7rs.3` verifier confirmed, before an external Claude-API socket drop
ended its session, that **panel add/remove reflows correctly**: removing the
bottom Stochastics panel shrank the element 1080→930px (480 + 3×150), reduced
the grids 5→4, reassigned y-axes to (price, RSI, MACD, ATR), made ATR the new
bottom panel inheriting the datetime axis labels, and rebuilt the `dataZoom` to
drive x-axes [0,1,2,3]. Stochastics rendered both %K and %D lines in one panel.

## 4. Persistence

Indicator selections (overlays and panels) persist via the per-run
`ViewerState` resource — on reload the chart re-renders the saved set.

## Discrepancies

**None.** Every parity comparison passed (0 failures across 134 tests). No bug
beads filed.

## Process note

The `nae-7rs.3` polecat completed the verification work (panel rendering, reflow,
recompute) but its Claude-API socket dropped mid-task and the session hung before
writing this doc / committing. The mayor re-ran the parity suite, re-confirmed
panel rendering in-browser first-hand, authored this doc from the combined
evidence, and closed the bead.
