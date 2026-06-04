// CandlestickChart LiveView hook.
//
// Owns an eCharts instance and builds the same option object as the React app
// (packages/client/src/components/chart/CandlestickChart.tsx + lib/chart-config,
// lib/trade-utils, lib/chart-zoom, hooks/use-trades). Phase 2 scope: candlestick
// + trade entry/exit markLines + zoom-to-trade. Indicators, key-levels and
// secondary panels are deferred to Phase 3.
//
// Server contract (from RunDetailLive):
//   chart:init        %{ohlc, trades}  -> (re)build and render the option
//   chart:focus_trade %{index}         -> dataZoom centered on that trade
// Client -> server:
//   select_trade      %{index}         -> a trade markLine was clicked
import * as echarts from "echarts"

// Mirrors CHART_COLORS in lib/chart-config.ts.
const TRADE_WIN = "#7FD373"
const TRADE_LOSS = "#F68EA3"
const CANDLE_UP = "#7FD373"
const CANDLE_UP_BORDER = "#2B6D22"
const CANDLE_DOWN = "#F68EA3"
const CANDLE_DOWN_BORDER = "#970C28"

// Number of bars visible by default; ports DEFAULT_VISIBLE_BARS / computeDefaultStart
// from lib/chart-zoom.ts — show the most recent `visible` bars on load.
const DEFAULT_VISIBLE_BARS = 50

const computeDefaultStart = (totalBars, visible = DEFAULT_VISIBLE_BARS) => {
  if (totalBars <= visible) return 0
  return ((totalBars - visible) / totalBars) * 100
}

// Ports formatDatetime from lib/trade-utils.ts ("Mon-D HH:MM"), but renders in
// UTC rather than the browser's local time so the chart x-axis matches the
// trades table's UTC timestamps (fmt_datetime in run_detail_live.ex). This is a
// deliberate, documented divergence from React's local-time display, chosen for
// server/client timezone consistency (nae-t2x).
const formatDatetime = (iso) => {
  const d = new Date(iso)
  const month = d.toLocaleString("en", {month: "short", timeZone: "UTC"})
  const day = d.getUTCDate()
  const hours = d.getUTCHours().toString().padStart(2, "0")
  const mins = d.getUTCMinutes().toString().padStart(2, "0")
  return `${month}-${day} ${hours}:${mins}`
}

// Ports findBarIndex from lib/trade-utils.ts: nearest bar index to an ISO datetime.
const findBarIndex = (datetimes, target) => {
  const targetTime = new Date(target).getTime()
  let closest = 0
  let minDiff = Infinity
  for (let i = 0; i < datetimes.length; i++) {
    const diff = Math.abs(new Date(datetimes[i]).getTime() - targetTime)
    if (diff < minDiff) {
      minDiff = diff
      closest = i
    }
  }
  return closest
}

// Ports buildTradeMarkLines from lib/trade-utils.ts: one entry->exit line per
// trade, colored by pnl. The start point carries `name` (label) and the raw
// `trade` (read back on click).
const buildTradeMarkLines = (trades) =>
  trades.map((trade) => [
    {
      coord: [trade.entry_datetime, trade.entry_price],
      lineStyle: {color: trade.pnl > 0 ? TRADE_WIN : TRADE_LOSS},
      name: `#${trade.relative_id}`,
      trade,
    },
    {coord: [trade.exit_datetime, trade.exit_price]},
  ])

// Ports buildOption from CandlestickChart.tsx, Phase 2 subset (no indicator
// overlays / key levels / panels). Candlestick rows are [open, close, low, high].
const buildOption = (ohlc, trades) => {
  const categoryData = ohlc.datetime
  const ohlcValues = ohlc.open.map((_, i) => [
    ohlc.open[i],
    ohlc.close[i],
    ohlc.low[i],
    ohlc.high[i],
  ])
  const defaultStart = computeDefaultStart(categoryData.length)

  return {
    animation: false,
    tooltip: {trigger: "axis", axisPointer: {type: "cross"}},
    grid: [{left: "3%", right: "3%", top: "5%", bottom: "15%"}],
    xAxis: [
      {
        type: "category",
        data: categoryData,
        boundaryGap: false,
        axisLabel: {formatter: (value) => formatDatetime(value)},
        axisTick: {show: true},
      },
    ],
    yAxis: [{scale: true, splitArea: {show: true}}],
    dataZoom: [
      {type: "inside", start: defaultStart, end: 100, xAxisIndex: [0]},
      {type: "slider", start: defaultStart, end: 100, bottom: "2%", xAxisIndex: [0]},
    ],
    series: [
      {
        name: "Candlestick",
        type: "candlestick",
        data: ohlcValues,
        itemStyle: {
          color: CANDLE_UP,
          color0: CANDLE_DOWN,
          borderColor: CANDLE_UP_BORDER,
          borderColor0: CANDLE_DOWN_BORDER,
        },
        markLine: {
          symbol: ["none", "triangle"],
          symbolSize: 10,
          label: {
            show: true,
            formatter: (params) => params.data?.name ?? "",
            position: "end",
            fontSize: 10,
          },
          emphasis: {lineStyle: {width: 4}},
          lineStyle: {type: "solid", width: 2},
          data: buildTradeMarkLines(trades),
        },
      },
    ],
  }
}

// Ports centerOnTrade from hooks/use-trades.ts: zoom to 5x the trade's bar-span,
// centered on it, minimum 50 bars, clamped to the data range.
const centerOnTrade = (chart, ohlc, trades, index) => {
  if (!chart || !ohlc || !trades || trades.length === 0) return
  const trade = trades[index]
  if (!trade) return

  const totalBars = ohlc.datetime.length
  const entryIdx = findBarIndex(ohlc.datetime, trade.entry_datetime)
  const exitIdx = findBarIndex(ohlc.datetime, trade.exit_datetime)

  const tradeLen = Math.max(exitIdx - entryIdx, 1)
  const viewLen = Math.max(tradeLen * 5, 50)
  const padding = (viewLen - tradeLen) / 2
  const startIdx = Math.max(0, Math.round(entryIdx - padding))
  const endIdx = Math.min(totalBars - 1, Math.round(exitIdx + padding))

  chart.dispatchAction({
    type: "dataZoom",
    start: (startIdx / totalBars) * 100,
    end: (endIdx / totalBars) * 100,
  })
}

export default {
  mounted() {
    this.chart = echarts.init(this.el)
    this.ohlc = null
    this.trades = []

    this.handleEvent("chart:init", ({ohlc, trades}) => {
      this.ohlc = ohlc
      this.trades = trades || []
      this.chart.setOption(buildOption(ohlc, this.trades), true)
    })

    this.handleEvent("chart:focus_trade", ({index}) => {
      centerOnTrade(this.chart, this.ohlc, this.trades, index)
    })

    // A trade markLine was clicked -> report its index to the server.
    this.chart.on("click", {componentType: "markLine"}, (params) => {
      const trade = params.data?.trade
      if (!trade) return
      const index = this.trades.findIndex((t) => t.relative_id === trade.relative_id)
      if (index >= 0) this.pushEvent("select_trade", {index})
    })

    this._onResize = () => this.chart.resize()
    window.addEventListener("resize", this._onResize)
  },

  destroyed() {
    window.removeEventListener("resize", this._onResize)
    this.chart?.dispose()
  },
}
