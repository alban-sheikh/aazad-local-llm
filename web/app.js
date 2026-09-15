'use strict';

// ---------- constants
const OLLAMA = '/ollama';
const APP_NAME = 'Aazad Chat';
const HEADERS = { 'Content-Type': 'application/json', 'X-Aazad-Chat': '1' };
const DEFAULT_MODEL = 'llama3.2:3b';
const SUGGESTED = [
  ['llama3.2:3b', '2 GB · fastest'],
  ['gemma3:4b', '3.3 GB · images'],
  ['qwen2.5-coder:7b', '4.7 GB · code'],
  ['llama3.1:8b', '4.9 GB · general'],
  ['qwen3:8b', '5.2 GB · reasoning'],
  ['deepseek-r1:8b', '5.2 GB · reasoning'],
  ['nomic-embed-text', '274 MB · embeddings'],
];
const STARTERS = [
  'Explain how HTTP works in simple terms',
  'Write a Python function that checks if a string is a palindrome, with tests',
  'Give me 5 weekend project ideas that use a local LLM',
  'What is 17 × 23? Show your steps',
];
const NEW_TITLE = 'New chat';

const state = {
  chats: [],            // summaries: {id, title, model, created, updated, message_count}
  found: null,          // ids of chats matching the search, from the server
  defaults: {},         // settings for new chats
  chat: null,           // the open chat
  models: [],           // /api/tags
  loaded: new Map(),    // name -> /api/ps entry
  info: new Map(),      // name -> {caps, details, ctx}
  attachments: [],      // images waiting to be sent
  controller: null,     // AbortController for the reply being generated
  streaming: false,
  pullController: null,
};
const ui = {};

// ---------- small helpers
function h(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value == null || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat()) {
    if (child == null || child === false) continue;
    node.append(child.nodeType ? child : String(child));
  }
  return node;
}

const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
const fmtSize = bytes => (bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : `${Math.round(bytes / 1e6)} MB`);
const fmtSec = s => (s < 10 ? `${s.toFixed(1)}s` : `${Math.round(s)}s`);
const rate = (count, ns) => (count && ns ? count / (ns / 1e9) : 0);
const gpuPct = p => (p.size ? Math.round((100 * (p.size_vram || 0)) / p.size) : 0);
const hasCap = (name, cap) => !!state.info.get(name)?.caps.includes(cap);
const isNarrow = () => matchMedia('(max-width: 800px)').matches;

function debounce(fn, ms) {
  let timer;
  return (...args) => { clearTimeout(timer); timer = setTimeout(() => fn(...args), ms); };
}

function relTime(t) {
  const s = (Date.now() - t) / 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  if (s < 604800) return `${Math.floor(s / 86400)}d ago`;
  return new Date(t).toLocaleDateString();
}

function mimeOf(b64) {
  if (b64.startsWith('/9j/')) return 'image/jpeg';
  if (b64.startsWith('iVBOR')) return 'image/png';
  if (b64.startsWith('R0lG')) return 'image/gif';
  if (b64.startsWith('UklG')) return 'image/webp';
  return 'image/png';
}

const store = {
  get(key, fallback) {
    try { const v = localStorage.getItem(key); return v == null ? fallback : JSON.parse(v); } catch { return fallback; }
  },
  set(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* storage unavailable */ }
  },
};

// ---------- network
async function request(path, { method = 'GET', body, signal } = {}) {
  const res = await fetch(path, {
    method, headers: HEADERS, signal,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) {
    let message = `${res.status} ${res.statusText}`;
    try { const j = await res.json(); if (j.error) message = j.error; } catch { /* not JSON */ }
    throw new Error(message);
  }
  return res;
}
const getJSON = async path => (await request(path)).json();
const sendJSON = async (path, method, body) => (await request(path, { method, body })).json();

async function* readNDJSON(res) {
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let nl;
    while ((nl = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (line) yield JSON.parse(line);
    }
  }
  if (buffer.trim()) yield JSON.parse(buffer);
}

// ---------- theme
function applyTheme() {
  const theme = store.get('aazad.theme', 'auto');
  const dark = theme === 'dark' || (theme === 'auto' && matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  document.getElementById('hljs-light').disabled = dark;
  document.getElementById('hljs-dark').disabled = !dark;
  ui.themeBtn.textContent = `🌓 Theme: ${theme[0].toUpperCase()}${theme.slice(1)}`;
}

function cycleTheme() {
  const order = ['auto', 'light', 'dark'];
  const next = order[(order.indexOf(store.get('aazad.theme', 'auto')) + 1) % order.length];
  store.set('aazad.theme', next);
  applyTheme();
}

// ---------- banner
function showBanner(text, kind = 'warn') {
  ui.banner.textContent = text;
  ui.banner.dataset.kind = kind;
  ui.banner.hidden = false;
  clearTimeout(showBanner.timer);
  if (kind !== 'down') showBanner.timer = setTimeout(hideBanner, 8000);
}
function hideBanner() {
  ui.banner.hidden = true;
  ui.banner.dataset.kind = '';
}

// ---------- markdown
marked.use({ gfm: true, breaks: true });
hljs.configure({ ignoreUnescapedHTML: true });

function renderMarkdown(target, text) {
  target.innerHTML = DOMPurify.sanitize(marked.parse(text));
  for (const a of target.querySelectorAll('a')) {
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
  }
  for (const code of target.querySelectorAll('pre > code')) {
    const declared = (code.className.match(/language-([\w+#-]+)/) || [])[1];
    hljs.highlightElement(code);
    const lang = declared || (code.className.match(/language-([\w+#-]+)/) || [])[1] || 'code';
    code.parentElement.prepend(h('div', { class: 'code-head' },
      h('span', {}, lang),
      h('button', { class: 'copy-code', type: 'button', onclick: e => copyText(code.innerText, e.currentTarget) }, 'Copy')));
  }
}

async function copyText(text, button) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const ta = h('textarea', {}, text);
    document.body.append(ta);
    ta.select();
    document.execCommand('copy');
    ta.remove();
  }
  if (button) {
    const old = button.textContent;
    button.textContent = 'Copied';
    setTimeout(() => { button.textContent = old; }, 1200);
  }
}

// Some models put their reasoning inside <think>…</think> in the reply itself.
function splitThink(msg) {
  let content = msg.content || '';
  let thinking = msg.thinking || '';
  const m = content.match(/^\s*<think>([\s\S]*?)(<\/think>|$)/);
  if (m) {
    thinking += m[1];
    content = m[2] ? content.slice(m[0].length) : '';
  }
  return { content: content.replace(/^\s+/, ''), thinking: thinking.trim() };
}

// ---------- server & models
async function poll() {
  try {
    const version = await getJSON(`${OLLAMA}/api/version`);
    const [tags, ps] = await Promise.all([getJSON(`${OLLAMA}/api/tags`), getJSON(`${OLLAMA}/api/ps`)]);
    state.models = (tags.models || []).sort((a, b) => a.name.localeCompare(b.name));
    state.loaded = new Map((ps.models || []).map(m => [m.name, m]));
    setServer(true, version.version);
  } catch (e) {
    setServer(false, e.message);
  }
  if (state.chat && !state.chat.model && state.models.length) {
    state.chat.model = pickModel();
    await ensureInfo(state.chat.model);
    renderMessages();
    renderComposer();
  }
  renderModelSelect();
  renderModelInfo();
  if (!ui.modelsModal.hidden) renderModelList();
}

async function refreshLoaded() {
  try {
    const ps = await getJSON(`${OLLAMA}/api/ps`);
    state.loaded = new Map((ps.models || []).map(m => [m.name, m]));
  } catch { /* poll() reports outages */ }
  renderModelSelect();
  renderModelInfo();
}

function setServer(ok, detail) {
  ui.serverStatus.className = `status ${ok ? 'ok' : 'down'}`;
  ui.serverStatus.textContent = ok ? 'AI engine online' : 'AI engine offline';
  ui.serverStatus.title = ok ? `Powered by Ollama ${detail} on 127.0.0.1:11434` : `${detail}\nStart it with: systemctl --user start ollama`;
  if (!ok) showBanner('The AI engine is not running. Start it with: systemctl --user start ollama', 'down');
  else if (ui.banner.dataset.kind === 'down') hideBanner();
}

async function ensureInfo(name) {
  if (!name) return undefined;
  if (state.info.has(name)) return state.info.get(name);
  try {
    const r = await sendJSON(`${OLLAMA}/api/show`, 'POST', { model: name });
    const ctxKey = Object.keys(r.model_info || {}).find(k => k.endsWith('.context_length'));
    state.info.set(name, { caps: r.capabilities || [], details: r.details || {}, ctx: ctxKey ? r.model_info[ctxKey] : 0 });
  } catch {
    return undefined;
  }
  return state.info.get(name);
}

function pickModel(preferred) {
  const names = state.models.map(m => m.name);
  if (preferred && names.includes(preferred)) return preferred;
  if (names.includes(DEFAULT_MODEL)) return DEFAULT_MODEL;
  return (names.find(n => !n.includes('embed')) || names[0]) || '';
}

// ---------- chats and settings (saved in the server's database)
async function saveChat(chat, { keepTime = false } = {}) {
  if (!keepTime) chat.updated = Date.now();
  await request(`/api/chats/${chat.id}`, { method: 'PUT', body: chat });
  const summary = { id: chat.id, title: chat.title, model: chat.model, created: chat.created, updated: chat.updated, message_count: chat.messages.length };
  const i = state.chats.findIndex(c => c.id === chat.id);
  if (i >= 0) state.chats[i] = summary; else state.chats.unshift(summary);
  state.chats.sort((a, b) => b.updated - a.updated);
  renderChatList();
}

let defaultsTimer = 0;
function saveDefaults() {
  const c = state.chat;
  state.defaults = { model: c.model, system: c.system, options: { ...c.options }, keep_alive: c.keep_alive, think: c.think };
  clearTimeout(defaultsTimer); // typing a system prompt saves once, not on every key
  defaultsTimer = setTimeout(() => {
    request('/api/settings/defaults', { method: 'PUT', body: state.defaults }).catch(() => {});
  }, 500);
}

// Older versions kept the new-chat defaults in the browser. Move them into the database once.
async function moveBrowserDefaults() {
  const old = store.get('aazad.defaults', null);
  if (!old) return {};
  await request('/api/settings/defaults', { method: 'PUT', body: old });
  try { localStorage.removeItem('aazad.defaults'); } catch { /* storage unavailable */ }
  return old;
}

function blockedWhileStreaming() {
  if (!state.streaming) return false;
  showBanner('Wait for the reply to finish, or press Stop.');
  return true;
}

function newChat() {
  if (blockedWhileStreaming()) return;
  const d = state.defaults;
  const model = pickModel(d.model);
  state.chat = {
    id: uid(), title: NEW_TITLE, model,
    system: d.system || '',
    options: { temperature: 0.7, num_ctx: 0, num_predict: 0, ...(d.options || {}) },
    keep_alive: d.keep_alive || '',
    think: d.think !== false,
    messages: [], created: Date.now(), updated: Date.now(),
  };
  history.replaceState(null, '', location.pathname);
  renderAll();
  ensureInfo(model).then(() => { renderModelInfo(); renderComposer(); });
  closeSidebarOnMobile();
  ui.input.focus();
}

async function openChat(id) {
  if (blockedWhileStreaming()) return;
  try {
    const chat = await getJSON(`/api/chats/${id}`);
    chat.options = { temperature: 0.7, num_ctx: 0, num_predict: 0, ...(chat.options || {}) };
    chat.messages = chat.messages || [];
    state.chat = chat;
    history.replaceState(null, '', `#${id}`);
    await ensureInfo(chat.model);
    renderAll();
    closeSidebarOnMobile();
  } catch (e) {
    showBanner(`Could not open chat: ${e.message}`);
    newChat();
  }
}

function renameChat(item, summary) {
  const input = h('input', { class: 'rename', value: summary.title, 'aria-label': 'Chat title' });
  item.querySelector('.chat-title').replaceWith(input);
  input.addEventListener('click', e => e.stopPropagation());
  input.focus();
  input.select();
  let finished = false;
  const finish = async save => {
    if (finished) return;
    finished = true;
    const title = input.value.trim();
    if (save && title && title !== summary.title) {
      try {
        const chat = state.chat?.id === summary.id ? state.chat : await getJSON(`/api/chats/${summary.id}`);
        chat.title = title;
        await saveChat(chat, { keepTime: true });
        if (state.chat?.id === summary.id) document.title = `${title} · ${APP_NAME}`;
      } catch (e) {
        showBanner(`Rename failed: ${e.message}`);
      }
    }
    renderChatList();
  };
  input.addEventListener('keydown', e => {
    if (e.key === 'Enter') finish(true);
    if (e.key === 'Escape') finish(false);
  });
  input.addEventListener('blur', () => finish(true));
}

async function deleteChat(button, summary) {
  if (button.dataset.confirm !== '1') {
    button.dataset.confirm = '1';
    button.textContent = 'Delete?';
    button.classList.add('danger-text');
    setTimeout(() => {
      if (!button.isConnected) return;
      button.dataset.confirm = '';
      button.textContent = '🗑';
      button.classList.remove('danger-text');
    }, 3000);
    return;
  }
  if (state.chat?.id === summary.id) stop();
  try {
    await request(`/api/chats/${summary.id}`, { method: 'DELETE' });
  } catch (e) {
    return showBanner(`Delete failed: ${e.message}`);
  }
  state.chats = state.chats.filter(c => c.id !== summary.id);
  if (state.chat?.id === summary.id) {
    state.streaming = false;
    newChat();
  } else {
    renderChatList();
  }
}

// ---------- sending & streaming
function historyFor(chat) {
  const out = [];
  if (chat.system && chat.system.trim()) out.push({ role: 'system', content: chat.system });
  for (const m of chat.messages.slice(0, -1)) {
    const content = m.role === 'assistant' ? splitThink(m).content : m.content;
    if (m.role === 'assistant' && (m.error || !content)) continue;
    const item = { role: m.role, content };
    if (m.images?.length) item.images = m.images;
    out.push(item);
  }
  return out;
}

function optionsFor(chat) {
  const o = { temperature: Number(chat.options.temperature) };
  if (Number(chat.options.num_ctx)) o.num_ctx = Number(chat.options.num_ctx);
  if (Number(chat.options.num_predict)) o.num_predict = Number(chat.options.num_predict);
  return o;
}

async function send() {
  if (state.streaming) return;
  const chat = state.chat;
  const text = ui.input.value.trim();
  const images = state.attachments.map(a => a.b64);
  if (!text && !images.length) return;
  if (!chat.model) return showBanner('Choose a model at the top first, or download one in Models.');
  await ensureInfo(chat.model);
  const info = state.info.get(chat.model);
  if (info && !info.caps.includes('completion')) return showBanner(`${chat.model} is an embedding model and can't chat. Pick another model.`);
  if (images.length && !hasCap(chat.model, 'vision')) return showBanner(`${chat.model} can't read images. Switch to a vision model such as gemma3:4b.`);
  hideBanner();

  const message = { role: 'user', content: text };
  if (images.length) message.images = images;
  chat.messages.push(message);
  if (chat.title === NEW_TITLE) chat.title = (text || 'Image').replace(/\s+/g, ' ').slice(0, 60);
  document.title = `${chat.title} · ${APP_NAME}`;
  history.replaceState(null, '', `#${chat.id}`);
  ui.input.value = '';
  autosize();
  state.attachments = [];
  renderAttachments();
  await generate();
}

async function generate() {
  const chat = state.chat;
  const msg = { role: 'assistant', content: '', thinking: '', model: chat.model };
  chat.messages.push(msg);
  const index = chat.messages.length - 1;
  renderMessages();
  const node = ui.messages.lastElementChild;
  setStreaming(true);

  const controller = new AbortController();
  state.controller = controller;
  const body = { model: chat.model, messages: historyFor(chat), stream: true, options: optionsFor(chat) };
  if (chat.keep_alive !== '' && chat.keep_alive != null) body.keep_alive = /^-?\d+$/.test(chat.keep_alive) ? Number(chat.keep_alive) : chat.keep_alive;
  if (hasCap(chat.model, 'thinking')) body.think = chat.think !== false;

  const started = performance.now();
  let firstToken = null;
  let frame = 0;
  const paint = () => {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      const stick = nearBottom();
      updateAssistant(node, msg, index, true);
      if (stick) scrollToBottom();
    });
  };

  try {
    const res = await request(`${OLLAMA}/api/chat`, { method: 'POST', body, signal: controller.signal });
    for await (const part of readNDJSON(res)) {
      if (part.error) throw new Error(part.error);
      const m = part.message || {};
      if (firstToken === null && (m.content || m.thinking)) firstToken = (performance.now() - started) / 1000;
      if (m.thinking) msg.thinking += m.thinking;
      if (m.content) msg.content += m.content;
      if (part.done) {
        msg.stats = {
          gen_tps: rate(part.eval_count, part.eval_duration),
          eval_count: part.eval_count || 0,
          prompt_count: part.prompt_eval_count || 0,
          prompt_tps: rate(part.prompt_eval_count, part.prompt_eval_duration),
          load_s: (part.load_duration || 0) / 1e9,
          total_s: (part.total_duration || 0) / 1e9,
          first_token_s: firstToken,
          done_reason: part.done_reason,
        };
      }
      paint();
    }
  } catch (e) {
    if (e.name === 'AbortError') msg.stopped = true;
    else msg.error = e.message;
  } finally {
    if (frame) cancelAnimationFrame(frame);
    state.controller = null;
    if (!msg.content && !msg.thinking && !msg.error && !msg.stopped) msg.error = 'The model returned an empty reply.';
    if (msg.stats && !splitThink(msg).content && msg.stats.done_reason === 'length') {
      msg.error = 'The token limit was used up before the answer started (thinking models need a higher "Max reply length").';
    }
    await refreshLoaded();
    const loaded = state.loaded.get(msg.model);
    if (msg.stats && loaded) msg.stats.gpu_pct = gpuPct(loaded);
    setStreaming(false);
    if (state.chat === chat) updateAssistant(node, msg, index, false);
    try {
      await saveChat(chat);
    } catch (e) {
      showBanner(`Could not save chat: ${e.message}`);
    }
  }
}

function stop() {
  state.controller?.abort();
}

function regenerate() {
  if (state.streaming) return;
  const msgs = state.chat.messages;
  if (msgs.at(-1)?.role === 'assistant') msgs.pop();
  if (msgs.at(-1)?.role !== 'user') return;
  hideBanner();
  generate();
}

function setStreaming(on) {
  state.streaming = on;
  ui.sendBtn.hidden = on;
  ui.stopBtn.hidden = !on;
  ui.modelSelect.disabled = on;
}

// ---------- rendering: messages
const nearBottom = () => ui.messages.scrollHeight - ui.messages.scrollTop - ui.messages.clientHeight < 120;
const scrollToBottom = () => { ui.messages.scrollTop = ui.messages.scrollHeight; };

function renderMessages() {
  const chat = state.chat;
  ui.messages.replaceChildren();
  if (!chat.messages.length) {
    ui.messages.append(emptyState());
    return;
  }
  chat.messages.forEach((m, i) => ui.messages.append(m.role === 'user' ? userNode(m, i) : assistantNode(m, i)));
  scrollToBottom();
}

function emptyState() {
  const hasModels = state.models.length > 0;
  return h('div', { class: 'empty' },
    h('img', { src: 'icon.svg', alt: '' }),
    h('h1', {}, APP_NAME),
    h('p', { class: 'tagline' }, 'Free, private AI on your own computer.'),
    h('p', {}, hasModels
      ? `You're chatting with ${state.chat.model || 'no model'}. Nothing leaves this machine.`
      : 'No models installed yet. Open Models to download one.'),
    hasModels
      ? h('div', { class: 'starters' }, STARTERS.map(text => h('button', {
        class: 'starter', type: 'button',
        onclick: () => { ui.input.value = text; autosize(); ui.input.focus(); },
      }, text)))
      : h('button', { class: 'btn primary', type: 'button', onclick: openModels }, 'Open Models'));
}

function userNode(msg, index) {
  const node = h('div', { class: 'msg user' },
    h('div', { class: 'bubble' },
      msg.images?.length
        ? h('div', { class: 'msg-images' }, msg.images.map(b64 => h('img', { src: `data:${mimeOf(b64)};base64,${b64}`, alt: 'Attached image' })))
        : null,
      msg.content ? h('div', { class: 'text' }, msg.content) : null),
    h('div', { class: 'actions' },
      h('button', { type: 'button', onclick: e => copyText(msg.content, e.currentTarget) }, 'Copy'),
      h('button', { type: 'button', onclick: () => startEdit(node, msg, index) }, 'Edit')));
  return node;
}

function startEdit(node, msg, index) {
  if (blockedWhileStreaming()) return;
  const box = h('textarea', { class: 'edit-box', rows: '3', 'aria-label': 'Edit message' });
  box.value = msg.content;
  const submit = () => {
    const text = box.value.trim();
    if (!text && !msg.images?.length) return;
    state.chat.messages = state.chat.messages.slice(0, index);
    state.chat.messages.push({ ...msg, content: text });
    generate();
  };
  box.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); submit(); }
    if (e.key === 'Escape') renderMessages();
  });
  node.querySelector('.bubble').replaceWith(h('div', { class: 'bubble editing' }, box,
    h('div', { class: 'edit-actions' },
      h('button', { class: 'btn ghost', type: 'button', onclick: renderMessages }, 'Cancel'),
      h('button', { class: 'btn primary', type: 'button', onclick: submit }, 'Send'))));
  node.querySelector('.actions').remove();
  box.focus();
}

function assistantNode(msg, index) {
  const node = h('div', { class: 'msg assistant' },
    h('div', { class: 'who' }, msg.model || 'assistant'),
    h('details', { class: 'thinking', hidden: true }, h('summary', {}, 'Thinking'), h('div', { class: 'think-body' })),
    h('div', { class: 'md' }),
    h('div', { class: 'error', hidden: true }),
    h('div', { class: 'meta', hidden: true }),
    h('div', { class: 'actions', hidden: true }));
  updateAssistant(node, msg, index, false);
  return node;
}

function updateAssistant(node, msg, index, live) {
  const { content, thinking } = splitThink(msg);

  const think = node.querySelector('.thinking');
  if (thinking) {
    think.hidden = false;
    node.querySelector('.think-body').textContent = thinking;
    const thinkingNow = live && !content;
    think.querySelector('summary').textContent = thinkingNow ? 'Thinking…' : `Thought process (${thinking.split(/\s+/).length} words)`;
    if (thinkingNow && !think.dataset.touched) think.open = true;
    if (content && !think.dataset.touched && think.open) { think.open = false; think.dataset.touched = '1'; }
  }

  const md = node.querySelector('.md');
  if (content) renderMarkdown(md, content);
  else if (live && !thinking) md.replaceChildren(h('span', { class: 'typing', 'aria-label': 'Waiting for reply' }, h('i'), h('i'), h('i')));
  else md.replaceChildren();

  const err = node.querySelector('.error');
  err.hidden = !msg.error;
  err.textContent = msg.error ? `⚠ ${msg.error}` : '';

  const meta = node.querySelector('.meta');
  const stats = statsText(msg, live);
  meta.hidden = !stats;
  meta.textContent = stats;

  const actions = node.querySelector('.actions');
  actions.hidden = live;
  if (!live) {
    const isLast = index === state.chat.messages.length - 1;
    actions.replaceChildren(...[
      content ? h('button', { type: 'button', onclick: e => copyText(content, e.currentTarget) }, 'Copy') : null,
      isLast ? h('button', { type: 'button', onclick: regenerate, title: 'Tip: change the model first to compare' }, 'Regenerate') : null,
    ].filter(Boolean));
  }
}

function statsText(msg, live) {
  const s = msg.stats;
  const bits = [];
  if (live && !s) return '';
  if (s) {
    if (s.gen_tps) bits.push(`${s.gen_tps.toFixed(1)} tok/s`);
    if (s.eval_count) bits.push(`${s.eval_count} tokens`);
    if (s.gpu_pct != null) bits.push(`${s.gpu_pct}% GPU`);
    if (s.first_token_s != null) bits.push(`first token ${fmtSec(s.first_token_s)}`);
    if (s.load_s >= 0.1) bits.push(`load ${fmtSec(s.load_s)}`);
    if (s.prompt_count) bits.push(`prompt ${s.prompt_count} tok${s.prompt_tps ? ` @ ${Math.round(s.prompt_tps)} tok/s` : ''}`);
    if (s.total_s) bits.push(`total ${fmtSec(s.total_s)}`);
    if (s.done_reason === 'length') bits.push('hit token limit');
  }
  if (msg.stopped) bits.push('stopped');
  return bits.join(' · ');
}

// ---------- rendering: chrome
function renderAll() {
  document.title = state.chat.title === NEW_TITLE ? APP_NAME : `${state.chat.title} · ${APP_NAME}`;
  renderChatList();
  renderModelSelect(true);
  renderModelInfo();
  renderMessages();
  renderSettings();
  renderComposer();
}

// Search titles right away, then show the server's matches, which also look inside messages.
let searchTimer = 0;
let searchRun = 0;
function searchChats() {
  clearTimeout(searchTimer);
  const run = ++searchRun;
  const q = ui.searchChats.value.trim();
  state.found = null;
  renderChatList();
  if (!q) return;
  searchTimer = setTimeout(async () => {
    try {
      const found = await getJSON(`/api/chats?q=${encodeURIComponent(q)}`);
      if (run !== searchRun) return; // a newer search started
      state.found = new Set(found.map(c => c.id));
      renderChatList();
    } catch (e) {
      if (run === searchRun) showBanner(`Search failed: ${e.message}`);
    }
  }, 250);
}

function renderChatList() {
  const q = ui.searchChats.value.trim().toLowerCase();
  const items = !q ? state.chats
    : state.found ? state.chats.filter(c => state.found.has(c.id))
      : state.chats.filter(c => c.title.toLowerCase().includes(q));
  ui.chatList.replaceChildren(...items.map(chatItem));
  if (!items.length) ui.chatList.append(h('div', { class: 'muted small pad' }, q ? 'No matching chats' : 'Your saved chats will appear here'));
}

function chatItem(summary) {
  const active = state.chat?.id === summary.id;
  const item = h('div', { class: `chat-item${active ? ' active' : ''}`, onclick: () => openChat(summary.id) },
    h('div', { class: 'chat-title' }, summary.title),
    h('div', { class: 'chat-sub' }, [summary.model, relTime(summary.updated)].filter(Boolean).join(' · ')),
    h('div', { class: 'chat-actions' },
      h('button', { type: 'button', title: 'Rename', 'aria-label': 'Rename chat', onclick: e => { e.stopPropagation(); renameChat(item, summary); } }, '✎'),
      h('button', { type: 'button', title: 'Delete', 'aria-label': 'Delete chat', onclick: e => { e.stopPropagation(); deleteChat(e.currentTarget, summary); } }, '🗑')));
  return item;
}

function renderModelSelect(force = false) {
  const current = state.chat?.model || '';
  const key = JSON.stringify([current, state.models.map(m => m.name), [...state.loaded.keys()]]);
  if (!force && ui.modelSelect.dataset.key === key) return; // don't close an open dropdown for nothing
  ui.modelSelect.dataset.key = key;
  const options = state.models.map(m => h('option', { value: m.name },
    `${m.name} · ${fmtSize(m.size)}${state.loaded.has(m.name) ? ' · ● loaded' : ''}`));
  if (current && !state.models.some(m => m.name === current)) options.unshift(h('option', { value: current }, `${current} (not installed)`));
  if (!options.length) options.push(h('option', { value: '' }, 'No models installed'));
  ui.modelSelect.replaceChildren(...options);
  ui.modelSelect.value = current;
}

function renderModelInfo() {
  const name = state.chat?.model;
  if (!name) { ui.modelInfo.textContent = ''; return; }
  const info = state.info.get(name);
  const loaded = state.loaded.get(name);
  const bits = [];
  if (info) {
    if (info.details.parameter_size) bits.push(info.details.parameter_size);
    if (info.ctx) bits.push(`up to ${Math.round(info.ctx / 1024)}K ctx`);
    for (const cap of ['vision', 'thinking', 'tools']) if (info.caps.includes(cap)) bits.push(cap);
  }
  bits.push(loaded ? `loaded · ${gpuPct(loaded)}% GPU` : 'not loaded (first reply loads it)');
  ui.modelInfo.textContent = bits.join(' · ');
}

function renderComposer() {
  const model = state.chat?.model;
  ui.thinkWrap.hidden = !hasCap(model, 'thinking');
  ui.thinkToggle.checked = state.chat?.think !== false;
  ui.thinkWrap.title = model?.startsWith('deepseek-r1')
    ? 'deepseek-r1 always thinks, even when this is off'
    : 'Let the model reason before answering';
  ui.attachBtn.title = hasCap(model, 'vision') ? 'Attach image' : `Attach image (${model || 'this model'} can't read images)`;
}

function renderSettings() {
  const c = state.chat;
  ui.sysPrompt.value = c.system || '';
  ui.temp.value = c.options.temperature;
  ui.tempVal.textContent = Number(c.options.temperature).toFixed(1);
  ui.numCtx.value = String(c.options.num_ctx || 0);
  ui.numPredict.value = c.options.num_predict ? String(c.options.num_predict) : '';
  ui.keepAlive.value = c.keep_alive || '';
}

const settingsChanged = debounce(() => {
  saveDefaults();
  if (state.chat.messages.length && !state.streaming) saveChat(state.chat, { keepTime: true }).catch(() => {});
}, 400);

// ---------- attachments
function readAsDataURL(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

async function addFiles(files) {
  for (const file of files) {
    if (!file.type.startsWith('image/')) continue;
    if (file.size > 20e6) { showBanner(`${file.name} is larger than 20 MB`); continue; }
    const url = await readAsDataURL(file);
    state.attachments.push({ name: file.name, url, b64: url.split(',')[1] });
  }
  renderAttachments();
  if (state.attachments.length && !hasCap(state.chat.model, 'vision')) {
    showBanner(`${state.chat.model} can't read images. Switch to a vision model such as gemma3:4b.`);
  }
}

function renderAttachments() {
  ui.attachments.replaceChildren(...state.attachments.map((a, i) => h('div', { class: 'thumb' },
    h('img', { src: a.url, alt: a.name }),
    h('button', { type: 'button', title: 'Remove', 'aria-label': `Remove ${a.name}`, onclick: () => { state.attachments.splice(i, 1); renderAttachments(); } }, '×'))));
  ui.attachments.hidden = !state.attachments.length;
}

function autosize() {
  ui.input.style.height = 'auto';
  ui.input.style.height = `${Math.min(ui.input.scrollHeight, 240)}px`;
}

// ---------- models modal
async function openModels() {
  ui.modelsModal.hidden = false;
  renderSuggested();
  renderModelList();
  ui.pullName.focus();
  await Promise.all(state.models.map(m => ensureInfo(m.name)));
  renderModelList();
}

function closeModels() {
  ui.modelsModal.hidden = true;
}

function renderSuggested() {
  const have = new Set(state.models.map(m => m.name));
  ui.suggested.replaceChildren(...SUGGESTED.map(([name, note]) => h('button', {
    class: `chip${have.has(name) ? ' have' : ''}`, type: 'button',
    onclick: () => { ui.pullName.value = name; ui.pullName.focus(); },
  }, name, h('span', {}, have.has(name) ? ' ✓ installed' : ` · ${note}`))));
}

function renderModelList() {
  const total = state.models.reduce((sum, m) => sum + m.size, 0);
  ui.diskNote.textContent = `${state.models.length} models · ${fmtSize(total)} on the HDD`;
  ui.modelList.replaceChildren(...state.models.map(modelRow));
  if (!state.models.length) ui.modelList.append(h('div', { class: 'muted pad' }, 'No models yet. Download one above.'));
}

function modelRow(m) {
  const info = state.info.get(m.name);
  const loaded = state.loaded.get(m.name);
  const canChat = !info || info.caps.includes('completion');
  return h('div', { class: 'model-row' },
    h('div', { class: 'model-main' },
      h('div', { class: 'model-name' }, m.name,
        loaded ? h('span', { class: 'badge live' }, `loaded · ${gpuPct(loaded)}% GPU · ${fmtSize(loaded.size)} in memory`) : null),
      h('div', { class: 'model-sub' }, [fmtSize(m.size), m.details?.parameter_size, m.details?.quantization_level, m.details?.family].filter(Boolean).join(' · ')),
      info ? h('div', { class: 'badges' }, info.caps.map(cap => h('span', { class: 'badge' }, cap))) : null),
    h('div', { class: 'model-actions' },
      canChat ? h('button', { class: 'btn small', type: 'button', onclick: () => useModel(m.name) }, 'Use') : null,
      loaded ? h('button', { class: 'btn small ghost', type: 'button', onclick: e => unloadModel(m.name, e.currentTarget) }, 'Unload') : null,
      h('button', { class: 'btn small ghost danger-text', type: 'button', onclick: e => deleteModel(m.name, e.currentTarget) }, 'Delete')));
}

async function useModel(name) {
  if (blockedWhileStreaming()) return;
  state.chat.model = name;
  await ensureInfo(name);
  saveDefaults();
  if (state.chat.messages.length) saveChat(state.chat, { keepTime: true }).catch(() => {});
  closeModels();
  renderAll();
}

async function unloadModel(name, button) {
  button.disabled = true;
  button.textContent = 'Unloading…';
  const info = await ensureInfo(name);
  try {
    if (info && !info.caps.includes('completion')) await sendJSON(`${OLLAMA}/api/embed`, 'POST', { model: name, input: '', keep_alive: 0 });
    else await sendJSON(`${OLLAMA}/api/generate`, 'POST', { model: name, keep_alive: 0, stream: false });
  } catch (e) {
    showBanner(`Unload failed: ${e.message}`);
  }
  await refreshLoaded();
  renderModelList();
}

async function deleteModel(name, button) {
  if (button.dataset.confirm !== '1') {
    button.dataset.confirm = '1';
    button.textContent = `Really delete ${name}?`;
    setTimeout(() => {
      if (!button.isConnected) return;
      button.dataset.confirm = '';
      button.textContent = 'Delete';
    }, 4000);
    return;
  }
  button.disabled = true;
  button.textContent = 'Deleting…';
  try {
    await request(`${OLLAMA}/api/delete`, { method: 'DELETE', body: { model: name } });
    state.info.delete(name);
  } catch (e) {
    showBanner(`Delete failed: ${e.message}`);
  }
  await poll();
  renderModelList();
  renderSuggested();
}

async function pullModel() {
  const name = ui.pullName.value.trim();
  if (!name || state.pullController) return;
  const controller = new AbortController();
  state.pullController = controller;
  ui.pullBtn.hidden = true;
  ui.pullCancel.hidden = false;
  const fill = h('div', { class: 'fill' });
  const label = h('div', {}, `Starting ${name}…`);
  ui.pullProgress.replaceChildren(label, h('div', { class: 'bar' }, fill));
  ui.pullProgress.hidden = false;
  const layers = new Map();
  try {
    const res = await request(`${OLLAMA}/api/pull`, { method: 'POST', body: { model: name, stream: true }, signal: controller.signal });
    for await (const p of readNDJSON(res)) {
      if (p.error) throw new Error(p.error);
      if (p.digest && p.total) layers.set(p.digest, { total: p.total, done: p.completed || 0 });
      let total = 0;
      let done = 0;
      for (const layer of layers.values()) { total += layer.total; done += layer.done; }
      const pct = total ? Math.floor((100 * done) / total) : 0;
      fill.style.width = `${pct}%`;
      label.textContent = total ? `${name}: ${p.status} · ${fmtSize(done)} of ${fmtSize(total)} (${pct}%)` : `${name}: ${p.status}`;
    }
    fill.style.width = '100%';
    label.textContent = `✓ ${name} is ready`;
    ui.pullName.value = '';
    await poll();
    await ensureInfo(name);
    renderModelList();
    renderSuggested();
  } catch (e) {
    label.textContent = e.name === 'AbortError' ? `Download of ${name} cancelled` : `✗ ${e.message}`;
  } finally {
    state.pullController = null;
    ui.pullBtn.hidden = false;
    ui.pullCancel.hidden = true;
  }
}

// ---------- layout
function toggleSidebar() {
  document.body.classList.toggle(isNarrow() ? 'side-open' : 'side-hidden');
}
function closeSidebarOnMobile() {
  document.body.classList.remove('side-open');
}

// ---------- events
function bindUI() {
  for (const node of document.querySelectorAll('[id]')) ui[node.id] = node;
}

function bindEvents() {
  ui.newChat.addEventListener('click', newChat);
  ui.sendBtn.addEventListener('click', send);
  ui.stopBtn.addEventListener('click', stop);
  ui.searchChats.addEventListener('input', searchChats);
  ui.toggleSidebar.addEventListener('click', toggleSidebar);
  ui.scrim.addEventListener('click', closeSidebarOnMobile);
  ui.themeBtn.addEventListener('click', cycleTheme);
  ui.settingsBtn.addEventListener('click', () => { ui.settings.hidden = !ui.settings.hidden; });
  ui.closeSettings.addEventListener('click', () => { ui.settings.hidden = true; });
  ui.openModels.addEventListener('click', openModels);
  ui.closeModels.addEventListener('click', closeModels);
  ui.modelsModal.addEventListener('click', e => { if (e.target === ui.modelsModal) closeModels(); });
  ui.pullBtn.addEventListener('click', pullModel);
  ui.pullCancel.addEventListener('click', () => state.pullController?.abort());
  ui.pullName.addEventListener('keydown', e => { if (e.key === 'Enter') pullModel(); });

  ui.input.addEventListener('input', autosize);
  ui.input.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
  });
  ui.input.addEventListener('paste', e => {
    const files = [...(e.clipboardData?.files || [])];
    if (files.length) { e.preventDefault(); addFiles(files); }
  });
  ui.attachBtn.addEventListener('click', () => ui.fileInput.click());
  ui.fileInput.addEventListener('change', () => { addFiles([...ui.fileInput.files]); ui.fileInput.value = ''; });
  ui.composer.addEventListener('dragover', e => { e.preventDefault(); ui.composer.classList.add('drag'); });
  ui.composer.addEventListener('dragleave', () => ui.composer.classList.remove('drag'));
  ui.composer.addEventListener('drop', e => {
    e.preventDefault();
    ui.composer.classList.remove('drag');
    addFiles([...e.dataTransfer.files]);
  });

  ui.modelSelect.addEventListener('change', async () => {
    state.chat.model = ui.modelSelect.value;
    await ensureInfo(state.chat.model);
    renderModelSelect(true);
    renderModelInfo();
    renderComposer();
    saveDefaults();
    if (state.chat.messages.length) saveChat(state.chat, { keepTime: true }).catch(() => {});
    else renderMessages();
  });
  ui.thinkToggle.addEventListener('change', () => { state.chat.think = ui.thinkToggle.checked; settingsChanged(); });
  ui.sysPrompt.addEventListener('input', () => { state.chat.system = ui.sysPrompt.value; settingsChanged(); });
  ui.temp.addEventListener('input', () => {
    state.chat.options.temperature = Number(ui.temp.value);
    ui.tempVal.textContent = Number(ui.temp.value).toFixed(1);
    settingsChanged();
  });
  ui.numCtx.addEventListener('change', () => { state.chat.options.num_ctx = Number(ui.numCtx.value); settingsChanged(); });
  ui.numPredict.addEventListener('input', () => { state.chat.options.num_predict = Number(ui.numPredict.value) || 0; settingsChanged(); });
  ui.keepAlive.addEventListener('change', () => { state.chat.keep_alive = ui.keepAlive.value; settingsChanged(); });

  document.addEventListener('keydown', e => {
    if (e.key !== 'Escape') return;
    if (!ui.modelsModal.hidden) closeModels();
    else if (!ui.settings.hidden) ui.settings.hidden = true;
    else if (state.streaming) stop();
  });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', applyTheme);
}

// ---------- start
async function init() {
  bindUI();
  applyTheme();
  bindEvents();
  await poll();
  try {
    const [chats, settings] = await Promise.all([getJSON('/api/chats'), getJSON('/api/settings')]);
    state.chats = chats;
    state.defaults = settings.defaults || await moveBrowserDefaults();
  } catch (e) {
    showBanner(`Could not load saved chats: ${e.message}`);
  }
  const id = location.hash.slice(1);
  if (id && state.chats.some(c => c.id === id)) await openChat(id);
  else newChat();
  setInterval(poll, 15000);
}

init();
