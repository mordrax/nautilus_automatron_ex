// CandlestickChart LiveView hook.
//
// Owns an eCharts instance and builds the same option object as the React app
// (packages/client/src/components/chart/CandlestickChart.tsx + lib/chart-config,
// lib/trade-utils, lib/chart-zoom, hooks/use-trades). Candlestick + trade
// entry/exit markLines + zoom-to-trade, plus the registry indicators: Phase 3a
// overlay moving averages (SMA/EMA/HMA) on the price axis and Phase 3b oscillator
// panels (RSI/MACD/ATR/Stochastics) in their own grids below the chart. Key-level
// detectors remain deferred to later Phase 3 slices.
//
// Server contract (from RunDetailLive):
//   chart:init           %{ohlc, trades}  -> (re)build and render the option
//   chart:focus_trade    %{index}         -> dataZoom centered on that trade
//   chart:set_indicators %{series}        -> add/update/remove indicator series,
//                                            routed by each series' `display`
// Client -> server:
//   select_trade         %{index}         -> a trade markLine was clicked
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

// Panel-grid geometry, ported from buildPanelConfig / buildOption in
// CandlestickChart.tsx. Each display:"panel" indicator gets a fixed-height grid
// stacked below the main chart (own y-axis, sharing the category x-axis + zoom);
// the element grows per panel so the candlesticks stay usable. Pixel offsets are
// measured from the bottom of the (grown) element.
const DATA_ZOOM_HEIGHT = 40
const PANEL_HEIGHT = 100
const PANEL_GAP = 30
// Base element height (mirrors the run-chart container's h-[480px]) plus the
// per-panel growth that keeps the main grid large as panels are added.
const CHART_BASE_HEIGHT = 480
const PANEL_CONTAINER_GROWTH = 150

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

// The candlestick series (rows are [open, close, low, high]) with its per-trade
// entry->exit markLines. Always series index 0; indicator updates rebuild the
// whole series/grid/axis arrays and replaceMerge them (ports CandlestickChart.tsx),
// so it is re-sent each time and stays put.
const buildCandleSeries = (ohlc, trades) => {
  const ohlcValues = ohlc.open.map((_, i) => [
    ohlc.open[i],
    ohlc.close[i],
    ohlc.low[i],
    ohlc.high[i],
  ])

  return {
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
  }
}

// Overlay indicators (display:"overlay") draw on the price grid (xAxisIndex/
// yAxisIndex 0) — one line per output field (the 3a moving averages each carry a
// single "value"). `connectNulls` bridges the indicator's nil initialization
// prefix; `z: 3` keeps the line above the candlesticks. Anything not flagged as a
// panel falls here. Ports buildIndicatorOverlaySeries from CandlestickChart.tsx.
const buildOverlaySeries = (indicators) =>
  indicators
    .filter((ind) => ind.display !== "panel")
    .flatMap((ind) => {
      const fields = Object.keys(ind.outputs ?? {})
      return fields.map((field) => ({
        name: fields.length > 1 ? `${ind.label} ${field}` : ind.label,
        type: "line",
        data: ind.outputs[field] ?? [],
        smooth: false,
        showSymbol: false,
        connectNulls: true,
        lineStyle: {color: ind.color, width: 1.5},
        itemStyle: {color: ind.color},
        xAxisIndex: 0,
        yAxisIndex: 0,
        z: 3,
      }))
    })

// Panel indicators (display:"panel") each get their own grid stacked below the
// main chart: a fixed-height grid, its own labeled y-axis, and a category x-axis
// sharing the main chart's data + dataZoom. Multi-output indicators (Stochastics
// %K/%D) draw one line per output in the same panel. Returns the grids/x-axes/
// y-axes/series to splice into the option, plus the panel count. Ports
// buildPanelConfig from CandlestickChart.tsx.
const buildPanelConfig = (indicators) => {
  const panels = indicators.filter((ind) => ind.display === "panel")
  const grids = []
  const xAxes = []
  const yAxes = []
  const series = []

  panels.forEach((ind, panelIdx) => {
    const gridIdx = panelIdx + 1 // grid 0 is the main candlestick chart
    const bottomOffset =
      DATA_ZOOM_HEIGHT + (panels.length - 1 - panelIdx) * (PANEL_HEIGHT + PANEL_GAP)

    grids.push({
      left: "3%",
      right: "3%",
      height: `${PANEL_HEIGHT}px`,
      bottom: `${bottomOffset}px`,
    })

    // Only the bottom panel carries the shared datetime axis labels/ticks.
    const isBottomPanel = panelIdx === panels.length - 1
    xAxes.push({
      type: "category",
      gridIndex: gridIdx,
      data: ind.datetime,
      boundaryGap: false,
      axisLabel: isBottomPanel
        ? {formatter: (value) => formatDatetime(value), fontSize: 10}
        : {show: false},
      axisTick: {show: isBottomPanel},
    })

    yAxes.push({
      scale: true,
      gridIndex: gridIdx,
      splitNumber: 3,
      axisLabel: {fontSize: 10},
      name: ind.label,
      nameTextStyle: {fontSize: 10, padding: [0, 40, 0, 0]},
    })

    const fields = Object.keys(ind.outputs ?? {})
    for (const field of fields) {
      series.push({
        name: fields.length > 1 ? `${ind.label} ${field}` : ind.label,
        type: "line",
        data: ind.outputs[field] ?? [],
        smooth: false,
        showSymbol: false,
        lineStyle: {color: ind.color, width: 1.5},
        itemStyle: {color: ind.color},
        xAxisIndex: gridIdx,
        yAxisIndex: gridIdx,
      })
    }
  })

  return {grids, xAxes, yAxes, series, panelCount: panels.length}
}

// Ports buildOption from CandlestickChart.tsx: the main candlestick grid plus a
// stacked grid per panel indicator. Overlays layer onto the price axis; panels add
// their own grids/axes below. Every grid's x-axis shares the one dataZoom, so the
// panels scroll with the candlesticks. Called fresh on chart:init (no indicators)
// and rebuilt on chart:set_indicators.
const buildOption = (ohlc, trades, indicators = []) => {
  const categoryData = ohlc.datetime
  const defaultStart = computeDefaultStart(categoryData.length)

  const panels = buildPanelConfig(indicators)
  const hasPanels = panels.panelCount > 0

  // Push the main grid's bottom up to make room for the stacked panels + slider.
  const mainGridBottom = hasPanels
    ? `${DATA_ZOOM_HEIGHT + panels.panelCount * (PANEL_HEIGHT + PANEL_GAP) + DATA_ZOOM_HEIGHT}px`
    : "15%"

  // The dataZoom drives the main x-axis (0) plus each panel's x-axis.
  const allXAxisIndices = [0, ...panels.xAxes.map((_, i) => i + 1)]

  return {
    animation: false,
    tooltip: {trigger: "axis", axisPointer: {type: "cross"}},
    grid: [{left: "3%", right: "3%", top: "5%", bottom: mainGridBottom}, ...panels.grids],
    xAxis: [
      {
        type: "category",
        data: categoryData,
        boundaryGap: false,
        // With panels, the bottom panel owns the datetime labels; hide the main one.
        axisLabel: hasPanels ? {show: false} : {formatter: (value) => formatDatetime(value)},
        axisTick: {show: !hasPanels},
      },
      ...panels.xAxes,
    ],
    yAxis: [{scale: true, splitArea: {show: true}}, ...panels.yAxes],
    dataZoom: [
      {type: "inside", start: defaultStart, end: 100, xAxisIndex: allXAxisIndices},
      {type: "slider", start: defaultStart, end: 100, bottom: "2%", xAxisIndex: allXAxisIndices},
    ],
    series: [
      buildCandleSeries(ohlc, trades),
      ...buildOverlaySeries(indicators),
      ...panels.series,
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
    this.indicators = []

    this.handleEvent("chart:init", ({ohlc, trades}) => {
      this.ohlc = ohlc
      this.trades = trades || []
      // A fresh option clears any prior overlays; the server re-pushes the
      // persisted ones via chart:set_indicators right after init.
      this.indicators = []
      this.chart.setOption(buildOption(ohlc, this.trades), true)
    })

    this.handleEvent("chart:set_indicators", ({series}) => {
      this.indicators = series || []
      this.renderIndicators()
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

  // Re-apply the indicators (overlays + panels) without disturbing the user's zoom.
  // Mirrors the CandlestickChart.tsx update effect: rebuild the full option and
  // replaceMerge the series + grids + axes, so panels are added/removed and the
  // grids reflow; the candlestick (re-sent at index 0) and trade markLines stay.
  // The element grows with the panel count so the candlesticks stay usable.
  renderIndicators() {
    if (!this.chart || !this.ohlc) return

    const panelCount = this.indicators.filter((ind) => ind.display === "panel").length
    this.el.style.height = `${CHART_BASE_HEIGHT + panelCount * PANEL_CONTAINER_GROWTH}px`

    const option = buildOption(this.ohlc, this.trades, this.indicators)

    // dataZoom is merged (not replaced), but its xAxisIndex set changes as panels
    // come and go — so rebuild it, carrying over the current start/end zoom window.
    const current = this.chart.getOption()
    const start = current.dataZoom?.[0]?.start ?? 0
    const end = current.dataZoom?.[0]?.end ?? 100
    option.dataZoom = option.dataZoom.map((dz) => ({...dz, start, end}))

    this.chart.setOption(option, {replaceMerge: ["series", "grid", "xAxis", "yAxis"]})
    this.chart.resize()
  },

  destroyed() {
    window.removeEventListener("resize", this._onResize)
    this.chart?.dispose()
  },
}
