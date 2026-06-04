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
  Read the columnar OHLCV for a `bar_type` from `data/bar/<bar_type>/*.parquet`.

  Concatenates every parquet file in the directory, sorts by `ts_event`, and
  projects to a columnar map with the same shape (and field-by-field values) as
  the Python `/bars` JSON (`transforms.bars_to_ohlc`):

      %{datetime: [iso8601], open: [float], high: [float],
        low: [float], close: [float], volume: [float]}

  `open`/`high`/`low`/`close`/`volume` are stored as Nautilus high-precision raw
  i128 cells (little-endian 16-byte signed) and decoded to floats by dividing by
  10^16 (see `docs/catalog-schema.md`). `datetime` is `ts_event` (ns) rendered
  with `ns_to_iso/1` to match the Python `_ns_to_iso` format exactly.

  Returns `{:error, {:no_bars, bar_type}}` when the directory holds no parquet
  files, or `{:error, reason}` when a file is unreadable.
  """
  @spec read_bars(catalog_path(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_bars(catalog_path, bar_type) do
    dir = Path.join([catalog_path, "data", "bar", bar_type])

    case Path.wildcard(Path.join(dir, "*.parquet")) do
      [] ->
        {:error, {:no_bars, bar_type}}

      files ->
        df =
          files
          |> Enum.map(&DataFrame.from_parquet!/1)
          |> DataFrame.concat_rows()
          |> DataFrame.sort_with(fn d -> [asc: d["ts_event"]] end)

        {:ok,
         %{
           datetime: df["ts_event"] |> Series.to_list() |> Enum.map(&ns_to_iso/1),
           open: prices(df["open"]),
           high: prices(df["high"]),
           low: prices(df["low"]),
           close: prices(df["close"]),
           volume: prices(df["volume"])
         }}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Read `backtest/<run_id>/position_closed_0.feather` and project each closed
  position to a Trade map for the run-detail table, sorted by `ts_opened` with a
  1-based `relative_id`. Mirrors the Python `transforms.positions_to_trades` /
  `/trades` JSON field-by-field:

      %{relative_id, position_id, instrument_id, direction: "Long" | "Short",
        entry_datetime, entry_price, exit_datetime, exit_price, quantity, pnl,
        currency}

  `direction` is `"Long"` when the position `entry` is `"BUY"`, else `"Short"`
  (`side` is `"FLAT"` for closed positions, so `entry` is the source).
  `entry_price`/`exit_price` are `avg_px_open`/`avg_px_close`; `quantity` is
  `peak_qty`; `pnl` is `realized_pnl` rounded to 2 decimals; the datetimes are
  `ts_opened`/`ts_closed` via `ns_to_iso/1`.

  A run with no closed positions (0-row feather) or a missing feather returns
  `{:ok, []}`; an unreadable feather returns `{:error, reason}`.
  """
  @spec read_trades(catalog_path(), run_id()) :: {:ok, [map()]} | {:error, term()}
  def read_trades(catalog_path, run_id) do
    case read_feather(catalog_path, run_id, "position_closed_0.feather") do
      {:ok, df} -> {:ok, project_trades(df)}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Read the run-detail summary the `/runs/:run_id` page needs:

      %{run_id, config, total_positions, total_fills, bar_types}

  `config` is the parsed `config.json`; `bar_types` are the unique
  `strategies[].config.bar_type` values from that config (the bar types the run
  traded, each an existing `data/bar/<bar_type>` directory); `total_positions`
  and `total_fills` are the `position_closed_0` / `order_filled_0` feather row
  counts.

  Returns `{:error, reason}` (propagated from `read_run_config/2`) when the run's
  `config.json` is missing or malformed.
  """
  @spec read_run_detail(catalog_path(), run_id()) :: {:ok, map()} | {:error, term()}
  def read_run_detail(catalog_path, run_id) do
    with {:ok, config} <- read_run_config(catalog_path, run_id) do
      {:ok,
       %{
         run_id: run_id,
         config: config,
         total_positions: count_rows(catalog_path, run_id, "position_closed_0.feather"),
         total_fills: count_rows(catalog_path, run_id, "order_filled_0.feather"),
         bar_types: bar_types_from_config(config)
       }}
    end
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

  # Decode a series of Nautilus high-precision raw i128 OHLCV cells (16-byte
  # little-endian signed integers) to floats by dividing by 10^16
  # (FIXED_PRECISION = 16; see docs/catalog-schema.md). This matches the Python
  # `float(bar.open)` projection in `transforms.bars_to_ohlc`.
  @fixed_precision_divisor 1.0e16
  @spec prices(Series.t()) :: [float() | nil]
  defp prices(series), do: series |> Series.to_list() |> Enum.map(&decode_price/1)

  defp decode_price(<<raw::little-signed-128>>), do: raw / @fixed_precision_divisor
  defp decode_price(nil), do: nil

  # Render a u64 nanosecond-since-epoch timestamp as an ISO-8601 UTC string,
  # byte-for-byte matching Python's `transforms._ns_to_iso`
  # (`datetime.fromtimestamp(ns / 1e9, tz=timezone.utc).isoformat()`): a `+00:00`
  # offset (not `Z`), with fractional seconds only when sub-second precision is
  # present. All catalog timestamps observed are whole-second, so the integer
  # microsecond path matches the Python float path exactly (verified by the
  # parity test).
  @spec ns_to_iso(non_neg_integer()) :: String.t()
  defp ns_to_iso(ns) do
    dt = DateTime.from_unix!(div(ns, 1000), :microsecond)
    {microsecond, _precision} = dt.microsecond
    base = Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S")

    frac =
      if microsecond == 0,
        do: "",
        else: "." <> (microsecond |> Integer.to_string() |> String.pad_leading(6, "0"))

    base <> frac <> "+00:00"
  end

  # Project a closed-positions data frame to the sorted, 1-based Trade maps the
  # run-detail table consumes (see read_trades/2 and Python positions_to_trades).
  @spec project_trades(DataFrame.t()) :: [map()]
  defp project_trades(df) do
    df
    |> DataFrame.sort_with(fn d -> [asc: d["ts_opened"]] end)
    |> DataFrame.to_rows()
    |> Enum.with_index(1)
    |> Enum.map(fn {row, relative_id} ->
      %{
        relative_id: relative_id,
        position_id: row["position_id"],
        instrument_id: row["instrument_id"],
        direction: direction(row["entry"]),
        entry_datetime: ns_to_iso(row["ts_opened"]),
        entry_price: to_float(row["avg_px_open"]),
        exit_datetime: ns_to_iso(row["ts_closed"]),
        exit_price: to_float(row["avg_px_close"]),
        quantity: to_float(row["peak_qty"]),
        pnl: row["realized_pnl"] |> to_float() |> round2(),
        currency: row["currency"]
      }
    end)
  end

  # Position entry side -> trade direction. Python: "Long" if entry == BUY else
  # "Short" (anything non-BUY is Short).
  defp direction("BUY"), do: "Long"
  defp direction(_other), do: "Short"

  defp to_float(nil), do: nil
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0

  defp round2(nil), do: nil
  defp round2(n), do: Float.round(n, 2)

  # The bar types a run traded, taken from its config's
  # strategies[].config.bar_type (unique, source order).
  @spec bar_types_from_config(map()) :: [String.t()]
  defp bar_types_from_config(config) do
    config
    |> Map.get("strategies", [])
    |> Enum.map(&get_in(&1, ["config", "bar_type"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Row count of a per-run feather, or 0 when it is missing/unreadable.
  @spec count_rows(catalog_path(), run_id(), String.t()) :: non_neg_integer()
  defp count_rows(catalog_path, run_id, filename) do
    case read_feather(catalog_path, run_id, filename) do
      {:ok, df} -> DataFrame.n_rows(df)
      {:error, _reason} -> 0
    end
  end
end
