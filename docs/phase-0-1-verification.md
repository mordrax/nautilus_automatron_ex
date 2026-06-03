# Phase 0+1 — E2E parity verification vs the real catalog

**Bead:** `nae-46k.8` (final bead of Phase 0+1) ·
**Spec:** [`docs/superpowers/specs/2026-06-03-foundation-readonly-dashboard-design.md`](superpowers/specs/2026-06-03-foundation-readonly-dashboard-design.md) ·
**Date:** 2026-06-04 · **Branch:** `bead/nae-46k.8-e2e-verify`

## Verdict

**All four spec success criteria pass. Zero numeric discrepancies.** The Elixir
app, run against the real NautilusTrader catalog, produces metric values
identical to the Python reference implementation for every metric of every run,
and lists the instrument data with bar counts and date ranges that match the
on-disk parquet ground truth.

| # | Spec success criterion | Result |
|---|---|---|
| 1 | App boots against the real catalog with `CATALOG_PATH` set | ✅ pass |
| 2 | "Sync catalog" populates the runs table; metric values match the Python app's numbers | ✅ pass — 36/36 metric values match (12 metrics × 3 runs) |
| 3 | `/instruments` lists the real instrument data with correct bar counts and date ranges | ✅ pass — 2/2 bar types match ground truth |
| 4 | Metrics unit tests pass | ✅ pass — 28 metrics tests (76 suite-wide), 0 failures |

One **non-blocking observation** (a known, documented, non-metric identity-field
difference in the `strategy` string) is recorded in
[§Observations](#observations-non-blocking). It is not one of the 12 metrics, is
non-numeric, and does not affect any success criterion.

## Catalog under test

`/Users/mordrax/code/nautilus_automatron/backtest_catalog` — three real runs,
all `trader_id = BACKTESTER-001`, instrument `XAUUSD.IBCFD`:

| Run id | Strategy (catalog) | Closed positions | Order fills |
|---|---|---:|---:|
| `e4599dab-fd51-4758-9564-c2061bc2104e` | EMACross | 204 | 408 |
| `fbaf897e-db90-4c15-9445-97ee39c67408` | BBBStrategy | 238 | 476 |
| `017f6297-c633-4419-aa23-bc3fb8171cad` | BBBStrategy | 0 | 0 |

Position/fill counts are independently confirmed from the raw feather row counts
(`position_closed_0.feather`, `order_filled_0.feather`) and match the values the
Elixir `Run` index stored on sync.

## Method

Two **independent** implementations are compared on the **same** input files:

- **Elixir (under test).** Booted with
  `CATALOG_PATH=…/backtest_catalog`, ran the `:sync` action (the same code path
  the dashboard's "Sync catalog" button invokes), then read the values back —
  both from the Postgres `runs` table and from the rendered `/` and
  `/instruments` pages of a live `mix phx.server`. Elixir reads the feathers /
  parquet with Explorer (Polars) and computes metrics with
  `AutomatronEx.Catalog.Metrics`.
- **Python (reference).** The actual app metric code,
  `server.store.metrics.compute_run_metrics`, run against position lists read
  from the same feathers with `pyarrow` (Arrow IPC **stream**). Instrument bar
  counts / date ranges computed directly from the `data/bar/**.parquet` files
  with `pyarrow`.

Because the two stacks read the files independently (Explorer vs pyarrow) and
compute independently (Elixir port vs Python original), agreement on every value
is genuine cross-implementation parity, not a tautology.

Reproduction commands and the exact reference scripts are in
[§Reproduction](#reproduction).

## 1. Boot evidence (criterion 1)

`mix phx.server` with the real catalog booted cleanly and bound the port:

```
[info] Running AutomatronExWeb.Endpoint with Bandit 1.11.1 at 127.0.0.1:4000 (http)
[info] Access AutomatronExWeb.Endpoint at http://localhost:4000
```

`GET /` → HTTP 200 (24,931 bytes) · `GET /instruments` → HTTP 200 (16,443 bytes).
No errors or exceptions in the boot log.

## 2. Sync + metric parity (criterion 2)

`Run.sync!()` against the real catalog returned
`%{synced: 3, skipped: 0, removed: 0}` — all three run dirs indexed, none
skipped. The values below are the Elixir numbers **as rendered on the `/`
dashboard page** (i.e. the full app path: catalog → Explorer → Metrics →
Postgres → LiveView), set side by side with the Python reference.

### Run `e4599dab-…` — EMACross, 204 positions / 408 fills

| Metric | Elixir | Python | Match |
|---|---:|---:|:--:|
| total_pnl | 677.41 | 677.41 | ✅ |
| win_rate | 0.2598 | 0.2598 | ✅ |
| expectancy | 3.32 | 3.32 | ✅ |
| sharpe_ratio | 2.24 | 2.24 | ✅ |
| avg_win | 44.28 | 44.28 | ✅ |
| avg_loss | -11.06 | -11.06 | ✅ |
| win_loss_ratio | 4.0 | 4.0 | ✅ |
| wins | 53 | 53 | ✅ |
| losses | 151 | 151 | ✅ |
| avg_hold_hours | 3.4 | 3.4 | ✅ |
| pnl_per_week | 162.32 | 162.32 | ✅ |
| trades_per_week | 48.88 | 48.88 | ✅ |

### Run `fbaf897e-…` — BBBStrategy, 238 positions / 476 fills

| Metric | Elixir | Python | Match |
|---|---:|---:|:--:|
| total_pnl | -618.15 | -618.15 | ✅ |
| win_rate | 0.5798 | 0.5798 | ✅ |
| expectancy | -2.6 | -2.6 | ✅ |
| sharpe_ratio | -2.14 | -2.14 | ✅ |
| avg_win | 10.9 | 10.9 | ✅ |
| avg_loss | -21.23 | -21.23 | ✅ |
| win_loss_ratio | 0.51 | 0.51 | ✅ |
| wins | 138 | 138 | ✅ |
| losses | 100 | 100 | ✅ |
| avg_hold_hours | 2.0 | 2.0 | ✅ |
| pnl_per_week | -148.06 | -148.06 | ✅ |
| trades_per_week | 57.01 | 57.01 | ✅ |

### Run `017f6297-…` — BBBStrategy, 0 positions / 0 fills

The zero-position branch (`empty_metrics`): every one of the 12 metrics is `nil`
in Elixir (rendered as `—`) and `None` in Python. All 12 match.

| Metric | Elixir | Python | Match |
|---|---:|---:|:--:|
| total_pnl, win_rate, expectancy, sharpe_ratio, avg_win, avg_loss, win_loss_ratio, wins, losses, avg_hold_hours, pnl_per_week, trades_per_week | `nil` (—) | `None` | ✅ (×12) |

**Metric parity total: 36/36 values match.** Identity counts also match:
`total_positions` 204 / 238 / 0 and `total_fills` 408 / 476 / 0 equal the raw
feather row counts.

### Runs dashboard page dump (`/`)

Text extracted from the rendered table (columns: Run · Trader · Strategy ·
Positions · Fills · Total PnL · Win rate · Expectancy · Sharpe · Avg win ·
Avg loss · Win/Loss · Wins · Losses · Avg hold (h) · PnL/wk · Trades/wk):

```
017f6297-… | BACKTESTER-001 | strategies.bbb_strategy:BBBStrategy | 0 | 0 | — | — | — | — | — | — | — | — | — | — | — | —
e4599dab-… | BACKTESTER-001 | nautilus_trader.examples.strategies.ema_cross:EMACross | 204 | 408 | 677.41 | 0.2598 | 3.32 | 2.24 | 44.28 | -11.06 | 4.0 | 53 | 151 | 3.4 | 162.32 | 48.88
fbaf897e-… | BACKTESTER-001 | strategies.bbb_strategy:BBBStrategy | 238 | 476 | -618.15 | 0.5798 | -2.6 | -2.14 | 10.9 | -21.23 | 0.51 | 138 | 100 | 2.0 | -148.06 | 57.01
```

## 3. Instrument listing parity (criterion 3)

Elixir `/instruments` values vs ground truth aggregated directly from the
`data/bar/**.parquet` files (sum of rows; min/max `ts_event` → UTC date):

| Bar type | Field | Elixir (`/instruments`) | Ground truth (parquet) | Match |
|---|---|---|---|:--:|
| `XAUUSD.IBCFD-1-MINUTE-MID-EXTERNAL` | bar_count | 29,754 | 29,754 | ✅ |
| | files | 2 | 2 | ✅ |
| | start_date | 2026-02-25 | 2026-02-25 | ✅ |
| | end_date | 2026-03-27 | 2026-03-27 | ✅ |
| | instrument / venue / timeframe | XAUUSD.IBCFD / IBCFD / 1-MINUTE-MID-EXTERNAL | (dir-name derived) | ✅ |
| `XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL` | bar_count | 4,673 | 4,673 | ✅ |
| | files | 1 | 1 | ✅ |
| | start_date | 2026-02-25 | 2026-02-25 | ✅ |
| | end_date | 2026-03-26 | 2026-03-26 | ✅ |
| | instrument / venue / timeframe | XAUUSD.IBCFD / IBCFD / 5-MINUTE-MID-EXTERNAL | (dir-name derived) | ✅ |

Ground-truth nanosecond bounds (shared `ts_min`; differing `ts_max`):
`ts_min = 1772060400000000000` (2026-02-25T23:00:00Z) for both;
`ts_max = 1774590360000000000` (2026-03-27T05:46:00Z) for 1-MINUTE and
`1774530000000000000` (2026-03-26T13:00:00Z) for 5-MINUTE — exactly the bounds
the Elixir reader produced. The two bar types legitimately end on different
dates, and both implementations agree.

### Instruments page dump (`/instruments`)

Columns: Instrument · Bar type · Timeframe · Venue · Bars · Date range · Files.

```
XAUUSD.IBCFD | XAUUSD.IBCFD-1-MINUTE-MID-EXTERNAL | 1-MINUTE-MID-EXTERNAL | IBCFD | 29754 | 2026-02-25 – 2026-03-27 | 2
XAUUSD.IBCFD | XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL | 5-MINUTE-MID-EXTERNAL | IBCFD | 4673 | 2026-02-25 – 2026-03-26 | 1
```

## 4. Metrics unit tests (criterion 4)

Re-run on this branch:

```
$ mix test test/automatron_ex/catalog/metrics_test.exs
28 tests, 0 failures

$ mix test            # full suite
76 tests, 0 failures
```

The metrics test file is the ported `packages/server/tests/test_metrics.py`
fixtures (numeric parity is the phase's contract); all pass, as does the full
suite (reader, sync, runs, instruments, LiveView).

## Discrepancies

**None.** Every numeric comparison — 36 metric values, 6 position/fill counts,
and all instrument bar-count/date-range fields — matched. No discrepancy bug
beads were filed because there were no numeric mismatches.

## Observations (non-blocking)

**`Run.strategy` string format differs from the Python app for runs with
positions — by design, and out of scope of the success criteria.**

- The Elixir `Sync` (`lib/automatron_ex/runs/sync.ex`) resolves `strategy` from
  `config.strategies[0].strategy_path` (e.g.
  `nautilus_trader.examples.strategies.ema_cross:EMACross`). Its own doc-comment
  explicitly notes it is a "Port of the Python `_extract_strategy_name`, **minus
  the positions_opened path** (the read-only Reader does not load opened
  positions)."
- The Python `_extract_strategy_name`
  (`packages/server/server/store/transforms.py`) prefers
  `str(positions_opened[0].strategy_id)` (e.g. `EMACross-000`) when opened
  positions are present, only falling back to `strategy_path` when they are not.
  For the 0-position run (`017f6297-…`) both implementations therefore agree
  (`strategies.bbb_strategy:BBBStrategy`); for the two populated runs the strings
  differ in format.

Why this is **not** a reported discrepancy:

1. `strategy` is a run **identity** field, not one of the 12 metrics. Success
   criterion 2 concerns "metric values," all of which match.
2. The difference is **non-numeric**; the bead's discrepancy protocol governs
   numeric mismatches.
3. It is a **known, deliberate, documented** omission from a prior merged bead
   (`nae-46k.5`), not a regression discovered here.

Surfaced for the reviewer's awareness per "never silently fix or fudge." If
exact `strategy` parity (loading opened positions to derive `strategy_id`) is
wanted, it should be scoped as its own change, not folded into this verification.

## Reproduction

Prerequisites: Postgres running locally (dev DB `automatron_ex_dev`); the real
catalog at `/Users/mordrax/code/nautilus_automatron/backtest_catalog`; the Python
app's venv at `/Users/mordrax/code/nautilus_automatron/packages/server/.venv`.

```bash
# (criterion 4) unit tests
mix test test/automatron_ex/catalog/metrics_test.exs
mix test

# (criteria 1+2+3) boot, sync, read back — Elixir numbers
mix ecto.migrate
CATALOG_PATH=/Users/mordrax/code/nautilus_automatron/backtest_catalog \
  mix run tmp/verify_sync.exs          # dumps runs + instruments as JSON

# (criterion 1) live server + page dumps
CATALOG_PATH=/Users/mordrax/code/nautilus_automatron/backtest_catalog PORT=4000 mix phx.server
#   then: curl -s localhost:4000/  and  curl -s localhost:4000/instruments

# Python reference (run with the app's venv, cwd = packages/server)
cd /Users/mordrax/code/nautilus_automatron/packages/server
.venv/bin/python <py_reference_metrics.py>        # run metrics
.venv/bin/python <py_reference_instruments.py>    # instrument ground truth
```

The helper scripts live under this repo's `tmp/` (gitignored), so their source
is inlined below for self-contained reproduction.

<details>
<summary><code>py_reference_metrics.py</code> — Python run-metric reference</summary>

```python
import json, sys
from pathlib import Path
from types import SimpleNamespace

CATALOG = Path("/Users/mordrax/code/nautilus_automatron/backtest_catalog")
SERVER_PKG = "/Users/mordrax/code/nautilus_automatron/packages/server"
sys.path.insert(0, SERVER_PKG)
from server.store.metrics import compute_run_metrics
import pyarrow as pa

RUN_IDS = [
    "e4599dab-fd51-4758-9564-c2061bc2104e",
    "fbaf897e-db90-4c15-9445-97ee39c67408",
    "017f6297-c633-4419-aa23-bc3fb8171cad",
]

def read_positions(run_id):
    path = CATALOG / "backtest" / run_id / "position_closed_0.feather"
    if not path.exists():
        return []
    with pa.ipc.open_stream(str(path)) as reader:
        table = reader.read_all()
    if table.num_rows == 0:
        return []
    cols = {c: table.column(c).to_pylist()
            for c in ("realized_pnl", "ts_opened", "ts_closed", "duration_ns")}
    return [SimpleNamespace(realized_pnl=rp, ts_opened=to, ts_closed=tc, duration_ns=dn)
            for rp, to, tc, dn in zip(cols["realized_pnl"], cols["ts_opened"],
                                      cols["ts_closed"], cols["duration_ns"])]

out = {rid: {"n_positions": len(p := read_positions(rid)),
             "metrics": compute_run_metrics(p)} for rid in RUN_IDS}
print(json.dumps(out, indent=2, sort_keys=True))
```
</details>

<details>
<summary><code>py_reference_instruments.py</code> — Python instrument ground truth</summary>

```python
import json
from datetime import datetime, timezone
from pathlib import Path
import pyarrow.parquet as pq

DATA_BAR = Path("/Users/mordrax/code/nautilus_automatron/backtest_catalog/data/bar")
def d(ns): return datetime.fromtimestamp(ns / 1e9, tz=timezone.utc).date().isoformat()

out = {}
for bar_dir in sorted(DATA_BAR.iterdir()):
    if not bar_dir.is_dir():
        continue
    files = sorted(bar_dir.glob("*.parquet"))
    bar_count, ts_min, ts_max = 0, None, None
    for f in files:
        t = pq.read_table(str(f), columns=["ts_event"])
        bar_count += t.num_rows
        ts = t.column("ts_event").to_pylist()
        if ts:
            ts_min = min(ts) if ts_min is None else min(ts_min, min(ts))
            ts_max = max(ts) if ts_max is None else max(ts_max, max(ts))
    out[bar_dir.name] = {"bar_count": bar_count, "file_count": len(files),
                         "ts_min": ts_min, "ts_max": ts_max,
                         "start_date": d(ts_min), "end_date": d(ts_max)}
print(json.dumps(out, indent=2, sort_keys=True))
```
</details>
