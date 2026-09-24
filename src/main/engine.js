'use strict';
// Forge's built-in server engine. On Windows, Forge runs its own Docker Engine inside a
// private WSL2 distro ("forge-engine", Alpine Linux), so nobody has to install Docker Desktop.
// If Docker Desktop (or a native Docker on Mac/Linux) is already running, Forge uses that.
const { execFile, spawn } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const DISTRO = 'forge-engine';
const PORT = 23750; // dockerd listens on 127.0.0.1 inside WSL; WSL forwards it to Windows localhost
const ALPINE_INDEX = 'https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml';
const ALPINE_FALLBACK = 'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.3-x86_64.tar.gz';

// wsl.exe prints UTF-16LE unless WSL_UTF8 is set; strip NULs either way.
function cleanWslOutput(buf) {
  return String(buf || '').replace(/\u0000/g, '').replace(/\r/g, '');
}

function run(cmd, args, { timeout = 120000, onLine } = {}) {
  return new Promise((resolve) => {
    const child = execFile(cmd, args, { timeout, windowsHide: true, env: { ...process.env, WSL_UTF8: '1' }, maxBuffer: 32 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ code: err ? (typeof err.code === 'number' ? err.code : -1) : 0, out: cleanWslOutput(stdout), err: cleanWslOutput(stderr), missing: err?.code === 'ENOENT' });
    });
    if (onLine) {
      const emit = (d) => cleanWslOutput(d).split('\n').filter((l) => l.trim()).forEach((l) => onLine(l.trim()));
      child.stdout.on('data', emit);
      child.stderr.on('data', emit);
    }
  });
}

// Picks the mini root filesystem entry out of Alpine's latest-releases.yaml.
function parseAlpineIndex(yaml) {
  for (const block of yaml.split(/\n-\s*\n/)) {
    const get = (k) => block.match(new RegExp(`^\\s*${k}:\\s*"?([^"\\n]+)"?\\s*$`, 'm'))?.[1];
    if (get('flavor') === 'alpine-minirootfs' && get('file')) {
      return { file: get('file'), sha256: get('sha256') || null, version: get('version') || '' };
    }
  }
  return null;
}

// Runs a command as administrator (UAC prompt) and waits for it.
function runElevated(file, args) {
  const quoted = args.map((a) => `'${a.replace(/'/g, "''")}'`).join(',');
  return run('powershell.exe', ['-NoProfile', '-Command', `$p = Start-Process -FilePath '${file}' -ArgumentList ${quoted} -Verb RunAs -Wait -PassThru; exit $p.ExitCode`], { timeout: 30 * 60000 });
}

class Engine {
  constructor({ dataDir, docker, runner = run, elevated = runElevated, spawner = spawn, fetcher = fetch, platform = process.platform, emit = () => {} }) {
    this.dataDir = path.join(dataDir, 'engine');
    this.docker = docker; // the docker module: useEngine / useDefault / status
    this.run = runner;
    this.elevated = elevated;
    this.spawn = spawner;
    this.fetch = fetcher;
    this.platform = platform;
    this.emit = emit;
    this.child = null;
    this.state = { phase: 'checking' };
    this.busy = null;
  }

  set(phase, extra = {}) {
    this.state = { phase, ...extra };
    this.emit(this.state);
    return this.state;
  }

  log(text) {
    this.emit({ ...this.state, log: text });
  }

  async wslReady() {
    const r = await this.run('wsl.exe', ['--status'], { timeout: 20000 });
    return !r.missing && r.code === 0;
  }

  async distroInstalled() {
    const r = await this.run('wsl.exe', ['--list', '--quiet'], { timeout: 20000 });
    return r.code === 0 && r.out.split('\n').map((l) => l.trim()).includes(DISTRO);
  }

  // Figures out what exists; starts the engine if it is installed but not running.
  async detect() {
    this.docker.useDefault();
    if ((await this.docker.status()).available) return this.set('ready', { via: this.platform === 'win32' ? 'Docker Desktop' : 'Docker' });
    if (this.platform !== 'win32') return this.set('unsupported');
    if (!(await this.wslReady())) return this.set('needs-setup', { wsl: false });
    if (!(await this.distroInstalled())) return this.set('needs-setup', { wsl: true });
    return this.start();
  }

  // One-time setup: enable WSL if needed, create the distro, install Docker Engine, start it.
  setup() {
    this.busy ??= this.#setup().finally(() => (this.busy = null));
    return this.busy;
  }

  async #setup() {
    try {
      if (!(await this.wslReady())) {
        this.set('installing', { step: 'Enabling Windows Subsystem for Linux (approve the admin prompt)…' });
        const r = await this.elevated('wsl.exe', ['--install', '--no-distribution']);
        if (r.code !== 0 && r.code !== 3010) {
          return this.set('error', { error: `WSL setup failed or was cancelled (code ${r.code}). Make sure virtualization is enabled in your BIOS, then try again.` });
        }
        if (!(await this.wslReady())) return this.set('needs-reboot');
      }

      if (!(await this.distroInstalled())) {
        fs.mkdirSync(this.dataDir, { recursive: true });
        const tar = path.join(this.dataDir, 'rootfs.tar.gz');
        await this.download(tar);
        this.set('installing', { step: 'Creating Forge\'s Linux environment…' });
        const imp = await this.run('wsl.exe', ['--import', DISTRO, path.join(this.dataDir, 'disk'), tar, '--version', '2'], { timeout: 10 * 60000 });
        fs.rmSync(tar, { force: true });
        if (imp.code !== 0) {
          const msg = `${imp.err} ${imp.out}`;
          // Freshly enabled virtualization features only work after a restart.
          if (/restart|reboot|0x80370102|0x8004032d|virtual machine platform/i.test(msg)) return this.set('needs-reboot');
          return this.set('error', { error: `Could not create the engine environment: ${msg.trim()}` });
        }
      }

      this.set('installing', { step: 'Installing Docker Engine (about 100 MB)…' });
      const apk = await this.run('wsl.exe', ['-d', DISTRO, '-u', 'root', '--', '/bin/sh', '-c', 'apk update && apk add --no-cache docker'], {
        timeout: 20 * 60000,
        onLine: (l) => this.log(l),
      });
      if (apk.code !== 0) return this.set('error', { error: `Installing Docker Engine failed: ${(apk.err || apk.out).split('\n').slice(-3).join(' ')}` });
      return this.start();
    } catch (e) {
      return this.set('error', { error: e.message });
    }
  }

  async download(dest) {
    this.set('installing', { step: 'Downloading Alpine Linux (3 MB)…' });
    let url = ALPINE_FALLBACK;
    let sha256 = null;
    try {
      const idx = await this.fetch(ALPINE_INDEX, { signal: AbortSignal.timeout(20000) });
      const entry = idx.ok ? parseAlpineIndex(await idx.text()) : null;
      if (entry) {
        url = ALPINE_INDEX.replace(/[^/]+$/, entry.file);
        sha256 = entry.sha256;
      }
    } catch {
      // index unreachable: use the pinned fallback release
    }
    const res = await this.fetch(url, { signal: AbortSignal.timeout(5 * 60000) });
    if (!res.ok) throw new Error(`Download failed (${res.status}) from ${url}`);
    const buf = Buffer.from(await res.arrayBuffer());
    if (sha256 && crypto.createHash('sha256').update(buf).digest('hex') !== sha256) {
      throw new Error('Downloaded Alpine image failed its checksum. Try again.');
    }
    fs.writeFileSync(dest, buf);
  }

  // Runs dockerd inside the distro as a child of Forge; WSL keeps the distro alive while it runs.
  async start() {
    if (this.platform !== 'win32') return this.detect();
    this.set('starting');
    this.docker.useEngine({ host: '127.0.0.1', port: PORT });
    if ((await this.docker.status()).available) return this.set('ready', { via: 'Forge engine' });

    if (!this.child) {
      const cmd = `mkdir -p /var/log && exec dockerd --host=unix:///var/run/docker.sock --host=tcp://127.0.0.1:${PORT} --tls=false >>/var/log/dockerd.log 2>&1`;
      this.child = this.spawn('wsl.exe', ['-d', DISTRO, '-u', 'root', '--', '/bin/sh', '-c', cmd], { windowsHide: true, stdio: 'ignore' });
      this.child.on('exit', () => {
        this.child = null;
        if (this.state.phase === 'ready') this.set('stopped');
      });
    }
    for (let i = 0; i < 60; i++) {
      await new Promise((r) => setTimeout(r, 1000));
      if ((await this.docker.status()).available) return this.set('ready', { via: 'Forge engine' });
      if (!this.child) break;
    }
    const logTail = await this.run('wsl.exe', ['-d', DISTRO, '-u', 'root', '--', 'tail', '-n', '5', '/var/log/dockerd.log']);
    return this.set('error', { error: `The engine didn't start. ${logTail.out.trim().split('\n').slice(-2).join(' ')}` });
  }

  get ownsEngine() {
    return this.child !== null;
  }

  // Stops Forge's engine (containers stop too; ones with a restart policy come back next launch).
  async stop() {
    if (this.platform !== 'win32' || this.state.via !== 'Forge engine') return;
    this.child?.kill();
    this.child = null;
    await this.run('wsl.exe', ['--terminate', DISTRO], { timeout: 20000 });
  }
}

module.exports = { Engine, parseAlpineIndex, cleanWslOutput, DISTRO, PORT };
