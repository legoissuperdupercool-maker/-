'use strict';
const { app, BrowserWindow, ipcMain, safeStorage, shell, nativeTheme, Tray, Menu, Notification } = require('electron');
const path = require('path');
const { Settings } = require('./settings');
const { PtyManager } = require('./pty');
const { Agent } = require('./agent');
const { CATALOG } = require('./catalog');
const { listOllamaModels, fetchModels, testConnection } = require('./agent/openai-compat');
const docker = require('./docker');
const stats = require('./stats');
const { Engine } = require('./engine');

let win;
let settings;
let ptys;
let agent;
let engine;
let tray;
let quitting = false;
let trayHintShown = false;

const ICON = path.join(__dirname, '..', '..', 'build', 'icon.png');

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
    icon: ICON,
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

  // While Forge's own server engine runs, closing the window keeps servers up in the tray.
  win.on('close', (e) => {
    if (quitting || !engine?.ownsEngine) return;
    e.preventDefault();
    win.hide();
    if (!trayHintShown && Notification.isSupported()) {
      trayHintShown = true;
      new Notification({ title: 'Forge is still running', body: 'Your servers keep running. Right-click the Forge tray icon to quit.', icon: ICON }).show();
    }
  });
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

function showWindow() {
  if (!win || win.isDestroyed()) createWindow();
  else {
    win.show();
    win.focus();
  }
}

function createTray() {
  tray = new Tray(ICON);
  tray.setToolTip('Forge');
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: 'Open Forge', click: showWindow },
      { type: 'separator' },
      { label: 'Quit Forge (stops servers)', click: () => app.quit() },
    ]),
  );
  tray.on('click', showWindow);
}

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) app.quit();
app.on('second-instance', showWindow);

app.whenReady().then(() => {
  if (!gotLock) return;
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

  engine = new Engine({ dataDir: app.getPath('userData'), docker, emit: (st) => send('engine:state', st) });
  handle('engine:state', () => engine.state);
  handle('engine:detect', () => engine.detect());
  handle('engine:setup', () => engine.setup());
  handle('engine:reboot', () => {
    require('child_process').execFile('shutdown.exe', ['/r', '/t', '5', '/c', 'Restarting to finish setting up the Forge server engine']);
    return true;
  });
  engine.detect().catch(() => {});

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
  createTray();
  app.on('activate', showWindow);
});

app.on('before-quit', (e) => {
  if (quitting) return;
  quitting = true;
  ptys?.killAll();
  agent?.stop();
  if (engine?.ownsEngine) {
    e.preventDefault();
    engine.stop().finally(() => app.quit());
  }
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
