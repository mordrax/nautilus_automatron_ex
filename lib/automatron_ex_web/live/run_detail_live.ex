defmodule AutomatronExWeb.RunDetailLive do
  @moduledoc """
  `/runs/:run_id` — placeholder reserved for the Phase 2 run-detail page.

  The runs dashboard links each row here; this phase only reserves the route. The
  real view (candlestick chart, fills, positions) arrives in Phase 2, so for now
  we echo the requested run id and point back to the dashboard.
  """

  use AutomatronExWeb, :live_view

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Run #{run_id}")
      |> assign(:run_id, run_id)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Run detail
        <:subtitle>{@run_id}</:subtitle>
      </.header>

      <div class="py-8 text-center text-base-content/70">
        <p>
          The run-detail page (chart, fills, positions) arrives in <span class="font-semibold">Phase 2</span>.
        </p>
        <.button navigate={~p"/"} class="btn btn-soft mt-4">← Back to runs</.button>
      </div>
    </Layouts.app>
    """
  end
end
