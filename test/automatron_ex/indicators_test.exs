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

  describe "registry/0" do
    test "lists the three overlay moving-average types with a period param" do
      reg = Indicators.registry()

      assert Enum.map(reg, & &1.type) == ["SMA", "EMA", "HMA"]

      for spec <- reg do
        assert spec.display == "overlay"
        assert spec.outputs == ["value"]
        assert [%{name: "period", type: "int", default: 20, min: 2, max: 500}] = spec.params
      end

      assert Enum.find(reg, &(&1.type == "SMA")).label_template == "SMA({period})"
      assert Enum.find(reg, &(&1.type == "EMA")).label_template == "EMA({period})"
      assert Enum.find(reg, &(&1.type == "HMA")).label_template == "HMA({period})"
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
  end
end
