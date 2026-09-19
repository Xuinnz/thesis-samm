// TODO (stretch): dashed reference line at 1024MB on memory chart, container cap

let memoryChart = null;
let throughputChart = null;
let latencyChart = null;

const STROKE_BLUE = "#3b82f6";
const STROKE_RED = "#ef4444";
const FILL_BLUE = "rgba(59, 130, 246, 0.25)";
const FILL_RED = "rgba(239, 68, 68, 0.25)";

function chartSize(el) {
  return {
    width: el.clientWidth || 600,
    height: el.clientHeight || 256,
  };
}

function seriesOpts(isDual, filled) {
  const primary = {
    stroke: STROKE_BLUE,
    width: 2,
  };
  const secondary = {
    stroke: STROKE_RED,
    width: 2,
  };
  if (filled) {
    primary.fill = FILL_BLUE;
    secondary.fill = FILL_RED;
  }
  return isDual ? [{}, primary, secondary] : [{}, primary];
}

function renderMemoryChart(data) {
  if (memoryChart) {
    memoryChart.destroy();
    memoryChart = null;
  }

  const el = document.getElementById("memory-chart");
  const samm = data.series.samm_memory_mb;
  const isDual = Array.isArray(samm);
  const chartData = isDual
    ? [data.series.time_seconds, samm, data.series.v8_memory_mb]
    : [data.series.time_seconds, data.series.v8_memory_mb];
  const size = chartSize(el);

  memoryChart = new uPlot(
    {
      width: size.width,
      height: size.height,
      scales: {
        x: { time: false, min: 0, max: 60 },
        y: { min: 0, max: isDual ? 1200 : 1024 },
      },
      axes: [{ label: "Time (seconds)" }, {}],
      series: seriesOpts(isDual, false),
    },
    chartData,
    el
  );
}

function renderThroughputChart(data) {
  if (throughputChart) {
    throughputChart.destroy();
    throughputChart = null;
  }

  const el = document.getElementById("throughput-chart");
  const samm = data.series.samm_throughput_rps;
  const isDual = Array.isArray(samm);
  const chartData = isDual
    ? [data.series.time_seconds, samm, data.series.v8_throughput_rps]
    : [data.series.time_seconds, data.series.v8_throughput_rps];
  const size = chartSize(el);

  throughputChart = new uPlot(
    {
      width: size.width,
      height: size.height,
      scales: {
        x: { time: false, min: 1, max: 60 },
        y: { min: 0, max: 1500 },
      },
      axes: [{ label: "Time (seconds)" }, {}],
      series: seriesOpts(isDual, true),
    },
    chartData,
    el
  );
}

function renderLatencyChart(data) {
  if (latencyChart) {
    latencyChart.destroy();
    latencyChart = null;
  }

  const el = document.getElementById("latency-chart");
  const samm = data.series.samm_latency_ms;
  const isDual = Array.isArray(samm);
  const chartData = isDual
    ? [data.series.time_seconds, samm, data.series.v8_latency_ms]
    : [data.series.time_seconds, data.series.v8_latency_ms];
  const size = chartSize(el);

  latencyChart = new uPlot(
    {
      width: size.width,
      height: size.height,
      scales: {
        x: { time: false, min: 0, max: 60 },
        y: { min: 0, max: 1200 },
      },
      axes: [{ label: "Time (seconds)" }, {}],
      series: seriesOpts(isDual, false),
    },
    chartData,
    el
  );
}

function renderCharts(data) {
  renderMemoryChart(data);
  renderThroughputChart(data);
  renderLatencyChart(data);
}
