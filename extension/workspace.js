import { PROVIDERS } from './providers.js';

/* ---------------------------------------------------------------------------
 * 判断台工作台
 *
 * 这个文件只做三件事：读取后台保存的场次、把每一席的提示交给用户复制、
 * 把用户从原网站取回的回答按任务号交回后台。它不猜测网页状态，也不把
 * 没有提交的内容写成回答。所有动态文本都通过 textContent 进入页面。
 * ------------------------------------------------------------------------- */

const STAGES = [
  {
    key: 'independent',
    label: '独立作答',
    desc: '两席拿到相同题面，各自完成后才能进入下一阶段。此时彼此看不到对方的回答。',
  },
  {
    key: 'critique',
    label: '交叉质询',
    desc: '把对方的具体主张交给这一席：指出最强依据、最有影响的反例，并说明自己维持或修正了哪条主张。',
  },
  {
    key: 'proposal',
    label: '候选结论',
    desc: '由指定席位起草一版候选结论，写清建议、依据、成立条件与最强反例，供两席确认。',
  },
  {
    key: 'vote',
    label: '逐席确认',
    desc: '两席对同一版候选结论明确表态。只有每位都明确同意且关键条件已纳入，才构成全体一致。',
  },
  {
    key: 'done',
    label: '结论',
    desc: '按当前记录交付结论。存在实质反对、缺席或未纳入的条件时，保留这些状态。',
  },
];

const STAGE_BY_KEY = new Map(STAGES.map((stage, index) => [stage.key, { ...stage, index }]));
const STANCE_LABELS = {
  agree: '同意',
  conditional: '有条件同意',
  oppose: '反对',
};
const STATUS_LABELS = {
  pending: '待回答',
  answered: '已收到',
  skipped: '已跳过',
};

const DRAFTS_KEY = 'aiArena.workspace.drafts.v1';
const COMPOSE_KEY = 'aiArena.workspace.compose.v1';
const DRAFT_MAX_AGE = 30 * 24 * 60 * 60 * 1000;

const viewEl = document.getElementById('view');
const listEl = document.getElementById('history-list');
const countEl = document.getElementById('history-count');
const searchEl = document.getElementById('history-search');
const globalErrorEl = document.getElementById('global-error');
const globalErrorTextEl = document.getElementById('global-error-text');
const toastEl = document.getElementById('toast');

const state = {
  view: 'home',
  sessions: [],
  listError: '',
  listFilter: '',
  session: null,
  compose: { question: '', providers: [] },
  drafts: {},
  showEditor: {},
  dismissedDraftEditors: new Set(),
  stanceChoice: {},
  taskErrors: {},
  taskErrorEls: new Map(),
  homeRefs: null,
  pendingCreate: false,
  toastTimer: null,
};

let loadToken = 0;
let dialogSequence = 0;

/* ------------------------------ 站点清单 ------------------------------ */

function normalizeProviders(raw) {
  const entries = [];

  if (Array.isArray(raw)) {
    raw.forEach((item, index) => {
      if (typeof item === 'string') {
        entries.push({ id: item, name: item });
      } else if (item && typeof item === 'object') {
        entries.push({ ...item, id: item.id || item.key || item.slug || `provider-${index + 1}` });
      }
    });
  } else if (raw && typeof raw === 'object') {
    Object.entries(raw).forEach(([key, value]) => {
      if (typeof value === 'string') {
        entries.push({ id: key, name: value, url: /^https?:\/\//i.test(value) ? value : '' });
      } else if (value && typeof value === 'object') {
        entries.push({ ...value, id: value.id || key });
      }
    });
  }

  const seen = new Set();
  const result = [];
  for (const item of entries) {
    const id = String(item.id || '').trim().toLowerCase();
    if (!id || seen.has(id) || !/^[a-z0-9][a-z0-9_-]*$/.test(id)) continue;
    seen.add(id);
    result.push({
      id,
      name: firstText(item.name, item.displayName, item.label, item.title, item.id, id),
      url: firstUrl(item.url, item.homepage, item.home, item.siteUrl, item.site_url, item.openUrl, item.startUrl, item.baseUrl, item.origin),
      note: firstText(item.note, item.description, item.desc, item.summary),
    });
  }
  return result;
}

function firstText(...values) {
  for (const value of values) {
    if (typeof value === 'string' && value.trim()) return value.trim();
  }
  return '';
}

function firstUrl(...values) {
  for (const value of values) {
    if (typeof value !== 'string' || !value.trim()) continue;
    try {
      const url = new URL(value.trim());
      if (url.protocol === 'http:' || url.protocol === 'https:') return url.href;
    } catch {
      /* 不是可用的站点地址，继续看下一个字段。 */
    }
  }
  return '';
}

const PROVIDER_LIST = normalizeProviders(PROVIDERS);
const PROVIDER_BY_ID = new Map(PROVIDER_LIST.map((provider) => [provider.id, provider]));

function providerName(id) {
  const key = String(id || '').toLowerCase();
  return PROVIDER_BY_ID.get(key)?.name || key || '未登记席位';
}

function providerById(id) {
  return PROVIDER_BY_ID.get(String(id || '').toLowerCase()) || null;
}

function hostOf(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, '');
  } catch {
    return '';
  }
}

function initialOf(name) {
  const chars = Array.from(String(name || '').trim());
  return chars.length ? chars[0].toUpperCase() : '·';
}

function seatLetter(index) {
  return String.fromCharCode(65 + Math.max(0, index));
}

/* ------------------------------ 小工具 ------------------------------ */

function h(tag, props, ...children) {
  const el = document.createElement(tag);
  if (props && typeof props === 'object') {
    for (const [key, value] of Object.entries(props)) {
      if (value === null || value === undefined || value === false) continue;
      if (key === 'class') {
        el.className = Array.isArray(value) ? value.filter(Boolean).join(' ') : String(value);
      } else if (key === 'text') {
        el.textContent = String(value);
      } else if (key === 'dataset') {
        for (const [dataKey, dataValue] of Object.entries(value)) {
          if (dataValue !== null && dataValue !== undefined) el.dataset[dataKey] = String(dataValue);
        }
      } else if (key === 'attrs') {
        for (const [attrKey, attrValue] of Object.entries(value)) {
          if (attrValue === null || attrValue === undefined || attrValue === false) continue;
          el.setAttribute(attrKey, attrValue === true ? '' : String(attrValue));
        }
      } else if (key.startsWith('on') && typeof value === 'function') {
        el.addEventListener(key.slice(2).toLowerCase(), value);
      } else if (key in el && key !== 'list' && key !== 'form') {
        try {
          el[key] = value;
        } catch {
          el.setAttribute(key, String(value));
        }
      } else if (value === true) {
        el.setAttribute(key, '');
      } else {
        el.setAttribute(key, String(value));
      }
    }
  }
  appendChildren(el, children);
  return el;
}

function appendChildren(el, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
}

function stageInfo(key) {
  return STAGE_BY_KEY.get(key) || {
    key: String(key || ''),
    label: `阶段 ${key || '未知'}`,
    desc: '',
    index: 99,
  };
}

function statusLabel(status) {
  return STATUS_LABELS[status] || String(status || '待回答');
}

function stanceChip(stance, label) {
  const key = STANCE_LABELS[stance] ? stance : 'none';
  return h('span', {
    class: `stance-chip is-${key}`,
    text: label || STANCE_LABELS[stance] || '未表态',
  });
}

function oneLine(text, limit = 160) {
  const value = String(text || '').replace(/\s+/g, ' ').trim();
  if (value.length <= limit) return value;
  return `${value.slice(0, limit)}…`;
}

function isSameDay(a, b) {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

function formatTime(timestamp) {
  const value = Number(timestamp);
  if (!Number.isFinite(value) || value <= 0) return '时间未知';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '时间未知';
  const now = new Date();
  const clock = new Intl.DateTimeFormat('zh-CN', {
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(date);
  if (isSameDay(date, now)) return `今天 ${clock}`;
  const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
  if (isSameDay(date, yesterday)) return `昨天 ${clock}`;
  const options = date.getFullYear() === now.getFullYear()
    ? { month: 'numeric', day: 'numeric' }
    : { year: 'numeric', month: 'numeric', day: 'numeric' };
  return `${new Intl.DateTimeFormat('zh-CN', options).format(date)} ${clock}`;
}

function formatAbsolute(timestamp) {
  const value = Number(timestamp);
  if (!Number.isFinite(value) || value <= 0) return '时间未知';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '时间未知';
  return new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(date);
}

function friendlyError(error, prefix = '') {
  const message = error && error.message ? error.message : String(error || '未知错误');
  return prefix ? `${prefix}：${message}` : message;
}

/* ------------------------------ 后台消息 ------------------------------ */

function runtimeAvailable() {
  try {
    return typeof chrome !== 'undefined'
      && !!chrome.runtime
      && !!chrome.runtime.id
      && typeof chrome.runtime.sendMessage === 'function';
  } catch {
    return false;
  }
}

function callBackground(message) {
  return new Promise((resolve, reject) => {
    if (!runtimeAvailable()) {
      reject(new Error('未检测到扩展后台。请从 Chrome 的扩展页打开 workspace.html。'));
      return;
    }

    let settled = false;
    let timer = null;

    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      fn(value);
    };

    const callback = (reply) => {
      const lastError = chrome.runtime.lastError;
      if (lastError) {
        finish(reject, new Error(lastError.message || '扩展后台没有响应。'));
        return;
      }
      if (!reply || typeof reply !== 'object') {
        finish(reject, new Error('扩展后台没有返回可读结果。'));
        return;
      }
      if (reply.ok === false) {
        finish(reject, new Error(typeof reply.error === 'string' && reply.error ? reply.error : '操作失败，后台未提供原因。'));
        return;
      }
      finish(resolve, reply);
    };

    timer = setTimeout(() => {
      finish(reject, new Error('扩展后台在 20 秒内没有响应。'));
    }, 20000);

    try {
      const maybePromise = chrome.runtime.sendMessage(message, callback);
      if (maybePromise && typeof maybePromise.then === 'function') {
        maybePromise
          .then((reply) => {
            if (!settled) callback(reply);
          })
          .catch((error) => {
            finish(reject, new Error(error?.message || '扩展后台通信失败。'));
          });
      }
    } catch (error) {
      finish(reject, new Error(error?.message || '无法和扩展后台通信。'));
    }
  });
}

async function fetchSession(id) {
  const reply = await callBackground({ type: 'get', id });
  if (!reply.session) throw new Error('后台没有返回场次内容。');
  return reply.session;
}

async function ensureSession(reply, id) {
  if (reply && reply.session) return reply.session;
  return fetchSession(id);
}

async function actSession(action, payload) {
  const current = state.session;
  if (!current) throw new Error('当前没有打开的场次。');
  const message = { type: 'act', id: current.id, action };
  if (payload !== undefined) message.payload = payload;
  const reply = await callBackground(message);
  return ensureSession(reply, current.id);
}

/* ------------------------------ 本地草稿 ------------------------------ */

function loadStoredState() {
  try {
    const rawDrafts = JSON.parse(localStorage.getItem(DRAFTS_KEY) || '{}');
    if (rawDrafts && typeof rawDrafts === 'object') {
      const cutoff = Date.now() - DRAFT_MAX_AGE;
      const entries = Object.entries(rawDrafts)
        .filter(([, value]) => value && typeof value === 'object')
        .filter(([, value]) => !Number.isFinite(value.savedAt) || value.savedAt >= cutoff)
        .sort((a, b) => (Number(b[1].savedAt) || 0) - (Number(a[1].savedAt) || 0))
        .slice(0, 500);
      state.drafts = {};
      for (const [key, value] of entries) {
        state.drafts[key] = {
          text: typeof value.text === 'string' ? value.text : '',
          stance: STANCE_LABELS[value.stance] ? value.stance : null,
          savedAt: Number(value.savedAt) || Date.now(),
        };
      }
    }
  } catch {
    state.drafts = {};
  }

  try {
    const rawCompose = JSON.parse(localStorage.getItem(COMPOSE_KEY) || 'null');
    if (rawCompose && typeof rawCompose === 'object') {
      if (typeof rawCompose.question === 'string') state.compose.question = rawCompose.question;
      if (Array.isArray(rawCompose.providers)) {
        const ids = [];
        for (const value of rawCompose.providers) {
          const id = String(value || '').toLowerCase();
          if (PROVIDER_BY_ID.has(id) && !ids.includes(id) && ids.length < 2) ids.push(id);
        }
        state.compose.providers = ids;
      }
    }
  } catch {
    state.compose = { question: '', providers: [] };
  }
}

function persistDrafts() {
  try {
    localStorage.setItem(DRAFTS_KEY, JSON.stringify(state.drafts));
  } catch {
    /* 本地空间不足时保留内存草稿，提交仍可继续。 */
  }
}

function persistCompose() {
  try {
    localStorage.setItem(COMPOSE_KEY, JSON.stringify(state.compose));
  } catch {
    /* 不影响当前输入。 */
  }
}

function flushStoredState() {
  persistDrafts();
  persistCompose();
}

function draftKey(session, task) {
  return [session?.id || '', session?.stage || '', String(session?.round ?? ''), String(task?.id || '')].join('::');
}

function getDraft(session, task) {
  return state.drafts[draftKey(session, task)] || null;
}

function saveDraft(key, patch) {
  const previous = state.drafts[key] || {};
  state.drafts[key] = {
    text: typeof patch.text === 'string' ? patch.text : previous.text || '',
    stance: STANCE_LABELS[patch.stance] ? patch.stance : previous.stance || null,
    savedAt: Date.now(),
  };
  persistDrafts();
}

function deleteDraftKey(key) {
  if (Object.prototype.hasOwnProperty.call(state.drafts, key)) {
    delete state.drafts[key];
    persistDrafts();
  }
}

function deleteDraft(session, task) {
  deleteDraftKey(draftKey(session, task));
}

function purgeDraftsForSession(sessionId) {
  const prefix = `${sessionId}::`;
  let changed = false;
  for (const key of Object.keys(state.drafts)) {
    if (key.startsWith(prefix)) {
      delete state.drafts[key];
      changed = true;
    }
  }
  if (changed) persistDrafts();
}

function updateDraftForTask(session, task, text, stance) {
  const key = draftKey(session, task);
  const hasText = String(text || '').trim().length > 0;
  if (!hasText && !stance) {
    deleteDraftKey(key);
    return;
  }
  saveDraft(key, { text: String(text ?? ''), stance: stance || null });
}

/* ------------------------------ 数据规整 ------------------------------ */

function normalizeTask(raw, fallbackIndex = 0) {
  if (!raw || typeof raw !== 'object') return null;
  const id = String(raw.id || '').trim();
  if (!id) return null;
  const status = ['pending', 'answered', 'skipped'].includes(raw.status) ? raw.status : 'pending';
  return {
    id,
    provider: String(raw.provider || '').toLowerCase(),
    prompt: typeof raw.prompt === 'string' ? raw.prompt : '',
    status,
    answer: typeof raw.answer === 'string' ? raw.answer : '',
    stance: STANCE_LABELS[raw.stance] ? raw.stance : undefined,
    _index: fallbackIndex,
  };
}

function normalizeHistoryEntry(raw, fallbackIndex = 0) {
  const task = normalizeTask(raw, fallbackIndex);
  if (!task) return null;
  return {
    ...task,
    stage: STAGE_BY_KEY.has(raw.stage) ? raw.stage : String(raw.stage || ''),
    round: Number.isFinite(Number(raw.round)) ? Number(raw.round) : 1,
  };
}

function normalizeSession(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const id = String(raw.id || '').trim();
  if (!id) return null;
  return {
    id,
    question: typeof raw.question === 'string' ? raw.question : '',
    providers: Array.isArray(raw.providers) ? raw.providers.map((value) => String(value || '').toLowerCase()) : [],
    stage: String(raw.stage || 'independent'),
    round: Number.isFinite(Number(raw.round)) ? Number(raw.round) : 1,
    paused: Boolean(raw.paused),
    tasks: Array.isArray(raw.tasks) ? raw.tasks.map(normalizeTask).filter(Boolean) : [],
    history: Array.isArray(raw.history) ? raw.history.map(normalizeHistoryEntry).filter(Boolean) : [],
    report: typeof raw.report === 'string' ? raw.report : '',
    updatedAt: Number.isFinite(Number(raw.updatedAt)) ? Number(raw.updatedAt) : Date.now(),
  };
}

function normalizeSummary(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const id = String(raw.id || '').trim();
  if (!id) return null;
  return {
    id,
    question: typeof raw.question === 'string' ? raw.question : '',
    updatedAt: Number.isFinite(Number(raw.updatedAt)) ? Number(raw.updatedAt) : 0,
  };
}

function setSessions(list) {
  const sessions = Array.isArray(list) ? list.map(normalizeSummary).filter(Boolean) : [];
  sessions.sort((a, b) => b.updatedAt - a.updatedAt);
  state.sessions = sessions;
}

function upsertSessionSummary(session) {
  const summary = { id: session.id, question: session.question, updatedAt: session.updatedAt };
  const index = state.sessions.findIndex((item) => item.id === session.id);
  if (index >= 0) state.sessions[index] = summary;
  else state.sessions.push(summary);
  state.sessions.sort((a, b) => b.updatedAt - a.updatedAt);
}

function sessionProviderList(session) {
  const providers = [];
  const add = (value) => {
    const id = String(value || '').toLowerCase();
    if (id && !providers.includes(id)) providers.push(id);
  };
  session.providers.forEach(add);
  session.tasks.forEach((task) => add(task.provider));
  session.history.forEach((entry) => add(entry.provider));
  return providers;
}

function deriveStances(session) {
  const providers = sessionProviderList(session);
  const entries = session.history.filter((entry) => entry.stage === 'vote');
  if (session.stage === 'vote') {
    entries.push(...session.tasks.map((task) => ({ ...task, stage: 'vote', round: session.round })));
  }

  const latest = new Map();
  for (const entry of entries) {
    const provider = String(entry.provider || '').toLowerCase();
    const round = Number(entry.round) || 0;
    const previous = latest.get(provider);
    if (!previous || round >= previous.round) {
      latest.set(provider, {
        round,
        status: entry.status || 'pending',
        stance: entry.stance,
        answer: entry.answer || '',
      });
    }
  }

  return providers.map((provider) => {
    const found = latest.get(provider);
    return found
      ? { provider, ...found }
      : { provider, round: 0, status: 'none', stance: undefined, answer: '' };
  });
}

function stanceRowLabel(row) {
  if (row.status === 'none') return '未表态';
  if (row.status === 'skipped') return '缺席';
  if (row.stance) return STANCE_LABELS[row.stance];
  if (row.status === 'answered') return '已表态（未标注立场）';
  return statusLabel(row.status);
}

/* ------------------------------ 面包屑式提示 ------------------------------ */

function toast(message, kind = 'info') {
  if (!toastEl) return;
  toastEl.textContent = String(message || '');
  toastEl.className = `toast${kind === 'error' ? ' is-error' : ''}`;
  toastEl.hidden = false;
  if (state.toastTimer) clearTimeout(state.toastTimer);
  state.toastTimer = setTimeout(() => {
    toastEl.hidden = true;
    state.toastTimer = null;
  }, kind === 'error' ? 6500 : 3800);
}

function showGlobalError(message) {
  if (!globalErrorEl || !globalErrorTextEl) return;
  globalErrorTextEl.textContent = message;
  globalErrorEl.hidden = false;
}

function hideGlobalError() {
  if (globalErrorEl) globalErrorEl.hidden = true;
}

function confirmDialog({ title, body, confirmLabel = '确认', cancelLabel = '取消', danger = false }) {
  return new Promise((resolve) => {
    const dialog = document.createElement('dialog');
    dialog.className = 'confirm';
    const titleId = `confirm-title-${++dialogSequence}`;
    dialog.setAttribute('aria-labelledby', titleId);

    let settled = false;
    const close = (value) => {
      if (settled) return;
      settled = true;
      try {
        dialog.close();
      } catch {
        /* 已经关闭。 */
      }
      dialog.remove();
      resolve(value);
    };

    const confirmButton = h('button', {
      class: `btn ${danger ? 'btn-danger-solid' : 'btn-strong'}`,
      type: 'button',
      text: confirmLabel,
      onClick: () => close(true),
    });

    dialog.append(
      h('div', { class: 'confirm-inner' },
        h('h2', { class: 'confirm-title', id: titleId, text: title }),
        h('p', { class: 'confirm-body', text: body })),
      h('div', { class: 'confirm-actions' },
        h('button', { class: 'btn', type: 'button', text: cancelLabel, onClick: () => close(false) }),
        confirmButton),
    );

    dialog.addEventListener('cancel', (event) => {
      event.preventDefault();
      close(false);
    });
    dialog.addEventListener('click', (event) => {
      if (event.target === dialog) close(false);
    });

    document.body.append(dialog);
    if (typeof dialog.showModal === 'function') dialog.showModal();
    else dialog.setAttribute('open', '');
    confirmButton.focus();
  });
}

/* ------------------------------ 焦点恢复 ------------------------------ */

function captureFocus() {
  const active = document.activeElement;
  if (!active || !(active instanceof HTMLElement) || !active.dataset.focusKey) return null;
  return {
    key: active.dataset.focusKey,
    start: typeof active.selectionStart === 'number' ? active.selectionStart : null,
    end: typeof active.selectionEnd === 'number' ? active.selectionEnd : null,
  };
}

function restoreFocus(focus) {
  if (!focus) return;
  const escaped = (window.CSS && CSS.escape)
    ? CSS.escape(focus.key)
    : focus.key.replace(/"/g, '\\"');
  const target = viewEl.querySelector(`[data-focus-key="${escaped}"]`);
  if (!target) return;
  try {
    target.focus({ preventScroll: true });
    if (focus.start !== null && typeof target.setSelectionRange === 'function') {
      target.setSelectionRange(focus.start, focus.end ?? focus.start);
    }
  } catch {
    /* 焦点恢复失败不影响数据。 */
  }
}

/* ------------------------------ 渲染入口 ------------------------------ */

function render() {
  const focus = captureFocus();
  if (state.view === 'session' && state.session) renderSession();
  else renderHome();
  restoreFocus(focus);
}

function renderLoading(text) {
  state.homeRefs = null;
  viewEl.replaceChildren(
    h('div', { class: 'loading' },
      h('span', { class: 'spinner', attrs: { 'aria-hidden': 'true' } }),
      h('p', { text })),
  );
}

function goHome() {
  loadToken += 1;
  state.view = 'home';
  state.session = null;
  state.showEditor = {};
  state.dismissedDraftEditors = new Set();
  state.stanceChoice = {};
  state.taskErrors = {};
  state.taskErrorEls = new Map();
  setHash('');
  renderHome();
  renderHistoryList();
  window.scrollTo(0, 0);
  requestAnimationFrame(() => {
    const input = document.getElementById('question-input');
    if (input) input.focus({ preventScroll: true });
  });
}

/* ------------------------------ 历史侧栏 ------------------------------ */

function renderHistoryList() {
  if (!listEl) return;
  if (countEl) countEl.textContent = String(state.sessions.length);
  listEl.replaceChildren();

  if (state.listError) {
    if (state.sessions.length) {
      /* 已有列表时保留可用内容，不因一次后台刷新失败而清空侧栏。 */
    } else {
      listEl.append(
        h('div', { class: 'sidebar-error' },
          h('p', { text: '历史读取失败。' }),
          h('p', { class: 'sidebar-error-detail', text: state.listError }),
          h('button', {
            class: 'btn btn-small btn-on-dark',
            type: 'button',
            text: '重试',
            onClick: () => { void reloadList(); },
          })),
      );
      return;
    }
  }

  if (!state.sessions.length) {
    listEl.append(h('div', { class: 'sidebar-empty', text: '还没有场次。写下第一个要判断的问题。' }));
    return;
  }

  const filter = state.listFilter.trim().toLowerCase();
  const sessions = filter
    ? state.sessions.filter((session) => session.question.toLowerCase().includes(filter))
    : state.sessions;

  if (!sessions.length) {
    listEl.append(h('div', { class: 'sidebar-empty', text: '没有匹配的问题。' }));
    return;
  }

  for (const session of sessions) {
    const active = state.session && state.session.id === session.id;
    const button = h('button', {
      class: `history-item${active ? ' is-active' : ''}`,
      type: 'button',
      title: session.question,
      onClick: () => { void openSession(session.id); },
    },
      h('span', { class: 'history-question', text: session.question || '未命名问题' }),
      h('span', { class: 'history-meta' }, h('span', { text: formatTime(session.updatedAt) })),
    );
    listEl.append(button);
  }
}

async function reloadList({ silent = false } = {}) {
  try {
    const reply = await callBackground({ type: 'list' });
    setSessions(reply.sessions);
    state.listError = '';
    hideGlobalError();
    renderHistoryList();
    return true;
  } catch (error) {
    if (silent && state.sessions.length) return false;
    state.listError = friendlyError(error);
    renderHistoryList();
    if (!silent) toast(friendlyError(error, '刷新历史失败'), 'error');
    return false;
  }
}

/* ------------------------------ 首页 ------------------------------ */

function renderHome() {
  state.view = 'home';
  state.homeRefs = null;

  const wrap = h('div', { class: 'wrap home' });
  wrap.append(
    h('header', { class: 'home-hero' },
      h('div', { class: 'eyebrow-row' },
        h('span', { class: 'eyebrow', text: '本地工作台' }),
        h('span', { class: 'hero-tag', text: '手动中转' })),
      h('h1', { class: 'home-title', text: '把一个问题，交给两席独立判断。' }),
      h('p', { class: 'home-lede', text: '两席先各自回答，再交换质疑，最后逐席确认同一版结论。每一步由你复制提示、在原网站取得回答，再粘贴回来。工作台不代替你发送。' })),
  );

  const refs = {
    providerButtons: new Map(),
    selectionCount: null,
    previewNames: null,
    error: null,
    errorText: null,
    start: null,
    charCount: null,
  };

  /* 一 · 选择两席 */
  const providerGrid = h('div', { class: 'provider-grid' });
  if (!PROVIDER_LIST.length) {
    providerGrid.append(
      h('div', { class: 'inline-empty' },
        h('strong', { text: '没有读到站点清单。' }),
        h('p', { text: '请重新加载扩展后再试；建场需要 extension/providers.js 提供至少两个站点。' })),
    );
  } else {
    for (const provider of PROVIDER_LIST) {
      const selectedIndex = state.compose.providers.indexOf(provider.id);
      const order = h('span', {
        class: 'provider-order',
        text: selectedIndex >= 0 ? `席 ${seatLetter(selectedIndex)}` : '',
        hidden: selectedIndex < 0,
      });
      const button = h('button', {
        class: `provider-option${selectedIndex >= 0 ? ' is-selected' : ''}`,
        type: 'button',
        attrs: { 'aria-pressed': String(selectedIndex >= 0) },
        title: provider.note || `使用 ${provider.name} 的原网页手动回答`,
        onClick: () => toggleProvider(provider.id),
      },
        h('span', { class: 'provider-avatar', attrs: { 'aria-hidden': 'true' }, text: initialOf(provider.name) }),
        h('span', { class: 'provider-body' },
          h('span', { class: 'provider-name', text: provider.name }),
          h('span', { class: 'provider-host', text: hostOf(provider.url) || '站点地址未登记' }),
          h('span', { class: 'provider-tags' }, h('span', { class: 'provider-tag', text: '手动中转' }))),
        order,
      );
      refs.providerButtons.set(provider.id, button);
      providerGrid.append(button);
    }
  }

  refs.selectionCount = h('span', {
    class: `selection-count${state.compose.providers.length === 2 ? ' is-complete' : ''}`,
    text: `${state.compose.providers.length} / 2 已选`,
  });
  wrap.append(
    h('section', { class: 'section' },
      h('div', { class: 'section-head' },
        h('span', { class: 'section-index', text: '一' }),
        h('h2', { class: 'section-title', text: '选择两席' }),
        refs.selectionCount),
      h('p', { class: 'section-note', text: '两位不同成员。点击卡片选择或取消；最多两席，第一席为 A，第二席为 B。' }),
      providerGrid),
  );

  /* 二 · 写下问题 */
  const questionInput = h('textarea', {
    id: 'question-input',
    class: 'question-input',
    rows: 4,
    placeholder: '例如：我的个人笔记工具值不值得先做移动端？我只有两个周末。',
    spellcheck: false,
    autocomplete: 'off',
    dataset: { focusKey: 'question' },
    value: state.compose.question,
    onInput: (event) => {
      state.compose.question = event.target.value;
      persistCompose();
      if (refs.charCount) {
        refs.charCount.textContent = `${Array.from(event.target.value).length} 字 · 会原样出现在两席提示中`;
      }
      clearHomeError();
    },
    onKeydown: (event) => {
      if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
        event.preventDefault();
        void startSession();
      }
    },
  });

  refs.charCount = h('span', {
    text: `${Array.from(state.compose.question).length} 字 · 会原样出现在两席提示中`,
  });

  wrap.append(
    h('section', { class: 'section' },
      h('div', { class: 'section-head' },
        h('span', { class: 'section-index', text: '二' }),
        h('h2', { class: 'section-title', text: '写下问题' })),
      h('p', { class: 'section-note', text: '尽量写清你已有的条件、时间和判断标准。问题原文会保存，也会进入每一轮的提示。' }),
      questionInput,
      h('div', { class: 'field-foot' }, refs.charCount)),
  );

  /* 三 · 开始之后 */
  refs.previewNames = h('strong', { text: previewNameText() });
  const flow = h('ol', { class: 'flow-steps' },
    h('li', {}, '第一轮会把同一题面交给你复制到 ', refs.previewNames, '；两席各自独立回答，互相看不到。'),
    h('li', {}, '首轮回答齐备后，工作台为每一席生成质询提示，里面包含对方的原话与出处。'),
    h('li', {}, '候选结论出来后，两席对同一版本分别表态；立场、理由和条件都按席位保存。'),
    h('li', {}, '最后由你导出结论，或保留仍未解决的分歧。'),
  );

  wrap.append(
    h('section', { class: 'section' },
      h('div', { class: 'section-head' },
        h('span', { class: 'section-index', text: '三' }),
        h('h2', { class: 'section-title', text: '开始之后' })),
      h('div', { class: 'flow-card' }, flow),
      h('div', { class: 'manual-note' },
        h('strong', { text: '本版全程手动中转' }),
        h('span', { text: '不自动登录、不自动发送，也不读取网页回答。复制、粘贴和提交都由你操作。' }))),
  );

  refs.errorText = h('span');
  refs.error = h('div', { class: 'inline-error', role: 'alert', hidden: true }, refs.errorText);

  refs.start = h('button', {
    class: 'btn btn-accent btn-large',
    type: 'button',
    text: '开始判断',
    onClick: () => { void startSession(); },
  });

  wrap.append(
    h('div', { class: 'start-row' },
      refs.start,
      h('p', { class: 'start-note', text: '创建后可随时暂停、补录或结束；记录保存在本机，也可导出为 Markdown。' })),
    refs.error,
    h('p', { class: 'home-foot', text: '每一轮的提示与回答原文会按席位保存，关闭工作台后仍能回到本场。' }),
  );

  state.homeRefs = refs;
  viewEl.replaceChildren(wrap);
}

function previewNameText() {
  const names = state.compose.providers.map(providerName);
  if (names.length === 2) return `${names[0]} 与 ${names[1]}`;
  if (names.length === 1) return `${names[0]} 与另一席`;
  return '两席';
}

function toggleProvider(id) {
  const refs = state.homeRefs;
  if (!refs) return;
  const index = state.compose.providers.indexOf(id);
  if (index >= 0) {
    state.compose.providers.splice(index, 1);
    clearHomeError();
  } else if (state.compose.providers.length >= 2) {
    showHomeError('最多选择两席。先取消一席，再选另一位。');
    return;
  } else {
    state.compose.providers.push(id);
    clearHomeError();
  }
  persistCompose();
  syncHomeSelection();
}

function syncHomeSelection() {
  const refs = state.homeRefs;
  if (!refs) return;
  for (const [id, button] of refs.providerButtons) {
    const index = state.compose.providers.indexOf(id);
    const selected = index >= 0;
    button.classList.toggle('is-selected', selected);
    button.setAttribute('aria-pressed', String(selected));
    const order = button.querySelector('.provider-order');
    if (order) {
      order.hidden = !selected;
      order.textContent = selected ? `席 ${seatLetter(index)}` : '';
    }
  }
  if (refs.selectionCount) {
    refs.selectionCount.textContent = `${state.compose.providers.length} / 2 已选`;
    refs.selectionCount.classList.toggle('is-complete', state.compose.providers.length === 2);
  }
  if (refs.previewNames) refs.previewNames.textContent = previewNameText();
}

function showHomeError(message) {
  const refs = state.homeRefs;
  if (!refs || !refs.error || !refs.errorText) {
    toast(message, 'error');
    return;
  }
  refs.errorText.textContent = message;
  refs.error.hidden = false;
  refs.error.scrollIntoView({ block: 'nearest' });
}

function clearHomeError() {
  if (state.homeRefs?.error) state.homeRefs.error.hidden = true;
}

function setStartBusy(busy) {
  const button = state.homeRefs?.start;
  if (!button || !button.isConnected) return;
  button.disabled = busy;
  button.textContent = busy ? '正在创建…' : '开始判断';
}

async function startSession() {
  if (state.pendingCreate) return;
  const question = state.compose.question.trim();
  const providers = state.compose.providers.map((id) => String(id).toLowerCase());

  if (!question) {
    showHomeError('先写下要判断的问题，再开始。');
    document.getElementById('question-input')?.focus();
    return;
  }
  if (providers.length < 2) {
    showHomeError(providers.length === 0
      ? '先选择两席不同的 AI。'
      : '还需要再选一席：两席才能交换质疑。');
    return;
  }
  if (new Set(providers).size !== 2) {
    showHomeError('两席不能是同一个网站。请取消一位后重新选择。');
    return;
  }
  for (const id of providers) {
    if (!PROVIDER_BY_ID.has(id)) {
      showHomeError('站点清单里找不到其中一席，请重新选择。');
      return;
    }
  }

  state.pendingCreate = true;
  clearHomeError();
  setStartBusy(true);

  try {
    const reply = await callBackground({ type: 'create', question, providers });
    if (!reply.session) throw new Error('后台没有返回新场次。');
    const session = normalizeSession(reply.session);
    if (!session) throw new Error('后台返回的场次数据不完整。');

    state.compose = { question: '', providers: [] };
    persistCompose();

    state.session = session;
    state.view = 'session';
    state.showEditor = {};
    state.dismissedDraftEditors = new Set();
    state.stanceChoice = {};
    state.taskErrors = {};
    upsertSessionSummary(session);
    setHash(session.id);
    render();
    renderHistoryList();
    window.scrollTo(0, 0);
    toast('新场次已创建');
    void reloadList({ silent: true });
  } catch (error) {
    showHomeError(friendlyError(error, '创建失败'));
  } finally {
    state.pendingCreate = false;
    setStartBusy(false);
  }
}

/* ------------------------------ 打开场次 ------------------------------ */

function setHash(id) {
  try {
    window.history.replaceState(null, '', id ? `#s=${encodeURIComponent(id)}` : '#');
  } catch {
    /* 某些内嵌环境不允许改地址，不影响场内数据。 */
  }
}

function readHashId() {
  try {
    const match = /^#s=([^&]+)/.exec(window.location.hash);
    return match ? decodeURIComponent(match[1]) : '';
  } catch {
    return '';
  }
}

async function openSession(id) {
  if (!id) return;
  const previous = state.session;
  loadToken += 1;
  const token = loadToken;
  state.view = 'loading';
  renderLoading('正在读取场次…');

  try {
    const raw = await fetchSession(id);
    if (token !== loadToken) return;
    const session = normalizeSession(raw);
    if (!session) throw new Error('后台返回的场次数据不完整。');

    state.session = session;
    state.view = 'session';
    state.showEditor = {};
    state.dismissedDraftEditors = new Set();
    state.stanceChoice = {};
    state.taskErrors = {};
    upsertSessionSummary(session);
    setHash(session.id);
    render();
    renderHistoryList();
    window.scrollTo(0, 0);
  } catch (error) {
    if (token !== loadToken) return;
    if (previous) {
      /* 已有场次仍在屏幕上时，打开另一场失败不应把当前内容清掉。 */
      state.session = previous;
      state.view = 'session';
      setHash(previous.id);
      render();
      renderHistoryList();
    } else {
      state.view = 'home';
      state.session = null;
      setHash('');
      renderHome();
      renderHistoryList();
    }
    toast(friendlyError(error, '打开场次失败'), 'error');
  }
}

function commitSession(session, { scroll = false } = {}) {
  state.session = session;
  state.view = 'session';
  state.showEditor = {};
  state.stanceChoice = {};
  state.taskErrors = {};
  state.taskErrorEls = new Map();
  upsertSessionSummary(session);
  setHash(session.id);
  render();
  renderHistoryList();
  if (scroll) window.scrollTo(0, 0);
}

function applySession(raw, options) {
  const session = normalizeSession(raw);
  if (!session) throw new Error('后台返回的场次数据不完整。');
  commitSession(session, options);
}

/* ------------------------------ 会话工具栏 ------------------------------ */

async function withButton(button, busyLabel, work) {
  if (!button || button.disabled) return;
  const original = button.textContent;
  button.disabled = true;
  button.textContent = busyLabel;
  try {
    await work();
  } finally {
    if (button.isConnected) {
      button.disabled = false;
      button.textContent = original;
    }
  }
}

async function refreshSession(button) {
  if (!state.session) return;
  const id = state.session.id;
  await withButton(button, '读取中…', async () => {
    try {
      const raw = await fetchSession(id);
      applySession(raw);
      toast('已读取最新状态');
    } catch (error) {
      toast(friendlyError(error, '刷新失败'), 'error');
    }
  });
}

async function togglePause(button) {
  const current = state.session;
  if (!current) return;
  const action = current.paused ? 'resume' : 'pause';
  await withButton(button, action === 'pause' ? '暂停中…' : '继续中…', async () => {
    try {
      const raw = await actSession(action);
      applySession(raw);
      toast(action === 'pause' ? '已暂停后续推进' : '已继续讨论');
    } catch (error) {
      toast(friendlyError(error, action === 'pause' ? '暂停失败' : '继续失败'), 'error');
    }
  });
}

async function finishSession(button) {
  const current = state.session;
  if (!current) return;
  const confirmed = await confirmDialog({
    title: '结束这场讨论？',
    body: '结束会保留已经收到的回答，未完成的席位记为缺席，不会被当作同意。之后仍可查看和导出本场记录。',
    confirmLabel: '结束讨论',
  });
  if (!confirmed) return;

  await withButton(button, '结束中…', async () => {
    try {
      const raw = await actSession('finish');
      applySession(raw);
      toast('讨论已结束');
    } catch (error) {
      toast(friendlyError(error, '结束失败'), 'error');
    }
  });
}

async function deleteCurrentSession(button) {
  const current = state.session;
  if (!current) return;
  const names = sessionProviderList(current).map(providerName).join('、') || '各网站';
  const confirmed = await confirmDialog({
    title: '删除本机记录？',
    body: `“${oneLine(current.question, 80)}”\n\n只删除工作台在本机保存的记录，不影响 ${names} 中的历史对话。删除后不能从工作台恢复。`,
    confirmLabel: '删除记录',
    danger: true,
  });
  if (!confirmed) return;

  await withButton(button, '删除中…', async () => {
    try {
      await callBackground({ type: 'delete', id: current.id });
      purgeDraftsForSession(current.id);
      state.sessions = state.sessions.filter((item) => item.id !== current.id);
      state.session = null;
      state.view = 'home';
      state.showEditor = {};
      state.dismissedDraftEditors = new Set();
      state.stanceChoice = {};
      state.taskErrors = {};
      setHash('');
      renderHome();
      renderHistoryList();
      window.scrollTo(0, 0);
      toast('已删除本机记录');
      void reloadList({ silent: true });
    } catch (error) {
      toast(friendlyError(error, '删除失败'), 'error');
    }
  });
}

/* ------------------------------ 场次页 ------------------------------ */

function renderSession() {
  const session = state.session;
  if (!session) {
    renderHome();
    return;
  }
  state.homeRefs = null;
  state.taskErrorEls = new Map();

  const wrap = h('div', { class: 'wrap session' });
  wrap.append(renderSessionHeader(session), renderStepper(session));

  if (session.paused && session.stage !== 'done') {
    wrap.append(renderPauseBanner(session));
  }

  if (session.stage === 'done') {
    wrap.append(renderReport(session));
  } else {
    wrap.append(renderStage(session));
  }

  wrap.append(renderHistory(session));
  viewEl.replaceChildren(wrap);
}

function renderSessionHeader(session) {
  const seats = session.providers.map((provider, index) => h('span', {
    class: `seat-meta seat-meta-${index === 0 ? 'a' : 'b'}`,
  }, h('span', { class: 'seat-dot', attrs: { 'aria-hidden': 'true' } }),
    `席 ${seatLetter(index)} · ${providerName(provider)}`));

  const statusText = session.stage === 'done'
    ? '已结束'
    : session.paused ? '已暂停' : '进行中';

  return h('header', { class: 'session-head' },
    h('div', { class: 'session-eyebrow' },
      h('span', { text: '本地场次' }),
      h('span', { class: 'dot-sep', attrs: { 'aria-hidden': 'true' }, text: '·' }),
      h('span', { class: session.paused ? 'status-paused' : '', text: statusText }),
      session.stage !== 'done'
        ? h('span', { class: 'round-chip', text: `第 ${session.round} 轮` })
        : null),
    h('h1', { class: 'session-question', text: session.question || '未命名问题' }),
    h('div', { class: 'session-meta' },
      ...seats,
      h('span', { class: 'meta-time', text: `更新于 ${formatTime(session.updatedAt)}` })),
    renderSessionToolbar(session));
}

function renderSessionToolbar(session) {
  const toolbar = h('div', { class: 'session-toolbar' });

  const refreshButton = h('button', {
    class: 'btn btn-ghost',
    type: 'button',
    text: '刷新状态',
    title: '重新读取后台保存的场次',
  });
  refreshButton.addEventListener('click', () => { void refreshSession(refreshButton); });
  toolbar.append(refreshButton);

  if (session.stage !== 'done') {
    const pauseButton = h('button', {
      class: 'btn',
      type: 'button',
      text: session.paused ? '继续讨论' : '暂停',
      title: session.paused ? '恢复后续阶段推进' : '暂停后续阶段推进，已写草稿保留',
    });
    pauseButton.addEventListener('click', () => { void togglePause(pauseButton); });
    toolbar.append(pauseButton);

    const finishButton = h('button', {
      class: 'btn',
      type: 'button',
      text: '结束讨论',
      title: '保留当前回答并交付现有结果',
    });
    finishButton.addEventListener('click', () => { void finishSession(finishButton); });
    toolbar.append(finishButton);
  }

  toolbar.append(
    h('button', {
      class: 'btn',
      type: 'button',
      text: '导出 Markdown',
      onClick: () => exportSession(),
    }),
  );

  const deleteButton = h('button', {
    class: 'btn btn-danger',
    type: 'button',
    text: '删除记录',
  });
  deleteButton.addEventListener('click', () => { void deleteCurrentSession(deleteButton); });
  toolbar.append(deleteButton);

  return toolbar;
}

function renderStepper(session) {
  const current = stageInfo(session.stage);
  const list = h('ol', { class: 'stepper', attrs: { 'aria-label': '讨论阶段' } });

  STAGES.forEach((stage, index) => {
    const done = session.stage === 'done' || index < current.index;
    const active = session.stage !== 'done' && index === current.index;
    const item = h('li', {
      class: `step${done ? ' is-done' : ''}${active ? ' is-current' : ''}`,
      attrs: active ? { 'aria-current': 'step' } : {},
    },
      h('span', { class: 'step-dot', text: done ? '✓' : String(index + 1) }),
      h('span', { class: 'step-label', text: stage.label }));
    list.append(item);
  });

  return list;
}

function renderPauseBanner(session) {
  const button = h('button', {
    class: 'btn btn-small',
    type: 'button',
    text: '继续讨论',
  });
  button.addEventListener('click', () => { void togglePause(button); });
  return h('div', { class: 'pause-banner', role: 'status' },
    h('div', {},
      h('strong', { text: '已暂停' }),
      h('span', { text: '后续阶段不会推进。你仍可查看和复制提示；草稿会保留，继续后可提交。' })),
    button);
}

function renderStage(session) {
  const info = stageInfo(session.stage);
  const tasks = session.tasks;
  const counts = {
    answered: tasks.filter((task) => task.status === 'answered').length,
    skipped: tasks.filter((task) => task.status === 'skipped').length,
  };
  counts.pending = tasks.length - counts.answered - counts.skipped;

  const section = h('section', { class: 'stage', attrs: { 'aria-labelledby': 'stage-title' } });
  const countLine = h('div', { class: 'stage-count' },
    h('span', { text: `已收到 ${counts.answered} / ${tasks.length}` }),
    counts.skipped ? h('span', { class: 'count-skip', text: `跳过 ${counts.skipped}` }) : null,
    counts.pending ? h('span', { class: 'count-pending', text: `待回答 ${counts.pending}` }) : null);

  section.append(
    h('div', { class: 'stage-head' },
      h('div', {},
        h('p', { class: 'stage-kicker', text: `第 ${session.round} 轮` }),
        h('h2', { class: 'stage-title', id: 'stage-title', text: info.label }),
        h('p', { class: 'stage-desc', text: info.desc })),
      countLine),
  );

  if (!tasks.length) {
    const refresh = h('button', { class: 'btn', type: 'button', text: '刷新状态' });
    refresh.addEventListener('click', () => { void refreshSession(refresh); });
    section.append(
      h('div', { class: 'inline-empty' },
        h('strong', { text: '当前阶段没有待处理任务。' }),
        h('p', { text: '后台可能还在生成下一步。读取一次最新状态，或稍后再看。' }),
        refresh),
    );
    return section;
  }

  const grid = h('div', { class: `seat-grid${tasks.length === 1 ? ' is-single' : ''}` });
  tasks.forEach((task, index) => {
    grid.append(renderTaskCard(session, task, index));
  });
  section.append(grid);

  if (counts.pending === 0) {
    const refresh = h('button', { class: 'btn btn-small', type: 'button', text: '刷新读取后台结果' });
    refresh.addEventListener('click', () => { void refreshSession(refresh); });
    section.append(
      h('div', { class: 'all-terminal-note' },
        h('span', { text: '本轮任务都已结束。' }),
        h('span', { text: '如果界面仍停在本阶段，可刷新读取后台推进结果。' }),
        refresh),
    );
  }

  return section;
}

function renderTaskCard(session, task, fallbackIndex) {
  const providerId = String(task.provider || '').toLowerCase();
  const provider = providerById(providerId);
  const seatIndex = session.providers.indexOf(providerId);
  const seat = seatLetter(seatIndex >= 0 ? seatIndex : fallbackIndex);
  const name = providerName(providerId);
  const draft = getDraft(session, task);
  const hasDraft = Boolean(draft && (String(draft.text || '').trim() || draft.stance));
  const dismissed = state.dismissedDraftEditors.has(task.id);
  const mode = state.showEditor[task.id];
  const editorOpen = Boolean(mode) || (hasDraft && !dismissed);

  const card = h('article', {
    class: [
      'seat-card',
      `is-${task.status}`,
      editorOpen ? 'is-editing' : '',
      seat === 'A' ? 'seat-a' : 'seat-b',
    ].filter(Boolean).join(' '),
  });

  const statusChip = h('span', {
    class: `status-chip is-${task.status}`,
    text: statusLabel(task.status),
  });

  const header = h('div', { class: 'seat-top' },
    h('div', { class: 'seat-identity' },
      h('span', { class: `seat-badge${seat === 'B' ? ' seat-badge-b' : ''}`, text: seat }),
      h('div', {},
        h('div', { class: 'seat-name', text: name }),
        h('div', { class: 'seat-sub', text: `${providerId || '未登记站点'} · 席 ${seat}` }))),
    h('div', { class: 'seat-status' },
      hasDraft && !editorOpen ? h('span', { class: 'draft-chip', text: '有草稿' }) : null,
      statusChip));
  card.append(header, renderPromptBox(task));

  const actions = h('div', { class: 'task-actions' });
  actions.append(
    h('button', {
      class: 'btn btn-small',
      type: 'button',
      text: '复制提示',
      title: '复制本轮发送给这一席的完整提示',
      onClick: () => copyPrompt(task),
    }),
  );

  const openButton = h('button', {
    class: 'btn btn-small',
    type: 'button',
    text: '打开原站',
    title: `使用已登录的浏览器打开 ${name}`,
  });
  openButton.addEventListener('click', () => { void openProviderSite(session, task, openButton); });
  actions.append(openButton);

  if (provider?.url) {
    actions.append(h('a', {
      class: 'link-quiet',
      href: provider.url,
      target: '_blank',
      rel: 'noopener noreferrer',
      text: '站点首页',
      title: '直接打开站点首页；对话可能需要重新选择',
    }));
  }

  if (!editorOpen) {
    const openEditor = h('button', {
      class: 'btn btn-small btn-strong',
      type: 'button',
      text: hasDraft ? '继续草稿' : task.status === 'answered' ? '修改回答' : task.status === 'skipped' ? '补录回答' : '粘贴回答',
    });
    openEditor.addEventListener('click', () => {
      state.showEditor[task.id] = task.status === 'answered' ? 'edit' : 'new';
      state.dismissedDraftEditors.delete(task.id);
      render();
    });
    actions.append(openEditor);
  }

  card.append(actions, renderAnswerBlock(session, task));

  const errorEl = h('div', {
    class: 'task-error',
    role: 'alert',
    text: state.taskErrors[task.id] || '',
    hidden: !state.taskErrors[task.id],
  });
  state.taskErrorEls.set(task.id, errorEl);

  if (editorOpen) {
    card.append(renderEditor(session, task, { mode, draft, hasDraft, errorEl }));
  } else {
    card.append(errorEl);
  }

  if (!editorOpen && task.status !== 'answered') {
    card.append(renderSkipRow(session, task, null));
  }

  return card;
}

function renderPromptBox(task) {
  const prompt = typeof task.prompt === 'string' ? task.prompt : '';
  const details = h('details', { class: 'prompt-box' },
    h('summary', {},
      h('span', { text: '本轮提示原文' }),
      h('span', { class: 'prompt-hint', text: prompt ? '展开' : '未保存' })));
  if (prompt) {
    details.append(
      h('pre', { class: 'prompt-text', text: prompt }),
      h('div', { class: 'prompt-actions' },
        h('button', {
          class: 'btn btn-small',
          type: 'button',
          text: '复制这一份',
          onClick: () => copyPrompt(task),
        })),
    );
  }
  return details;
}

function renderAnswerBlock(session, task) {
  if (task.status === 'answered') {
    const block = h('div', { class: 'answer-block' });
    const head = h('div', { class: 'answer-head' },
      h('span', { class: 'answer-label', text: session.stage === 'vote' ? '本轮表态' : '已收到的原文' }));
    if (task.stance) head.append(stanceChip(task.stance));
    const answer = task.answer && task.answer.trim()
      ? task.answer
      : '未保存回答文本。';
    block.append(head, h('div', { class: 'answer-text', text: answer }));
    return block;
  }

  if (task.status === 'skipped') {
    return h('div', { class: 'answer-block is-muted' },
      h('div', { class: 'answer-head' }, h('span', { class: 'answer-label', text: '本阶段缺席' })),
      h('p', { class: 'answer-note', text: '这一席被标记为跳过。缺席不计为同意，仍可补录。' }));
  }

  return h('p', { class: 'answer-note', text: '等待你从原站取回回答，再粘贴到这里。' });
}

function renderEditor(session, task, { mode, draft, hasDraft, errorEl }) {
  const name = providerName(task.provider);
  const draftText = draft && typeof draft.text === 'string' ? draft.text : '';
  const initialText = draftText || (mode === 'edit' ? task.answer || '' : '');
  let stance = state.stanceChoice[task.id] || draft?.stance || task.stance || '';
  if (!STANCE_LABELS[stance]) stance = '';
  state.stanceChoice[task.id] = stance;

  const editor = h('div', { class: 'answer-editor' });

  const textarea = h('textarea', {
    class: 'answer-input',
    rows: 6,
    value: initialText,
    spellcheck: false,
    autocomplete: 'off',
    dataset: { focusKey: `answer:${task.id}` },
    placeholder: editorPlaceholder(session.stage),
    attrs: { 'aria-label': `${name} 的回答原文` },
  });

  if (session.stage === 'vote') {
    editor.append(h('span', { class: 'field-label', text: '明确立场' }));
    const stanceGroup = h('div', {
      class: 'stance-group',
      attrs: { role: 'group', 'aria-label': '本席对候选结论的立场' },
    });
    const stanceButtons = [];

    for (const [value, label] of Object.entries(STANCE_LABELS)) {
      const button = h('button', {
        class: `stance-btn${stance === value ? ' is-active' : ''}`,
        type: 'button',
        text: label,
        dataset: { stance: value },
        attrs: { 'aria-pressed': String(stance === value) },
      });
      button.addEventListener('click', () => {
        stance = value;
        state.stanceChoice[task.id] = value;
        for (const item of stanceButtons) {
          const active = item.dataset.stance === value;
          item.classList.toggle('is-active', active);
          item.setAttribute('aria-pressed', String(active));
        }
        updateDraftForTask(session, task, textarea.value, value);
        noteEl.textContent = '草稿已保存';
        setTaskError(task.id, '');
      });
      stanceButtons.push(button);
      stanceGroup.append(button);
    }
    editor.append(stanceGroup);
    editor.append(h('span', {
      class: 'field-label',
      text: '理由（必填，保存为本轮回答原文）',
    }));
  } else {
    editor.append(h('span', {
      class: 'field-label',
      text: session.stage === 'proposal' ? '候选结论原文' : '回答原文',
    }));
  }

  editor.append(textarea);

  if (session.paused) {
    editor.append(h('p', { class: 'editor-paused-note', text: '已暂停：你可以继续编辑草稿，继续讨论后再提交。' }));
  }

  const noteEl = h('span', {
    class: 'draft-note',
    text: draft ? '已恢复本机草稿' : '草稿自动保存在本机',
  });
  textarea.addEventListener('input', () => {
    updateDraftForTask(session, task, textarea.value, state.stanceChoice[task.id] || '');
    noteEl.textContent = '草稿已保存';
    setTaskError(task.id, '');
  });

  const footer = h('div', { class: 'editor-foot' });
  footer.append(noteEl);

  const actionWrap = h('div', { class: 'editor-actions' });

  if (hasDraft) {
    actionWrap.append(h('button', {
      class: 'btn btn-small btn-ghost',
      type: 'button',
      text: '清除草稿',
      onClick: async () => {
        const confirmed = await confirmDialog({
          title: '清除这一席的草稿？',
          body: '只清除这段尚未提交的本地文本，不会删除已经保存的回答。',
          confirmLabel: '清除草稿',
          danger: true,
        });
        if (!confirmed) return;
        deleteDraft(session, task);
        state.dismissedDraftEditors.delete(task.id);
        state.showEditor[task.id] = task.status === 'answered' ? 'edit' : 'new';
        render();
        toast('草稿已清除');
      },
    }));
  }

  actionWrap.append(h('button', {
    class: 'btn btn-small',
    type: 'button',
    text: '收起',
    onClick: () => {
      delete state.showEditor[task.id];
      if (hasDraft) state.dismissedDraftEditors.add(task.id);
      render();
    },
  }));

  const submitLabel = session.stage === 'vote'
    ? '记录表态'
    : task.status === 'answered' ? '保存修改' : '提交回答';
  const submitButton = h('button', {
    class: 'btn btn-small btn-strong',
    type: 'button',
    text: submitLabel,
    disabled: session.paused,
    title: session.paused ? '讨论已暂停，继续后可提交' : '',
  });
  actionWrap.append(submitButton);
  footer.append(actionWrap);
  editor.append(footer, errorEl);

  const skipRow = task.status !== 'answered'
    ? renderSkipRow(session, task, submitButton)
    : null;
  if (skipRow) editor.append(skipRow);

  submitButton.addEventListener('click', () => {
    void submitTaskAnswer(session, task, {
      textarea,
      stance: () => state.stanceChoice[task.id] || '',
      submitButton,
      noteEl,
    });
  });

  return editor;
}

function renderSkipRow(session, task, submitButton) {
  const row = h('div', { class: 'skip-row' });
  const button = h('button', {
    class: 'btn btn-small btn-ghost',
    type: 'button',
    text: task.status === 'skipped' ? '保持缺席' : '跳过这一席',
    disabled: session.paused || task.status === 'skipped',
    title: session.paused ? '讨论已暂停，继续后可跳过' : '本阶段记为缺席，不会被当作同意',
  });
  button.addEventListener('click', () => {
    void skipTask(session, task, button, submitButton);
  });
  row.append(button);
  return row;
}

function editorPlaceholder(stage) {
  if (stage === 'vote') return '为什么同意、有条件同意或反对？写下能改变你判断的条件。';
  if (stage === 'proposal') return '粘贴这一席起草的候选结论：建议、依据、成立条件、最强反例。';
  if (stage === 'critique') return '粘贴这一席的质询回答：最强依据、最有影响的反例、维持或修正了哪条主张。';
  return '粘贴这一席的完整回答原文。';
}

function setTaskError(taskId, message) {
  if (message) state.taskErrors[taskId] = message;
  else delete state.taskErrors[taskId];
  const element = state.taskErrorEls.get(taskId);
  if (element) {
    element.textContent = message || '';
    element.hidden = !message;
  }
}

/* ------------------------------ 席任务动作 ------------------------------ */

async function submitTaskAnswer(session, task, { textarea, stance, submitButton, noteEl }) {
  const current = state.session;
  if (!current) return;
  if (current.paused) {
    setTaskError(task.id, '讨论已暂停。继续后再提交，你的草稿已经保留。');
    return;
  }

  const text = textarea.value.trim();
  const selectedStance = stance();

  if (!text) {
    setTaskError(task.id, session.stage === 'vote'
      ? '先写下理由，再记录表态。'
      : '先粘贴这一席的回答原文。');
    textarea.focus();
    return;
  }
  if (session.stage === 'vote' && !STANCE_LABELS[selectedStance]) {
    setTaskError(task.id, '先选择明确立场：同意、有条件同意或反对。');
    return;
  }

  const oldText = submitButton.textContent;
  submitButton.disabled = true;
  submitButton.textContent = '提交中…';
  textarea.readOnly = true;
  setTaskError(task.id, '');

  try {
    const payload = { taskId: task.id, text };
    if (session.stage === 'vote') payload.stance = selectedStance;
    const raw = await actSession('answer', payload);
    const next = normalizeSession(raw);
    if (!next) throw new Error('后台返回的场次数据不完整。');

    deleteDraft(session, task);
    state.dismissedDraftEditors.delete(task.id);
    commitSession(next);
    toast(session.stage === 'vote' ? '已记录本席表态' : '回答已提交');
  } catch (error) {
    setTaskError(task.id, friendlyError(error, '提交失败，草稿已保留'));
    submitButton.disabled = false;
    submitButton.textContent = oldText;
    textarea.readOnly = false;
    if (noteEl) noteEl.textContent = '草稿已保存';
  }
}

async function skipTask(session, task, skipButton, submitButton) {
  const current = state.session;
  if (!current) return;
  if (current.paused) {
    setTaskError(task.id, '讨论已暂停，继续后再处理缺席。');
    return;
  }

  const name = providerName(task.provider);
  const confirmed = await confirmDialog({
    title: `跳过席 ${seatLetter(Math.max(0, session.providers.indexOf(task.provider)))}？`,
    body: `${name} 在本阶段会被记为缺席。缺席不会被当作同意，尚未提交的草稿会保留。`,
    confirmLabel: '跳过这一席',
  });
  if (!confirmed) return;

  skipButton.disabled = true;
  if (submitButton) submitButton.disabled = true;
  const oldLabel = skipButton.textContent;
  skipButton.textContent = '记录中…';

  try {
    const raw = await actSession('skip', { taskId: task.id });
    const next = normalizeSession(raw);
    if (!next) throw new Error('后台返回的场次数据不完整。');
    state.dismissedDraftEditors.add(task.id);
    commitSession(next);
    toast('已记为缺席');
  } catch (error) {
    skipButton.disabled = false;
    skipButton.textContent = oldLabel;
    if (submitButton) submitButton.disabled = false;
    setTaskError(task.id, friendlyError(error, '跳过失败'));
  }
}

async function copyPrompt(task) {
  const prompt = typeof task.prompt === 'string' ? task.prompt : '';
  if (!prompt.trim()) {
    toast('这一席的提示原文为空，无法复制。', 'error');
    return;
  }
  try {
    await copyText(prompt);
    toast('已复制这一席的提示');
  } catch (error) {
    toast(friendlyError(error, '复制失败'), 'error');
  }
}

async function openProviderSite(session, task, button) {
  if (!session || !task) return;
  if (button.disabled) return;
  const oldLabel = button.textContent;
  button.disabled = true;
  button.textContent = '打开中…';
  try {
    await callBackground({ type: 'open', id: session.id, provider: task.provider });
  } catch (error) {
    toast(friendlyError(error, '无法打开原站'), 'error');
  } finally {
    if (button.isConnected) {
      button.disabled = false;
      button.textContent = oldLabel;
    }
  }
}

async function copyText(text) {
  const value = String(text ?? '');
  try {
    if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
      await navigator.clipboard.writeText(value);
      return;
    }
  } catch {
    /* 退回到选择文本后复制。 */
  }

  const helper = h('textarea', {
    class: 'clipboard-helper',
    value,
    attrs: { readonly: '', 'aria-hidden': 'true' },
  });
  document.body.append(helper);
  helper.select();
  let copied = false;
  try {
    copied = document.execCommand('copy');
  } finally {
    helper.remove();
  }
  if (!copied) throw new Error('浏览器拒绝了复制操作。');
}

/* ------------------------------ 结论与历史 ------------------------------ */

function renderReport(session) {
  const reportText = session.report && session.report.trim() ? session.report.trim() : '';
  const actions = h('div', { class: 'report-actions' });

  actions.append(h('button', {
    class: 'btn btn-small',
    type: 'button',
    text: '复制结论',
    disabled: !reportText,
    title: reportText ? '复制结论文本' : '本场没有结论文本',
    onClick: async () => {
      try {
        await copyText(reportText);
        toast('已复制结论文本');
      } catch (error) {
        toast(friendlyError(error, '复制失败'), 'error');
      }
    },
  }));

  actions.append(h('button', {
    class: 'btn btn-small',
    type: 'button',
    text: '导出 Markdown',
    onClick: () => exportSession(),
  }));

  const section = h('section', { class: 'report', attrs: { 'aria-labelledby': 'report-title' } },
    h('div', { class: 'report-head' },
      h('div', {},
        h('p', { class: 'report-kicker', text: '本场记录' }),
        h('h2', { class: 'report-title', id: 'report-title', text: '结论' })),
      actions));

  if (reportText) {
    section.append(h('div', { class: 'report-body', text: reportText }));
  } else {
    section.append(h('div', {
      class: 'report-empty',
      text: '本场已结束，但没有附上结论文本。逐席表态和历次发言仍保留在下面，也可以导出完整记录。',
    }));
  }

  section.append(renderStanceSummary(session));
  return section;
}

function renderStanceSummary(session) {
  const rows = deriveStances(session);
  const wrap = h('div', { class: 'stance-summary' },
    h('h3', { class: 'stance-title', text: '逐席确认' }),
    h('p', {
      class: 'stance-rule',
      text: '缺席、沉默与无法解析的表态都不计为同意。只有每位参与者明确同意且关键条件已纳入，才构成全体一致。',
    }));

  for (const row of rows) {
    const reason = row.status === 'none'
      ? '没有确认记录。'
      : row.status === 'skipped'
        ? '这一席在本阶段缺席。'
        : row.status === 'pending'
          ? '尚未回答。'
          : row.answer && row.answer.trim() ? row.answer : '未保存理由文本。';
    wrap.append(h('div', { class: 'stance-row' },
      h('span', { class: 'stance-name', text: providerName(row.provider) }),
      h('span', {}, stanceChip(row.stance, stanceRowLabel(row))),
      h('span', { class: 'stance-reason', text: reason })));
  }

  return wrap;
}

function renderHistory(session) {
  const entries = session.history
    .filter((entry) => !(entry.stage === session.stage && entry.round === session.round))
    .slice()
    .sort((a, b) => {
      const roundDiff = (Number(a.round) || 0) - (Number(b.round) || 0);
      if (roundDiff) return roundDiff;
      const stageDiff = stageInfo(a.stage).index - stageInfo(b.stage).index;
      if (stageDiff) return stageDiff;
      const seatA = session.providers.indexOf(a.provider);
      const seatB = session.providers.indexOf(b.provider);
      return (seatA < 0 ? 99 : seatA) - (seatB < 0 ? 99 : seatB);
    });

  const section = h('section', { class: 'history-section', attrs: { 'aria-labelledby': 'history-title' } },
    h('div', { class: 'history-section-head' },
      h('div', {},
        h('p', { class: 'report-kicker', text: '原文保留' }),
        h('h2', { class: 'history-title', id: 'history-title', text: '历次发言' })),
      h('span', { class: 'history-note', text: '按轮次与阶段保存' })));

  if (!entries.length) {
    section.append(h('div', {
      class: 'inline-empty',
      text: '还没有已完成的发言。当前轮的回答会先显示在上面的席位卡片中。',
    }));
    return section;
  }

  const timeline = h('div', { class: 'timeline' });
  let lastGroup = '';
  for (const entry of entries) {
    const group = `${entry.round}::${entry.stage}`;
    if (group !== lastGroup) {
      timeline.append(h('h3', {
        class: 'timeline-group',
        text: `第 ${entry.round} 轮 · ${stageInfo(entry.stage).label}`,
      }));
      lastGroup = group;
    }
    timeline.append(renderHistoryEntry(session, entry));
  }

  section.append(timeline);
  return section;
}

function renderHistoryEntry(session, entry) {
  const seatIndex = session.providers.indexOf(entry.provider);
  const meta = h('div', { class: 'timeline-meta' },
    h('span', { class: 'timeline-seat', text: `席 ${seatLetter(seatIndex >= 0 ? seatIndex : 0)} · ${providerName(entry.provider)}` }),
    h('span', { text: statusLabel(entry.status) }));
  if (entry.stance) meta.append(stanceChip(entry.stance));

  const item = h('article', { class: 'timeline-item' }, meta);

  if (entry.status === 'skipped') {
    item.append(h('div', { class: 'timeline-answer is-muted', text: '该席在本阶段缺席（跳过）。' }));
  } else if (entry.answer && entry.answer.trim()) {
    item.append(h('div', { class: 'timeline-answer', text: entry.answer }));
  } else if (entry.status === 'pending') {
    item.append(h('div', { class: 'timeline-answer is-muted', text: '尚未回答。' }));
  } else {
    item.append(h('div', { class: 'timeline-answer is-muted', text: '未保存回答文本。' }));
  }

  if (entry.prompt) {
    item.append(h('details', { class: 'prompt-box prompt-box-history' },
      h('summary', {},
        h('span', { text: '本阶段提示原文' }),
        h('span', { class: 'prompt-hint', text: '展开' })),
      h('pre', { class: 'prompt-text', text: entry.prompt }),
      h('div', { class: 'prompt-actions' },
        h('button', {
          class: 'btn btn-small',
          type: 'button',
          text: '复制提示',
          onClick: () => copyPrompt(entry),
        }))));
  }

  if (entry.answer && entry.answer.trim()) {
    item.append(h('div', { class: 'timeline-actions' },
      h('button', {
        class: 'btn btn-small btn-ghost',
        type: 'button',
        text: '复制回答',
        onClick: async () => {
          try {
            await copyText(entry.answer);
            toast('已复制回答原文');
          } catch (error) {
            toast(friendlyError(error, '复制失败'), 'error');
          }
        },
      })));
  }

  return item;
}

/* ------------------------------ Markdown 导出 ------------------------------ */

function exportSession() {
  if (!state.session) return;
  try {
    const markdown = buildMarkdown(state.session);
    downloadText(markdown, exportFilename(state.session));
    toast('已导出 Markdown');
  } catch (error) {
    toast(friendlyError(error, '导出失败'), 'error');
  }
}

function buildMarkdown(session) {
  const lines = [];
  lines.push('# 判断记录', '');
  lines.push('## 问题', '', session.question || '未填写问题', '');

  lines.push('## 场次信息', '');
  const seats = sessionProviderList(session).map((provider, index) =>
    `席 ${seatLetter(index)} ${providerName(provider)}（${provider}）`);
  lines.push(`- 参与席位：${seats.join('；') || '未登记'}`);
  lines.push(`- 当前阶段：${stageInfo(session.stage).label}${session.stage !== 'done' ? ` · 第 ${session.round} 轮` : ''}`);
  lines.push(`- 状态：${session.paused ? '已暂停' : session.stage === 'done' ? '已结束' : '进行中'}`);
  lines.push(`- 更新时间：${formatAbsolute(session.updatedAt)}`);
  lines.push(`- 导出时间：${formatAbsolute(Date.now())}`, '');

  lines.push('## 结论', '');
  const report = session.report && session.report.trim() ? session.report.trim() : '';
  lines.push(report || '本场没有附上结论文本，只保留以下回答与表态记录。', '');

  lines.push('## 逐席确认', '');
  lines.push('> 缺席、沉默与无法解析的表态都不计为同意。只有每位参与者明确同意且关键条件已纳入，才构成全体一致。', '');
  const stances = deriveStances(session);
  if (!stances.length) lines.push('- 没有可列出的席位。');
  for (const row of stances) {
    const reason = row.answer && row.answer.trim() ? `；理由：${oneLine(row.answer, 240)}` : '';
    lines.push(`- ${providerName(row.provider)}：${stanceRowLabel(row)}${reason}`);
  }
  lines.push('');

  lines.push('## 讨论记录', '');
  const entries = collectExportEntries(session);
  if (!entries.length) {
    lines.push('还没有保存的发言。', '');
  } else {
    let lastGroup = '';
    for (const entry of entries) {
      const group = `${entry.round}::${entry.stage}`;
      if (group !== lastGroup) {
        lines.push(`### 第 ${entry.round} 轮 · ${stageInfo(entry.stage).label}`, '');
        lastGroup = group;
      }
      const providerIndex = sessionProviderList(session).indexOf(entry.provider);
      lines.push(`#### 席 ${seatLetter(providerIndex >= 0 ? providerIndex : 0)} · ${providerName(entry.provider)}`, '');
      lines.push(`- 站点标识：${entry.provider || '未登记'}`);
      lines.push(`- 状态：${statusLabel(entry.status)}`);
      if (entry.stance) lines.push(`- 立场：${STANCE_LABELS[entry.stance]}`);
      lines.push('', '**提示原文**', '', markdownBlock(entry.prompt || '未保存本轮提示。'), '');
      const answer = entry.status === 'skipped'
        ? '本阶段缺席（跳过）。'
        : entry.status === 'pending'
          ? '尚未回答。'
          : entry.answer && entry.answer.trim() ? entry.answer : '未保存回答文本。';
      lines.push('**回答原文**', '', markdownBlock(answer), '');
    }
  }

  return lines.join('\n');
}

function collectExportEntries(session) {
  const currentKeys = new Set(
    session.tasks.map((task) => `${task.id}::${session.stage}::${session.round}`),
  );
  const entries = [];

  for (const entry of session.history) {
    if (currentKeys.has(`${entry.id}::${entry.stage}::${entry.round}`)) continue;
    entries.push(entry);
  }
  for (const task of session.tasks) {
    entries.push({ ...task, stage: session.stage, round: session.round });
  }

  return entries.sort((a, b) => {
    const roundDiff = (Number(a.round) || 0) - (Number(b.round) || 0);
    if (roundDiff) return roundDiff;
    const stageDiff = stageInfo(a.stage).index - stageInfo(b.stage).index;
    if (stageDiff) return stageDiff;
    const seatA = sessionProviderList(session).indexOf(a.provider);
    const seatB = sessionProviderList(session).indexOf(b.provider);
    return (seatA < 0 ? 99 : seatA) - (seatB < 0 ? 99 : seatB);
  });
}

function markdownBlock(text) {
  const source = String(text ?? '');
  const runs = source.match(/`{3,}/g);
  const length = Math.max(3, (runs ? Math.max(...runs.map((run) => run.length)) : 0) + 1);
  const fence = '`'.repeat(length);
  return `${fence}\n${source}\n${fence}`;
}

function exportFilename(session) {
  const base = String(session.question || '未命名判断')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 32)
    .replace(/[\\/:*?"<>|#%{}~&]/g, '-') || '未命名判断';
  const now = new Date();
  const pad = (value) => String(value).padStart(2, '0');
  return `判断台-${base}-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}.md`;
}

function downloadText(text, filename) {
  const blob = new Blob([text], { type: 'text/markdown;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = filename;
  anchor.rel = 'noopener';
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/* ------------------------------ 启动 ------------------------------ */

function bindGlobalEvents() {
  document.getElementById('new-session')?.addEventListener('click', goHome);

  searchEl?.addEventListener('input', (event) => {
    state.listFilter = event.target.value || '';
    renderHistoryList();
  });

  document.getElementById('global-error-retry')?.addEventListener('click', async (event) => {
    const button = event.currentTarget;
    await withButton(button, '重试中…', async () => {
      const ok = await reloadList();
      if (!ok) return;
      const hashId = readHashId();
      if (hashId && !state.session) {
        await openSession(hashId);
      } else if (state.view === 'home') {
        renderHome();
      }
    });
  });

  window.addEventListener('pagehide', flushStoredState);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') flushStoredState();
  });
}

async function boot() {
  loadStoredState();
  bindGlobalEvents();
  renderHistoryList();

  if (!runtimeAvailable()) {
    showGlobalError('未检测到扩展后台。请从 Chrome 的扩展页打开 workspace.html，而不是直接打开本地文件。');
    renderHome();
    return;
  }

  renderLoading('正在读取本地场次…');

  try {
    const reply = await callBackground({ type: 'list' });
    setSessions(reply.sessions);
    hideGlobalError();
    renderHistoryList();

    const hashId = readHashId();
    if (hashId) await openSession(hashId);
    else renderHome();
  } catch (error) {
    setSessions([]);
    state.listError = friendlyError(error);
    renderHistoryList();
    showGlobalError(friendlyError(error, '读取场次失败'));
    renderHome();
  }
}

void boot();
