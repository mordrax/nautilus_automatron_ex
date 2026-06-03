defmodule AutomatronEx.Runs.Sync do
  @moduledoc """
  Rebuilds the `AutomatronEx.Runs.Run` Postgres index from the on-disk catalog.

  Driven by the `Run.sync` action. For each run under `backtest/` it reads the
  config + closed positions + fills (via `AutomatronEx.Catalog.Reader`), computes
  the trade metrics (`AutomatronEx.Catalog.Metrics`), and upserts one `Run` row
  keyed on `run_id`. Rows for runs that have left the catalog are removed.

  Error tolerance (mirrors the Python app): a run dir missing `config.json` or a
  feather file, or with a malformed file, is skipped with a logged warning — the
  remaining runs still sync. A previously-synced run that becomes unreadable
  keeps its existing row (its dir is still in the catalog); only runs whose dir is
  gone are removed.
  """

  require Logger

  alias AutomatronEx.Catalog.{Metrics, Reader}
  alias AutomatronEx.Runs.{Run, RunMetric}

  @type result :: %{
          synced: non_neg_integer(),
          skipped: non_neg_integer(),
          removed: non_neg_integer()
        }

  @doc """
  Sync the runs index against `catalog_path`.

  Returns `%{synced: n, skipped: n, removed: n}`.
  """
  @spec run(String.t()) :: result()
  def run(catalog_path) do
    catalog_run_ids = Reader.list_run_ids(catalog_path)

    outcomes = Enum.map(catalog_run_ids, &sync_run(catalog_path, &1))

    %{
      synced: Enum.count(outcomes, &(&1 == :synced)),
      skipped: Enum.count(outcomes, &(&1 == :skipped)),
      removed: remove_stale(catalog_run_ids)
    }
  end

  # Read + compute + upsert a single run. Any read error (missing/malformed
  # config or feather) skips this run with a warning; the rest still sync.
  @spec sync_run(String.t(), String.t()) :: :synced | :skipped
  defp sync_run(catalog_path, run_id) do
    with {:ok, config} <- Reader.read_run_config(catalog_path, run_id),
         {:ok, positions} <- Reader.read_positions_closed(catalog_path, run_id),
         {:ok, fills} <- Reader.read_fills(catalog_path, run_id),
         {:ok, _run} <- Run.upsert(build_attrs(run_id, config, positions, fills)) do
      :synced
    else
      {:error, reason} ->
        Logger.warning("Runs.Sync: skipping run #{run_id}: #{inspect(reason)}")
        :skipped
    end
  end

  # Build the Run attributes map: identity fields from config, counts from the
  # frames, and the 12 metric keys merged from the computed metrics map.
  @spec build_attrs(String.t(), map(), Explorer.DataFrame.t(), Explorer.DataFrame.t()) :: map()
  defp build_attrs(run_id, config, positions, fills) do
    metrics = Metrics.compute_run_metrics(positions)

    %{
      run_id: run_id,
      trader_id: Map.get(config, "trader_id", "Unknown"),
      strategy: strategy_name(config),
      total_positions: Explorer.DataFrame.n_rows(positions),
      total_fills: Explorer.DataFrame.n_rows(fills)
    }
    |> Map.merge(Map.take(metrics, RunMetric.keys()))
  end

  # Port of the Python `_extract_strategy_name`, minus the positions_opened path
  # (the read-only Reader does not load opened positions): prefer an explicit
  # `strategy_name`, else the first strategy's `strategy_path`, else "Unknown".
  @spec strategy_name(map()) :: String.t()
  defp strategy_name(config) do
    case config do
      %{"strategy_name" => name} when is_binary(name) and name != "" ->
        name

      %{"strategies" => [%{"strategy_path" => path} | _]} when is_binary(path) ->
        path

      _ ->
        "Unknown"
    end
  end

  # Destroy rows whose run_id is no longer a directory in the catalog.
  @spec remove_stale([String.t()]) :: non_neg_integer()
  defp remove_stale(catalog_run_ids) do
    catalog_set = MapSet.new(catalog_run_ids)

    stale =
      Run
      |> Ash.read!()
      |> Enum.reject(&MapSet.member?(catalog_set, &1.run_id))

    Enum.each(stale, &Ash.destroy!/1)
    length(stale)
  end
end
