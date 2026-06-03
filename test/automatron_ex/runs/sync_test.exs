defmodule AutomatronEx.Runs.SyncTest do
  @moduledoc """
  Behaviour tests for the `Run.sync` action against the committed fixture catalog
  (test/support/fixtures/catalog). Covers the four contracts from bead nae-46k.5:
  populate with correct metric values, idempotent re-sync, stale-row removal, and
  skip-broken-run tolerance.
  """

  use AutomatronEx.DataCase

  import ExUnit.CaptureLog

  alias AutomatronEx.Catalog.{Metrics, Reader}
  alias AutomatronEx.Runs.{Run, RunMetric}

  # Fixture facts (see test/support/fixtures/catalog/README.md):
  #   017f6297-… — empty run, 0 closed positions / 0 fills (BBBStrategy)
  #   e4599dab-… — populated run, 204 closed positions / 408 fills (EMACross)
  @empty_run "017f6297-c633-4419-aa23-bc3fb8171cad"
  @populated_run "e4599dab-fd51-4758-9564-c2061bc2104e"
  @fixture_catalog Path.expand("../../support/fixtures/catalog", __DIR__)

  # Copy the read-only fixture catalog into a writable tmp dir so a test can
  # mutate it (delete a run dir / break a run) without touching the fixture.
  defp temp_catalog(tmp_dir) do
    catalog = Path.join(tmp_dir, "catalog")
    File.cp_r!(@fixture_catalog, catalog)
    catalog
  end

  defp run_ids do
    Run.read!() |> Enum.map(& &1.run_id) |> Enum.sort()
  end

  describe "sync populates the runs index" do
    test "creates one row per run with the catalog identity fields" do
      assert %{synced: 2, skipped: 0, removed: 0} = Run.sync!()
      assert run_ids() == [@empty_run, @populated_run]
    end

    test "the populated run carries the correct identity and metric values" do
      Run.sync!()
      run = Ash.get!(Run, @populated_run)

      assert run.trader_id == "BACKTESTER-001"
      assert run.strategy =~ "EMACross"
      assert run.total_positions == 204
      assert run.total_fills == 408

      # Metric parity: the synced columns equal a direct Reader -> Metrics compute.
      {:ok, positions} = Reader.read_positions_closed(@fixture_catalog, @populated_run)
      expected = Metrics.compute_run_metrics(positions)
      actual = Map.take(Map.from_struct(run), RunMetric.keys())

      assert actual == expected
      # Sanity anchors on concrete numbers.
      assert run.wins + run.losses == 204
      assert is_float(run.total_pnl)
    end

    test "the empty run has zero counts and all-nil metrics" do
      Run.sync!()
      run = Ash.get!(Run, @empty_run)

      assert run.strategy =~ "BBBStrategy"
      assert run.total_positions == 0
      assert run.total_fills == 0
      assert Map.take(Map.from_struct(run), RunMetric.keys()) == Metrics.empty_metrics()
    end
  end

  describe "re-sync is idempotent" do
    test "a second sync produces no duplicates and stable values" do
      Run.sync!()
      first = Ash.get!(Run, @populated_run)

      assert %{synced: 2, skipped: 0, removed: 0} = Run.sync!()
      assert run_ids() == [@empty_run, @populated_run]

      second = Ash.get!(Run, @populated_run)
      metric_keys = RunMetric.keys()

      assert Map.take(Map.from_struct(second), metric_keys) ==
               Map.take(Map.from_struct(first), metric_keys)

      assert second.total_positions == first.total_positions
      assert second.total_fills == first.total_fills
    end
  end

  describe "stale-row removal" do
    @tag :tmp_dir
    test "removing a run dir from the catalog removes its row on the next sync", %{tmp_dir: tmp} do
      catalog = temp_catalog(tmp)

      assert %{synced: 2, removed: 0} = Run.sync!(catalog)
      assert run_ids() == [@empty_run, @populated_run]

      File.rm_rf!(Path.join([catalog, "backtest", @populated_run]))

      assert %{synced: 1, skipped: 0, removed: 1} = Run.sync!(catalog)
      assert run_ids() == [@empty_run]
    end
  end

  describe "broken-run tolerance" do
    @tag :tmp_dir
    test "a run dir missing config.json is skipped with a warning; others still sync",
         %{tmp_dir: tmp} do
      catalog = temp_catalog(tmp)
      File.rm!(Path.join([catalog, "backtest", @populated_run, "config.json"]))

      {result, log} = with_log(fn -> Run.sync!(catalog) end)

      assert %{synced: 1, skipped: 1, removed: 0} = result
      assert log =~ "skipping run #{@populated_run}"
      # The healthy run still synced; the broken one has no row.
      assert run_ids() == [@empty_run]
    end
  end
end
