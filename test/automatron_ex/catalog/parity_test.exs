defmodule AutomatronEx.Catalog.ParityTest do
  # Cross-language parity: assert the Elixir Reader projections are field-by-field
  # identical to the Python server's `/trades` and `/bars` JSON for the same real
  # backtest run. This is the phase's data-parity success criterion and the
  # oracle for the `ns_to_iso` format and the i128 OHLCV decode.
  #
  # Opt-in (tagged `:parity`, excluded by default in test_helper.exs) because it
  # shells out to the Python server venv and reads the full real catalog. Run:
  #
  #     mix test test/automatron_ex/catalog/parity_test.exs --include parity
  #
  # Mirrors the metrics parity approach from nae-46k.8 (Python is the reference
  # implementation; Elixir must reproduce its numbers).
  use ExUnit.Case, async: false

  alias AutomatronEx.Catalog.Reader

  @moduletag :parity

  @catalog "/Users/mordrax/code/nautilus_automatron/backtest_catalog"
  @run "e4599dab-fd51-4758-9564-c2061bc2104e"
  @python "/Users/mordrax/code/nautilus_automatron/packages/server/.venv/bin/python"

  # The run's bar types both live under data/bar/ and (verified in recon) hold
  # the same bars the run persisted locally, so read_bars over data/bar/ must
  # match the Python /bars projection exactly.
  @bar_types ["XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL", "XAUUSD.IBCFD-1-MINUTE-MID-EXTERNAL"]

  test "read_trades matches the Python /trades projection field-by-field" do
    py = py_ref("py_ref_trades.py", [@catalog, @run])
    assert {:ok, ex} = Reader.read_trades(@catalog, @run)
    assert length(ex) == length(py)
    assert ex != []

    for {e, p} <- Enum.zip(ex, py) do
      assert e.relative_id == p["relative_id"]
      assert e.position_id == p["position_id"]
      assert e.instrument_id == p["instrument_id"]
      assert e.direction == p["direction"]
      assert e.currency == p["currency"]
      # ns_to_iso must match Python's _ns_to_iso byte-for-byte.
      assert e.entry_datetime == p["entry_datetime"]
      assert e.exit_datetime == p["exit_datetime"]
      assert_in_delta e.entry_price, p["entry_price"], 1.0e-4
      assert_in_delta e.exit_price, p["exit_price"], 1.0e-4
      assert_in_delta e.quantity, p["quantity"], 1.0e-9
      assert_in_delta e.pnl, p["pnl"], 0.01
    end
  end

  test "read_bars matches the Python /bars projection field-by-field" do
    for bar_type <- @bar_types do
      py = py_ref("py_ref_bars.py", [@catalog, @run, bar_type])
      assert {:ok, ex} = Reader.read_bars(@catalog, bar_type)

      # datetime (the ns_to_iso output) must match exactly, in order.
      assert ex.datetime == py["datetime"], "datetime mismatch for #{bar_type}"

      for col <- [:open, :high, :low, :close, :volume] do
        ex_vals = Map.fetch!(ex, col)
        py_vals = py[Atom.to_string(col)]
        assert length(ex_vals) == length(py_vals)

        for {e, p} <- Enum.zip(ex_vals, py_vals) do
          assert_in_delta e, p, 1.0e-4
        end
      end
    end
  end

  # Run a Python reference script in the server venv and decode its JSON stdout.
  defp py_ref(script, args) do
    path = Path.expand("../../support/#{script}", __DIR__)
    {out, status} = System.cmd(@python, [path | args])
    assert status == 0, "#{script} exited #{status}"
    Jason.decode!(out)
  end
end
