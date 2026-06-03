defmodule AutomatronEx.Catalog.MetricsTest do
  use ExUnit.Case, async: true

  alias AutomatronEx.Catalog.Metrics
  alias Explorer.DataFrame

  # Port of packages/server/tests/test_metrics.py. Every case there has an
  # equivalent here asserting the same numbers (numeric parity is the phase
  # success criterion). The Python tests build SimpleNamespace position lists;
  # here we build the closed-positions Explorer dataframe directly, matching the
  # column shape Catalog.Reader.read_positions_closed produces
  # (realized_pnl f64; ts_opened / ts_closed / duration_ns u64).

  # Timestamp helpers (mirror test_metrics.py)
  @h1_ns 3_600_000_000_000
  @d1_ns 86_400_000_000_000
  # 2024-01-01 00:00:00 UTC
  @base_ts 1_704_067_200_000_000_000
  # 2024-02-01 00:00:00 UTC
  @feb1_2024 1_706_745_600_000_000_000

  @metric_keys ~w(
    total_pnl win_rate expectancy sharpe_ratio avg_win avg_loss win_loss_ratio
    wins losses avg_hold_hours pnl_per_week trades_per_week
  )a

  # Build the closed-positions dataframe for a list of realized pnls, mirroring
  # the Python `_make_positions_list`: ts_opened defaults to one-per-day from
  # @base_ts, ts_closed one hour later, duration_ns to one hour each.
  defp positions_df(realized_pnl, opts \\ []) do
    n = length(realized_pnl)
    ts_opened = Keyword.get(opts, :ts_opened, for(i <- 0..(n - 1)//1, do: @base_ts + i * @d1_ns))

    ts_closed =
      Keyword.get(opts, :ts_closed, for(i <- 0..(n - 1)//1, do: @base_ts + i * @d1_ns + @h1_ns))

    duration_ns = Keyword.get(opts, :duration_ns, List.duplicate(@h1_ns, n))

    DataFrame.new(
      [
        {"realized_pnl", realized_pnl},
        {"ts_opened", ts_opened},
        {"ts_closed", ts_closed},
        {"duration_ns", duration_ns}
      ],
      dtypes: [
        {"realized_pnl", {:f, 64}},
        {"ts_opened", {:u, 64}},
        {"ts_closed", {:u, 64}},
        {"duration_ns", {:u, 64}}
      ]
    )
  end

  # -------------------------------------------------------------------------
  # empty_metrics
  # -------------------------------------------------------------------------

  describe "empty_metrics/0" do
    test "all values are nil" do
      for {key, value} <- Metrics.empty_metrics() do
        assert value == nil, "Expected nil for key #{inspect(key)}, got #{inspect(value)}"
      end
    end

    test "has exactly the 12 metric keys" do
      assert Metrics.empty_metrics() |> Map.keys() |> Enum.sort() == Enum.sort(@metric_keys)
    end
  end

  # -------------------------------------------------------------------------
  # compute_run_metrics — empty table
  # -------------------------------------------------------------------------

  describe "compute_run_metrics/1 with zero positions" do
    test "a 0-row frame returns the all-nil metrics map" do
      result = Metrics.compute_run_metrics(positions_df([]))

      assert Map.keys(result) |> Enum.sort() == Enum.sort(@metric_keys)

      for {key, value} <- result do
        assert value == nil, "Expected nil for key #{inspect(key)}, got #{inspect(value)}"
      end
    end
  end

  # -------------------------------------------------------------------------
  # total_pnl
  # -------------------------------------------------------------------------

  describe "total_pnl" do
    test "is the sum of realized pnl" do
      result = Metrics.compute_run_metrics(positions_df([100.0, -50.0, 200.0]))
      assert result.total_pnl == 250.0
    end

    test "is rounded to 2 decimals" do
      result = Metrics.compute_run_metrics(positions_df([100.123, 50.456]))
      assert result.total_pnl == Float.round(100.123 + 50.456, 2)
    end
  end

  # -------------------------------------------------------------------------
  # wins and losses counts
  # -------------------------------------------------------------------------

  describe "wins and losses" do
    test "wins counts pnl > 0" do
      result = Metrics.compute_run_metrics(positions_df([100.0, 200.0, -50.0, -10.0, 0.0]))
      assert result.wins == 2
    end

    test "losses counts pnl <= 0" do
      result = Metrics.compute_run_metrics(positions_df([100.0, 200.0, -50.0, -10.0, 0.0]))
      assert result.losses == 3
    end
  end

  # -------------------------------------------------------------------------
  # win_rate
  # -------------------------------------------------------------------------

  describe "win_rate" do
    test "is wins over total" do
      result = Metrics.compute_run_metrics(positions_df([100.0, -50.0, 200.0, -30.0]))
      # 2 wins, 4 total
      assert result.win_rate == Float.round(2 / 4, 4)
    end

    test "is rounded to 4 decimals" do
      result = Metrics.compute_run_metrics(positions_df([100.0, 50.0, -10.0]))
      assert result.win_rate == Float.round(2 / 3, 4)
    end
  end

  # -------------------------------------------------------------------------
  # avg_win and avg_loss
  # -------------------------------------------------------------------------

  describe "avg_win and avg_loss" do
    test "avg_win is the mean of winning pnls" do
      result = Metrics.compute_run_metrics(positions_df([100.0, 200.0, -50.0]))
      assert result.avg_win == Float.round((100.0 + 200.0) / 2, 2)
    end

    test "avg_loss is the mean of losing pnls" do
      result = Metrics.compute_run_metrics(positions_df([100.0, -50.0, -30.0]))
      assert result.avg_loss == Float.round((-50.0 + -30.0) / 2, 2)
    end

    test "avg_loss includes zero pnl (pnl <= 0 are losses)" do
      result = Metrics.compute_run_metrics(positions_df([100.0, -50.0, 0.0]))
      assert result.avg_loss == Float.round((-50.0 + 0.0) / 2, 2)
    end
  end

  # -------------------------------------------------------------------------
  # win_loss_ratio
  # -------------------------------------------------------------------------

  describe "win_loss_ratio" do
    test "is abs(avg_win / avg_loss)" do
      result = Metrics.compute_run_metrics(positions_df([100.0, -50.0]))
      assert result.win_loss_ratio == Float.round(abs(100.0 / -50.0), 2)
    end

    test "is nil when there are no losses (avg_loss is nil)" do
      result = Metrics.compute_run_metrics(positions_df([100.0, 200.0, 50.0]))
      assert result.win_loss_ratio == nil
    end
  end

  # -------------------------------------------------------------------------
  # expectancy
  # -------------------------------------------------------------------------

  describe "expectancy" do
    test "computed from win_rate, avg_win, avg_loss" do
      result = Metrics.compute_run_metrics(positions_df([100.0, 200.0, -50.0, -30.0]))

      win_rate = 2 / 4
      # 150
      avg_win = (100.0 + 200.0) / 2
      # -40
      avg_loss = (-50.0 + -30.0) / 2
      expected = Float.round(win_rate * avg_win - (1 - win_rate) * abs(avg_loss), 2)
      assert result.expectancy == expected
    end

    test "expectancy/3 helper matches the formula" do
      result = Metrics.expectancy(0.5, 150.0, -40.0)
      expected = Float.round(0.5 * 150.0 - 0.5 * abs(-40.0), 2)
      assert result == expected
    end
  end

  # -------------------------------------------------------------------------
  # avg_hold_hours
  # -------------------------------------------------------------------------

  describe "avg_hold_hours" do
    test "is the mean hold duration in hours" do
      durations = [2 * @h1_ns, 4 * @h1_ns, 6 * @h1_ns]

      result =
        Metrics.compute_run_metrics(positions_df([100.0, -50.0, 200.0], duration_ns: durations))

      # mean of 2, 4, 6 hours
      assert result.avg_hold_hours == Float.round(4.0, 1)
    end

    test "is rounded to 1 decimal" do
      durations = [1 * @h1_ns, 2 * @h1_ns]
      result = Metrics.compute_run_metrics(positions_df([100.0, -50.0], duration_ns: durations))
      assert result.avg_hold_hours == Float.round(1.5, 1)
    end
  end

  # -------------------------------------------------------------------------
  # pnl_per_week and trades_per_week
  # -------------------------------------------------------------------------

  describe "pnl_per_week and trades_per_week" do
    test "pnl_per_week uses the run span in weeks" do
      ts_opened = [@base_ts, @base_ts + 14 * @d1_ns]
      ts_closed = [@base_ts + @h1_ns, @base_ts + 14 * @d1_ns + @h1_ns]

      result =
        Metrics.compute_run_metrics(
          positions_df([100.0, 200.0], ts_opened: ts_opened, ts_closed: ts_closed)
        )

      # span = max(ts_closed) - min(ts_opened) = 14 days + 1H
      span_ns = 14 * @d1_ns + @h1_ns
      span_weeks = span_ns / (7 * @d1_ns)
      assert result.pnl_per_week == Float.round(300.0 / span_weeks, 2)
    end

    test "trades_per_week uses the run span in weeks" do
      ts_opened = [@base_ts, @base_ts + 14 * @d1_ns]
      ts_closed = [@base_ts + @h1_ns, @base_ts + 14 * @d1_ns + @h1_ns]

      result =
        Metrics.compute_run_metrics(
          positions_df([100.0, 200.0], ts_opened: ts_opened, ts_closed: ts_closed)
        )

      span_ns = 14 * @d1_ns + @h1_ns
      span_weeks = span_ns / (7 * @d1_ns)
      assert result.trades_per_week == Float.round(2 / span_weeks, 2)
    end
  end

  # -------------------------------------------------------------------------
  # run_span_weeks/2 helper
  # -------------------------------------------------------------------------

  describe "run_span_weeks/2" do
    test "is (max ts_closed - min ts_opened) in weeks" do
      ts_openeds = [@base_ts, @base_ts + 3 * @d1_ns]
      ts_closeds = [@base_ts + @h1_ns, @base_ts + 14 * @d1_ns]

      result = Metrics.run_span_weeks(ts_openeds, ts_closeds)
      # span = (@base_ts + 14 days) - @base_ts = 14 days
      expected = (@base_ts + 14 * @d1_ns - @base_ts) / (7 * @d1_ns)
      assert_in_delta result, expected, 1.0e-8
    end
  end

  # -------------------------------------------------------------------------
  # sharpe_ratio/2 helper
  # -------------------------------------------------------------------------

  describe "sharpe_ratio/2" do
    test "is nil with a single month of data" do
      # All trades in same month → < 2 months → nil
      pnls = [100.0, -50.0, 200.0]
      ts_closeds = [@base_ts + @d1_ns, @base_ts + 2 * @d1_ns, @base_ts + 3 * @d1_ns]
      assert Metrics.sharpe_ratio(pnls, ts_closeds) == nil
    end

    test "is nil when sample std is zero" do
      # Same monthly return every month → std == 0 → nil
      pnls = [100.0, 100.0]
      ts_closeds = [@base_ts + @d1_ns, @feb1_2024 + @d1_ns]
      assert Metrics.sharpe_ratio(pnls, ts_closeds) == nil
    end

    test "annualizes the monthly returns over two months" do
      # Jan: 100 + 200 = 300, Feb: -50 + 150 = 100
      pnls = [100.0, 200.0, -50.0, 150.0]

      ts_closeds = [
        @base_ts + @d1_ns,
        @base_ts + 2 * @d1_ns,
        @feb1_2024 + @d1_ns,
        @feb1_2024 + 2 * @d1_ns
      ]

      result = Metrics.sharpe_ratio(pnls, ts_closeds)
      assert result != nil

      monthly_returns = [300.0, 100.0]
      mean = Enum.sum(monthly_returns) / 2
      variance = Enum.sum(Enum.map(monthly_returns, fn r -> (r - mean) ** 2 end)) / (2 - 1)
      std = :math.sqrt(variance)
      expected = Float.round(mean / std * :math.sqrt(12), 2)
      assert result == expected
    end

    test "is surfaced (non-nil float) through compute_run_metrics/1" do
      ts_opened = [
        @base_ts,
        @base_ts + @d1_ns,
        @feb1_2024,
        @feb1_2024 + @d1_ns
      ]

      ts_closed = [
        @base_ts + @h1_ns,
        @base_ts + 2 * @d1_ns,
        @feb1_2024 + @h1_ns,
        @feb1_2024 + 2 * @d1_ns
      ]

      result =
        Metrics.compute_run_metrics(
          positions_df([100.0, 200.0, -50.0, 150.0], ts_opened: ts_opened, ts_closed: ts_closed)
        )

      assert result.sharpe_ratio != nil
      assert is_float(result.sharpe_ratio)
    end
  end

  # -------------------------------------------------------------------------
  # Edge cases
  # -------------------------------------------------------------------------

  describe "edge cases" do
    test "all winning trades → no avg_loss, win_loss_ratio, or expectancy" do
      result = Metrics.compute_run_metrics(positions_df([100.0, 200.0, 50.0]))
      assert result.wins == 3
      assert result.losses == 0
      assert result.avg_loss == nil
      assert result.win_loss_ratio == nil
      assert result.expectancy == nil
    end

    test "all losing trades → no avg_win, win_rate is 0.0" do
      result = Metrics.compute_run_metrics(positions_df([-100.0, -50.0]))
      assert result.wins == 0
      assert result.losses == 2
      assert result.avg_win == nil
      assert result.win_rate == 0.0
    end

    test "single winning trade" do
      result = Metrics.compute_run_metrics(positions_df([100.0]))
      assert result.total_pnl == 100.0
      assert result.wins == 1
      assert result.losses == 0
      assert result.win_rate == 1.0
    end
  end
end
