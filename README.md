# Forge

**An AI-powered command center for your computer and home server.** Real terminals, a Docker home-server panel with one-click apps, live system stats, and an AI agent that can see and control all of it. It always asks before changing anything.

![Dashboard](docs/dashboard.png)

## Install on Windows 11

**[Download ForgeInstaller.exe](https://github.com/legoissuperdupercool-maker/forge-releases/releases/latest/download/ForgeInstaller.exe)** (from the public [forge-releases](https://github.com/legoissuperdupercool-maker/forge-releases/releases) repo)

1. Run `ForgeInstaller.exe`.
2. Windows shows *"Windows protected your PC"* because the installer isn't code-signed. Click **More info → Run anyway**.
3. Choose a folder and click **Install**. **Forge** appears on your desktop and in the Start menu.

Forge updates itself. When a new version is out, a glowing **Update available** badge appears; click it, then **Restart & update**.

### How releases are published

This code repo is private. Every push builds the installer on a Windows runner (`.github/workflows/windows-installer.yml`), stamps it as version `0.2.<run number>`, and publishes it as a new release in the public `forge-releases` repo with `latest.yml`, which installed copies use to detect and verify updates. That needs one repo secret, `RELEASES_TOKEN`: a fine-grained personal access token with **Contents: Read and write** on `forge-releases` only.

To build locally on Windows: `npm install` then `npm run dist:win`. The output is `dist\ForgeInstaller.exe`.

## What it does

| | |
|---|---|
| **Command Center** | Live CPU / RAM / disk / temperature gauges, a streaming load chart, per-core heatmap, network speed, top processes |
| **Terminal** | Real shell tabs (PowerShell on Windows, your `$SHELL` on Mac/Linux) |
| **Home Server** | Built-in server engine (no Docker Desktop needed). Every container with live CPU/RAM, ports, logs, start / stop / restart / remove |
| **App Store** | One-click installs: Minecraft server, Jellyfin, Pi-hole, Uptime Kuma, Home Assistant, VS Code Server, Ollama, Nextcloud |
| **Forge AI** | Chat with an agent that reads your stats, containers and logs, runs commands and installs apps. Every change shows an **Approve / Deny** card first |

Try asking it:

- *"What's slowing my PC down?"*
- *"Set up a Minecraft server with 4GB of RAM."*
- *"Why did my Jellyfin container crash?"*
- *"What's eating my disk space?"*

![AI agent diagnosing a crashed container](docs/server-agent.png)

## Built-in server engine

On Windows, Forge runs its own server engine, so you don't install Docker Desktop. The first time you open the **Server** tab, click **Set up server engine**:

1. If Windows' built-in Linux support (WSL2) is off, Forge turns it on. Windows asks for admin permission, and may need one restart.
2. Forge creates a tiny private Linux environment called `forge-engine` (Alpine Linux, about 3 MB, checksum-verified) and installs the open-source Docker Engine inside it.
3. From then on, the engine starts automatically whenever Forge opens. Closing the window keeps your servers running in the system tray; **Quit** from the tray stops them. Containers come back the next time Forge starts.

If Docker Desktop is already running, Forge uses that instead. The engine's API listens only on `127.0.0.1:23750` on your PC.

## Pick your AI engine (Settings)

![Settings](docs/settings.png)

| Engine | Cost | Setup |
|---|---|---|
| **Free cloud AI** (default) | Free | Get a free key from [Groq](https://console.groq.com/keys), [OpenRouter](https://openrouter.ai/keys) or [Google Gemini](https://aistudio.google.com/apikey) and paste it in Settings. No credit card needed. Free tiers have rate limits. |
| **Local AI** | Free, offline | Install [Ollama](https://ollama.com/download) (or one-click it in the App Store), then run `ollama pull qwen3:8b`. Everything stays on your PC. Needs a decent GPU or a lot of RAM for good speed. |
| **Claude** | Pay per use | Paste an [Anthropic API key](https://console.anthropic.com/settings/keys). This is the smartest and most reliable option for multi-step jobs. Uses Claude Opus 5 by default, or Sonnet 5 if you want cheaper. |

API keys are encrypted with your OS keychain (Windows DPAPI, macOS Keychain, libsecret on Linux) and never shown to the UI.

## Run it

You need [Node.js 20+](https://nodejs.org). On Mac/Linux the Home Server features use your installed Docker.

```bash
npm install
npm start
```

Linux only: if `npm install` can't find a prebuilt terminal module, install build tools first (`sudo apt install build-essential python3`).

Build an installer (`.exe` / `.dmg` / `.AppImage`) for your OS:

```bash
npm run dist
```

## Tests

```bash
npm test
```

Covers the tool approval gate, input validation, both AI engines end-to-end against fake streaming servers, Docker config generation, key encryption, and the chat markdown sanitizer.

## How it's built

```
src/
  main/              Electron main process (Node)
    main.js          window + IPC
    agent/
      index.js       routes chat to the chosen engine, brokers approvals
      claude.js      Claude via the Anthropic SDK (streaming tool loop)
      openai-compat.js  Groq / OpenRouter / Gemini / Ollama (OpenAI-compatible API)
      tools.js       what the AI can do: run_command, system_stats, list_containers,
                     container_logs, container_action, install_app, read_file
    docker.js        Docker Engine API (dockerode)
    catalog.js       one-click app definitions
    stats.js         system stats (systeminformation)
    pty.js           terminals (node-pty)
    settings.js      settings + encrypted keys
  preload.js         the only bridge between UI and system (contextIsolation + sandbox)
  renderer/          UI: plain HTML/CSS/JS + xterm.js
```

## Safety

- The AI **can't change anything without your click**: running commands, starting, stopping or removing containers, and installing apps all need approval. Reading stats, logs and files is automatic by default; you can turn that off in Settings.
- Removing a container keeps its data volumes.
- The UI runs sandboxed, with no Node access, and talks to the system only through a small, fixed API.
