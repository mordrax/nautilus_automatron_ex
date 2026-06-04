defmodule AutomatronEx.Indicators do
  @moduledoc """
  Pure compute core for overlay moving-average indicators (SMA, EMA, HMA).

  No Ash, no database, no web concerns — just `closes -> [float | nil]` series
  that reproduce the Python/NautilusTrader output bar-for-bar (the cross-language
  parity oracle is `test/automatron_ex/indicators_parity_test.exs`). This is the
  Elixir port of `server/store/indicators.py` for the three overlay types; later
  phases add the panel / envelope / stateful indicators on the same registry +
  `compute/2` plumbing.

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
    }
  ]

  @doc """
  The indicator type registry — one `t:spec/0` per supported overlay type
  (`SMA`, `EMA`, `HMA`), each with its label template and `period` param schema.
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
  Compute the requested indicator `instances` over `bars` (a `Reader.read_bars/2`
  map with `:close` and `:datetime`), returning one `t:result/0` per valid
  instance in input order.

  Each instance is a map with an `id`, a `type` (a registry type string), and
  `params` (with a `period`); string or atom keys are both accepted. Instances
  with an unknown type or out-of-range params are skipped with a logged warning,
  so one bad selection never drops the others.
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

    case validate_period(spec, params) do
      {:ok, period} ->
        %{
          id: get(instance, :id),
          label: format_label(spec.label_template, %{"period" => period}),
          display: spec.display,
          outputs: %{"value" => series_for(spec.type, bars.close, period)},
          datetime: bars.datetime
        }

      {:error, reason} ->
        Logger.warning(
          "Indicators.compute: skipping #{spec.type} instance with bad params (#{reason})"
        )

        nil
    end
  end

  @spec series_for(String.t(), closes(), pos_integer()) :: series()
  defp series_for("SMA", closes, period), do: sma(closes, period)
  defp series_for("EMA", closes, period), do: ema(closes, period)
  defp series_for("HMA", closes, period), do: hma(closes, period)

  @spec validate_period(spec(), map()) :: {:ok, pos_integer()} | {:error, String.t()}
  defp validate_period(spec, params) do
    schema = Enum.find(spec.params, &(&1.name == "period"))
    period = get(params, :period)

    cond do
      not is_integer(period) ->
        {:error, "period must be an integer, got #{inspect(period)}"}

      period < schema.min or period > schema.max ->
        {:error, "period #{period} out of range [#{schema.min}, #{schema.max}]"}

      true ->
        {:ok, period}
    end
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
end
