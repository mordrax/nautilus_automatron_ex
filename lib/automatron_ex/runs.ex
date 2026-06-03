defmodule AutomatronEx.Runs do
  @moduledoc """
  The Runs Ash domain: a Postgres-backed read model of backtest runs.

  The on-disk NautilusTrader catalog is the source of truth; the `Run` rows here
  are a derived index, (re)populated by the `Run.sync` action
  (`AutomatronEx.Runs.Sync`). Reads (the Phase 1 dashboard) query Postgres so
  sort/filter/paginate run as ordinary Ash queries over indexed columns.
  """

  use Ash.Domain, otp_app: :automatron_ex

  resources do
    resource AutomatronEx.Runs.Run
  end
end
