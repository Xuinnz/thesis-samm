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
    block.style.height = '32px';
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
    arenaEl.classList.add('items-center', 'justify-center');

    const emptyWrap = document.createElement('div');
    emptyWrap.className = 'flex w-full flex-col items-center justify-center gap-4';

    const emptyText = document.createElement('p');
    emptyText.className = 'text-center text-slate-400';
    emptyText.textContent = 'No Arena Found';

    const overflowTag = document.createElement('div');
    overflowTag.className = 'w-full rounded-full px-4 py-2 text-center text-sm';
    overflowTag.style.background = 'rgba(255, 255, 255, 0.1)';
    overflowTag.style.color = '#e2e8f0';
    overflowTag.textContent = 'Arena Overflow Count: N/A';

    emptyWrap.append(emptyText, overflowTag);
    arenaEl.appendChild(emptyWrap);
    return;
  }

  const grid = document.createElement('div');
  grid.className = 'w-full';
  grid.style.display = 'grid';
  grid.style.gridTemplateColumns = 'repeat(auto-fit, minmax(140px, 1fr))';
  grid.style.gap = '12px';

  data.arenas.forEach((arena) => {
    const card = document.createElement('div');
    card.className = 'rounded-xl border border-slate-200 bg-white text-slate-800';
    card.style.padding = '12px';

    const title = document.createElement('p');
    title.className = 'mb-2 font-bold';
    title.textContent = `Arena ${arena.id}`;

    const lifespan = document.createElement('p');
    lifespan.className = 'text-sm';
    lifespan.textContent = `Lifespan: ${arena.lifespan_ms}ms`;

    const variance = document.createElement('p');
    variance.className = 'text-sm';
    variance.textContent = `Variance: ${arena.variance}`;

    const allocator = document.createElement('p');
    allocator.className = 'text-sm';
    allocator.textContent = `${arena.allocator_type} Allocator`;

    const usage = document.createElement('p');
    usage.className = 'text-sm';
    usage.textContent = `${arena.used_mb} / ${arena.total_mb}MB`;

    card.append(title, lifespan, variance, allocator, usage);
    grid.appendChild(card);
  });

  const overflowTag = document.createElement('div');
  overflowTag.className = 'w-full rounded-full px-4 py-2 text-center text-sm';
  overflowTag.style.marginTop = '16px';
  overflowTag.style.background = 'rgba(255, 255, 255, 0.1)';
  overflowTag.style.color = '#e2e8f0';
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

const BOOST_STAGES = ["Deriving workload", "Loading k6", "Collecting data", "ML Refinery", "SAMM Optimization", "Done ✓"];

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function onBoostWithSAMM() {
  const modal = document.getElementById('boost-modal');
  modal.classList.remove('hidden');

  const stages = Array.from(document.getElementById('modal-stage-list').children);
  stages.forEach((el) => el.classList.add('stage-item'));

  for (let i = 0; i < BOOST_STAGES.length; i++) {
    if (i > 0) {
      stages[i - 1].classList.remove('active');
    }
    stages[i].classList.add('active');
    await sleep(900);
  }

  await sleep(500);
  stages[stages.length - 1].classList.remove('active');
  modal.classList.add('hidden');
}

renderDashboard(MOCK_DATA.baseline);

document.getElementById('test-btn').addEventListener('click', () => {
  currentState = 'samm';
  renderDashboard(MOCK_DATA.samm);
});

document.getElementById('boost-btn').addEventListener('click', onBoostWithSAMM);
