# AutomatronEx

Elixir/Ash/Phoenix LiveView rewrite of
[`nautilus_automatron`](file:///Users/mordrax/code/nautilus_automatron) — a
backtest-analysis app over the NautilusTrader catalog.

NautilusTrader itself stays an external Python engine that produces the
catalog; this app reads and visualises it (and in later phases orchestrates
backtest runs). See `docs/superpowers/specs/` for the design docs.

## Tech stack

- Elixir / Phoenix 1.8 + LiveView (Bandit)
- Ash 3 + AshPostgres (PostgreSQL 14)
- Oban — job queue (scaffolded now, first used by backtest orchestration)
- Explorer — native Parquet / Arrow IPC reads of the catalog

## Prerequisites

- **Elixir** ≥ 1.15 with Erlang/OTP — `brew install elixir`
- **PostgreSQL 14** on `localhost:5432` —
  `brew install postgresql@14 && brew services start postgresql@14`

  The app uses the standard Phoenix dev credentials `postgres` / `postgres`.
  If your local Postgres does not have that role yet:

  ```bash
  psql -d postgres -c "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';"
  ```

- A NautilusTrader catalog directory (see [Catalog configuration](#catalog-configuration-catalog_path))

## Setup

```bash
mix setup
```

This fetches deps, creates and migrates the database, and builds assets.
Or step by step:

```bash
mix deps.get
mix ecto.create
mix ecto.migrate
```

## Running

```bash
mix phx.server
```

Then open [http://localhost:4000](http://localhost:4000). To run inside IEx:

```bash
iex -S mix phx.server
```

## Tests

```bash
mix test
```

Before committing, run the full check (compile with warnings as errors,
format, unused-dep check, tests):

```bash
mix precommit
```

## Catalog configuration (CATALOG_PATH)

The app reads a NautilusTrader catalog — a directory containing `data/`
(market data, Parquet) and `backtest/` (run results, feather + JSON).

| Environment | Default catalog path |
|---|---|
| dev | `/Users/mordrax/code/nautilus_automatron/backtest_catalog` (the real catalog) |
| test | `test/support/fixtures/catalog` (committed fixture, added in a later phase) |

Override in any environment with the `CATALOG_PATH` env var:

```bash
CATALOG_PATH=/path/to/catalog mix phx.server
```

In code, the path is available via `AutomatronEx.catalog_path/0`.

## Roadmap

- **Phase 0 (this)** — wired skeleton: Phoenix + Ash + AshPostgres + Oban + Explorer.
- **Phase 1** — Explorer catalog reader, run-metrics port (Python parity),
  read-only runs dashboard (`/`) and instrument catalog (`/instruments`).
- **Phase 2+** — run detail + charts, indicators in Elixir, backtest/ingestion
  orchestration.
