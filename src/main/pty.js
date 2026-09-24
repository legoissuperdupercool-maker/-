'use strict';
const os = require('os');
const pty = require('node-pty');

function defaultShell() {
  if (process.platform === 'win32') return 'powershell.exe';
  return process.env.SHELL || '/bin/bash';
}

// Owns the terminal sessions shown in the Terminal tab.
class PtyManager {
  constructor(send) {
    this.send = send;
    this.terms = new Map();
    this.nextId = 1;
  }

  create(cols = 100, rows = 30) {
    const id = this.nextId++;
    const term = pty.spawn(defaultShell(), [], {
      name: 'xterm-256color',
      cols,
      rows,
      cwd: os.homedir(),
      env: { ...process.env, TERM: 'xterm-256color', COLORTERM: 'truecolor' },
    });
    term.onData((data) => this.send('pty:data', { id, data }));
    term.onExit(({ exitCode }) => {
      this.terms.delete(id);
      this.send('pty:exit', { id, exitCode });
    });
    this.terms.set(id, term);
    return id;
  }

  write(id, data) {
    this.terms.get(id)?.write(data);
  }

  resize(id, cols, rows) {
    try {
      this.terms.get(id)?.resize(Math.max(cols, 2), Math.max(rows, 2));
    } catch {
      // terminal exited mid-resize
    }
  }

  kill(id) {
    this.terms.get(id)?.kill();
    this.terms.delete(id);
  }

  killAll() {
    for (const id of [...this.terms.keys()]) this.kill(id);
  }
}

module.exports = { PtyManager, defaultShell };
