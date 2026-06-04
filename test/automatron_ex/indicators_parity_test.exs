defmodule AutomatronEx.IndicatorsParityTest do
  # Cross-language parity: assert the Elixir `Indicators.sma/ema/hma` (via
  # `compute/2`) reproduce the Python `server.store.indicators` output for
  # SMA(20)/EMA(20)/HMA(20) over the fixture 5-MINUTE bars — field-by-field,
  # including the `nil` prefix. This is the bead's compute-parity success
  # criterion and the oracle for the EMA/HMA initialization semantics.
  #
  # The production reader supplies the closes to both sides (written to a temp
  # file the Python oracle reads), so the maths is what's under test, not the
  # close decode (already covered by `AutomatronEx.Catalog.ParityTest`).
  #
  # Opt-in (tagged `:parity`, excluded by default in test_helper.exs) because it
  # shells out to the Python server venv. Run:
  #
  #     mix test test/automatron_ex/indicators_parity_test.exs --include parity
  #
  # Mirrors the reader/metrics parity approach (Python is the reference; Elixir
  # must reproduce its numbers).
  use ExUnit.Case, async: false

  alias AutomatronEx.Catalog.Reader
  alias AutomatronEx.Indicators

  @moduletag :parity

  @catalog Path.expand("../support/fixtures/catalog", __DIR__)
  @bar_type "XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL"
  @python "/Users/mordrax/code/nautilus_automatron/packages/server/.venv/bin/python"
  @period 20

  @tag :tmp_dir
  test "sma/ema/hma match Python store.indicators on the fixture 5-MINUTE bars", %{tmp_dir: tmp} do
    assert {:ok, bars} = Reader.read_bars(@catalog, @bar_type)
    assert length(bars.close) == 300

    instances = [
      %{id: "sma", type: "SMA", params: %{"period" => @period}},
      %{id: "ema", type: "EMA", params: %{"period" => @period}},
      %{id: "hma", type: "HMA", params: %{"period" => @period}}
    ]

    by_id = bars |> Indicators.compute(instances) |> Map.new(&{&1.id, &1})

    closes_path = Path.join(tmp, "closes.json")
    File.write!(closes_path, Jason.encode!(bars.close))
    py = py_ref("py_ref_indicators.py", [closes_path, Integer.to_string(@period)])

    for {id, type} <- [{"sma", "SMA"}, {"ema", "EMA"}, {"hma", "HMA"}] do
      ex = by_id[id].outputs["value"]
      px = py[type]

      assert length(ex) == length(px), "#{type}: length mismatch"
      # period - 1 leading nils, the rest populated.
      assert Enum.count(ex, &is_nil/1) == @period - 1, "#{type}: nil-prefix mismatch"

      for {{e, p}, i} <- Enum.with_index(Enum.zip(ex, px)) do
        cond do
          is_nil(e) or is_nil(p) ->
            assert e == p,
                   "#{type}[#{i}]: nil alignment mismatch (#{inspect(e)} vs #{inspect(p)})"

          true ->
            assert_in_delta e, p, 1.0e-6, "#{type}[#{i}]: #{e} vs #{p}"
        end
      end
    end
  end

  # Run a Python reference script in the server venv and decode its JSON stdout.
  defp py_ref(script, args) do
    path = Path.expand("../support/#{script}", __DIR__)
    {out, status} = System.cmd(@python, [path | args])
    assert status == 0, "#{script} exited #{status}: #{out}"
    Jason.decode!(out)
  end
end
