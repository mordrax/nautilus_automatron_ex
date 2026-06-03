defmodule AutomatronEx.Runs.Run do
  @moduledoc """
  A backtest run: catalog identity fields plus the 12 embedded trade metrics.

  This is a **derived Postgres index** over the on-disk NautilusTrader catalog
  (the source of truth). Rows are created/refreshed by the `:sync` action, which
  scans the catalog, computes metrics, upserts one row per run keyed on `run_id`,
  and removes rows for runs that have left the catalog. See
  `AutomatronEx.Runs.Sync` for the implementation and
  `AutomatronEx.Runs.RunMetric` for the embedded-metrics decision.
  """

  use Ash.Resource,
    otp_app: :automatron_ex,
    domain: AutomatronEx.Runs,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "runs"
    repo AutomatronEx.Repo
  end

  code_interface do
    define :sync, action: :sync, args: [{:optional, :catalog_path}]
    define :upsert
    define :read
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      description "Insert or refresh a single run, keyed on run_id (used by sync)."
      # No upsert_identity: run_id is the primary key, so it is the default
      # ON CONFLICT target. Avoids a redundant unique index.
      upsert? true

      accept [
        :run_id,
        :trader_id,
        :strategy,
        :total_positions,
        :total_fills,
        :total_pnl,
        :win_rate,
        :expectancy,
        :sharpe_ratio,
        :avg_win,
        :avg_loss,
        :win_loss_ratio,
        :wins,
        :losses,
        :avg_hold_hours,
        :pnl_per_week,
        :trades_per_week
      ]
    end

    action :sync, :map do
      description """
      Rebuild the runs index from the catalog: upsert each run, remove rows for
      runs no longer present, skip unreadable run dirs with a logged warning.
      Returns `%{synced: n, skipped: n, removed: n}`.
      """

      argument :catalog_path, :string do
        allow_nil? true

        description "Catalog dir to sync; defaults to the configured catalog_path."
      end

      run fn input, _context ->
        catalog_path =
          Ash.ActionInput.get_argument(input, :catalog_path) || AutomatronEx.catalog_path()

        {:ok, AutomatronEx.Runs.Sync.run(catalog_path)}
      end
    end
  end

  attributes do
    # --- identity (from the catalog config) ---
    attribute :run_id, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "NautilusTrader run id (the backtest/<run_id> directory name)."
    end

    attribute :trader_id, :string, public?: true
    attribute :strategy, :string, public?: true

    attribute :total_positions, :integer do
      allow_nil? false
      default 0
      public? true
      description "Count of closed positions in the run."
    end

    attribute :total_fills, :integer do
      allow_nil? false
      default 0
      public? true
      description "Count of order fills in the run."
    end

    # --- embedded trade metrics (AutomatronEx.Runs.RunMetric) ---
    # All nullable: a run with 0 closed positions has the all-nil metrics map.
    attribute :total_pnl, :float, public?: true
    attribute :win_rate, :float, public?: true
    attribute :expectancy, :float, public?: true
    attribute :sharpe_ratio, :float, public?: true
    attribute :avg_win, :float, public?: true
    attribute :avg_loss, :float, public?: true
    attribute :win_loss_ratio, :float, public?: true
    attribute :wins, :integer, public?: true
    attribute :losses, :integer, public?: true
    attribute :avg_hold_hours, :float, public?: true
    attribute :pnl_per_week, :float, public?: true
    attribute :trades_per_week, :float, public?: true

    timestamps()
  end
end
