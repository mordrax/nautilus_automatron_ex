"""Python reference for `AutomatronEx.Indicators` — cross-language parity oracle.

Reads a JSON list of close prices (the Elixir `Reader.read_bars/2` output, handed
over so both languages compute over one identical input series) and prints, per
indicator type, the value series gated by `initialized` — exactly what
`server.store.indicators.compute_indicator_instance` produces for the SMA/EMA/HMA
overlay types. The indicators are built from the real `INDICATOR_TYPES` registry
(NautilusTrader `SimpleMovingAverage` / `ExponentialMovingAverage` /
`HullMovingAverage`), so this is a true parity target for the Elixir port.

Sharing the Elixir-read closes isolates the maths under test (the moving-average
algorithms and their `nil`-until-initialized alignment); the close decode itself
is already covered by the `/bars` parity test.

Usage: py_ref_indicators.py <closes_json_path> <period>
Invoked by test/automatron_ex/indicators_parity_test.exs via the server venv.
"""

import json
import sys

# The server package lives next to its venv; make `server.*` importable.
sys.path.insert(0, "/Users/mordrax/code/nautilus_automatron/packages/server")

from server.store.indicators import INDICATOR_TYPES

closes_path, period = sys.argv[1], int(sys.argv[2])

with open(closes_path) as f:
    closes = json.load(f)

out: dict[str, list[float | None]] = {}

for type_name in ("SMA", "EMA", "HMA"):
    indicator = INDICATOR_TYPES[type_name].factory({"period": period})
    series: list[float | None] = []
    for close in closes:
        # update_close (the registry's update fn for these types) is exactly
        # `indicator.update_raw(float(bar.close))`.
        indicator.update_raw(float(close))
        series.append(float(indicator.value) if indicator.initialized else None)
    out[type_name] = series

print(json.dumps(out))
