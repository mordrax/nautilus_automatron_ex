# Phase 3a E2E verification — overlay indicators vs Python

**Bead:** `nae-38s.4` (final bead of Phase 3a)
**Date:** 2026-06-04
**Verifier branch:** `bead/nae-38s.4-e2e-verify`
**Code under test:** `main` @ `ec02f58` (merge of `nae-38s.3` — functional indicator
sidebar + chart overlay rendering)

**Verdict: PASS.** The indicator sidebar adds SMA/EMA/HMA overlays on the real
catalog; the overlay lines render on the candlestick chart (colored, following
price); the rendered values match the Python `server.store.indicators` compute
bar-for-bar; selections persist across reload; and `mix test --include parity`
passes. **No discrepancies found, so no bug beads were filed.**

---

## Environment

| | |
|---|---|
| Phoenix app | `PORT=4111 CATALOG_PATH=/Users/mordrax/code/nautilus_automatron/backtest_catalog mix phx.server` |
| Catalog | `/Users/mordrax/code/nautilus_automatron/backtest_catalog` (real) |
| Run | `e4599dab-fd51-4758-9564-c2061bc2104e` (204 positions · 408 fills) |
| Bar type | `XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL` — **4673 bars**, 2026-02-25T23:00 → 2026-03-26T13:00 |
| Python oracle | `packages/server/.venv/bin/python` → `server.store.indicators.INDICATOR_TYPES` |

Ports: used **4111** (alternates per bead note; `4100/5173/8000` left free, mayor
dashboard on `:8080` untouched). Postgres on `:5432` (viewer-state).

---

## Method

1. **Parity suite** — `mix test --include parity` (SMA/EMA/HMA vs Python on the
   fixture 5-MINUTE bars).
2. **Value parity on the real run** — extracted the run's 4673 closes via the
   production `Reader.read_bars/2`, computed SMA/EMA/HMA(20) with
   `AutomatronEx.Indicators.compute/2`, and ran the **identical** closes through
   the Python `server.store.indicators` compute (`test/support/py_ref_indicators.py`
   — the exact code path the Python chart renders). Compared field-by-field.
3. **Runtime rendering** — drove the live sidebar in Chrome (add EMA(20), SMA(20),
   HMA(20)); read the live ECharts series back through the LiveView hook to confirm
   the chart draws the parity-verified values.
4. **Persistence** — full page reload; confirmed sidebar + overlays + colors reload
   from viewer-state.
5. **Probes** — live period change and indicator removal.

> **Note on the "Python page":** the bead suggests booting the Python client
> (`bun run dev`, `:5173`) and eyeballing the two charts. Instead this verification
> runs the run's closes through `server.store.indicators` directly — the same
> compute the Python chart renders — which yields an **exact numeric** side-by-side
> (below) rather than a visual approximation. The Python client UI was therefore
> not booted; the comparison is against its underlying compute, which is the
> substantive "matches the Python chart's EMA" claim.

---

## 1. Parity test suite

```
$ mix test --include parity
Including tags: [:parity]
..................................................................................................................
Finished in 6.2 seconds (0.2s async, 5.9s sync)
114 tests, 0 failures
```

✅ Full suite green with `:parity` included (114 tests, 0 failures).

## 2. Value parity on the real run (Elixir `compute/2` vs Python `store.indicators`)

Identical 4673 closes through both engines, period 20:

| Indicator | nil-prefix (Ex/Py) | max \|Δ\| | max relΔ | result |
|---|---|---|---|---|
| SMA(20) | 19 / 19 | 0.000e+00 | 0.000e+00 | ✅ exact |
| EMA(20) | 19 / 19 | 1.819e-12 | 4.18e-16 | ✅ (float noise ≪ 1e-6) |
| HMA(20) | 19 / 19 | 3.638e-12 | 7.74e-16 | ✅ (float noise ≪ 1e-6) |

Sample bars (Elixir | Python, both period 20):

| idx | datetime (UTC) | SMA Ex | SMA Py | EMA Ex | EMA Py | HMA Ex | HMA Py |
|---|---|---|---|---|---|---|---|
| 19   | 2026-02-26 00:35 | 5172.20700 | 5172.20700 | 5174.10879 | 5174.10879 | 5176.51938 | 5176.51938 |
| 20   | 2026-02-26 00:40 | 5172.83900 | 5172.83900 | 5175.49271 | 5175.49271 | 5180.35581 | 5180.35581 |
| 100  | 2026-02-26 07:20 | 5193.64800 | 5193.64800 | 5192.41286 | 5192.41286 | 5187.91610 | 5187.91610 |
| 1000 | 2026-03-04 12:15 | 5192.98200 | 5192.98200 | 5192.29374 | 5192.29374 | 5196.04771 | 5196.04771 |
| 2336 | 2026-03-12 06:30 | 5150.79850 | 5150.79850 | 5152.91727 | 5152.91727 | 5157.43965 | 5157.43965 |
| 4672 | 2026-03-26 13:00 | 4436.41650 | 4436.41650 | 4435.94967 | 4435.94967 | 4435.94111 | 4435.94111 |

✅ Identical to 5 decimals across the series; max divergence is `~1e-12`
floating-point noise. The `nil` initialization prefix (19 = period − 1) matches.

## 3. Runtime chart rendering (live ECharts series read back through the hook)

After adding EMA(20), SMA(20), HMA(20) via the sidebar, the chart's ECharts option
held one candlestick + three overlay line series:

```json
[
  {"id":"candlestick","type":"candlestick","name":"Candlestick","n":4673},
  {"id":"ind-1026", "type":"line","name":"SMA(20)","n":4673,"color":"#2563eb","connectNulls":true,"showSymbol":false,"nilPrefix":19,
   "samples@[19,100,1000,4672]":[5172.206999,5193.647999,5192.982,4436.4165]},
  {"id":"ind-11394","type":"line","name":"EMA(20)","n":4673,"color":"#dc2626","connectNulls":true,"showSymbol":false,"nilPrefix":19,
   "samples@[19,100,1000,4672]":[5174.108787,5192.412856,5192.293739,4435.949673]},
  {"id":"ind-11458","type":"line","name":"HMA(20)","n":4673,"color":"#16a34a","connectNulls":true,"showSymbol":false,"nilPrefix":19,
   "samples@[19,100,1000,4672]":[5176.519378,5187.916096,5196.047705,4435.941113]}
]
```

✅ Three overlay line series, one per instance, each 4673 points (aligned to bars),
`connectNulls:true` (bridges the nil prefix), `showSymbol:false`, distinct palette
colors. **The rendered `data` values are exactly the parity-verified compute** —
sample values at idx 19/100/1000/4672 match the table in §2 to the digit. HMA is
visibly the most responsive line, SMA the smoothest, EMA between — the expected MA
ordering. The candlestick + trade markLines remain intact beneath the overlays.

## 4. Persistence (viewer-state)

Full page reload of `/runs/e4599dab…`:

- Sidebar reloads all instances: `SMA(20)/#2563eb`, `EMA(20)/#dc2626`, `HMA(20)/#16a34a`.
- Chart re-renders all three overlay lines with identical values (re-pushed after
  `chart:init`).
- ✅ Confirmed twice — once on the initial selection and once after the probes
  below (a post-mutation state survived reload).

## 5. Probes (beyond the happy path)

- 🔍 **Live period change** SMA 20 → 50: series relabels to `SMA(50)`, nil-prefix
  moves to 49, `data[19]` becomes `null`, `data[49]=5180.561`, `data[100]=5193.924`.
  Independently recomputed from the raw closes: SMA(50)[49]=`5180.561`,
  SMA(50)[100]=`5193.924` — ✅ exact. Recompute-on-edit is correct.
- 🔍 **Remove indicator** (HMA): the green line drops (chart back to candlestick +
  2 lines), sidebar shrinks to 2 rows, and the candlestick + current zoom are
  preserved (clean `replaceMerge` on `series`). ✅
- 🔍 **Browser console**: no errors or warnings across all add/remove/edit/reload
  actions — only the LiveView `CONNECTED` info line. ✅

---

## Documented divergences (expected, not bugs)

- **Indicator color** persists in **viewer-state (Postgres)** here, vs the Python
  client's `localStorage`. Intentional per the Phase 3a spec (§Out / locked
  decision); not a parity break.
- **Chart x-axis** renders in **UTC** (matches the trades table) vs the React
  reference's local time — pre-existing, documented in `candlestick_chart.js`
  (`nae-t2x`).

## Environment notes (pre-existing, unrelated to Phase 3a)

- The Phoenix server log emits `CategoricalRemappingWarning` from Polars/Explorer
  while reading the catalog feather files (categorical columns). This originates in
  the catalog data-layer read, not the indicator code, and predates this work. No
  Elixir errors or crashes occurred during verification.

## Conclusion

All four success criteria of the Phase 3a spec are met on the real catalog:
sidebar adds/edits/colors SMA/EMA/HMA and an overlay line renders; selections
persist per run across reload; SMA/EMA/HMA values match Python; tests pass.
**No discrepancies → no bug beads filed.**
