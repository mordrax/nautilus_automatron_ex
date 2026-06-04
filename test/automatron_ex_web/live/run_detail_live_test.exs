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

  test "next_trade_fast / prev_trade_fast jump 50 trades and clamp at the bounds",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")

    # CapsLock+Shift+Arrow (mirroring the React use-hotkeys fast step of 50) jumps
    # 50 trades at a time. The fixture run has 204 trades, so +50 from 0 lands on 50.
    render_hook(lv, "next_trade_fast", %{})
    assert_push_event(lv, "chart:focus_trade", %{index: 50})

    render_hook(lv, "prev_trade_fast", %{})
    assert_push_event(lv, "chart:focus_trade", %{index: 0})

    # Clamped at the lower bound — a fast jump never underflows below the first trade.
    render_hook(lv, "prev_trade_fast", %{})
    assert_push_event(lv, "chart:focus_trade", %{index: 0})
  end

  test "on connected mount, focuses the initial trade so the chart opens on trade #1",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")

    # Beyond chart:init, the connected mount centers the chart on the selected
    # trade (#1 → index 0), matching the React reference (nae-g9c). Without it the
    # chart opens on the most-recent bars while the navigator reads "Trade 1".
    assert_push_event(lv, "chart:focus_trade", %{index: 0})
  end

  test "navigator wires the TradeHotkeys hook and Prev/Next carry shortcut tooltips",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")

    nav = lv |> element("#trade-navigator") |> render()

    # The CapsLock+arrow keyboard navigation is driven by the TradeHotkeys JS hook.
    assert nav =~ ~s(phx-hook="TradeHotkeys")
    # Prev/Next expose their shortcut as a hover tooltip (mentions the Shift fast jump).
    assert nav =~ "CapsLock+←"
    assert nav =~ "CapsLock+Shift+←"
    assert nav =~ "CapsLock+→"
    assert nav =~ "CapsLock+Shift+→"
  end

  test "chart container stays phx-update=ignore across trade navigation", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")

    # #run-chart is owned by the CandlestickChart hook (echarts.init appends the
    # canvas), so it must be phx-update="ignore" — otherwise a navigator re-render
    # reconciles the hook-created canvas away and the chart goes blank (nae-ji0).
    assert lv |> element("#run-chart") |> render() =~ ~s(phx-update="ignore")

    render_click(lv, "next_trade")
    assert lv |> element("#run-chart") |> render() =~ ~s(phx-update="ignore")
  end

  test "unknown run renders not-found, no crash", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/runs/does-not-exist")

    assert html =~ "not found"
    assert html =~ "Back to runs"
    refute html =~ "204"
  end
end
