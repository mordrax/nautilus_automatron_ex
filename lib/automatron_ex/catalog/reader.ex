defmodule AutomatronEx.Catalog.Reader do
  @moduledoc """
  Pure reader for a NautilusTrader backtest catalog.

  Reads the on-disk catalog (`backtest/` runs and `data/bar/` market data) with
  Explorer — no Ash, no database, no web concerns. Mirrors the Python
  `server/store/{reader,catalog_reader,transforms}.py`.

  Catalog layout (see `docs/catalog-schema.md`):

      catalog/
        backtest/<run_id>/
          config.json               # serialized BacktestEngineConfig
          position_closed_0.feather # closed positions (metrics source)
          order_filled_0.feather    # order fills
        data/bar/<bar_type>/*.parquet

  > `.feather` files are Arrow IPC **stream** format — read with
  > `Explorer.DataFrame.from_ipc_stream/1`, never `from_ipc/1`.
  """

  alias Explorer.DataFrame
  alias Explorer.Series

  @type catalog_path :: String.t()
  @type run_id :: String.t()

  # Columns projected out of `position_closed_0.feather` for the metrics
  # computation (`AutomatronEx.Catalog.Metrics`); see docs/catalog-schema.md.
  @position_closed_projection ~w(realized_pnl ts_opened ts_closed duration_ns)

  @doc """
  List the backtest run ids (the directory names under `backtest/`), sorted.

  Returns `[]` when the catalog or its `backtest/` directory is absent.
  """
  @spec list_run_ids(catalog_path()) :: [run_id()]
  def list_run_ids(catalog_path) do
    backtest_dir = Path.join(catalog_path, "backtest")

    case File.ls(backtest_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(backtest_dir, &1)))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Read and parse `backtest/<run_id>/config.json`.

  Returns `{:ok, map}` on success, or a tagged `{:error, reason}` when the file
  is missing (`:enoent`) or contains malformed JSON.
  """
  @spec read_run_config(catalog_path(), run_id()) :: {:ok, map()} | {:error, term()}
  def read_run_config(catalog_path, run_id) do
    path = Path.join([catalog_path, "backtest", run_id, "config.json"])

    with {:ok, body} <- File.read(path) do
      Jason.decode(body)
    end
  end

  @doc """
  Read `backtest/<run_id>/position_closed_0.feather`, projecting the columns the
  metrics computation needs: `realized_pnl`, `ts_opened`, `ts_closed`,
  `duration_ns`.

  A run with no closed positions yields a valid 0-row frame with those columns.
  Returns `{:error, reason}` when the feather is missing or malformed.
  """
  @spec read_positions_closed(catalog_path(), run_id()) ::
          {:ok, DataFrame.t()} | {:error, term()}
  def read_positions_closed(catalog_path, run_id) do
    with {:ok, df} <- read_feather(catalog_path, run_id, "position_closed_0.feather") do
      {:ok, DataFrame.select(df, @position_closed_projection)}
    end
  end

  @doc """
  Read `backtest/<run_id>/order_filled_0.feather` as a full data frame.

  This phase uses only the row count (`Run.total_fills`); fill detail is parsed
  in a later phase. Returns `{:error, reason}` when the feather is missing or
  malformed.
  """
  @spec read_fills(catalog_path(), run_id()) :: {:ok, DataFrame.t()} | {:error, term()}
  def read_fills(catalog_path, run_id) do
    read_feather(catalog_path, run_id, "order_filled_0.feather")
  end

  @doc """
  List the available instrument bar data — one entry per `data/bar/<bar_type>`
  directory, sorted by directory name.

  Each entry aggregates `bar_count`, `ts_min` and `ts_max` (over `ts_event`)
  across **all** parquet files in the directory, plus `file_count` and the
  absolute `path`. `instrument_id`, `timeframe` and `venue` are derived from the
  bar_type directory name (see `parse_instrument_id/1`, `parse_timeframe/2`,
  `parse_venue/1`).

  Directories with no readable bars are skipped (mirrors the Python reader).
  Returns `[]` when the catalog has no `data/bar/` directory.
  """
  @spec list_instrument_data(catalog_path()) :: [map()]
  def list_instrument_data(catalog_path) do
    data_bar_dir = Path.join([catalog_path, "data", "bar"])

    case File.ls(data_bar_dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(&Path.join(data_bar_dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&bar_type_entry/1)
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Derive the instrument id from a Nautilus `BarType` string (the bar_type
  directory name) by dropping the trailing `step-aggregation-price-source`
  segments, e.g. `"XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL"` → `"XAUUSD.IBCFD"`.
  """
  @spec parse_instrument_id(String.t()) :: String.t()
  def parse_instrument_id(bar_type) do
    segments = String.split(bar_type, "-")

    case length(segments) - 4 do
      keep when keep >= 1 ->
        segments |> Enum.take(keep) |> Enum.join("-")

      _ ->
        bar_type
    end
  end

  @doc """
  Extract the timeframe of a `bar_type` by stripping the `"<instrument_id>-"`
  prefix, e.g. `("XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL", "XAUUSD.IBCFD")` →
  `"5-MINUTE-MID-EXTERNAL"`. Returns the `bar_type` unchanged when it does not
  start with that prefix. Port of Python `transforms._parse_timeframe`.
  """
  @spec parse_timeframe(String.t(), String.t()) :: String.t()
  def parse_timeframe(bar_type, instrument_id) do
    String.replace_prefix(bar_type, instrument_id <> "-", "")
  end

  @doc """
  Extract the venue token from a `bar_type`: the segment after the last `.`, up
  to the first `-`, e.g. `"XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL"` → `"IBCFD"`.
  Returns `nil` when the `bar_type` contains no `.`. Port of Python
  `transforms._parse_venue`.
  """
  @spec parse_venue(String.t()) :: String.t() | nil
  def parse_venue(bar_type) do
    if String.contains?(bar_type, ".") do
      bar_type
      |> String.split(".")
      |> List.last()
      |> String.split("-", parts: 2)
      |> List.first()
    else
      nil
    end
  end

  # Build one instrument-data entry for a bar_type directory, or nil when the
  # directory has no readable bars (matches the Python reader's skip behaviour).
  @spec bar_type_entry(String.t()) :: map() | nil
  defp bar_type_entry(bar_type_dir) do
    bar_type = Path.basename(bar_type_dir)
    files = Path.wildcard(Path.join(bar_type_dir, "*.parquet"))
    {bar_count, ts_min, ts_max} = aggregate_bars(files)

    if bar_count == 0 do
      nil
    else
      instrument_id = parse_instrument_id(bar_type)

      %{
        instrument_id: instrument_id,
        bar_type: bar_type,
        bar_count: bar_count,
        ts_min: ts_min,
        ts_max: ts_max,
        file_count: length(files),
        path: Path.expand(bar_type_dir),
        timeframe: parse_timeframe(bar_type, instrument_id),
        venue: parse_venue(bar_type)
      }
    end
  end

  # Sum bar counts and fold ts_event min/max across every parquet file. Files
  # that fail to read are skipped so a single bad file never crashes the scan.
  @spec aggregate_bars([String.t()]) :: {non_neg_integer(), integer() | nil, integer() | nil}
  defp aggregate_bars(files) do
    Enum.reduce(files, {0, nil, nil}, fn file, {count, min_ts, max_ts} = acc ->
      case DataFrame.from_parquet(file) do
        {:ok, df} ->
          ts = DataFrame.pull(df, "ts_event")

          {count + DataFrame.n_rows(df), min_of(min_ts, Series.min(ts)),
           max_of(max_ts, Series.max(ts))}

        {:error, _reason} ->
          acc
      end
    end)
  end

  defp min_of(nil, b), do: b
  defp min_of(a, nil), do: a
  defp min_of(a, b), do: min(a, b)

  defp max_of(nil, b), do: b
  defp max_of(a, nil), do: a
  defp max_of(a, b), do: max(a, b)

  # Read a per-run feather (Arrow IPC stream). Returns {:error, :enoent} for a
  # missing file rather than relying on the loader's error for that case.
  @spec read_feather(catalog_path(), run_id(), String.t()) ::
          {:ok, DataFrame.t()} | {:error, term()}
  defp read_feather(catalog_path, run_id, filename) do
    path = Path.join([catalog_path, "backtest", run_id, filename])

    if File.exists?(path) do
      DataFrame.from_ipc_stream(path)
    else
      {:error, :enoent}
    end
  end
end
