'use strict';
// Built-in server engine: detection and one-time setup, against a simulated Windows.
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { EventEmitter } = require('events');
const { Engine, parseAlpineIndex, cleanWslOutput, DISTRO } = require('../src/main/engine');

const TAR = Buffer.from('fake-rootfs');
const SHA = crypto.createHash('sha256').update(TAR).digest('hex');
const INDEX = `---
-
  title: "Standard"
  flavor: alpine-standard
  file: alpine-standard-3.22.1-x86_64.iso
  sha256: aaa
-
  title: "Mini root filesystem"
  desc: "Minimal root filesystem."
  flavor: alpine-minirootfs
  version: 3.22.1
  file: alpine-minirootfs-3.22.1-x86_64.tar.gz
  sha256: ${SHA}
`;

function sim({ wsl = true, distro = false, desktop = false, afterElevate = true, importErr = null, tarBody = TAR } = {}) {
  const w = { wsl, distro, desktop, engineUp: false, mode: 'default', calls: [], elevated: [], spawned: [] };
  const docker = {
    useDefault: () => (w.mode = 'default'),
    useEngine: () => (w.mode = 'engine'),
    status: async () => ({ available: w.mode === 'default' ? w.desktop : w.engineUp }),
  };
  const runner = async (cmd, args) => {
    w.calls.push([cmd, ...args].join(' '));
    if (args[0] === '--status') return { code: w.wsl ? 0 : 1, out: '', err: '' };
    if (args[0] === '--list') return { code: 0, out: w.distro ? `Ubuntu\n${DISTRO}\n` : 'Ubuntu\n', err: '' };
    if (args[0] === '--import') {
      if (importErr) return { code: 1, out: '', err: importErr };
      w.distro = true;
      return { code: 0, out: '', err: '' };
    }
    return { code: 0, out: 'OK', err: '' };
  };
  const elevated = async (file, args) => {
    w.elevated.push([file, ...args].join(' '));
    w.wsl = afterElevate;
    return { code: 0 };
  };
  const spawner = (cmd, args) => {
    w.spawned.push([cmd, ...args].join(' '));
    w.engineUp = true;
    const child = new EventEmitter();
    child.kill = () => child.emit('exit', 0);
    return child;
  };
  const fetcher = async (url) => ({
    ok: true,
    status: 200,
    text: async () => INDEX,
    arrayBuffer: async () => tarBody,
    url,
  });
  const states = [];
  const engine = new Engine({
    dataDir: fs.mkdtempSync(path.join(os.tmpdir(), 'forge-engine-')),
    docker, runner, elevated, spawner, fetcher, platform: 'win32',
    emit: (s) => !s.log && states.push(s.phase),
  });
  return { w, engine, states };
}

test('wsl output decoding and Alpine index parsing', () => {
  assert.strictEqual(cleanWslOutput('f\u0000o\u0000r\u0000g\u0000e\u0000\r\n'), 'forge\n');
  assert.deepStrictEqual(parseAlpineIndex(INDEX), { file: 'alpine-minirootfs-3.22.1-x86_64.tar.gz', sha256: SHA, version: '3.22.1' });
  assert.strictEqual(parseAlpineIndex('nothing here'), null);
});

test('uses Docker Desktop when it is already running', async () => {
  const { engine } = sim({ desktop: true });
  const st = await engine.detect();
  assert.deepStrictEqual(st, { phase: 'ready', via: 'Docker Desktop' });
});

test('fresh Windows: asks for setup, then enables WSL, builds the distro and starts the engine', async () => {
  const { w, engine, states } = sim({ wsl: false });
  assert.deepStrictEqual(await engine.detect(), { phase: 'needs-setup', wsl: false });
  const st = await engine.setup();
  assert.deepStrictEqual(st, { phase: 'ready', via: 'Forge engine' });
  assert.match(w.elevated[0], /wsl\.exe --install --no-distribution/);
  assert.ok(w.calls.some((c) => c.startsWith(`wsl.exe --import ${DISTRO}`) && c.endsWith('--version 2')));
  assert.ok(w.calls.some((c) => c.includes('apk add --no-cache docker')));
  assert.match(w.spawned[0], /dockerd .*--host=tcp:\/\/127\.0\.0\.1:23750 --tls=false/);
  assert.ok(states.includes('installing') && states.at(-1) === 'ready');
  assert.strictEqual(engine.ownsEngine, true);
  await engine.stop();
  assert.ok(w.calls.at(-1) === `wsl.exe --terminate ${DISTRO}`);
});

test('already set up: detect just starts the engine', async () => {
  const { w, engine } = sim({ distro: true });
  assert.deepStrictEqual(await engine.detect(), { phase: 'ready', via: 'Forge engine' });
  assert.strictEqual(w.elevated.length, 0);
  assert.ok(!w.calls.some((c) => c.includes('--import')));
});

test('asks for a restart when WSL needs one', async () => {
  const a = sim({ wsl: false, afterElevate: false });
  assert.deepStrictEqual(await a.engine.setup(), { phase: 'needs-reboot' });
  const b = sim({ importErr: 'Please enable the Virtual Machine Platform Windows feature and ensure virtualization is enabled in the BIOS. Error code: Wsl/Service/CreateInstance/0x80370102' });
  assert.deepStrictEqual(await b.engine.setup(), { phase: 'needs-reboot' });
});

test('a corrupted download is rejected', async () => {
  const { engine } = sim({ tarBody: Buffer.from('tampered') });
  const st = await engine.setup();
  assert.strictEqual(st.phase, 'error');
  assert.match(st.error, /checksum/);
});

test('Docker Desktop is never stopped by Forge', async () => {
  const { w, engine } = sim({ desktop: true });
  await engine.detect();
  await engine.stop();
  assert.ok(!w.calls.some((c) => c.includes('--terminate')));
});
