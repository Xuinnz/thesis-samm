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
    height: (el.clientHeight || 256) - 40,
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
      legend: { show: true },
      series: isDual ? [
        {},
        { stroke: STROKE_BLUE, width: 2, label: "SAMM (MB)", value: (u, v) => v == null ? '--' : v.toFixed(1) + ' MB' },
        { stroke: STROKE_RED, width: 2, label: "V8 Baseline (MB)", value: (u, v) => v == null ? '--' : v.toFixed(1) + ' MB' }
      ] : [
        {},
        { stroke: STROKE_BLUE, width: 2, label: "V8 Baseline (MB)", value: (u, v) => v == null ? '--' : v.toFixed(1) + ' MB' }
      ],
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
      legend: { show: true },
      series: isDual ? [
        {},
        { stroke: STROKE_BLUE, width: 2, fill: FILL_BLUE, label: "SAMM (req/s)", value: (u, v) => v == null ? '--' : Math.round(v) + ' req/s' },
        { stroke: STROKE_RED, width: 2, fill: FILL_RED, label: "V8 Baseline (req/s)", value: (u, v) => v == null ? '--' : Math.round(v) + ' req/s' }
      ] : [
        {},
        { stroke: STROKE_BLUE, width: 2, fill: FILL_BLUE, label: "V8 Baseline (req/s)", value: (u, v) => v == null ? '--' : Math.round(v) + ' req/s' }
      ],
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
      legend: { show: true },
      series: isDual ? [
        {},
        { stroke: STROKE_BLUE, width: 2, label: "SAMM (ms)", value: (u, v) => v == null ? '--' : v.toFixed(1) + ' ms' },
        { stroke: STROKE_RED, width: 2, label: "V8 Baseline (ms)", value: (u, v) => v == null ? '--' : v.toFixed(1) + ' ms' }
      ] : [
        {},
        { stroke: STROKE_BLUE, width: 2, label: "V8 Baseline (ms)", value: (u, v) => v == null ? '--' : v.toFixed(1) + ' ms' }
      ],
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

const resizeObserver = new ResizeObserver(entries => {
  for (let entry of entries) {
    const el = entry.target;
    const size = chartSize(el);
    if (el.id === 'memory-chart' && memoryChart) {
      memoryChart.setSize(size);
    } else if (el.id === 'throughput-chart' && throughputChart) {
      throughputChart.setSize(size);
    } else if (el.id === 'latency-chart' && latencyChart) {
      latencyChart.setSize(size);
    }
  }
});

resizeObserver.observe(document.getElementById('memory-chart'));
resizeObserver.observe(document.getElementById('throughput-chart'));
resizeObserver.observe(document.getElementById('latency-chart'));
