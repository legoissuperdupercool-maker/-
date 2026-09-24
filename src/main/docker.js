'use strict';
const Docker = require('dockerode');
const { CATALOG, getApp, buildContainerConfig } = require('./catalog');

const docker = new Docker(); // default socket: /var/run/docker.sock, or the named pipe on Windows

function cpuPercent(s) {
  const cpuDelta = s.cpu_stats.cpu_usage.total_usage - (s.precpu_stats.cpu_usage?.total_usage || 0);
  const sysDelta = (s.cpu_stats.system_cpu_usage || 0) - (s.precpu_stats.system_cpu_usage || 0);
  const cpus = s.cpu_stats.online_cpus || s.cpu_stats.cpu_usage.percpu_usage?.length || 1;
  return sysDelta > 0 && cpuDelta > 0 ? (cpuDelta / sysDelta) * cpus * 100 : 0;
}

async function status() {
  try {
    const v = await docker.version();
    return { available: true, version: v.Version, os: v.Os };
  } catch (e) {
    return { available: false, error: e.code === 'ENOENT' || e.code === 'ECONNREFUSED' ? 'Docker is not running' : e.message };
  }
}

async function listContainers({ withStats = false } = {}) {
  const list = await docker.listContainers({ all: true });
  return Promise.all(
    list.map(async (c) => {
      const item = {
        id: c.Id.slice(0, 12),
        name: c.Names[0]?.replace(/^\//, '') || c.Id.slice(0, 12),
        image: c.Image,
        state: c.State,
        status: c.Status,
        app: c.Labels?.['forge.app'] || null,
        ports: (c.Ports || [])
          .filter((p) => p.PublicPort)
          .map((p) => `${p.PublicPort}->${p.PrivatePort}/${p.Type}`)
          .filter((v, i, a) => a.indexOf(v) === i),
      };
      if (withStats && c.State === 'running') {
        try {
          const s = await docker.getContainer(c.Id).stats({ stream: false });
          item.cpu = +cpuPercent(s).toFixed(1);
          item.memMb = Math.round((s.memory_stats.usage || 0) / 1048576);
          item.memLimitMb = Math.round((s.memory_stats.limit || 0) / 1048576);
        } catch {
          // container stopped between list and stats
        }
      }
      return item;
    }),
  );
}

async function logs(id, tail = 200) {
  const buf = await docker.getContainer(id).logs({ stdout: true, stderr: true, tail, timestamps: false });
  return demux(buf);
}

// Docker multiplexes stdout/stderr with 8-byte frame headers when there is no TTY.
function demux(buf) {
  if (!Buffer.isBuffer(buf)) return String(buf);
  let out = '';
  let i = 0;
  while (i + 8 <= buf.length && (buf[i] === 1 || buf[i] === 2 || buf[i] === 0) && buf[i + 1] === 0) {
    const len = buf.readUInt32BE(i + 4);
    out += buf.slice(i + 8, i + 8 + len).toString('utf8');
    i += 8 + len;
  }
  return i === 0 ? buf.toString('utf8') : out;
}

async function action(id, act) {
  const c = docker.getContainer(id);
  switch (act) {
    case 'start': return c.start();
    case 'stop': return c.stop();
    case 'restart': return c.restart();
    case 'remove': return c.remove({ force: true });
    default: throw new Error(`unknown action ${act}`);
  }
}

// Pulls the image (reporting progress) and starts a container for a catalog app.
async function install(appId, overrides = {}, onProgress = () => {}) {
  const app = getApp(appId);
  if (!app) throw new Error(`unknown app ${appId}; choose from ${CATALOG.map((a) => a.id).join(', ')}`);
  const existing = (await docker.listContainers({ all: true })).find((c) => c.Names.includes(`/forge-${app.id}`));
  if (existing) throw new Error(`forge-${app.id} already exists (${existing.State}); start it or remove it first`);

  onProgress({ phase: 'pull', text: `Pulling ${app.image}…` });
  const stream = await docker.pull(app.image);
  await new Promise((resolve, reject) =>
    docker.modem.followProgress(
      stream,
      (err) => (err ? reject(err) : resolve()),
      (evt) => {
        if (evt.status) onProgress({ phase: 'pull', text: `${evt.status}${evt.progress ? ' ' + evt.progress : ''}` });
      },
    ),
  );
  onProgress({ phase: 'create', text: 'Creating container…' });
  const container = await docker.createContainer(buildContainerConfig(app, overrides));
  await container.start();
  onProgress({ phase: 'done', text: `${app.name} is running` });
  return { id: container.id.slice(0, 12), name: `forge-${app.id}`, url: app.url };
}

module.exports = { status, listContainers, logs, action, install, demux, cpuPercent };
