defmodule AutomatronEx.Instruments do
  @moduledoc """
  The Instruments Ash domain: a read-through view of the available market data
  in the on-disk NautilusTrader catalog.

  Unlike `AutomatronEx.Runs` (a Postgres-backed index), nothing here is persisted.
  `AutomatronEx.Instruments.InstrumentData` is a read-through resource whose single
  manual read action scans the catalog's `data/bar/` directory on every read
  (`AutomatronEx.Catalog.Reader.list_instrument_data/1`). The metadata is cheap to
  recompute and always fresh from disk, so a database index would buy nothing.
  """

  use Ash.Domain, otp_app: :automatron_ex

  resources do
    resource AutomatronEx.Instruments.InstrumentData
  end
end
