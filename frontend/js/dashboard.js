let currentState = 'landing';

function displayOrNA(value, suffix = '') {
  return value !== null && value !== undefined ? `${value}${suffix}` : 'N/A';
}

function updateHeadline(data) {
  document.getElementById('status-headline').textContent = data.status_headline;
}

function updateStatusBar(data) {
  const healthEl = document.getElementById('health-score-value');
  healthEl.textContent = data.health_score;
  document.getElementById('system-status-value').textContent = data.system_status;
  document.getElementById('memory-load-value').textContent = data.memory_load;

  const isStable = data.system_status === 'STABLE';
  healthEl.classList.toggle('text-green-400', isStable);
  healthEl.classList.toggle('text-red-400', !isStable);
  healthEl.style.color = isStable ? '#4ade80' : '#f87171';
}

function hexToRgb(hex) {
  const n = parseInt(hex.slice(1), 16);
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
}

function lerp(a, b, t) {
  return a + (b - a) * t;
}

function mixHex(from, to, t) {
  const a = hexToRgb(from);
  const b = hexToRgb(to);
  const r = Math.round(lerp(a.r, b.r, t));
  const g = Math.round(lerp(a.g, b.g, t));
  const bl = Math.round(lerp(a.b, b.b, t));
  return `rgb(${r}, ${g}, ${bl})`;
}

function gradientColorAt(t, stops) {
  if (t <= 0) return stops[0];
  if (t >= 1) return stops[stops.length - 1];
  const scaled = t * (stops.length - 1);
  const i = Math.min(Math.floor(scaled), stops.length - 2);
  return mixHex(stops[i], stops[i + 1], scaled - i);
}

function updateMemoryDensityTracker(data) {
  document.getElementById('memory-density-current').textContent =
    `${data.memory_density_current_mb} MB / 1 GB`;

  const blocksEl = document.getElementById('memory-density-blocks');
  blocksEl.replaceChildren();

  const filledCount = Math.round(
    (data.memory_density_current_mb / data.memory_density_max_mb) * 24
  );
  const isStable = data.system_status === 'STABLE';
  const stops = isStable
    ? ['#0b1428', '#2563eb', '#7dd3fc']
    : ['#0b1428', '#2563eb', '#7f1d1d'];

  for (let i = 0; i < 24; i++) {
    const block = document.createElement('div');
    block.style.height = '128px';
    block.style.flex = '1';
    block.style.borderRadius = '2px';
    if (i < filledCount) {
      const t = filledCount <= 1 ? 1 : i / (filledCount - 1);
      block.style.background = gradientColorAt(t, stops);
    } else {
      block.style.background = '#ffffff';
      block.style.border = '1px solid #cbd5e1';
    }
    blocksEl.appendChild(block);
  }
}

function updateArenaSection(data) {
  const arenaEl = document.getElementById('arena-content');
  arenaEl.replaceChildren();
  arenaEl.className = 'flex flex-1 flex-col';

  if (!data.arenas || data.arenas.length === 0) {
    const emptyWrap = document.createElement('div');
    emptyWrap.className = 'flex w-full flex-1 flex-col items-center justify-center';

    const emptyText = document.createElement('p');
    emptyText.className = 'text-center text-slate-400';
    emptyText.textContent = 'No Arena Found';

    emptyWrap.appendChild(emptyText);

    const overflowTag = document.createElement('div');
    overflowTag.className = 'mt-auto w-full rounded-full bg-white px-4 py-2 text-center text-sm font-semibold text-slate-900';
    overflowTag.textContent = 'Arena Overflow Count: N/A';

    arenaEl.append(emptyWrap, overflowTag);
    return;
  }

  const grid = document.createElement('div');
  grid.className = 'w-full flex-1 mt-4 mb-8';
  grid.style.display = 'grid';
  grid.style.gridTemplateColumns = 'repeat(auto-fit, minmax(140px, 1fr))';
  grid.style.gap = '16px';
  grid.style.alignContent = 'start';

  data.arenas.forEach((arena) => {
    const card = document.createElement('div');
    card.className = 'flex flex-col items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white p-6 text-slate-800 shadow-sm text-center';
    card.style.height = '300px';

    const title = document.createElement('p');
    title.className = 'mb-1 font-bold text-lg';
    title.textContent = `Arena ${arena.id}`;

    const lifespan = document.createElement('p');
    lifespan.className = 'text-sm text-slate-600';
    lifespan.textContent = `Lifespan: ${arena.lifespan_ms}ms`;

    const variance = document.createElement('p');
    variance.className = 'text-sm text-slate-600';
    variance.textContent = `Variance: ${arena.variance}`;

    const allocator = document.createElement('p');
    allocator.className = 'text-sm text-slate-600';
    allocator.textContent = `${arena.allocator_type}`;

    const usage = document.createElement('p');
    usage.className = 'mt-2 text-sm font-bold text-slate-800 bg-slate-100 rounded-md px-3 py-1.5';
    usage.textContent = `${arena.used_mb} / ${arena.total_mb}MB`;

    card.append(title, lifespan, variance, allocator, usage);
    grid.appendChild(card);
  });

  const overflowTag = document.createElement('div');
  overflowTag.className = 'mt-auto w-full rounded-full bg-white px-4 py-2 text-center text-sm font-semibold text-slate-900';
  overflowTag.textContent = `Arena Overflow Count: ${data.arena_overflow_count}`;

  arenaEl.append(grid, overflowTag);
}

function updateMLMetrics(data) {
  document.getElementById('kmeans-clusters-value').textContent = displayOrNA(data.k_means_clusters);
  document.getElementById('ml-accuracy-value').textContent =
    data.ml_accuracy_pct != null ? `${data.ml_accuracy_pct}%` : 'N/A';
}

function renderDashboard(data) {
  updateStatusBar(data);
  updateHeadline(data);
  updateMemoryDensityTracker(data);
  updateArenaSection(data);
  updateMLMetrics(data);
  renderCharts(data);
}

const BOOST_STAGES = [
  "Deriving Workload",
  "Loading k6",
  "Collecting Data",
  "ML Refinery",
  "SAMM Optimization"
];

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function getBoostModalEls() {
  return {
    modal: document.getElementById('boost-modal'),
    statusText: document.getElementById('modal-status-text'),
    spinner: document.getElementById('modal-spinner'),
    doneBtn: document.getElementById('modal-done-btn'),
  };
}

function setBoostModalOpen(open) {
  const { modal } = getBoostModalEls();
  if (!modal) return;
  modal.classList.toggle('is-open', open);
  modal.classList.toggle('hidden', !open);
  modal.setAttribute('aria-hidden', open ? 'false' : 'true');
}

function resetModal() {
  const { statusText, spinner, doneBtn } = getBoostModalEls();
  if (statusText) statusText.textContent = '';
  if (spinner) spinner.classList.remove('hidden');
  if (doneBtn) doneBtn.classList.add('hidden');
}

async function onBoostWithSAMM() {
  const { modal, statusText, spinner, doneBtn } = getBoostModalEls();
  if (!modal || !statusText || !spinner || !doneBtn) return;

  resetModal();
  setBoostModalOpen(true);

  for (let i = 0; i < BOOST_STAGES.length; i++) {
    if (i > 0) await sleep(750);
    statusText.textContent = BOOST_STAGES[i];
  }

  await sleep(750);
  statusText.textContent = 'Complete';
  spinner.classList.add('hidden');
  doneBtn.textContent = 'Done';
  doneBtn.classList.remove('hidden');
}

renderDashboard(MOCK_DATA.baseline);

document.getElementById('test-btn').addEventListener('click', () => {
  currentState = 'samm';
  renderDashboard(MOCK_DATA.samm);
});

document.getElementById('boost-btn').addEventListener('click', onBoostWithSAMM);

document.getElementById('modal-done-btn').addEventListener('click', () => {
  setBoostModalOpen(false);
  currentState = 'samm';
  renderDashboard(MOCK_DATA.samm);
  resetModal();
});
