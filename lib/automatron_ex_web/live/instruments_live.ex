defmodule AutomatronExWeb.InstrumentsLive do
  @moduledoc """
  `/instruments` — the instrument catalog.

  A plain LiveView (no JS hooks; charts arrive in Phase 2) listing the catalog's
  available market data via the read-through
  `AutomatronEx.Instruments.InstrumentData` resource. An unreadable or empty
  catalog renders an empty state with the reason rather than crashing
  (spec §Error handling).
  """

  use AutomatronExWeb, :live_view

  alias AutomatronEx.Instruments.InstrumentData

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Instruments")
      |> load_instruments()

    {:ok, socket}
  end

  # Read the catalog through the resource. The reader tolerates a missing/unreadable
  # catalog (returns []); we additionally rescue any failure (e.g. an unset
  # CATALOG_PATH) so the page degrades to an empty state with the reason rather
  # than crashing.
  defp load_instruments(socket) do
    catalog_path = AutomatronEx.catalog_path()

    case InstrumentData.list() do
      {:ok, instruments} ->
        socket
        |> assign(:instruments, instruments)
        |> assign(:catalog_path, catalog_path)
        |> assign(:load_error, nil)

      {:error, error} ->
        socket
        |> assign(:instruments, [])
        |> assign(:catalog_path, catalog_path)
        |> assign(:load_error, Exception.message(error))
    end
  rescue
    error ->
      socket
      |> assign(:instruments, [])
      |> assign(:catalog_path, nil)
      |> assign(:load_error, Exception.message(error))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Instruments
        <:subtitle>Market data available in the catalog</:subtitle>
      </.header>

      <div :if={@load_error} class="alert alert-error" role="alert">
        <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
        <span>Could not read the catalog: {@load_error}</span>
      </div>

      <div
        :if={is_nil(@load_error) and @instruments == []}
        class="py-8 text-center text-base-content/70"
      >
        <p>No instrument data found in the catalog.</p>
        <p :if={@catalog_path} class="text-sm">Looked in <code>{@catalog_path}</code></p>
      </div>

      <.table :if={@instruments != []} id="instruments" rows={@instruments}>
        <:col :let={instrument} label="Instrument">{instrument.instrument}</:col>
        <:col :let={instrument} label="Bar type">{instrument.bar_type}</:col>
        <:col :let={instrument} label="Timeframe">{instrument.timeframe}</:col>
        <:col :let={instrument} label="Venue">{instrument.venue}</:col>
        <:col :let={instrument} label="Bars">{instrument.bar_count}</:col>
        <:col :let={instrument} label="Date range">{date_range(instrument)}</:col>
        <:col :let={instrument} label="Files">{instrument.file_count}</:col>
      </.table>
    </Layouts.app>
    """
  end

  # Render the bar date span as "start – end" ISO dates, tolerating missing dates.
  defp date_range(%{start_date: nil, end_date: nil}), do: "—"

  defp date_range(%{start_date: start_date, end_date: end_date}) do
    "#{format_date(start_date)} – #{format_date(end_date)}"
  end

  defp format_date(nil), do: "—"
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
end
