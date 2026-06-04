defmodule AutomatronEx.Catalog.ReaderTest do
  use ExUnit.Case, async: true

  alias AutomatronEx.Catalog.Reader
  alias Explorer.DataFrame

  @catalog Path.expand("../../support/fixtures/catalog", __DIR__)

  # Fixture facts (see test/support/fixtures/catalog/README.md and docs/catalog-schema.md):
  #   017f6297-… — empty run, 0 closed positions / 0 fills (BBBStrategy)
  #   e4599dab-… — populated run, 204 closed positions / 408 fills (EMACross)
  @empty_run "017f6297-c633-4419-aa23-bc3fb8171cad"
  @populated_run "e4599dab-fd51-4758-9564-c2061bc2104e"

  describe "list_run_ids/1" do
    test "returns the backtest run directory names, sorted" do
      assert Reader.list_run_ids(@catalog) == [@empty_run, @populated_run]
    end

    test "returns [] when the catalog has no backtest dir", %{} do
      assert Reader.list_run_ids("/nonexistent/catalog/path") == []
    end
  end

  describe "read_run_config/2" do
    test "parses config.json into {:ok, map} with trader and strategy" do
      assert {:ok, config} = Reader.read_run_config(@catalog, @populated_run)
      assert config["trader_id"] == "BACKTESTER-001"
      assert [%{"strategy_path" => path} | _] = config["strategies"]
      assert path =~ "EMACross"
    end

    test "returns a tagged error when config.json is missing" do
      assert {:error, _reason} = Reader.read_run_config(@catalog, "does-not-exist")
    end

    @tag :tmp_dir
    test "returns a tagged error when config.json is malformed", %{tmp_dir: tmp} do
      run_dir = Path.join([tmp, "backtest", "bad-run"])
      File.mkdir_p!(run_dir)
      File.write!(Path.join(run_dir, "config.json"), "{not valid json")

      assert {:error, _reason} = Reader.read_run_config(tmp, "bad-run")
    end
  end

  describe "read_positions_closed/2" do
    test "reads the populated run, projecting the metrics columns" do
      assert {:ok, df} = Reader.read_positions_closed(@catalog, @populated_run)
      assert DataFrame.n_rows(df) == 204

      assert DataFrame.names(df) == [
               "realized_pnl",
               "ts_opened",
               "ts_closed",
               "duration_ns"
             ]
    end

    test "reads the empty run as a valid 0-row frame with the same columns" do
      assert {:ok, df} = Reader.read_positions_closed(@catalog, @empty_run)
      assert DataFrame.n_rows(df) == 0

      assert DataFrame.names(df) == [
               "realized_pnl",
               "ts_opened",
               "ts_closed",
               "duration_ns"
             ]
    end

    test "returns a tagged error when the feather file is missing" do
      assert {:error, _reason} = Reader.read_positions_closed(@catalog, "does-not-exist")
    end

    @tag :tmp_dir
    test "returns a tagged error when the feather file is malformed", %{tmp_dir: tmp} do
      run_dir = Path.join([tmp, "backtest", "bad-run"])
      File.mkdir_p!(run_dir)
      File.write!(Path.join(run_dir, "position_closed_0.feather"), "not a feather file")

      assert {:error, _reason} = Reader.read_positions_closed(tmp, "bad-run")
    end
  end

  describe "read_fills/2" do
    test "reads the populated run's fills" do
      assert {:ok, df} = Reader.read_fills(@catalog, @populated_run)
      assert DataFrame.n_rows(df) == 408
    end

    test "reads the empty run's fills as a 0-row frame" do
      assert {:ok, df} = Reader.read_fills(@catalog, @empty_run)
      assert DataFrame.n_rows(df) == 0
    end

    test "returns a tagged error when the feather file is missing" do
      assert {:error, _reason} = Reader.read_fills(@catalog, "does-not-exist")
    end
  end

  describe "list_instrument_data/1" do
    test "returns one aggregated entry per bar_type directory" do
      assert [entry] = Reader.list_instrument_data(@catalog)

      assert entry.instrument_id == "XAUUSD.IBCFD"
      assert entry.bar_type == "XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL"
      assert entry.timeframe == "5-MINUTE-MID-EXTERNAL"
      assert entry.venue == "IBCFD"
      assert entry.bar_count == 300
      assert entry.file_count == 1
      assert String.ends_with?(entry.path, "data/bar/XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL")
      assert Path.type(entry.path) == :absolute
    end

    test "derives ts_min/ts_max as ns-epoch timestamps from the bar data" do
      assert [entry] = Reader.list_instrument_data(@catalog)

      assert is_integer(entry.ts_min) and entry.ts_min > 0
      assert is_integer(entry.ts_max) and entry.ts_max > 0
      assert entry.ts_min <= entry.ts_max
      # Sanity: the bars are nanoseconds since the epoch, in 2026.
      assert DateTime.from_unix!(entry.ts_min, :nanosecond).year == 2026
    end

    test "returns [] when the catalog has no data/bar dir" do
      assert Reader.list_instrument_data("/nonexistent/catalog/path") == []
    end
  end

  describe "parse_instrument_id/1" do
    test "drops the trailing step/aggregation/price/source segments" do
      assert Reader.parse_instrument_id("XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL") == "XAUUSD.IBCFD"
      assert Reader.parse_instrument_id("AUDUSD.SIM-100-TICK-MID-INTERNAL") == "AUDUSD.SIM"
    end
  end

  describe "parse_timeframe/2" do
    test "strips the instrument-id prefix" do
      assert Reader.parse_timeframe("XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL", "XAUUSD.IBCFD") ==
               "5-MINUTE-MID-EXTERNAL"
    end

    test "returns the bar_type unchanged when the prefix does not match" do
      assert Reader.parse_timeframe("XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL", "EURUSD.SIM") ==
               "XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL"
    end
  end

  describe "parse_venue/1" do
    test "extracts the venue token after the last dot, up to the first dash" do
      assert Reader.parse_venue("XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL") == "IBCFD"
      assert Reader.parse_venue("AUDUSD.SIM-100-TICK-MID-INTERNAL") == "SIM"
    end

    test "returns nil when there is no dot in the bar_type" do
      assert Reader.parse_venue("NODOT-1-MINUTE-MID-EXTERNAL") == nil
    end
  end

  describe "read_bars/2" do
    @bar_type "XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL"

    test "returns sorted columnar OHLCV for a bar type" do
      assert {:ok, ohlc} = Reader.read_bars(@catalog, @bar_type)

      assert Map.keys(ohlc) |> Enum.sort() == [:close, :datetime, :high, :low, :open, :volume]

      # The fixture's 5-MINUTE directory holds 300 bars (see list_instrument_data).
      n = length(ohlc.datetime)
      assert n == 300

      for col <- [:open, :high, :low, :close, :volume] do
        assert length(Map.fetch!(ohlc, col)) == n
      end

      # OHLCV decoded from raw i128 binary to floats.
      assert Enum.all?(ohlc.open, &is_float/1)
      assert Enum.all?(ohlc.volume, &is_float/1)

      # datetime is ISO-8601 UTC strings (Python's _ns_to_iso uses a +00:00
      # offset, not Z), ascending.
      assert ohlc.datetime == Enum.sort(ohlc.datetime)
      assert hd(ohlc.datetime) =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+00:00$/
    end

    test "errors on unknown bar type" do
      assert {:error, _reason} = Reader.read_bars(@catalog, "NOPE-1-MINUTE-MID-EXTERNAL")
    end
  end

  describe "read_trades/2" do
    test "projects closed positions to Trade maps, 1-based relative_id by ts_opened" do
      assert {:ok, trades} = Reader.read_trades(@catalog, @populated_run)

      assert length(trades) == 204
      assert Enum.map(trades, & &1.relative_id) == Enum.to_list(1..204)

      t = hd(trades)

      assert Map.keys(t) |> Enum.sort() ==
               [
                 :currency,
                 :direction,
                 :entry_datetime,
                 :entry_price,
                 :exit_datetime,
                 :exit_price,
                 :instrument_id,
                 :pnl,
                 :position_id,
                 :quantity,
                 :relative_id
               ]

      assert t.direction in ["Long", "Short"]
      assert is_float(t.pnl)
      assert t.entry_datetime <= t.exit_datetime

      # Exact field mapping for the first trade (by ts_opened), verified against
      # the Python `/trades` JSON for this run (entry "BUY" -> "Long";
      # entry/exit = avg_px_open/close; quantity = peak_qty; pnl = realized_pnl
      # rounded 2dp; datetimes via _ns_to_iso).
      assert t.relative_id == 1
      assert t.position_id == "XAUUSD.IBCFD-EMACross-000"
      assert t.instrument_id == "XAUUSD.IBCFD"
      assert t.direction == "Long"
      assert t.entry_datetime == "2026-02-26T00:40:00+00:00"
      assert t.entry_price == 5182.76
      assert t.exit_datetime == "2026-02-26T02:35:00+00:00"
      assert t.exit_price == 5178.98
      assert t.quantity == 1.0
      assert t.pnl == -3.98
      assert t.currency == "USD"
    end

    test "returns [] for a zero-position run" do
      assert {:ok, []} = Reader.read_trades(@catalog, @empty_run)
    end
  end

  describe "read_run_detail/2" do
    test "returns config-derived bar_types and feather-derived counts" do
      assert {:ok, d} = Reader.read_run_detail(@catalog, @populated_run)

      assert d.run_id == @populated_run
      assert d.total_positions == 204
      assert d.total_fills == 408

      # bar_types come from the run config (strategies[].config.bar_type).
      assert d.bar_types == ["XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL"]

      assert is_map(d.config)
      assert d.config["trader_id"] == "BACKTESTER-001"
    end

    test "returns a tagged error for an unknown run" do
      assert {:error, _reason} = Reader.read_run_detail(@catalog, "does-not-exist")
    end
  end
end
