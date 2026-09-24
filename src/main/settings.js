'use strict';
const fs = require('fs');
const path = require('path');

// Free cloud providers that speak the OpenAI-compatible chat completions API.
const FREE_PRESETS = {
  groq: {
    label: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    model: 'llama-3.3-70b-versatile',
    keyUrl: 'https://console.groq.com/keys',
  },
  openrouter: {
    label: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    model: 'meta-llama/llama-3.3-70b-instruct:free',
    keyUrl: 'https://openrouter.ai/keys',
  },
  gemini: {
    label: 'Google Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    model: 'gemini-2.5-flash',
    keyUrl: 'https://aistudio.google.com/apikey',
  },
};

const DEFAULTS = {
  provider: 'free', // 'claude' (paid API), 'free' (free cloud API) or 'ollama' (local)
  claudeModel: 'claude-opus-5',
  freePreset: 'groq',
  freeModel: FREE_PRESETS.groq.model,
  ollamaUrl: 'http://127.0.0.1:11434',
  ollamaModel: 'qwen3:8b',
  autoApproveReadOnly: true,
  secrets: {}, // name -> { enc: base64 } (OS keychain) or { plain: string } (no keychain available)
};

const SECRET_NAMES = ['claude', 'groq', 'openrouter', 'gemini'];

// Persists settings as JSON in the app's userData directory. API keys are encrypted
// with the OS keychain (Electron safeStorage) whenever the platform supports it.
class Settings {
  constructor(dir, safeStorage) {
    this.file = path.join(dir, 'settings.json');
    this.safeStorage = safeStorage;
    this.data = structuredClone(DEFAULTS);
    try {
      Object.assign(this.data, JSON.parse(fs.readFileSync(this.file, 'utf8')));
    } catch {
      // first run or unreadable file: keep defaults
    }
  }

  save() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    fs.writeFileSync(this.file, JSON.stringify(this.data, null, 2), { mode: 0o600 });
  }

  getSecret(name) {
    const s = this.data.secrets[name];
    if (!s) return null;
    if (s.enc) {
      try {
        return this.safeStorage.decryptString(Buffer.from(s.enc, 'base64'));
      } catch {
        return null;
      }
    }
    return s.plain || null;
  }

  setSecret(name, value) {
    if (!SECRET_NAMES.includes(name)) throw new Error(`unknown secret ${name}`);
    if (!value) delete this.data.secrets[name];
    else if (this.safeStorage?.isEncryptionAvailable()) {
      this.data.secrets[name] = { enc: this.safeStorage.encryptString(value).toString('base64') };
    } else {
      this.data.secrets[name] = { plain: value };
    }
  }

  claudeKey() {
    return this.getSecret('claude') || process.env.ANTHROPIC_API_KEY || null;
  }

  freeConfig() {
    const preset = FREE_PRESETS[this.data.freePreset] || FREE_PRESETS.groq;
    return {
      ...preset,
      model: this.data.freeModel || preset.model,
      apiKey: this.getSecret(this.data.freePreset),
    };
  }

  // What the renderer is allowed to see: which keys exist, never the keys themselves.
  public() {
    const { secrets, ...rest } = this.data;
    const hasKey = Object.fromEntries(SECRET_NAMES.map((n) => [n, Boolean(this.getSecret(n))]));
    if (process.env.ANTHROPIC_API_KEY) hasKey.claude = true;
    return { ...rest, hasKey, freePresets: FREE_PRESETS };
  }

  update(patch) {
    for (const k of Object.keys(DEFAULTS)) {
      if (k !== 'secrets' && k in patch) this.data[k] = patch[k];
    }
    for (const [name, value] of Object.entries(patch.keys || {})) this.setSecret(name, value);
    this.save();
    return this.public();
  }
}

module.exports = { Settings, DEFAULTS, FREE_PRESETS };
