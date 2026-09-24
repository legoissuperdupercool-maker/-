'use strict';
const { contextBridge, ipcRenderer } = require('electron');

async function call(channel, ...args) {
  const r = await ipcRenderer.invoke(channel, ...args);
  if (!r.ok) throw new Error(r.error);
  return r.data;
}

function on(channel, cb) {
  const listener = (_e, payload) => cb(payload);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}

contextBridge.exposeInMainWorld('forge', {
  platform: process.platform,
  settings: {
    get: () => call('settings:get'),
    update: (patch) => call('settings:update', patch),
  },
  stats: {
    snapshot: () => call('stats:snapshot'),
    top: () => call('stats:top'),
  },
  docker: {
    status: () => call('docker:status'),
    list: () => call('docker:list'),
    logs: (id) => call('docker:logs', id),
    action: (id, act) => call('docker:action', id, act),
    install: (appId, overrides) => call('docker:install', appId, overrides),
    catalog: () => call('catalog:list'),
    onProgress: (cb) => on('docker:progress', cb),
  },
  pty: {
    create: (cols, rows) => call('pty:create', cols, rows),
    write: (id, data) => ipcRenderer.send('pty:write', { id, data }),
    resize: (id, cols, rows) => ipcRenderer.send('pty:resize', { id, cols, rows }),
    kill: (id) => ipcRenderer.send('pty:kill', id),
    onData: (cb) => on('pty:data', cb),
    onExit: (cb) => on('pty:exit', cb),
  },
  agent: {
    send: (text) => call('agent:send', text),
    stop: () => call('agent:stop'),
    reset: () => call('agent:reset'),
    approve: (id, approved) => ipcRenderer.send('agent:approve', { id, approved }),
    onEvent: (cb) => on('agent:event', cb),
  },
  ollama: { models: () => call('ollama:models') },
  ai: {
    models: (form) => call('ai:models', form),
    test: (form) => call('ai:test', form),
  },
  openExternal: (url) => call('open:external', url),
});
