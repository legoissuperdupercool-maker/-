'use strict';
// Free-engine recovery: model discovery, auto-switching off a broken model, and
// retrying Groq's mid-stream tool_use_failed errors.
const test = require('node:test');
const assert = require('node:assert');
const http = require('http');
const { OpenAICompatEngine, rankChatModels, toProviderError } = require('../src/main/agent/openai-compat');

const GROQ_MODELS = [
  'whisper-large-v3', 'whisper-large-v3-turbo', 'playai-tts', 'meta-llama/llama-guard-4-12b',
  'meta-llama/llama-prompt-guard-2-86m', 'groq/compound', 'groq/compound-mini', 'allam-2-7b',
  'llama-3.1-8b-instant', 'llama-3.3-70b-versatile', 'openai/gpt-oss-120b', 'openai/gpt-oss-20b',
  'qwen/qwen3-32b', 'moonshotai/kimi-k2-instruct',
].map((id) => ({ id, object: 'model' }));

test('non-chat models are filtered out and the best tool model comes first', () => {
  const r = rankChatModels(GROQ_MODELS);
  assert.deepStrictEqual(r, ['openai/gpt-oss-120b', 'llama-3.3-70b-versatile', 'moonshotai/kimi-k2-instruct', 'qwen/qwen3-32b', 'openai/gpt-oss-20b', 'llama-3.1-8b-instant']);
  assert.deepStrictEqual(rankChatModels([{ id: 'models/gemini-2.5-flash' }, { id: 'models/text-embedding-004' }, { id: 'models/gemini-2.5-flash-preview-tts' }]), ['gemini-2.5-flash']);
  assert.deepStrictEqual(rankChatModels([{ id: 'a:free', supported_parameters: ['tools'] }, { id: 'b:free', supported_parameters: ['temperature'] }]), ['a:free']);
});

test('provider errors are classified', () => {
  const cfg = { label: 'Groq', model: 'whisper-large-v3' };
  assert.strictEqual(toProviderError(cfg, 400, '{"error":{"message":"The model `whisper-large-v3` does not support chat completions","type":"invalid_request_error"}}').kind, 'model');
  assert.strictEqual(toProviderError(cfg, 400, '{"error":{"message":"The model `x` has been decommissioned","code":"model_decommissioned"}}').kind, 'model');
  assert.strictEqual(toProviderError(cfg, 404, '{"error":{"message":"The model `x` does not exist or you do not have access to it.","code":"model_not_found"}}').kind, 'model');
  assert.strictEqual(toProviderError(cfg, 400, '{"error":{"message":"Failed to call a function. Please adjust your prompt.","code":"tool_use_failed"}}').kind, 'tool');
  assert.strictEqual(toProviderError(cfg, 401, '{"error":{"message":"Invalid API Key","code":"invalid_api_key"}}').kind, 'auth');
  assert.strictEqual(toProviderError(cfg, 429, '{}').kind, 'rate');
  assert.strictEqual(toProviderError(cfg, 400, '{"error":{"message":"failed to template request: failed to render tokenized output: failed to render tokens with harmony: HarmonyError: EncodingError: Message=render failed: Tools should have a name!"}}').kind, 'model');
});

// Fake Groq: /models lists GROQ_MODELS; chat behaviour is scripted per call.
function fakeGroq(script) {
  const calls = [];
  const srv = http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/models') {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ object: 'list', data: GROQ_MODELS }));
    }
    let b = '';
    req.on('data', (c) => (b += c));
    req.on('end', () => {
      const body = JSON.parse(b);
      calls.push(body);
      script(calls.length, body, res);
    });
  });
  return new Promise((r) => srv.listen(0, '127.0.0.1', () => r({ srv, calls, url: `http://127.0.0.1:${srv.address().port}` })));
}

function sse(res, ...objs) {
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  for (const o of objs) res.write(`data: ${JSON.stringify(o)}\n\n`);
  res.end('data: [DONE]\n\n');
}

function harness() {
  const events = [];
  return {
    events,
    h: {
      signal: new AbortController().signal,
      emit: (e) => events.push(e),
      toolCtx: () => ({ signal: new AbortController().signal, autoApproveReadOnly: true, approve: async () => true, notify: () => {}, progress: () => {} }),
    },
  };
}

test('auto model: picks the best model when none is set', async () => {
  const { srv, calls, url } = await fakeGroq((n, body, res) => sse(res, { choices: [{ delta: { content: 'hi' } }] }));
  let saved = null;
  const engine = new OpenAICompatEngine(() => ({ label: 'Groq', baseUrl: url, apiKey: 'k', model: '', needsKey: true, onModelChange: (m) => (saved = m) }));
  const { events, h } = harness();
  await engine.send('hello', h);
  srv.close();
  assert.strictEqual(calls[0].model, 'openai/gpt-oss-120b');
  assert.strictEqual(saved, 'openai/gpt-oss-120b');
  assert.ok(events.some((e) => e.type === 'notice' && /openai\/gpt-oss-120b/.test(e.text)));
});

test('a model that cannot chat is replaced automatically', async () => {
  const { srv, calls, url } = await fakeGroq((n, body, res) => {
    if (body.model === 'whisper-large-v3') {
      res.writeHead(400, { 'content-type': 'application/json' });
      return res.end('{"error":{"message":"The model `whisper-large-v3` does not support chat completions","type":"invalid_request_error"}}');
    }
    sse(res, { choices: [{ delta: { content: 'working now' } }] });
  });
  let saved = null;
  const engine = new OpenAICompatEngine(() => ({ label: 'Groq', baseUrl: url, apiKey: 'k', model: 'whisper-large-v3', needsKey: true, onModelChange: (m) => (saved = m) }));
  const { events, h } = harness();
  await engine.send('hello', h);
  srv.close();
  assert.deepStrictEqual(calls.map((c) => c.model), ['whisper-large-v3', 'openai/gpt-oss-120b']);
  assert.strictEqual(saved, 'openai/gpt-oss-120b');
  assert.ok(events.some((e) => e.type === 'retract'));
  assert.strictEqual(events.filter((e) => e.type === 'text').map((e) => e.delta).join(''), 'working now');
});

test('mid-stream tool_use_failed is retried instead of silently ending', async () => {
  const { srv, calls, url } = await fakeGroq((n, body, res) => {
    if (n === 1) {
      return sse(res, { choices: [{ delta: { content: 'Let me ' } }] }, { error: { message: 'Failed to call a function. Please adjust your prompt.', type: 'invalid_request_error', code: 'tool_use_failed' } });
    }
    sse(res, { choices: [{ delta: { content: 'Answer.' } }] });
  });
  const engine = new OpenAICompatEngine(() => ({ label: 'Groq', baseUrl: url, apiKey: 'k', model: 'llama-3.3-70b-versatile', needsKey: true }));
  const { events, h } = harness();
  await engine.send('hello', h);
  srv.close();
  assert.strictEqual(calls.length, 2);
  assert.ok(calls.every((c) => Array.isArray(c.tools)));
  const idxRetract = events.findIndex((e) => e.type === 'retract');
  const after = events.slice(idxRetract + 1).filter((e) => e.type === 'text').map((e) => e.delta).join('');
  assert.strictEqual(after, 'Answer.');
});

test('a model that keeps failing tool calls falls back to answering without tools', async () => {
  const { srv, calls, url } = await fakeGroq((n, body, res) => {
    if (body.tools) {
      res.writeHead(400, { 'content-type': 'application/json' });
      return res.end('{"error":{"message":"Failed to call a function.","code":"tool_use_failed"}}');
    }
    sse(res, { choices: [{ delta: { content: 'plain answer' } }] });
  });
  const engine = new OpenAICompatEngine(() => ({ label: 'Groq', baseUrl: url, apiKey: 'k', model: 'llama-3.1-8b-instant', needsKey: true }));
  const { events, h } = harness();
  await engine.send('hello', h);
  srv.close();
  assert.strictEqual(calls.length, 4); // 1 try + 2 retries with tools, then 1 without
  assert.ok(!calls[3].tools);
  assert.ok(events.some((e) => e.type === 'notice' && /without tools/.test(e.text)));
});

test('a bad key gives a clear message', async () => {
  const { srv, url } = await fakeGroq((n, body, res) => {
    res.writeHead(401, { 'content-type': 'application/json' });
    res.end('{"error":{"message":"Invalid API Key","type":"invalid_request_error","code":"invalid_api_key"}}');
  });
  const engine = new OpenAICompatEngine(() => ({ label: 'Groq', baseUrl: url, apiKey: 'bad', model: 'llama-3.3-70b-versatile', needsKey: true }));
  await assert.rejects(engine.send('hello', harness().h), /Groq rejected the API key/);
  srv.close();
});
