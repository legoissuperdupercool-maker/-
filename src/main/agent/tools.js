'use strict';
const { exec } = require('child_process');
const fs = require('fs/promises');
const os = require('os');
const path = require('path');
const { z } = require('zod');
const docker = require('../docker');
const stats = require('../stats');
const { CATALOG } = require('../catalog');

const MAX_OUTPUT = 12000;

function clip(text) {
  if (text.length <= MAX_OUTPUT) return text;
  return `[…${text.length - MAX_OUTPUT} earlier characters trimmed…]\n` + text.slice(-MAX_OUTPUT);
}

function commandShell() {
  if (process.platform === 'win32') return 'powershell.exe';
  return process.env.SHELL || '/bin/bash';
}

function runCommand(command, cwd, signal) {
  return new Promise((resolve) => {
    exec(
      command,
      { cwd: cwd || os.homedir(), shell: commandShell(), timeout: 120000, maxBuffer: 16 * 1024 * 1024, signal, windowsHide: true },
      (err, stdout, stderr) => {
        const code = err ? (err.killed ? 'timeout/cancelled' : err.code ?? 1) : 0;
        resolve(clip(`exit code: ${code}\n${stdout}${stderr ? `\n[stderr]\n${stderr}` : ''}`.trim()));
      },
    );
  });
}

// Each tool: JSON schema for the model, zod schema to validate what the model sent,
// readOnly (never needs approval), describe() for the approval card, run().
const TOOLS = [
  {
    name: 'run_command',
    description: `Run a shell command on the user's computer and return its combined output. The shell is ${commandShell()} on ${process.platform}. Use for diagnostics, file operations, git, package managers, docker CLI, etc. Commands time out after 2 minutes; do not start interactive or never-ending programs.`,
    schema: {
      type: 'object',
      properties: {
        command: { type: 'string', description: 'The exact command line to run' },
        cwd: { type: 'string', description: 'Working directory (defaults to the home directory)' },
        reason: { type: 'string', description: 'One short sentence telling the user why you are running this' },
      },
      required: ['command', 'reason'],
    },
    zod: z.object({ command: z.string().min(1), cwd: z.string().optional(), reason: z.string() }),
    readOnly: false,
    describe: (i) => ({ title: 'Run command', detail: i.command, reason: i.reason, code: true }),
    run: (i, ctx) => runCommand(i.command, i.cwd, ctx.signal),
  },
  {
    name: 'system_stats',
    description: 'Get live CPU, memory, disk, network and temperature stats for the host, plus the top processes by CPU.',
    schema: { type: 'object', properties: {}, required: [] },
    zod: z.object({}).passthrough(),
    readOnly: true,
    describe: () => ({ title: 'Read system stats' }),
    run: async () => JSON.stringify({ ...(await stats.snapshot()), topProcesses: await stats.topProcesses(12) }),
  },
  {
    name: 'list_containers',
    description: 'List all Docker containers (running and stopped) with state, ports, CPU% and memory.',
    schema: { type: 'object', properties: {}, required: [] },
    zod: z.object({}).passthrough(),
    readOnly: true,
    describe: () => ({ title: 'List containers' }),
    run: async () => {
      const s = await docker.status();
      if (!s.available) return `Docker unavailable: ${s.error}`;
      return JSON.stringify(await docker.listContainers({ withStats: true }));
    },
  },
  {
    name: 'container_logs',
    description: 'Fetch the most recent log lines of a Docker container. Use this first when diagnosing crashes.',
    schema: {
      type: 'object',
      properties: {
        container: { type: 'string', description: 'Container name or ID' },
        tail: { type: 'integer', description: 'Number of lines (default 150)' },
      },
      required: ['container'],
    },
    zod: z.object({ container: z.string().min(1), tail: z.number().int().positive().max(2000).optional() }),
    readOnly: true,
    describe: (i) => ({ title: 'Read logs', detail: i.container }),
    run: async (i) => clip(await docker.logs(i.container, i.tail || 150)) || '(no log output)',
  },
  {
    name: 'container_action',
    description: 'Start, stop, restart or remove (force, keeps named volumes) a Docker container.',
    schema: {
      type: 'object',
      properties: {
        container: { type: 'string', description: 'Container name or ID' },
        action: { type: 'string', enum: ['start', 'stop', 'restart', 'remove'] },
      },
      required: ['container', 'action'],
    },
    zod: z.object({ container: z.string().min(1), action: z.enum(['start', 'stop', 'restart', 'remove']) }),
    readOnly: false,
    describe: (i) => ({ title: `${i.action[0].toUpperCase()}${i.action.slice(1)} container`, detail: i.container }),
    run: async (i) => {
      await docker.action(i.container, i.action);
      return `${i.action} ${i.container}: ok`;
    },
  },
  {
    name: 'install_app',
    description: `Install and start a self-hosted app from Forge's catalog as a Docker container named forge-<app_id>. Catalog: ${CATALOG.map((a) => `${a.id} (${a.name}: ${a.tagline})`).join('; ')}.`,
    schema: {
      type: 'object',
      properties: {
        app_id: { type: 'string', enum: CATALOG.map((a) => a.id) },
        env: { type: 'object', description: 'Extra/overriding environment variables, e.g. {"MEMORY":"4G"} for minecraft', additionalProperties: { type: 'string' } },
        memory_mb: { type: 'integer', description: 'Container memory limit in MB' },
      },
      required: ['app_id'],
    },
    zod: z.object({
      app_id: z.enum(CATALOG.map((a) => a.id)),
      env: z.record(z.string(), z.coerce.string()).optional(),
      memory_mb: z.number().int().positive().optional(),
    }),
    readOnly: false,
    describe: (i) => ({
      title: 'Install app',
      detail: `${i.app_id}${i.env ? ' ' + JSON.stringify(i.env) : ''}${i.memory_mb ? ` · ${i.memory_mb} MB` : ''}`,
    }),
    run: async (i, ctx) => {
      const r = await docker.install(i.app_id, { env: i.env, memoryMb: i.memory_mb }, (p) => ctx.progress(p.text));
      return JSON.stringify(r);
    },
  },
  {
    name: 'read_file',
    description: 'Read a text file (config files, logs, compose files). Returns at most ~12k characters.',
    schema: {
      type: 'object',
      properties: { path: { type: 'string', description: 'Absolute path, or relative to the home directory' } },
      required: ['path'],
    },
    zod: z.object({ path: z.string().min(1) }),
    readOnly: true,
    describe: (i) => ({ title: 'Read file', detail: i.path }),
    run: async (i) => clip(await fs.readFile(path.resolve(os.homedir(), i.path), 'utf8')),
  },
];

const byName = new Map(TOOLS.map((t) => [t.name, t]));

// Validates, asks for approval when needed, runs. Always resolves to { content, isError }.
async function executeTool(name, input, ctx) {
  const tool = byName.get(name);
  if (!tool) return { content: `Unknown tool ${name}`, isError: true };
  const parsed = tool.zod.safeParse(input ?? {});
  if (!parsed.success) {
    return { content: JSON.stringify({ INVALID_INPUT: input, issues: parsed.error.issues.map((x) => x.message) }), isError: true };
  }
  const info = tool.describe(parsed.data);
  const needsApproval = !(tool.readOnly && ctx.autoApproveReadOnly);
  if (needsApproval) {
    const ok = await ctx.approve({ tool: name, ...info });
    if (!ok) return { content: 'The user declined this action. Ask what they would like instead.', isError: true };
  } else {
    ctx.notify({ tool: name, ...info });
  }
  try {
    return { content: String(await tool.run(parsed.data, ctx)), isError: false };
  } catch (e) {
    return { content: `Error: ${e.message}`, isError: true };
  }
}

const anthropicTools = () =>
  TOOLS.map((t) => ({ name: t.name, description: t.description, input_schema: t.schema, eager_input_streaming: true }));

const openAiTools = () =>
  TOOLS.map((t) => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.schema } }));

function systemPrompt() {
  return `You are Forge, an AI operator built into a desktop command center. You help the user run their computer and their self-hosted home server (Docker).

Host: ${os.hostname()} · ${os.type()} ${os.release()} (${process.platform}/${process.arch}) · home directory ${os.homedir()}.

How to work:
- Investigate before acting: read stats, list containers and read logs to ground your answers in real data.
- Use tools rather than telling the user to run commands themselves. Actions that change things are shown to the user for approval, so just call them; if one is declined, ask what they want instead.
- Prefer the catalog (install_app) for self-hosted apps. After installing, tell the user the URL or port to connect to.
- Never run destructive commands (deleting data, wiping disks, force-pushing) unless the user explicitly asked for exactly that.
- Keep replies short and skimmable: a sentence or two, bullets for findings, code blocks for commands and config.`;
}

module.exports = { TOOLS, executeTool, anthropicTools, openAiTools, systemPrompt, runCommand, clip };
