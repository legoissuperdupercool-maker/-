'use strict';
const Anthropic = require('@anthropic-ai/sdk');
const { anthropicTools, executeTool, systemPrompt } = require('./tools');

const MAX_TURNS = 30;

// Claude via the Anthropic API: streamed manual tool loop so every action can be
// shown and approved in the UI. History is append-only (thinking blocks stay valid).
class ClaudeEngine {
  constructor(settings) {
    this.settings = settings;
    this.history = [];
  }

  reset() {
    this.history = [];
  }

  async send(text, h) {
    const apiKey = this.settings.claudeKey();
    if (!apiKey) throw new Error('Add your Anthropic API key in Settings to use Claude (or switch to a free engine).');
    const client = new Anthropic({ apiKey });
    const model = this.settings.data.claudeModel || 'claude-opus-5';
    const tools = anthropicTools();
    const system = [{ type: 'text', text: systemPrompt(), cache_control: { type: 'ephemeral' } }];
    // Server-side refusal fallback: declined requests are re-run on the recommended model.
    const fallback = model === 'claude-opus-5' ? { betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default' } : {};

    this.history.push({ role: 'user', content: text });
    let jsonRetries = 0;

    for (let turn = 0; turn < MAX_TURNS; turn++) {
      const stream = client.beta.messages.stream(
        {
          model,
          max_tokens: 64000,
          thinking: { type: 'adaptive', display: 'summarized' },
          output_config: { effort: 'high' },
          system,
          tools,
          messages: this.history,
          ...fallback,
        },
        { signal: h.signal },
      );
      stream.on('text', (delta) => h.emit({ type: 'text', delta }));
      stream.on('thinking', (delta) => h.emit({ type: 'thinking', delta }));

      let message;
      try {
        message = await stream.finalMessage();
        jsonRetries = 0;
      } catch (err) {
        // Only an unparseable streamed tool input is retried; API errors and aborts propagate.
        if (err instanceof Anthropic.APIError || h.signal.aborted || jsonRetries++ >= 2) throw friendly(err);
        h.emit({ type: 'notice', text: 'Tool input was garbled, retrying…' });
        continue;
      }

      if (message.stop_reason === 'refusal') {
        h.emit({ type: 'notice', text: 'Claude declined this request.' });
        return;
      }
      if (message.stop_reason === 'pause_turn') {
        this.history.push({ role: 'assistant', content: message.content });
        continue;
      }

      const toolUses = message.content.filter((b) => b.type === 'tool_use');
      if (toolUses.length === 0) {
        this.history.push({ role: 'assistant', content: message.content });
        return;
      }
      if (message.stop_reason === 'max_tokens') {
        h.emit({ type: 'notice', text: 'Response was cut off before a tool call finished.' });
        return;
      }

      this.history.push({ role: 'assistant', content: message.content });
      const results = [];
      for (const use of toolUses) {
        if (h.signal.aborted) {
          results.push({ type: 'tool_result', tool_use_id: use.id, content: 'Cancelled by the user.', is_error: true });
          continue;
        }
        const r = await executeTool(use.name, use.input, h.toolCtx(use.id));
        h.emit({ type: 'tool-result', id: use.id, content: r.content, isError: r.isError });
        results.push({ type: 'tool_result', tool_use_id: use.id, content: r.content, is_error: r.isError });
      }
      // All results for one assistant turn go back in a single user message.
      this.history.push({ role: 'user', content: results });
      if (h.signal.aborted) return;
    }
    h.emit({ type: 'notice', text: `Stopped after ${MAX_TURNS} steps.` });
  }
}

function friendly(err) {
  if (err instanceof Anthropic.AuthenticationError) return new Error('Your Anthropic API key was rejected. Check it in Settings.');
  if (err instanceof Anthropic.RateLimitError) return new Error('Claude rate limit hit. Wait a moment and try again.');
  if (err instanceof Anthropic.APIUserAbortError) return Object.assign(new Error('Stopped.'), { aborted: true });
  if (err instanceof Anthropic.APIConnectionError) return new Error('Could not reach the Anthropic API. Check your internet connection.');
  if (err instanceof Anthropic.APIError) return new Error(`Claude API error ${err.status ?? ''}: ${err.message}`);
  return err;
}

module.exports = { ClaudeEngine };
