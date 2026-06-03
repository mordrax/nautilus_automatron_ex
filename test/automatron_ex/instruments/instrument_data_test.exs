defmodule AutomatronEx.Instruments.InstrumentDataTest do
  @moduledoc """
  Tests the read-through `InstrumentData` resource against the committed fixture
  catalog (test/support/fixtures/catalog): the manual read maps each
  `Catalog.Reader.list_instrument_data/1` entry onto a record (including the
  ns-timestamp → `Date` conversion), and tolerates an unreadable catalog.

  Every assertion passes an explicit `catalog_path` (never the global config) so
  the case is safe to run async alongside tests that mutate `:catalog_path`.
  """

  use ExUnit.Case, async: true

  alias AutomatronEx.Catalog.Reader
  alias AutomatronEx.Instruments.InstrumentData

  @fixture_catalog Path.expand("../../support/fixtures/catalog", __DIR__)

  describe "read action (list/1)" do
    test "returns one record per bar_type, mapped from the reader entry" do
      assert [row] = InstrumentData.list!(@fixture_catalog)

      assert row.instrument == "XAUUSD.IBCFD"
      assert row.bar_type == "XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL"
      assert row.timeframe == "5-MINUTE-MID-EXTERNAL"
      assert row.venue == "IBCFD"
      assert row.bar_count == 300
      assert row.file_count == 1
      assert String.ends_with?(row.path, "data/bar/XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL")
      assert Path.type(row.path) == :absolute
    end

    test "maps the reader's ns ts_min/ts_max onto start_date/end_date as UTC dates" do
      [entry] = Reader.list_instrument_data(@fixture_catalog)
      [row] = InstrumentData.list!(@fixture_catalog)

      assert %Date{} = row.start_date
      assert %Date{} = row.end_date

      assert row.start_date ==
               entry.ts_min |> DateTime.from_unix!(:nanosecond) |> DateTime.to_date()

      assert row.end_date ==
               entry.ts_max |> DateTime.from_unix!(:nanosecond) |> DateTime.to_date()

      assert Date.compare(row.start_date, row.end_date) in [:lt, :eq]
    end

    test "returns [] for an unreadable / nonexistent catalog (no crash)" do
      assert InstrumentData.list!("/nonexistent/catalog/path") == []
    end
  end
end
