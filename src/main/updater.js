'use strict';
// Update checks against the "windows-latest" GitHub release. Every CI build stamps a new
// version (0.2.<run number>) and uploads latest.yml, which electron-updater compares with
// this app's version. Downloads are verified with the sha512 in latest.yml before installing.
const { app } = require('electron');

const CHECK_EVERY_MS = 4 * 60 * 60 * 1000;

class Updater {
  constructor(send) {
    this.send = send;
    this.state = { state: 'idle', current: app.getVersion() };
    this.updater = null;
    if (!app.isPackaged || process.platform !== 'win32') {
      this.state = { state: 'unsupported', current: app.getVersion() };
      return;
    }
    const { autoUpdater } = require('electron-updater');
    this.updater = autoUpdater;
    autoUpdater.autoDownload = false; // the user decides when to download
    autoUpdater.autoInstallOnAppQuit = true; // a downloaded update installs on next quit anyway
    autoUpdater.on('checking-for-update', () => this.set({ state: 'checking' }));
    autoUpdater.on('update-available', (info) => this.set({ state: 'available', version: info.version, notes: notesText(info.releaseNotes), date: info.releaseDate }));
    autoUpdater.on('update-not-available', () => this.set({ state: 'latest' }));
    autoUpdater.on('download-progress', (p) => this.set({ ...this.state, state: 'downloading', percent: Math.round(p.percent) }));
    autoUpdater.on('update-downloaded', (info) => this.set({ state: 'ready', version: info.version, notes: notesText(info.releaseNotes) }));
    autoUpdater.on('error', (e) => this.set({ ...this.state, state: this.state.state === 'downloading' ? 'available' : 'error', error: shortError(e) }));
  }

  set(patch) {
    this.state = { current: app.getVersion(), ...patch };
    this.send('update:state', this.state);
  }

  start() {
    if (!this.updater) return;
    setTimeout(() => this.check(), 8000);
    setInterval(() => ['idle', 'latest', 'error'].includes(this.state.state) && this.check(), CHECK_EVERY_MS).unref();
  }

  async check() {
    if (!this.updater) return this.state;
    try {
      await this.updater.checkForUpdates();
    } catch (e) {
      this.set({ state: 'error', error: shortError(e) });
    }
    return this.state;
  }

  async download() {
    if (!this.updater || this.state.state !== 'available') return this.state;
    this.set({ ...this.state, state: 'downloading', percent: 0 });
    try {
      await this.updater.downloadUpdate();
    } catch (e) {
      this.set({ ...this.state, state: 'available', error: shortError(e) });
    }
    return this.state;
  }

  // Silent install, then Forge starts again on the new version.
  install() {
    if (this.state.state === 'ready') this.updater.quitAndInstall(true, true);
  }
}

function notesText(notes) {
  if (!notes) return '';
  const text = Array.isArray(notes) ? notes.map((n) => n.note).join('\n') : String(notes);
  return text.replace(/<[^>]+>/g, '').trim().slice(0, 600);
}

function shortError(e) {
  const m = String(e?.message || e);
  if (/404|Cannot find latest\.yml|ENOTFOUND|ETIMEDOUT|ECONNRESET|net::/i.test(m)) return 'Could not reach the update server. Will try again later.';
  return m.split('\n')[0].slice(0, 200);
}

module.exports = { Updater };
