'use strict';
// Engine for the free AI modes. Groq, OpenRouter, Gemini and a local Ollama all speak
// the OpenAI-compatible /chat/completions protocol, so one streamed tool loop serves them.
const { openAiTools, executeTool, systemPrompt } = require('./tools');

const MAX_TURNS = 30;

// Splits Server-Sent Events into parsed JSON payloads. Feed it raw text chunks.
function createSseParser(onJson) {
  let buf = '';
  return (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line.startsWith('data:')) continue;
      const data = line.slice(5).trim();
      if (!data || data === '[DONE]') continue;
      try {
        onJson(JSON.parse(data));
      } catch {
        // ignore keep-alive or malformed lines
      }
    }
  };
}

// Routes <think>…</think> spans (emitted by reasoning models such as Qwen3/DeepSeek)
// to the thinking channel; handles tags split across chunks.
function createThinkSplitter(onText, onThinking) {
  let inThink = false;
  let pending = '';
  return (chunk) => {
    pending += chunk;
    for (;;) {
      const tag = inThink ? '</think>' : '<think>';
      const i = pending.indexOf(tag);
      if (i >= 0) {
        const part = pending.slice(0, i);
        if (part) (inThink ? onThinking : onText)(part);
        pending = pending.slice(i + tag.length);
        inThink = !inThink;
        continue;
      }
      // keep a possible partial tag at the end for the next chunk
      let keep = 0;
      for (let k = Math.min(tag.length - 1, pending.length); k > 0; k--) {
        if (tag.startsWith(pending.slice(-k))) {
          keep = k;
          break;
        }
      }
      const out = pending.slice(0, pending.length - keep);
      if (out) (inThink ? onThinking : onText)(out);
      pending = pending.slice(pending.length - keep);
      return;
    }
  };
}

// Merges streamed tool_call deltas into complete calls.
function mergeToolCallDelta(calls, deltas) {
  for (const [pos, d] of deltas.entries()) {
    // Some providers (e.g. Gemini) omit `index`; a new id at an occupied slot is a new call.
    let idx = d.index ?? pos;
    if (d.index == null && d.id && calls[idx]?.id && calls[idx].id !== d.id) idx = calls.length;
    const c = (calls[idx] ??= { id: '', name: '', arguments: '' });
    if (d.id) c.id = d.id;
    if (d.function?.name) c.name += d.function.name;
    if (d.function?.arguments != null) {
      c.arguments += typeof d.function.arguments === 'string' ? d.function.arguments : JSON.stringify(d.function.arguments);
    }
  }
  return calls;
}

// Models that can't chat or can't take custom tools (speech, TTS, safety filters, embeddings…).
const NON_CHAT = /whisper|tts|playai|orpheus|guard|embed|moderation|transcri|speech|audio|imagen|image-gen|aqa|veo|lyria|compound|allam|distil|learnlm|gemma-3n|native-audio|live-/i;
// Best tool-calling models first; the first match in the live list wins.
const PREFERRED = [
  'gpt-oss-120b', 'llama-3.3-70b', 'kimi-k2', 'qwen3-32b', 'llama-4-maverick', 'llama-4-scout',
  'gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-flash-latest', 'gemini-2.0-flash',
  'deepseek-chat-v3', 'qwen3-235b', 'qwen3-coder', 'gpt-oss-20b', 'mistral-small', 'llama-3.1-8b',
];

// Filters a provider's /models response down to chat models that support tools, best first.
function rankChatModels(models) {
  const usable = models
    .map((m) => (typeof m === 'string' ? { id: m } : m))
    .map((m) => ({ ...m, id: String(m.id).replace(/^models\//, '') }))
    .filter((m) => !NON_CHAT.test(m.id))
    .filter((m) => !Array.isArray(m.supported_parameters) || m.supported_parameters.includes('tools'));
  const score = (id) => {
    const i = PREFERRED.findIndex((p) => id.includes(p));
    return i < 0 ? PREFERRED.length : i;
  };
  return usable
    .map((m) => m.id)
    .filter((id, i, a) => a.indexOf(id) === i)
    .sort((a, b) => score(a) - score(b) || a.localeCompare(b));
}

function authHeaders(cfg) {
  const headers = { 'Content-Type': 'application/json' };
  if (cfg.apiKey) headers.Authorization = `Bearer ${cfg.apiKey}`;
  if (cfg.baseUrl.includes('openrouter.ai')) {
    headers['HTTP-Referer'] = 'https://github.com/forge-app';
    headers['X-Title'] = 'Forge';
  }
  return headers;
}

class ProviderError extends Error {
  constructor(message, kind) {
    super(message);
    this.kind = kind; // 'auth' | 'rate' | 'model' | 'tool' | 'other'
  }
}

const MODEL_ERR = /model.{0,60}(not found|does not exist|decommissioned|deprecated|not supported|unsupported|no longer|not available|not a valid|invalid)|does not support chat|chat completions? (are |is )?not supported|not supported for chat|no endpoints found|invalid model/i;
const TOOL_ERR = /tool_use_failed|failed to call a function|failed to parse tool|tool call validation|invalid tool call/i;

function toProviderError(cfg, status, body) {
  let msg = body;
  let code = '';
  try {
    let j = JSON.parse(body);
    if (Array.isArray(j)) j = j[0];
    const e = j.error ?? j;
    msg = typeof e === 'string' ? e : e.message || body;
    code = (typeof e === 'object' && (e.code || e.type)) || '';
  } catch {
    // plain-text error body
  }
  msg = String(msg).slice(0, 300);
  const label = cfg.label;
  if (status === 401 || status === 403 || code === 'invalid_api_key') {
    return new ProviderError(`${label} rejected the API key. Paste it again in Settings and press Test.`, 'auth');
  }
  if (status === 429) return new ProviderError(`${label} free-tier rate limit hit. Wait a minute, or pick a different model or engine.`, 'rate');
  if (code === 'tool_use_failed' || TOOL_ERR.test(msg)) return new ProviderError(`${label}: the model sent a broken tool call (${msg})`, 'tool');
  if (code === 'model_not_found' || code === 'model_decommissioned' || MODEL_ERR.test(msg) || (status === 404 && !cfg.pullHint)) {
    return new ProviderError(`${label} can't use model "${cfg.model}": ${msg}`, 'model');
  }
  if (status === 404 && cfg.pullHint) return new ProviderError(cfg.pullHint, 'model');
  return new ProviderError(`${label} error${status ? ' ' + status : ''}: ${msg}`, 'other');
}

// Lists the models the key can use, best tool-calling chat models first.
async function fetchModels(cfg) {
  let res;
  try {
    res = await fetch(`${cfg.baseUrl.replace(/\/$/, '')}/models`, { headers: authHeaders(cfg), signal: AbortSignal.timeout(15000) });
  } catch (e) {
    throw new ProviderError(cfg.offlineHint || `Could not reach ${cfg.label}: ${e.message}`, 'other');
  }
  if (!res.ok) throw toProviderError(cfg, res.status, await res.text().catch(() => ''));
  const j = await res.json();
  let list = j.data || j.models || [];
  if (cfg.baseUrl.includes('openrouter.ai')) list = list.filter((m) => String(m.id).endsWith(':free'));
  return rankChatModels(list);
}

class OpenAICompatEngine {
  // getConfig() -> { baseUrl, apiKey, model, label, needsKey, keyUrl, offlineHint, pullHint, onModelChange }
  constructor(getConfig) {
    this.getConfig = getConfig;
    this.history = [];
  }

  reset() {
    this.history = [];
  }

  // One streamed completion. Returns { content, calls }; throws ProviderError.
  async streamTurn(cfg, h, useTools) {
    let res;
    try {
      res = await fetch(`${cfg.baseUrl.replace(/\/$/, '')}/chat/completions`, {
        method: 'POST',
        headers: authHeaders(cfg),
        signal: h.signal,
        body: JSON.stringify({
          model: cfg.model,
          stream: true,
          messages: [{ role: 'system', content: systemPrompt() }, ...this.history],
          ...(useTools ? { tools: openAiTools() } : {}),
        }),
      });
    } catch (e) {
      if (h.signal.aborted) throw Object.assign(new Error('Stopped.'), { aborted: true });
      throw new ProviderError(cfg.offlineHint || `Could not reach ${cfg.label}: ${e.message}`, 'other');
    }
    if (!res.ok) throw toProviderError(cfg, res.status, await res.text().catch(() => ''));

    let content = '';
    let calls = [];
    let streamError = null;
    const split = createThinkSplitter(
      (t) => {
        content += t;
        h.emit({ type: 'text', delta: t });
      },
      (t) => h.emit({ type: 'thinking', delta: t }),
    );
    // Providers report mid-stream failures (e.g. Groq's tool_use_failed) as an error payload.
    const feed = createSseParser((j) => {
      if (j.error) {
        streamError ??= toProviderError(cfg, 0, JSON.stringify(j));
        return;
      }
      const d = j.choices?.[0]?.delta;
      if (!d) return;
      const reasoning = d.reasoning ?? d.reasoning_content;
      if (reasoning) h.emit({ type: 'thinking', delta: reasoning });
      if (d.content) split(d.content);
      if (d.tool_calls) calls = mergeToolCallDelta(calls, d.tool_calls);
    });
    const decoder = new TextDecoder();
    try {
      for await (const chunk of res.body) feed(decoder.decode(chunk, { stream: true }));
      feed('\n');
    } catch (e) {
      if (h.signal.aborted) throw Object.assign(new Error('Stopped.'), { aborted: true });
      throw new ProviderError(`${cfg.label} connection dropped: ${e.message}`, 'other');
    }
    if (streamError) throw streamError;
    calls = calls.filter(Boolean).map((c, i) => ({ ...c, id: c.id || `call_${Date.now()}_${i}` }));
    if (!content && !calls.length) throw new ProviderError(`${cfg.label} returned an empty reply from "${cfg.model}".`, 'empty');
    return { content, calls };
  }

  async pickModel(cfg, avoid) {
    const models = await fetchModels(cfg);
    const next = models.find((m) => m !== avoid);
    if (!next) throw new ProviderError(`${cfg.label} has no chat models with tool support available for this key.`, 'model');
    cfg.model = next;
    cfg.onModelChange?.(next);
    return next;
  }

  async send(text, h) {
    const cfg = { ...this.getConfig() };
    if (cfg.needsKey && !cfg.apiKey) {
      throw new Error(`Add your free ${cfg.label} API key in Settings (get one at ${cfg.keyUrl}).`);
    }
    if (!cfg.model && cfg.needsKey) {
      const m = await this.pickModel(cfg);
      h.emit({ type: 'notice', text: `Using ${cfg.label} model ${m}` });
    }
    this.history.push({ role: 'user', content: text });

    let switched = false;
    let toolRetries = 0;
    let useTools = true;
    for (let turn = 0; turn < MAX_TURNS; turn++) {
      let reply;
      try {
        reply = await this.streamTurn(cfg, h, useTools);
      } catch (e) {
        if (e.aborted) throw e;
        h.emit({ type: 'retract' }); // drop any partial text from the failed attempt
        if ((e.kind === 'tool' && toolRetries < 2) || (e.kind === 'empty' && toolRetries < 1)) {
          toolRetries++;
          turn--;
          continue;
        }
        if ((e.kind === 'model' || e.kind === 'empty') && !switched && cfg.needsKey) {
          switched = true;
          const failed = cfg.model;
          const m = await this.pickModel(cfg, failed);
          h.emit({ type: 'notice', text: `"${failed}" isn't working on ${cfg.label}, switched to ${m}.` });
          turn--;
          continue;
        }
        if (e.kind === 'tool' && useTools) {
          useTools = false;
          h.emit({ type: 'notice', text: `${cfg.model} keeps fumbling tool calls, so it's answering without tools. Pick a stronger model in Settings for full control.` });
          turn--;
          continue;
        }
        throw e;
      }
      toolRetries = 0;
      const { content, calls } = reply;
      this.history.push({
        role: 'assistant',
        content: content || null,
        ...(calls.length
          ? { tool_calls: calls.map((c) => ({ id: c.id, type: 'function', function: { name: c.name, arguments: c.arguments || '{}' } })) }
          : {}),
      });
      if (!calls.length) return;

      for (const c of calls) {
        let result;
        if (h.signal.aborted) {
          result = { content: 'Cancelled by the user.', isError: true };
        } else {
          let input;
          try {
            input = JSON.parse(c.arguments || '{}');
          } catch {
            input = undefined;
          }
          result =
            input === undefined
              ? { content: JSON.stringify({ INVALID_JSON: c.arguments }), isError: true }
              : await executeTool(c.name, input, h.toolCtx(c.id));
          h.emit({ type: 'tool-result', id: c.id, content: result.content, isError: result.isError });
        }
        this.history.push({ role: 'tool', tool_call_id: c.id, content: result.content });
      }
      if (h.signal.aborted) return;
    }
    h.emit({ type: 'notice', text: `Stopped after ${MAX_TURNS} steps.` });
  }
}

// Quick end-to-end check used by Settings → Test: a short chat request with tools attached.
async function testConnection(cfg) {
  const models = cfg.needsKey ? await fetchModels(cfg) : [];
  const model = cfg.model || models[0];
  if (!model) throw new Error(`${cfg.label} has no chat models with tool support for this key.`);
  const res = await fetch(`${cfg.baseUrl.replace(/\/$/, '')}/chat/completions`, {
    method: 'POST',
    headers: authHeaders(cfg),
    signal: AbortSignal.timeout(60000),
    body: JSON.stringify({ model, max_tokens: 400, messages: [{ role: 'user', content: 'Reply with just: OK' }], tools: openAiTools() }),
  }).catch((e) => {
    throw new ProviderError(cfg.offlineHint || `Could not reach ${cfg.label}: ${e.message}`, 'other');
  });
  if (!res.ok) throw toProviderError({ ...cfg, model }, res.status, await res.text().catch(() => ''));
  return { model, models };
}

async function listOllamaModels(url) {
  try {
    const r = await fetch(`${url.replace(/\/$/, '')}/api/tags`, { signal: AbortSignal.timeout(2000) });
    const j = await r.json();
    return { running: true, models: (j.models || []).map((m) => m.name) };
  } catch {
    return { running: false, models: [] };
  }
}

module.exports = {
  OpenAICompatEngine,
  createSseParser,
  createThinkSplitter,
  mergeToolCallDelta,
  listOllamaModels,
  rankChatModels,
  fetchModels,
  testConnection,
  toProviderError,
};
