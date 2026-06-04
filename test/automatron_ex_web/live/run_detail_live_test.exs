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

  alias AutomatronEx.Runs.ViewerState

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

  describe "indicator sidebar (Phase 3a)" do
    test "replaces the inert Phase 3 placeholder with a functional add control",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/runs/#{@run}")

      # The add control offers the three overlay types from the registry.
      assert html =~ ~s(phx-submit="add_indicator")
      assert html =~ "SMA"
      assert html =~ "EMA"
      assert html =~ "HMA"

      # The inert Phase-3 placeholder copy is gone.
      refute html =~ "arrive in"
    end

    test "adding an overlay indicator computes its series and pushes chart:set_indicators",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")

      lv |> form("#add-indicator", %{"type" => "SMA"}) |> render_submit()

      assert_push_event(lv, "chart:set_indicators", %{series: [series]})
      assert series.label == "SMA(20)"
      assert series.display == "overlay"
      assert is_list(series.outputs["value"])
      assert series.color =~ ~r/^#[0-9a-fA-F]{6}$/

      # Persisted to viewer-state for the run.
      assert [%{"type" => "SMA", "params" => %{"period" => 20}}] =
               ViewerState.get_by_run!(@run).indicators
    end

    test "editing the period recomputes the series with the new label and persists it",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")
      lv |> form("#add-indicator", %{"type" => "SMA"}) |> render_submit()
      assert_push_event(lv, "chart:set_indicators", %{series: [s]})

      lv |> form("#indicator-#{s.id}", %{"period" => "50"}) |> render_change()

      assert_push_event(lv, "chart:set_indicators", %{series: [s2]})
      assert s2.label == "SMA(50)"
      assert s2.id == s.id

      assert [%{"params" => %{"period" => 50}}] = ViewerState.get_by_run!(@run).indicators
    end

    test "setting a color updates the pushed series and persists it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")
      lv |> form("#add-indicator", %{"type" => "HMA"}) |> render_submit()
      assert_push_event(lv, "chart:set_indicators", %{series: [s]})

      lv |> form("#indicator-#{s.id}", %{"color" => "#123456"}) |> render_change()

      assert_push_event(lv, "chart:set_indicators", %{series: [s2]})
      assert s2.color == "#123456"
      assert [%{"color" => "#123456"}] = ViewerState.get_by_run!(@run).indicators
    end

    test "removing an indicator drops it from the series and clears viewer-state",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")
      lv |> form("#add-indicator", %{"type" => "EMA"}) |> render_submit()
      assert_push_event(lv, "chart:set_indicators", %{series: [s]})

      lv |> element("#remove-#{s.id}") |> render_click()

      assert_push_event(lv, "chart:set_indicators", %{series: []})
      assert ViewerState.get_by_run!(@run).indicators == []
    end

    test "selections persist and are re-pushed on remount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")
      lv |> form("#add-indicator", %{"type" => "EMA"}) |> render_submit()
      assert_push_event(lv, "chart:set_indicators", %{series: [s]})

      # A fresh LiveView for the same run reloads the persisted viewer-state:
      # the instance renders again and its series is re-pushed after chart:init.
      {:ok, lv2, _html2} = live(conn, ~p"/runs/#{@run}")

      assert has_element?(lv2, "#indicator-#{s.id}")
      assert_push_event(lv2, "chart:set_indicators", %{series: [s2]})
      assert s2.id == s.id
      assert s2.label == "EMA(20)"
    end
  end

  describe "indicator sidebar (Phase 3b — panel oscillators)" do
    # The chart hook routes the pushed series by `display`: "overlay" stays on the
    # price axis (3a), "panel" gets its own grid below the candlesticks. The server
    # contract those panels rely on is that each panel indicator's pushed series
    # carries display: "panel" and its output keys — asserted here.

    test "adding a single-output panel indicator (RSI) pushes a display:\"panel\" series",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")

      lv |> form("#add-indicator", %{"type" => "RSI"}) |> render_submit()

      assert_push_event(lv, "chart:set_indicators", %{series: [series]})
      assert series.display == "panel"
      assert series.label == "RSI(14)"
      assert is_list(series.outputs["value"])
      assert series.color =~ ~r/^#[0-9a-fA-F]{6}$/
    end

    test "adding a multi-param panel indicator (MACD) seeds both params and computes it",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")

      lv |> form("#add-indicator", %{"type" => "MACD"}) |> render_submit()

      assert_push_event(lv, "chart:set_indicators", %{series: [series]})
      assert series.display == "panel"
      assert series.label == "MACD(12,26)"
      assert is_list(series.outputs["value"])

      # Both registry params round-trip to viewer-state (not just a single `period`).
      assert [%{"type" => "MACD", "params" => %{"fast_period" => 12, "slow_period" => 26}}] =
               ViewerState.get_by_run!(@run).indicators
    end

    test "adding a multi-output panel indicator (Stochastics) pushes both %K and %D series",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")

      lv |> form("#add-indicator", %{"type" => "Stochastics"}) |> render_submit()

      assert_push_event(lv, "chart:set_indicators", %{series: [series]})
      assert series.display == "panel"
      assert series.label == "Stoch(14,3)"
      # The hook draws one line per output — Stochastics carries both %K and %D.
      assert is_list(series.outputs["value_k"])
      assert is_list(series.outputs["value_d"])
    end

    test "panel and overlay indicators coexist, each tagged with its own display",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")

      lv |> form("#add-indicator", %{"type" => "SMA"}) |> render_submit()
      assert_push_event(lv, "chart:set_indicators", %{series: [_overlay_only]})

      lv |> form("#add-indicator", %{"type" => "RSI"}) |> render_submit()
      assert_push_event(lv, "chart:set_indicators", %{series: series})

      # The same push carries the 3a overlay and the 3b panel, each routed by display.
      display_by_label = Map.new(series, &{&1.label, &1.display})
      assert display_by_label["SMA(20)"] == "overlay"
      assert display_by_label["RSI(14)"] == "panel"
    end

    test "editing a multi-param panel (MACD fast_period) recomputes the label and persists",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")
      lv |> form("#add-indicator", %{"type" => "MACD"}) |> render_submit()
      assert_push_event(lv, "chart:set_indicators", %{series: [s]})

      lv |> form("#indicator-#{s.id}", %{"fast_period" => "5"}) |> render_change()

      assert_push_event(lv, "chart:set_indicators", %{series: [s2]})
      assert s2.label == "MACD(5,26)"
      assert s2.id == s.id

      assert [%{"params" => %{"fast_period" => 5, "slow_period" => 26}}] =
               ViewerState.get_by_run!(@run).indicators
    end

    test "a panel indicator persists and is re-pushed with its display on remount",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/runs/#{@run}")
      lv |> form("#add-indicator", %{"type" => "Stochastics"}) |> render_submit()
      assert_push_event(lv, "chart:set_indicators", %{series: [s]})

      {:ok, lv2, _html2} = live(conn, ~p"/runs/#{@run}")

      assert has_element?(lv2, "#indicator-#{s.id}")
      assert_push_event(lv2, "chart:set_indicators", %{series: [s2]})
      assert s2.id == s.id
      assert s2.display == "panel"
      assert s2.label == "Stoch(14,3)"
    end
  end
end
