defmodule AutomatronExWeb.RunsLive do
  @moduledoc """
  `/` — the runs dashboard.

  A plain LiveView (no JS hooks; charts arrive in Phase 2) over the Postgres
  `AutomatronEx.Runs.Run` index: a sortable / filterable / paginated table whose
  columns are the run identity fields plus the 12 embedded trade metrics. Sort,
  filter, and pagination are all expressed as Ash queries against Postgres.

  A "Sync catalog" button runs `Run.sync` (rescan the on-disk catalog, recompute
  metrics, upsert rows) and reloads the table. With nothing synced the page shows
  an empty state; when the catalog itself is missing/unreadable that empty state
  carries the reason rather than crashing (spec §Error handling). Each row links
  to `/runs/:run_id`, the route reserved for the Phase 2 run-detail page.
  """

  use AutomatronExWeb, :live_view

  require Ash.Query

  alias AutomatronEx.Runs.{Run, RunMetric}

  # Run identity columns, in display order: {attribute, header label}.
  @identity_columns [
    {:run_id, "Run"},
    {:trader_id, "Trader"},
    {:strategy, "Strategy"},
    {:total_positions, "Positions"},
    {:total_fills, "Fills"}
  ]

  # Header labels for the 12 metric attributes. Keyed by the canonical metric
  # names so the column set stays in lockstep with `RunMetric.keys/0` (a missing
  # label fails the compile, forcing this map to track the metric spec).
  @metric_labels %{
    total_pnl: "Total PnL",
    win_rate: "Win rate",
    expectancy: "Expectancy",
    sharpe_ratio: "Sharpe",
    avg_win: "Avg win",
    avg_loss: "Avg loss",
    win_loss_ratio: "Win/Loss",
    wins: "Wins",
    losses: "Losses",
    avg_hold_hours: "Avg hold (h)",
    pnl_per_week: "PnL/wk",
    trades_per_week: "Trades/wk"
  }

  @metric_columns Enum.map(RunMetric.keys(), fn key -> {key, Map.fetch!(@metric_labels, key)} end)

  # Every column the table renders / can sort on, in order.
  @columns @identity_columns ++ @metric_columns
  @sortable_fields Enum.map(@columns, &elem(&1, 0))

  @default_sort :run_id
  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Runs")
      |> assign(:columns, @columns)
      |> assign(:filter, "")
      |> assign(:sort_by, @default_sort)
      |> assign(:sort_dir, :asc)
      |> assign(:page, 1)
      |> load_runs()

    {:ok, socket}
  end

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    socket =
      case safe_field(field) do
        nil ->
          socket

        field ->
          {sort_by, sort_dir} =
            toggle_sort(socket.assigns.sort_by, socket.assigns.sort_dir, field)

          socket
          |> assign(:sort_by, sort_by)
          |> assign(:sort_dir, sort_dir)
          |> load_runs()
      end

    {:noreply, socket}
  end

  def handle_event("filter", %{"query" => query}, socket) do
    socket =
      socket
      |> assign(:filter, query)
      |> assign(:page, 1)
      |> load_runs()

    {:noreply, socket}
  end

  def handle_event("sync", _params, socket) do
    socket =
      case sync_catalog() do
        {:ok, result} ->
          socket
          |> put_flash(:info, sync_message(result))
          |> assign(:page, 1)
          |> load_runs()

        {:error, message} ->
          put_flash(socket, :error, "Sync failed: #{message}")
      end

    {:noreply, socket}
  end

  def handle_event("next_page", _params, socket) do
    {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_runs()}
  end

  def handle_event("prev_page", _params, socket) do
    {:noreply, socket |> assign(:page, socket.assigns.page - 1) |> load_runs()}
  end

  # --- query ---------------------------------------------------------------

  # Load the current page of runs from Postgres: count the filtered set (for the
  # pager), clamp the page into range, then read that slice sorted as requested.
  defp load_runs(socket) do
    %{filter: filter, sort_by: sort_by, sort_dir: sort_dir, page: page} = socket.assigns

    base = filtered_query(filter)
    total = Ash.count!(base)
    total_pages = total_pages(total)
    page = clamp(page, total_pages)

    runs =
      base
      |> Ash.Query.sort([{sort_by, sort_dir}])
      |> Ash.Query.limit(@page_size)
      |> Ash.Query.offset((page - 1) * @page_size)
      |> Ash.read!()

    socket
    |> assign(:runs, runs)
    |> assign(:total, total)
    |> assign(:page, page)
    |> assign(:total_pages, total_pages)
    |> assign(:catalog_reason, catalog_reason())
  end

  defp filtered_query(""), do: Run

  # Case-sensitive substring match across the string identity columns, via the
  # Ash `contains/2` expression (nil columns simply don't match).
  defp filtered_query(filter) do
    Ash.Query.filter(
      Run,
      contains(run_id, ^filter) or contains(trader_id, ^filter) or contains(strategy, ^filter)
    )
  end

  defp total_pages(0), do: 1
  defp total_pages(total), do: div(total + @page_size - 1, @page_size)

  defp clamp(page, _total_pages) when page < 1, do: 1
  defp clamp(page, total_pages) when page > total_pages, do: total_pages
  defp clamp(page, _total_pages), do: page

  # --- sync ----------------------------------------------------------------

  # Run.sync tolerates a missing catalog (it returns zero counts rather than
  # raising), so this rescue is a backstop for genuinely unexpected failures
  # (e.g. an unset CATALOG_PATH) — surfaced as a flash, never a crash.
  defp sync_catalog do
    {:ok, Run.sync!()}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp sync_message(%{synced: synced, skipped: skipped, removed: removed}) do
    "Synced #{synced} run(s) · skipped #{skipped} · removed #{removed}."
  end

  # --- catalog status (empty-state reason) ---------------------------------

  # The runs come from Postgres, but an empty table is usually because the
  # catalog has not been synced. Surface *why* a sync would find nothing when
  # the catalog dir is absent/unreadable, so the empty state is actionable.
  defp catalog_reason do
    case safe_catalog_path() do
      nil ->
        "CATALOG_PATH is not configured."

      path ->
        unless File.dir?(Path.join(path, "backtest")) do
          "Catalog not found or unreadable: #{path}"
        end
    end
  end

  defp safe_catalog_path do
    AutomatronEx.catalog_path()
  rescue
    _ -> nil
  end

  # --- helpers -------------------------------------------------------------

  # Only sort on a known column; ignore anything else (defends String.to_atom).
  defp safe_field(field) do
    atom = String.to_existing_atom(field)
    if atom in @sortable_fields, do: atom
  rescue
    ArgumentError -> nil
  end

  # Same column → flip direction; a new column → start ascending.
  defp toggle_sort(field, :asc, field), do: {field, :desc}
  defp toggle_sort(field, _dir, field), do: {field, :asc}
  defp toggle_sort(_current, _dir, field), do: {field, :asc}

  defp sort_indicator(field, :asc, field), do: " ▲"
  defp sort_indicator(field, :desc, field), do: " ▼"
  defp sort_indicator(_sort_by, _dir, _field), do: ""

  defp format_cell(nil), do: "—"
  defp format_cell(value) when is_float(value), do: Float.to_string(value)
  defp format_cell(value), do: to_string(value)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Runs
        <:subtitle>Backtest runs and their metrics</:subtitle>
        <:actions>
          <.button phx-click="sync" phx-disable-with="Syncing…">Sync catalog</.button>
        </:actions>
      </.header>

      <form id="filter-form" phx-change="filter" phx-submit="filter" class="mb-4">
        <input
          type="text"
          name="query"
          value={@filter}
          autocomplete="off"
          placeholder="Filter by run, trader, or strategy…"
          class="input w-full max-w-md"
          phx-debounce="200"
        />
      </form>

      <div
        :if={@catalog_reason && @total == 0 && @filter == ""}
        class="alert alert-warning"
        role="alert"
      >
        <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
        <span>{@catalog_reason}</span>
      </div>

      <div :if={@total == 0} class="py-8 text-center text-base-content/70">
        <%= if @filter != "" do %>
          <p>No runs match "{@filter}".</p>
        <% else %>
          <p>No runs synced yet.</p>
          <p class="text-sm">
            Click <span class="font-semibold">Sync catalog</span> to index the catalog.
          </p>
        <% end %>
      </div>

      <div :if={@total > 0} class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th
                :for={{field, label} <- @columns}
                phx-click="sort"
                phx-value-field={field}
                class="cursor-pointer select-none whitespace-nowrap"
                aria-sort={aria_sort(@sort_by, @sort_dir, field)}
              >
                {label}{sort_indicator(@sort_by, @sort_dir, field)}
              </th>
            </tr>
          </thead>
          <tbody id="runs">
            <tr
              :for={run <- @runs}
              id={"run-#{run.run_id}"}
              phx-click={JS.navigate(~p"/runs/#{run.run_id}")}
              class="hover:cursor-pointer"
            >
              <td :for={{field, _label} <- @columns} class="whitespace-nowrap">
                {format_cell(Map.get(run, field))}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@total > 0} id="pagination" class="flex items-center justify-between gap-4 pt-4">
        <span class="text-sm text-base-content/70">
          {@total} run(s) · Page {@page} of {@total_pages}
        </span>
        <div class="join">
          <.button class="btn btn-soft join-item" phx-click="prev_page" disabled={@page <= 1}>
            Prev
          </.button>
          <.button
            class="btn btn-soft join-item"
            phx-click="next_page"
            disabled={@page >= @total_pages}
          >
            Next
          </.button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp aria_sort(field, :asc, field), do: "ascending"
  defp aria_sort(field, :desc, field), do: "descending"
  defp aria_sort(_sort_by, _dir, _field), do: "none"
end
