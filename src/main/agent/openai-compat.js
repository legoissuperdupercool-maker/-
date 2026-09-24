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

class OpenAICompatEngine {
  // getConfig() -> { baseUrl, apiKey, model, label, needsKey, offlineHint }
  constructor(getConfig) {
    this.getConfig = getConfig;
    this.history = [];
  }

  reset() {
    this.history = [];
  }

  async request(cfg, signal) {
    const headers = { 'Content-Type': 'application/json' };
    if (cfg.apiKey) headers.Authorization = `Bearer ${cfg.apiKey}`;
    if (cfg.baseUrl.includes('openrouter.ai')) {
      headers['HTTP-Referer'] = 'https://github.com/forge-app';
      headers['X-Title'] = 'Forge';
    }
    let res;
    try {
      res = await fetch(`${cfg.baseUrl.replace(/\/$/, '')}/chat/completions`, {
        method: 'POST',
        headers,
        signal,
        body: JSON.stringify({
          model: cfg.model,
          stream: true,
          messages: [{ role: 'system', content: systemPrompt() }, ...this.history],
          tools: openAiTools(),
        }),
      });
    } catch (e) {
      if (signal.aborted) throw Object.assign(new Error('Stopped.'), { aborted: true });
      throw new Error(cfg.offlineHint || `Could not reach ${cfg.label}: ${e.message}`);
    }
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      let msg = body;
      try {
        const j = JSON.parse(body);
        msg = j.error?.message || j.error || j.message || body;
        if (Array.isArray(j) && j[0]?.error) msg = j[0].error.message;
      } catch {
        // plain-text error body
      }
      if (res.status === 401 || res.status === 403) throw new Error(`${cfg.label} rejected the API key. Check it in Settings.`);
      if (res.status === 429) throw new Error(`${cfg.label} free-tier rate limit hit. Wait a minute, or switch engine.`);
      if (res.status === 404 && cfg.pullHint) throw new Error(cfg.pullHint);
      throw new Error(`${cfg.label} error ${res.status}: ${String(msg).slice(0, 300)}`);
    }
    return res;
  }

  async send(text, h) {
    const cfg = this.getConfig();
    if (cfg.needsKey && !cfg.apiKey) {
      throw new Error(`Add your free ${cfg.label} API key in Settings (get one at ${cfg.keyUrl}).`);
    }
    this.history.push({ role: 'user', content: text });

    for (let turn = 0; turn < MAX_TURNS; turn++) {
      const res = await this.request(cfg, h.signal);
      let content = '';
      let calls = [];
      const split = createThinkSplitter(
        (t) => {
          content += t;
          h.emit({ type: 'text', delta: t });
        },
        (t) => h.emit({ type: 'thinking', delta: t }),
      );
      const feed = createSseParser((j) => {
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
      } catch (e) {
        if (h.signal.aborted) throw Object.assign(new Error('Stopped.'), { aborted: true });
        throw e;
      }

      calls = calls.filter(Boolean).map((c, i) => ({ ...c, id: c.id || `call_${Date.now()}_${i}` }));
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
        this.history.push({ role: 'tool', tool_call_id: c.id, name: c.name, content: result.content });
      }
      if (h.signal.aborted) return;
    }
    h.emit({ type: 'notice', text: `Stopped after ${MAX_TURNS} steps.` });
  }
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

module.exports = { OpenAICompatEngine, createSseParser, createThinkSplitter, mergeToolCallDelta, listOllamaModels };
