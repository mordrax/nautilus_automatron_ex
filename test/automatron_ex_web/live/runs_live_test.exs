defmodule AutomatronExWeb.RunsLiveTest do
  @moduledoc """
  Tests `/` (the runs dashboard) against the committed fixture catalog
  (config/test.exs points `:catalog_path` there): rows render with identity +
  metric values, sort/filter/paginate run as Ash queries over Postgres, the Sync
  button populates the index from the catalog, and an empty/unreadable catalog
  degrades to an empty state with the reason instead of crashing.

  Not `async` — one test mutates the global `:catalog_path`, and the LiveView
  reads Postgres, so the suite relies on the shared (non-async) SQL sandbox to
  see each test's writes.
  """

  use AutomatronExWeb.ConnCase

  import Phoenix.LiveViewTest

  alias AutomatronEx.Runs.Run

  # Fixture facts (see test/support/fixtures/catalog/README.md):
  #   017f6297-… — empty run, 0 closed positions / 0 fills (BBBStrategy)
  #   e4599dab-… — populated run, 204 closed positions / 408 fills (EMACross)
  @empty_run "017f6297-c633-4419-aa23-bc3fb8171cad"
  @populated_run "e4599dab-fd51-4758-9564-c2061bc2104e"

  # Byte offset of `needle` in `haystack` (the first row referencing a run id wins),
  # used to assert relative row ordering after a sort.
  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {start, _len} -> start
      :nomatch -> nil
    end
  end

  describe "GET / with synced runs" do
    test "renders a row per run with identity and metric values", %{conn: conn} do
      Run.sync!()

      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Runs"
      # The table body rendered (id lives on <tbody>).
      assert has_element?(view, "#runs")

      # Both fixture runs are listed.
      assert html =~ @populated_run
      assert html =~ @empty_run

      # Populated-run identity cells.
      assert has_element?(view, "td", "EMACross")
      assert has_element?(view, "td", "204")
      assert has_element?(view, "td", "408")

      # A metric value renders as stored (total_pnl is a non-nil float here).
      run = Ash.get!(Run, @populated_run)
      assert is_float(run.total_pnl)
      assert html =~ Float.to_string(run.total_pnl)
    end

    test "clicking a metric column header sorts by it, and toggles direction", %{conn: conn} do
      Run.sync!()

      {:ok, view, _html} = live(conn, ~p"/")

      # First click → ascending by total_pnl. Postgres orders NULLS LAST on ASC,
      # so the populated run (a number) sorts before the empty run (nil metric).
      asc = view |> element("th[phx-value-field='total_pnl']") |> render_click()
      assert index_of(asc, @populated_run) < index_of(asc, @empty_run)

      # Second click on the same column → descending (NULLS FIRST): order flips.
      desc = view |> element("th[phx-value-field='total_pnl']") |> render_click()
      assert index_of(desc, @empty_run) < index_of(desc, @populated_run)
    end

    test "the free-text filter narrows the table via an Ash query", %{conn: conn} do
      Run.sync!()

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "EMACross"
      assert html =~ "BBBStrategy"

      filtered = view |> form("#filter-form", %{query: "EMACross"}) |> render_change()

      assert filtered =~ "EMACross"
      refute filtered =~ "BBBStrategy"
    end

    test "row click navigates to the reserved run-detail route", %{conn: conn} do
      Run.sync!()

      {:ok, view, _html} = live(conn, ~p"/")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#run-#{@populated_run}") |> render_click()

      assert to == "/runs/#{@populated_run}"
    end
  end

  describe "Sync catalog button" do
    test "populates an empty database from the catalog and reloads", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      # Nothing synced yet → empty state, no run rows.
      assert html =~ "No runs"
      refute html =~ "EMACross"

      synced = view |> element("button", "Sync catalog") |> render_click()

      assert synced =~ "EMACross"
      assert has_element?(view, "td", "204")
    end
  end

  describe "empty / unreadable catalog" do
    test "renders an empty state when nothing is synced", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "No runs"
      refute html =~ "EMACross"
    end

    test "explains the reason when the catalog is unreadable (no crash)", %{conn: conn} do
      original = Application.get_env(:automatron_ex, :catalog_path)
      Application.put_env(:automatron_ex, :catalog_path, "/nonexistent/catalog/path")
      on_exit(fn -> Application.put_env(:automatron_ex, :catalog_path, original) end)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "No runs"
      assert html =~ "/nonexistent/catalog/path"
    end
  end

  describe "pagination" do
    test "splits results into pages navigable with Next/Prev", %{conn: conn} do
      # One full page (25) plus one row → two pages.
      for i <- 1..26 do
        Run.upsert!(%{run_id: "run-" <> String.pad_leading(Integer.to_string(i), 2, "0")})
      end

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Page 1 of 2"

      next = view |> element("button", "Next") |> render_click()
      assert next =~ "Page 2 of 2"
    end
  end

  describe "GET /runs/:run_id (Phase 2 placeholder)" do
    test "renders a placeholder without crashing", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/runs/#{@populated_run}")

      assert html =~ @populated_run
      assert html =~ "Phase 2"
    end
  end
end
