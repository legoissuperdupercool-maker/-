/* global forge, md, Terminal, FitAddon */
'use strict';

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = md.esc;

const TITLES = { dashboard: 'Command Center', terminal: 'Terminal', server: 'Home Server', store: 'App Store', settings: 'Settings' };
const ENGINE_NAMES = { claude: 'Claude', free: 'Free cloud AI', ollama: 'Local AI (Ollama)' };

let currentView = 'dashboard';
let settings = null;

function fmtBytes(n, perSec = false) {
  if (!n || n < 0) return perSec ? '0 B/s' : '0 B';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(Math.floor(Math.log(n) / Math.log(1024)), u.length - 1);
  return `${(n / 1024 ** i).toFixed(i ? 1 : 0)} ${u[i]}${perSec ? '/s' : ''}`;
}

function toast(text, isErr = false) {
  const t = document.createElement('div');
  t.className = `toast${isErr ? ' err' : ''}`;
  t.textContent = text;
  document.body.append(t);
  setTimeout(() => t.remove(), 3500);
}

// ---------------------------------------------------------------- navigation
function show(view) {
  currentView = view;
  $$('.nav').forEach((b) => b.classList.toggle('active', b.dataset.view === view));
  $$('.view').forEach((v) => v.classList.toggle('active', v.id === `view-${view}`));
  $('#viewTitle').textContent = TITLES[view];
  if (view === 'terminal') ensureTerminal();
  if (view === 'server' || view === 'dashboard') refreshDocker();
  if (view === 'settings') loadSettingsForm();
}

document.addEventListener('click', (e) => {
  const nav = e.target.closest('.nav');
  if (nav) return show(nav.dataset.view);
  const go = e.target.closest('[data-goto]');
  if (go) return show(go.dataset.goto);
  const ask = e.target.closest('[data-ask]');
  if (ask) return sendPrompt(ask.dataset.ask);
  const copy = e.target.closest('pre.code .copy');
  if (copy) {
    navigator.clipboard.writeText(copy.nextElementSibling.textContent);
    copy.textContent = 'Copied';
    setTimeout(() => (copy.textContent = 'Copy'), 1200);
    return;
  }
  const link = e.target.closest('a[href^="http"]');
  if (link) {
    e.preventDefault();
    forge.openExternal(link.href).catch((err) => toast(err.message, true));
  }
});

setInterval(() => {
  $('#clock').textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}, 1000);

// ---------------------------------------------------------------- dashboard
const CIRC = 2 * Math.PI * 50;
function setGauge(name, pct, label) {
  const g = $(`.gauge[data-g="${name}"]`);
  const p = Math.max(0, Math.min(100, pct || 0));
  $('.val', g).style.strokeDashoffset = String(CIRC * (1 - p / 100));
  $('.gv b', g).textContent = label ?? Math.round(p);
}

const HISTORY = 90;
const cpuHist = [];
const memHist = [];

function drawChart() {
  const c = $('#loadChart');
  const dpr = window.devicePixelRatio || 1;
  const w = c.clientWidth;
  const h = c.clientHeight;
  if (!w) return;
  if (c.width !== w * dpr) {
    c.width = w * dpr;
    c.height = h * dpr;
  }
  const ctx = c.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);

  ctx.strokeStyle = 'rgba(255,255,255,0.05)';
  ctx.lineWidth = 1;
  ctx.fillStyle = 'rgba(138,144,168,0.6)';
  ctx.font = '10px ' + getComputedStyle(document.body).getPropertyValue('--mono');
  for (const v of [25, 50, 75]) {
    const y = h - (v / 100) * (h - 8);
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
    ctx.fillText(`${v}%`, 4, y - 3);
  }

  const series = [
    [memHist, '#a855f7', 'rgba(168,85,247,'],
    [cpuHist, '#22e4ff', 'rgba(34,228,255,'],
  ];
  for (const [data, color, rgba] of series) {
    if (data.length < 2) continue;
    const step = w / (HISTORY - 1);
    const x0 = w - (data.length - 1) * step;
    const pt = (i) => [x0 + i * step, h - (data[i] / 100) * (h - 8)];
    ctx.beginPath();
    ctx.moveTo(...pt(0));
    for (let i = 1; i < data.length; i++) {
      const [px, py] = pt(i - 1);
      const [x, y] = pt(i);
      ctx.bezierCurveTo(px + step / 2, py, x - step / 2, y, x, y);
    }
    ctx.save();
    ctx.shadowColor = color;
    ctx.shadowBlur = 12;
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.stroke();
    ctx.restore();
    ctx.lineTo(w, h);
    ctx.lineTo(x0, h);
    ctx.closePath();
    const grad = ctx.createLinearGradient(0, 0, 0, h);
    grad.addColorStop(0, rgba + '0.28)');
    grad.addColorStop(1, rgba + '0)');
    ctx.fillStyle = grad;
    ctx.fill();
    const [lx, ly] = pt(data.length - 1);
    ctx.beginPath();
    ctx.arc(lx - 2, ly, 3.5, 0, Math.PI * 2);
    ctx.fillStyle = '#fff';
    ctx.shadowColor = color;
    ctx.shadowBlur = 14;
    ctx.fill();
    ctx.shadowBlur = 0;
  }
}
window.addEventListener('resize', drawChart);

async function tickStats() {
  try {
    const s = await forge.stats.snapshot();
    const memPct = (s.memUsed / s.memTotal) * 100;
    const diskPct = s.diskTotal ? (s.diskUsed / s.diskTotal) * 100 : 0;
    setGauge('cpu', s.cpu);
    setGauge('mem', memPct);
    setGauge('disk', diskPct);
    setGauge('temp', s.tempC ? s.tempC : 0, s.tempC ? Math.round(s.tempC) : '--');
    $('#memDetail').textContent = `${fmtBytes(s.memUsed)} / ${fmtBytes(s.memTotal)}`;
    $('#diskDetail').textContent = `${fmtBytes(s.diskUsed)} / ${fmtBytes(s.diskTotal)}`;
    $('#netRx').textContent = fmtBytes(s.netRx, true);
    $('#netTx').textContent = fmtBytes(s.netTx, true);
    const hrs = Math.floor(s.uptime / 3600);
    $('#hostLine').textContent = `${s.host} · ${s.platform} · up ${hrs >= 24 ? `${Math.floor(hrs / 24)}d ` : ''}${hrs % 24}h`;

    const cores = $('#cores');
    if (cores.children.length !== s.cores.length) cores.innerHTML = s.cores.map(() => '<i></i>').join('');
    s.cores.forEach((v, i) => cores.children[i].style.setProperty('--h', `${v}%`));

    if (!cpuHist.length) {
      // start with a full-width line instead of an empty chart
      cpuHist.push(...Array(HISTORY - 1).fill(s.cpu));
      memHist.push(...Array(HISTORY - 1).fill(memPct));
    }
    cpuHist.push(s.cpu);
    memHist.push(memPct);
    if (cpuHist.length > HISTORY) cpuHist.shift();
    if (memHist.length > HISTORY) memHist.shift();
    if (currentView === 'dashboard') drawChart();
  } catch (e) {
    console.error(e);
  }
}

async function tickProcs() {
  if (currentView !== 'dashboard') return;
  try {
    const list = await forge.stats.top();
    $('#procs').innerHTML = list
      .map(
        (p) =>
          `<tr><td title="${esc(p.name)}">${esc(p.name)}</td><td class="n"><span class="bar" style="width:${Math.min(p.cpu, 100) * 0.4}px"></span>${p.cpu}%</td><td class="n">${p.mem}%</td></tr>`,
      )
      .join('');
  } catch {
    // processes can race; next tick retries
  }
}

// ---------------------------------------------------------------- docker
let dockerOk = null;

async function refreshDocker() {
  const chip = $('#dockerChip');
  let st;
  try {
    st = await forge.docker.status();
  } catch (e) {
    st = { available: false, error: e.message };
  }
  dockerOk = st.available;
  const busyEngine = ['checking', 'starting', 'installing'].includes(engineState.phase);
  $('.led', chip).className = `led ${st.available ? 'on' : busyEngine ? 'warn' : 'off'}`;
  $('span', chip).textContent = st.available ? `Server engine ${st.version}` : busyEngine ? 'Engine starting…' : 'Engine offline';
  $('#engineCard').hidden = st.available;
  if (!st.available) {
    $('#containers').innerHTML = '';
    $('#serverSummary').textContent = '';
    $('#miniContainers').innerHTML = `<div class="muted">${busyEngine ? 'Server engine is starting…' : 'Server engine is off. <a href="#" data-goto="server">Set it up →</a>'}</div>`;
    renderEngine();
    return;
  }
  if (currentView !== 'server' && currentView !== 'dashboard') return;
  let list;
  try {
    list = await forge.docker.list();
  } catch (e) {
    return toast(e.message, true);
  }
  const running = list.filter((c) => c.state === 'running').length;
  $('#serverSummary').textContent = `${list.length} containers · ${running} running`;
  $('#miniContainers').innerHTML = list.length
    ? list
        .slice(0, 6)
        .map((c) => `<div class="mc"><i class="led ${c.state === 'running' ? 'on' : 'off'}"></i><span>${esc(c.name)}</span><small>${c.cpu != null ? c.cpu + '%' : c.state}</small></div>`)
        .join('')
    : '<div class="muted">No containers yet. Install an app from the App Store.</div>';

  if (currentView !== 'server') return;
  $('#containers').innerHTML = list.length
    ? list.map(containerCard).join('')
    : '<div class="card empty"><h3>No containers yet</h3><p>Open the App Store, or ask the AI: "set up a Minecraft server".</p></div>';
}

function meter(label, pct, text) {
  return `<div class="meter"><span>${label}</span><div class="track"><div class="fill" style="width:${Math.min(pct, 100)}%"></div></div><span>${text}</span></div>`;
}

function containerCard(c) {
  const run = c.state === 'running';
  const memPct = c.memLimitMb ? (c.memMb / c.memLimitMb) * 100 : 0;
  const ports = c.ports
    .map((p) => {
      const host = p.split('->')[0];
      return p.endsWith('/tcp') ? `<button class="port" data-open="${host}">:${esc(p)}</button>` : `<span class="port">:${esc(p)}</span>`;
    })
    .join('');
  return `<div class="card ct" data-id="${esc(c.id)}" data-name="${esc(c.name)}">
    <div class="ct-h"><i class="led ${run ? 'on' : c.state === 'restarting' ? 'warn' : 'off'}"></i><b title="${esc(c.name)}">${esc(c.name)}</b><span class="state ${esc(c.state)}">${esc(c.state)}</span></div>
    <div class="ct-img">${esc(c.image)} · ${esc(c.status)}</div>
    ${run ? meter('CPU', c.cpu || 0, `${c.cpu ?? 0}%`) + meter('RAM', memPct, `${c.memMb ?? 0} MB`) : ''}
    <div class="ports">${ports}</div>
    <div class="ct-actions">
      ${run ? '<button class="ghost sm" data-act="restart">Restart</button><button class="ghost sm" data-act="stop">Stop</button>' : '<button class="primary sm" data-act="start">Start</button>'}
      <button class="ghost sm" data-act="logs">Logs</button>
      <button class="ghost sm" data-act="ask">✦ Ask AI</button>
      <button class="danger sm" data-act="remove">Remove</button>
    </div>
  </div>`;
}

// ---------------------------------------------------------------- server engine
let engineState = { phase: 'checking' };
let engineLog = '';

function renderEngine() {
  const st = engineState;
  const card = $('#engineCard');
  const working = ['checking', 'starting', 'installing'].includes(st.phase);
  card.classList.toggle('working', working);
  $('#engineProgress').hidden = !working;
  $('#engineLog').textContent = st.phase === 'installing' ? engineLog : '';
  const btn = (label, action, cls = 'primary') => `<button class="${cls}" data-engine-act="${action}">${label}</button>`;
  let title = 'Server engine';
  let text = '';
  let actions = '';
  switch (st.phase) {
    case 'checking':
    case 'starting':
      title = 'Starting your server engine…';
      text = 'Waking up Forge\'s built-in Docker engine. This takes a few seconds.';
      break;
    case 'needs-setup':
      title = 'Set up your server engine';
      text = `Forge has a <b>built-in server engine</b> that runs Minecraft, Jellyfin and every other app in the App Store. It's a one-time setup of about 2 minutes, and you don't need to install anything else.${
        st.wsl === false ? '<br><br>Windows will ask for <b>admin permission</b> to turn on its built-in Linux support (WSL), and may need <b>one restart</b>.' : ''
      }`;
      actions = btn('⚡ Set up server engine', 'setup');
      break;
    case 'installing':
      title = 'Setting up your server engine…';
      text = esc(st.step || 'Working…');
      break;
    case 'needs-reboot':
      title = 'Restart to finish setup';
      text = 'Windows turned on its Linux support. It needs <b>one restart</b> to finish. Open Forge again afterwards and setup continues automatically.';
      actions = btn('Restart now', 'reboot') + btn('Later', 'later', 'ghost');
      break;
    case 'stopped':
      title = 'Server engine stopped';
      text = 'Start it again to bring your servers back.';
      actions = btn('Start engine', 'start');
      break;
    case 'unsupported':
      title = 'Docker needed';
      text = 'On Mac and Linux, Forge uses Docker directly. Install <a href="https://docs.docker.com/engine/install/" target="_blank" rel="noreferrer">Docker</a>, start it, and this page comes alive.';
      actions = btn('Check again', 'start', 'ghost');
      break;
    case 'error':
      title = 'Something went wrong';
      text = esc(st.error || 'Unknown error');
      actions = btn('Try again', 'setup') + btn('Ask AI to help', 'ask', 'ghost');
      break;
    default:
      break;
  }
  $('#engineTitle').textContent = title;
  $('#engineText').innerHTML = text;
  $('#engineActions').innerHTML = actions;
}

$('#engineActions').addEventListener('click', async (e) => {
  const act = e.target.closest('[data-engine-act]')?.dataset.engineAct;
  if (!act) return;
  if (act === 'setup') forge.engine.setup().catch((err) => toast(err.message, true));
  if (act === 'start') forge.engine.detect().catch((err) => toast(err.message, true));
  if (act === 'later') toast('Restart whenever you are ready, then open Forge.');
  if (act === 'ask') sendPrompt(`Forge's server engine setup failed with: "${engineState.error}". Help me diagnose and fix it (check WSL with "wsl --status" and "wsl -l -v").`);
  if (act === 'reboot' && confirm('Restart your PC now? Save your work first.')) forge.engine.reboot();
});

forge.engine.onState((st) => {
  if (st.log) {
    engineLog = st.log;
    if (currentView === 'server') $('#engineLog').textContent = engineLog;
    return;
  }
  engineState = st;
  if (st.phase !== 'installing') engineLog = '';
  refreshDocker();
});

$('#containers').addEventListener('click', async (e) => {
  const card = e.target.closest('.ct');
  if (!card) return;
  const port = e.target.closest('[data-open]');
  if (port) return forge.openExternal(`http://localhost:${port.dataset.open}`);
  const btn = e.target.closest('[data-act]');
  if (!btn) return;
  const { id, name } = card.dataset;
  const act = btn.dataset.act;
  if (act === 'logs') return showLogs(id, name);
  if (act === 'ask') return sendPrompt(`Look at the container "${name}": check its logs and stats and tell me if anything is wrong.`);
  if (act === 'remove' && !confirm(`Remove ${name}? Its named volumes (data) are kept.`)) return;
  btn.disabled = true;
  btn.textContent = '…';
  try {
    await forge.docker.action(id, act);
    toast(`${name}: ${act} ok`);
  } catch (err) {
    toast(err.message, true);
  }
  refreshDocker();
});

async function showLogs(id, name) {
  const scrim = document.createElement('div');
  scrim.className = 'scrim';
  const box = document.createElement('div');
  box.className = 'card logs';
  box.innerHTML = `<header><h3>Logs · ${esc(name)}</h3><div class="row"><button class="ghost sm" data-ask="Read the logs of container '${esc(name)}' and explain any errors and how to fix them.">✦ Explain with AI</button><button class="ghost sm" data-close>Close</button></div></header><pre>Loading…</pre>`;
  const close = () => {
    scrim.remove();
    box.remove();
  };
  scrim.onclick = close;
  box.addEventListener('click', (e) => (e.target.closest('[data-close],[data-ask]') ? close() : null));
  document.body.append(scrim, box);
  try {
    const pre = $('pre', box);
    pre.textContent = (await forge.docker.logs(id)) || '(no output)';
    pre.scrollTop = pre.scrollHeight;
  } catch (e) {
    $('pre', box).textContent = e.message;
  }
}

// ---------------------------------------------------------------- store
async function renderStore() {
  const apps = await forge.docker.catalog();
  $('#store').innerHTML = apps
    .map(
      (a) => `<div class="card app-card" data-app="${a.id}">
        <div class="app-ico">${a.icon}</div>
        <b>${esc(a.name)}</b>
        <p>${esc(a.tagline)}</p>
        <div class="img">${esc(a.image)} · port ${Object.keys(a.ports)[0]}</div>
        <div class="progress"></div>
        <div class="row"><button class="primary sm" data-install>Install</button><button class="ghost sm" data-ask="Help me set up ${esc(a.name)}: install it with sensible settings for my machine and tell me how to use it.">✦ Set up with AI</button></div>
      </div>`,
    )
    .join('');
}

$('#store').addEventListener('click', async (e) => {
  const btn = e.target.closest('[data-install]');
  if (!btn) return;
  const card = btn.closest('.app-card');
  if (dockerOk === false) {
    show('server');
    return toast('Set up the server engine first. It only takes a minute.', true);
  }
  btn.disabled = true;
  btn.textContent = 'Installing…';
  try {
    const r = await forge.docker.install(card.dataset.app, {});
    $('.progress', card).textContent = r.url ? `Running → ${r.url}` : 'Running';
    btn.textContent = 'Installed ✓';
    toast(`${r.name} is running`);
  } catch (err) {
    $('.progress', card).textContent = '';
    btn.disabled = false;
    btn.textContent = 'Install';
    toast(err.message, true);
  }
});

forge.docker.onProgress((p) => {
  const el = $(`.app-card[data-app="${p.appId}"] .progress`);
  if (el) el.textContent = p.text;
});

// ---------------------------------------------------------------- terminal
const terms = new Map();
let activeTerm = null;
const TERM_THEME = {
  background: '#00000000',
  foreground: '#dfe3f1',
  cursor: '#22e4ff',
  cursorAccent: '#07080d',
  selectionBackground: 'rgba(34,228,255,0.3)',
  black: '#1b1e2e', red: '#ff4d6d', green: '#34f5a4', yellow: '#fbbf24', blue: '#60a5fa', magenta: '#c084fc', cyan: '#22e4ff', white: '#dfe3f1',
  brightBlack: '#5b6079', brightRed: '#ff7a93', brightGreen: '#6dffc0', brightYellow: '#fcd34d', brightBlue: '#93c5fd', brightMagenta: '#d8b4fe', brightCyan: '#7af0ff', brightWhite: '#ffffff',
};

async function newTerminal() {
  const host = document.createElement('div');
  $('#termHost').append(host);
  const term = new Terminal({
    fontFamily: getComputedStyle(document.body).getPropertyValue('--mono'),
    fontSize: 13,
    lineHeight: 1.25,
    cursorBlink: true,
    allowTransparency: true,
    theme: TERM_THEME,
    scrollback: 5000,
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  host.classList.add('active');
  term.open(host);
  fit.fit();
  const id = await forge.pty.create(term.cols, term.rows);
  term.onData((d) => forge.pty.write(id, d));
  term.onResize(({ cols, rows }) => forge.pty.resize(id, cols, rows));

  const tab = document.createElement('button');
  tab.className = 'tab';
  tab.innerHTML = `<span>shell ${id}</span><span class="x" title="Close">×</span>`;
  tab.onclick = (e) => (e.target.classList.contains('x') ? closeTerminal(id) : focusTerminal(id));
  $('#termTabs').insertBefore(tab, $('#newTerm'));
  terms.set(id, { term, fit, host, tab });
  focusTerminal(id);
}

function focusTerminal(id) {
  activeTerm = id;
  for (const [tid, t] of terms) {
    t.host.classList.toggle('active', tid === id);
    t.tab.classList.toggle('active', tid === id);
  }
  const t = terms.get(id);
  if (t) {
    requestAnimationFrame(() => {
      t.fit.fit();
      t.term.focus();
    });
  }
}

function closeTerminal(id) {
  const t = terms.get(id);
  if (!t) return;
  forge.pty.kill(id);
  t.term.dispose();
  t.host.remove();
  t.tab.remove();
  terms.delete(id);
  if (activeTerm === id) {
    const next = [...terms.keys()].pop();
    if (next) focusTerminal(next);
  }
}

function ensureTerminal() {
  if (terms.size === 0) newTerminal().catch((e) => toast(`Terminal failed: ${e.message}`, true));
  else focusTerminal(activeTerm);
}

forge.pty.onData(({ id, data }) => terms.get(id)?.term.write(data));
forge.pty.onExit(({ id }) => closeTerminal(id));
$('#newTerm').onclick = () => newTerminal();
new ResizeObserver(() => activeTerm && currentView === 'terminal' && terms.get(activeTerm)?.fit.fit()).observe($('#termHost'));

// ---------------------------------------------------------------- settings
let selectedEngine = null;

function selectEngine(engine) {
  selectedEngine = engine;
  $$('.engine').forEach((b) => b.classList.toggle('active', b.dataset.engine === engine));
  $$('.form[data-for]').forEach((f) => f.classList.toggle('show', f.dataset.for === engine));
}

function keyState(el, has) {
  el.textContent = has ? '● saved' : '○ not set';
  el.classList.toggle('ok', has);
}

function updateEngineLabels() {
  const p = settings.provider;
  let detail = '';
  if (p === 'claude') detail = settings.claudeModel;
  if (p === 'free') detail = `${settings.freePresets[settings.freePreset]?.label} · ${settings.freeModel || 'auto model'}`;
  if (p === 'ollama') detail = settings.ollamaModel;
  $('#engineLabel').textContent = `${ENGINE_NAMES[p]} · ${detail}`;
  $('#engineChip span').textContent = ENGINE_NAMES[p];
  const ready = p === 'ollama' || settings.hasKey[p === 'claude' ? 'claude' : settings.freePreset];
  $('#engineChip .led').className = `led ${ready ? 'on' : 'warn'}`;
}

async function loadSettingsForm() {
  settings = await forge.settings.get();
  selectEngine(settings.provider);
  const sel = $('#freePreset');
  sel.innerHTML = Object.entries(settings.freePresets).map(([k, v]) => `<option value="${k}">${esc(v.label)}</option>`).join('');
  sel.value = settings.freePreset;
  setModelOptions([], settings.freeModel);
  keyState($('#freeKeyState'), settings.hasKey[settings.freePreset]);
  $('#testResult').textContent = '';
  if (settings.hasKey[settings.freePreset]) loadFreeModels();
  $('#claudeModel').value = settings.claudeModel;
  keyState($('#claudeKeyState'), settings.hasKey.claude);
  $('#ollamaUrl').value = settings.ollamaUrl;
  $('#ollamaModel').value = settings.ollamaModel;
  $('#autoApprove').checked = settings.autoApproveReadOnly;
  $('#freeKey').value = '';
  $('#claudeKey').value = '';
  const o = await forge.ollama.models().catch(() => ({ running: false, models: [] }));
  $('#ollamaModels').innerHTML = o.models.map((m) => `<option value="${esc(m)}">`).join('');
  $('#ollamaState').textContent = o.running ? `● running · ${o.models.length} model(s) installed` : '○ Ollama not detected';
  $('#ollamaState').classList.toggle('ok', o.running);
}

$('#engines').addEventListener('click', (e) => {
  const b = e.target.closest('.engine');
  if (b) selectEngine(b.dataset.engine);
});
// Unsaved form values, so models can be listed and tested before pressing Save.
function freeForm() {
  return { freePreset: $('#freePreset').value, freeModel: $('#freeModel').value, apiKey: $('#freeKey').value.trim() || undefined };
}

function setModelOptions(models, selected) {
  const sel = $('#freeModel');
  const list = selected && !models.includes(selected) ? [selected, ...models] : models;
  sel.innerHTML =
    '<option value="">Auto: best available model</option>' +
    list.map((m) => `<option value="${esc(m)}">${esc(m)}${m === models[0] ? '  ★ recommended' : ''}</option>`).join('');
  sel.value = selected || '';
}

async function loadFreeModels() {
  const state = $('#freeModelState');
  const keep = $('#freeModel').value;
  state.className = 'keystate';
  state.textContent = 'loading…';
  try {
    const models = await forge.ai.models(freeForm());
    setModelOptions(models, keep);
    state.textContent = `● ${models.length} chat models with tool support`;
    state.classList.add('ok');
    if (keep && !models.includes(keep)) {
      state.textContent = `⚠ "${keep}" isn't available any more. Choose another, or use Auto.`;
      state.className = 'keystate';
    }
  } catch (e) {
    state.textContent = `○ ${e.message}`;
  }
}

$('#freePreset').onchange = (e) => {
  keyState($('#freeKeyState'), settings.hasKey[e.target.value]);
  setModelOptions([], '');
  $('#freeModelState').textContent = '';
  $('#testResult').textContent = '';
  if (settings.hasKey[e.target.value]) loadFreeModels();
};
$('#loadModels').onclick = (e) => {
  e.preventDefault();
  loadFreeModels();
};
$('#testFree').onclick = async (e) => {
  e.preventDefault();
  const out = $('#testResult');
  out.className = 'test-result';
  out.textContent = 'Testing…';
  try {
    const r = await forge.ai.test(freeForm());
    setModelOptions(r.models, $('#freeModel').value);
    out.textContent = `✓ Works! ${r.model} answered with tools enabled. Press Save.`;
    out.classList.add('ok');
  } catch (err) {
    out.textContent = `✗ ${err.message}`;
    out.classList.add('err');
  }
};
$('#getFreeKey').onclick = () => forge.openExternal(settings.freePresets[$('#freePreset').value].keyUrl);
$('#getClaudeKey').onclick = () => forge.openExternal('https://console.anthropic.com/settings/keys');

$('#saveSettings').onclick = async () => {
  const keys = {};
  if ($('#freeKey').value.trim()) keys[$('#freePreset').value] = $('#freeKey').value.trim();
  if ($('#claudeKey').value.trim()) keys.claude = $('#claudeKey').value.trim();
  const changedEngine = selectedEngine !== settings.provider;
  settings = await forge.settings.update({
    provider: selectedEngine,
    freePreset: $('#freePreset').value,
    freeModel: $('#freeModel').value,
    claudeModel: $('#claudeModel').value,
    ollamaUrl: $('#ollamaUrl').value.trim(),
    ollamaModel: $('#ollamaModel').value.trim(),
    autoApproveReadOnly: $('#autoApprove').checked,
    keys,
  });
  if (changedEngine) resetChat();
  await loadSettingsForm();
  updateEngineLabels();
  $('#savedMsg').textContent = '✓ Saved';
  setTimeout(() => ($('#savedMsg').textContent = ''), 2000);
};

// ---------------------------------------------------------------- agent chat
const msgs = $('#messages');
let busy = false;
let aiEl = null; // current streaming text element
let aiText = '';
let thinkEl = null;
let renderQueued = false;
const toolCards = new Map();

function scrollDown() {
  const nearBottom = msgs.scrollHeight - msgs.scrollTop - msgs.clientHeight < 160;
  if (nearBottom) msgs.scrollTop = msgs.scrollHeight;
}

function append(el) {
  $('#welcome')?.remove();
  msgs.append(el);
  msgs.scrollTop = msgs.scrollHeight;
  return el;
}

function setBusy(b) {
  busy = b;
  $('#orb').classList.toggle('busy', b);
  const s = $('#sendBtn');
  s.classList.toggle('stop', b);
  s.title = b ? 'Stop' : 'Send';
  s.innerHTML = b ? '<svg viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="2"/></svg>' : '<svg viewBox="0 0 24 24"><path d="M4 12 20 4l-6 16-2.5-6.5z"/></svg>';
}

function endStreamingText() {
  if (aiEl) {
    aiEl.classList.remove('caret');
    aiEl.innerHTML = md.render(aiText);
  }
  aiEl = null;
  aiText = '';
}

function endThinking() {
  if (thinkEl) thinkEl.classList.remove('live');
  thinkEl = null;
}

function queueRender() {
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(() => {
    renderQueued = false;
    if (aiEl) {
      aiEl.innerHTML = md.render(aiText);
      scrollDown();
    }
  });
}

const TOOL_ICONS = { run_command: '›_', system_stats: '◔', list_containers: '▤', container_logs: '≣', container_action: '⏻', install_app: '⬇', read_file: '⎘' };

function toolCard(evt) {
  const el = document.createElement('div');
  el.className = `tool ${evt.needsApproval ? 'pending' : 'running'}`;
  el.innerHTML = `
    <div class="tool-h"><span class="ic">${TOOL_ICONS[evt.tool] || '⚙'}</span><b>${esc(evt.title)}</b><span class="st">${evt.needsApproval ? 'needs approval' : 'running'}</span></div>
    ${evt.reason ? `<div class="tool-reason">${esc(evt.reason)}</div>` : ''}
    ${evt.detail ? `<div class="tool-detail${evt.code ? ' cmd' : ''}">${esc(evt.detail)}</div>` : ''}
    <div class="tool-progress" hidden></div>
    ${evt.needsApproval ? '<div class="tool-actions"><button class="primary sm" data-approve>Approve</button><button class="ghost sm" data-deny>Deny</button></div>' : ''}`;
  el.addEventListener('click', (e) => {
    if (e.target.closest('[data-approve]')) forge.agent.approve(evt.id, true);
    if (e.target.closest('[data-deny]')) forge.agent.approve(evt.id, false);
  });
  return el;
}

forge.agent.onEvent((evt) => {
  switch (evt.type) {
    case 'start':
      setBusy(true);
      break;
    case 'thinking':
      if (!thinkEl) {
        endStreamingText();
        thinkEl = append(document.createElement('details'));
        thinkEl.className = 'thinking live';
        thinkEl.innerHTML = '<summary>Thinking</summary><div></div>';
      }
      $('div', thinkEl).textContent += evt.delta;
      break;
    case 'text':
      endThinking();
      if (!aiEl) {
        aiEl = append(document.createElement('div'));
        aiEl.className = 'msg ai caret';
      }
      aiText += evt.delta;
      queueRender();
      break;
    case 'tool-call': {
      endThinking();
      endStreamingText();
      const card = append(toolCard(evt));
      toolCards.set(evt.id, card);
      if (evt.needsApproval) $('[data-approve]', card).focus();
      break;
    }
    case 'tool-approval': {
      const card = toolCards.get(evt.id);
      if (!card) break;
      $('.tool-actions', card)?.remove();
      card.classList.remove('pending');
      card.classList.add(evt.approved ? 'running' : 'err');
      $('.st', card).textContent = evt.approved ? 'running' : 'denied';
      break;
    }
    case 'tool-progress': {
      const p = $('.tool-progress', toolCards.get(evt.id) || document.createElement('div'));
      if (p) {
        p.hidden = false;
        p.textContent = evt.text;
      }
      break;
    }
    case 'tool-result': {
      const card = toolCards.get(evt.id);
      if (!card) break;
      $('.tool-progress', card).hidden = true;
      if (!card.classList.contains('err')) {
        card.classList.remove('running');
        card.classList.add(evt.isError ? 'err' : 'ok');
        $('.st', card).textContent = evt.isError ? 'failed' : 'done';
      }
      const out = document.createElement('details');
      out.className = 'tool-out';
      out.innerHTML = `<summary>Output · ${evt.content.length.toLocaleString()} chars</summary><pre></pre>`;
      $('pre', out).textContent = evt.content;
      card.append(out);
      scrollDown();
      break;
    }
    case 'retract':
      // a failed attempt is being retried: drop its partial output
      if (aiEl) aiEl.remove();
      aiEl = null;
      aiText = '';
      if (thinkEl) thinkEl.remove();
      thinkEl = null;
      break;
    case 'model-changed':
      settings.freeModel = evt.model;
      updateEngineLabels();
      break;
    case 'notice':
      endStreamingText();
      append(Object.assign(document.createElement('div'), { className: 'notice', textContent: evt.text }));
      break;
    case 'error': {
      endThinking();
      endStreamingText();
      const n = append(document.createElement('div'));
      n.className = 'notice error';
      n.innerHTML = `${esc(evt.text)}<br><button class="ghost sm" data-goto="settings">Open settings</button>`;
      break;
    }
    case 'done':
      endThinking();
      endStreamingText();
      setBusy(false);
      if (currentView === 'server' || currentView === 'dashboard') refreshDocker();
      break;
  }
});

async function sendPrompt(text) {
  text = text.trim();
  if (!text || busy) return;
  append(Object.assign(document.createElement('div'), { className: 'msg user', textContent: text }));
  setBusy(true);
  try {
    await forge.agent.send(text);
  } catch (e) {
    setBusy(false);
    toast(e.message, true);
  }
}

const prompt = $('#prompt');
prompt.addEventListener('input', () => {
  prompt.style.height = 'auto';
  prompt.style.height = `${Math.min(prompt.scrollHeight, 160)}px`;
});
prompt.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    $('#composer').requestSubmit();
  }
});
$('#composer').addEventListener('submit', (e) => {
  e.preventDefault();
  if (busy) return forge.agent.stop();
  const t = prompt.value;
  prompt.value = '';
  prompt.style.height = 'auto';
  sendPrompt(t);
});

function resetChat() {
  forge.agent.reset();
  toolCards.clear();
  aiEl = null;
  aiText = '';
  thinkEl = null;
  msgs.innerHTML = '';
  msgs.append(welcomeTemplate.cloneNode(true));
  setBusy(false);
}
const welcomeTemplate = $('#welcome').cloneNode(true);
$('#resetChat').onclick = resetChat;

// ---------------------------------------------------------------- boot
(async function boot() {
  document.body.classList.add(`platform-${forge.platform}`);
  settings = await forge.settings.get();
  engineState = await forge.engine.state();
  updateEngineLabels();
  renderStore();
  tickStats();
  tickProcs();
  refreshDocker();
  setInterval(tickStats, 1500);
  setInterval(tickProcs, 4000);
  setInterval(refreshDocker, 4000);
  prompt.focus();
})();
