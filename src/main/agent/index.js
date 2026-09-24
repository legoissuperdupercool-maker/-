'use strict';
const { ClaudeEngine } = require('./claude');
const { OpenAICompatEngine } = require('./openai-compat');

// Routes chat messages to the selected engine and brokers tool approvals with the UI.
class Agent {
  constructor(settings, emit) {
    this.settings = settings;
    this.emit = emit;
    this.pending = new Map(); // approval id -> resolve
    this.controller = null;
    this.engines = {
      claude: new ClaudeEngine(settings),
      free: new OpenAICompatEngine(() => ({ ...settings.freeConfig(), needsKey: true })),
      ollama: new OpenAICompatEngine(() => {
        const url = settings.data.ollamaUrl.replace(/\/$/, '');
        const model = settings.data.ollamaModel;
        return {
          label: 'Ollama',
          baseUrl: `${url}/v1`,
          model,
          apiKey: null,
          needsKey: false,
          offlineHint: `Ollama isn't running at ${url}. Install it from ollama.com (or one-click it in the App Store), then run: ollama pull ${model}`,
          pullHint: `Model "${model}" isn't downloaded yet. Run: ollama pull ${model}`,
        };
      }),
    };
  }

  get busy() {
    return this.controller !== null;
  }

  reset() {
    this.stop();
    for (const e of Object.values(this.engines)) e.reset();
  }

  stop() {
    this.controller?.abort();
    for (const resolve of this.pending.values()) resolve(false);
    this.pending.clear();
  }

  resolveApproval(id, approved) {
    this.pending.get(id)?.(approved);
    this.pending.delete(id);
  }

  async send(text) {
    if (this.busy) throw new Error('Forge is still working on the last message.');
    const provider = this.settings.data.provider;
    const engine = this.engines[provider];
    if (!engine) throw new Error(`Unknown engine ${provider}`);
    const controller = (this.controller = new AbortController());
    const emit = this.emit;
    const h = {
      signal: controller.signal,
      emit,
      toolCtx: (id) => ({
        signal: controller.signal,
        autoApproveReadOnly: this.settings.data.autoApproveReadOnly,
        approve: (info) =>
          new Promise((resolve) => {
            if (controller.signal.aborted) return resolve(false);
            this.pending.set(id, (ok) => {
              emit({ type: 'tool-approval', id, approved: ok });
              resolve(ok);
            });
            emit({ type: 'tool-call', id, needsApproval: true, ...info });
          }),
        notify: (info) => emit({ type: 'tool-call', id, needsApproval: false, ...info }),
        progress: (text) => emit({ type: 'tool-progress', id, text }),
      }),
    };
    emit({ type: 'start', provider });
    try {
      await engine.send(text, h);
    } catch (e) {
      if (!e.aborted && !controller.signal.aborted) emit({ type: 'error', text: e.message });
    } finally {
      this.controller = null;
      emit({ type: 'done', stopped: controller.signal.aborted });
    }
  }
}

module.exports = { Agent };
