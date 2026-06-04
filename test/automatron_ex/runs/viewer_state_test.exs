defmodule AutomatronEx.Runs.ViewerStateTest do
  @moduledoc """
  Round-trip tests for the per-run viewer-state resource (bead nae-38s.2).

  `upsert` persists the selected indicator instances keyed on `run_id`,
  `get_by_run` reads them back unchanged, and a second `upsert` updates the same
  row in place (no duplicate). Mirrors the Python
  `GET/PUT /api/runs/{run_id}/viewer-state` contract — `indicators` only;
  detectors are reserved for Phase 3e.
  """

  use AutomatronEx.DataCase, async: true

  alias AutomatronEx.Runs.ViewerState

  @run_id "viewer-state-run"

  # Indicator instances as they cross the jsonb boundary: string keys, the
  # %{id, type, params, color} shape from the spec.
  @indicators [
    %{"id" => "i1", "type" => "sma", "params" => %{"period" => 20}, "color" => "#ff0000"},
    %{"id" => "i2", "type" => "ema", "params" => %{"period" => 50}, "color" => "#00ff00"}
  ]

  describe "upsert / get_by_run round-trip" do
    test "upsert persists indicators and get_by_run reads back the same list" do
      assert {:ok, _} = ViewerState.upsert(%{run_id: @run_id, indicators: @indicators})

      state = ViewerState.get_by_run!(@run_id)
      assert state.run_id == @run_id
      assert state.indicators == @indicators
    end

    test "a run with no indicators given defaults to an empty list" do
      assert {:ok, state} = ViewerState.upsert(%{run_id: @run_id})
      assert state.indicators == []
      assert ViewerState.get_by_run!(@run_id).indicators == []
    end
  end

  describe "upsert is keyed on run_id" do
    test "a second upsert updates in place — same indicators replaced, no duplicate row" do
      {:ok, _} = ViewerState.upsert(%{run_id: @run_id, indicators: @indicators})

      replacement = [
        %{"id" => "i3", "type" => "hma", "params" => %{"period" => 9}, "color" => "#0000ff"}
      ]

      {:ok, _} = ViewerState.upsert(%{run_id: @run_id, indicators: replacement})

      assert ViewerState.get_by_run!(@run_id).indicators == replacement
      assert length(Ash.read!(ViewerState)) == 1
    end
  end
end
