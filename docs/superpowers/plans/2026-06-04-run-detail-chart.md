# Run-detail page + candlestick chart — Implementation Plan (Phase 2)

> **For agentic workers:** This plan is executed as Gas City beads — one polecat per task, each doing TDD on its own branch with a PR + review gate. Steps use checkbox (`- [ ]`) syntax for tracking. If executed in-session instead, use superpowers:subagent-driven-development.

**Goal:** Add `/runs/:run_id` — a candlestick chart of a run's bars with trade entry/exit overlays, a trade navigator, and a trades table — matching the existing Python/React page.

**Architecture:** Read-through from the catalog (no new Postgres tables). `RunDetailLive` loads bars + trades via `Reader` and delivers them to a `CandlestickChart` JS hook over the websocket with `push_event`; the hook owns the eCharts instance and builds the same option object the React app builds.

**Tech Stack:** Elixir, Phoenix LiveView, Explorer (Polars), eCharts (JS, via esbuild), ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-04-run-detail-chart-design.md`
**Parity source (Python):** `/Users/mordrax/code/nautilus_automatron` — `packages/server/server/routes/{bars,fills,runs}.py`, `store/transforms.py`; `packages/client/src/components/chart/CandlestickChart.tsx`, `lib/{chart-config,trade-utils}.ts`.

---

## File structure

| File | Responsibility |
|---|---|
| `lib/automatron_ex/catalog/reader.ex` (modify) | + `read_bars/2`, `read_trades/2`, `read_run_detail/2` — pure catalog reads |
| `test/automatron_ex/catalog/reader_test.exs` (modify) | unit tests for the three new reader functions vs the fixture catalog |
| `test/automatron_ex/catalog/parity_test.exs` (create) | cross-language parity: `read_bars`/`read_trades` vs Python JSON |
| `assets/package.json` (modify) | + `echarts` dependency |
| `assets/js/hooks/candlestick_chart.js` (create) | eCharts hook: build option from `{ohlc, trades}`, trade markLines, click + zoom |
| `assets/js/app.js` (modify) | register the `CandlestickChart` hook |
| `lib/automatron_ex_web/live/run_detail_live.ex` (modify) | replace placeholder: load data, `push_event`, render header/chart/navigator/table/inert-sidebar, handle events |
| `test/automatron_ex_web/live/run_detail_live_test.exs` (create) | LiveView mount + event tests, `assert_push_event` |

## Task → bead mapping

- **Task 1** → bead A (Reader extensions + parity). No dependency (Reader exists on main).
- **Task 2** → bead B (eCharts asset + hook). No dependency; parallel with A.
- **Task 3** → bead C (RunDetailLive). Depends on A + B.
- **Task 4** → bead D (E2E parity verification + demo). Depends on C.

---

## Task 1: Reader extensions — `read_bars`, `read_trades`, `read_run_detail`

**Files:**
- Modify: `lib/automatron_ex/catalog/reader.ex`
- Test: `test/automatron_ex/catalog/reader_test.exs`
- Create: `test/automatron_ex/catalog/parity_test.exs`

- [ ] **Step 1: Recon the bar parquet + position columns before coding**

In `iex -S mix`, read one real file of each kind and inspect columns/dtypes; confirm the spec's field mapping. Cross-check `docs/catalog-schema.md`.

```elixir
alias Explorer.DataFrame, as: DF
# bars: confirm ts_event/open/high/low/close/volume + dtypes
DF.from_parquet!(Path.wildcard("/Users/mordrax/code/nautilus_automatron/backtest_catalog/data/bar/XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL/*.parquet") |> hd()) |> DF.names()
# positions: confirm avg_px_open/avg_px_close/entry/side/peak_qty/currency
DF.from_ipc_stream!("/Users/mordrax/code/nautilus_automatron/backtest_catalog/backtest/e4599dab-fd51-4758-9564-c2061bc2104e/position_closed_0.feather") |> DF.names()
```

Expected: bars have `open, high, low, close, volume, ts_event`; positions have `avg_px_open, avg_px_close, entry, side, peak_qty, currency, realized_pnl, ts_opened, ts_closed, instrument_id, position_id`. If a name differs, use the real name and note it.

- [ ] **Step 2: Write the failing test for `read_bars`**

```elixir
@cat "test/support/fixtures/catalog"

test "read_bars returns sorted columnar OHLCV for a bar type" do
  {:ok, ohlc} = Reader.read_bars(@cat, "XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL")
  assert Map.keys(ohlc) |> Enum.sort() == [:close, :datetime, :high, :low, :open, :volume]
  n = length(ohlc.datetime)
  assert n > 0
  assert length(ohlc.open) == n and length(ohlc.volume) == n
  # datetime is ISO-8601 strings, ascending
  assert ohlc.datetime == Enum.sort(ohlc.datetime)
  assert hd(ohlc.datetime) =~ ~r/^\d{4}-\d{2}-\d{2}T/
end

test "read_bars errors on unknown bar type" do
  assert {:error, _} = Reader.read_bars(@cat, "NOPE-1-MINUTE-MID-EXTERNAL")
end
```

- [ ] **Step 3: Run it, confirm failure**

Run: `mix test test/automatron_ex/catalog/reader_test.exs -k read_bars`
Expected: FAIL (`read_bars/2` undefined).

- [ ] **Step 4: Implement `read_bars/2`**

Read every `*.parquet` under `data/bar/<bar_type>/`, concatenate, sort by `ts_event`, project to columnar lists, convert `ts_event` (int64 ns) → ISO-8601 UTC strings.

```elixir
@doc "Columnar OHLCV for a bar type, read from data/bar/<bar_type>/*.parquet."
@spec read_bars(String.t(), String.t()) :: {:ok, map} | {:error, term}
def read_bars(catalog_path, bar_type) do
  dir = Path.join([catalog_path, "data", "bar", bar_type])
  case Path.wildcard(Path.join(dir, "*.parquet")) do
    [] -> {:error, {:no_bars, bar_type}}
    files ->
      df =
        files |> Enum.map(&DataFrame.from_parquet!/1) |> DataFrame.concat_rows()
        |> DataFrame.sort_by(ts_event)
      {:ok,
       %{
         datetime: df["ts_event"] |> Series.to_list() |> Enum.map(&ns_to_iso/1),
         open: to_floats(df["open"]),
         high: to_floats(df["high"]),
         low: to_floats(df["low"]),
         close: to_floats(df["close"]),
         volume: to_floats(df["volume"])
       }}
  end
rescue
  e -> {:error, Exception.message(e)}
end

defp to_floats(series), do: series |> Series.cast(:f64) |> Series.to_list()
# ns_to_iso/1: int64 nanoseconds -> "YYYY-MM-DDTHH:MM:SSZ" (UTC). Use DateTime.from_unix(div(ns, 1_000_000_000)) and DateTime.to_iso8601, or match the Python _ns_to_iso format exactly — confirm against a Python /bars datetime in Task 4.
```

- [ ] **Step 5: Run `read_bars` tests, confirm pass**

Run: `mix test test/automatron_ex/catalog/reader_test.exs -k read_bars`
Expected: PASS.

- [ ] **Step 6: Write failing tests for `read_trades`**

```elixir
test "read_trades projects closed positions to Trade maps, 1-based relative_id by ts_opened" do
  {:ok, trades} = Reader.read_trades(@cat, "e4599dab-fd51-4758-9564-c2061bc2104e")
  assert length(trades) == 204
  ids = Enum.map(trades, & &1.relative_id)
  assert ids == Enum.to_list(1..204)
  t = hd(trades)
  assert Map.keys(t) |> Enum.sort() ==
           [:currency, :direction, :entry_datetime, :entry_price, :exit_datetime,
            :exit_price, :instrument_id, :pnl, :position_id, :quantity, :relative_id]
  assert t.direction in ["Long", "Short"]
  assert is_float(t.pnl)
  assert t.entry_datetime <= t.exit_datetime
end

test "read_trades returns [] for a zero-position run" do
  assert {:ok, []} = Reader.read_trades(@cat, "017f6297-c633-4419-aa23-bc3fb8171cad")
end
```

- [ ] **Step 7: Run, confirm failure**

Run: `mix test test/automatron_ex/catalog/reader_test.exs -k read_trades`
Expected: FAIL (`read_trades/2` undefined).

- [ ] **Step 8: Implement `read_trades/2`**

Read `position_closed_0.feather` (IPC stream), sort by `ts_opened`, map each row. Direction from `entry`/`side` (BUY→"Long", SELL→"Short" — confirm in Task 4). `entry_price = avg_px_open`, `exit_price = avg_px_close`, `quantity = peak_qty`, `pnl = realized_pnl` rounded 2dp.

```elixir
@spec read_trades(String.t(), String.t()) :: {:ok, [map]} | {:error, term}
def read_trades(catalog_path, run_id) do
  path = Path.join([catalog_path, "backtest", run_id, "position_closed_0.feather"])
  if File.exists?(path) do
    df = DataFrame.from_ipc_stream!(path) |> DataFrame.sort_by(ts_opened)
    rows = DataFrame.to_rows(df)
    trades =
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} ->
        %{
          relative_id: i,
          position_id: r["position_id"],
          instrument_id: r["instrument_id"],
          direction: direction(r["entry"] || r["side"]),
          entry_datetime: ns_to_iso(r["ts_opened"]),
          entry_price: to_f(r["avg_px_open"]),
          exit_datetime: ns_to_iso(r["ts_closed"]),
          exit_price: to_f(r["avg_px_close"]),
          quantity: to_f(r["peak_qty"]),
          pnl: Float.round(to_f(r["realized_pnl"]), 2),
          currency: r["currency"]
        }
      end)
    {:ok, trades}
  else
    {:ok, []}
  end
rescue
  e -> {:error, Exception.message(e)}
end

defp direction("BUY"), do: "Long"
defp direction("SELL"), do: "Short"
defp direction(other), do: to_string(other)
defp to_f(nil), do: nil
defp to_f(n), do: n / 1.0
```

- [ ] **Step 9: Run `read_trades` tests, confirm pass**

Run: `mix test test/automatron_ex/catalog/reader_test.exs -k read_trades`
Expected: PASS.

- [ ] **Step 10: Write failing test + implement `read_run_detail/2`**

```elixir
test "read_run_detail returns config-derived bar_types and counts" do
  {:ok, d} = Reader.read_run_detail(@cat, "e4599dab-fd51-4758-9564-c2061bc2104e")
  assert d.run_id == "e4599dab-fd51-4758-9564-c2061bc2104e"
  assert d.total_positions == 204
  assert is_list(d.bar_types) and length(d.bar_types) >= 1
end
```

Implementation: reuse `read_run_config/2`; derive `bar_types` from the config (confirm the config key holding bar types during recon — likely under the strategy/data config); `total_positions` / `total_fills` from feather row counts (`read_positions_closed` / `read_fills`).

- [ ] **Step 11: Run the full reader test file, confirm pass**

Run: `mix test test/automatron_ex/catalog/reader_test.exs`
Expected: PASS (all new + existing reader tests).

- [ ] **Step 12: Write the cross-language parity test**

`test/automatron_ex/catalog/parity_test.exs` — compare Elixir `read_trades`/`read_bars` to the Python reference for run `e4599dab`. Generate the Python reference once and assert field equality. Use a tag so it can be skipped if the venv is absent.

```elixir
@moduletag :parity
@cat "/Users/mordrax/code/nautilus_automatron/backtest_catalog"
@run "e4599dab-fd51-4758-9564-c2061bc2104e"

test "read_trades matches Python /trades JSON" do
  py = System.cmd("/Users/mordrax/code/nautilus_automatron/packages/server/.venv/bin/python",
        [Path.expand("test/support/py_ref_trades.py"), @cat, @run]) |> elem(0) |> Jason.decode!()
  {:ok, ex} = Reader.read_trades(@cat, @run)
  assert length(ex) == length(py)
  Enum.zip(ex, py) |> Enum.each(fn {e, p} ->
    assert e.relative_id == p["relative_id"]
    assert e.direction == p["direction"]
    assert_in_delta e.entry_price, p["entry_price"], 0.0001
    assert_in_delta e.exit_price, p["exit_price"], 0.0001
    assert_in_delta e.pnl, p["pnl"], 0.01
    assert e.entry_datetime == p["entry_datetime"]
  end)
end
```

Add `test/support/py_ref_trades.py` and `py_ref_bars.py` (small scripts mirroring the Python `fills.py`/`bars.py` projection; see the spec's reproduction pattern from `nae-46k.8`). Assert `read_bars` datetime/OHLCV equal the Python `/bars` JSON for the run's first bar type.

- [ ] **Step 13: Run parity, confirm pass**

Run: `mix test test/automatron_ex/catalog/parity_test.exs --include parity`
Expected: PASS, zero field mismatches. If `ns_to_iso` format differs from Python, fix it here.

- [ ] **Step 14: Format, full suite, commit**

```bash
mix format && mix test
git add lib/automatron_ex/catalog/reader.ex test/automatron_ex/catalog/
git commit -m "feat: Reader.read_bars/read_trades/read_run_detail + parity (Phase 2)"
```
Expected: all green.

**Acceptance:** the three functions return the spec's shapes; parity test passes vs Python for `e4599dab`; zero-position run → `[]`; `mix test` green; format clean. Branch only, PR for review.

---

## Task 2: eCharts asset + `CandlestickChart` hook

**Files:**
- Modify: `assets/package.json`, `assets/js/app.js`
- Create: `assets/js/hooks/candlestick_chart.js`

- [ ] **Step 1: Add echarts and build**

```bash
cd assets && npm install echarts && cd ..
```
Confirm `echarts` is in `assets/package.json` dependencies.

- [ ] **Step 2: Create the hook**

Port `buildOption` + the trade-markLine builder from the React `CandlestickChart.tsx` / `lib/trade-utils.ts` / `lib/chart-config.ts`. The hook receives `{ohlc, trades}` from the server and builds the same option.

```javascript
// assets/js/hooks/candlestick_chart.js
import * as echarts from "echarts";

const WIN = "#7FD373", LOSS = "#F68EA3";

function buildOption(ohlc, trades) {
  return {
    animation: false,
    tooltip: { trigger: "axis", axisPointer: { type: "cross" } },
    grid: [{ left: "3%", right: "3%", top: "5%", bottom: "12%" }],
    xAxis: [{ type: "category", data: ohlc.datetime, boundaryGap: false }],
    yAxis: [{ scale: true, splitArea: { show: true } }],
    dataZoom: [
      { type: "inside", start: 60, end: 100 },
      { type: "slider", start: 60, end: 100, bottom: "2%" },
    ],
    series: [
      {
        name: "Candlestick",
        type: "candlestick",
        data: ohlc.open.map((o, i) => [o, ohlc.close[i], ohlc.low[i], ohlc.high[i]]),
        itemStyle: { color: WIN, color0: LOSS, borderColor: "#2B6D22", borderColor0: "#970C28" },
        markLine: {
          symbol: ["none", "triangle"], symbolSize: 10, label: { show: true },
          data: (trades || []).map((t) => [
            { coord: [t.entry_datetime, t.entry_price], name: `#${t.relative_id}`,
              lineStyle: { color: t.pnl > 0 ? WIN : LOSS }, trade: t },
            { coord: [t.exit_datetime, t.exit_price] },
          ]),
        },
      },
    ],
  };
}

export default {
  mounted() {
    this.chart = echarts.init(this.el);
    this.handleEvent("chart:init", ({ ohlc, trades }) => {
      this.trades = trades || [];
      this.chart.setOption(buildOption(ohlc, trades), true);
    });
    this.handleEvent("chart:focus_trade", ({ index }) => {
      const t = (this.trades || [])[index];
      if (!t || !this.lastOhlc) return;
      // center dataZoom around the trade; see Task 3 for index math
    });
    this.chart.on("click", (p) => {
      const t = p?.data?.trade;
      if (t) this.pushEvent("select_trade", { index: t.relative_id - 1 });
    });
    this._resize = () => this.chart.resize();
    window.addEventListener("resize", this._resize);
  },
  destroyed() {
    window.removeEventListener("resize", this._resize);
    this.chart?.dispose();
  },
};
```

- [ ] **Step 3: Register the hook in `app.js`**

```javascript
import CandlestickChart from "./hooks/candlestick_chart";
// in the LiveSocket hooks object:
const hooks = { CandlestickChart };
let liveSocket = new LiveSocket("/live", Socket, { params: { _csrf_token: csrfToken }, hooks });
```
(Match the existing `app.js` structure — it may already have a `hooks` object; add to it.)

- [ ] **Step 4: Build assets, confirm success**

Run: `mix assets.build`
Expected: esbuild bundles with echarts, no errors.

- [ ] **Step 5: Commit**

```bash
git add assets/package.json assets/package-lock.json assets/js/hooks/candlestick_chart.js assets/js/app.js
git commit -m "feat: echarts CandlestickChart LiveView hook (Phase 2)"
```

**Acceptance:** `mix assets.build` succeeds with echarts; hook registered; option-builder reproduces the React candlestick + trade markLine shape. Branch only, PR for review. (Visual verification happens in Task 4's demo.)

---

## Task 3: `RunDetailLive` — wire data → hook, render page, handle events

**Files:**
- Modify: `lib/automatron_ex_web/live/run_detail_live.ex` (replace placeholder)
- Create: `test/automatron_ex_web/live/run_detail_live_test.exs`

- [ ] **Step 1: Write the failing LiveView tests**

```elixir
defmodule AutomatronExWeb.RunDetailLiveTest do
  use AutomatronExWeb.ConnCase
  import Phoenix.LiveViewTest

  @run "e4599dab-fd51-4758-9564-c2061bc2104e"

  setup do
    # point the app at the fixture catalog (config or Application.put_env in test)
    :ok
  end

  test "mounts, renders header + trades, pushes chart:init", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/runs/#{@run}")
    assert html =~ "204"           # position count in header
    assert render(lv) =~ "#1"      # first trade row / relative id
    assert_push_event(lv, "chart:init", %{ohlc: ohlc, trades: trades})
    assert length(trades) == 204
    assert Map.has_key?(ohlc, :datetime)
  end

  test "select_trade updates index and pushes focus", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/runs/#{@run}")
    render_hook(lv, "select_trade", %{"index" => 5})
    assert_push_event(lv, "chart:focus_trade", %{index: 5})
  end

  test "unknown run renders not-found, no crash", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/runs/does-not-exist")
    assert html =~ "not found" or html =~ "Back to runs"
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Run: `mix test test/automatron_ex_web/live/run_detail_live_test.exs`
Expected: FAIL (placeholder has no chart/data).

- [ ] **Step 3: Implement `RunDetailLive`**

Replace the placeholder. `mount/3`: `read_run_detail`; on `{:error, _}` assign `not_found`. When `connected?(socket)`: `read_bars(bar_types[0])` + `read_trades`, assign, `push_event("chart:init", %{ohlc: ohlc, trades: trades})`. Assign `current_index: 0`.

`render/1`: header (run id, `{total_positions} positions`, `{total_fills} fills`, bar-type chips); `<div id="run-chart" phx-hook="CandlestickChart" class="...h-[480px]">`; trade navigator (`phx-click="prev_trade"`/`"next_trade"`, "current/total"); trades table (relative_id, direction, entry/exit datetime+price, pnl); inert indicator sidebar (`disabled`, "Phase 3"). Not-found branch renders the message + back link.

`handle_event`:
```elixir
def handle_event("select_trade", %{"index" => i}, socket),
  do: {:noreply, socket |> assign(:current_index, i) |> push_event("chart:focus_trade", %{index: i})}

def handle_event("prev_trade", _p, socket) do
  i = max(socket.assigns.current_index - 1, 0)
  {:noreply, socket |> assign(:current_index, i) |> push_event("chart:focus_trade", %{index: i})}
end

def handle_event("next_trade", _p, socket) do
  i = min(socket.assigns.current_index + 1, length(socket.assigns.trades) - 1)
  {:noreply, socket |> assign(:current_index, i) |> push_event("chart:focus_trade", %{index: i})}
end
```
Catalog path: read from `AutomatronEx.catalog_path/0` (same config the dashboard sync uses).

- [ ] **Step 4: Run the LiveView tests, confirm pass**

Run: `mix test test/automatron_ex_web/live/run_detail_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Format, full suite, commit**

```bash
mix format && mix test
git add lib/automatron_ex_web/live/run_detail_live.ex test/automatron_ex_web/live/run_detail_live_test.exs
git commit -m "feat: RunDetailLive — chart + trades + navigator (Phase 2)"
```
Expected: all green.

**Acceptance:** mount renders header counts + trades table; `chart:init` pushed with OHLC/trades; `select_trade`/`prev`/`next` push `chart:focus_trade`; unknown run → not-found, no crash; suite green; format clean. Branch only, PR for review.

---

## Task 4: E2E parity verification + demo

**Files:**
- Create: `docs/phase-2-verification.md`

- [ ] **Step 1: Boot against the real catalog**

```bash
CATALOG_PATH=/Users/mordrax/code/nautilus_automatron/backtest_catalog PORT=4100 mix phx.server
```
Open `http://localhost:4100/runs/e4599dab-fd51-4758-9564-c2061bc2104e`. Confirm the candlestick renders and trade markLines appear.

- [ ] **Step 2: Compare to the Python page**

Run the Python app (`NAUTILUS_STORE_PATH=<catalog> bun run dev`, client `:5173`). Open the same run. Compare: bar count, visible trade entry/exit markers, colors (win green / loss pink), trade count in the table.

- [ ] **Step 3: Confirm data parity (already unit-tested, re-assert E2E)**

Run: `mix test --include parity`
Expected: PASS. Record the trade-count and bar-count for `e4599dab` (204 trades; bar count from `read_bars`).

- [ ] **Step 4: Write `docs/phase-2-verification.md`**

Side-by-side: Elixir `/runs/:id` vs Python run-detail — bar count, trade count, sample trade entry/exit/pnl, screenshots or text dumps. Note any difference. File a bug bead per discrepancy; do not silently fix.

- [ ] **Step 5: Commit**

```bash
git add docs/phase-2-verification.md
git commit -m "docs: Phase 2 E2E verification vs real catalog"
```

**Acceptance:** chart + trades render against the real catalog and match the Python page; parity tests pass; verification doc committed. Branch only, PR for review.

---

## Self-review

**Spec coverage:** read_bars/read_trades/read_run_detail (Task 1) · push_event delivery + hook (Tasks 2–3) · RunDetailLive header/chart/navigator/table/inert-sidebar (Task 3) · echarts asset (Task 2) · read-through, no Postgres (Tasks 1, 3) · error handling: not-found + missing bars (Task 3) · tests: reader unit + parity + LiveView (Tasks 1, 3) · E2E (Task 4). All spec sections covered.

**Placeholders:** none — every code step shows code; `ns_to_iso` format and direction/price field mapping are explicitly flagged for confirmation in Task 1 recon + Task 1 Step 13 parity (not left vague).

**Type consistency:** Trade map keys identical across Task 1 (impl), Task 1 (test), Task 3 (`assert_push_event`). `chart:init` payload `%{ohlc, trades}` consistent between Task 2 hook, Task 3 push, Task 3 test. `chart:focus_trade %{index}` consistent across hook + LiveView + test.
