defmodule AutomatronExWeb.RunDetailLive do
  @moduledoc """
  `/runs/:run_id` — the run-detail page: a candlestick chart of the run's bars
  with trade entry/exit overlays, a trade navigator, and a trades table.

  Read-through from the catalog (no Postgres): `mount/3` reads the run summary
  with `AutomatronEx.Catalog.Reader` and, once the socket is connected, loads the
  OHLC bars + trades and hands them to the `CandlestickChart` JS hook via
  `push_event("chart:init", …)`. The hook owns the eCharts instance; the server
  only ships data and trade-focus commands.

  Events: the navigator (`prev_trade`/`next_trade`) and a trade row / chart
  markLine click (`select_trade`) move the focused trade and push
  `chart:focus_trade %{index}` so the chart zooms to it. The indicator sidebar
  (Phase 3a) adds / removes / parametrizes SMA/EMA/HMA overlays: each change
  recomputes via `AutomatronEx.Indicators.compute/2`, pushes
  `chart:set_indicators %{series}` to the hook, and upserts the per-run
  `AutomatronEx.Runs.ViewerState` so selections reload on the next mount. An
  unknown run renders a not-found message instead of crashing.
  """

  use AutomatronExWeb, :live_view

  require Logger

  alias AutomatronEx.Catalog.Reader
  alias AutomatronEx.Indicators
  alias AutomatronEx.Runs.ViewerState

  # Per-instance default colors, cycled as overlays are added. Color also lives in
  # viewer-state here (a documented divergence from the Python localStorage source).
  @palette ~w(#2563eb #dc2626 #16a34a #d97706 #7c3aed #db2777)

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Run #{run_id}")
      |> assign(:run_id, run_id)
      |> assign(:not_found, false)
      |> assign(:total_positions, 0)
      |> assign(:total_fills, 0)
      |> assign(:bar_types, [])
      |> assign(:trades, [])
      |> assign(:current_index, 0)
      |> assign(:registry, Indicators.registry())
      |> assign(:indicators, load_indicators(run_id))
      |> assign(:ohlc, empty_ohlc())

    {:ok, load_run(socket)}
  end

  # Read the run summary (cheap: config + feather row counts) on every mount so
  # the header renders without a socket; the heavier bars/trades read and the
  # chart push happen only on the connected mount. An unknown run → not-found.
  defp load_run(socket) do
    case Reader.read_run_detail(AutomatronEx.catalog_path(), socket.assigns.run_id) do
      {:ok, detail} ->
        socket
        |> assign(:total_positions, detail.total_positions)
        |> assign(:total_fills, detail.total_fills)
        |> assign(:bar_types, detail.bar_types)
        |> maybe_push_chart(detail)

      {:error, _reason} ->
        assign(socket, :not_found, true)
    end
  end

  # On the live (connected) mount, load the OHLC bars + trades and deliver them to
  # the CandlestickChart hook; the trades table renders the same list. After
  # init, center the chart on the selected trade (index 0) so it opens on trade #1
  # rather than the most-recent bars, matching the React reference (nae-g9c).
  defp maybe_push_chart(socket, detail) do
    if connected?(socket) do
      catalog = AutomatronEx.catalog_path()
      ohlc = read_ohlc(catalog, detail.bar_types)
      trades = read_trades(catalog, detail.run_id)

      socket
      |> assign(:ohlc, ohlc)
      |> assign(:trades, trades)
      |> push_event("chart:init", %{ohlc: ohlc, trades: trades})
      |> push_event("chart:focus_trade", %{index: socket.assigns.current_index})
      |> push_indicators()
    else
      socket
    end
  end

  # The run's first bar type drives the chart; a missing/empty bar directory
  # degrades to an empty chart rather than crashing the page.
  defp read_ohlc(catalog, [bar_type | _]) do
    case Reader.read_bars(catalog, bar_type) do
      {:ok, ohlc} -> ohlc
      {:error, _reason} -> empty_ohlc()
    end
  end

  defp read_ohlc(_catalog, []), do: empty_ohlc()

  defp empty_ohlc, do: %{datetime: [], open: [], high: [], low: [], close: [], volume: []}

  defp read_trades(catalog, run_id) do
    case Reader.read_trades(catalog, run_id) do
      {:ok, trades} -> trades
      {:error, _reason} -> []
    end
  end

  @impl true
  def handle_event("select_trade", %{"index" => index}, socket),
    do: {:noreply, focus_trade(socket, to_index(index))}

  def handle_event("prev_trade", _params, socket),
    do: {:noreply, focus_trade(socket, socket.assigns.current_index - 1)}

  def handle_event("next_trade", _params, socket),
    do: {:noreply, focus_trade(socket, socket.assigns.current_index + 1)}

  # Fast step (±50) — CapsLock+Shift+Arrow in the TradeHotkeys hook, mirroring the
  # React use-hotkeys fast jump. `focus_trade` clamps, so the bounds are safe.
  def handle_event("prev_trade_fast", _params, socket),
    do: {:noreply, focus_trade(socket, socket.assigns.current_index - 50)}

  def handle_event("next_trade_fast", _params, socket),
    do: {:noreply, focus_trade(socket, socket.assigns.current_index + 50)}

  # --- indicator sidebar events --------------------------------------------

  # Append a new overlay of the chosen type (seeded with its default period + a
  # palette color), then recompute / push / persist. Unknown types are ignored.
  def handle_event("add_indicator", %{"type" => type}, socket) do
    if known_type?(socket.assigns.registry, type) do
      instance = build_instance(type, socket.assigns.indicators, socket.assigns.registry)
      socket = assign(socket, :indicators, socket.assigns.indicators ++ [instance])
      {:noreply, sync_indicators(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_indicator", %{"id" => id}, socket) do
    indicators = Enum.reject(socket.assigns.indicators, &(&1.id == id))
    {:noreply, sync_indicators(assign(socket, :indicators, indicators))}
  end

  # The per-instance form fires on any change, carrying the row id (hidden) plus
  # the current period + color; apply both (idempotent for the unchanged one).
  # The id field is "indicator_id" (not "id") to avoid shadowing the form's DOM id.
  def handle_event("update_indicator", %{"indicator_id" => id} = params, socket) do
    indicators =
      Enum.map(socket.assigns.indicators, fn
        %{id: ^id} = instance -> apply_edit(instance, params)
        instance -> instance
      end)

    {:noreply, sync_indicators(assign(socket, :indicators, indicators))}
  end

  # Clamp the requested trade index into range, remember it, and tell the chart
  # hook to zoom to it.
  defp focus_trade(socket, index) do
    index = clamp(index, length(socket.assigns.trades))

    socket
    |> assign(:current_index, index)
    |> push_event("chart:focus_trade", %{index: index})
  end

  # `select_trade` arrives from the JS hook as an integer and from a table-row
  # `phx-value-index` as a string; normalize both to an integer.
  defp to_index(index) when is_integer(index), do: index
  defp to_index(index) when is_binary(index), do: String.to_integer(index)

  defp clamp(_index, 0), do: 0
  defp clamp(index, _count) when index < 0, do: 0
  defp clamp(index, count) when index >= count, do: count - 1
  defp clamp(index, _count), do: index

  # --- indicator helpers ----------------------------------------------------

  # Load the run's persisted overlay selections (viewer-state) into the in-memory
  # instance shape; an absent row (or any read error) means "no overlays".
  defp load_indicators(run_id) do
    case ViewerState.get_by_run(run_id) do
      {:ok, %{indicators: instances}} when is_list(instances) ->
        Enum.map(instances, &normalize_instance/1)

      _ ->
        []
    end
  end

  # Persisted instances cross the jsonb boundary string-keyed; bring them back to
  # the atom-keyed %{id, type, params: %{period}, color} shape the sidebar renders
  # and `Indicators.compute/2` consumes.
  defp normalize_instance(instance) do
    %{
      id: fetch(instance, "id"),
      type: fetch(instance, "type"),
      params: %{period: fetch(instance, ["params", "period"])},
      color: fetch(instance, "color")
    }
  end

  defp build_instance(type, existing, registry) do
    spec = Enum.find(registry, &(&1.type == type))

    %{
      id: "ind-" <> Integer.to_string(System.unique_integer([:positive])),
      type: type,
      params: %{period: default_period(spec)},
      color: Enum.at(@palette, rem(length(existing), length(@palette)))
    }
  end

  defp apply_edit(instance, params) do
    instance
    |> edit_period(params["period"])
    |> edit_color(params["color"])
  end

  defp edit_period(instance, raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {period, _} -> put_in(instance.params.period, clamp_period(period))
      :error -> instance
    end
  end

  defp edit_period(instance, _), do: instance

  defp edit_color(instance, color) when is_binary(color) and color != "",
    do: %{instance | color: color}

  defp edit_color(instance, _), do: instance

  # Recompute every overlay, push the series to the chart hook, and persist the
  # selection. Always pushes (even an empty list) so a removal clears the hook's
  # overlay lines.
  defp sync_indicators(socket) do
    socket
    |> persist_indicators()
    |> push_event("chart:set_indicators", %{series: compute_series(socket)})
  end

  # On (re)connect, re-push the persisted overlays after `chart:init` so the hook
  # re-draws them; nothing to do when there are no selections.
  defp push_indicators(socket) do
    case socket.assigns.indicators do
      [] -> socket
      _ -> push_event(socket, "chart:set_indicators", %{series: compute_series(socket)})
    end
  end

  # `Indicators.compute/2` results carry no color (color is viewer-state, not
  # compute output), so graft each instance's color back on by id for the hook.
  defp compute_series(socket) do
    instances = socket.assigns.indicators

    socket.assigns.ohlc
    |> Indicators.compute(instances)
    |> Enum.map(&Map.put(&1, :color, color_for(&1.id, instances)))
  end

  defp persist_indicators(socket) do
    case ViewerState.upsert(%{
           run_id: socket.assigns.run_id,
           indicators: socket.assigns.indicators
         }) do
      {:ok, _state} -> :ok
      {:error, reason} -> Logger.warning("viewer-state upsert failed: #{inspect(reason)}")
    end

    socket
  end

  defp color_for(id, instances) do
    case Enum.find(instances, &(&1.id == id)) do
      %{color: color} -> color
      _ -> nil
    end
  end

  defp known_type?(registry, type), do: Enum.any?(registry, &(&1.type == type))

  defp default_period(nil), do: 20

  defp default_period(spec) do
    case Enum.find(spec.params, &(&1.name == "period")) do
      %{default: default} -> default
      _ -> 20
    end
  end

  defp clamp_period(period), do: period |> max(2) |> min(500)

  # Fetch a (possibly nested) key from a string-keyed jsonb map, tolerating
  # atom-keyed maps too (instances may already be atom-keyed in-process).
  defp fetch(map, keys) when is_list(keys), do: Enum.reduce(keys, map, &fetch(&2, &1))

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, safe_existing_atom(key))
    end
  end

  defp fetch(_map, _key), do: nil

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp safe_existing_atom(_key), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} max_width="max-w-none">
      <div :if={@not_found}>
        <.header>
          Run not found
          <:subtitle>{@run_id}</:subtitle>
        </.header>

        <div class="py-8 text-center text-base-content/70">
          <p>
            No run with id <span class="font-mono">{@run_id}</span> was found in the catalog.
          </p>
          <.button navigate={~p"/"} class="btn btn-soft mt-4">← Back to runs</.button>
        </div>
      </div>

      <div :if={!@not_found}>
        <.header>
          Run {@run_id}
          <:subtitle>{@total_positions} positions · {@total_fills} fills</:subtitle>
          <:actions>
            <.button navigate={~p"/"} class="btn btn-soft">← Back to runs</.button>
          </:actions>
        </.header>

        <div :if={@bar_types != []} class="mb-4 flex flex-wrap gap-2">
          <span
            :for={bar_type <- @bar_types}
            class="badge badge-soft badge-neutral font-mono"
          >
            {bar_type}
          </span>
        </div>

        <div class="flex flex-col gap-4 lg:flex-row">
          <div class="min-w-0 flex-1">
            <div
              id="run-chart"
              phx-hook="CandlestickChart"
              phx-update="ignore"
              class="h-[480px] w-full"
            >
            </div>

            <div
              :if={@trades != []}
              id="trade-navigator"
              phx-hook="TradeHotkeys"
              class="flex items-center justify-center gap-3 py-4"
            >
              <.button
                class="btn btn-soft"
                phx-click="prev_trade"
                disabled={@current_index <= 0}
                title="CapsLock+← (CapsLock+Shift+← jumps 50)"
              >
                ← Prev
              </.button>
              <span class="text-sm text-base-content/70">
                Trade {@current_index + 1} / {length(@trades)}
              </span>
              <.button
                class="btn btn-soft"
                phx-click="next_trade"
                disabled={@current_index >= length(@trades) - 1}
                title="CapsLock+→ (CapsLock+Shift+→ jumps 50)"
              >
                Next →
              </.button>
            </div>

            <p :if={@trades != []} class="pb-2 text-center text-xs text-base-content/60">
              Tip: turn on CapsLock, then ← / → to step trades (Shift+← / Shift+→ jumps 50).
            </p>

            <div :if={@trades != []} class="max-h-[28rem] overflow-auto">
              <table class="table table-zebra table-sm table-pin-rows">
                <thead>
                  <tr>
                    <th>#</th>
                    <th>Direction</th>
                    <th>Entry</th>
                    <th>Exit</th>
                    <th class="text-right">Qty</th>
                    <th class="text-right">PnL</th>
                  </tr>
                </thead>
                <tbody id="trades">
                  <tr
                    :for={{trade, index} <- Enum.with_index(@trades)}
                    id={"trade-#{trade.relative_id}"}
                    phx-click="select_trade"
                    phx-value-index={index}
                    class={["hover:cursor-pointer", index == @current_index && "active"]}
                  >
                    <td class="font-mono">{"#"}{trade.relative_id}</td>
                    <td>{trade.direction}</td>
                    <td class="whitespace-nowrap">
                      {fmt_datetime(trade.entry_datetime)} @ {fmt_number(trade.entry_price)}
                    </td>
                    <td class="whitespace-nowrap">
                      {fmt_datetime(trade.exit_datetime)} @ {fmt_number(trade.exit_price)}
                    </td>
                    <td class="text-right">{fmt_number(trade.quantity)}</td>
                    <td class={["text-right", pnl_class(trade.pnl)]}>{fmt_number(trade.pnl)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <aside class="w-full shrink-0 lg:w-64">
            <div class="rounded-box border border-base-300 p-4">
              <h2 class="px-1 text-sm font-semibold">Indicators</h2>

              <form id="add-indicator" phx-submit="add_indicator" class="mt-3 flex gap-2">
                <select
                  name="type"
                  aria-label="Indicator type"
                  class="select select-bordered select-sm flex-1"
                >
                  <option :for={spec <- @registry} value={spec.type}>{spec.type}</option>
                </select>
                <button type="submit" class="btn btn-sm btn-primary">Add</button>
              </form>

              <ul :if={@indicators != []} class="mt-4 space-y-3">
                <li
                  :for={ind <- @indicators}
                  id={"indicator-row-#{ind.id}"}
                  class="rounded-box bg-base-200 p-2"
                >
                  <form
                    id={"indicator-#{ind.id}"}
                    phx-change="update_indicator"
                    class="flex items-center gap-2"
                  >
                    <input type="hidden" name="indicator_id" value={ind.id} />
                    <span class="badge badge-soft badge-neutral font-mono text-xs">{ind.type}</span>
                    <input
                      type="number"
                      name="period"
                      value={ind.params.period}
                      min="2"
                      max="500"
                      aria-label={"#{ind.type} period"}
                      class="input input-xs w-16"
                    />
                    <input
                      type="color"
                      name="color"
                      value={ind.color}
                      aria-label={"#{ind.type} color"}
                      class="h-6 w-8 cursor-pointer rounded border border-base-300"
                    />
                    <button
                      id={"remove-#{ind.id}"}
                      type="button"
                      phx-click="remove_indicator"
                      phx-value-id={ind.id}
                      aria-label={"Remove #{ind.type}"}
                      class="btn btn-ghost btn-xs ml-auto"
                    >
                      ✕
                    </button>
                  </form>
                </li>
              </ul>

              <p :if={@indicators == []} class="mt-3 text-sm text-base-content/70">
                No overlays yet — add SMA, EMA or HMA above.
              </p>
            </div>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- display helpers -----------------------------------------------------

  # ISO-8601 "YYYY-MM-DDTHH:MM:SS+00:00" -> compact "YYYY-MM-DD HH:MM".
  defp fmt_datetime(<<date::binary-size(10), "T", time::binary-size(5), _rest::binary>>),
    do: date <> " " <> time

  defp fmt_datetime(value), do: to_string(value)

  defp fmt_number(nil), do: "—"

  defp fmt_number(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 2])

  defp fmt_number(value), do: to_string(value)

  defp pnl_class(pnl) when is_float(pnl) and pnl > 0, do: "text-success"
  defp pnl_class(pnl) when is_float(pnl) and pnl < 0, do: "text-error"
  defp pnl_class(_pnl), do: nil
end
