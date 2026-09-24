'use strict';
// Drives both engines against fake streaming servers: turn 1 asks for a tool,
// turn 2 answers. Verifies streaming, approval, tool execution and history shape.
const test = require('node:test');
const assert = require('node:assert');
const http = require('http');

function fakeServer(handler) {
  return new Promise((resolve) => {
    const bodies = [];
    const srv = http.createServer((req, res) => {
      let b = '';
      req.on('data', (c) => (b += c));
      req.on('end', () => {
        const body = JSON.parse(b);
        bodies.push({ url: req.url, headers: req.headers, body });
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        handler(bodies.length, res);
      });
    });
    srv.listen(0, '127.0.0.1', () => resolve({ srv, bodies, url: `http://127.0.0.1:${srv.address().port}` }));
  });
}

function harness() {
  const events = [];
  return {
    events,
    h: {
      signal: new AbortController().signal,
      emit: (e) => events.push(e),
      toolCtx: (id) => ({
        signal: new AbortController().signal,
        autoApproveReadOnly: true,
        approve: async (info) => (events.push({ type: 'approval', id, ...info }), true),
        notify: (info) => events.push({ type: 'tool-call', id, ...info }),
        progress: () => {},
      }),
    },
  };
}

test('OpenAI-compatible engine: tool call then answer', async () => {
  const { OpenAICompatEngine } = require('../src/main/agent/openai-compat');
  const { srv, bodies, url } = await fakeServer((n, res) => {
    const send = (o) => res.write(`data: ${JSON.stringify(o)}\n\n`);
    if (n === 1) {
      send({ choices: [{ delta: { content: '<think>check</think>Running it.' } }] });
      send({ choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_1', function: { name: 'run_command', arguments: '{"command":"echo hi-from-tool",' } }] } }] });
      send({ choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: '"reason":"test"}' } }] } }] });
    } else {
      send({ choices: [{ delta: { content: 'All done.' } }] });
    }
    res.end('data: [DONE]\n\n');
  });
  const engine = new OpenAICompatEngine(() => ({ label: 'Fake', baseUrl: url, model: 'm', apiKey: 'k', needsKey: true }));
  const { events, h } = harness();
  await engine.send('say hi', h);
  srv.close();

  assert.strictEqual(bodies.length, 2);
  assert.strictEqual(bodies[0].headers.authorization, 'Bearer k');
  assert.ok(bodies[0].body.tools.some((t) => t.function.name === 'run_command'));
  const text = events.filter((e) => e.type === 'text').map((e) => e.delta).join('');
  assert.strictEqual(text, 'Running it.All done.');
  assert.ok(events.some((e) => e.type === 'thinking' && e.delta === 'check'));
  assert.ok(events.some((e) => e.type === 'approval' && e.detail === 'echo hi-from-tool'));
  const result = events.find((e) => e.type === 'tool-result');
  assert.match(result.content, /hi-from-tool/);
  const toolMsg = bodies[1].body.messages.find((m) => m.role === 'tool');
  assert.strictEqual(toolMsg.tool_call_id, 'call_1');
  assert.strictEqual(toolMsg.name, 'run_command'); // gpt-oss/harmony templates need it
  assert.deepStrictEqual(engine.history.map((m) => m.role), ['user', 'assistant', 'tool', 'assistant']);
});

test('OpenAI-compatible engine: friendly errors', async () => {
  const { OpenAICompatEngine } = require('../src/main/agent/openai-compat');
  const srv = http.createServer((req, res) => {
    res.writeHead(401, { 'content-type': 'application/json' });
    res.end('{"error":{"message":"bad key"}}');
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const engine = new OpenAICompatEngine(() => ({ label: 'Groq', baseUrl: `http://127.0.0.1:${srv.address().port}`, model: 'm', apiKey: 'k', needsKey: true }));
  await assert.rejects(engine.send('x', harness().h), /Groq rejected the API key/);
  srv.close();
  const noKey = new OpenAICompatEngine(() => ({ label: 'Groq', baseUrl: 'http://x', model: 'm', apiKey: null, needsKey: true, keyUrl: 'https://k' }));
  await assert.rejects(noKey.send('x', harness().h), /Add your free Groq API key/);
  const offline = new OpenAICompatEngine(() => ({ label: 'Ollama', baseUrl: 'http://127.0.0.1:1', model: 'm', offlineHint: 'Ollama isn\'t running' }));
  await assert.rejects(offline.send('x', harness().h), /Ollama isn't running/);
});

test('Claude engine: streamed tool_use, approval, tool_result, final answer', async () => {
  const { srv, bodies, url } = await fakeServer((n, res) => {
    const ev = (type, data) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
    const msg = { id: `msg_${n}`, type: 'message', role: 'assistant', model: 'claude-opus-5', content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 0 } };
    ev('message_start', { message: msg });
    if (n === 1) {
      ev('content_block_start', { index: 0, content_block: { type: 'thinking', thinking: '', signature: '' } });
      ev('content_block_delta', { index: 0, delta: { type: 'thinking_delta', thinking: 'Need stats.' } });
      ev('content_block_delta', { index: 0, delta: { type: 'signature_delta', signature: 'sig' } });
      ev('content_block_stop', { index: 0 });
      ev('content_block_start', { index: 1, content_block: { type: 'tool_use', id: 'toolu_1', name: 'container_action', input: {} } });
      ev('content_block_delta', { index: 1, delta: { type: 'input_json_delta', partial_json: '{"container":"mc",' } });
      ev('content_block_delta', { index: 1, delta: { type: 'input_json_delta', partial_json: '"action":"restart"}' } });
      ev('content_block_stop', { index: 1 });
      ev('message_delta', { delta: { stop_reason: 'tool_use', stop_sequence: null }, usage: { output_tokens: 20 } });
    } else {
      ev('content_block_start', { index: 0, content_block: { type: 'text', text: '' } });
      ev('content_block_delta', { index: 0, delta: { type: 'text_delta', text: 'Restart attempted.' } });
      ev('content_block_stop', { index: 0 });
      ev('message_delta', { delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 5 } });
    }
    ev('message_stop', {});
    res.end();
  });
  process.env.ANTHROPIC_BASE_URL = url;
  const { ClaudeEngine } = require('../src/main/agent/claude');
  const settings = { data: { claudeModel: 'claude-opus-5' }, claudeKey: () => 'sk-test' };
  const engine = new ClaudeEngine(settings);
  const { events, h } = harness();
  await engine.send('restart mc', h);
  srv.close();
  delete process.env.ANTHROPIC_BASE_URL;

  assert.strictEqual(bodies.length, 2);
  const req = bodies[0];
  assert.strictEqual(req.headers['x-api-key'], 'sk-test');
  assert.match(req.headers['anthropic-beta'], /server-side-fallback-2026-07-01/);
  assert.strictEqual(req.body.fallbacks, 'default');
  assert.deepStrictEqual(req.body.thinking, { type: 'adaptive', display: 'summarized' });
  assert.ok(req.body.tools.every((t) => t.eager_input_streaming === true));
  assert.ok(events.some((e) => e.type === 'thinking' && e.delta === 'Need stats.'));
  assert.ok(events.some((e) => e.type === 'approval' && e.tool === 'container_action' && e.detail === 'mc'));
  // Docker isn't running in tests, so the tool fails, and that error is returned to Claude.
  const second = bodies[1].body.messages;
  const results = second[second.length - 1].content;
  assert.strictEqual(results[0].type, 'tool_result');
  assert.strictEqual(results[0].tool_use_id, 'toolu_1');
  // Thinking block is echoed back unchanged (append-only history).
  assert.strictEqual(second[1].content[0].type, 'thinking');
  assert.strictEqual(second[1].content[0].signature, 'sig');
  assert.strictEqual(events.filter((e) => e.type === 'text').map((e) => e.delta).join(''), 'Restart attempted.');
});
