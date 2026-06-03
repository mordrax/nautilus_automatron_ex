defmodule AutomatronEx.Catalog.Metrics do
  @moduledoc """
  Pure run-metrics computation over a closed-positions Explorer dataframe.

  Port of the Python `server/store/metrics.py`. `compute_run_metrics/1` takes the
  dataframe produced by `AutomatronEx.Catalog.Reader.read_positions_closed/2` —
  columns `realized_pnl` (f64) and `ts_opened`, `ts_closed`, `duration_ns` (u64,
  nanoseconds since the epoch) — and returns a map with exactly these keys:

      :total_pnl, :win_rate, :expectancy, :sharpe_ratio, :avg_win, :avg_loss,
      :win_loss_ratio, :wins, :losses, :avg_hold_hours, :pnl_per_week,
      :trades_per_week

  A frame with no closed positions yields the all-nil map from `empty_metrics/0`.

  Pure: no I/O, no DB, no web concerns. Numeric parity with the Python app is the
  contract (see `docs/superpowers/specs/2026-06-03-foundation-readonly-dashboard-design.md`
  §Components.2 and the ported tests in `test/.../metrics_test.exs`).
  """

  alias Explorer.DataFrame
  alias Explorer.Series

  # Nanoseconds per week / per hour.
  @ns_per_week 7 * 86_400_000_000_000
  @ns_per_hour 3_600_000_000_000

  @type metrics :: %{
          total_pnl: float() | nil,
          win_rate: float() | nil,
          expectancy: float() | nil,
          sharpe_ratio: float() | nil,
          avg_win: float() | nil,
          avg_loss: float() | nil,
          win_loss_ratio: float() | nil,
          wins: non_neg_integer() | nil,
          losses: non_neg_integer() | nil,
          avg_hold_hours: float() | nil,
          pnl_per_week: float() | nil,
          trades_per_week: float() | nil
        }

  @doc """
  The metrics map with every value `nil` — for runs with 0 closed positions.
  """
  @spec empty_metrics() :: metrics()
  def empty_metrics do
    %{
      total_pnl: nil,
      win_rate: nil,
      expectancy: nil,
      sharpe_ratio: nil,
      avg_win: nil,
      avg_loss: nil,
      win_loss_ratio: nil,
      wins: nil,
      losses: nil,
      avg_hold_hours: nil,
      pnl_per_week: nil,
      trades_per_week: nil
    }
  end

  @doc """
  Compute the trade metrics from a closed-positions dataframe.

  Returns `empty_metrics/0` for a 0-row frame.
  """
  @spec compute_run_metrics(DataFrame.t()) :: metrics()
  def compute_run_metrics(%DataFrame{} = positions_closed) do
    if DataFrame.n_rows(positions_closed) == 0 do
      empty_metrics()
    else
      pnl_col = positions_closed |> column("realized_pnl") |> Enum.map(&(&1 * 1.0))
      ts_opened_col = column(positions_closed, "ts_opened")
      ts_closed_col = column(positions_closed, "ts_closed")
      duration_col = column(positions_closed, "duration_ns")

      total_positions = length(pnl_col)

      # --- total_pnl ---
      total_pnl = Float.round(Enum.sum(pnl_col), 2)

      # --- wins / losses ---
      winning_pnls = Enum.filter(pnl_col, &(&1 > 0))
      losing_pnls = Enum.filter(pnl_col, &(&1 <= 0))
      wins = length(winning_pnls)
      losses = length(losing_pnls)

      # --- win_rate ---
      win_rate = Float.round(wins / total_positions, 4)

      # --- avg_win ---
      avg_win = if wins > 0, do: Float.round(Enum.sum(winning_pnls) / wins, 2)

      # --- avg_loss ---
      avg_loss = if losses > 0, do: Float.round(Enum.sum(losing_pnls) / losses, 2)

      # --- win_loss_ratio ---
      win_loss_ratio =
        if avg_win != nil and avg_loss != nil and avg_loss != 0 do
          Float.round(abs(avg_win / avg_loss), 2)
        end

      # --- expectancy ---
      expectancy =
        if avg_win != nil and avg_loss != nil do
          expectancy(win_rate, avg_win, avg_loss)
        end

      # --- avg_hold_hours ---
      mean_ns = Enum.sum(duration_col) / length(duration_col)
      avg_hold_hours = Float.round(mean_ns / @ns_per_hour, 1)

      # --- sharpe_ratio ---
      sharpe_ratio = sharpe_ratio(pnl_col, ts_closed_col)

      # --- run span in weeks ---
      span_weeks = run_span_weeks(ts_opened_col, ts_closed_col)

      # --- pnl_per_week / trades_per_week ---
      {pnl_per_week, trades_per_week} =
        if span_weeks > 0 do
          {Float.round(total_pnl / span_weeks, 2), Float.round(total_positions / span_weeks, 2)}
        else
          {nil, nil}
        end

      %{
        total_pnl: total_pnl,
        win_rate: win_rate,
        expectancy: expectancy,
        sharpe_ratio: sharpe_ratio,
        avg_win: avg_win,
        avg_loss: avg_loss,
        win_loss_ratio: win_loss_ratio,
        wins: wins,
        losses: losses,
        avg_hold_hours: avg_hold_hours,
        pnl_per_week: pnl_per_week,
        trades_per_week: trades_per_week
      }
    end
  end

  @doc """
  Expectancy: `win_rate * avg_win - (1 - win_rate) * abs(avg_loss)`, 2dp.

  `avg_loss` is expected to be negative (or zero); `abs/1` is applied internally.
  """
  @spec expectancy(float(), float(), float()) :: float()
  def expectancy(win_rate, avg_win, avg_loss) do
    Float.round(win_rate * avg_win - (1 - win_rate) * abs(avg_loss), 2)
  end

  @doc """
  Run span in weeks: `(max ts_closed - min ts_opened) / ns_per_week`.

  Timestamps are nanoseconds since the epoch.
  """
  @spec run_span_weeks([integer()], [integer()]) :: float()
  def run_span_weeks(ts_openeds, ts_closeds) do
    span_ns = Enum.max(ts_closeds) - Enum.min(ts_openeds)
    span_ns / @ns_per_week
  end

  @doc """
  Annualized Sharpe ratio from monthly-grouped pnls.

  Groups `pnls` by UTC calendar month (via `ts_closeds`), sums per month to get
  monthly returns, then computes `mean / sample_std * sqrt(12)`, 2dp. Returns
  `nil` with fewer than 2 months of data, or when the sample std is 0.
  """
  @spec sharpe_ratio([float()], [integer()]) :: float() | nil
  def sharpe_ratio(pnls, ts_closeds) do
    monthly =
      pnls
      |> Enum.zip(ts_closeds)
      |> Enum.reduce(%{}, fn {pnl, ts_ns}, acc ->
        dt = DateTime.from_unix!(ts_ns, :nanosecond)
        Map.update(acc, {dt.year, dt.month}, pnl, &(&1 + pnl))
      end)

    returns = Map.values(monthly)
    n = length(returns)

    if n < 2 do
      nil
    else
      mean = Enum.sum(returns) / n
      variance = Enum.sum(Enum.map(returns, fn r -> (r - mean) ** 2 end)) / (n - 1)

      if variance == 0.0 do
        nil
      else
        std = :math.sqrt(variance)
        Float.round(mean / std * :math.sqrt(12), 2)
      end
    end
  end

  # Pull a column out of the dataframe as a plain Elixir list.
  @spec column(DataFrame.t(), String.t()) :: list()
  defp column(df, name), do: df |> DataFrame.pull(name) |> Series.to_list()
end
