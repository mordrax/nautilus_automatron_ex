defmodule AutomatronEx.Indicators do
  @moduledoc """
  Pure compute core for the overlay moving averages (SMA, EMA, HMA) and the
  panel oscillators (RSI, MACD, ATR, Stochastics).

  No Ash, no database, no web concerns — just series (`[float | nil]`, or a
  `{value_k, value_d}` pair for Stochastics) that reproduce the
  Python/NautilusTrader output bar-for-bar (the cross-language parity oracle is
  `test/automatron_ex/indicators_parity_test.exs`). This is the Elixir port of
  `server/store/indicators.py`; later phases add the envelope / stateful
  indicators on the same registry + `compute/2` plumbing.

  Where the textbook formula and NautilusTrader's class disagree, **the class
  (and so the parity test) wins** — notably: RSI uses an exponential average and
  an `_rsi_max` of `1`, so its value is in `[0, 1]`; ATR's default smoothing is a
  simple (not Wilder) moving average; and Stochastics' `%D` is the native ratio
  `Σ(close − LL) / Σ(HH − LL)`, not an SMA of `%K`. See each function's doc.

  ## Initialization (`nil` prefix)

  Each series is aligned to `closes` and `nil` until the indicator initializes.
  NautilusTrader's `MovingAverage` flips `initialized` once it has seen `period`
  inputs, so every type here is `nil` for the first `period - 1` closes and
  carries a value from index `period - 1` onward — matching `MovingAverage`'s
  `count >= period` rule (confirmed via parity).

  ## Maths (mirrors `nautilus_trader.indicators.averages`)

    * **SMA** — mean of the last `period` closes.
    * **EMA** — `α = 2 / (period + 1)`; seeded with the first close, then
      `EMAᵢ = α·closeᵢ + (1 - α)·EMAᵢ₋₁`.
    * **HMA** — `WMA(2·WMA(closes, period/2) - WMA(closes, period), √period)`,
      with `period/2` and `√period` floored to ints. The inner weighted averages
      carry their partial (pre-initialized) values into the Hull combination, so
      the WMA reproduces NautilusTrader's "last `n` weights" behaviour exactly.
  """

  require Logger

  @typedoc "A close-price series."
  @type closes :: [float()]

  @typedoc "An indicator output series, aligned to the closes and `nil` until initialized."
  @type series :: [float() | nil]

  @typedoc "A registry entry describing one indicator type."
  @type spec :: %{
          type: String.t(),
          label_template: String.t(),
          display: String.t(),
          outputs: [String.t()],
          params: [map()]
        }

  @typedoc "A requested indicator instance (e.g. from viewer-state)."
  @type instance :: %{optional(any()) => any()}

  @typedoc "The computed series for one instance — the Python `IndicatorResult` shape."
  @type result :: %{
          id: any(),
          label: String.t(),
          display: String.t(),
          outputs: %{String.t() => series()},
          datetime: [String.t()]
        }

  @period_param %{name: "period", type: "int", default: 20, min: 2, max: 500}

  @registry [
    %{
      type: "SMA",
      label_template: "SMA({period})",
      display: "overlay",
      outputs: ["value"],
      params: [@period_param]
    },
    %{
      type: "EMA",
      label_template: "EMA({period})",
      display: "overlay",
      outputs: ["value"],
      params: [@period_param]
    },
    %{
      type: "HMA",
      label_template: "HMA({period})",
      display: "overlay",
      outputs: ["value"],
      params: [@period_param]
    },
    %{
      type: "RSI",
      label_template: "RSI({period})",
      display: "panel",
      outputs: ["value"],
      params: [%{name: "period", type: "int", default: 14, min: 2, max: 100}]
    },
    %{
      type: "MACD",
      label_template: "MACD({fast_period},{slow_period})",
      display: "panel",
      outputs: ["value"],
      params: [
        %{name: "fast_period", type: "int", default: 12, min: 2, max: 200},
        %{name: "slow_period", type: "int", default: 26, min: 2, max: 500}
      ]
    },
    %{
      type: "ATR",
      label_template: "ATR({period})",
      display: "panel",
      outputs: ["value"],
      params: [%{name: "period", type: "int", default: 14, min: 1, max: 200}]
    },
    %{
      type: "Stochastics",
      label_template: "Stoch({period_k},{period_d})",
      display: "panel",
      outputs: ["value_k", "value_d"],
      params: [
        %{name: "period_k", type: "int", default: 14, min: 1, max: 200},
        %{name: "period_d", type: "int", default: 3, min: 1, max: 200}
      ]
    }
  ]

  @doc """
  The indicator type registry — one `t:spec/0` per supported type: the overlay
  moving averages (`SMA`, `EMA`, `HMA`) and the panel oscillators (`RSI`, `MACD`,
  `ATR`, `Stochastics`), each with its label template, `display`, output keys,
  and param schema.
  """
  @spec registry() :: [spec()]
  def registry, do: @registry

  @doc """
  Simple moving average: the mean of the last `period` closes, `nil` for the
  first `period - 1` entries (and all entries when there are fewer closes than
  `period`).
  """
  @spec sma(closes(), pos_integer()) :: series()
  def sma(closes, period) when is_integer(period) and period > 0 do
    n = length(closes)

    if n < period do
      List.duplicate(nil, n)
    else
      values =
        closes
        |> Enum.chunk_every(period, 1, :discard)
        |> Enum.map(fn window -> Enum.sum(window) / period end)

      List.duplicate(nil, period - 1) ++ values
    end
  end

  @doc """
  Exponential moving average with `α = 2 / (period + 1)`, seeded with the first
  close and `nil` for the first `period - 1` entries. Mirrors NautilusTrader's
  `ExponentialMovingAverage.update_raw`.
  """
  @spec ema(closes(), pos_integer()) :: series()
  def ema(closes, period) when is_integer(period) and period > 0 do
    alpha = 2.0 / (period + 1.0)

    closes
    |> ema_values(alpha)
    |> nil_prefix(period)
  end

  @doc """
  Hull moving average:
  `WMA(2·WMA(closes, ⌊period/2⌋) - WMA(closes, period), ⌊√period⌋)`, `nil` for
  the first `period - 1` entries. Mirrors NautilusTrader's `HullMovingAverage`.
  """
  @spec hma(closes(), pos_integer()) :: series()
  def hma(closes, period) when is_integer(period) and period >= 2 do
    period_halved = trunc(period / 2)
    period_sqrt = trunc(:math.sqrt(period))

    ma1 = wma(closes, period_halved)
    ma2 = wma(closes, period)
    hull = Enum.zip_with(ma1, ma2, fn a, b -> 2.0 * a - b end)

    hull
    |> wma(period_sqrt)
    |> nil_prefix(period)
  end

  @doc """
  Relative strength index, `nil` for the first `period - 1` closes.

  Mirrors NautilusTrader's `RelativeStrengthIndex`, whose default averaging is
  `EXPONENTIAL` (not Wilder) and whose `_rsi_max` is `1` — so the value is in
  **`[0, 1]`**, computed as `1 - 1/(1 + avg_gain/avg_loss)`, and is `1.0`
  whenever the average loss is `0`. The gain/loss inputs are the consecutive
  close differences (the first input is `0`, like NautilusTrader seeding
  `_last_value` to the first close), split into up-moves and down-moves, then
  each EMA-smoothed with `α = 2 / (period + 1)`. The averages (and thus the RSI)
  initialize once they have seen `period` inputs. The parity test is the oracle
  for this `[0, 1]` form.
  """
  @spec rsi(closes(), pos_integer()) :: series()
  def rsi(closes, period) when is_integer(period) and period > 0 do
    alpha = 2.0 / (period + 1.0)
    {gains, losses} = rsi_gains_losses(closes)
    avg_gain = ema_values(gains, alpha)
    avg_loss = ema_values(losses, alpha)

    avg_gain
    |> Enum.zip_with(avg_loss, fn ag, al ->
      if al == 0.0, do: 1.0, else: 1.0 - 1.0 / (1.0 + ag / al)
    end)
    |> nil_prefix(period)
  end

  @doc """
  Moving average convergence/divergence line, `nil` until the slow EMA
  initializes (the first `max(fast, slow) - 1` entries).

  Mirrors NautilusTrader's `MovingAverageConvergenceDivergence` with its default
  `EXPONENTIAL` averages: the difference of the running `EMA(close, fast)` and
  `EMA(close, slow)` values. NautilusTrader's MACD exposes only this line (no
  signal or histogram), and initializes once both inner EMAs have — i.e. on the
  larger period. `α = 2 / (period + 1)` for each EMA.
  """
  @spec macd(closes(), pos_integer(), pos_integer()) :: series()
  def macd(closes, fast, slow)
      when is_integer(fast) and is_integer(slow) and fast > 0 and slow > 0 do
    fast_vals = ema_values(closes, 2.0 / (fast + 1.0))
    slow_vals = ema_values(closes, 2.0 / (slow + 1.0))

    fast_vals
    |> Enum.zip_with(slow_vals, fn f, s -> f - s end)
    |> nil_prefix(max(fast, slow))
  end

  @doc """
  Average true range, `nil` for the first `period - 1` bars.

  Mirrors NautilusTrader's `AverageTrueRange`, whose defaults are a **SIMPLE**
  moving average (not EMA/Wilder) with `use_previous = true`: the true range is
  `max(prev_close, high) - min(low, prev_close)` (with `prev_close` seeded to the
  first close, so the first TR is `high - low`), and ATR is `SMA(TR, period)`,
  which initializes once it has seen `period` true ranges. The parity test is the
  oracle for the SMA (rather than Wilder) smoothing.
  """
  @spec atr(closes(), closes(), closes(), pos_integer()) :: series()
  def atr(highs, lows, closes, period) when is_integer(period) and period > 0 do
    highs
    |> true_ranges(lows, closes)
    |> sma(period)
  end

  @doc """
  Stochastic oscillator `%K`/`%D`, each `nil` for the first `period_k - 1` bars.

  Mirrors NautilusTrader's `Stochastics` with its defaults (`slowing = 1`, the
  `"ratio"` `%D` method):

    * `%K = 100 · (close − LL) / (HH − LL)` over the trailing `period_k` bars
      (`HH`/`LL` are the highest high / lowest low of that window);
    * `%D = 100 · Σ(close − LL) / Σ(HH − LL)` over the trailing `period_d` bars —
      the native ratio form, **not** an SMA of `%K`.

  Initializes once `period_k` bars are seen. When `HH == LL` (a flat window)
  NautilusTrader returns early, so both values carry their previous reading; this
  port reproduces that, including accumulating the `%D` numerator/denominator on
  every bar. The parity test is the oracle.
  """
  @spec stochastics(closes(), closes(), closes(), pos_integer(), pos_integer()) ::
          {series(), series()}
  def stochastics(highs, lows, closes, period_k, period_d)
      when is_integer(period_k) and is_integer(period_d) and period_k > 0 and period_d > 0 do
    {kd, _state} =
      [highs, lows, closes]
      |> Enum.zip()
      |> Enum.map_reduce(stoch_init(), fn {high, low, close}, state ->
        stoch_step(high, low, close, period_k, period_d, state)
      end)

    {ks, ds} = Enum.unzip(kd)
    {nil_prefix(ks, period_k), nil_prefix(ds, period_k)}
  end

  @doc """
  Compute the requested indicator `instances` over `bars` (a `Reader.read_bars/2`
  map with `:datetime`, `:close`, and — for ATR/Stochastics — `:high` and
  `:low`), returning one `t:result/0` per valid instance in input order.

  Each instance is a map with an `id`, a `type` (a registry type string), and
  `params` (every param named by the type's schema, e.g. `period`, or
  `fast_period`/`slow_period` for MACD); string or atom keys are both accepted.
  Multi-output types (Stochastics) populate multiple `outputs` keys (`value_k`,
  `value_d`). Instances with an unknown type or out-of-range/missing params are
  skipped with a logged warning, so one bad selection never drops the others.
  """
  @spec compute(map(), [instance()]) :: [result()]
  def compute(bars, instances) when is_list(instances) do
    instances
    |> Enum.map(&compute_instance(bars, &1))
    |> Enum.reject(&is_nil/1)
  end

  # --- per-instance compute -------------------------------------------------

  @spec compute_instance(map(), instance()) :: result() | nil
  defp compute_instance(bars, instance) do
    type = get(instance, :type)

    case Enum.find(@registry, &(&1.type == type)) do
      nil ->
        Logger.warning("Indicators.compute: skipping unknown indicator type #{inspect(type)}")
        nil

      spec ->
        build_result(bars, instance, spec)
    end
  end

  @spec build_result(map(), instance(), spec()) :: result() | nil
  defp build_result(bars, instance, spec) do
    params = get(instance, :params) || %{}

    case validate_params(spec, params) do
      {:ok, validated} ->
        %{
          id: get(instance, :id),
          label: format_label(spec.label_template, validated),
          display: spec.display,
          outputs: outputs_for(spec.type, bars, validated),
          datetime: bars.datetime
        }

      {:error, reason} ->
        Logger.warning(
          "Indicators.compute: skipping #{spec.type} instance with bad params (#{reason})"
        )

        nil
    end
  end

  # Project each type's output series from the validated (string-keyed) params.
  # ATR/Stochastics read `bars.high`/`bars.low` as well as `bars.close`;
  # Stochastics is the one multi-output type (`value_k`, `value_d`).
  @spec outputs_for(String.t(), map(), map()) :: %{String.t() => series()}
  defp outputs_for("SMA", bars, %{"period" => p}), do: %{"value" => sma(bars.close, p)}
  defp outputs_for("EMA", bars, %{"period" => p}), do: %{"value" => ema(bars.close, p)}
  defp outputs_for("HMA", bars, %{"period" => p}), do: %{"value" => hma(bars.close, p)}
  defp outputs_for("RSI", bars, %{"period" => p}), do: %{"value" => rsi(bars.close, p)}

  defp outputs_for("MACD", bars, %{"fast_period" => fast, "slow_period" => slow}),
    do: %{"value" => macd(bars.close, fast, slow)}

  defp outputs_for("ATR", bars, %{"period" => p}),
    do: %{"value" => atr(bars.high, bars.low, bars.close, p)}

  defp outputs_for("Stochastics", bars, %{"period_k" => period_k, "period_d" => period_d}) do
    {value_k, value_d} = stochastics(bars.high, bars.low, bars.close, period_k, period_d)
    %{"value_k" => value_k, "value_d" => value_d}
  end

  # Validate every param the type's schema declares (all are `int` today),
  # returning a name -> value map for the label and compute, or the first error.
  @spec validate_params(spec(), map()) :: {:ok, %{String.t() => integer()}} | {:error, String.t()}
  defp validate_params(spec, params) do
    Enum.reduce_while(spec.params, {:ok, %{}}, fn schema, {:ok, acc} ->
      value = get_param(params, schema.name)

      cond do
        not is_integer(value) ->
          {:halt, {:error, "#{schema.name} must be an integer, got #{inspect(value)}"}}

        value < schema.min or value > schema.max ->
          {:halt, {:error, "#{schema.name} #{value} out of range [#{schema.min}, #{schema.max}]"}}

        true ->
          {:cont, {:ok, Map.put(acc, schema.name, value)}}
      end
    end)
  end

  # --- moving-average helpers -----------------------------------------------

  # The EMA running value at every index (no `nil` prefix yet). Faithful to
  # NautilusTrader: the first input seeds `value`, then every input (including
  # the first) applies `α·value + (1 - α)·value`.
  @spec ema_values(closes(), float()) :: [float()]
  defp ema_values(closes, alpha) do
    {values, _} =
      Enum.map_reduce(closes, {0.0, false}, fn close, {prev, has_inputs?} ->
        seed = if has_inputs?, do: prev, else: close
        value = alpha * close + (1.0 - alpha) * seed
        {value, {value, true}}
      end)

    values
  end

  # Weighted moving average value at every index. Weights are `1..period`
  # (largest on the most recent close); before the window fills, NautilusTrader
  # uses the *last* `m` weights for the `m` available inputs, which this folds in
  # via `(period - m + 1)..period`. Always carries a value (never `nil`), since
  # the Hull combination consumes the inner WMAs' partial values.
  @spec wma(closes(), pos_integer()) :: [float()]
  defp wma(values, period) do
    {series, _} =
      Enum.map_reduce(values, [], fn value, window ->
        window = Enum.take(window ++ [value], -period)
        m = length(window)
        weights = Enum.to_list((period - m + 1)..period)

        weighted =
          window |> Enum.zip(weights) |> Enum.reduce(0.0, fn {v, w}, acc -> acc + v * w end)

        {weighted / Enum.sum(weights), window}
      end)

    series
  end

  # --- panel-indicator helpers ----------------------------------------------

  # Split close-to-close moves into (up-move, down-move) input pairs for the RSI
  # average gain/loss. The first input is `0` (NautilusTrader seeds `_last_value`
  # to the first close, so the first gain is `0`); thereafter `up = max(Δ, 0)`
  # and `down = max(-Δ, 0)`.
  @spec rsi_gains_losses(closes()) :: {[float()], [float()]}
  defp rsi_gains_losses([]), do: {[], []}

  defp rsi_gains_losses([_first | rest] = closes) do
    deltas = [0.0 | Enum.zip_with(rest, closes, fn cur, prev -> cur - prev end)]
    deltas |> Enum.map(fn d -> {max(d, 0.0), max(-d, 0.0)} end) |> Enum.unzip()
  end

  # The true-range series for ATR: `max(prev_close, high) - min(low, prev_close)`
  # with `prev_close` seeded to the first close (so the first TR is `high - low`),
  # matching NautilusTrader's `use_previous` true range.
  @spec true_ranges(closes(), closes(), closes()) :: [float()]
  defp true_ranges(highs, lows, closes) do
    [highs, lows, prev_closes(closes)]
    |> Enum.zip_with(fn [high, low, prev] -> max(prev, high) - min(low, prev) end)
  end

  @spec prev_closes(closes()) :: [float()]
  defp prev_closes([]), do: []
  defp prev_closes([first | _] = closes), do: [first | Enum.drop(closes, -1)]

  # One Stochastics bar update, mirroring NautilusTrader's `update_raw`. State
  # carries the trailing highs/lows (`period_k`), the ratio-method numerator /
  # denominator deques (`period_d`), and the last %K/%D for the flat-window
  # carry. The %D deques accumulate on *every* bar, before the guard.
  @spec stoch_init() :: map()
  defp stoch_init, do: %{highs: [], lows: [], c_sub_l: [], h_sub_l: [], last_k: 0.0, last_d: 0.0}

  @spec stoch_step(float(), float(), float(), pos_integer(), pos_integer(), map()) ::
          {{float(), float()}, map()}
  defp stoch_step(high, low, close, period_k, period_d, state) do
    highs = Enum.take(state.highs ++ [high], -period_k)
    lows = Enum.take(state.lows ++ [low], -period_k)
    max_high = Enum.max(highs)
    min_low = Enum.min(lows)

    c_sub_l = Enum.take(state.c_sub_l ++ [close - min_low], -period_d)
    h_sub_l = Enum.take(state.h_sub_l ++ [max_high - min_low], -period_d)

    {value_k, value_d} =
      if max_high == min_low do
        {state.last_k, state.last_d}
      else
        k = 100.0 * (close - min_low) / (max_high - min_low)
        sum_h = Enum.sum(h_sub_l)
        d = if sum_h == 0.0, do: 0.0, else: 100.0 * Enum.sum(c_sub_l) / sum_h
        {k, d}
      end

    state = %{
      state
      | highs: highs,
        lows: lows,
        c_sub_l: c_sub_l,
        h_sub_l: h_sub_l,
        last_k: value_k,
        last_d: value_d
    }

    {{value_k, value_d}, state}
  end

  # Replace the first `period - 1` values with `nil` so the series initializes on
  # the same index as NautilusTrader (`count >= period`).
  @spec nil_prefix([float()], pos_integer()) :: series()
  defp nil_prefix(values, period) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> if index < period - 1, do: nil, else: value end)
  end

  # --- misc -----------------------------------------------------------------

  # Interpolate `{param}` placeholders in a label template, e.g. "SMA({period})".
  @spec format_label(String.t(), map()) :: String.t()
  defp format_label(template, params) do
    Enum.reduce(params, template, fn {key, value}, acc ->
      String.replace(acc, "{#{key}}", to_string(value))
    end)
  end

  # Fetch a key from an instance/params map accepting either atom or string keys
  # (instances arrive as atom-keyed literals in tests and string-keyed JSON from
  # the persisted viewer-state).
  @spec get(map(), atom()) :: any()
  defp get(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  # Fetch a param by its (string) schema name, accepting either string or atom
  # keys — params arrive string-keyed from JSON viewer-state and (in tests)
  # sometimes atom-keyed. The name comes from the registry (a fixed set), so
  # interning it as an atom is safe.
  @spec get_param(map(), String.t()) :: any()
  defp get_param(params, name) when is_binary(name) do
    case Map.fetch(params, name) do
      {:ok, value} -> value
      :error -> Map.get(params, String.to_atom(name))
    end
  end
end
