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
end
