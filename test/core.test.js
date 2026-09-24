'use strict';
const test = require('node:test');
const assert = require('node:assert');
const os = require('os');
const fs = require('fs');
const path = require('path');

const { createSseParser, createThinkSplitter, mergeToolCallDelta } = require('../src/main/agent/openai-compat');
const { executeTool, anthropicTools, openAiTools, TOOLS } = require('../src/main/agent/tools');
const { buildContainerConfig, getApp, CATALOG } = require('../src/main/catalog');
const { Settings } = require('../src/main/settings');
const { demux } = require('../src/main/docker');
const md = require('../src/renderer/markdown');

test('SSE parser handles split chunks, [DONE] and junk', () => {
  const got = [];
  const feed = createSseParser((j) => got.push(j));
  feed('data: {"a":1}\n\nda');
  feed('ta: {"b":2}\n: keep-alive\ndata: [DONE]\n');
  assert.deepStrictEqual(got, [{ a: 1 }, { b: 2 }]);
});

test('think splitter routes <think> spans, even across chunk boundaries', () => {
  let text = '';
  let think = '';
  const split = createThinkSplitter((t) => (text += t), (t) => (think += t));
  for (const c of ['Hi <thi', 'nk>plan it</th', 'ink> done <', '3']) split(c);
  assert.strictEqual(text, 'Hi  done <3');
  assert.strictEqual(think, 'plan it');
});

test('tool call deltas merge by index; object arguments are stringified', () => {
  let calls = [];
  calls = mergeToolCallDelta(calls, [{ index: 0, id: 'c1', function: { name: 'run_', arguments: '{"comm' } }]);
  calls = mergeToolCallDelta(calls, [{ index: 0, function: { name: 'command', arguments: 'and":"ls"}' } }]);
  calls = mergeToolCallDelta(calls, [{ id: 'c2', function: { name: 'system_stats', arguments: {} } }]);
  assert.deepStrictEqual(calls[0], { id: 'c1', name: 'run_command', arguments: '{"command":"ls"}' });
  assert.deepStrictEqual(calls[1], { id: 'c2', name: 'system_stats', arguments: '{}' });
});

function ctx(approveAnswer) {
  const log = { approvals: [], notes: [] };
  return {
    log,
    signal: new AbortController().signal,
    autoApproveReadOnly: true,
    approve: async (info) => (log.approvals.push(info), approveAnswer),
    notify: (info) => log.notes.push(info),
    progress: () => {},
  };
}

test('mutating tools require approval and a denial never runs the command', async () => {
  const marker = path.join(os.tmpdir(), `forge-test-${process.pid}`);
  const c = ctx(false);
  const r = await executeTool('run_command', { command: `touch ${marker}`, reason: 't' }, c);
  assert.strictEqual(r.isError, true);
  assert.strictEqual(c.log.approvals.length, 1);
  assert.strictEqual(fs.existsSync(marker), false);
});

test('approved commands run and report exit code', async () => {
  const c = ctx(true);
  const r = await executeTool('run_command', { command: 'echo forge-ok', reason: 't' }, c);
  assert.strictEqual(r.isError, false);
  assert.match(r.content, /exit code: 0/);
  assert.match(r.content, /forge-ok/);
});

test('invalid tool input is rejected before approval', async () => {
  const c = ctx(true);
  const r = await executeTool('container_action', { container: 'x', action: 'nuke' }, c);
  assert.strictEqual(r.isError, true);
  assert.strictEqual(c.log.approvals.length, 0);
  assert.strictEqual((await executeTool('nope', {}, c)).isError, true);
});

test('read-only tools skip approval when auto-approve is on', async () => {
  const c = ctx(false);
  const r = await executeTool('system_stats', {}, c);
  assert.strictEqual(r.isError, false);
  assert.strictEqual(c.log.approvals.length, 0);
  assert.ok(JSON.parse(r.content).memTotal > 0);
});

test('tool schemas convert to both API formats', () => {
  assert.strictEqual(anthropicTools().length, TOOLS.length);
  for (const t of anthropicTools()) assert.ok(t.input_schema.type === 'object' && t.eager_input_streaming);
  for (const t of openAiTools()) assert.ok(t.type === 'function' && t.function.parameters);
});

test('catalog builds docker configs with ports, volumes, env and memory', () => {
  const cfg = buildContainerConfig(getApp('minecraft'), { env: { MEMORY: '4G' }, memoryMb: 5120 });
  assert.strictEqual(cfg.name, 'forge-minecraft');
  assert.ok(cfg.Env.includes('MEMORY=4G') && cfg.Env.includes('EULA=TRUE'));
  assert.deepStrictEqual(cfg.HostConfig.PortBindings['25565/tcp'], [{ HostPort: '25565' }]);
  assert.strictEqual(cfg.HostConfig.Memory, 5120 * 1024 * 1024);
  assert.deepStrictEqual(cfg.HostConfig.Binds, ['forge-minecraft-data:/data']);
  const pihole = buildContainerConfig(getApp('pihole'));
  assert.deepStrictEqual(pihole.HostConfig.PortBindings['53/udp'], [{ HostPort: '53' }]);
  assert.deepStrictEqual(pihole.HostConfig.PortBindings['80/tcp'], [{ HostPort: '8053' }]);
  assert.strictEqual(new Set(CATALOG.map((a) => a.id)).size, CATALOG.length);
});

test('settings encrypt keys and never expose them publicly', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'forge-settings-'));
  const fakeSafe = {
    isEncryptionAvailable: () => true,
    encryptString: (s) => Buffer.from(s.split('').reverse().join('')),
    decryptString: (b) => b.toString().split('').reverse().join(''),
  };
  const s = new Settings(dir, fakeSafe);
  s.update({ provider: 'free', keys: { groq: 'gsk_secret123' } });
  const raw = fs.readFileSync(path.join(dir, 'settings.json'), 'utf8');
  assert.ok(!raw.includes('gsk_secret123'));
  const again = new Settings(dir, fakeSafe);
  assert.strictEqual(again.freeConfig().apiKey, 'gsk_secret123');
  const pub = JSON.stringify(again.public());
  assert.ok(!pub.includes('secret'));
  assert.strictEqual(again.public().hasKey.groq, true);
  assert.throws(() => again.setSecret('bogus', 'x'));
});

test('docker log demux strips frame headers', () => {
  const frame = (type, s) => Buffer.concat([Buffer.from([type, 0, 0, 0, 0, 0, 0, s.length]), Buffer.from(s)]);
  assert.strictEqual(demux(Buffer.concat([frame(1, 'out\n'), frame(2, 'err\n')])), 'out\nerr\n');
  assert.strictEqual(demux(Buffer.from('plain tty log')), 'plain tty log');
});

test('markdown renderer escapes HTML and renders code, lists and links', () => {
  const html = md.render('Hi **there** <img src=x onerror=alert(1)>\n- a `b`\n```sh\nrm -rf <x>\n```\nsee https://x.io');
  assert.ok(!html.includes('<img'));
  assert.ok(html.includes('&lt;img'));
  assert.ok(html.includes('<strong>there</strong>'));
  assert.ok(html.includes('<li>a <code>b</code></li>'));
  assert.ok(html.includes('data-lang="sh"') && html.includes('rm -rf &lt;x&gt;'));
  assert.ok(html.includes('<a href="https://x.io"'));
  assert.ok(!md.render('[x](javascript:alert(1))').includes('href'));
});
