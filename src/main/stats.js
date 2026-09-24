'use strict';
const si = require('systeminformation');
const os = require('os');

async function snapshot() {
  const [load, mem, disks, net, temp] = await Promise.all([
    si.currentLoad(),
    si.mem(),
    si.fsSize().catch(() => []),
    si.networkStats().catch(() => []),
    si.cpuTemperature().catch(() => ({})),
  ]);
  const disk = disks.reduce((a, d) => ({ size: a.size + d.size, used: a.used + d.used }), { size: 0, used: 0 });
  const rx = net.reduce((a, n) => a + (n.rx_sec || 0), 0);
  const tx = net.reduce((a, n) => a + (n.tx_sec || 0), 0);
  return {
    host: os.hostname(),
    platform: `${os.type()} ${os.release()}`,
    uptime: os.uptime(),
    cpu: +load.currentLoad.toFixed(1),
    cores: load.cpus.map((c) => +c.load.toFixed(0)),
    memUsed: mem.active,
    memTotal: mem.total,
    diskUsed: disk.used,
    diskTotal: disk.size,
    netRx: rx,
    netTx: tx,
    tempC: temp.main || null,
  };
}

async function topProcesses(limit = 10) {
  const p = await si.processes();
  return p.list
    .sort((a, b) => b.cpu - a.cpu || b.mem - a.mem)
    .slice(0, limit)
    .map((x) => ({ pid: x.pid, name: x.name, cpu: +x.cpu.toFixed(1), mem: +x.mem.toFixed(1) }));
}

module.exports = { snapshot, topProcesses };
