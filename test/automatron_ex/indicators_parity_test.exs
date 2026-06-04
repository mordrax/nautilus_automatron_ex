defmodule AutomatronEx.IndicatorsParityTest do
  # Cross-language parity: assert the Elixir `Indicators` (via `compute/2`)
  # reproduce the Python `server.store.indicators` output for the overlay moving
  # averages and the panel oscillators over the fixture 5-MINUTE bars —
  # field-by-field, including the `nil` prefix. This is the bead's compute-parity
  # success criterion and the oracle for the (non-textbook) NautilusTrader
  # semantics: RSI/MACD use exponential smoothing, RSI is bounded [0,1], ATR uses
  # a simple moving average, and Stochastics' %D is the native ratio form.
  #
  # The production reader supplies high/low/close to both sides (written to a temp
  # file the Python oracle reads), so the maths is what's under test, not the OHLC
  # decode (already covered by `AutomatronEx.Catalog.ParityTest`).
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

  @tag :tmp_dir
  test "sma/ema/hma overlays match Python store.indicators on the fixture 5-MINUTE bars",
       %{tmp_dir: tmp} do
    instances = [
      %{id: "sma", type: "SMA", params: %{"period" => 20}},
      %{id: "ema", type: "EMA", params: %{"period" => 20}},
      %{id: "hma", type: "HMA", params: %{"period" => 20}}
    ]

    assert_parity(instances, tmp)
  end

  @tag :tmp_dir
  test "rsi/macd/atr/stochastics panels match Python store.indicators on the fixture 5-MINUTE bars",
       %{tmp_dir: tmp} do
    instances = [
      %{id: "rsi", type: "RSI", params: %{"period" => 14}},
      %{id: "macd", type: "MACD", params: %{"fast_period" => 12, "slow_period" => 26}},
      %{id: "atr", type: "ATR", params: %{"period" => 14}},
      %{id: "stoch", type: "Stochastics", params: %{"period_k" => 14, "period_d" => 3}}
    ]

    assert_parity(instances, tmp)
  end

  # Compute the instances in Elixir and in the Python oracle over one identical
  # series, then assert every output field matches field-by-field (nil alignment
  # exact, values within 1e-6). Multi-output types (Stochastics) compare every
  # output key.
  defp assert_parity(instances, tmp) do
    assert {:ok, bars} = Reader.read_bars(@catalog, @bar_type)
    assert length(bars.close) == 300

    by_id =
      bars
      |> Indicators.compute(instances)
      |> Map.new(&{to_string(&1.id), &1})

    series_path = Path.join(tmp, "series.json")
    File.write!(series_path, Jason.encode!(%{high: bars.high, low: bars.low, close: bars.close}))

    instances_path = Path.join(tmp, "instances.json")
    File.write!(instances_path, Jason.encode!(instances))

    py = py_ref("py_ref_indicators.py", [series_path, instances_path])

    for inst <- instances do
      id = to_string(inst.id)
      ex = by_id[id]
      assert ex, "#{id}: no Elixir result (instance was skipped?)"
      px = py[id]
      assert is_map(px), "#{id}: no Python result"

      for {field, ex_series} <- ex.outputs do
        py_series = px[field]
        assert is_list(py_series), "#{id}.#{field}: missing Python series"
        assert length(ex_series) == length(py_series), "#{id}.#{field}: length mismatch"

        # Guard against a degenerate all-nil-both-sides false pass.
        assert Enum.any?(ex_series, &(not is_nil(&1))), "#{id}.#{field}: never initialized"

        for {{e, p}, i} <- Enum.with_index(Enum.zip(ex_series, py_series)) do
          if is_nil(e) or is_nil(p) do
            assert e == p,
                   "#{id}.#{field}[#{i}]: nil alignment mismatch (#{inspect(e)} vs #{inspect(p)})"
          else
            assert_in_delta e, p, 1.0e-6, "#{id}.#{field}[#{i}]: #{e} vs #{p}"
          end
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
