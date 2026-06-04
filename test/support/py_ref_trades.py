"""Python reference for the `/trades` projection — cross-language parity oracle.

Prints the `transforms.positions_to_trades` JSON (one row per closed position,
sorted by ts_opened, 1-based relative_id) for a run, so the Elixir
`Reader.read_trades/2` can be asserted field-by-field against it.

Usage: py_ref_trades.py <catalog_path> <run_id>
Invoked by test/automatron_ex/catalog/parity_test.exs via the server venv.
"""

import json
import sys

# The server package lives next to its venv; make `server.*` importable.
sys.path.insert(0, "/Users/mordrax/code/nautilus_automatron/packages/server")

from nautilus_trader.persistence.catalog.parquet import ParquetDataCatalog

from server.store import transforms
from server.store.catalog_reader import get_positions_closed, read_backtest_data

catalog_path, run_id = sys.argv[1], sys.argv[2]

catalog = ParquetDataCatalog(catalog_path)
data = read_backtest_data(catalog, run_id)
positions = get_positions_closed(data)

print(json.dumps(transforms.positions_to_trades(positions)))
