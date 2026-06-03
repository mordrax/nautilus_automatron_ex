defmodule AutomatronEx.Instruments.InstrumentData do
  @moduledoc """
  A read-through view of one `data/bar/<bar_type>` slice of the NautilusTrader
  catalog: which instrument, at what timeframe/venue, how many bars over what date
  range, across how many files.

  This is **not** a Postgres-backed resource. It uses the default
  `Ash.DataLayer.Simple` (no table, no migration); its single manual read action
  delegates to `AutomatronEx.Instruments.ListFromCatalog`, which calls
  `AutomatronEx.Catalog.Reader.list_instrument_data/1` and maps each entry onto a
  record. The metadata is cheap file aggregation, always fresh from disk — see
  `AutomatronEx.Instruments` for the read-through rationale.

  ## Field mapping (reader entry → record)

  The reader speaks the catalog's vocabulary; this resource speaks the dashboard's:

    * `instrument_id`   → `instrument`
    * `ts_min`/`ts_max` → `start_date`/`end_date` (ns-since-epoch → UTC `Date`)

  `bar_type`, `timeframe`, `venue`, `bar_count`, `file_count` and `path` carry over
  unchanged. `bar_type` is the primary key — it is the unique directory name the
  reader produces one entry per.
  """

  use Ash.Resource,
    otp_app: :automatron_ex,
    domain: AutomatronEx.Instruments,
    # The read action takes an optional `catalog_path` (mirrors `Run.sync`); it is
    # also the primary read. The argument is optional, so the primary-read warning
    # does not apply here.
    primary_read_warning?: false

  code_interface do
    define :list, action: :read, args: [{:optional, :catalog_path}]
  end

  actions do
    read :read do
      primary? true

      description """
      List the catalog's instrument data, one record per `data/bar/<bar_type>`
      directory. Reads through to the filesystem on every call.
      """

      argument :catalog_path, :string do
        allow_nil? true
        description "Catalog dir to read; defaults to the configured catalog_path."
      end

      manual AutomatronEx.Instruments.ListFromCatalog
    end
  end

  attributes do
    attribute :bar_type, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "Nautilus BarType — the `data/bar/<bar_type>` directory name; unique per entry."
    end

    attribute :instrument, :string do
      public? true
      description "Instrument id parsed from the bar_type, e.g. `XAUUSD.IBCFD`."
    end

    attribute :timeframe, :string do
      public? true
      description "Timeframe segment of the bar_type, e.g. `5-MINUTE-MID-EXTERNAL`."
    end

    attribute :venue, :string do
      public? true
      description "Venue token parsed from the bar_type, e.g. `IBCFD` (nil when absent)."
    end

    attribute :bar_count, :integer do
      public? true
      description "Total bars aggregated across all parquet files in the directory."
    end

    attribute :start_date, :date do
      public? true
      description "Date of the earliest bar (`ts_min`), UTC."
    end

    attribute :end_date, :date do
      public? true
      description "Date of the latest bar (`ts_max`), UTC."
    end

    attribute :file_count, :integer do
      public? true
      description "Number of parquet files in the directory."
    end

    attribute :path, :string do
      public? true
      description "Absolute path to the bar_type directory."
    end
  end
end
