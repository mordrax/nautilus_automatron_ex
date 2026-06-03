# Fixture catalog

A small, **real**, Explorer-readable slice of a NautilusTrader backtest catalog,
used by the reader / metrics / LiveView tests. Mirrors the layout of the real
catalog at `/Users/mordrax/code/nautilus_automatron/backtest_catalog`.

Full schema reference: [`docs/catalog-schema.md`](../../../../docs/catalog-schema.md).

## Layout

```
catalog/
  backtest/
    017f6297-c633-4419-aa23-bc3fb8171cad/   # EMPTY run (0 closed positions)
      config.json
      position_closed_0.feather             # 0 rows  (verbatim copy)
      order_filled_0.feather                # 0 rows  (verbatim copy)
    e4599dab-fd51-4758-9564-c2061bc2104e/   # POPULATED run (EMACross)
      config.json
      position_closed_0.feather             # 204 rows (all kept, re-encoded)
      order_filled_0.feather                # 408 rows (all kept, re-encoded)
  data/
    bar/
      XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL/
        2026-02-25T23-00-00-000000000Z_2026-03-01T23-50-00-000000000Z.parquet  # 300 bars
```

Total ≈ **221 KiB** (< 1 MB). Feathers are Arrow IPC **stream** format — read with
`Explorer.DataFrame.from_ipc_stream!/1`.

## What each piece exercises

| Fixture | Purpose |
|---|---|
| `017f6297-…` (0 positions) | `empty_metrics` / all-nil branch; copied byte-for-byte to preserve Nautilus's exact 0-row schema |
| `e4599dab-…` (204 positions) | **all rows kept** so metrics on the fixture equal the real run → metrics-parity tests; populated reader paths |
| two distinct `config.json` | config parse: `trader_id`, `strategies[].strategy_path` (`EMACross` vs `BBBStrategy`) |
| `data/bar/…` (300 bars) | instrument-catalog reader: `bar_count`, `ts_min/ts_max`, `file_count`, `bar_type` → `timeframe`/`venue` parsing |

## Regenerate

```bash
# from the project root; needs access to the real catalog
mix run --no-start test/support/fixtures/catalog/generate.exs

# point at a different source catalog:
NAEC_REAL_CATALOG=/path/to/backtest_catalog \
  mix run --no-start test/support/fixtures/catalog/generate.exs
```

`generate.exs` rebuilds `backtest/` and `data/` from the source catalog: copies
the empty run verbatim, re-encodes the populated run's feathers (all rows), and
truncates one bar parquet to 300 rows with a regenerated
`{ts_min}_{ts_max}.parquet` filename. The run UUIDs / bar_type are constants at
the top of the script — edit them to choose different source runs.
