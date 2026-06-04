defmodule AutomatronEx.Runs.ViewerState do
  @moduledoc """
  Per-run viewer state: the user's selected indicator instances for a run's
  detail chart, persisted in Postgres and keyed on `run_id`.

  Unlike `AutomatronEx.Runs.Run` (a derived index over the read-only catalog),
  this is **app-owned state** — created and updated from the UI, not synced from
  disk. It mirrors the Python `GET/PUT /api/runs/{run_id}/viewer-state` endpoint:
  only the `indicators` field is modelled here (the `detectors` field is reserved
  for Phase 3e and omitted). Each indicator instance is a
  `%{id, type, params, color}` map; the list is stored in a single jsonb column.
  """

  use Ash.Resource,
    otp_app: :automatron_ex,
    domain: AutomatronEx.Runs,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "viewer_states"
    repo AutomatronEx.Repo
  end

  code_interface do
    define :get_by_run, args: [:run_id]
    define :upsert
  end

  actions do
    defaults [:read, :destroy]

    read :get_by_run do
      description "Fetch the viewer-state for a single run_id."
      get? true
      argument :run_id, :string, allow_nil?: false
      filter expr(run_id == ^arg(:run_id))
    end

    create :upsert do
      description "Insert or replace the viewer-state for a run, keyed on run_id."
      # run_id is the primary key, so it is the default ON CONFLICT target.
      upsert? true
      accept [:run_id, :indicators]
    end
  end

  attributes do
    attribute :run_id, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "NautilusTrader run id this viewer-state belongs to."
    end

    attribute :indicators, {:array, :map} do
      allow_nil? false
      default []
      public? true

      description """
      Selected overlay indicator instances, each a %{id, type, params, color}
      map, stored as jsonb. (Detectors reserved for Phase 3e.)
      """
    end

    timestamps()
  end
end
