defmodule AutomatronEx.IndicatorsTest do
  # Unit contract for the pure indicator compute core: the `nil`-until-initialized
  # alignment, the moving-average maths, the registry shape, and the `compute/2`
  # IndicatorResult projection (incl. skipping bad instances). Exact numeric
  # parity with the Python/NautilusTrader output lives in `indicators_parity_test.exs`.
  use ExUnit.Case, async: true

  # The compute/2 skip paths intentionally log warnings; capture them so the
  # suite output stays clean (shown only on failure). The explicit capture_log/1
  # calls below still assert on the warning content.
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias AutomatronEx.Indicators

  describe "sma/2" do
    test "is nil until the window fills, then the rolling mean of the last `period`" do
      assert Indicators.sma([1.0, 2.0, 3.0, 4.0, 5.0], 3) == [nil, nil, 2.0, 3.0, 4.0]
    end

    test "all nil when there are fewer closes than the period" do
      assert Indicators.sma([1.0, 2.0], 3) == [nil, nil]
    end

    test "a constant series is the constant once initialized" do
      assert Indicators.sma([5.0, 5.0, 5.0, 5.0], 2) == [nil, 5.0, 5.0, 5.0]
    end
  end

  describe "ema/2" do
    test "seeds with the first close and is nil until initialized" do
      # period 3 → alpha = 2/4 = 0.5, seeded at close[0]:
      #   ema0 = 1.0, ema1 = 1.5, ema2 = 2.25, ema3 = 3.125; nil-prefix = period - 1 = 2
      assert [nil, nil, v2, v3] = Indicators.ema([1.0, 2.0, 3.0, 4.0], 3)
      assert_in_delta v2, 2.25, 1.0e-12
      assert_in_delta v3, 3.125, 1.0e-12
    end

    test "a constant series is the constant once initialized" do
      assert [nil, c1, c2] = Indicators.ema([7.0, 7.0, 7.0], 2)
      assert_in_delta c1, 7.0, 1.0e-12
      assert_in_delta c2, 7.0, 1.0e-12
    end
  end

  describe "hma/2" do
    test "is nil until initialized, then floats, aligned to the closes" do
      closes = Enum.map(1..30, &(&1 * 1.0))
      result = Indicators.hma(closes, 20)

      assert length(result) == 30
      assert Enum.take(result, 19) == List.duplicate(nil, 19)
      assert result |> Enum.drop(19) |> Enum.all?(&is_float/1)
    end

    test "a constant series is the constant once initialized" do
      # period 4 → period_halved = 2, period_sqrt = 2, nil-prefix = 3
      result = Indicators.hma(List.duplicate(3.0, 10), 4)

      assert Enum.take(result, 3) == [nil, nil, nil]
      for v <- Enum.drop(result, 3), do: assert_in_delta(v, 3.0, 1.0e-12)
    end
  end

  describe "rsi/2" do
    # NautilusTrader's RelativeStrengthIndex defaults to EXPONENTIAL average
    # gain/loss and `_rsi_max = 1`, so the value is in [0, 1] (not [0, 100]) and
    # is exactly `1 - 1/(1 + avg_gain/avg_loss)`. Confirmed against the source +
    # parity oracle; the textbook 0–100 form does NOT match the Python store.
    test "a series with no losses is 1.0 once initialized (avg_loss == 0)" do
      assert Indicators.rsi([5.0, 5.0, 5.0], 2) == [nil, 1.0, 1.0]
      assert Indicators.rsi([1.0, 2.0, 3.0, 4.0], 2) == [nil, 1.0, 1.0, 1.0]
    end

    test "is the EMA-smoothed RS form, nil until initialized at period - 1" do
      # closes [1,2,1,2], period 2 (alpha = 2/3): gain inputs [0,1,0,1], loss
      # inputs [0,0,1,0]. i2: rs = 0.2222/0.6667 = 1/3 -> 1 - 0.75 = 0.25.
      # i3: rs = 0.7407/0.2222 = 10/3 -> 1 - 0.230769 = 0.769231.
      assert [nil, v1, v2, v3] = Indicators.rsi([1.0, 2.0, 1.0, 2.0], 2)
      assert_in_delta v1, 1.0, 1.0e-12
      assert_in_delta v2, 0.25, 1.0e-9
      assert_in_delta v3, 0.769231, 1.0e-6
    end

    test "all nil when there are fewer closes than the period" do
      assert Indicators.rsi([1.0, 2.0], 3) == [nil, nil]
    end
  end

  describe "macd/3" do
    test "is EMA(fast) - EMA(slow), nil until the slow EMA initializes (slow - 1)" do
      # closes [1,2,3,4], fast 2 (a=2/3), slow 3 (a=1/2). Difference of the
      # running EMAs; initialized at index slow - 1 = 2.
      assert [nil, nil, v2, v3] = Indicators.macd([1.0, 2.0, 3.0, 4.0], 2, 3)
      assert_in_delta v2, 0.305556, 1.0e-6
      assert_in_delta v3, 0.393519, 1.0e-6
    end

    test "a constant series has a zero MACD line once initialized" do
      assert [nil, nil, v2, v3] = Indicators.macd([7.0, 7.0, 7.0, 7.0], 2, 3)
      assert_in_delta v2, 0.0, 1.0e-12
      assert_in_delta v3, 0.0, 1.0e-12
    end
  end

  describe "atr/4" do
    # NautilusTrader's AverageTrueRange defaults to a SIMPLE moving average (not
    # EMA/Wilder) with use_previous=True, so ATR = SMA(TR, period) where
    # TR = max(prev_close, high) - min(low, prev_close) (prev_close seeds to the
    # first close). Confirmed against the source + parity oracle.
    test "is SMA of the true range, nil until initialized at period - 1" do
      highs = [10.0, 12.0, 13.0]
      lows = [9.0, 10.0, 11.0]
      closes = [10.0, 11.0, 12.0]
      # TR = [1, 2, 2] -> SMA(2) = [nil, 1.5, 2.0]
      assert Indicators.atr(highs, lows, closes, 2) == [nil, 1.5, 2.0]
    end

    test "all nil when there are fewer bars than the period" do
      assert Indicators.atr([2.0], [1.0], [1.5], 3) == [nil]
    end
  end

  describe "stochastics/5" do
    # NautilusTrader's Stochastics defaults to slowing=1 and the "ratio" %D
    # method: %K = 100*(close - LL)/(HH - LL) over period_k; %D = 100 *
    # SUM(close - LL)/SUM(HH - LL) over the last period_d bars (NOT SMA(%K)).
    # Initialized once period_k highs/lows are seen. Confirmed via parity.
    test "returns {value_k, value_d} lists, nil until initialized at period_k - 1" do
      highs = [10.0, 11.0, 12.0]
      lows = [8.0, 9.0, 10.0]
      closes = [9.0, 10.0, 11.0]

      assert {k, d} = Indicators.stochastics(highs, lows, closes, 2, 2)

      assert [nil, k1, k2] = k
      assert_in_delta k1, 100.0 * 2 / 3, 1.0e-9
      assert_in_delta k2, 100.0 * 2 / 3, 1.0e-9

      assert [nil, d1, d2] = d
      # d1 = 100 * (1 + 2)/(2 + 3) = 60; d2 = 100 * (2 + 2)/(3 + 3) = 66.667
      assert_in_delta d1, 60.0, 1.0e-9
      assert_in_delta d2, 100.0 * 4 / 6, 1.0e-9
    end

    test "both lists are all nil when there are fewer bars than period_k" do
      assert {[nil], [nil]} = Indicators.stochastics([2.0], [1.0], [1.5], 3, 2)
    end
  end

  describe "registry/0" do
    test "lists the three overlay moving-average types with a period param" do
      reg = Indicators.registry()

      assert "SMA" in Enum.map(reg, & &1.type)

      for type <- ["SMA", "EMA", "HMA"] do
        spec = Enum.find(reg, &(&1.type == type))
        assert spec.display == "overlay"
        assert spec.outputs == ["value"]
        assert [%{name: "period", type: "int", default: 20, min: 2, max: 500}] = spec.params
        assert spec.label_template == "#{type}({period})"
      end
    end

    test "lists the four panel oscillator types with correct params and outputs" do
      reg = Indicators.registry()

      rsi = Enum.find(reg, &(&1.type == "RSI"))
      assert rsi.display == "panel"
      assert rsi.outputs == ["value"]
      assert rsi.label_template == "RSI({period})"
      assert [%{name: "period", type: "int", default: 14, min: 2, max: 100}] = rsi.params

      macd = Enum.find(reg, &(&1.type == "MACD"))
      assert macd.display == "panel"
      assert macd.outputs == ["value"]
      assert macd.label_template == "MACD({fast_period},{slow_period})"

      assert [
               %{name: "fast_period", type: "int", default: 12, min: 2, max: 200},
               %{name: "slow_period", type: "int", default: 26, min: 2, max: 500}
             ] = macd.params

      atr = Enum.find(reg, &(&1.type == "ATR"))
      assert atr.display == "panel"
      assert atr.outputs == ["value"]
      assert atr.label_template == "ATR({period})"
      assert [%{name: "period", type: "int", default: 14, min: 1, max: 200}] = atr.params

      stoch = Enum.find(reg, &(&1.type == "Stochastics"))
      assert stoch.display == "panel"
      assert stoch.outputs == ["value_k", "value_d"]
      assert stoch.label_template == "Stoch({period_k},{period_d})"

      assert [
               %{name: "period_k", type: "int", default: 14, min: 1, max: 200},
               %{name: "period_d", type: "int", default: 3, min: 1, max: 200}
             ] = stoch.params
    end
  end

  describe "compute/2" do
    setup do
      {:ok, bars: %{datetime: ["t0", "t1", "t2", "t3"], close: [1.0, 2.0, 3.0, 4.0]}}
    end

    test "projects an IndicatorResult: id, label, display, outputs.value, datetime", %{bars: bars} do
      assert [res] = Indicators.compute(bars, [%{id: "a", type: "SMA", params: %{"period" => 2}}])

      assert res.id == "a"
      assert res.label == "SMA(2)"
      assert res.display == "overlay"
      assert res.datetime == bars.datetime
      assert res.outputs["value"] == [nil, 1.5, 2.5, 3.5]
    end

    test "formats the label from each type's template", %{bars: bars} do
      instances = [
        %{id: "a", type: "SMA", params: %{"period" => 2}},
        %{id: "b", type: "EMA", params: %{"period" => 2}},
        %{id: "c", type: "HMA", params: %{"period" => 2}}
      ]

      labels = bars |> Indicators.compute(instances) |> Enum.map(& &1.label)
      assert labels == ["SMA(2)", "EMA(2)", "HMA(2)"]
    end

    test "skips unknown indicator types with a logged warning", %{bars: bars} do
      log =
        capture_log(fn ->
          assert Indicators.compute(bars, [%{id: "x", type: "NOPE", params: %{"period" => 2}}]) ==
                   []
        end)

      assert log =~ "NOPE"
    end

    test "skips instances whose period is out of range, with a logged warning", %{bars: bars} do
      log =
        capture_log(fn ->
          assert Indicators.compute(bars, [%{id: "y", type: "SMA", params: %{"period" => 1}}]) ==
                   []
        end)

      assert log =~ "period"
    end

    test "computes the valid instances and drops the invalid ones", %{bars: bars} do
      results =
        Indicators.compute(bars, [
          %{id: "a", type: "SMA", params: %{"period" => 2}},
          %{id: "b", type: "NOPE", params: %{"period" => 2}},
          %{id: "c", type: "EMA", params: %{"period" => 2}}
        ])

      assert Enum.map(results, & &1.id) == ["a", "c"]
    end

    test "projects panel oscillators with display panel and a formatted label", %{bars: bars} do
      instances = [
        %{id: "r", type: "RSI", params: %{"period" => 2}},
        %{id: "m", type: "MACD", params: %{"fast_period" => 2, "slow_period" => 3}}
      ]

      by_id = bars |> Indicators.compute(instances) |> Map.new(&{&1.id, &1})

      assert by_id["r"].display == "panel"
      assert by_id["r"].label == "RSI(2)"
      assert by_id["r"].datetime == bars.datetime
      assert length(by_id["r"].outputs["value"]) == length(bars.close)

      assert by_id["m"].display == "panel"
      assert by_id["m"].label == "MACD(2,3)"
    end

    test "dispatches ATR/Stochastics with high/low/close and multi-output keys" do
      hlc_bars = %{
        datetime: ["t0", "t1", "t2"],
        high: [10.0, 11.0, 12.0],
        low: [8.0, 9.0, 10.0],
        close: [9.0, 10.0, 11.0]
      }

      instances = [
        %{id: "atr", type: "ATR", params: %{"period" => 2}},
        %{id: "st", type: "Stochastics", params: %{"period_k" => 2, "period_d" => 2}}
      ]

      by_id = hlc_bars |> Indicators.compute(instances) |> Map.new(&{&1.id, &1})

      assert by_id["atr"].display == "panel"
      assert by_id["atr"].label == "ATR(2)"

      assert by_id["atr"].outputs["value"] ==
               Indicators.atr([10.0, 11.0, 12.0], [8.0, 9.0, 10.0], [9.0, 10.0, 11.0], 2)

      assert by_id["st"].label == "Stoch(2,2)"

      {k, d} =
        Indicators.stochastics([10.0, 11.0, 12.0], [8.0, 9.0, 10.0], [9.0, 10.0, 11.0], 2, 2)

      assert by_id["st"].outputs["value_k"] == k
      assert by_id["st"].outputs["value_d"] == d
    end

    test "skips a panel instance whose param is out of range, with a logged warning", %{
      bars: bars
    } do
      log =
        capture_log(fn ->
          assert Indicators.compute(bars, [
                   %{id: "m", type: "MACD", params: %{"fast_period" => 2, "slow_period" => 1}}
                 ]) == []
        end)

      assert log =~ "slow_period"
    end
  end
end
