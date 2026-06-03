defmodule AutomatronEx do
  @moduledoc """
  AutomatronEx keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc """
  Returns the configured NautilusTrader catalog path.

  The catalog is the directory produced by NautilusTrader containing
  `data/` (market data) and `backtest/` (run results). Configured per
  environment under `config :automatron_ex, catalog_path: ...` and
  overridable at runtime with the `CATALOG_PATH` env var.
  """
  @spec catalog_path() :: String.t()
  def catalog_path do
    Application.fetch_env!(:automatron_ex, :catalog_path)
  end
end
