defmodule AutomatronExWeb.RunDetailLiveTest do
  @moduledoc """
  Tests `/runs/:run_id` (the Phase 2 run-detail page) against the committed
  fixture catalog (config/test.exs points `:catalog_path` there).

  The page reads the run through `AutomatronEx.Catalog.Reader` (no Postgres):
  mount renders the header counts + trades table and pushes `chart:init`
  (OHLC + trades) to the `CandlestickChart` JS hook; the trade navigator and
  trade clicks push `chart:focus_trade`; an unknown run degrades to a not-found
  message instead of crashing.
  """

  use AutomatronExWeb.ConnCase

  import Phoenix.LiveViewTest

  # Fixture facts (see test/support/fixtures/catalog/README.md):
  #   e4599dab-… — populated run, 204 closed positions / 408 fills (EMACross)
  @run "e4599dab-fd51-4758-9564-c2061bc2104e"

  test "mounts, renders header counts + trades, pushes chart:init", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/runs/#{@run}")

    # Header carries the run's position/fill counts (read_run_detail).
    assert html =~ "204"
    assert html =~ "408"

    # Once connected, the trades table is populated (first trade's relative id).
    assert render(lv) =~ "#1"

    # The chart data is delivered to the hook over the socket.
    assert_push_event(lv, "chart:init", %{ohlc: ohlc, trades: trades})
    assert length(trades) == 204
    assert Map.has_key?(ohlc, :datetime)
  end

  test "select_trade assigns the index and pushes chart:focus_trade", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")

    render_hook(lv, "select_trade", %{"index" => 5})

    assert_push_event(lv, "chart:focus_trade", %{index: 5})
  end

  test "next_trade / prev_trade step the focused trade and push chart:focus_trade",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")

    render_click(lv, "next_trade")
    assert_push_event(lv, "chart:focus_trade", %{index: 1})

    render_click(lv, "prev_trade")
    assert_push_event(lv, "chart:focus_trade", %{index: 0})

    # Clamped at the lower bound — no underflow below the first trade.
    render_click(lv, "prev_trade")
    assert_push_event(lv, "chart:focus_trade", %{index: 0})
  end

  test "unknown run renders not-found, no crash", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/runs/does-not-exist")

    assert html =~ "not found"
    assert html =~ "Back to runs"
    refute html =~ "204"
  end
end
