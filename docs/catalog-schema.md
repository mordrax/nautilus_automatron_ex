# NautilusTrader catalog schema (recon)

Schema reconnaissance for the real NautilusTrader catalog the Elixir reader must
parse. Resolves the design spec's open question — *"Exact Nautilus feather column
names/encodings — confirm against the real files during implementation"*
([2026-06-03-foundation-readonly-dashboard-design.md](superpowers/specs/2026-06-03-foundation-readonly-dashboard-design.md)).

- **Source catalog:** `/Users/mordrax/code/nautilus_automatron/backtest_catalog`
- **Method:** read every file with Explorer (`mix run --no-start`) and inspect
  `names/1`, `dtypes/1`, `shape/1`, plus sample rows. Cross-referenced against the
  Python reader (`packages/server/server/store/{reader,catalog_reader,metrics,transforms}.py`).
- **Dtypes** are written in Explorer's notation: `:category`, `:string`,
  `{:f, 64}` (f64), `{:u, 64}` (u64), `{:u, 8}` (u8), `:binary`, `:boolean`.

## Catalog layout

```
backtest_catalog/
  backtest/<run_id>/              # one dir per backtest run; <run_id> is a UUID
    config.json                   # full Nautilus engine config for the run
    position_closed_0.feather     # closed positions  (metrics source)
    order_filled_0.feather        # order fills        (count this phase)
    account_state_0.feather       # account snapshots
    <~40 other *_0.feather>       # all other Nautilus event/instrument types
    bar/                          # (some runs) run-local bar snapshots — ignored
  data/
    bar/<bar_type>/*.parquet      # input market data: OHLCV bars  (instrument catalog)
    currency_pair/<instr>/*.parquet  # instrument definitions
```

This phase reads only: per-run `config.json`, `position_closed_0.feather`,
`order_filled_0.feather`; and `data/bar/`. Everything else is documented for
context but unused until later phases.

> **Real catalog snapshot (3 runs):** `017f6297-…` (0 closed positions,
> `BBBStrategy`), `e4599dab-…` (204 positions, `EMACross`), `fbaf897e-…`
> (238 positions, `BBBStrategy`). All share `trader_id = "BACKTESTER-001"`,
> instrument `XAUUSD.IBCFD`.

## ⚠️ Read format: Arrow IPC **stream**, not IPC file

The `.feather` files are Arrow IPC **stream** format. Explorer's `from_ipc/2`
(IPC *file*) **fails** on them; `from_ipc_stream/2` succeeds:

```elixir
Explorer.DataFrame.from_ipc_stream!(path)   # ✅ feathers
Explorer.DataFrame.from_parquet!(path)      # ✅ data/ parquet
```

Reading multi-batch feathers with `:category` columns emits many
`CategoricalRemappingWarning` lines on stderr (Polars re-encoding per record
batch). They are noise, not errors — the read succeeds. Suppress in scripts or
ignore.

## `backtest/<run_id>/config.json`

Plain JSON: the serialized `BacktestEngineConfig`. ~30 top-level keys; the app
uses a handful:

| Key | Example | Use |
|---|---|---|
| `trader_id` | `"BACKTESTER-001"` | `Run.trader_id` |
| `strategies` | list (below) | `Run.strategy` source |
| `streaming.catalog_path` | the catalog path | informational |
| `environment` | `"backtest"` | informational |

`strategies` is a list of `{strategy_path, config_path, config}`:

```json
{
  "strategy_path": "nautilus_trader.examples.strategies.ema_cross:EMACross",
  "config_path":   "nautilus_trader.examples.strategies.ema_cross:EMACrossConfig",
  "config": { "instrument_id": "XAUUSD.IBCFD",
              "bar_type": "XAUUSD.IBCFD-1-MINUTE-MID-EXTERNAL", ... }
}
```

For `Run.strategy`, use the class name after `:` in `strategies[0].strategy_path`
(`EMACross`, `BBBStrategy`). The same identity also appears as `strategy_id` in
the event feathers, suffixed with an instance index (`EMACross-000`).

## `backtest/<run_id>/position_closed_0.feather` — 24 cols

Metrics source (`Automatron.Catalog.Metrics`). **All needed numeric/time columns
are already native** (f64 / u64) — no string parsing required.

| Column | Dtype | Notes |
|---|---|---|
| trader_id, account_id, strategy_id, instrument_id | `:category` | identity |
| position_id, opening_order_id, closing_order_id | `:string` | |
| entry | `:string` | `"BUY"` / `"SELL"` |
| side | `:string` | `"FLAT"` for closed positions |
| signed_qty, quantity, peak_qty, last_qty, last_px | `{:f, 64}` | |
| currency | `:string` | `"USD"` |
| avg_px_open, avg_px_close, realized_return | `{:f, 64}` | |
| **realized_pnl** | `{:f, 64}` | **metrics: pnl** |
| event_id | `:string` | |
| **ts_opened** | `{:u, 64}` | **metrics: ns since epoch** |
| **ts_closed** | `{:u, 64}` | **metrics: ns since epoch** |
| **duration_ns** | `{:u, 64}` | **metrics: hold duration (ns)** |
| ts_init | `{:u, 64}` | |

**Projection for metrics:** `realized_pnl`, `ts_opened`, `ts_closed`,
`duration_ns` — matches the Python `compute_run_metrics` inputs
(`p.realized_pnl`, `p.ts_opened`, `p.ts_closed`, `p.duration_ns`). `total_positions`
= row count.

A run with **0 closed positions** yields a valid 0-row dataframe with this exact
24-col schema → drives the `empty_metrics` (all-nil) branch.

## `backtest/<run_id>/order_filled_0.feather` — 20 cols

This phase uses the **row count only** (`Run.total_fills`). Detail is for later.

| Column | Dtype | Notes |
|---|---|---|
| trader_id, strategy_id, account_id, instrument_id | `:category` | identity |
| order_side, order_type | `:category` | `"BUY"`/`"SELL"`, `"MARKET"`… |
| client_order_id, venue_order_id, trade_id, position_id | `:string` | |
| **last_qty** | `:string` | ⚠️ numeric **stored as string** (`"1"`) |
| **last_px** | `:string` | ⚠️ numeric **stored as string** (`"5182.76"`) |
| currency | `:string` | `"USD"` |
| **commission** | `:string` | ⚠️ value **and** currency: `"0.10 USD"` |
| liquidity_side | `:string` | `"TAKER"` / `"MAKER"` |
| event_id | `:string` | |
| ts_event, ts_init | `{:u, 64}` | ns since epoch |
| info | `:binary` | JSON blob, usually `"{}"` |
| reconciliation | `:boolean` | |

⚠️ Unlike `position_closed` (f64 prices), `order_filled` stores `last_qty`,
`last_px`, `commission` as **strings**; `commission` is `"<amount> <currency>"`
(split on space). Parse only when fill detail is needed (later phase).

## `backtest/<run_id>/account_state_0.feather` — 16 cols (brief)

Not on this phase's read path. Schema for reference:

| Column | Dtype |
|---|---|
| account_id, account_type, base_currency | `:category` |
| balance_total, balance_locked, balance_free | `{:f, 64}` |
| balance_currency | `:category` |
| margin_initial, margin_maintenance | `{:f, 64}` (nilable) |
| margin_currency, margin_instrument_id | `:category` (nilable) |
| reported | `:boolean` |
| info | `:binary` |
| event_id | `:string` |
| ts_event, ts_init | `{:u, 64}` |

## `data/bar/<bar_type>/*.parquet` — 7 cols

Input OHLCV bars (instrument catalog). Per-`bar_type` directory; **one or more**
parquet files per directory (the real 1-MINUTE type has 2 files).

| Column | Dtype | Notes |
|---|---|---|
| open, high, low, close, volume | `:binary` | ⚠️ raw i128 — **not** float (decode below) |
| ts_event | `{:u, 64}` | bar timestamp, ns since epoch |
| ts_init | `{:u, 64}` | |

### ⚠️ OHLCV binary decode (verified)

Each OHLCV cell is a **16-byte little-endian signed 128-bit integer** (Nautilus
high-precision build). Convert to a price by dividing by **10¹⁶**
(`FIXED_PRECISION = 16`):

```elixir
<<raw::little-signed-128>> = open_binary
price = raw / 1.0e16
```

Verified against the real 5-MINUTE file (cross-checked vs the f64 prices in
`position_closed`, gold ≈ 5100–5200):

| `open` bytes (LE) | raw i128 | `/10¹⁶` |
|---|---|---|
| `<<0,64,242,16,199,195,171,206,2,0,0,0,0,0,0,0>>` | `51785700000000000000` | `5178.57` |

`close[i] == open[i+1]` holds (continuous MID bars). `volume` raw = `0` (synthetic
MID bars carry no volume). Decoding is **not needed this phase** (instrument
catalog needs only counts/timestamps) but is required for the Phase 2 chart.

### `bar_type` directory-name encoding

Directory name = the Nautilus `BarType` string:

```
XAUUSD.IBCFD-1-MINUTE-MID-EXTERNAL
└── instrument_id ┘ └ step ┘ └ agg ┘ └price┘ └ source ┘
   {symbol}.{venue}
```

Parsing (port of `transforms._parse_timeframe` / `_parse_venue`):

- **timeframe** = strip the `"<instrument_id>-"` prefix →
  `"1-MINUTE-MID-EXTERNAL"`.
- **venue** = segment after the last `.`, up to the first `-` →
  `IBCFD`. (`nil` if no `.`.)
- **instrument_id** = the directory-name prefix up to where the timeframe begins,
  i.e. `XAUUSD.IBCFD`. The Python code reads it from the parsed `BarType`; the
  Elixir reader derives it from the directory name. ⚠️ FX-pair symbols have `/`
  **stripped** on disk (see `currency_pair` below), so a directory-derived
  instrument_id may differ from the in-event `instrument_id` for slashed symbols.

### parquet filename encoding

`{ts_min}_{ts_max}.parquet`, each timestamp formatted
`YYYY-MM-DDTHH-MM-SS-nnnnnnnnnZ` (UTC; `:` → `-`; 9-digit nanoseconds), e.g.
`2026-02-25T23-05-00-000000000Z_2026-03-26T13-05-00-000000000Z.parquet`.

⚠️ The filename is **not** the source of truth for the date range — the Python
reader computes `ts_min`/`ts_max` from the data (`min/max ts_event`) and
`bar_count`/`file_count` by scanning, summing across **all** parquet files in the
directory. Mirror that: aggregate over every `*.parquet`, don't trust one filename.

### Reader output per bar_type (port of `reader.list_catalog_entries`)

`instrument_id`, `bar_type` (dir name), `bar_count` (Σ rows), `ts_min`, `ts_max`
(over `ts_event`), `file_count`, `path`, plus derived `timeframe`, `venue`. The
API/`InstrumentData` shape (`transforms.catalog_entry_to_dict`) renders
`ts_min`/`ts_max` as ISO-8601 `start_date`/`end_date`.

## `data/currency_pair/<instrument>/*.parquet` — 23 cols (instrument defs)

Instrument definitions. **Not read by this phase** (the instrument catalog scans
`data/bar/` only) — documented for the `data/` layout.

- ⚠️ Directory name **strips `/`** from the symbol: instrument id `"XAU/USD.SIM"`
  (column `id`) lives in directory `XAUUSD.SIM`. The on-disk `XAUUSD.IBCFD` has
  no slash to strip. This is why bar directory names can't be reversed back into
  a slashed `instrument_id` for FX pairs.
- Key columns: `id` `:category`, `raw_symbol` `:string`, `base_currency`/
  `quote_currency` `:category`, `price_precision`/`size_precision` `{:u, 8}`,
  increments/sizes (`:category` strings like `"0.01"`), `margin_*`/`*_fee`
  `:string`, `info` `:binary`, `ts_event`/`ts_init` `{:u, 64}` (= `0`).

## Timestamps & numeric conventions

- All `ts_*` columns are **`u64` nanoseconds since the Unix epoch** (UTC).
  Elixir: `DateTime.from_unix!(ns, :nanosecond)`. Python `_ns_to_iso` divides by
  `1e9` then `.isoformat()` (UTC) — match with `DateTime.from_unix!/2` +
  `DateTime.to_iso8601/1`.
- Instrument-definition and initial `account_state` rows use `ts_event = 0`.
- Metrics constants (from `metrics.py`): `NS_PER_WEEK = 7*86_400*1_000_000_000`;
  hold hours = `duration_ns / 3_600_000_000_000`; Sharpe groups `realized_pnl`
  by UTC calendar month and annualizes by `sqrt(12)`.

## Reader/Metrics mapping summary

| Elixir field | Source |
|---|---|
| `Run.run_id` | `backtest/` directory name |
| `Run.trader_id` | `config.json` → `trader_id` |
| `Run.strategy` | `config.json` → `strategies[0].strategy_path` (class after `:`) |
| `Run.total_positions` | `position_closed_0.feather` row count |
| `Run.total_fills` | `order_filled_0.feather` row count |
| `RunMetric.*` | `Metrics` over `position_closed` projection (see above) |
| `InstrumentData.*` | `data/bar/` scan (see reader output above) |

## Fixture catalog

A small, real, Explorer-readable fixture is committed at
[`test/support/fixtures/catalog/`](../test/support/fixtures/catalog/) for the
reader/metrics/LiveView tests. See its
[`README.md`](../test/support/fixtures/catalog/README.md). Regenerate with:

```bash
mix run --no-start test/support/fixtures/catalog/generate.exs
```

Contents (~221 KiB total, < 1 MB):

- `backtest/017f6297-…/` — empty run (0 positions), feathers copied verbatim →
  zero-position metrics branch.
- `backtest/e4599dab-…/` — populated run, **all 204 positions / 408 fills kept**
  (Explorer-re-encoded) → metrics computed on the fixture equal the real run's
  numbers (parity test material).
- `data/bar/XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL/` — one parquet truncated to 300
  bars; output filename regenerated to the Nautilus `{ts_min}_{ts_max}` convention.

## Gotchas checklist

1. Feathers are IPC **stream** — use `from_ipc_stream/2`, never `from_ipc/2`.
2. `CategoricalRemappingWarning` spam on category-heavy feathers is harmless.
3. Bar `open/high/low/close/volume` are **raw i128 binary** (÷10¹⁶), not floats.
4. `order_filled` `last_qty`/`last_px`/`commission` are **strings**; `commission`
   carries its currency (`"0.10 USD"`).
5. FX symbols have `/` **stripped** in `data/` directory names.
6. `bar_count`/`ts_min`/`ts_max`/`file_count` come from the **data**, aggregated
   across all parquet files — not from filenames.
7. `position_closed` may have **0 rows** (valid schema) → all-nil metrics.
