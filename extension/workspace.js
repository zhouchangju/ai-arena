import {
  PROVIDERS,
  AUTOMATION_PROVIDER_IDS,
  PUBLIC_AUTOMATION_PROVIDER_IDS,
  providerOrigin,
} from './providers.js';
import { latestAnsweredProposal, proposalDigest } from './core.js';

/* ---------------------------------------------------------------------------
 * 判断台工作台
 *
 * 这个文件只做三件事：读取后台保存的场次、把每一席的提示交给用户复制、
 * 把用户从原网站取回的回答按任务号交回后台。它不猜测网页状态，也不把
 * 没有提交的内容写成回答。所有动态文本都通过 textContent 进入页面。
 * ------------------------------------------------------------------------- */

const MIN_SEATS = 2;
const MAX_SEATS = 3;

const STAGES = [
  {
    key: 'independent',
    label: '独立作答',
    desc: '每席拿到同一个问题，各自作答后才能进入下一步；这时彼此看不到对方的回答。',
  },
  {
    key: 'critique',
    label: '交叉质询',
    desc: '把其他席位的具体主张交给这一席：指出最强依据和最有影响的反例，说明自己维持或修正了哪条主张。',
  },
  {
    key: 'proposal',
    label: '候选结论',
    desc: '一席起草候选结论：建议、依据、成立条件和最强反例，交给所有席位确认。',
  },
  {
    key: 'vote',
    label: '逐席确认',
    desc: '每席对同一版候选结论表态。每位都明确同意、关键条件也写进去，才算全体一致。',
  },
  {
    key: 'done',
    label: '结论',
    desc: '按现有记录给出结论。有实质反对、缺席或没写进去的条件，都照实保留。',
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

const AUTOMATION_SEATS = new Set(AUTOMATION_PROVIDER_IDS);
/* 公开的三席（ChatGPT / Gemini / DeepSeek）在点「开始」的同一次手势里申请
 * 各自域名的访问权限；本机 A/B 仍只用连接设置里保存的地址。 */
const PUBLIC_AUTOMATION_SEATS = new Set(PUBLIC_AUTOMATION_PROVIDER_IDS);
const AUTOMATION_POLL_MS = 4000;
const AUTOMATION_NEEDS_ACTION = new Set([
  'paused',
  'stale',
  'session-paused',
  'unconfigured',
]);
const AUTOMATION_RUNNING_STATUSES = new Set([
  'probing',
  'dispatching',
  'verifying',
  'submitted',
  'streaming',
  'waiting',
]);
/* 会改变场次内容或交互方式的状态：已写入讨论要重读回答；暂停、失败、停止
 * 要让这一席的卡片换成手动动作。流式正文不在此列。 */
const AUTOMATION_REFRESH_STATUSES = new Set([
  'answered',
  'paused',
  'stale',
  'session-paused',
  'unconfigured',
  'detached',
  'idle',
]);
/* 后台核对了原页用户消息之后才会进入这些相位。提示入口只凭这份回执
 * 说「已确认发送」，不看本机复制、按钮点击或自动流程正在跑。 */
const CONFIRMED_DISPATCH_PHASES = new Set(['submitted', 'streaming', 'answered']);
const SENDING_DISPATCH_PHASES = new Set([
  'dispatching',
  'waiting-send',
  'verifying',
]);
const AUTOMATION_SEAT_LABELS = {
  idle: '待命',
  probing: '检查原页',
  dispatching: '正在发送',
  verifying: '正在确认发送',
  submitted: '已确认发送，等回答',
  streaming: '正在生成',
  waiting: '等待回答',
  answered: '已完成，已写入讨论',
  stale: '需要人工核对',
  'session-paused': '讨论已暂停',
  paused: '需要处理',
  unconfigured: '未配置',
  detached: '已停止自动',
};

const DRAFTS_KEY = 'aiArena.workspace.drafts.v1';
const COMPOSE_KEY = 'aiArena.workspace.compose.v1';
const LAST_PAIR_KEY = 'aiArena.workspace.lastPair.v1';
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
  lastPair: [],
  drafts: {},
  showEditor: {},
  /* 打开「改正录入」时看到的原文；提交时作为预期旧文本交给后台拒绝过期覆盖。 */
  correctionBase: {},
  dismissedDraftEditors: new Set(),
  stanceChoice: {},
  taskErrors: {},
  taskErrorEls: new Map(),
  promptCopied: {},
  nextStepPanel: null,
  homeRefs: null,
  pendingCreate: false,
  toastTimer: null,
  automation: { loaded: false, configs: {}, runs: {}, error: '' },
  automationPanel: null,
  automationPollTimer: null,
  automationRefreshPending: false,
  automationBusy: false,
  /* 上次看到的逐席快照：只有「已写入讨论」这类会改变场次的状态才触发重读。 */
  automationSnapshot: {},
  automationNotice: null,
  automationRefreshTimer: null,
  /* 席卡上的自动进度节点，供 automation.progress 只改文字、不整页重绘。 */
  autoSeatEls: new Map(),
  /* 提示入口上的发送状态，同样按进度原地更新；键是任务 ID。 */
  promptStateEls: new Map(),
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

/* ------------------------------ 本机自动化状态 ------------------------------ */

function isAutomationSeat(id) {
  return AUTOMATION_SEATS.has(String(id || '').toLowerCase());
}

/* ChatGPT / Gemini / DeepSeek：权限按站点申请，不需要连接设置里的地址。 */
function isPublicAutomationSeat(id) {
  return PUBLIC_AUTOMATION_SEATS.has(String(id || '').toLowerCase());
}

function isLocalAutomationSeat(id) {
  return isAutomationSeat(id) && !isPublicAutomationSeat(id);
}

function automationConfig(id) {
  const key = String(id || '').toLowerCase();
  return state.automation.configs && state.automation.configs[key]
    ? state.automation.configs[key]
    : null;
}

function automationRun(session) {
  if (!session) return null;
  return (state.automation.runs && state.automation.runs[session.id]) || null;
}

function automationSeats(session) {
  if (!session) return [];
  return sessionProviderList(session).filter(isAutomationSeat);
}

function automationSeatState(run, provider) {
  if (!run || !run.seats) return null;
  const seat = run.seats[provider];
  return seat && typeof seat === 'object' ? seat : null;
}

function automationSeatNeedsAction(seat) {
  if (!seat) return false;
  if (seat.paused || seat.takenOver) return true;
  const status = String(seat.status || '').toLowerCase();
  /* 配置缺失时后台保持 idle 并写清原因；这类席位也要按手动处理。 */
  if (status === 'idle' && seat.detail) return true;
  return AUTOMATION_NEEDS_ACTION.has(status);
}

function automationNeedsAction(run) {
  if (!run) return 0;
  let count = 0;
  for (const provider of AUTOMATION_PROVIDER_IDS) {
    if (automationSeatNeedsAction(automationSeatState(run, provider))) count += 1;
  }
  return count;
}

function automationSeatMode(session, provider) {
  const id = String(provider || '').toLowerCase();
  if (!isAutomationSeat(id)) return '手动';
  const run = automationRun(session);
  const seat = automationSeatState(run, id);
  const local = isLocalAutomationSeat(id);
  if (run && run.enabled) {
    if (seat && seat.takenOver) return '手动接管';
    if (automationSeatNeedsAction(seat)) return local ? '本机待处理' : '自动待处理';
    if (seat && seat.status === 'detached') return '手动';
    return '自动';
  }
  if (!local) return seat ? automationSeatLabel(seat) : '可自动';
  return automationConfig(id) ? '本机手动' : '本机未配置';
}

function automationSeatLabel(seat) {
  if (!seat) return '待命';
  const status = String(seat.status || '').toLowerCase();
  const label = AUTOMATION_SEAT_LABELS[status] || (status || '待命');
  return seat.paused && status !== 'paused' ? `${label}（需处理）` : label;
}

/* 自动运行中，「待命」有两种意思：这一席还有本轮任务要发，或本席已完成、等
 * 其他席位／下一阶段。只在后一种显示「等待下一步」，不和席卡的「待回答」重复。 */
function automationSeatContextLabel(seat, run, session, provider) {
  const base = automationSeatLabel(seat);
  if (base !== '待命') return base;
  if (!run || !run.enabled || run.completed || run.stoppedAt) return base;
  if (!session || session.stage === 'done') return base;
  if (automationSeatNeedsAction(seat)) return base;
  const id = String(provider || '').toLowerCase();
  const pending = (session.tasks || []).some((task) =>
    String(task.provider || '').toLowerCase() === id && task.status === 'pending');
  return pending ? base : '等待下一步';
}

/* 状态语气只用于一个色点和一个短标签，不改变任何发送行为。 */
function automationStatusTone(seat) {
  if (!seat) return 'is-idle';
  const status = String(seat.status || '').toLowerCase();
  if (seat.paused || status === 'paused' || status === 'stale') return 'is-error';
  if (status === 'answered') return 'is-done';
  if (status === 'unconfigured' || status === 'session-paused' || status === 'detached') return 'is-warn';
  if (status === 'idle' && seat.detail) return 'is-warn';
  if (AUTOMATION_RUNNING_STATUSES.has(status)) return 'is-running';
  return 'is-idle';
}

/* 自动还在主动驱动这一席：卡片上给出进度、原页和接管入口。
 * 暂停、失败、已停止的席位由现有手动动作处理，只补一行原因。 */
function automationSeatDriving(run, seat) {
  if (!run || !run.enabled || !seat) return false;
  if (automationSeatNeedsAction(seat)) return false;
  const status = String(seat.status || '').toLowerCase();
  if (status === 'detached') return false;
  return true;
}

function automationSeatSnapshot(run) {
  const seats = {};
  for (const [provider, seat] of Object.entries((run && run.seats) || {})) {
    seats[provider] = [
      seat && seat.taskId ? String(seat.taskId) : '',
      seat && seat.status ? String(seat.status) : '',
      seat && seat.paused ? '1' : '0',
      seat && seat.takenOver ? '1' : '0',
    ].join('|');
  }
  return {
    seats,
    enabled: Boolean(run && run.enabled),
    completed: Boolean(run && run.completed),
    stopped: Boolean(run && run.stoppedAt),
  };
}

/* 记住这次看到的逐席状态；返回这次是否出现「已写入讨论」或流程整体变化。 */
function automationSnapshotChanged(run) {
  if (!run) return false;
  const previous = state.automationSnapshot[run.id];
  const next = automationSeatSnapshot(run);
  state.automationSnapshot[run.id] = next;
  if (!previous) return false;
  if (previous.enabled !== next.enabled
    || previous.completed !== next.completed
    || previous.stopped !== next.stopped) return true;
  for (const [provider, seat] of Object.entries((run && run.seats) || {})) {
    const status = String((seat && seat.status) || '').toLowerCase();
    if (!AUTOMATION_REFRESH_STATUSES.has(status)) continue;
    if (previous.seats[provider] !== next.seats[provider]) return true;
  }
  return false;
}

function automationRunSummary(run, session) {
  const seats = session ? automationSeats(session) : [];
  const hasPublic = seats.some(isPublicAutomationSeat);
  const hasLocal = seats.some(isLocalAutomationSeat);
  if (!run) {
    if (hasPublic && hasLocal) return '自动还没开始。公开席位和本机席位都要点「开始自动化」才会发送；手动一直可用。';
    if (hasPublic) return '自动还没开始。点「开始自动化」会请求原站权限；手动复制、粘贴也一直可用。';
    return '没有启用自动。可以手动复制、粘贴和提交。';
  }
  if (run.enabled) {
    const needs = automationNeedsAction(run);
    if (needs > 0) {
      return `自动运行中，有 ${needs} 席要你处理；没处理的席位不会继续自动发送。`;
    }
    return '自动运行中，逐席进度见下；手动操作一直可用。';
  }
  if (run.completed) return '讨论已结束，自动也停了。';
  if (run.stoppedAt) return '自动已停止，原页还在，可以继续手动操作。';
  return '没有启用自动。可以手动复制、粘贴和提交。';
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
      reject(new Error('没有检测到扩展后台。请从 Chrome 扩展页打开，不要直接打开文件。'));
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
  if (!reply.session) throw new Error('后台没有返回讨论内容。');
  return reply.session;
}

async function ensureSession(reply, id) {
  if (reply && reply.session) return reply.session;
  return fetchSession(id);
}

async function actSession(action, payload) {
  const current = state.session;
  if (!current) throw new Error('当前没有打开的讨论。');
  const message = { type: 'act', id: current.id, action };
  if (payload !== undefined) message.payload = payload;
  const reply = await callBackground(message);
  return ensureSession(reply, current.id);
}

/* ------------------------------ 本机自动化通信 ------------------------------ */

async function loadAutomationInfo({ silent = true } = {}) {
  try {
    const reply = await callBackground({ type: 'automation.info' });
    state.automation.configs = reply.configs && typeof reply.configs === 'object'
      ? reply.configs
      : {};
    state.automation.runs = reply.runs && typeof reply.runs === 'object'
      ? reply.runs
      : {};
    state.automation.loaded = true;
    state.automation.error = '';
    refreshHomeAutomationHints();
    updateAutomationPanel();
    return reply;
  } catch (error) {
    state.automation.error = friendlyError(error);
    updateAutomationPanel();
    if (!silent) toast(friendlyError(error, '读取自动化状态失败'), 'error');
    return null;
  }
}

function automationEditingFocus() {
  const active = document.activeElement;
  if (!active || !(active instanceof HTMLElement)) return false;
  const tag = active.tagName;
  if (tag === 'TEXTAREA' || tag === 'INPUT' || tag === 'SELECT') return true;
  if (active.isContentEditable) return true;
  return Boolean(active.closest && active.closest('.answer-editor'));
}

/* ------------------------------ 原站权限 ------------------------------ */

function permissionsAvailable() {
  try {
    return typeof chrome !== 'undefined'
      && !!chrome.permissions
      && typeof chrome.permissions.request === 'function';
  } catch {
    return false;
  }
}

/** 权限可能早已授予（例如用户上次同意过）；用 contains 复核一次。 */
function originsGranted(origins) {
  return new Promise((resolve) => {
    try {
      if (!chrome.permissions || typeof chrome.permissions.contains !== 'function') {
        resolve(false);
        return;
      }
      chrome.permissions.contains({ origins }, (granted) => {
        resolve(Boolean(granted));
      });
    } catch {
      resolve(false);
    }
  });
}

/** "https://chatgpt.com" → "https://chatgpt.com/*"，只覆盖这一站。 */
function permissionPatternFor(id) {
  const origin = providerOrigin(id);
  if (!origin) return '';
  const { protocol, hostname } = new URL(origin);
  return `${protocol}//${hostname}/*`;
}

/**
 * 必须在点击处理函数里同步调用：Chrome 只接受用户手势触发的权限请求。
 * Promise 构造器同步执行 chrome.permissions.request，因此外层可以随后 await
 * 创建场次，手势仍然有效。拒绝授权不是错误——仍会建场，只是先按手动。
 */
function requestPublicSeatPermissions(providers) {
  const ids = (providers || []).filter(isPublicAutomationSeat);
  const origins = [...new Set(ids.map(permissionPatternFor).filter(Boolean))];
  if (!ids.length || !origins.length) {
    return Promise.resolve({ requested: false, granted: true, ids, origins, error: null });
  }
  if (!permissionsAvailable()) {
    return Promise.resolve({
      requested: false,
      granted: false,
      ids,
      origins,
      error: new Error('当前环境不能请求网页权限；请从 Chrome 的扩展页打开工作台。'),
    });
  }
  return new Promise((resolve) => {
    let settled = false;
    let timer = null;
    const settle = (granted, error) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve({ requested: true, granted: Boolean(granted), ids, origins, error: error || null });
    };
    /* 浏览器拒绝这次请求时，先确认这些来源是不是已经授权过了。 */
    const settleWithCheck = (granted, error) => {
      if (granted) {
        settle(true);
        return;
      }
      originsGranted(origins).then((already) => settle(already, error), () => settle(false, error));
    };
    timer = setTimeout(() => {
      settleWithCheck(false, new Error('浏览器在 20 秒内没有返回授权结果。'));
    }, 20000);
    try {
      chrome.permissions.request({ origins }, (granted) => {
        const lastError = chrome.runtime && chrome.runtime.lastError;
        if (lastError) {
          settleWithCheck(false, new Error(lastError.message || '浏览器没有响应授权请求。'));
          return;
        }
        settleWithCheck(granted);
      });
    } catch (error) {
      settleWithCheck(false, error);
    }
  });
}

function permissionRefusalText(permission) {
  const ids = permission && permission.ids && permission.ids.length
    ? permission.ids
    : [];
  const names = ids.map(providerName).join('、') || '原站';
  const reason = permission && permission.error && permission.error.message
    ? `（${oneLine(permission.error.message, 120)}）`
    : '';
  return `没有获得 ${names} 的原站权限${reason}。这些席位先按手动：复制提示、打开原页、粘贴回答；想自动就点「开始自动化」重新授权。`;
}

/* 用户第一次看到授权框可能要想几秒；创建工作不必一直等它。超过这个时间
 * 先按「结果未返回」建场，结果回来后只更新提示，不默默启动。 */
const PERMISSION_DECISION_WAIT_MS = 5000;

function waitForPermissionDecision(promise, ms = PERMISSION_DECISION_WAIT_MS) {
  return new Promise((resolve) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      resolve({ requested: true, granted: false, undecided: true, ids: [], origins: [], error: null });
    }, ms);
    promise.then((value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    }, () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ requested: true, granted: false, undecided: false, ids: [], origins: [], error: new Error('授权请求失败。') });
    });
  });
}

/* ------------------------------ 状态提示 ------------------------------ */

function setAutomationNotice(sessionId, kind, text) {
  if (!sessionId || !text) {
    state.automationNotice = null;
    updateAutomationPanel();
    return;
  }
  state.automationNotice = { sessionId, kind: kind || 'info', text };
  updateAutomationPanel();
}

function clearAutomationNotice(sessionId) {
  if (!state.automationNotice) return;
  if (sessionId && state.automationNotice.sessionId !== sessionId) return;
  state.automationNotice = null;
  updateAutomationPanel();
}

function automationNoticeFor(session) {
  const notice = state.automationNotice;
  if (!notice || !session || notice.sessionId !== session.id) return null;
  return notice;
}

/* ------------------------------ 轮询与事件 ------------------------------ */

function stopAutomationPolling() {
  if (state.automationPollTimer) {
    clearInterval(state.automationPollTimer);
    state.automationPollTimer = null;
  }
}

function ensureAutomationPolling() {
  if (state.view !== 'session' || !state.session) {
    stopAutomationPolling();
    return;
  }
  const run = automationRun(state.session);
  if (!run || !run.enabled) {
    stopAutomationPolling();
    return;
  }
  if (state.automationPollTimer) return;
  state.automationPollTimer = setInterval(() => {
    void pollAutomation();
  }, AUTOMATION_POLL_MS);
}

async function refreshSessionQuietly() {
  const current = state.session;
  if (!current) return false;
  try {
    const raw = await fetchSession(current.id);
    if (!state.session || state.session.id !== current.id) return false;
    applySession(raw);
    return true;
  } catch {
    return false;
  }
}

/* 只在「已写入讨论」或流程整体变化后重读场次；流式正文不进这里。 */
function scheduleAutomationSessionRefresh() {
  if (state.automationRefreshTimer) return;
  const sessionId = state.session?.id;
  state.automationRefreshTimer = setTimeout(() => {
    state.automationRefreshTimer = null;
    if (state.view !== 'session' || state.session?.id !== sessionId) return;
    if (automationEditingFocus()) {
      state.automationRefreshPending = true;
      updateAutomationPanel();
      return;
    }
    state.automationRefreshPending = false;
    void refreshSessionQuietly();
  }, 250);
}

/* 后台每次更新自动状态都会发这一条；只认当前场次，并且只改对应席位的文字。 */
function handleAutomationProgress(id, run) {
  if (!id || !run || typeof run !== 'object') return;
  state.automation.runs = { ...(state.automation.runs || {}), [id]: run };
  if (!state.session || state.session.id !== id) return;
  updateAutomationPanel();
  updateSeatAutoViews(run);
  const changed = automationSnapshotChanged(run);
  if (run.enabled) ensureAutomationPolling();
  else stopAutomationPolling();
  if (changed) scheduleAutomationSessionRefresh();
}

function bindAutomationEvents() {
  try {
    if (!chrome.runtime || !chrome.runtime.onMessage) return;
    chrome.runtime.onMessage.addListener((message) => {
      if (!message || message.type !== 'automation.progress') return;
      const run = message.run;
      const id = String(message.id || (run && run.id) || '');
      handleAutomationProgress(id, run);
    });
  } catch {
    /* 通知只是加速；定时轮询和「刷新自动状态」仍然可用。 */
  }
}

async function pollAutomation() {
  if (state.view !== 'session' || !state.session) {
    stopAutomationPolling();
    return;
  }
  if (state.automationBusy) return;

  const sessionId = state.session.id;
  const reply = await loadAutomationInfo({ silent: true });
  if (!reply) return;

  const session = state.session;
  if (!session || session.id !== sessionId) {
    stopAutomationPolling();
    return;
  }
  const run = automationRun(session);
  updateSeatAutoViews(run);
  updateAutomationPanel();

  const changed = automationSnapshotChanged(run);
  const pendingRefresh = state.automationRefreshPending && !automationEditingFocus();
  if (changed || pendingRefresh) {
    if (automationEditingFocus()) {
      state.automationRefreshPending = true;
      updateAutomationPanel();
      return;
    }
    state.automationRefreshPending = false;
    await refreshSessionQuietly();
  }

  if (!run || !run.enabled) {
    stopAutomationPolling();
    return;
  }
  ensureAutomationPolling();
}

/* ------------------------------ 启动、停止、接管 ------------------------------ */

async function startAutomation(button) {
  const session = state.session;
  if (!session || state.automationBusy) return;
  const publicSeats = automationSeats(session).filter(isPublicAutomationSeat);
  const publicNames = publicSeats.map(providerName).join('、');
  state.automationBusy = true;
  const original = button ? button.textContent : '';
  if (button) {
    button.disabled = true;
    button.textContent = publicSeats.length ? '等待授权…' : '启动中…';
  }
  try {
    /* 先授权，再启动：权限请求必须在这次点击的手势里同步发起。 */
    let permission = { requested: false, granted: true, ids: [], origins: [], error: null };
    if (publicSeats.length) {
      setAutomationNotice(session.id, 'info', `等待 Chrome 返回 ${publicNames} 的原站权限；同意后马上开始发送。`);
      permission = await requestPublicSeatPermissions(publicSeats);
      /* 已授权时不会弹窗，直接进入启动；这句把两边的情况都说清。 */
      if (permission.granted) {
        setAutomationNotice(session.id, 'info', `已获得 ${publicNames} 的原站权限，正在打开各席原页并发送本轮提示…`);
      }
    }
    const mixed = automationSeats(session).some(isLocalAutomationSeat);
    if (!permission.granted && !mixed) {
      /* 纯公开席没有权限就不启动：保留「开始自动化」按钮让用户重新授权。 */
      setAutomationNotice(session.id, 'warn', permissionRefusalText(permission));
      toast('没拿到原站权限，自动没有开始；手动操作一直可用', 'error');
      return;
    }
    await callBackground({ type: 'automation.start', id: session.id });
    await loadAutomationInfo({ silent: true });
    if (state.session) {
      state.automationSnapshot[session.id] = automationSeatSnapshot(automationRun(state.session));
    }
    await refreshSessionQuietly();
    ensureAutomationPolling();
    if (!permission.granted) {
      const mixedNotice = mixed
        ? `没拿到 ${publicNames} 的原站权限：这些席位先按手动，其他席位照常自动。要重试授权，先点「停止自动化」再点「开始自动化」。`
        : permissionRefusalText(permission);
      setAutomationNotice(session.id, 'warn', mixedNotice);
      toast('公开席位没拿到权限，只有它按手动；其他席位照常自动', 'error');
      return;
    }
    clearAutomationNotice(session.id);
    toast(publicSeats.length ? '已开始自动：逐席发送和生成进度见各席卡片' : '已开始自动：只驱动配置好的本机席位，手动操作一直可用');
  } catch (error) {
    const message = friendlyError(error, '无法开始自动化');
    setAutomationNotice(session.id, 'error', `没能开始自动：${message}。可以按手动复制、打开原页并粘贴回答。`);
    toast(message, 'error');
  } finally {
    state.automationBusy = false;
    if (button && button.isConnected) {
      button.disabled = false;
      button.textContent = original;
    }
    updateAutomationPanel();
  }
}

async function stopAutomation(button) {
  const session = state.session;
  if (!session || state.automationBusy) return;
  state.automationBusy = true;
  const original = button ? button.textContent : '';
  if (button) {
    button.disabled = true;
    button.textContent = '停止中…';
  }
  try {
    await callBackground({ type: 'automation.stop', id: session.id });
    stopAutomationPolling();
    await loadAutomationInfo({ silent: true });
    toast('自动已停止，原页还在');
  } catch (error) {
    toast(friendlyError(error, '无法停止自动化'), 'error');
  } finally {
    state.automationBusy = false;
    if (button && button.isConnected) {
      button.disabled = false;
      button.textContent = original;
    }
    updateAutomationPanel();
  }
}

/* 单席手动接管：后台停止对这一席的原页驱动，已生成的内容保留；随后用现有
 * 手动路径粘贴回答。请求带 taskId，接管只对这一席当前任务生效。 */
async function takeoverSeat(session, task, button) {
  if (!session || !task) return;
  if (state.automationBusy) return;
  state.automationBusy = true;
  const original = button ? button.textContent : '';
  if (button) {
    button.disabled = true;
    button.textContent = '接管中…';
  }
  try {
    await callBackground({
      type: 'automation.takeover',
      id: session.id,
      provider: task.provider,
      taskId: task.id,
    });
    await loadAutomationInfo({ silent: true });
    setTaskError(task.id, '');
    state.showEditor[task.id] = 'new';
    state.dismissedDraftEditors.delete(task.id);
    setAutomationNotice(
      session.id,
      'info',
      `${providerName(task.provider)} 已交给手动：自动不会再发送这一席。到原页取回回答，粘贴到这里提交。`,
    );
    state.automationSnapshot[session.id] = automationSeatSnapshot(automationRun(session));
    render();
    requestAnimationFrame(() => {
      const card = taskCardElement(task.id);
      if (!card) return;
      card.scrollIntoView({ block: 'nearest' });
      const input = card.querySelector('textarea.answer-input');
      if (input) input.focus({ preventScroll: true });
    });
    toast('已接管这一席：按手动粘贴回答');
  } catch (error) {
    const message = friendlyError(error, '无法接管这一席');
    setTaskError(task.id, message);
    toast(message, 'error');
  } finally {
    state.automationBusy = false;
    if (button && button.isConnected) {
      button.disabled = false;
      button.textContent = original;
    }
    updateAutomationPanel();
  }
}

async function refreshAutomationNow(button) {
  const session = state.session;
  if (!session) return;
  await withButton(button, '刷新中…', async () => {
    await loadAutomationInfo({ silent: false });
    state.automationSnapshot[session.id] = automationSeatSnapshot(automationRun(state.session));
    await refreshSessionQuietly();
    ensureAutomationPolling();
  });
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
          if (PROVIDER_BY_ID.has(id) && !ids.includes(id) && ids.length < MAX_SEATS) ids.push(id);
        }
        state.compose.providers = ids;
      }
    }
  } catch {
    state.compose = { question: '', providers: [] };
  }

  state.lastPair = loadLastPair();
  maybeRecallLastPair();
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

/* 只记住「上一次实际开始讨论」的两席或三席，供下一次首页直接沿用。它不创建
 * 讨论、不发送任何内容，也不覆盖已经写了一半的首页草稿。第一次使用时
 * 没有记录，首页仍保持空白，由用户自己选。 */
function loadLastPair() {
  try {
    const raw = JSON.parse(localStorage.getItem(LAST_PAIR_KEY) || 'null');
    if (!Array.isArray(raw)) return [];
    const ids = [];
    for (const value of raw) {
      const id = String(value || '').toLowerCase();
      if (PROVIDER_BY_ID.has(id) && !ids.includes(id) && ids.length < MAX_SEATS) ids.push(id);
    }
    return ids.length >= MIN_SEATS ? ids : [];
  } catch {
    return [];
  }
}

function rememberLastPair(providers) {
  const ids = [];
  for (const value of providers || []) {
    const id = String(value || '').toLowerCase();
    if (PROVIDER_BY_ID.has(id) && !ids.includes(id) && ids.length < MAX_SEATS) ids.push(id);
  }
  if (ids.length < MIN_SEATS) return;
  state.lastPair = ids;
  try {
    localStorage.setItem(LAST_PAIR_KEY, JSON.stringify(ids));
  } catch {
    /* 只影响下次是否沿用，不影响本次讨论。 */
  }
}

function maybeRecallLastPair() {
  if (!state.lastPair.length) return;
  if (state.compose.providers.length) return;
  if (state.compose.question.trim()) return;
  state.compose.providers = state.lastPair.slice();
  persistCompose();
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

/* 阶段推进后，被跳过的任务只剩 history 里的快照；用它的 stage/round/id
 * 还原同一个草稿键，保证刷新后仍能只读找回。 */
function draftForHistoryEntry(session, entry) {
  if (!session || !entry) return null;
  const key = [session.id, entry.stage, String(entry.round), String(entry.id)].join('::');
  return state.drafts[key] || null;
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
  const corrections = Array.isArray(raw.corrections)
    ? raw.corrections
      .filter((entry) => entry && typeof entry === 'object')
      .map((entry) => ({
        previousText: typeof entry.previousText === 'string' ? entry.previousText : '',
        text: typeof entry.text === 'string' ? entry.text : '',
        at: Number.isFinite(Number(entry.at)) ? Number(entry.at) : 0,
      }))
    : [];
  return {
    id,
    provider: String(raw.provider || '').toLowerCase(),
    prompt: typeof raw.prompt === 'string' ? raw.prompt : '',
    status,
    answer: typeof raw.answer === 'string' ? raw.answer : '',
    stance: STANCE_LABELS[raw.stance] ? raw.stance : undefined,
    sourceId: typeof raw.sourceId === 'string' ? raw.sourceId.trim() : '',
    /* 更正留存：首次提交原文、每次替换前后的文本与时间；只作出处，不再计一条回答。 */
    originalAnswer: typeof raw.originalAnswer === 'string' ? raw.originalAnswer : '',
    corrections,
    answeredAt: Number.isFinite(Number(raw.answeredAt)) ? Number(raw.answeredAt) : 0,
    correctedAt: Number.isFinite(Number(raw.correctedAt)) ? Number(raw.correctedAt) : 0,
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
    version: raw.version,
    proposalDigest: raw.proposalDigest,
  };
}

/* 用户补充的判断条件由后台保存，工作台只做只读展示。 */
function normalizeGuidance(raw) {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((item) => item && typeof item === 'object')
    .map((item) => ({
      text: typeof item.text === 'string' ? item.text : '',
      stage: typeof item.stage === 'string' ? item.stage : '',
      round: Number.isFinite(Number(item.round)) ? Number(item.round) : 1,
      createdAt: Number.isFinite(Number(item.createdAt)) ? Number(item.createdAt) : 0,
    }))
    .filter((item) => item.text.trim());
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
    guidance: normalizeGuidance(raw.guidance),
    report: typeof raw.report === 'string' ? raw.report : '',
    /* 核心写入的结束原因；只用于结论区状态显示，不参与任何判断。 */
    stopReason: typeof raw.stopReason === 'string' ? raw.stopReason : '',
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
  const proposal = session.stage === 'done' ? latestAnsweredProposal(session.history) : null;
  const digest = proposal ? proposalDigest(proposal) : null;
  const entries = session.history.filter((entry) => entry.stage === 'vote' && (
    session.stage !== 'done' || (proposal
      && entry.version === proposal.version
      && entry.proposalDigest === digest)
  ));
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
        sourceId: entry.sourceId,
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
  stopAutomationPolling();
  state.view = 'home';
  state.session = null;
  state.automationPanel = null;
  state.showEditor = {};
  state.dismissedDraftEditors = new Set();
  state.stanceChoice = {};
  state.taskErrors = {};
  state.taskErrorEls = new Map();
  state.promptCopied = {};
  state.nextStepPanel = null;
  state.automationNotice = null;
  state.autoSeatEls = new Map();
  state.promptStateEls = new Map();
  setHash('');
  maybeRecallLastPair();
  renderHome();
  renderHistoryList();
  void loadAutomationInfo({ silent: true });
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
          h('p', { text: '读取讨论失败。' }),
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
    listEl.append(h('div', { class: 'sidebar-empty', text: '暂无讨论' }));
    return;
  }

  const filter = state.listFilter.trim().toLowerCase();
  const sessions = filter
    ? state.sessions.filter((session) => session.question.toLowerCase().includes(filter))
    : state.sessions;

  if (!sessions.length) {
    listEl.append(h('div', { class: 'sidebar-empty', text: '没有匹配的讨论。' }));
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

/* 首页只做一件事：尽快让人写下问题、选两席并开始。接线方可以注册
 * 额外链接，不必改动这里的布局。 */
const homeExtraLinks = [];

function registerHomeLink(link) {
  if (!link || typeof link !== 'object') return;
  const label = typeof link.label === 'string' ? link.label.trim() : '';
  const href = typeof link.href === 'string' ? link.href.trim() : '';
  if (!label || !href) return;
  if (homeExtraLinks.some((item) => item.href === href && item.label === label)) return;
  homeExtraLinks.push({ label, href, title: typeof link.title === 'string' ? link.title : '' });
  if (state.view === 'home') renderHome();
}

function homeSeatTag(id) {
  if (!isAutomationSeat(id)) return '';
  if (isPublicAutomationSeat(id)) return '自动';
  if (!state.automation.loaded) return '';
  return automationConfig(id) ? '自动' : '';
}

function homeSeatModeText(id) {
  if (!isAutomationSeat(id)) return '手动';
  if (isPublicAutomationSeat(id)) return '自动（开始时授权）';
  if (!state.automation.loaded) return '读取设置中';
  return automationConfig(id) ? '自动' : '未连接，手动';
}

function joinProviderNames(providers) {
  const names = (providers || []).map(providerName).filter(Boolean);
  if (!names.length) return '';
  if (names.length === 1) return names[0];
  return `${names.slice(0, -1).join('、')} 和 ${names[names.length - 1]}`;
}

function recalledPairNote() {
  if (state.lastPair.length < MIN_SEATS) return '';
  const current = state.compose.providers;
  if (current.length !== state.lastPair.length) return '';
  if (current.some((id, index) => id !== state.lastPair[index])) return '';
  return `沿用上次的 ${joinProviderNames(state.lastPair)}。换人先点一下已选的 AI。`;
}

function homeSeatStatusText() {
  const recall = recalledPairNote();
  const summary = homeSeatModeSummary();
  return recall ? `${recall}${summary}` : summary;
}

function homeSeatModeSummary() {
  const selected = state.compose.providers;
  if (!selected.length) return `选 ${MIN_SEATS} 或 ${MAX_SEATS} 个不同的 AI 就能开始。`;

  const parts = selected.map((id, index) =>
    `${seatLetter(index)} ${providerName(id)}：${homeSeatModeText(id)}`);
  const text = parts.join(' · ');

  if (selected.length < MIN_SEATS) {
    return `${text}。再选一位才能开始；最多 ${MAX_SEATS} 席。`;
  }

  const ready = selected.length >= MAX_SEATS
    ? `已经选满 ${MAX_SEATS} 席，可以开始。`
    : `${MIN_SEATS} 席已就绪，可以开始；还能再加一席。`;

  /* 全手动时不再重复一遍 A/B/C 模式，保留一句下一步。 */
  if (selected.every((id) => !isAutomationSeat(id))) {
    return `${ready}每席都手动：复制提示到原站，再粘贴回答。`;
  }

  if (selected.some(isAutomationSeat) && !state.automation.loaded) {
    return `${text}。${ready}读完设置前可手动。`;
  }

  const publicSeats = selected.filter(isPublicAutomationSeat);
  const localSeats = selected.filter(isLocalAutomationSeat);
  const localReady = localSeats.filter((id) => automationConfig(id)).length;

  if (publicSeats.length && !localSeats.length) {
    return `${text}。${ready}点开始会请求 ${publicSeats.map(providerName).join('、')} 的原站权限；同意就直接自动发送（已授权不再弹窗），拒绝也能手动。`;
  }
  if (publicSeats.length && localSeats.length) {
    return `${text}。${ready}到讨论页点「开始自动化」时请求公开席位的权限；本机席位也在那一下开始。`;
  }
  if (localReady === 0) {
    return `${text}。${ready}本机席位未连接，按手动操作。`;
  }
  if (localReady < selected.length) {
    return `${text}。${ready}${localReady} 席可自动，其余手动；创建后点「开始自动化」，不点就手动。`;
  }
  return `${text}。${ready}每席都可自动；创建后点「开始自动化」，不点就手动。`;
}

function selectionCountText(count) {
  if (count >= MAX_SEATS) return `${count} / ${MAX_SEATS} 已选 · 已满`;
  if (count >= MIN_SEATS) return `${count} / ${MAX_SEATS} 已选 · 可开始`;
  return `${count} / ${MAX_SEATS} 已选`;
}

function focusHomeQuestion() {
  requestAnimationFrame(() => {
    if (state.view !== 'home') return;
    const active = document.activeElement;
    if (active && active !== document.body && viewEl.contains(active)) return;
    const input = document.getElementById('question-input');
    if (input) input.focus({ preventScroll: true });
  });
}

/* 其它模块可在不修改布局的前提下追加首页链接（例如本机席位设置）。 */
try {
  window.aiArenaWorkspace = Object.assign(window.aiArenaWorkspace || {}, {
    registerHomeLink,
    renderHome,
  });
} catch {
  /* 非窗口环境。 */
}

function renderHome() {
  state.view = 'home';
  state.homeRefs = null;
  state.automationPanel = null;
  state.autoSeatEls = new Map();
  state.promptStateEls = new Map();
  stopAutomationPolling();

  const refs = {
    providerButtons: new Map(),
    providerTags: new Map(),
    selectionCount: null,
    previewNames: null,
    heroTag: null,
    manualNote: null,
    manualNoteStrong: null,
    manualNoteSpan: null,
    seatStatus: null,
    seatLinks: null,
    error: null,
    errorText: null,
    start: null,
    charCount: null,
  };

  refs.heroTag = h('span', { class: 'hero-tag', hidden: true });
  const wrap = h('div', { class: 'wrap home' });
  wrap.append(
    h('header', { class: 'home-hero' },
      h('h1', { class: 'home-title', text: '想讨论什么？' }),
      refs.heroTag),
  );

  /* 问题优先：打开首页即可直接输入。 */
  const questionInput = h('textarea', {
    id: 'question-input',
    class: 'question-input',
    rows: 3,
    placeholder: '我只有两个周末，个人笔记工具先做手机版，还是先把搜索做好？',
    spellcheck: false,
    autocomplete: 'off',
    dataset: { focusKey: 'question' },
    value: state.compose.question,
    onInput: (event) => {
      state.compose.question = event.target.value;
      persistCompose();
      if (refs.charCount) {
        refs.charCount.textContent = `${Array.from(event.target.value).length} 字`;
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
    text: `${Array.from(state.compose.question).length} 字`,
  });

  /* 两席选择器：紧凑的可切换按钮，保留 button.provider-option 和 aria-pressed。 */
  const providerGrid = h('div', { class: 'provider-grid' });
  if (!PROVIDER_LIST.length) {
    providerGrid.append(
      h('div', { class: 'inline-empty' },
        h('strong', { text: '没有读到站点清单。' }),
        h('p', { text: '重新加载扩展后再试。站点清单至少要两个。' })),
    );
  } else {
    for (const provider of PROVIDER_LIST) {
      const selectedIndex = state.compose.providers.indexOf(provider.id);
      const local = isAutomationSeat(provider.id);
      const order = h('span', {
        class: 'provider-order',
        text: selectedIndex >= 0 ? seatLetter(selectedIndex) : '',
        hidden: selectedIndex < 0,
      });
      const tag = h('span', { class: 'provider-tag', text: '', hidden: true });
      const button = h('button', {
        class: [
          'provider-option',
          local ? 'is-local' : '',
          selectedIndex >= 0 ? 'is-selected' : '',
        ].filter(Boolean).join(' '),
        type: 'button',
        dataset: { providerId: provider.id },
        attrs: { 'aria-pressed': String(selectedIndex >= 0) },
        title: providerChipTitle(provider),
        onClick: () => toggleProvider(provider.id),
      },
        h('span', { class: 'provider-avatar', attrs: { 'aria-hidden': 'true' }, text: initialOf(provider.name) }),
        h('span', { class: 'provider-name', text: provider.name }),
        tag,
        order,
      );
      refs.providerButtons.set(provider.id, button);
      refs.providerTags.set(provider.id, tag);
      providerGrid.append(button);
    }
  }

  refs.selectionCount = h('span', {
    class: `selection-count${state.compose.providers.length >= MIN_SEATS ? ' is-complete' : ''}`,
    text: selectionCountText(state.compose.providers.length),
  });

  refs.seatStatus = h('p', {
    class: 'home-seat-status',
    attrs: { 'aria-live': 'polite' },
    text: homeSeatStatusText(),
  });

  refs.seatLinks = h('p', { class: 'seat-links' },
    h('a', {
      class: 'link-quiet',
      href: 'connections.html',
      target: '_blank',
      rel: 'noopener noreferrer',
      text: '连接设置',
      title: '配置本机席位的网页地址和选择器',
    }),
    ...homeExtraLinks.map((link) => h('a', {
      class: 'link-quiet',
      href: link.href,
      target: '_blank',
      rel: 'noopener noreferrer',
      text: link.label,
      title: link.title || link.label,
    })));

  refs.previewNames = h('strong', { text: previewNameText() });
  const flow = h('ol', { class: 'flow-steps' },
    h('li', {}, '第一轮同一个问题分别发给 ', refs.previewNames, '；各自回答，互相看不到。'),
    h('li', {}, '每席答完，这里给各席生成质询，带上其他席位的原话和出处。'),
    h('li', {}, '候选结论出来后，每席对同一版表态；立场、理由和条件按席位保存。'),
    h('li', {}, '最后导出结论，没解决的分歧也一起留着。'),
  );

  refs.manualNoteStrong = h('strong', { text: '全程手动' });
  refs.manualNoteSpan = h('span', { text: '不自动登录、不自动发送，也不读网页回答。' });
  refs.manualNote = h('div', { class: 'manual-note' }, refs.manualNoteStrong, refs.manualNoteSpan);

  wrap.append(
    h('section', { class: 'home-compose', attrs: { 'aria-label': '开始一场讨论' } },
      h('div', { class: 'home-question' },
        h('label', { class: 'home-field-label', for: 'question-input', text: '问题' }),
        questionInput,
        h('div', { class: 'field-foot' },
          refs.charCount,
          h('span', { class: 'kbd-hint', text: '⌘ / Ctrl + Enter 开始' }))),
      h('div', { class: 'home-seats' },
        h('div', { class: 'home-seat-head' },
          h('h2', { class: 'home-seat-title', text: '选择两个或三个 AI' }),
          refs.selectionCount),
        providerGrid,
        refs.seatStatus,
        refs.seatLinks)),
  );

  refs.errorText = h('span');
  refs.error = h('div', { class: 'inline-error', role: 'alert', hidden: true }, refs.errorText);

  refs.start = h('button', {
    class: 'btn btn-accent btn-large',
    type: 'button',
    text: '开始讨论',
    title: '创建讨论；⌘ / Ctrl + Enter 也能开始',
    onClick: () => { void startSession(); },
  });

  wrap.append(
    h('div', { class: 'start-row' },
      refs.start),
    refs.error,
    h('details', { class: 'home-guide' },
      h('summary', {},
        h('span', { class: 'home-guide-title', text: '一场讨论怎么走' }),
        h('span', { class: 'home-guide-hint', text: '4 步，随时可停' })),
      h('div', { class: 'home-guide-body' },
        h('div', { class: 'flow-card' }, flow),
        refs.manualNote)),
  );

  state.homeRefs = refs;
  refreshHomeAutomationHints();
  viewEl.replaceChildren(wrap);
  focusHomeQuestion();
}

function providerTagLabel(id) {
  if (!isAutomationSeat(id)) return '手动';
  if (isPublicAutomationSeat(id)) return '自动，开始时授权';
  if (!state.automation.loaded) return '本机，检查配置中';
  return automationConfig(id) ? '本机自动' : '本机未配置';
}

function providerChipTitle(provider) {
  if (!provider) return '';
  return [provider.note, hostOf(provider.url), providerTagLabel(provider.id)]
    .filter(Boolean)
    .join(' · ');
}

function homeAutomationSummary() {
  const selected = state.compose.providers;
  const automation = selected.filter(isAutomationSeat);
  const publicSeats = automation.filter(isPublicAutomationSeat);
  const localSeats = automation.filter(isLocalAutomationSeat);
  if (!automation.length) {
    return {
      tag: '手动',
      strong: '全程手动',
      span: '不自动登录、不自动发送，也不读网页回答。',
    };
  }
  if (publicSeats.length) {
    const names = publicSeats.map(providerName).join('、');
    if (localSeats.length) {
      return {
        tag: '公开席位可自动',
        strong: '到讨论页再开始自动',
        span: `点「开始自动化」时请求 ${names} 的原站权限，本机席位也在那一下开始；拒绝也能手动。`,
      };
    }
    return {
      tag: '开始时授权',
      strong: '开始后自动发送',
      span: `点开始会请求 ${names} 的原站权限；同意就直接自动发送，已授权时不再弹窗，拒绝也能建场并手动粘贴。`,
    };
  }
  if (!state.automation.loaded) {
    return {
      tag: '读取设置中',
      strong: '正在读取设置',
      span: '读完前不会自动；手动一直可用。',
    };
  }
  const configured = localSeats.filter((id) => automationConfig(id));
  if (!configured.length) {
    return {
      tag: '未连接设置',
      strong: '本机席位没连接',
      span: '去「连接设置」填网页地址和选择器；没填就按手动。',
    };
  }
  if (configured.length < localSeats.length) {
    return {
      tag: '部分可自动',
      strong: '要手动开始自动化',
      span: '已连接的本机席位可自动，其他手动。创建后点「开始自动化」。',
    };
  }
  if (configured.length < selected.length) {
    return {
      tag: '部分可自动',
      strong: '自动只覆盖本机席位',
      span: '其他席位仍手动。创建后点「开始自动化」，不点就全部手动。',
    };
  }
  return {
    tag: selected.length > localSeats.length ? '部分可自动' : '全部可自动',
    strong: '要手动开始自动化',
    span: '创建后点「开始自动化」才会发送；手动一直可用。',
  };
}

function refreshHomeAutomationHints() {
  const refs = state.homeRefs;
  if (!refs) return;
  const summary = homeAutomationSummary();
  if (refs.heroTag) {
    const generic = !state.compose.providers.length || summary.tag === '手动';
    refs.heroTag.hidden = generic;
    refs.heroTag.textContent = generic ? '' : summary.tag;
  }
  if (refs.manualNoteStrong) refs.manualNoteStrong.textContent = summary.strong;
  if (refs.manualNoteSpan) refs.manualNoteSpan.textContent = summary.span;
  if (refs.seatStatus) refs.seatStatus.textContent = homeSeatStatusText();
  for (const [id, tag] of refs.providerTags) {
    const label = homeSeatTag(id);
    tag.hidden = !label;
    tag.textContent = label;
    tag.classList.toggle('is-auto', label === '自动');
    const button = refs.providerButtons.get(id);
    if (!button) continue;
    button.classList.toggle('is-auto-ready', label === '自动');
    const provider = providerById(id);
    if (provider) button.title = providerChipTitle(provider);
  }
}

function previewNameText() {
  const names = state.compose.providers.map(providerName);
  if (names.length > 1) return `${names.slice(0, -1).join('、')} 与 ${names[names.length - 1]}`;
  if (names.length === 1) return `${names[0]} 与另一席`;
  return `${MIN_SEATS} 到 ${MAX_SEATS} 席`;
}

function toggleProvider(id) {
  const refs = state.homeRefs;
  if (!refs) return;
  const index = state.compose.providers.indexOf(id);
  if (index >= 0) {
    state.compose.providers.splice(index, 1);
    clearHomeError();
  } else if (state.compose.providers.length >= MAX_SEATS) {
    showHomeError(`已选满 ${MAX_SEATS} 席。先点一下已选的 AI 取消，再换人。`);
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
      order.textContent = selected ? seatLetter(index) : '';
    }
  }
  if (refs.selectionCount) {
    const count = state.compose.providers.length;
    refs.selectionCount.textContent = selectionCountText(count);
    refs.selectionCount.classList.toggle('is-complete', count >= MIN_SEATS);
  }
  if (refs.previewNames) refs.previewNames.textContent = previewNameText();
  refreshHomeAutomationHints();
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

function setStartBusy(busy, label) {
  const button = state.homeRefs?.start;
  if (!button || !button.isConnected) return;
  button.disabled = busy;
  button.textContent = busy ? (label || '正在创建…') : '开始讨论';
}

async function startSession() {
  if (state.pendingCreate) return;
  const question = state.compose.question.trim();
  const providers = state.compose.providers.map((id) => String(id).toLowerCase());

  if (!question) {
    showHomeError('先写下问题。');
    document.getElementById('question-input')?.focus();
    return;
  }
  if (providers.length < MIN_SEATS) {
    showHomeError(providers.length === 0
      ? `先选 ${MIN_SEATS} 或 ${MAX_SEATS} 个不同的 AI。`
      : `再选一位才能开始；最多 ${MAX_SEATS} 席。`);
    return;
  }
  if (providers.length > MAX_SEATS) {
    showHomeError(`最多 ${MAX_SEATS} 席。先取消一位再开始。`);
    return;
  }
  if (new Set(providers).size !== providers.length) {
    showHomeError('同一个网站只能放一席。换一位。');
    return;
  }
  for (const id of providers) {
    if (!PROVIDER_BY_ID.has(id)) {
      showHomeError('站点清单里找不到其中一位，重新选。');
      return;
    }
  }

  state.pendingCreate = true;
  clearHomeError();

  /* 权限请求必须先于任何 await 发起：这是「开始」这一次点击的手势。
   * 只有本次点击确实会启动自动（公开席、且没有本机席）时才请求；混用本机
   * 席位时，自动仍由讨论页的「开始自动化」显式启动，那一下再授权。 */
  const publicSeats = providers.filter(isPublicAutomationSeat);
  const hasLocalSeat = providers.some(isLocalAutomationSeat);
  const willAutoStart = publicSeats.length > 0 && !hasLocalSeat;
  const publicNames = publicSeats.map(providerName).join('、');
  setStartBusy(true, willAutoStart ? '等待 Chrome 授权…' : '正在创建…');
  let permission = { requested: false, granted: true, undecided: false, ids: [], origins: [], error: null };
  let pendingPermission = null;
  let autoStarted = false;
  if (willAutoStart) {
    const ask = requestPublicSeatPermissions(providers);
    permission = await waitForPermissionDecision(ask);
    if (permission.undecided) pendingPermission = ask;
    /* 已授权时 Chrome 不会再弹窗：这里直接进入自动启动，不再要求第二次点击。 */
    setStartBusy(true, permission.granted ? '正在自动启动…' : '正在创建…');
  }

  let startNotice = null;
  try {
    const reply = await callBackground({ type: 'create', question, providers });
    if (!reply.session) throw new Error('后台没有返回新讨论。');
    const session = normalizeSession(reply.session);
    if (!session) throw new Error('后台返回的讨论数据不完整。');

    /* 授权通过就在同一次开始动作里启动；拒绝或没有返回结果时不启动，保留
     * 「开始自动化」按钮供重新授权。本机 A/B 保持显式启动。 */
    if (willAutoStart && permission.granted) {
      try {
        await callBackground({ type: 'automation.start', id: session.id });
        await loadAutomationInfo({ silent: true });
        state.automationSnapshot[session.id] = automationSeatSnapshot(automationRun(session));
        autoStarted = true;
        startNotice = {
          kind: 'info',
          text: `已获得 ${publicNames} 的原站权限，已开始自动发送本轮提示。逐席进度和接管入口见各席卡片。`,
        };
      } catch (error) {
        startNotice = {
          kind: 'error',
          text: `${friendlyError(error, '已建场，但没能开始自动发送')}。每席都可以手动复制、打开原页并粘贴回答。`,
        };
      }
    } else if (willAutoStart && permission.undecided) {
      startNotice = {
        kind: 'info',
        text: '浏览器还没有返回原站授权结果。自动先不启动；授权完成后点「开始自动化」即可，手动一直可用。',
      };
    } else if (willAutoStart) {
      startNotice = { kind: 'warn', text: permissionRefusalText(permission) };
    } else if (publicSeats.length && hasLocalSeat) {
      startNotice = {
        kind: 'info',
        text: '公开席位和本机席位混用：自动要你在下面点「开始自动化」才会开始，那一下会请求原站权限；手动一直可用。',
      };
    }

    /* 授权框晚于建场才返回：只更新提示，不在这里偷偷启动。 */
    if (pendingPermission) {
      const sessionId = session.id;
      pendingPermission.then((final) => {
        if (!state.session || state.session.id !== sessionId) return;
        if (final.granted) {
          setAutomationNotice(sessionId, 'info', `已获得 ${publicNames} 的原站权限；点「开始自动化」就能自动发送。`);
        } else {
          setAutomationNotice(sessionId, 'warn', permissionRefusalText(final));
        }
      });
    }

    rememberLastPair(providers);
    state.compose = { question: '', providers: [] };
    persistCompose();

    state.session = session;
    state.view = 'session';
    state.automationNotice = startNotice
      ? { sessionId: session.id, kind: startNotice.kind, text: startNotice.text }
      : null;
    state.showEditor = {};
    state.dismissedDraftEditors = new Set();
    state.stanceChoice = {};
    state.taskErrors = {};
    state.promptCopied = {};
    state.nextStepPanel = null;
    upsertSessionSummary(session);
    setHash(session.id);
    render();
    renderHistoryList();
    window.scrollTo(0, 0);
    toast(autoStarted ? '讨论已创建，已开始自动发送' : '讨论已创建');
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
  stopAutomationPolling();
  loadToken += 1;
  const token = loadToken;
  state.view = 'loading';
  state.automationPanel = null;
  renderLoading('正在读取讨论…');

  try {
    const [raw] = await Promise.all([
      fetchSession(id),
      loadAutomationInfo({ silent: true }),
    ]);
    if (token !== loadToken) return;
    const session = normalizeSession(raw);
    if (!session) throw new Error('后台返回的讨论数据不完整。');

    state.session = session;
    state.view = 'session';
    /* 旧场次只读取现有状态，不在这里启动任何自动。 */
    state.automationSnapshot[session.id] = automationSeatSnapshot(automationRun(session));
    state.automationNotice = state.automationNotice && state.automationNotice.sessionId === session.id
      ? state.automationNotice
      : null;
    state.showEditor = {};
    state.dismissedDraftEditors = new Set();
    state.stanceChoice = {};
    state.taskErrors = {};
    state.promptCopied = {};
    state.nextStepPanel = null;
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
      maybeRecallLastPair();
      renderHome();
      renderHistoryList();
    }
    toast(friendlyError(error, '打开讨论失败'), 'error');
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
  if (!session) throw new Error('后台返回的讨论数据不完整。');
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
    body: '结束后，已收到的回答保留，没完成的席位记为缺席，不算同意。之后还能查看和导出。',
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
    body: `“${oneLine(current.question, 80)}”\n\n只删本机记录，不影响 ${names} 里的对话。删除后不能恢复。`,
    confirmLabel: '删除记录',
    danger: true,
  });
  if (!confirmed) return;

  await withButton(button, '删除中…', async () => {
    try {
      await callBackground({ type: 'delete', id: current.id });
      stopAutomationPolling();
      purgeDraftsForSession(current.id);
      state.sessions = state.sessions.filter((item) => item.id !== current.id);
      state.session = null;
      state.automationPanel = null;
      state.automationNotice = null;
      state.autoSeatEls = new Map();
  state.promptStateEls = new Map();
      state.view = 'home';
      state.showEditor = {};
      state.dismissedDraftEditors = new Set();
      state.stanceChoice = {};
      state.taskErrors = {};
      state.promptCopied = {};
      state.nextStepPanel = null;
      setHash('');
      maybeRecallLastPair();
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
  state.automationPanel = null;
  state.nextStepPanel = null;
  state.autoSeatEls = new Map();
  state.promptStateEls = new Map();

  const wrap = h('div', { class: 'wrap session' });
  wrap.append(renderSessionHeader(session), renderStepper(session));

  if (automationSeats(session).length) {
    wrap.append(renderAutomationPanel(session));
  } else {
    stopAutomationPolling();
  }

  if (session.paused && session.stage !== 'done') {
    wrap.append(renderPauseBanner(session));
  }

  const guidancePanel = renderGuidance(session);
  if (guidancePanel) wrap.append(guidancePanel);

  if (session.stage === 'done') {
    wrap.append(renderReport(session));
  } else {
    wrap.append(renderStage(session));
  }

  wrap.append(renderHistory(session));
  viewEl.replaceChildren(wrap);
  ensureAutomationPolling();
}

function renderAutomationPanel(session) {
  const seats = automationSeats(session);
  const hasPublic = seats.some(isPublicAutomationSeat);
  const hasLocal = seats.some(isLocalAutomationSeat);

  const summaryEl = h('span', { class: 'auto-panel-summary' });
  const noticeEl = h('p', { class: 'auto-notice', role: 'status', hidden: true });
  const seatListEl = h('div', { class: 'auto-seat-list' });
  const rows = new Map();

  for (const provider of seats) {
    const dot = h('span', { class: 'auto-dot', attrs: { 'aria-hidden': 'true' } });
    const name = h('span', { class: 'auto-seat-name', text: providerName(provider) });
    const stateEl = h('span', { class: 'auto-seat-state', text: '待命' });
    const detailEl = h('span', { class: 'auto-seat-detail', text: '' });
    seatListEl.append(h('div', {
      class: 'auto-seat-row',
      dataset: { provider },
    }, dot, name, stateEl, detailEl));
    rows.set(provider, { dot, stateEl, detailEl });
  }

  const startButton = h('button', {
    class: 'btn btn-small btn-strong',
    type: 'button',
    text: '开始自动化',
  });
  startButton.addEventListener('click', () => { void startAutomation(startButton); });

  const stopButton = h('button', {
    class: 'btn btn-small',
    type: 'button',
    text: '停止自动化',
  });
  stopButton.addEventListener('click', () => { void stopAutomation(stopButton); });

  const refreshButton = h('button', {
    class: 'btn btn-small btn-ghost',
    type: 'button',
    text: '刷新自动状态',
  });
  refreshButton.addEventListener('click', () => { void refreshAutomationNow(refreshButton); });

  const settingsLink = hasLocal ? h('a', {
    class: 'link-quiet',
    href: 'connections.html',
    target: '_blank',
    rel: 'noopener noreferrer',
    text: '连接设置',
    title: '配置本机席位的网页地址和选择器',
  }) : null;

  const panel = h('section', {
    class: 'auto-panel',
    attrs: { 'aria-label': hasPublic ? '自动发送' : '本机自动' },
  },
    h('div', { class: 'auto-panel-head' },
      h('strong', { class: 'auto-panel-title', text: hasPublic ? '自动发送' : '本机自动' }),
      summaryEl),
    noticeEl,
    seatListEl,
    h('div', { class: 'auto-panel-actions' }, startButton, stopButton, refreshButton, settingsLink));

  state.automationPanel = {
    sessionId: session.id,
    seats,
    hasPublic,
    hasLocal,
    summaryEl,
    noticeEl,
    rows,
    startButton,
    stopButton,
    refreshButton,
  };
  updateAutomationPanel();
  return panel;
}

function canStartAutomationSeat(provider) {
  if (isPublicAutomationSeat(provider)) return true;
  return Boolean(automationConfig(provider));
}

function updateAutomationPanel() {
  const panel = state.automationPanel;
  if (!panel || !panel.summaryEl) return;
  const session = state.session;
  if (!session || session.id !== panel.sessionId) return;

  const run = automationRun(session);
  let summary = automationRunSummary(run, session);
  if (state.automation.error) {
    summary = `${summary} 读取自动状态失败：${oneLine(state.automation.error, 120)}`;
  }
  if (state.automationRefreshPending) {
    summary = `${summary} 有新的自动进展；结束当前编辑后会自动刷新。`;
  }
  panel.summaryEl.textContent = summary;

  /* 授权被拒、启动失败这类配置问题要一直留在页面上，不只是弹一条提示。 */
  const notice = automationNoticeFor(session);
  const errorText = !notice && state.automation.error
    ? `读取自动状态失败：${oneLine(state.automation.error, 160)}`
    : '';
  const shown = notice ? notice.text : errorText;
  panel.noticeEl.hidden = !shown;
  if (shown) {
    panel.noticeEl.className = `auto-notice is-${notice ? notice.kind : 'error'}`;
    panel.noticeEl.textContent = shown;
  }

  for (const [provider, refs] of panel.rows) {
    const seat = automationSeatState(run, provider);
    const tone = automationStatusTone(seat);
    refs.dot.className = `auto-dot ${tone}`;
    refs.stateEl.className = `auto-seat-state ${tone}`;
    refs.stateEl.textContent = automationSeatContextLabel(seat, run, session, provider);
    const detailParts = [];
    if (seat && seat.detail) detailParts.push(String(seat.detail));
    if (isLocalAutomationSeat(provider) && !automationConfig(provider)) {
      detailParts.push('未连接设置，按手动');
    }
    refs.detailEl.textContent = detailParts.join(' · ');
  }

  const startable = panel.seats.filter(canStartAutomationSeat);
  const active = Boolean(run && run.enabled);
  panel.startButton.hidden = active || session.stage === 'done';
  panel.startButton.disabled = state.automationBusy || startable.length === 0;
  if (!startable.length) {
    panel.startButton.title = '先在连接设置保存本机席位的网页地址和选择器';
  } else if (panel.hasPublic) {
    panel.startButton.title = '会先请求原站权限再开始发送；复制、粘贴和提交一直可用';
  } else {
    panel.startButton.title = '手动开始自动发送；复制、粘贴和提交一直可用';
  }
  panel.stopButton.hidden = !active;
  panel.stopButton.disabled = state.automationBusy;
  panel.refreshButton.hidden = !active;
  panel.refreshButton.disabled = state.automationBusy;
}

function renderSessionHeader(session) {
  const seats = session.providers.map((provider, index) => {
    const seat = seatLetter(index).toLowerCase();
    let seatTitle = '原站席位：手动复制提示、粘贴回答';
    if (isPublicAutomationSeat(provider)) {
      seatTitle = '公开席位：开始讨论时按站申请权限，授权后自动发送；也能手动粘贴';
    } else if (isAutomationSeat(provider)) {
      seatTitle = automationConfig(provider)
        ? '本机席位：可以手动，也可以在连接设置后自动'
        : '本机席位：还没保存地址，只能手动';
    }
    const mode = automationSeatMode(session, provider);
    const modeClass = /待处理|未配置/.test(mode)
      ? 'provider-tag is-issue'
      : (mode === '自动' ? 'provider-tag is-auto' : 'provider-tag');
    return h('span', {
      class: `seat-meta seat-meta-${seat}`,
      title: seatTitle,
    }, h('span', { class: 'seat-dot', attrs: { 'aria-hidden': 'true' } }),
      `席 ${seatLetter(index)} · ${providerName(provider)}`,
      h('span', { class: modeClass, text: mode }));
  });

  const statusText = session.stage === 'done'
    ? '已结束'
    : session.paused ? '已暂停' : '进行中';

  return h('header', { class: 'session-head' },
    h('div', { class: 'session-eyebrow' },
      h('span', { text: '讨论' }),
      h('span', { class: 'dot-sep', attrs: { 'aria-hidden': 'true' }, text: '·' }),
      h('span', { class: session.paused ? 'status-paused' : '', text: statusText }),
      h('span', { class: 'round-chip', text: `${session.providers.length} 席参与` }),
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
    title: '重新读取本机保存的讨论',
  });
  refreshButton.addEventListener('click', () => { void refreshSession(refreshButton); });
  toolbar.append(refreshButton);

  if (session.stage !== 'done') {
    const pauseButton = h('button', {
      class: 'btn',
      type: 'button',
      text: session.paused ? '继续讨论' : '暂停',
      title: session.paused ? '继续推进后面的阶段' : '暂停后面的阶段，草稿保留',
    });
    pauseButton.addEventListener('click', () => { void togglePause(pauseButton); });
    toolbar.append(pauseButton);

    const finishButton = h('button', {
      class: 'btn',
      type: 'button',
      text: '结束讨论',
      title: '保留现有回答，按当前结果结束',
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
      h('span', { text: '后面的阶段不会推进。提示还能看、能复制；草稿保留，继续后可以提交。' })),
    button);
}

/* 暂停时补充的判断条件：只在独立作答与交叉质询两段出现。它只写入后台
 * 记录，供之后新建的任务使用；不修改当前提示，也不触发任何发送。 */
function guidanceStageLabel(stage) {
  return stage ? stageInfo(stage).label : '未注明阶段';
}

function renderGuidance(session) {
  const entries = Array.isArray(session.guidance) ? session.guidance : [];
  const canAdd = session.paused && (session.stage === 'independent' || session.stage === 'critique');
  if (!entries.length && !canAdd) return null;

  const countEl = h('span', {
    class: 'guide-count',
    text: entries.length ? `${entries.length} 条已保存` : '',
  });

  const section = h('section', {
    class: 'guide-panel',
    attrs: { 'aria-labelledby': 'guide-title' },
  },
    h('div', { class: 'guide-head' },
      h('h2', { class: 'guide-title', id: 'guide-title', text: '补充判断条件' }),
      countEl),
    h('p', {
      class: 'guide-note',
      id: 'guide-note',
      text: '只用于之后新建的任务，不改当前提示，也不自动发送。条件随记录保存。',
    }));

  if (entries.length) {
    const list = h('ol', { class: 'guide-list', attrs: { 'aria-label': '已保存的判断条件' } });
    for (const entry of entries) {
      list.append(h('li', { class: 'guide-item' },
        h('p', { class: 'guide-text', text: entry.text }),
        h('p', {
          class: 'guide-meta',
          text: `${guidanceStageLabel(entry.stage)} · 第 ${entry.round} 轮`,
        })));
    }
    section.append(list);
  }

  if (canAdd) {
    const input = h('textarea', {
      class: 'guide-input',
      rows: 2,
      value: '',
      spellcheck: false,
      autocomplete: 'off',
      id: 'guide-input',
      dataset: { focusKey: 'guide' },
      placeholder: '例如：预算上限是两万元；没有实测数据时不要给确定结论。',
      attrs: { 'aria-describedby': 'guide-note' },
    });
    const errorEl = h('div', { class: 'task-error', role: 'alert', hidden: true });
    const saveButton = h('button', {
      class: 'btn btn-small btn-strong',
      type: 'button',
      text: '保存条件',
      title: '保存到讨论记录，供之后新建的任务使用',
    });
    saveButton.addEventListener('click', () => {
      void saveGuidance(session, input, saveButton, errorEl);
    });
    input.addEventListener('keydown', (event) => {
      if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
        event.preventDefault();
        void saveGuidance(session, input, saveButton, errorEl);
      }
    });

    section.append(h('div', { class: 'guide-form' },
      h('label', { class: 'field-label', for: 'guide-input', text: '要补充的条件' }),
      input,
      h('div', { class: 'guide-actions' }, saveButton),
      errorEl));
  }

  return section;
}

async function saveGuidance(session, textarea, button, errorEl) {
  const text = textarea.value.trim();
  const fail = (message) => {
    errorEl.textContent = message;
    errorEl.hidden = false;
    textarea.focus();
  };
  if (!text) {
    fail('先写下要补充的条件。');
    return;
  }
  if (button.disabled) return;

  button.disabled = true;
  button.textContent = '保存中…';
  errorEl.hidden = true;
  try {
    const raw = await actSession('guide', { text });
    const next = normalizeSession(raw);
    if (!next) throw new Error('后台返回的讨论数据不完整。');
    commitSession(next);
    toast('条件已保存，只用于后面的任务');
  } catch (error) {
    if (button.isConnected) {
      button.disabled = false;
      button.textContent = '保存条件';
    }
    const message = friendlyError(error, '保存失败');
    if (errorEl.isConnected) {
      errorEl.textContent = message;
      errorEl.hidden = false;
    }
    toast(message, 'error');
  }
}

function renderStage(session) {
  const info = stageInfo(session.stage);
  const tasks = session.tasks;
  const nextTask = pickNextTask(session, tasks);
  const counts = {
    answered: tasks.filter((task) => task.status === 'answered').length,
    skipped: tasks.filter((task) => task.status === 'skipped').length,
  };
  const remaining = tasks.length - counts.answered - counts.skipped;
  /* 自动正在驱动、且已有具体状态的席位，卡上已写「正在发送 / 正在生成」；
   * 不再并列算进「待回答」，只保留还没拿到具体状态的席位。 */
  const run = automationRun(session);
  counts.auto = tasks.filter((task) => {
    if (task.status !== 'pending') return false;
    const provider = String(task.provider || '').toLowerCase();
    const seat = run ? automationSeatState(run, provider) : null;
    if (!seat || !automationSeatDriving(run, seat)) return false;
    return AUTOMATION_RUNNING_STATUSES.has(String(seat.status || '').toLowerCase());
  }).length;
  counts.pending = remaining - counts.auto;

  const section = h('section', { class: 'stage', attrs: { 'aria-labelledby': 'stage-title' } });
  const countLine = h('div', { class: 'stage-count' },
    h('span', { text: `本阶段 ${tasks.length} 席 · 已收到 ${counts.answered} / ${tasks.length}` }),
    counts.skipped ? h('span', { class: 'count-skip', text: `跳过 ${counts.skipped}` }) : null,
    counts.auto ? h('span', { class: 'count-auto', text: `自动中 ${counts.auto}` }) : null,
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
        h('strong', { text: '这一阶段还没有任务。' }),
        h('p', { text: '可能还在生成下一步。刷新看看，或稍后再看。' }),
        refresh),
    );
    return section;
  }

  const nextStep = renderNextStep(session, nextTask);
  if (nextStep) section.append(nextStep);

  /* 有空间时三席并排；两席、单席各有自己的列宽。窄屏由 CSS 收回成两列或一列。 */
  const layoutClass = tasks.length === 1 ? ' is-single' : tasks.length === 3 ? ' is-triple' : '';
  const grid = h('div', { class: `seat-grid${layoutClass}` });
  tasks.forEach((task, index) => {
    grid.append(renderTaskCard(session, task, index, nextTask ? nextTask.id : ''));
  });
  section.append(grid);

  if (remaining === 0) {
    const refresh = h('button', { class: 'btn btn-small', type: 'button', text: '刷新状态' });
    refresh.addEventListener('click', () => { void refreshSession(refresh); });
    section.append(
      h('div', { class: 'all-terminal-note' },
        h('span', { text: '这一轮的任务都结束了。' }),
        h('span', { text: '界面还停在这里，就刷新一次看看。' }),
        refresh),
    );
  }

  return section;
}

/* ------------------------------ 下一步 ------------------------------ */

/* 只挑仍要手动中转的一席作为「下一步」：有草稿的先继续，否则按席位顺序。
 * 自动席位由自动化面板负责，不在这里催；暂停时顶部暂停条优先。 */
function pickNextTask(session, tasks) {
  if (!session || !Array.isArray(tasks)) return null;
  const pending = tasks.filter((task) => task.status === 'pending');
  if (!pending.length) return null;
  const manual = pending.filter((task) =>
    seatOperatesManually(session, String(task.provider || '').toLowerCase()));
  if (!manual.length) return null;
  const withDraft = manual.find((task) => {
    const draft = getDraft(session, task);
    return draft && String(draft.text || '').trim();
  });
  return withDraft || manual[0];
}

function nextStepCopy(session, task) {
  const providerId = String(task.provider || '').toLowerCase();
  const index = session.providers.indexOf(providerId);
  const label = `席 ${seatLetter(index >= 0 ? index : 0)} · ${providerName(providerId)}`;
  const draft = getDraft(session, task);
  if (draft && String(draft.text || '').trim()) {
    return {
      title: `下一步：继续填写 ${label}`,
      body: '草稿已保存在本机；提交后这一席才算收到。',
      action: '继续填写',
      mode: 'draft',
    };
  }
  if (state.promptCopied[task.id]) {
    return {
      title: `下一步：粘回 ${label} 的回答`,
      body: '提示已复制。在原页发送、复制回答，回到这里粘贴提交。',
      action: session.stage === 'vote' ? '记录表态' : '粘贴回答',
      mode: 'paste',
    };
  }
  const title = session.stage === 'critique'
    ? `下一步：把质询提示发给 ${label}`
    : session.stage === 'proposal'
      ? `下一步：让 ${label} 起草候选结论`
      : session.stage === 'vote'
        ? `下一步：让 ${label} 明确表态`
        : `下一步：把提示发给 ${label}`;
  return {
    title,
    body: '复制提示并切到原页；拿到回答后回来粘贴提交。',
    action: '复制并打开原页',
    mode: 'handoff',
  };
}

function buildNextStepChildren(session, task) {
  const copy = nextStepCopy(session, task);
  const action = h('button', {
    class: 'btn btn-small btn-strong',
    type: 'button',
    text: copy.action,
  });
  action.addEventListener('click', () => {
    if (copy.mode === 'handoff') void copyPromptAndOpen(session, task, action);
    else openTaskFromStep(task);
  });
  return [
    h('div', {},
      h('strong', { text: copy.title }),
      h('span', { text: copy.body })),
    action,
  ];
}

function renderNextStep(session, task) {
  if (!task || session.paused) return null;
  const strip = h('div', {
    class: 'pause-banner',
    role: 'status',
    attrs: { 'aria-label': '当前可执行的下一步' },
  });
  strip.append(...buildNextStepChildren(session, task));
  state.nextStepPanel = { container: strip, taskId: task.id };
  return strip;
}

function updateNextStepPanel() {
  const panel = state.nextStepPanel;
  if (!panel || !panel.container || !panel.container.isConnected) return;
  const session = state.session;
  if (!session) return;
  const task = session.tasks.find((item) => item.id === panel.taskId);
  if (!task || task.status !== 'pending') return;
  panel.container.replaceChildren(...buildNextStepChildren(session, task));
}

function markPromptCopied(taskId) {
  if (!taskId) return;
  state.promptCopied[taskId] = true;
  updateNextStepPanel();
}

function taskCardElement(taskId) {
  const value = String(taskId || '');
  const escaped = (window.CSS && CSS.escape)
    ? CSS.escape(value)
    : value.replace(/["\\]/g, '\\$&');
  return viewEl.querySelector(`article.seat-card[data-task-id="${escaped}"]`);
}

/* 显式点击「继续填写 / 粘贴回答」才定位；普通刷新和提交不会把正在编辑的
 * 席位滚走。 */
function openTaskFromStep(task) {
  if (!task) return;
  state.showEditor[task.id] = task.status === 'answered' ? 'edit' : 'new';
  state.dismissedDraftEditors.delete(task.id);
  render();
  requestAnimationFrame(() => {
    const card = taskCardElement(task.id);
    if (!card) return;
    card.scrollIntoView({ block: 'nearest' });
    const input = card.querySelector('textarea.answer-input');
    if (input) input.focus({ preventScroll: true });
  });
}

/* 只有「本轮仍未冻结」的手动公共席位回答才允许改正录入。
 * 后台 core 会按同样条件再校验一次，并以预期旧文本拒绝过期或重复提交。 */
const CORRECTABLE_STAGES = new Set(['independent', 'critique']);

function isCorrectedAnswer(task) {
  return Boolean(task) && (
    Number(task.correctedAt) > 0
    || (Array.isArray(task.corrections) && task.corrections.length > 0)
  );
}

function canCorrectTask(session, task) {
  if (!session || !task) return false;
  if (!CORRECTABLE_STAGES.has(session.stage)) return false;
  if (task.status !== 'answered') return false;
  if (!String(task.answer || '').trim()) return false;
  /* 本机席位由驱动写入，后台一律拒绝改正；公开席位只有没在自动驱动时才
   * 允许人工改正，避免和原页答案分叉。 */
  if (isLocalAutomationSeat(task.provider)) return false;
  if (!seatOperatesManually(session, String(task.provider || '').toLowerCase())) return false;
  if (!session.tasks.some((item) => item.id === task.id)) return false;
  return session.tasks.some((item) => item.id !== task.id && item.status === 'pending');
}

function revisionChip() {
  return h('span', {
    class: 'revision-chip',
    text: '已更正',
    title: '录入后被更正；首次提交原文仍保留在本席记录里',
  });
}

/* 只展示出处，不把原文再算成一条回答。 */
function renderRevisionDetails(task) {
  if (!isCorrectedAnswer(task)) return null;
  const original = typeof task.originalAnswer === 'string' ? task.originalAnswer : '';
  if (!original.trim()) return null;
  const corrections = Array.isArray(task.corrections) ? task.corrections : [];
  const stamp = [];
  if (Number(task.answeredAt) > 0) stamp.push(`首次提交 ${formatAbsolute(task.answeredAt)}`);
  if (Number(task.correctedAt) > 0) stamp.push(`最近更正 ${formatAbsolute(task.correctedAt)}`);
  if (corrections.length > 1) stamp.push(`共更正 ${corrections.length} 次`);

  const details = h('details', { class: 'prompt-box prompt-box-revision' },
    h('summary', {},
      h('span', { text: '更正前后' }),
      h('span', { class: 'prompt-hint', text: '首次原文保留' })));
  if (stamp.length) {
    details.append(h('p', { class: 'answer-note', text: stamp.join(' · ') }));
  }
  details.append(
    h('pre', { class: 'prompt-text', text: original }),
    h('div', { class: 'prompt-actions' },
      h('button', {
        class: 'btn btn-small',
        type: 'button',
        text: '复制首次原文',
        onClick: async () => {
          try {
            await copyText(original);
            toast('已复制首次提交原文');
          } catch (error) {
            toast(friendlyError(error, '复制失败'), 'error');
          }
        },
      })));
  return details;
}

/* ------------------------------ 席卡上的自动进度 ------------------------------ */

/* 停掉这一席的自动发送，保留已读到的预览；进度区和故障区共用同一个按钮。 */
function seatTakeoverButton(session, task) {
  const button = h('button', {
    class: 'btn btn-small',
    type: 'button',
    text: '手动接管',
    title: '停止这一席的自动发送；已生成的内容保留，之后按手动粘贴回答',
  });
  button.addEventListener('click', () => { void takeoverSeat(session, task, button); });
  return button;
}

/* 只在自动仍在驱动这一席时渲染：发送确认、生成中、已完成和失败原因都写在
 * 这张卡上，不动其他席位的内容。preview 一律按纯文本写入。 */
function renderSeatAuto(session, task, providerId, seat) {
  const entry = {
    provider: providerId,
    taskId: String((seat && seat.taskId) || ''),
    root: null,
    dot: h('span', { class: 'auto-dot', attrs: { 'aria-hidden': 'true' } }),
    stateEl: h('span', { class: 'seat-auto-state' }),
    detailEl: h('span', { class: 'seat-auto-detail' }),
    previewHead: h('div', { class: 'seat-auto-preview-meta', hidden: true },
      h('span', { class: 'seat-auto-preview-label', text: '原页正文' }),
      h('span', { class: 'seat-auto-preview-hint', text: `来自 ${providerName(providerId)} 原页 · 生成中` })),
    previewEl: h('pre', { class: 'seat-auto-preview', hidden: true }),
  };

  const openButton = h('button', {
    class: 'btn btn-small btn-ghost',
    type: 'button',
    text: '打开原页',
    title: '打开这一席的对话页；自动标签会被复用',
  });
  openButton.addEventListener('click', () => { void openProviderSite(session, task, openButton); });

  entry.root = h('section', {
    class: 'seat-auto',
    dataset: { provider: providerId, taskId: entry.taskId },
    attrs: { 'aria-label': `${providerName(providerId)} 的自动进度` },
  },
    h('div', { class: 'seat-auto-head' },
      entry.dot,
      entry.stateEl,
      entry.detailEl),
    entry.previewHead,
    entry.previewEl,
    h('div', { class: 'seat-auto-actions' }, openButton, seatTakeoverButton(session, task)));

  state.autoSeatEls.set(providerId, entry);
  applySeatAutoView(entry, seat, automationRun(session), session);
  return entry.root;
}

/* 需要处理的席位：先给原页和接管两个入口，再由现有手动动作负责粘贴或跳过。
 * 讨论整体暂停时不提供接管，避免把暂停误当成这一席故障。 */
function renderSeatAutoIssue(session, task, providerId, seat) {
  const preview = seatPreviewText(seat, task.id);
  const status = String((seat && seat.status) || '').toLowerCase();
  const canTakeover = Boolean(seat) && !seat.takenOver && status !== 'session-paused';
  const openButton = h('button', {
    class: 'btn btn-small btn-ghost',
    type: 'button',
    text: '打开原页',
  });
  openButton.addEventListener('click', () => { void openProviderSite(session, task, openButton); });
  return h('div', {
    class: 'seat-auto seat-auto-issue',
    dataset: { provider: providerId },
  },
    h('div', { class: 'seat-auto-head' },
      h('span', { class: 'auto-dot is-error', attrs: { 'aria-hidden': 'true' } }),
      h('span', { class: 'seat-auto-state is-error', text: automationSeatLabel(seat) }),
      h('span', {
        class: 'seat-auto-detail',
        text: seat && seat.detail ? String(seat.detail) : '这一席不会自动重发；核对原页后手动粘贴或跳过。',
      })),
    preview && h('div', { class: 'seat-auto-preview-meta' },
      h('span', { class: 'seat-auto-preview-label', text: '原页正文' }),
      h('span', { class: 'seat-auto-preview-hint', text: `来自 ${providerName(providerId)} 原页 · 尚未保存` })),
    preview && h('pre', {
      class: 'seat-auto-preview',
      text: preview,
      attrs: { 'aria-label': '来自原页、尚未保存的网页正文' },
    }),
    h('div', { class: 'seat-auto-actions' },
      openButton,
      canTakeover ? seatTakeoverButton(session, task) : null));
}

/* 后台把正在生成的正文放在 seat.preview = { taskId, text, … }。只有同一任务的
 * 片段才会显示；它永远不会被当作回答。 */
function seatPreviewText(seat, taskId) {
  const preview = seat && seat.preview;
  if (!preview || typeof preview !== 'object') return '';
  if (typeof preview.text !== 'string' || !preview.text) return '';
  if (taskId && preview.taskId && preview.taskId !== taskId) return '';
  if (taskId && seat.taskId && seat.taskId !== taskId) return '';
  return preview.truncated ? `…\n${preview.text}` : preview.text;
}

function applySeatAutoView(entry, seat, run, session) {
  if (!entry || !entry.root) return;
  const tone = automationStatusTone(seat);
  entry.dot.className = `auto-dot ${tone}`;
  entry.stateEl.className = `seat-auto-state ${tone}`;
  entry.stateEl.textContent = automationSeatContextLabel(seat, run, session, entry.provider);
  entry.detailEl.textContent = seat && seat.detail ? String(seat.detail) : '';

  const status = String((seat && seat.status) || '').toLowerCase();
  const preview = seatPreviewText(seat, entry.taskId);
  const showPreview = Boolean(preview) && status !== 'answered';
  const el = entry.previewEl;
  const nearBottom = el.hidden
    || (el.scrollHeight - el.scrollTop - el.clientHeight) < 24;
  if (el.textContent !== preview) el.textContent = preview;
  el.hidden = !showPreview;
  if (entry.previewHead) entry.previewHead.hidden = !showPreview;
  if (showPreview) {
    /* 流式时跟随到底部，但用户往上翻看时不动滚动位置。 */
    if (nearBottom) el.scrollTop = el.scrollHeight;
  }
  entry.root.dataset.status = status;
  entry.root.classList.toggle('is-running', tone === 'is-running');
  entry.root.classList.toggle('is-done', tone === 'is-done');
  entry.root.classList.toggle('is-error', tone === 'is-error');
}

/* 从 automation.progress 只增量更新仍显示同一任务的席卡；不重绘整页。 */
function updateSeatAutoViews(run) {
  updatePromptStatusViews();
  if (!run || !state.autoSeatEls) return;
  for (const [provider, entry] of state.autoSeatEls) {
    if (!entry || !entry.root || !entry.root.isConnected) continue;
    const seat = automationSeatState(run, provider);
    if (!seat) continue;
    const taskId = String(seat.taskId || '');
    if (entry.taskId && taskId && entry.taskId !== taskId) continue;
    applySeatAutoView(entry, seat, run, state.session);
  }
}

function renderTaskCard(session, task, fallbackIndex, nextTaskId) {
  const providerId = String(task.provider || '').toLowerCase();
  const seatIndex = session.providers.indexOf(providerId);
  const seat = seatLetter(seatIndex >= 0 ? seatIndex : fallbackIndex);
  const seatClass = `seat-${seat.toLowerCase()}`;
  const name = providerName(providerId);
  const draft = getDraft(session, task);
  const hasDraft = Boolean(draft && (String(draft.text || '').trim() || draft.stance));
  const dismissed = state.dismissedDraftEditors.has(task.id);
  const mode = state.showEditor[task.id];
  const terminal = task.status !== 'pending';
  /* 已回答、已跳过都是本轮终态：后台拒绝再次提交，不再自动展开草稿编辑器。 */
  const editorOpen = !terminal && (Boolean(mode) || (hasDraft && !dismissed));
  const correctable = canCorrectTask(session, task);
  const correcting = correctable && mode === 'correct';
  const isNext = Boolean(nextTaskId) && task.id === nextTaskId;

  const card = h('article', {
    class: [
      'seat-card',
      `is-${task.status}`,
      editorOpen || correcting ? 'is-editing' : '',
      isNext ? 'is-next' : '',
      seatClass,
    ].filter(Boolean).join(' '),
    dataset: { taskId: task.id, provider: providerId },
  });

  const statusChip = h('span', {
    class: `status-chip is-${task.status}`,
    text: statusLabel(task.status),
  });

  const autoRun = isAutomationSeat(providerId) ? automationRun(session) : null;
  const autoSeat = autoRun ? automationSeatState(autoRun, providerId) : null;
  const autoDriving = automationSeatDriving(autoRun, autoSeat);
  /* 需要人工处理的自动席已有「自动待处理」和具体原因，不再并排一个「待回答」。 */
  const autoIssue = Boolean(
    autoRun && autoRun.enabled && autoSeat && automationSeatNeedsAction(autoSeat));
  const header = h('div', { class: 'seat-top' },
    h('div', { class: 'seat-identity' },
      h('span', { class: `seat-badge seat-badge-${seat.toLowerCase()}`, text: seat }),
      h('div', {},
        h('div', { class: 'seat-name', text: name }),
        h('div', { class: 'seat-sub' },
          `${providerId || '未登记站点'} · 席 ${seat}`,
          h('span', { class: 'provider-tag', text: automationSeatMode(session, providerId) })))),
    h('div', { class: 'seat-status' },
      isNext ? h('span', { class: 'draft-chip', text: '下一步' }) : null,
      hasDraft && !editorOpen && !terminal ? h('span', { class: 'draft-chip', text: '有草稿' }) : null,
      autoSeat && !terminal && automationSeatNeedsAction(autoSeat) && !autoSeat.takenOver
        ? h('span', { class: 'draft-chip', text: '自动待处理', title: autoSeat.detail || '' })
        : null,
      isCorrectedAnswer(task) ? revisionChip() : null,
      terminal || (!autoDriving && !autoIssue) ? statusChip : null));
  card.append(header, renderPromptBox(session, task));

  /* 自动仍在驱动这一席：把发送确认、生成正文和接管入口放在这张卡上。 */
  if (!terminal && autoDriving) {
    const autoRow = renderSeatAuto(session, task, providerId, autoSeat);
    if (autoRow) card.append(autoRow);
  } else if (!terminal && autoSeat && automationSeatNeedsAction(autoSeat)) {
    card.append(renderSeatAutoIssue(session, task, providerId, autoSeat));
  }

  const actions = h('div', { class: 'task-actions' });

  /* 每个动作沿用原来的点击处理，只按席卡状态决定露在正面还是「更多操作」里。 */
  const copyPromptButton = () => h('button', {
    class: 'btn btn-small',
    type: 'button',
    text: '复制提示',
    title: '复制本轮发送给这一席的完整提示',
    onClick: () => copyPrompt(task),
  });

  const openSiteButton = () => {
    const button = h('button', {
      class: 'btn btn-small',
      type: 'button',
      text: '打开原站',
      title: `用已登录的浏览器打开 ${name}`,
    });
    button.addEventListener('click', () => { void openProviderSite(session, task, button); });
    return button;
  };

  const editorButton = (label, variant = 'btn-strong') => {
    const button = h('button', {
      class: `btn btn-small${variant ? ` ${variant}` : ''}`,
      type: 'button',
      text: label,
    });
    button.addEventListener('click', () => {
      state.showEditor[task.id] = 'new';
      state.dismissedDraftEditors.delete(task.id);
      render();
    });
    return button;
  };

  /* 退路动作收进原生 details：单独复制、直接打开、跳过都还在。 */
  const moreActions = (...extra) => {
    const details = h('details', { class: 'task-more' },
      h('summary', { class: 'task-more-summary', text: '更多操作' }));
    const body = h('div', { class: 'task-more-body' },
      copyPromptButton(),
      openSiteButton(),
      ...extra);
    if (!terminal && !editorOpen) body.append(renderSkipRow(session, task, null));
    details.append(body);
    return details;
  };

  if (terminal) {
    /* 终态只留已保存内容与出处：不再提供修改、补录、跳过或再次提交。 */
    if (task.status === 'answered') {
      const savedText = typeof task.answer === 'string' ? task.answer : '';
      if (savedText.trim()) {
        actions.append(h('button', {
          class: 'btn btn-small btn-strong',
          type: 'button',
          text: '复制回答',
          title: '复制这一席已保存的回答原文',
          onClick: async () => {
            try {
              await copyText(savedText);
              toast('已复制回答原文');
            } catch (error) {
              toast(friendlyError(error, '复制失败'), 'error');
            }
          },
        }));
      }
    }
    if (correctable) {
      /* 只有可改正时，才把入口收进「更多操作」，正面仍只留复制回答。 */
      const correction = h('button', {
        class: 'btn btn-small',
        type: 'button',
        text: '改正录入',
        title: '仅本轮其他席位尚未提交时可用；保存后本席仍只算一条回答',
      });
      correction.addEventListener('click', () => {
        state.correctionBase[task.id] = typeof task.answer === 'string' ? task.answer : '';
        state.showEditor[task.id] = 'correct';
        setTaskError(task.id, '');
        render();
      });
      actions.append(moreActions(correction));
    } else {
      actions.append(copyPromptButton(), openSiteButton());
    }
  } else if (seatOperatesManually(session, providerId)) {
    /* 原生 append 会把 null 当文本插进去；这里统一走 appendChildren 过滤。 */
    appendChildren(actions, [
      h('button', {
        class: 'btn btn-small btn-accent',
        type: 'button',
        text: '复制提示并打开原页',
        title: '一次点完：复制本轮提示并切到这一席的原页；已绑定的原页会复用当前标签',
        dataset: { taskId: task.id },
        onClick: (event) => copyPromptAndOpen(session, task, event.currentTarget),
      }),
      editorOpen ? null : editorButton(hasDraft ? '继续草稿' : '粘贴回答'),
      moreActions(),
    ]);
  } else {
    /* 自动席位已在跑：不摆手动主按钮，状态和接管入口都在上面的进度区。 */
    actions.append(moreActions(editorOpen ? null : editorButton(hasDraft ? '继续草稿' : '手动填写', '')));
  }

  /* 原页正文 / 生成预览之后紧接保存后的回答，动作按钮放最后，避免打断阅读。 */
  card.append(renderAnswerBlock(session, task, isNext));
  if (!terminal && session.stage === 'critique') {
    appendChildren(card, [renderCritiqueContext(session, task, session.round)]);
  }
  card.append(actions);

  const errorEl = h('div', {
    class: 'task-error',
    role: 'alert',
    text: state.taskErrors[task.id] || '',
    hidden: !state.taskErrors[task.id],
  });
  state.taskErrorEls.set(task.id, errorEl);

  if (correcting) {
    card.append(renderCorrectionEditor(session, task, errorEl));
  } else if (editorOpen) {
    card.append(renderEditor(session, task, { mode, draft, hasDraft, errorEl }));
  } else {
    card.append(errorEl);
  }

  return card;
}

/* 后台回执只认当前任务的 dispatch 记录：同一席、相位已经过原页用户消息核对。
 * 复制提示、点按钮或自动流程刚开始都不会产生这里说的「已确认发送」。 */
function taskDispatchReceipt(session, task) {
  if (!session || !task) return null;
  if (!isAutomationSeat(task.provider)) return null;
  const run = automationRun(session);
  if (!run || !run.dispatch || typeof run.dispatch !== 'object') return null;
  const taskId = String(task.id || '');
  if (!taskId) return null;
  const item = run.dispatch[taskId];
  if (!item || typeof item !== 'object') return null;
  const provider = String(task.provider || '').toLowerCase();
  if (String(item.provider || '').toLowerCase() !== provider) return null;
  const phase = String(item.phase || '').toLowerCase();
  if (!CONFIRMED_DISPATCH_PHASES.has(phase)) return null;
  const seat = automationSeatState(run, provider);
  if (seat && seat.taskId && String(seat.taskId) !== taskId) return null;
  return item;
}

/* 提示入口只描述这一轮提示的发送状态，不参与任何判断。 */
function taskPromptStatus(session, task) {
  if (task.status === 'skipped') {
    return { tone: 'skipped', label: '已跳过', title: '这一席本轮没有发送提示' };
  }
  const receipt = taskDispatchReceipt(session, task);
  if (receipt) {
    const at = Number(receipt.at);
    return {
      tone: 'sent',
      label: '已确认发送',
      title: Number.isFinite(at) && at > 0
        ? `后台核对了这一轮的用户消息 · ${formatTime(at)}`
        : '后台核对了这一轮的用户消息',
    };
  }
  if (task.status === 'answered') {
    return { tone: 'manual', label: '手动录入', title: '这一席的回答是粘贴进来的，没有自动发送回执' };
  }
  const provider = String(task.provider || '').toLowerCase();
  const run = automationRun(session);
  const seat = run ? automationSeatState(run, provider) : null;
  const status = String((seat && seat.status) || '').toLowerCase();
  if (seat && String(seat.taskId || '') === String(task.id || '')
    && SENDING_DISPATCH_PHASES.has(status)) {
    return {
      tone: 'sending',
      label: '发送中 · 待核对',
      title: '正在原页发送；后台核对到用户消息后才会标记已确认发送',
    };
  }
  return { tone: 'ready', label: '准备发送', title: '提示已保存在本机；还没有后台发送回执' };
}

function applyPromptStatus(entry, session) {
  if (!entry || !entry.el || !entry.el.isConnected) return;
  const task = (session.tasks || []).find((item) => item.id === entry.taskId);
  if (!task) return;
  const status = taskPromptStatus(session, task);
  const className = `prompt-status is-${status.tone}`;
  if (entry.el.className !== className) entry.el.className = className;
  if (entry.el.textContent !== status.label) entry.el.textContent = status.label;
  const title = status.title || '';
  if (entry.el.title !== title) entry.el.title = title;
}

function updatePromptStatusViews() {
  if (!state.session || !state.promptStateEls) return;
  for (const entry of state.promptStateEls.values()) applyPromptStatus(entry, state.session);
}

/* 提示默认只露出一行摘要，点开才读精确全文；摘要不会把三席的回答挤出首屏。 */
function renderPromptBox(session, task) {
  const prompt = typeof task.prompt === 'string' ? task.prompt : '';
  const status = taskPromptStatus(session, task);
  const statusEl = h('span', {
    class: `prompt-status is-${status.tone}`,
    text: status.label,
    title: status.title || '',
  });
  state.promptStateEls.set(task.id, { el: statusEl, taskId: task.id });
  const details = h('details', { class: 'prompt-box' },
    h('summary', {},
      h('span', { class: 'prompt-head' },
        h('span', { class: 'prompt-title', text: '本轮提示原文' }),
        statusEl),
      h('span', { class: 'prompt-hint', text: prompt ? '读全文' : '未保存' }),
      h('span', {
        class: 'prompt-excerpt',
        text: prompt ? oneLine(prompt, 120) : '这一轮没有保存提示原文。',
      })));
  if (prompt) {
    details.append(
      h('pre', { class: 'prompt-text', text: prompt }),
      h('div', { class: 'prompt-actions' },
        h('button', {
          class: 'btn btn-small',
          type: 'button',
          text: '复制这一份',
          onClick: () => copyPrompt(task),
        })));
  }
  return details;
}

function renderAnswerBlock(session, task, isNext) {
  if (task.status === 'answered') {
    const block = h('div', { class: 'answer-block' });
    const head = h('div', { class: 'answer-head' },
      h('span', { class: 'answer-label', text: session.stage === 'vote' ? '本轮表态' : '已收到的原文' }),
      task.answeredAt > 0 ? h('span', {
        class: 'answer-label',
        text: formatAbsolute(task.answeredAt),
        title: '工作台收到完整回答的时间',
      }) : null);
    if (task.stance) head.append(stanceChip(task.stance));
    if (isCorrectedAnswer(task)) head.append(revisionChip());
    const answer = task.answer && task.answer.trim()
      ? task.answer
      : '未保存回答文本。';
    block.append(head);
    if (session.stage === 'critique') {
      appendChildren(block, [renderCritiqueContext(session, task, session.round)]);
    }
    block.append(h('div', { class: 'answer-text', text: answer }));
    const revision = renderRevisionDetails(task);
    if (revision) block.append(revision);
    return block;
  }

  if (task.status === 'skipped') {
    const block = h('div', { class: 'answer-block is-muted' },
      h('div', { class: 'answer-head' }, h('span', { class: 'answer-label', text: '本阶段缺席' })),
      h('p', { class: 'answer-note', text: '已跳过，本轮不计入结论。' }));
    if (session.stage === 'critique') {
      appendChildren(block, [renderCritiqueContext(session, task, session.round)]);
    }
    const draft = getDraft(session, task);
    if (draft) block.append(renderUnsubmittedDraft(draft));
    return block;
  }

  return h('p', {
    class: 'answer-note',
    text: isNext
      ? '这一席是当前下一步；收到回答后粘贴到这里提交。'
      : session.stage === 'proposal'
        ? '这一席负责起草候选结论；收到后交给所有席位确认。'
        : '同一轮的其他席位；每席都收到后才进入下一阶段。',
  });
}

/* 草稿只作本机只读留存：可看、可复制，但不会进入回答、逐席确认或报告。 */
function renderUnsubmittedDraft(draft) {
  const text = draft && typeof draft.text === 'string' ? draft.text : '';
  const details = h('details', { class: 'prompt-box' },
    h('summary', {},
      h('span', { text: '未提交的草稿' }),
      h('span', { class: 'prompt-hint', text: '只读 · 不计入结论' })));
  if (text.trim()) {
    details.append(
      h('pre', { class: 'prompt-text', text }),
      h('div', { class: 'prompt-actions' },
        h('button', {
          class: 'btn btn-small',
          type: 'button',
          text: '复制草稿原文',
          onClick: async () => {
            try {
              await copyText(text);
              toast('已复制草稿原文');
            } catch (error) {
              toast(friendlyError(error, '复制失败'), 'error');
            }
          },
        })));
  } else {
    details.append(h('p', {
      class: 'answer-note',
      text: '这份草稿没有文字，只有未提交的立场。',
    }));
  }
  return details;
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

  /* 「清除草稿」只按此刻的草稿显示：文字或立场任一非空即可清除。
   * 输入和选择立场时即时同步按钮，不重绘输入框、不抢焦点。 */
  const hasLiveDraft = () => Boolean(textarea.value.trim() || state.stanceChoice[task.id]);
  let syncClearButton = () => {};

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
        syncClearButton();
        noteEl.textContent = '草稿已保存';
        setTaskError(task.id, '');
      });
      stanceButtons.push(button);
      stanceGroup.append(button);
    }
    editor.append(stanceGroup);
    editor.append(h('span', {
      class: 'field-label',
      text: '理由（必填，会存为回答原文）',
    }));
  } else {
    editor.append(h('span', {
      class: 'field-label',
      text: session.stage === 'proposal' ? '候选结论原文' : '回答原文',
    }));
  }

  editor.append(textarea);

  if (session.paused) {
    editor.append(h('p', { class: 'editor-paused-note', text: '已暂停：草稿可以继续改，继续讨论后再提交。' }));
  }

  const noteEl = h('span', {
    class: 'draft-note',
    text: draft ? '已恢复本机草稿' : '草稿自动保存在本机',
  });
  textarea.addEventListener('input', () => {
    updateDraftForTask(session, task, textarea.value, state.stanceChoice[task.id] || '');
    syncClearButton();
    noteEl.textContent = '草稿已保存';
    setTaskError(task.id, '');
  });

  const footer = h('div', { class: 'editor-foot' });
  footer.append(noteEl);

  const actionWrap = h('div', { class: 'editor-actions' });

  /* 按钮常驻，只切换显示：首次输入后立刻能清除，删空文字后自动隐藏。 */
  const clearButton = h('button', {
    class: 'btn btn-small btn-ghost',
    type: 'button',
    text: '清除草稿',
    hidden: !hasDraft,
    onClick: async () => {
      const confirmed = await confirmDialog({
        title: '清除这一席的草稿？',
        /* 投票席的草稿含立场与理由，只提「文本」会漏掉立场，确认语要按阶段说清。 */
        body: session.stage === 'vote'
          ? '清除本席未提交的本地立场和理由，已保存的回答不动。'
          : '只清除这段没提交的本地文本，已保存的回答不动。',
        confirmLabel: '清除草稿',
        danger: true,
      });
      if (!confirmed) return;
      deleteDraft(session, task);
      /* 立场也是草稿的一部分：确认清除后立场一并归零；取消则两者都不动。 */
      delete state.stanceChoice[task.id];
      state.dismissedDraftEditors.delete(task.id);
      state.showEditor[task.id] = task.status === 'answered' ? 'edit' : 'new';
      render();
      toast('草稿已清除');
    },
  });
  actionWrap.append(clearButton);
  syncClearButton = () => {
    clearButton.hidden = !hasLiveDraft();
  };

  actionWrap.append(h('button', {
    class: 'btn btn-small',
    type: 'button',
    text: '收起',
    onClick: () => {
      delete state.showEditor[task.id];
      /* 按点击当下的草稿判断：刚输入、尚未重绘的草稿也要收起，避免立刻重开。 */
      if (hasLiveDraft()) state.dismissedDraftEditors.add(task.id);
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

/* 改正录入只针对当前已收到的一条回答：预填最新原文，提交预期旧文本，
 * 由后台拒绝别人已经改过或本轮已冻结的情况。 */
function renderCorrectionEditor(session, task, errorEl) {
  const editor = h('div', { class: 'answer-editor correction-editor' });
  editor.append(h('span', {
    class: 'field-label',
    text: '改正录入：粘贴这一席更正后的完整原文',
  }));

  const textarea = h('textarea', {
    class: 'answer-input correction-input',
    rows: 6,
    value: typeof task.answer === 'string' ? task.answer : '',
    spellcheck: false,
    autocomplete: 'off',
    dataset: { focusKey: `correction:${task.id}` },
    placeholder: editorPlaceholder(session.stage),
    attrs: { 'aria-label': `${providerName(task.provider)} 的更正原文` },
  });
  editor.append(textarea);
  editor.append(h('p', {
    class: 'answer-note',
    text: '保存后本席仍只算一条回答；下一阶段的提示会使用更正后的原文，首次提交原文保留在「更正前后」里。',
  }));

  const footer = h('div', { class: 'editor-foot' });
  footer.append(h('span', {
    class: 'draft-note',
    text: '只要本轮还有待答席位就能保存；过期或重复提交会被后台拒绝。',
  }));

  const actionWrap = h('div', { class: 'editor-actions' });
  actionWrap.append(h('button', {
    class: 'btn btn-small',
    type: 'button',
    text: '取消',
    onClick: () => {
      delete state.showEditor[task.id];
      delete state.correctionBase[task.id];
      setTaskError(task.id, '');
      render();
    },
  }));

  const submitButton = h('button', {
    class: 'btn btn-small btn-strong',
    type: 'button',
    text: '保存更正',
    disabled: session.paused,
    title: session.paused ? '讨论已暂停，继续后可保存' : '',
  });
  actionWrap.append(submitButton);
  footer.append(actionWrap);
  editor.append(footer, errorEl);

  submitButton.addEventListener('click', () => {
    void submitCorrection(session, task, { textarea, submitButton });
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
    title: session.paused ? '讨论已暂停，继续后可跳过' : '本阶段记为缺席，不算同意',
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
    setTaskError(task.id, '讨论已暂停。继续后再提交，草稿还在。');
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
    setTaskError(task.id, '先选明确立场：同意、有条件同意或反对。');
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
    if (!next) throw new Error('后台返回的讨论数据不完整。');

    deleteDraft(session, task);
    delete state.promptCopied[task.id];
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

async function submitCorrection(session, task, { textarea, submitButton }) {
  const current = state.session;
  if (!current) return;
  if (current.paused) {
    setTaskError(task.id, '讨论已暂停。继续后再保存更正，原文暂时不变。');
    return;
  }

  const text = textarea.value.trim();
  if (!text) {
    setTaskError(task.id, '先粘贴这一席更正后的完整回答原文。');
    textarea.focus();
    return;
  }
  if (text === task.answer) {
    setTaskError(task.id, '内容没有变化；直接取消即可。');
    textarea.focus();
    return;
  }

  /* 打开编辑器时看到的原文才是预期旧文本。后台只在它仍等于已保存回答时
   * 接受，这样另一个窗口的更正或一次重复点击不会被静默覆盖。 */
  const previousText = typeof state.correctionBase[task.id] === 'string'
    ? state.correctionBase[task.id]
    : (typeof task.answer === 'string' ? task.answer : '');

  const oldText = submitButton.textContent;
  submitButton.disabled = true;
  submitButton.textContent = '保存中…';
  textarea.readOnly = true;
  setTaskError(task.id, '');

  try {
    const raw = await actSession('correct', {
      taskId: task.id,
      text,
      previousText,
      stage: current.stage,
      round: current.round,
    });
    const next = normalizeSession(raw);
    if (!next) throw new Error('后台返回的讨论数据不完整。');
    delete state.correctionBase[task.id];
    commitSession(next);
    toast('已更正录入；下一阶段使用更正后的原文');
  } catch (error) {
    setTaskError(task.id, friendlyError(error, '更正失败，已保存原文未变'));
    submitButton.disabled = false;
    submitButton.textContent = oldText;
    textarea.readOnly = false;
  }
}

async function skipTask(session, task, skipButton, submitButton) {  const current = state.session;
  if (!current) return;
  if (current.paused) {
    setTaskError(task.id, '讨论已暂停，继续后再处理缺席。');
    return;
  }

  const name = providerName(task.provider);
  const existingDraft = getDraft(session, task);
  const draftNote = existingDraft
    ? '本机还留着这份未提交的草稿；跳过不会删除，之后可只读查看和复制，但不能再提交。'
    : '当前没有未提交的草稿；跳过之后不能再补录或提交。';
  const confirmed = await confirmDialog({
    title: `跳过席 ${seatLetter(Math.max(0, session.providers.indexOf(task.provider)))}？`,
    body: `${name} 在这一阶段记为缺席，本轮不计入结论。${draftNote}`,
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
    if (!next) throw new Error('后台返回的讨论数据不完整。');
    delete state.promptCopied[task.id];
    state.dismissedDraftEditors.add(task.id);
    commitSession(next);
    toast('已跳过，本轮不计入结论');
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
    toast('这一席没有提示原文，复制不了。', 'error');
    return;
  }
  try {
    await copyText(prompt);
    markPromptCopied(task.id);
    toast('已复制提示');
  } catch (error) {
    toast(friendlyError(error, '复制失败'), 'error');
  }
}

/* 自动驱动没有接管时，这一席仍需手动中转。 */
function seatOperatesManually(session, providerId) {
  if (!isAutomationSeat(providerId)) return true;
  const run = automationRun(session);
  if (!run || !run.enabled) return true;
  const seat = automationSeatState(run, providerId);
  if (!seat) return false;
  if (automationSeatNeedsAction(seat)) return true;
  return seat.status === 'detached';
}

/* 一次点击完成复制和打开原页。复制失败时绝不声称已复制；两边分开报告，
 * 保留「复制提示」「打开原站」作为各自独立的退路。 */
async function copyPromptAndOpen(session, task, button) {
  if (!session || !task) return;
  if (button && button.disabled) return;
  const prompt = typeof task.prompt === 'string' ? task.prompt : '';
  if (!prompt.trim()) {
    toast('这一席没有提示原文，复制不了。', 'error');
    return;
  }

  const original = button ? button.textContent : '';
  if (button) {
    button.disabled = true;
    button.textContent = '复制并打开…';
  }

  let copyError = null;
  let openError = null;
  try {
    await copyText(prompt);
  } catch (error) {
    copyError = error;
  }
  if (!copyError) markPromptCopied(task.id);
  try {
    await callBackground({ type: 'open', id: session.id, provider: task.provider });
  } catch (error) {
    openError = error;
  }

  if (button && button.isConnected) {
    button.disabled = false;
    button.textContent = original;
  }

  if (!copyError && !openError) {
    toast('已复制提示并切到原页');
    return;
  }
  if (!copyError) {
    toast(friendlyError(openError, '提示已复制，原页没打开。可以点「打开原站」再试'), 'error');
    return;
  }
  if (!openError) {
    toast(friendlyError(copyError, '提示没复制成功，原页已打开。回来点「复制提示」再试'), 'error');
    return;
  }
  toast(friendlyError(copyError, '复制与打开都失败'), 'error');
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

const SOURCE_CITE_MS = 3200;
const citeTimers = new WeakMap();

function sourceAnchorId(sourceId) {
  return `source-${String(sourceId || '').toLowerCase().replace(/[^a-z0-9_-]/g, '')}`;
}

function reportSourceIndex(session) {
  const index = new Map();
  for (const entry of session.history) {
    if (entry.sourceId) index.set(entry.sourceId, entry);
  }
  for (const task of session.tasks) {
    if (task.sourceId && !index.has(task.sourceId)) index.set(task.sourceId, task);
  }
  return index;
}

function highlightSource(sourceId, block = 'center') {
  const target = document.getElementById(sourceAnchorId(sourceId));
  if (!target) {
    toast(`这场讨论没有找到 ${sourceId} 的原文`, 'error');
    return;
  }
  let smooth = true;
  try {
    smooth = !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  } catch {
    /* 保持默认滚动。 */
  }
  target.scrollIntoView({ behavior: smooth ? 'smooth' : 'auto', block });
  try {
    target.focus({ preventScroll: true });
  } catch {
    /* 个别环境禁止脚本聚焦，滚动定位仍然有效。 */
  }
  target.classList.remove('is-cited');
  void target.offsetWidth;
  target.classList.add('is-cited');
  const previous = citeTimers.get(target);
  if (previous) clearTimeout(previous);
  citeTimers.set(target, setTimeout(() => target.classList.remove('is-cited'), SOURCE_CITE_MS));
}

function reportCitation(sourceId, { label, block } = {}) {
  return h('a', {
    class: 'report-cite',
    href: `#${sourceAnchorId(sourceId)}`,
    dataset: { sourceId },
    title: `跳到 ${sourceId} 的原文`,
    attrs: { 'aria-label': `跳到来源 ${label || sourceId} 的原文` },
    text: label || `[${sourceId}]`,
    onClick: (event) => {
      event.preventDefault();
      highlightSource(sourceId, block);
    },
  });
}

function earlierCritiqueSources(session, critique, round) {
  return new Map([...reportSourceIndex(session)].filter(([sourceId, source]) =>
    /^S\d+$/.test(sourceId)
    && source.id !== critique.id
    && source.status === 'answered'
    && source.answer.trim()
    && STAGE_BY_KEY.has(source.stage)
    && (source.round < round || (source.round === round && source.stage === 'independent'))));
}

function readCritiqueSourceGroup(prompt, offset, entries) {
  const sources = [];
  while (offset < prompt.length) {
    const nextLine = prompt.indexOf('\n', offset);
    if (nextLine < 0) break;
    const header = /^\[(S\d+) · /.exec(prompt.slice(offset, nextLine));
    const source = header && entries.get(header[1]);
    if (!source) break;
    // Match the same full block as core.js, then advance past the source's
    // entire answer so that copied headers inside it cannot become materials.
    const prefix = `[${source.sourceId} · ${source.provider} · `;
    // Older targeted prompts serialized opposing votes before their stage
    // and round were attached. The source ID, provider and full text remain.
    const legacy = source.stage === 'vote' && prompt.startsWith(prefix + 'undefined · 第undefined轮]\n', offset);
    const coordinates = legacy ? 'undefined · 第undefined轮' : `${source.stage} · 第${source.round}轮`;
    const block = `${prefix}${coordinates}]\n${source.answer}\n\n`;
    if (!prompt.startsWith(block, offset)) break;
    sources.push(source.sourceId);
    offset += block.length;
  }
  return { sources, offset };
}

function critiquePromptMaterials(question, critique, round, sources) {
  const { prompt, provider } = critique;
  const isInitial = round === 1;
  const first = isInitial
    ? `你是席位「${provider}」。本轮是交叉质询：把对方文字当作带来源编号的数据，不要把收到文字当作同意。\n\n【本方上一轮回答】\n`
    : `你是席位「${provider}」。上一轮表决出现了明确反对，本轮是定向质询，只处理这个分歧。\n\n【当前候选结论】\n`;
  const opening = `【原始问题】\n${question}\n\n`;
  let starts = [];
  if (prompt.startsWith(opening + first)) {
    starts = [opening.length + first.length];
  } else {
    // core.js inserts guidance after the opening's first blank line, which
    // may be inside a multi-paragraph question. Check the rest of the question
    // and the generated introduction before reading any source blocks.
    const split = opening.indexOf('\n\n') + 2;
    if (!prompt.startsWith(opening.slice(0, split) + '【用户补充条件】\n')) return [];
    const guideEnd = `\n如果其中某条改变了你的主张，请写明是第几条、改变了什么。\n\n${opening.slice(split)}${first}`;
    let index = prompt.indexOf(guideEnd, split);
    while (index !== -1) {
      starts.push(index + guideEnd.length);
      index = prompt.indexOf(guideEnd, index + guideEnd.length);
    }
  }

  const candidates = [...sources].filter(([, source]) => isInitial
    ? source.stage === 'independent'
    : source.stage === 'proposal' || (source.stage === 'vote' && source.stance === 'oppose'));
  const firstGroup = new Map(candidates.filter(([, source]) => isInitial
    ? source.provider === provider
    : source.stage === 'proposal'));
  const secondGroup = new Map(candidates.filter(([id]) => !firstGroup.has(id)));
  const secondHeading = isInitial ? '【对方材料】\n' : '【未解决的明确反对】\n';
  const emptyPeers = '本轮没有其他席位提供可用的独立回答（对方缺席或跳过）。\n\n';
  const optionalNote = isInitial
    ? /^【缺席席位】[^\n]*（缺席、跳过或超时都不能算作同意）\n\n/
    : /^你上一轮明确选择了反对。请重新检验自己的反对理由，也明确说明什么证据会改变它。\n\n/;
  const closing = isInitial
    ? '不要用礼貌性同意代替证据和推理。'
    : '不要声称已经达成共识；只有每位席位对同一版本明确同意才算共识。';
  for (const start of starts) {
    const firstEnd = readCritiqueSourceGroup(prompt, start, firstGroup);
    if (firstEnd.sources.length !== 1 || !prompt.startsWith(secondHeading, firstEnd.offset)) continue;

    const secondEnd = readCritiqueSourceGroup(prompt, firstEnd.offset + secondHeading.length, secondGroup);
    let tail = prompt.slice(secondEnd.offset);
    if (isInitial && tail.startsWith(emptyPeers)) tail = tail.slice(emptyPeers.length);
    tail = tail.replace(optionalNote, '');
    if (!tail.startsWith('请完成：\n') || tail.indexOf('\n\n') !== tail.length - closing.length - 2
      || !tail.endsWith(closing)) continue;
    return [...new Set([...firstEnd.sources, ...secondEnd.sources])];
  }
  return [];
}

function renderCritiqueContext(session, critique, round) {
  const sources = earlierCritiqueSources(session, critique, round);
  const cited = critique.status === 'answered'
    ? [...new Set(critique.answer.match(/\bS\d+\b/g) || [])].filter((id) => sources.has(id))
    : [];
  const materials = critiquePromptMaterials(session.question, critique, round, sources);
  if (!cited.length && !materials.length) return null;

  const context = h('div', { class: 'critique-context' });
  if (cited.length) {
    context.append(h('div', { class: 'critique-citations' },
      h('span', { text: '回复提到的来源' }),
      cited.map((id) => reportCitation(id, { block: 'start' }))));
  }
  if (materials.length) {
    context.append(h('div', { class: 'critique-materials' },
      h('span', { text: '本轮提示中的材料' }),
      materials.map((id) => {
        const source = sources.get(id);
        const own = source.provider === critique.provider ? ' · 本席' : '';
        return reportCitation(id, {
          label: `[${id}] ${providerName(source.provider)} · 第${source.round}轮${own}`,
          block: 'start',
        });
      })));
  }
  return context;
}

function appendReportInline(parent, text, sources) {
  const value = String(text ?? '');
  const token = /(\*\*[^*]+\*\*|`[^`]+`|\[S\d+\])/g;
  let lastIndex = 0;
  for (const match of value.matchAll(token)) {
    if (match.index > lastIndex) parent.append(document.createTextNode(value.slice(lastIndex, match.index)));
    const piece = match[0];
    if (piece.startsWith('**') && piece.endsWith('**') && piece.length > 4) {
      parent.append(h('strong', { text: piece.slice(2, -2) }));
    } else if (piece.startsWith('`')) {
      parent.append(h('code', { text: piece.slice(1, -1) }));
    } else {
      const sourceId = piece.slice(1, -1);
      if (sources.has(sourceId)) parent.append(reportCitation(sourceId));
      else parent.append(document.createTextNode(piece));
    }
    lastIndex = match.index + piece.length;
  }
  if (lastIndex < value.length) parent.append(document.createTextNode(value.slice(lastIndex)));
}

function reportParagraph(text, sources) {
  const paragraph = h('p', { class: 'report-md-p' });
  const lines = String(text ?? '').split('\n');
  lines.forEach((line, index) => {
    if (index) paragraph.append(h('br'));
    appendReportInline(paragraph, line, sources);
  });
  return paragraph;
}

function reportHeading(level, text, sources) {
  const depth = Math.max(1, Math.min(4, Number(level) || 1));
  const tag = depth <= 2 ? 'h3' : depth === 3 ? 'h4' : 'h5';
  const heading = h(tag, { class: `report-md-heading report-md-h${depth}` });
  appendReportInline(heading, text, sources);
  return heading;
}

function renderReportMarkdown(markdown, session) {
  const root = h('div', { class: 'report-md' });
  const sources = new Set(reportSourceIndex(session).keys());
  const lines = String(markdown ?? '').split(/\r?\n/);
  let index = 0;

  while (index < lines.length) {
    const line = lines[index];
    if (!line.trim()) {
      index += 1;
      continue;
    }

    const heading = /^(#{1,4})\s+(.+)$/.exec(line);
    if (heading) {
      root.append(reportHeading(heading[1].length, heading[2].trim(), sources));
      index += 1;
      continue;
    }

    if (/^[-*]\s+/.test(line)) {
      const list = h('ul', { class: 'report-md-list' });
      while (index < lines.length && /^[-*]\s+/.test(lines[index])) {
        const item = h('li', {});
        appendReportInline(item, lines[index].replace(/^[-*]\s+/, ''), sources);
        list.append(item);
        index += 1;
      }
      root.append(list);
      continue;
    }

    if (/^>\s?/.test(line)) {
      const quoteLines = [];
      while (index < lines.length && /^>\s?/.test(lines[index])) {
        quoteLines.push(lines[index].replace(/^>\s?/, ''));
        index += 1;
      }
      const quote = h('blockquote', { class: 'report-md-quote' });
      quote.append(reportParagraph(quoteLines.join('\n'), sources));
      root.append(quote);
      continue;
    }

    const paragraphLines = [];
    while (
      index < lines.length
      && lines[index].trim()
      && !/^(#{1,4})\s+/.test(lines[index])
      && !/^[-*]\s+/.test(lines[index])
      && !/^>\s?/.test(lines[index])
    ) {
      paragraphLines.push(lines[index]);
      index += 1;
    }
    root.append(reportParagraph(paragraphLines.join('\n'), sources));
  }

  return root;
}

/* 以下只把报告拆成展示小节，报告原文、导出和判断都不变。 */
const REPORT_STATUS_COPY = {
  consensus: { label: '全体一致', tone: 'good', note: '每位都明确同意同一候选版本。' },
  'conditional-agreement': { label: '有条件一致', tone: 'warn', note: '至少一席附加了条件，不等于无条件同意。' },
  'unresolved-opposition': { label: '仍有明确反对', tone: 'warn', note: '当前版本未形成共识。' },
  'partial-votes': { label: '部分完成', tone: 'warn', note: '有席位未对当前版本明确表态，不计为同意。' },
  'partial-participation': { label: '部分完成', tone: 'warn', note: '参与席位不齐，不构成全体一致。' },
  'no-cross-review': { label: '部分完成', tone: 'warn', note: '交叉质询未齐，不构成全体一致。' },
  draft: { label: '草稿', tone: 'draft', note: '候选缺少可核实的出处编号，未形成可核验的一致。' },
  'proposal-skipped': { label: '未形成候选', tone: 'draft', note: '候选结论没有完成，未进入有效表决。' },
  'no-critique': { label: '部分完成', tone: 'warn', note: '缺少可用的质询材料。' },
  partial: { label: '部分完成', tone: 'warn', note: '讨论未完整走完，不构成全体一致。' },
  'no-answers': { label: '没有可用回答', tone: 'draft', note: '尚未收到可用的独立回答。' },
  'user-finished': { label: '提前结束', tone: 'neutral', note: '讨论未走完，以下是阶段记录。' },
};

const REPORT_REASON_PREFIXES = {
  全体一致: 'consensus',
  有条件一致: 'conditional-agreement',
  未解决分歧: 'unresolved-opposition',
  部分完成: 'partial',
  未形成结论: 'no-answers',
  草稿: 'draft',
};

function reportSections(markdown) {
  const sections = new Map();
  let current = null;
  for (const line of String(markdown ?? '').split(/\r?\n/)) {
    const heading = /^##\s+(.+?)\s*$/.exec(line);
    if (heading) {
      current = { title: heading[1], lines: [] };
      sections.set(current.title, current);
      continue;
    }
    if (current) current.lines.push(line);
  }
  return sections;
}

function reportSectionText(section) {
  if (!section) return '';
  const lines = section.lines.slice();
  while (lines.length && !lines[0].trim()) lines.shift();
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  return lines.join('\n');
}

/* 结束原因取核心写入的 stopReason；缺失时只按报告的状态行兜底。 */
function reportReasonOf(session, sections) {
  const reason = String(session.stopReason || '');
  if (reason) return reason;
  const statusLines = (sections.get('状态')?.lines || []).map((line) => line.trim());
  const first = statusLines.find((line) => /^-\s+/.test(line));
  const text = first ? first.replace(/^-\s+/, '') : '';
  for (const [prefix, value] of Object.entries(REPORT_REASON_PREFIXES)) {
    if (text.startsWith(prefix)) return value;
  }
  return '';
}

function renderReport(session) {
  const reportText = session.report && session.report.trim() ? session.report.trim() : '';
  const stanceSummary = renderStanceSummary(session);
  const openConditions = stanceSummary.querySelector('#report-open-conditions');
  const actions = h('div', { class: 'report-actions' });

  actions.append(h('button', {
    class: 'btn btn-small',
    type: 'button',
    text: '复制结论',
    disabled: !reportText,
    title: reportText ? '复制结论文本' : '没有结论文本',
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
        h('p', { class: 'report-kicker', text: '记录' }),
        h('h2', { class: 'report-title', id: 'report-title', text: '结论' })),
      actions));

  if (reportText) {
    const sections = reportSections(reportText);
    const sources = new Set(reportSourceIndex(session).keys());
    const reason = reportReasonOf(session, sections);
    const status = REPORT_STATUS_COPY[reason]
      || { label: '已结束', tone: 'neutral', note: '报告未标注一致结论，按记录使用。' };
    const incomplete = reason !== 'consensus';
    const answerLines = reportSectionText(sections.get('建议回答')).split('\n');
    const metaText = (answerLines[0] || '').trim();
    const hasProposal = /^候选版本\s+v\d+/i.test(metaText);
    const bodyText = hasProposal
      ? answerLines.slice(1).join('\n').trim()
      : reportSectionText(sections.get('建议回答'));
    const answer = h('div', { class: 'report-answer' },
      h('div', { class: 'report-answer-head' },
        h('p', {
          class: 'report-answer-label',
          text: hasProposal ? (incomplete ? '候选建议' : '建议回答') : '当前状态',
        }),
        h('span', { class: `report-status is-${status.tone}`, text: status.label })),
      h('p', { class: 'report-status-note', text: status.note }));

    if (hasProposal) {
      const meta = h('p', { class: 'report-answer-meta' });
      appendReportInline(meta, metaText, sources);
      answer.append(meta);
    }

    if (openConditions) {
      answer.append(h('p', { class: 'report-status-note' }, h('a', {
        class: 'link-quiet',
        href: '#report-open-conditions',
        text: '查看各席附加条件与反对',
        onClick: (event) => {
          event.preventDefault();
          openConditions.scrollIntoView({ block: 'start' });
          openConditions.focus({ preventScroll: true });
        },
      })));
    }

    if (hasProposal && bodyText) {
      const body = renderReportMarkdown(bodyText, session);
      body.classList.add('report-answer-body');
      answer.append(body);
    } else if (!hasProposal) {
      const material = sections.get('独立回答');
      const materialCount = (material?.lines || [])
        .filter((line) => /^###\s+\[S\d+\]/.test(line.trim())).length;
      answer.append(h('p', {
        class: 'report-partial-text',
        text: bodyText || '尚无可用的候选结论。以下保留已收到的材料，供人工判断。',
      }));
      answer.append(h('p', {
        class: 'report-partial-text',
        text: materialCount > 0
          ? `已收到 ${materialCount} 条独立回答，原文见下方「历次发言」或展开完整报告。`
          : '没有可用的独立回答，逐席状态见下方。',
      }));
    }

    section.append(answer, stanceSummary);

    const visibleText = [
      hasProposal ? metaText : '',
      hasProposal ? bodyText : (bodyText || ''),
    ].join(' ');
    if (/\[S\d+\]/.test(visibleText) || openConditions?.querySelector('.report-cite')) {
      section.append(h('p', {
        class: 'report-source-note',
        text: '编号可跳到下面「历次发言」的对应原文。',
      }));
    }

    const details = h('details', { class: 'report-details' },
      h('summary', { class: 'report-details-summary', text: '完整报告与状态记录' }),
      h('p', {
        class: 'report-details-hint',
        text: '未删改的完整 Markdown 报告，含上方建议回答与逐席记录。',
      }));
    details.append(renderReportMarkdown(reportText, session));
    section.append(details);
  } else {
    section.append(h('div', {
      class: 'report-empty',
      text: '这场讨论已结束，但没有结论文本。逐席表态和发言仍在下面，可以导出。',
    }));
    section.append(stanceSummary);
  }

  return section;
}

function renderStanceSummary(session) {
  const rows = deriveStances(session);
  const wrap = h('div', { class: 'stance-summary' },
    h('h3', { class: 'stance-title', text: `逐席确认（${rows.length} 席）` }),
    h('p', {
      class: 'stance-rule',
      text: '缺席、沉默和无法解析的表态都不计为同意。每位都明确同意，且关键条件已写入，才算全体一致。',
    }));

  const conditions = h('div', {
    class: 'report-conditions',
    id: 'report-open-conditions',
    tabIndex: -1,
    attrs: { role: 'group', 'aria-labelledby': 'report-open-conditions-title' },
  }, h('h4', {
    class: 'report-conditions-title',
    id: 'report-open-conditions-title',
    text: '尚未解决的条件与反对',
  }));
  const otherRows = [];
  for (const row of rows) {
    const reason = row.status === 'none'
      ? '没有确认记录。'
      : row.status === 'skipped'
        ? '这一席在本阶段缺席。'
        : row.status === 'pending'
          ? '尚未回答。'
          : row.answer && row.answer.trim() ? row.answer : '未保存理由文本。';
    const outstanding = row.status === 'answered'
      && (row.stance === 'conditional' || row.stance === 'oppose');
    const entry = h('div', { class: 'stance-row' },
      h('span', { class: 'stance-name', text: providerName(row.provider) }),
      h('span', {}, stanceChip(row.stance, stanceRowLabel(row))),
      h('div', {},
        h('span', { class: 'stance-reason', text: reason }),
        outstanding && row.sourceId ? [' ', reportCitation(row.sourceId)] : null));
    if (outstanding) conditions.append(entry);
    else otherRows.push(entry);
  }

  if (conditions.childElementCount > 1) wrap.append(conditions);
  wrap.append(...otherRows);
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
      h('span', { class: 'history-note', text: '按轮次、阶段与席位保存' })));

  if (!entries.length) {
    section.append(h('div', {
      class: 'inline-empty',
      text: '还没有早先的发言。当前轮的回答在上面。',
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
  const sourceId = String(entry.sourceId || '').trim();
  const anchorId = sourceId ? sourceAnchorId(sourceId) : '';
  const meta = h('div', { class: 'timeline-meta' },
    h('span', { class: 'timeline-seat', text: `席 ${seatLetter(seatIndex >= 0 ? seatIndex : 0)} · ${providerName(entry.provider)}` }),
    h('span', { text: statusLabel(entry.status) }));
  if (entry.stance) meta.append(stanceChip(entry.stance));
  if (isCorrectedAnswer(entry)) meta.append(revisionChip());
  if (sourceId) {
    meta.append(h('a', {
      class: 'source-id',
      href: `#${anchorId}`,
      title: `${sourceId} 的原文位置`,
      text: sourceId,
      onClick: (event) => {
        event.preventDefault();
        highlightSource(sourceId);
      },
    }));
  }

  const item = h('article', {
    class: 'timeline-item',
    id: anchorId || null,
    dataset: sourceId ? { sourceId } : null,
    attrs: sourceId ? { tabindex: '-1' } : null,
  }, meta);

  if (entry.stage === 'critique') {
    appendChildren(item, [renderCritiqueContext(session, entry, entry.round)]);
  }
  if (entry.status === 'skipped') {
    item.append(h('div', { class: 'timeline-answer is-muted', text: '这一席在这一阶段缺席。' }));
  } else if (entry.answer && entry.answer.trim()) {
    item.append(h('div', { class: 'timeline-answer', text: entry.answer }));
  } else if (entry.status === 'pending') {
    item.append(h('div', { class: 'timeline-answer is-muted', text: '尚未回答。' }));
  } else {
    item.append(h('div', { class: 'timeline-answer is-muted', text: '未保存回答文本。' }));
  }
  const revision = renderRevisionDetails(entry);
  if (revision) item.append(revision);

  const draft = draftForHistoryEntry(session, entry);
  if (draft) item.append(renderUnsubmittedDraft(draft));

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
  lines.push('# 讨论记录', '');
  lines.push('## 问题', '', session.question || '未填写问题', '');

  lines.push('## 讨论信息', '');
  const seats = sessionProviderList(session).map((provider, index) =>
    `席 ${seatLetter(index)} ${providerName(provider)}（${provider}）`);
  lines.push(`- 参与席位（${seats.length}）：${seats.join('；') || '未登记'}`);
  lines.push(`- 当前阶段：${stageInfo(session.stage).label}${session.stage !== 'done' ? ` · 第 ${session.round} 轮` : ''}`);
  lines.push(`- 状态：${session.paused ? '已暂停' : session.stage === 'done' ? '已结束' : '进行中'}`);
  lines.push(`- 更新时间：${formatAbsolute(session.updatedAt)}`);
  lines.push(`- 导出时间：${formatAbsolute(Date.now())}`, '');

  lines.push('## 结论', '');
  const report = session.report && session.report.trim() ? session.report.trim() : '';
  lines.push(report || '这场讨论没有结论文本，只保留下面的回答和表态。', '');

  lines.push('## 逐席确认', '');
  lines.push('> 缺席、沉默和无法解析的表态都不计为同意。每位都明确同意，且关键条件已写入，才算全体一致。', '');
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
      if (isCorrectedAnswer(entry) && entry.originalAnswer && entry.originalAnswer.trim()) {
        lines.push('**更正说明**', '');
        lines.push(`- 首次提交：${formatAbsolute(entry.answeredAt)}；最近更正：${formatAbsolute(entry.correctedAt)}。这场讨论仍只把上面一条回答计为证据。`);
        lines.push('', '**首次提交原文（保留，不计第二条回答）**', '', markdownBlock(entry.originalAnswer), '');
      }
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
  const base = String(session.question || '未命名讨论')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 32)
    .replace(/[\\/:*?"<>|#%{}~&]/g, '-') || '未命名讨论';
  const now = new Date();
  const pad = (value) => String(value).padStart(2, '0');
  return `AI-Arena-${base}-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}.md`;
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
  bindAutomationEvents();
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

  window.addEventListener('pagehide', () => {
    flushStoredState();
    stopAutomationPolling();
  });
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') flushStoredState();
  });
  document.addEventListener('focusout', () => {
    if (!state.automationRefreshPending) return;
    setTimeout(() => {
      if (!automationEditingFocus()) void pollAutomation();
    }, 120);
  });
}

async function boot() {
  loadStoredState();
  bindGlobalEvents();
  renderHistoryList();

  if (!runtimeAvailable()) {
    showGlobalError('没有检测到扩展后台。请从 Chrome 的扩展页打开，不要直接打开本地文件。');
    renderHome();
    return;
  }

  renderLoading('正在读取本机记录…');

  try {
    const reply = await callBackground({ type: 'list' });
    setSessions(reply.sessions);
    hideGlobalError();
    renderHistoryList();
    await loadAutomationInfo({ silent: true });

    const hashId = readHashId();
    if (hashId) await openSession(hashId);
    else renderHome();
  } catch (error) {
    setSessions([]);
    state.listError = friendlyError(error);
    renderHistoryList();
    showGlobalError(friendlyError(error, '读取讨论失败'));
    renderHome();
  }
}

void boot();
