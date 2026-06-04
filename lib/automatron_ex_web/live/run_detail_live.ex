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
  `chart:focus_trade %{index}` so the chart zooms to it. An unknown run renders a
  not-found message instead of crashing (the indicator sidebar is inert until
  Phase 3).
  """

  use AutomatronExWeb, :live_view

  alias AutomatronEx.Catalog.Reader

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
  # the CandlestickChart hook; the trades table renders the same list.
  defp maybe_push_chart(socket, detail) do
    if connected?(socket) do
      catalog = AutomatronEx.catalog_path()
      ohlc = read_ohlc(catalog, detail.bar_types)
      trades = read_trades(catalog, detail.run_id)

      socket
      |> assign(:trades, trades)
      |> push_event("chart:init", %{ohlc: ohlc, trades: trades})
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
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
            <div id="run-chart" phx-hook="CandlestickChart" class="h-[480px] w-full"></div>

            <div
              :if={@trades != []}
              id="trade-navigator"
              class="flex items-center justify-center gap-3 py-4"
            >
              <.button class="btn btn-soft" phx-click="prev_trade" disabled={@current_index <= 0}>
                ← Prev
              </.button>
              <span class="text-sm text-base-content/70">
                Trade {@current_index + 1} / {length(@trades)}
              </span>
              <.button
                class="btn btn-soft"
                phx-click="next_trade"
                disabled={@current_index >= length(@trades) - 1}
              >
                Next →
              </.button>
            </div>

            <div :if={@trades != []} class="overflow-x-auto">
              <table class="table table-zebra table-sm">
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
            <fieldset
              disabled
              aria-disabled="true"
              class="rounded-box border border-base-300 p-4 opacity-60"
            >
              <legend class="px-1 text-sm font-semibold">Indicators</legend>
              <p class="text-sm text-base-content/70">
                Indicator overlays and key levels arrive in <span class="font-semibold">Phase 3</span>.
              </p>
              <label class="mt-3 flex items-center gap-2 text-sm">
                <input type="checkbox" class="checkbox checkbox-sm" disabled /> EMA
              </label>
              <label class="mt-2 flex items-center gap-2 text-sm">
                <input type="checkbox" class="checkbox checkbox-sm" disabled /> Volume
              </label>
            </fieldset>
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
