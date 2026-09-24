'use strict';

// One-click apps. `ports` maps host port -> container port ("/udp" suffix allowed),
// `volumes` maps a named-volume suffix -> container path.
const CATALOG = [
  {
    id: 'minecraft',
    name: 'Minecraft Server',
    icon: '⛏️',
    tagline: 'Java Edition server, auto-updating, ready for friends',
    image: 'itzg/minecraft-server:latest',
    ports: { 25565: 25565 },
    env: { EULA: 'TRUE', MEMORY: '2G', TYPE: 'PAPER' },
    volumes: { data: '/data' },
    memoryMb: 3072,
    url: null,
  },
  {
    id: 'jellyfin',
    name: 'Jellyfin',
    icon: '🎬',
    tagline: 'Your own Netflix for movies, shows and music',
    image: 'jellyfin/jellyfin:latest',
    ports: { 8096: 8096 },
    env: {},
    volumes: { config: '/config', cache: '/cache', media: '/media' },
    url: 'http://localhost:8096',
  },
  {
    id: 'pihole',
    name: 'Pi-hole',
    icon: '🛡️',
    tagline: 'Network-wide ad and tracker blocking',
    image: 'pihole/pihole:latest',
    ports: { 53: 53, '53/udp': '53/udp', 8053: 80 },
    env: { TZ: 'UTC', FTLCONF_webserver_api_password: 'forge' },
    volumes: { etc: '/etc/pihole' },
    url: 'http://localhost:8053/admin',
  },
  {
    id: 'uptime-kuma',
    name: 'Uptime Kuma',
    icon: '📡',
    tagline: 'Monitor websites and services, get alerts when they go down',
    image: 'louislam/uptime-kuma:1',
    ports: { 3001: 3001 },
    env: {},
    volumes: { data: '/app/data' },
    url: 'http://localhost:3001',
  },
  {
    id: 'home-assistant',
    name: 'Home Assistant',
    icon: '🏠',
    tagline: 'Control every smart device in your home from one place',
    image: 'ghcr.io/home-assistant/home-assistant:stable',
    ports: { 8123: 8123 },
    env: { TZ: 'UTC' },
    volumes: { config: '/config' },
    url: 'http://localhost:8123',
  },
  {
    id: 'code-server',
    name: 'VS Code Server',
    icon: '💻',
    tagline: 'VS Code in the browser, reachable from any device',
    image: 'codercom/code-server:latest',
    ports: { 8443: 8080 },
    env: { PASSWORD: 'forge' },
    volumes: { home: '/home/coder' },
    url: 'http://localhost:8443',
  },
  {
    id: 'ollama',
    name: 'Ollama',
    icon: '🦙',
    tagline: 'Run free local AI models (powers Forge\'s free AI mode)',
    image: 'ollama/ollama:latest',
    ports: { 11434: 11434 },
    env: {},
    volumes: { models: '/root/.ollama' },
    url: null,
  },
  {
    id: 'nextcloud',
    name: 'Nextcloud',
    icon: '☁️',
    tagline: 'Your own Google Drive: files, photos, calendar',
    image: 'nextcloud:latest',
    ports: { 8080: 80 },
    env: {},
    volumes: { data: '/var/www/html' },
    url: 'http://localhost:8080',
  },
];

function getApp(id) {
  return CATALOG.find((a) => a.id === id) || null;
}

function normalizePort(p) {
  const s = String(p);
  return s.includes('/') ? s : `${s}/tcp`;
}

// Builds the dockerode createContainer() options for a catalog app.
// `overrides` may carry { env, memoryMb, hostPorts: { containerPort: hostPort } }.
function buildContainerConfig(app, overrides = {}) {
  const env = { ...app.env, ...(overrides.env || {}) };
  const memoryMb = overrides.memoryMb ?? app.memoryMb;
  const ExposedPorts = {};
  const PortBindings = {};
  for (const [host, container] of Object.entries(app.ports)) {
    const cKey = normalizePort(container);
    const hostPort = String(overrides.hostPorts?.[cKey] ?? overrides.hostPorts?.[String(container)] ?? host).split('/')[0];
    ExposedPorts[cKey] = {};
    PortBindings[cKey] = [{ HostPort: hostPort }];
  }
  const Binds = Object.entries(app.volumes).map(([suffix, target]) => `forge-${app.id}-${suffix}:${target}`);
  return {
    name: `forge-${app.id}`,
    Image: app.image,
    Env: Object.entries(env).map(([k, v]) => `${k}=${v}`),
    ExposedPorts,
    Labels: { 'forge.app': app.id },
    HostConfig: {
      PortBindings,
      Binds,
      RestartPolicy: { Name: 'unless-stopped' },
      ...(memoryMb ? { Memory: memoryMb * 1024 * 1024 } : {}),
    },
  };
}

module.exports = { CATALOG, getApp, buildContainerConfig };
