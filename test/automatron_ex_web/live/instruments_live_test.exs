defmodule AutomatronExWeb.InstrumentsLiveTest do
  @moduledoc """
  Tests `/instruments` against the committed fixture catalog (config/test.exs
  points `:catalog_path` there): the table renders a row per bar_type, and an
  unreadable catalog degrades to an empty state instead of crashing.

  Not `async` — the empty-state test mutates the global `:catalog_path`. No async
  test reads that global, so the mutation is isolated to this (serial) case.
  """

  use AutomatronExWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "GET /instruments" do
    test "renders a table row for each bar_type in the catalog", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/instruments")

      assert html =~ "Instruments"
      # The table body rendered (id lives on <tbody> per CoreComponents.table/1).
      assert has_element?(view, "#instruments")

      # The fixture catalog holds a single bar_type — assert its cells render.
      assert has_element?(view, "td", "XAUUSD.IBCFD")
      assert has_element?(view, "td", "XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL")
      assert has_element?(view, "td", "5-MINUTE-MID-EXTERNAL")
      assert has_element?(view, "td", "IBCFD")
      # bar_count cell.
      assert has_element?(view, "td", "300")
      # date range cell (start–end, from ts_min/ts_max).
      assert has_element?(view, "td", "2026-02-25")
    end

    test "shows an empty state (not a crash) when the catalog is unreadable", %{conn: conn} do
      original = Application.get_env(:automatron_ex, :catalog_path)
      Application.put_env(:automatron_ex, :catalog_path, "/nonexistent/catalog/path")
      on_exit(fn -> Application.put_env(:automatron_ex, :catalog_path, original) end)

      {:ok, _view, html} = live(conn, ~p"/instruments")

      assert html =~ "No instrument data"
      refute html =~ "XAUUSD.IBCFD"
    end
  end
end
