defmodule AutomatronEx.Runs.RunMetric do
  @moduledoc """
  Canonical specification of the per-run trade metrics embedded on
  `AutomatronEx.Runs.Run`.

  These are exactly the 12 keys produced by
  `AutomatronEx.Catalog.Metrics.compute_run_metrics/1`.

  ## Embedded-vs-1:1 decision (bead nae-46k.5)

  The metrics are embedded as **flat, nullable columns directly on the `runs`
  table**, not modelled as a separate 1:1 `RunMetric` resource/table and not as a
  single jsonb blob. Rationale:

    * Metrics are 1:1 with a run and have no independent lifecycle — they are
      recomputed wholesale on every `Run.sync`. A separate table + join buys
      nothing for a read-only derived index.
    * The Phase 1 dashboard sorts/filters/paginates on individual metric keys via
      Ash queries against Postgres. Flat typed columns are directly sortable and
      indexable; a joined table or a jsonb blob would add query friction.
    * Simplicity wins for a read-only index (the spec explicitly recommends
      embedded for this phase).

  This module is the single source of truth for *which* metric fields exist and
  their Ash types. `Run` declares the matching attributes; `Sync` projects the
  computed metrics map onto run attributes via `keys/0`; a test asserts the key
  set stays in parity with `Catalog.Metrics`.
  """

  # {field, ash_type}, in dashboard column order. Ten floats plus the two integer
  # counts — mirrors the `Catalog.Metrics.metrics()` typespec.
  @fields [
    total_pnl: :float,
    win_rate: :float,
    expectancy: :float,
    sharpe_ratio: :float,
    avg_win: :float,
    avg_loss: :float,
    win_loss_ratio: :float,
    wins: :integer,
    losses: :integer,
    avg_hold_hours: :float,
    pnl_per_week: :float,
    trades_per_week: :float
  ]

  @doc "The metric fields as ordered `{name, ash_type}` pairs."
  @spec fields() :: [{atom(), atom()}]
  def fields, do: @fields

  @doc "The 12 metric field names, in column order."
  @spec keys() :: [atom()]
  def keys, do: Keyword.keys(@fields)
end
