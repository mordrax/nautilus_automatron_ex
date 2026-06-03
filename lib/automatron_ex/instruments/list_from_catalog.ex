defmodule AutomatronEx.Instruments.ListFromCatalog do
  @moduledoc """
  The manual read backing `AutomatronEx.Instruments.InstrumentData`'s `:read`
  action.

  Resolves the catalog path (the action's `:catalog_path` argument, else the
  configured `AutomatronEx.catalog_path/0`), scans it with
  `AutomatronEx.Catalog.Reader.list_instrument_data/1`, and maps each reader entry
  onto an `InstrumentData` record. The reader already tolerates a missing or
  unreadable `data/bar/` directory (returns `[]`), so this never raises for an
  absent catalog — the LiveView renders an empty state rather than crashing.
  """

  use Ash.Resource.ManualRead

  alias AutomatronEx.Catalog.Reader
  alias AutomatronEx.Instruments.InstrumentData

  @impl true
  def read(query, _data_layer_query, _opts, _context) do
    catalog_path = Ash.Query.get_argument(query, :catalog_path) || AutomatronEx.catalog_path()

    records =
      catalog_path
      |> Reader.list_instrument_data()
      |> Enum.map(&to_record/1)

    {:ok, records}
  end

  # Map one `Reader.list_instrument_data/1` entry onto an InstrumentData record,
  # renaming `instrument_id` → `instrument` and converting the ns-epoch
  # `ts_min`/`ts_max` to UTC `Date`s for `start_date`/`end_date`.
  @spec to_record(map()) :: Ash.Resource.record()
  defp to_record(entry) do
    %InstrumentData{
      bar_type: entry.bar_type,
      instrument: entry.instrument_id,
      timeframe: entry.timeframe,
      venue: entry.venue,
      bar_count: entry.bar_count,
      start_date: to_date(entry.ts_min),
      end_date: to_date(entry.ts_max),
      file_count: entry.file_count,
      path: entry.path
    }
  end

  @spec to_date(integer() | nil) :: Date.t() | nil
  defp to_date(nil), do: nil

  defp to_date(ns) when is_integer(ns) do
    ns
    |> DateTime.from_unix!(:nanosecond)
    |> DateTime.to_date()
  end
end
