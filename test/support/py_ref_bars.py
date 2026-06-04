"""Python reference for the `/bars` projection — cross-language parity oracle.

Prints the `transforms.bars_to_ohlc` JSON (columnar datetime/OHLCV) for a run's
bar_type, so the Elixir `Reader.read_bars/2` can be asserted field-by-field
against it.

Usage: py_ref_bars.py <catalog_path> <run_id> <bar_type>
Invoked by test/automatron_ex/catalog/parity_test.exs via the server venv.
"""

import json
import sys

# The server package lives next to its venv; make `server.*` importable.
sys.path.insert(0, "/Users/mordrax/code/nautilus_automatron/packages/server")

from nautilus_trader.persistence.catalog.parquet import ParquetDataCatalog

from server.store import transforms
from server.store.catalog_reader import get_bars, read_backtest_data

catalog_path, run_id, bar_type = sys.argv[1], sys.argv[2], sys.argv[3]

catalog = ParquetDataCatalog(catalog_path)
data = read_backtest_data(catalog, run_id)
bars = get_bars(data, bar_type)

print(json.dumps(transforms.bars_to_ohlc(bars)))
