"""Python reference for `AutomatronEx.Indicators` — cross-language parity oracle.

Reads (1) a JSON object of the `Reader.read_bars/2` series `{"high", "low",
"close"}` and (2) a JSON list of indicator instances `{"id", "type", "params"}`,
then prints, per instance id, each output field's value series gated by
`initialized` — exactly what `server.store.indicators.compute_indicator_instance`
produces for the SMA/EMA/HMA overlays and the RSI/MACD/ATR/Stochastics panels.

The indicators are built from the real `INDICATOR_TYPES` registry (NautilusTrader
indicator classes) and fed through each type's declared `update` strategy
(`update_close` -> close only; `update_hlc` -> high/low/close), so this is a true
parity target for the Elixir port — including the smoothing choices (RSI/MACD
exponential, ATR simple) and the `[0, 1]` RSI / ratio %D forms that differ from
the textbook formulas.

Sharing the Elixir-read series isolates the maths under test (the algorithms and
their `nil`-until-initialized alignment); the OHLC decode is already covered by
the `/bars` parity test.

Usage: py_ref_indicators.py <series_json_path> <instances_json_path>
Invoked by test/automatron_ex/indicators_parity_test.exs via the server venv.
"""

import json
import sys

# The server package lives next to its venv; make `server.*` importable.
sys.path.insert(0, "/Users/mordrax/code/nautilus_automatron/packages/server")

from server.store.indicators import (
    INDICATOR_TYPES,
    update_close,
    update_hl,
    update_hlc,
)

series_path, instances_path = sys.argv[1], sys.argv[2]

with open(series_path) as f:
    series = json.load(f)

with open(instances_path) as f:
    instances = json.load(f)

closes = series["close"]
highs = series.get("high")
lows = series.get("low")


def feed(indicator, update_fn, i: int) -> None:
    """Feed bar `i` using the type's declared update strategy (its real prod path)."""
    if update_fn is update_close:
        indicator.update_raw(float(closes[i]))
    elif update_fn is update_hlc:
        indicator.update_raw(float(highs[i]), float(lows[i]), float(closes[i]))
    elif update_fn is update_hl:
        indicator.update_raw(float(highs[i]), float(lows[i]))
    else:
        raise SystemExit(f"py_ref_indicators: unsupported update strategy {update_fn!r}")


out: dict[str, dict[str, list[float | None]]] = {}

for inst in instances:
    indicator_type = INDICATOR_TYPES[inst["type"]]
    indicator = indicator_type.factory(inst["params"])
    fields: dict[str, list[float | None]] = {f: [] for f in indicator_type.outputs}

    for i in range(len(closes)):
        feed(indicator, indicator_type.update, i)
        for f in indicator_type.outputs:
            fields[f].append(
                float(getattr(indicator, f)) if indicator.initialized else None
            )

    out[inst["id"]] = fields

print(json.dumps(out))
