'use strict';
const { app, BrowserWindow, ipcMain, safeStorage, shell, nativeTheme } = require('electron');
const path = require('path');
const { Settings } = require('./settings');
const { PtyManager } = require('./pty');
const { Agent } = require('./agent');
const { CATALOG } = require('./catalog');
const { listOllamaModels, fetchModels, testConnection } = require('./agent/openai-compat');
const docker = require('./docker');
const stats = require('./stats');

let win;
let settings;
let ptys;
let agent;

function send(channel, payload) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
}

function createWindow() {
  nativeTheme.themeSource = 'dark';
  win = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 1080,
    minHeight: 680,
    backgroundColor: '#07080d',
    title: 'Forge',
    icon: path.join(__dirname, '..', '..', 'build', 'icon.png'),
    titleBarStyle: process.platform === 'linux' ? 'default' : process.platform === 'darwin' ? 'hiddenInset' : 'hidden',
    ...(process.platform === 'win32' ? { titleBarOverlay: { color: '#0b0c14', symbolColor: '#8a90a8', height: 34 } } : {}),
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload.js'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
    },
  });
  win.once('ready-to-show', () => win.show());
  win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));

  // Links open in the real browser, never inside the app.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (e) => e.preventDefault());
}

function handle(channel, fn) {
  ipcMain.handle(channel, async (_e, ...args) => {
    try {
      return { ok: true, data: await fn(...args) };
    } catch (e) {
      return { ok: false, error: e.message };
    }
  });
}

app.whenReady().then(() => {
  settings = new Settings(app.getPath('userData'), safeStorage);
  ptys = new PtyManager(send);
  agent = new Agent(settings, (evt) => send('agent:event', evt));

  handle('settings:get', () => settings.public());
  handle('settings:update', (patch) => settings.update(patch));

  handle('stats:snapshot', () => stats.snapshot());
  handle('stats:top', () => stats.topProcesses(8));

  handle('docker:status', () => docker.status());
  handle('docker:list', () => docker.listContainers({ withStats: true }));
  handle('docker:logs', (id) => docker.logs(id, 300));
  handle('docker:action', (id, act) => docker.action(id, act));
  handle('docker:install', (appId, overrides) =>
    docker.install(appId, overrides, (p) => send('docker:progress', { appId, ...p })),
  );
  handle('catalog:list', () => CATALOG);

  handle('pty:create', (cols, rows) => ptys.create(cols, rows));
  ipcMain.on('pty:write', (_e, { id, data }) => ptys.write(id, data));
  ipcMain.on('pty:resize', (_e, { id, cols, rows }) => ptys.resize(id, cols, rows));
  ipcMain.on('pty:kill', (_e, id) => ptys.kill(id));

  handle('agent:send', (text) => {
    // Runs in the background; progress arrives as agent:event.
    agent.send(String(text)).catch((e) => send('agent:event', { type: 'error', text: e.message }));
    return true;
  });
  handle('agent:stop', () => agent.stop());
  handle('agent:reset', () => agent.reset());
  ipcMain.on('agent:approve', (_e, { id, approved }) => agent.resolveApproval(id, Boolean(approved)));

  handle('ollama:models', () => listOllamaModels(settings.data.ollamaUrl));
  // Settings screen: `form` carries unsaved values (preset, model, key) so they can be tried before saving.
  handle('ai:models', (form = {}) => fetchModels({ ...settings.freeConfig(form), needsKey: true }));
  handle('ai:test', (form = {}) => testConnection({ ...settings.freeConfig(form), needsKey: true }));
  handle('open:external', (url) => {
    if (/^https?:\/\//.test(url)) return shell.openExternal(url);
    throw new Error('only http(s) links can be opened');
  });

  createWindow();
  app.on('activate', () => BrowserWindow.getAllWindows().length === 0 && createWindow());
});

app.on('window-all-closed', () => {
  ptys?.killAll();
  agent?.stop();
  if (process.platform !== 'darwin') app.quit();
});
