/**
 * AI Arena — background automation for real web pages (G1, G3; R06, R09).
 *
 * First version scope: user-controlled loopback web UIs only. Two seats,
 * `local-a` and `local-b`, each with its own URL and CSS selectors configured
 * from an extension page. No remote sites, no credentials, no API keys, no
 * hidden network dependencies.
 *
 * Wiring contract:
 *   installAutomation({ getSession, act })
 *     getSession(id) -> full raw session (all fields, including tasks/history)
 *     act(id, action, payload) -> updated raw session
 *
 * Trusted extension-page messages (workspace.html or another extension page):
 *   { type: 'automation.config', provider, config: { url, selectors } | null }
 *   { type: 'automation.info' }
 *   { type: 'automation.start', id }
 *   { type: 'automation.stop', id }
 *   -> { ok: true, ... } | { ok: false, error }
 *
 * Driver contract, delivered to the page as `web-driver.js`:
 *   { type: 'arena.web.submit' | 'arena.web.read' | 'arena.web.probe',
 *     taskId, prompt?, selectors }
 *   -> { ok, status, text?, error? }
 *
 * Safety properties enforced here:
 * - Configured URLs must be http(s) on exactly `localhost` or `127.0.0.1`.
 * - Every driver call re-checks that the dedicated tab's origin is the exact
 *   configured origin, not merely a similar hostname.
 * - The dispatch intent is persisted *before* the submit command. After a
 *   worker restart, an intent in `dispatching` is only ever re-read, never
 *   re-submitted. Unknown state produces an actionable per-seat pause.
 * - Answers are written only through `act('answer', ...)` after re-reading the
 *   session: stale tasks, paused sessions and changed votes are never attached
 *   to the wrong round.
 * - Votes are recognized only from one exact `STANCE: ...` line. Anything else
 *   is handled manually, never guessed.
 * - The module keeps a single pump lock, so two UI polls can not submit the
 *   same task twice.
 */

/** Only these seat ids may be automated in this first version. */
export const AUTOMATION_PROVIDERS = Object.freeze(['local-a', 'local-b']);

const STORE_KEY = 'arena.automation.v1';
const DRIVER_FILE = 'web-driver.js';
const ALARM_NAME = 'arena.automation.poll';
const POLL_MS = 4000;
const DRIVER_TIMEOUT_MS = 30000;
const TAB_READY_TIMEOUT_MS = 15000;
const MAX_URL_LENGTH = 2000;
const MAX_SELECTOR_LENGTH = 400;
const MAX_RUNS = 50;
const RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const DRIVER_TASK_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/;

const SELECTOR_KEYS = ['input', 'send', 'user', 'answer', 'stop', 'done', 'container'];
const REQUIRED_SELECTOR_KEYS = ['input', 'send', 'user', 'answer'];
const AUTOMATION_SET = new Set(AUTOMATION_PROVIDERS);

const DONE_STATUSES = new Set(['done', 'complete', 'completed', 'finished']);
const WAIT_STATUSES = new Set([
  'pending',
  'streaming',
  'waiting',
  'generating',
  'submitted',
  'queued',
]);
const READY_STATUSES = new Set(['ready', 'ok']);
/** A recovery read only trusts an explicit "already submitted" signal. */
const RECOVERED_SUBMITTED_STATUSES = new Set([
  'submitted',
  'streaming',
  'generating',
  'done',
  'complete',
  'completed',
  'finished',
]);

/**
 * Appended to vote prompts. The marker is deliberately shown with placeholders:
 * copying a list of three literal markers would make the answer ambiguous.
 */
const VOTE_INSTRUCTION = [
  '',
  '【本机自动化表决格式】',
  '请在回答的最后单独写一行，格式必须完全如下（三选一，不要保留尖括号）：',
  'STANCE: <agree|conditional|oppose>',
  'agree 表示同意候选结论，conditional 表示有条件同意，oppose 表示反对。',
  '这一行之外不要重复标记；缺少或无法识别的标记会退回人工处理。',
].join('\n');

const VOTE_MARKER_RE = /^STANCE: (agree|conditional|oppose)$/;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function clone(value) {
  if (typeof structuredClone === 'function') {
    try {
      return structuredClone(value);
    } catch {
      /* fall through */
    }
  }
  return JSON.parse(JSON.stringify(value));
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function withTimeout(promise, ms, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`${label}超时`));
    }, ms);
    Promise.resolve(promise).then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

function nowIso() {
  return new Date().toISOString();
}

function messageOf(error) {
  if (error && typeof error.message === 'string' && error.message) {
    return error.message;
  }
  return String(error || '未知错误');
}

function requireSessionId(value) {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error('缺少场次 id');
  }
  if (value.length > 128) throw new Error('场次 id 过长');
  return value;
}

function requireAutomationProvider(value) {
  if (typeof value !== 'string' || !AUTOMATION_SET.has(value)) {
    throw new Error(`该席位不支持自动驱动：${String(value)}`);
  }
  return value;
}

function isLoopbackHost(hostname) {
  return hostname === 'localhost' || hostname === '127.0.0.1';
}

// ---------------------------------------------------------------------------
// Configuration validation
// ---------------------------------------------------------------------------

function normalizeSelector(value, key, required) {
  if (value === undefined || value === null || value === '') {
    if (required) throw new Error(`CSS 选择器 ${key} 不能为空`);
    return '';
  }
  if (typeof value !== 'string') {
    throw new Error(`CSS 选择器 ${key} 必须是字符串`);
  }
  const selector = value.trim();
  if (selector.length === 0) {
    if (required) throw new Error(`CSS 选择器 ${key} 不能为空`);
    return '';
  }
  if (selector.length > MAX_SELECTOR_LENGTH) {
    throw new Error(`CSS 选择器 ${key} 过长`);
  }
  if (/[\r\n]/.test(selector)) {
    throw new Error(`CSS 选择器 ${key} 不能包含换行`);
  }
  return selector;
}

/**
 * Only loopback URLs are accepted. Origin is stored and compared exactly on
 * every driver call, so a redirect to a remote login page pauses the seat.
 */
function normalizeConfig(raw) {
  if (!isPlainObject(raw)) throw new Error('automation.config.config 必须是对象');
  if (typeof raw.url !== 'string' || raw.url.trim().length === 0) {
    throw new Error('本机网页地址不能为空');
  }
  if (raw.url.length > MAX_URL_LENGTH) throw new Error('本机网页地址过长');

  let url;
  try {
    url = new URL(raw.url.trim());
  } catch {
    throw new Error('本机网页地址不是有效 URL');
  }
  if (url.protocol !== 'http:') {
    throw new Error('只接受 http://localhost 或 http://127.0.0.1 的本机地址');
  }
  if (!isLoopbackHost(url.hostname)) {
    throw new Error('只允许 localhost 或 127.0.0.1，不接受远程站点');
  }
  if (url.username || url.password) {
    throw new Error('本机地址不能包含用户名或密码');
  }
  url.hash = '';

  if (!isPlainObject(raw.selectors)) {
    throw new Error('selectors 必须是对象');
  }
  const selectors = {};
  for (const key of SELECTOR_KEYS) {
    selectors[key] = normalizeSelector(
      raw.selectors[key],
      key,
      REQUIRED_SELECTOR_KEYS.includes(key),
    );
  }

  return {
    url: url.href,
    origin: url.origin,
    selectors,
    updatedAt: Date.now(),
  };
}

function configsForDriver(config) {
  const selectors = {};
  for (const key of SELECTOR_KEYS) {
    if (config.selectors[key]) selectors[key] = config.selectors[key];
  }
  return selectors;
}

function scopeFor(config) {
  // The driver re-checks its own location against this exact origin, in
  // addition to the tab-origin assertion in this module.
  return { origin: config.origin };
}

function publicConfig(provider, config) {
  return {
    provider,
    url: config.url,
    origin: config.origin,
    selectors: { ...config.selectors },
    updatedAt: config.updatedAt,
  };
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

function emptyStore() {
  return { version: 1, configs: {}, runs: {} };
}

function normalizeStore(raw) {
  const store = emptyStore();
  if (!isPlainObject(raw)) return store;

  if (isPlainObject(raw.configs)) {
    for (const provider of AUTOMATION_PROVIDERS) {
      const config = raw.configs[provider];
      if (!isPlainObject(config)) continue;
      try {
        // Re-validate on every load: a hand-edited or stale record can not
        // smuggle in a remote origin.
        const normalized = normalizeConfig(config);
        if (Number.isFinite(config.updatedAt)) {
          normalized.updatedAt = config.updatedAt;
        }
        store.configs[provider] = normalized;
      } catch {
        /* drop invalid config */
      }
    }
  }

  if (isPlainObject(raw.runs)) {
    for (const [id, run] of Object.entries(raw.runs)) {
      if (!isPlainObject(run) || typeof id !== 'string') continue;
      store.runs[id] = normalizeRun(id, run);
    }
  }
  return store;
}

function normalizeRun(id, raw) {
  const run = {
    id,
    enabled: raw.enabled === true,
    completed: raw.completed === true,
    startedAt: Number.isFinite(raw.startedAt) ? raw.startedAt : Date.now(),
    updatedAt: Number.isFinite(raw.updatedAt) ? raw.updatedAt : Date.now(),
    stoppedAt: Number.isFinite(raw.stoppedAt) ? raw.stoppedAt : null,
    bootId: typeof raw.bootId === 'string' ? raw.bootId : '',
    tabs: {},
    dispatch: {},
    seats: {},
    lastError: typeof raw.lastError === 'string' ? raw.lastError : '',
  };

  if (isPlainObject(raw.tabs)) {
    for (const provider of AUTOMATION_PROVIDERS) {
      const tab = raw.tabs[provider];
      if (!isPlainObject(tab) || !Number.isInteger(tab.tabId)) continue;
      if (typeof tab.origin !== 'string') continue;
      run.tabs[provider] = {
        tabId: tab.tabId,
        origin: tab.origin,
        url: typeof tab.url === 'string' ? tab.url : '',
        openedAt: Number.isFinite(tab.openedAt) ? tab.openedAt : Date.now(),
      };
    }
  }

  if (isPlainObject(raw.dispatch)) {
    for (const [taskId, item] of Object.entries(raw.dispatch)) {
      if (!isPlainObject(item)) continue;
      if (typeof taskId !== 'string' || !AUTOMATION_SET.has(item.provider)) continue;
      const phase = ['dispatching', 'submitted', 'answered', 'stale', 'paused'].includes(
        item.phase,
      )
        ? item.phase
        : 'paused';
      run.dispatch[taskId] = {
        taskId,
        provider: item.provider,
        phase,
        bootId: typeof item.bootId === 'string' ? item.bootId : '',
        stage: typeof item.stage === 'string' ? item.stage : '',
        round: Number.isInteger(item.round) ? item.round : 0,
        voteInstruction: item.voteInstruction === true,
        status: typeof item.status === 'string' ? item.status : '',
        at: Number.isFinite(item.at) ? item.at : Date.now(),
      };
    }
  }

  if (isPlainObject(raw.seats)) {
    for (const provider of AUTOMATION_PROVIDERS) {
      const seat = raw.seats[provider];
      if (!isPlainObject(seat)) continue;
      run.seats[provider] = {
        status: typeof seat.status === 'string' ? seat.status : 'idle',
        taskId: typeof seat.taskId === 'string' ? seat.taskId : '',
        detail: typeof seat.detail === 'string' ? seat.detail : '',
        paused: seat.paused === true,
        at: Number.isFinite(seat.at) ? seat.at : Date.now(),
      };
    }
  }

  return run;
}

function storageArea() {
  const area =
    typeof chrome !== 'undefined' && chrome.storage && chrome.storage.local;
  if (!area) throw new Error('扩展本地存储不可用，无法保存自动化状态');
  return area;
}

async function loadStore() {
  const area = storageArea();
  const got = await area.get(STORE_KEY);
  return normalizeStore(got && got[STORE_KEY]);
}

let storeLock = Promise.resolve();

/**
 * Serialize all read-modify-write cycles. The pump and the UI messages share
 * this lock, so a config edit can not be overwritten by a stale pump snapshot.
 */
function withStore(mutator) {
  const run = storeLock.then(async () => {
    const store = await loadStore();
    const result = await mutator(store);
    pruneStore(store);
    await storageArea().set({ [STORE_KEY]: store });
    return result;
  });
  storeLock = run.then(
    () => undefined,
    () => undefined,
  );
  return run;
}

function pruneStore(store) {
  const now = Date.now();
  const entries = Object.entries(store.runs);
  for (const [id, run] of entries) {
    if (!run.enabled && now - run.updatedAt > RETENTION_MS) {
      delete store.runs[id];
    }
  }
  const rest = Object.entries(store.runs).sort(
    (left, right) => right[1].updatedAt - left[1].updatedAt,
  );
  for (const [id, run] of rest.slice(MAX_RUNS)) {
    if (!run.enabled) delete store.runs[id];
  }
}

async function updateRun(id, mutator) {
  const result = await withStore((store) => {
    const run = store.runs[id];
    if (!run) return null;
    const before = JSON.stringify(run);
    mutator(run, store);
    run.updatedAt = Date.now();
    const after = JSON.stringify(run);
    return { run: clone(run), changed: before !== after };
  });
  if (result && result.changed) notifyRun(result.run);
  return result ? result.run : null;
}

async function updateSeat(id, provider, patch) {
  return updateRun(id, (run) => {
    const seat = run.seats[provider] || {
      status: 'idle',
      taskId: '',
      detail: '',
      paused: false,
      at: Date.now(),
    };
    Object.assign(seat, patch, { at: Date.now() });
    run.seats[provider] = seat;
  });
}

function publicRun(run) {
  return {
    id: run.id,
    enabled: run.enabled,
    completed: run.completed,
    startedAt: run.startedAt,
    updatedAt: run.updatedAt,
    stoppedAt: run.stoppedAt,
    lastError: run.lastError,
    seats: clone(run.seats),
    tabs: Object.fromEntries(
      Object.entries(run.tabs).map(([provider, tab]) => [
        provider,
        { tabId: tab.tabId, origin: tab.origin },
      ]),
    ),
    dispatch: Object.fromEntries(
      Object.entries(run.dispatch).map(([taskId, item]) => [
        taskId,
        {
          provider: item.provider,
          phase: item.phase,
          status: item.status,
          voteInstruction: item.voteInstruction,
          at: item.at,
        },
      ]),
    ),
  };
}

function notifyRun(run) {
  try {
    const maybe = chrome.runtime.sendMessage({
      type: 'automation.progress',
      id: run.id,
      run: publicRun(run),
    });
    if (maybe && typeof maybe.catch === 'function') maybe.catch(() => {});
  } catch {
    /* nobody is listening; progress is best effort */
  }
}

// ---------------------------------------------------------------------------
// Dedicated tabs and driver delivery
// ---------------------------------------------------------------------------

function originOf(value) {
  try {
    return new URL(value).origin;
  } catch {
    return '';
  }
}

function assertLoopbackOrigin(origin) {
  let url;
  try {
    url = new URL(origin);
  } catch {
    throw new Error('配置的来源无效');
  }
  if (url.protocol !== 'http:') {
    throw new Error('只允许 http 本机来源');
  }
  if (!isLoopbackHost(url.hostname)) {
    throw new Error('只允许 localhost 或 127.0.0.1，不接受远程站点');
  }
  return url.origin;
}

function permissionPattern(origin) {
  const url = new URL(origin);
  // Match patterns do not take ports; this grants the loopback host only.
  return `${url.protocol}//${url.hostname}/*`;
}

async function ensureLoopbackPermission(config) {
  try {
    if (!chrome.permissions || !chrome.permissions.contains) return;
    const granted = await chrome.permissions.contains({
      origins: [permissionPattern(config.origin)],
    });
    if (!granted) {
      throw new Error(
        `尚未授予 ${permissionPattern(config.origin)} 的访问权限；请在工作台的自动化设置中点击授权后重新开始`,
      );
    }
  } catch (error) {
    if (/尚未授予/.test(messageOf(error))) throw error;
    // A browser without the permissions API still gets the origin checks below.
  }
}

async function getTab(tabId) {
  try {
    const tab = await chrome.tabs.get(tabId);
    return tab || null;
  } catch {
    return null;
  }
}

async function waitForTabReady(tabId, config) {
  const deadline = Date.now() + TAB_READY_TIMEOUT_MS;
  let lastError = '标签页不可用';
  while (Date.now() < deadline) {
    const tab = await getTab(tabId);
    if (!tab) throw new Error('自动化标签页已关闭');
    if (tab.discarded) throw new Error('自动化标签页已被浏览器丢弃，请重新开始');
    if (typeof tab.url === 'string' && tab.url) {
      let origin;
      try {
        origin = new URL(tab.url).origin;
      } catch {
        origin = '';
      }
      if (origin === config.origin) {
        if (tab.status !== 'loading') return tab;
        lastError = '页面仍在加载';
      } else if (tab.status === 'loading') {
        lastError = '页面仍在跳转';
      } else {
        throw new Error(
          `自动化标签页已离开配置来源（${origin || '未知'}），请检查是否被跳到远程或登录页`,
        );
      }
    } else {
      lastError = '页面没有可读地址';
    }
    await sleep(250);
  }
  throw new Error(`自动化标签页未就绪：${lastError}`);
}

/**
 * Reuse only our own bound tab whose origin exactly matches the configured
 * origin. A user tab is never navigated; a mismatched tab is left alone and a
 * fresh dedicated tab is opened for this seat.
 */
async function ensureTab(id, provider, config) {
  assertLoopbackOrigin(config.origin);
  await ensureLoopbackPermission(config);

  let run = null;
  const store = await loadStore();
  run = store.runs[id] || null;
  if (!run || !run.enabled) throw new Error('自动化已停止，不再打开或读取网页');
  const binding = run && run.tabs[provider];
  if (binding && Number.isInteger(binding.tabId)) {
    const tab = await getTab(binding.tabId);
    if (tab && originOf(tab.url) === config.origin) {
      return waitForTabReady(binding.tabId, config);
    }
  }

  const created = await chrome.tabs.create({ url: config.url, active: false });
  if (!created || !Number.isInteger(created.id)) {
    throw new Error('无法打开自动化标签页');
  }
  await updateRun(id, (draft) => {
    draft.tabs[provider] = {
      tabId: created.id,
      origin: config.origin,
      url: config.url,
      openedAt: Date.now(),
    };
  });
  return waitForTabReady(created.id, config);
}

async function assertTabOrigin(tabId, config) {
  const tab = await getTab(tabId);
  if (!tab) throw new Error('自动化标签页已关闭');
  const origin = originOf(tab.url);
  if (!origin) throw new Error('自动化标签页没有可读地址');
  if (origin !== config.origin) {
    throw new Error(`标签页来源已变为 ${origin}，与配置的 ${config.origin} 不一致`);
  }
  if (!isLoopbackHost(new URL(origin).hostname)) {
    throw new Error('标签页不再是本机来源');
  }
  return tab;
}

function normalizeReply(reply) {
  if (!isPlainObject(reply)) {
    return { ok: false, status: 'unknown', error: '驱动没有返回有效结果' };
  }
  const status =
    typeof reply.status === 'string' ? reply.status.trim().toLowerCase() : '';
  const text = typeof reply.text === 'string' ? reply.text : '';
  const error =
    typeof reply.error === 'string' && reply.error
      ? reply.error
      : reply.ok === false
        ? '驱动报告失败'
        : '';
  return {
    ok: reply.ok !== false,
    status,
    text,
    error,
  };
}

async function sendTabMessage(tabId, command) {
  try {
    return await chrome.tabs.sendMessage(tabId, command);
  } catch (error) {
    const text = messageOf(error);
    if (
      /Receiving end does not exist|Could not establish connection/i.test(text)
    ) {
      return undefined;
    }
    throw error;
  }
}

/**
 * `web-driver.js` may expose a content-script message listener, a global
 * `__arenaWebDriver`, or both. Message first (cheapest), then inject the file
 * and retry; finally call the exposed global in the isolated world.
 */
async function deliver(tabId, command) {
  const first = await sendTabMessage(tabId, command);
  if (first !== undefined) return first;

  await chrome.scripting.executeScript({
    target: { tabId },
    files: [DRIVER_FILE],
  });

  const second = await sendTabMessage(tabId, command);
  if (second !== undefined) return second;

  const results = await chrome.scripting.executeScript({
    target: { tabId },
    func: async (payload) => {
      const api =
        globalThis.__arenaWebDriver ||
        globalThis.arenaWebDriver ||
        globalThis.__ARENA_WEB_DRIVER__;
      try {
        if (typeof api === 'function') return await api(payload);
        if (api && typeof api.handle === 'function') return await api.handle(payload);
        if (api && typeof api.run === 'function') return await api.run(payload);
        return {
          ok: false,
          status: 'unknown',
          error: 'web-driver.js 未暴露可调用的驱动接口',
        };
      } catch (error) {
        return {
          ok: false,
          status: 'unknown',
          error: String((error && error.message) || error),
        };
      }
    },
    args: [command],
  });
  return Array.isArray(results) && results.length > 0
    ? results[0].result
    : undefined;
}

async function callDriver(id, provider, config, command) {
  const tab = await ensureTab(id, provider, config);
  await assertTabOrigin(tab.id, config);
  let reply;
  try {
    reply = await withTimeout(
      deliver(tab.id, command),
      DRIVER_TIMEOUT_MS,
      '网页驱动调用',
    );
  } catch (error) {
    throw new Error(`网页驱动调用失败：${messageOf(error)}`);
  }
  return normalizeReply(reply);
}

// ---------------------------------------------------------------------------
// Seat pause / progress helpers
// ---------------------------------------------------------------------------

async function pauseSeat(id, provider, task, reason, detail) {
  if (!(await runEnabled(id))) return;
  const actionHint =
    '该席不会自动重发。若仍可查看原对话，请先核对。已有完整回答可在工作台粘贴，也可跳过这一席。';
  return updateSeat(id, provider, {
    status: 'paused',
    taskId: task ? task.id : '',
    paused: true,
    detail: `${reason}${detail ? `：${detail}` : ''}。${actionHint}`,
  });
}

async function noteSeat(id, provider, task, status, detail) {
  if (!(await runEnabled(id))) return;
  return updateSeat(id, provider, {
    status,
    taskId: task ? task.id : '',
    paused: false,
    detail: detail || '',
  });
}

async function runEnabled(id) {
  try {
    const store = await loadStore();
    const run = store.runs[id];
    return Boolean(run && run.enabled && !run.completed);
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Vote recognition
// ---------------------------------------------------------------------------

/**
 * Accept exactly one standalone marker line. A missing, duplicated or
 * decorated marker is unknown and must go to manual handling.
 */
function parseStance(text) {
  if (typeof text !== 'string') return null;
  const hits = [];
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (!/^STANCE\s*:/i.test(trimmed)) continue;
    const match = VOTE_MARKER_RE.exec(trimmed);
    if (!match) return null;
    hits.push(match[1].toLowerCase());
  }
  if (hits.length !== 1) return null;
  return hits[0];
}

// ---------------------------------------------------------------------------
// Answer write path
// ---------------------------------------------------------------------------

let writeLock = Promise.resolve();

function serializeWrite(fn) {
  const run = writeLock.then(fn, fn);
  writeLock = run.then(
    () => undefined,
    () => undefined,
  );
  return run;
}

/**
 * Re-read the session immediately before writing. This is the stale/paused
 * gate: an answer read from a page after a stage change or a user pause is not
 * attached to whatever task happens to be current now.
 */
function writeAnswer(id, provider, taskId, text, coords) {
  return serializeWrite(async () => {
    const session = await deps.getSession(id);
    if (!session || !Array.isArray(session.tasks)) {
      return { outcome: 'missing', error: '场次不存在' };
    }
    if (session.stage === 'done') {
      return { outcome: 'stale', error: '场次已结束' };
    }
    if (session.paused) {
      return { outcome: 'session-paused', error: '会话已被用户暂停' };
    }
    const task = session.tasks.find((item) => item.id === taskId);
    if (!task) return { outcome: 'stale', error: '该任务已不属于当前阶段' };
    if (task.status !== 'pending') {
      return { outcome: 'stale', error: `任务状态为 ${task.status}` };
    }
    if (task.provider !== provider) {
      return { outcome: 'stale', error: '任务席位不匹配' };
    }
    if (typeof text !== 'string' || text.trim().length === 0) {
      return { outcome: 'manual', error: '读取到的回答为空' };
    }

    // The task record has no stage/round of its own; the re-read session is
    // the only authority. A vote is committed only when the session (and the
    // dispatch intent, when supplied) still points at the same coordinates.
    const stage = typeof session.stage === 'string' ? session.stage : '';
    const round = Number.isInteger(session.round) ? session.round : 0;
    if (coords && (coords.stage !== stage || coords.round !== round)) {
      return {
        outcome: 'stale',
        error: `任务签发于 ${coords.stage || '未知'} 第${coords.round}轮，当前为 ${stage} 第${round}轮`,
      };
    }

    const payload = { taskId, text, stage, round };
    if (stage === 'vote') {
      const proposal = latestAnsweredProposal(session);
      if (!proposal || task.version !== proposal.version) {
        return {
          outcome: 'stale',
          error: `表决目标是候选 v${String(task.version)}，当前候选已是 v${proposal ? proposal.version : '无'}`,
        };
      }
      const stance = parseStance(text);
      if (!stance) {
        return {
          outcome: 'manual',
          error:
            '回答中没有唯一的 STANCE: agree|conditional|oppose 标记行，不能自动写入表决',
        };
      }
      payload.stance = stance;
      payload.version = task.version;
    }

    try {
      const updated = await deps.act(id, 'answer', payload);
      return { outcome: 'answered', session: updated || null };
    } catch (error) {
      const message = messageOf(error);
      if (/stale|already answered|was skipped|no longer current/i.test(message)) {
        return { outcome: 'stale', error: message };
      }
      return { outcome: 'manual', error: message };
    }
  });
}

// ---------------------------------------------------------------------------
// Pump
// ---------------------------------------------------------------------------

let bootId = `boot-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
let deps = null;
let installed = false;
let pumpPromise = null;
let pumpQueued = false;
let pollTimer = null;

function pendingTaskForProvider(session, provider) {
  if (!Array.isArray(session.tasks)) return null;
  return (
    session.tasks.find(
      (task) => task.provider === provider && task.status === 'pending',
    ) || null
  );
}

/** Tasks never carry stage/round; the session is the sole authority. */
function sessionCoordinates(session) {
  return {
    stage: typeof session.stage === 'string' ? session.stage : '',
    round: Number.isInteger(session.round) ? session.round : 0,
  };
}

function latestAnsweredProposal(session) {
  let latest = null;
  for (const item of Array.isArray(session.history) ? session.history : []) {
    if (
      !item ||
      item.stage !== 'proposal' ||
      item.status !== 'answered' ||
      typeof item.answer !== 'string' ||
      item.answer.trim().length === 0 ||
      !Number.isInteger(item.version)
    ) {
      continue;
    }
    if (
      !latest ||
      item.version > latest.version ||
      (item.version === latest.version &&
        (item.round || 0) > (latest.round || 0))
    ) {
      latest = item;
    }
  }
  return latest;
}

/**
 * A pending task left over from an older saved stage/round must never be sent
 * into the current one, and a vote must target the candidate version that is
 * current right now. The task id encodes its issue coordinates, so no
 * guessed or forced stage is involved.
 */
function stalePendingReason(session, task, provider) {
  const { stage, round } = sessionCoordinates(session);
  const suffix = `:r${round}:${stage}:${provider}`;
  if (!String(task.id || '').endsWith(suffix)) {
    return '该待处理任务不是当前阶段与轮次签发的，可能来自旧的已保存场次';
  }
  if (stage === 'vote') {
    const proposal = latestAnsweredProposal(session);
    if (!proposal) return '当前表决没有可用的候选版本';
    if (task.version !== proposal.version) {
      return `表决目标是候选 v${String(task.version)}，当前候选已是 v${proposal.version}`;
    }
  }
  return '';
}

function stagePrompt(task, stage) {
  if (typeof task.prompt !== 'string' || task.prompt.trim().length === 0) {
    return null;
  }
  if (stage !== 'vote') return task.prompt;
  return `${task.prompt}${VOTE_INSTRUCTION}`;
}

async function markDispatch(id, provider, task, coords, patch) {
  return updateRun(id, (run) => {
    const existing = run.dispatch[task.id] || {
      taskId: task.id,
      provider,
      phase: 'paused',
      bootId: '',
      stage: coords.stage,
      round: coords.round,
      voteInstruction: coords.stage === 'vote',
      status: '',
      at: Date.now(),
    };
    Object.assign(existing, patch, { at: Date.now() });
    run.dispatch[task.id] = existing;
  });
}

/** Stop and config edits win over an in-flight driver call. */
async function canContinue(id, provider) {
  try {
    const store = await loadStore();
    const run = store.runs[id];
    if (!run || !run.enabled || run.completed) return false;
    const seat = run.seats[provider];
    return !(seat && seat.paused);
  } catch {
    return false;
  }
}

async function acceptAnswer(id, provider, task, reply, coords) {
  if (!(await canContinue(id, provider))) return false;
  const text = typeof reply.text === 'string' ? reply.text : '';
  const verdict = await writeAnswer(id, provider, task.id, text, coords);
  if (verdict.outcome === 'answered') {
    await markDispatch(id, provider, task, coords, {
      phase: 'answered',
      status: reply.status || 'done',
    });
    await noteSeat(id, provider, task, 'answered', '已把原文写入本会场次');
    kickPump();
    return true;
  }
  if (verdict.outcome === 'stale') {
    await markDispatch(id, provider, task, coords, {
      phase: 'stale',
      status: reply.status || 'done',
    });
    await noteSeat(id, provider, task, 'unknown', verdict.error);
    return true;
  }
  if (verdict.outcome === 'session-paused') {
    await noteSeat(id, provider, task, 'session-paused', verdict.error);
    return true;
  }
  if (verdict.outcome === 'missing') {
    await pauseSeat(id, provider, task, '场次已不存在', verdict.error);
    return true;
  }
  await pauseSeat(id, provider, task, '回答无法自动写入', verdict.error);
  return true;
}

/**
 * After a restart (or an interrupted write) the only safe action is a read.
 * A positive final answer is accepted; an explicit already-submitted state
 * continues waiting; everything else pauses for the user.
 */
async function reconcileDispatch(id, provider, config, task, intent, coords) {
  let reply;
  try {
    reply = await callDriver(id, provider, config, {
      type: 'arena.web.read',
      taskId: task.id,
      selectors: configsForDriver(config),
      scope: scopeFor(config),
    });
  } catch (error) {
    await pauseSeat(
      id,
      provider,
      task,
      '发送结果待确认',
      `${messageOf(error)}。为避免重复提交，本次只读不重发`,
    );
    return;
  }

  if (reply.ok && DONE_STATUSES.has(reply.status) && reply.text.trim()) {
    await acceptAnswer(id, provider, task, reply, coords);
    return;
  }

  if (
    reply.ok &&
    (RECOVERED_SUBMITTED_STATUSES.has(reply.status) ||
      (reply.status && WAIT_STATUSES.has(reply.status)))
  ) {
    // Only an explicit "submitted/streaming" signal continues the wait. A bare
    // `pending` can also mean "nothing was ever sent", so it stays ambiguous.
    if (reply.status === 'pending' || reply.status === 'waiting') {
      await pauseSeat(
        id,
        provider,
        task,
        '发送结果待确认',
        '重启后读到待处理状态，但无法确认上次是否已发送；不会自动重发',
      );
      return;
    }
    if (intent.phase === 'dispatching') {
      await markDispatch(id, provider, task, coords, {
        phase: 'submitted',
        status: reply.status,
      });
    }
    await noteSeat(id, provider, task, 'waiting', '重启后继续读取原页回答');
    return;
  }

  await pauseSeat(
    id,
    provider,
    task,
    '发送结果待确认',
    `${reply.error || `驱动状态 ${reply.status || '未知'}`}。为避免重复提交，本次只读不重发`,
  );
}

async function pumpSeat(id, session, provider, config) {
  const task = pendingTaskForProvider(session, provider);

  if (!task) {
    const store = await loadStore();
    const run = store.runs[id];
    const previous = run && run.seats[provider];
    if (previous && ['paused', 'waiting', 'dispatching', 'probing'].includes(previous.status)) {
      await noteSeat(id, provider, null, 'idle', '');
    }
    return;
  }

  const store = await loadStore();
  const run = store.runs[id];
  if (!run || !run.enabled || run.completed) return;
  const seatState = run.seats[provider] || null;

  if (seatState && seatState.paused) {
    if (seatState.taskId === task.id) return;
    // A new task means the old pause no longer blocks the current round.
    await noteSeat(id, provider, task, 'probing', '');
  }

  const coords = sessionCoordinates(session);
  const stale = stalePendingReason(session, task, provider);
  if (stale) {
    await pauseSeat(id, provider, task, '待处理任务与当前阶段不一致', stale);
    return;
  }

  if (!config) {
    await noteSeat(
      id,
      provider,
      task,
      'idle',
      '该席尚未配置本机网址与 CSS，可人工处理',
    );
    return;
  }

  const intent = run.dispatch[task.id] || null;

  if (
    intent &&
    (intent.stage !== coords.stage || intent.round !== coords.round)
  ) {
    // A legacy intent (stage '') or an intent from another round is unknown.
    // Never resend or reinterpret it as the current stage; hand it to a human.
    await pauseSeat(
      id,
      provider,
      task,
      '发送记录与当前阶段不一致',
      `原记录为 ${intent.stage || '未知阶段'} 第${intent.round}轮，当前为 ${coords.stage} 第${coords.round}轮`,
    );
    return;
  }

  if (!intent) {
    const prompt = stagePrompt(task, coords.stage);
    if (!prompt) {
      await pauseSeat(id, provider, task, '任务缺少提示正文', '无法发送空提示');
      return;
    }
    if (!DRIVER_TASK_ID_RE.test(String(task.id || ''))) {
      await pauseSeat(id, provider, task, '任务号不符合网页驱动格式', String(task.id));
      return;
    }

    await noteSeat(id, provider, task, 'probing', '检查页面可填写状态');
    let probe;
    try {
      probe = await callDriver(id, provider, config, {
        type: 'arena.web.probe',
        taskId: task.id,
        selectors: configsForDriver(config),
        scope: scopeFor(config),
      });
    } catch (error) {
      await pauseSeat(id, provider, task, '页面不可用', messageOf(error));
      return;
    }
    if (!probe.ok || !READY_STATUSES.has(probe.status)) {
      await pauseSeat(
        id,
        provider,
        task,
        '页面未就绪',
        probe.error || `驱动状态 ${probe.status || '未知'}`,
      );
      return;
    }

    // Persist the intent *before* the submit call. If the worker dies between
    // these two steps, recovery only reads and never sends again.
    let persisted = false;
    let canSubmit = false;
    try {
      await updateRun(id, (draft, store) => {
        if (!draft.enabled || draft.completed) return;
        const seat = draft.seats[provider];
        if (seat && seat.paused) return;
        const live = store.configs[provider];
        if (
          !live ||
          live.origin !== config.origin ||
          JSON.stringify(live.selectors) !== JSON.stringify(config.selectors)
        ) {
          // Configuration changed between probe and submit.
          return;
        }
        draft.tabs[provider] = draft.tabs[provider] || {};
        draft.dispatch[task.id] = {
          taskId: task.id,
          provider,
          phase: 'dispatching',
          bootId,
          stage: coords.stage,
          round: coords.round,
          voteInstruction: coords.stage === 'vote',
          status: '',
          at: Date.now(),
        };
        draft.seats[provider] = {
          status: 'dispatching',
          taskId: task.id,
          detail: '已记录发送意图，正在提交',
          paused: false,
          at: Date.now(),
        };
        canSubmit = true;
        persisted = true;
      });
    } catch (error) {
      await pauseSeat(
        id,
        provider,
        task,
        '本地记录写入失败，未提交',
        messageOf(error),
      );
      return;
    }
    if (!persisted || !canSubmit) return; // stopped or reconfigured before submit

    let reply;
    try {
      reply = await callDriver(id, provider, config, {
        type: 'arena.web.submit',
        taskId: task.id,
        prompt,
        selectors: configsForDriver(config),
        scope: scopeFor(config),
      });
    } catch (error) {
      if (!(await canContinue(id, provider))) return;
      await pauseSeat(
        id,
        provider,
        task,
        '提交结果待确认',
        `${messageOf(error)}。为避免重复提交，不会自动重发`,
      );
      return;
    }

    if (!reply.ok) {
      if (!(await canContinue(id, provider))) return;
      await markDispatch(id, provider, task, coords, {
        phase: 'paused',
        status: reply.status,
      });
      await pauseSeat(
        id,
        provider,
        task,
        '提交结果待确认',
        `${reply.error || reply.status || '驱动报告失败'}。为避免重复提交，不会自动重发`,
      );
      return;
    }

    if (!(await canContinue(id, provider))) return;
    await markDispatch(id, provider, task, coords, {
      phase: 'submitted',
      status: reply.status || 'submitted',
    });
    if (DONE_STATUSES.has(reply.status) && reply.text.trim()) {
      await acceptAnswer(id, provider, task, reply, coords);
      return;
    }
    await noteSeat(id, provider, task, 'waiting', '已提交，等待完整回答');
    return;
  }

  if (intent.phase === 'dispatching') {
    // A dispatch intent without a confirmed submit means "ambiguous". Read
    // only; never call submit again.
    await noteSeat(id, provider, task, 'probing', '重启后只读核对原页');
    await reconcileDispatch(id, provider, config, task, intent, coords);
    return;
  }

  if (intent.phase === 'submitted') {
    let reply;
    try {
      reply = await callDriver(id, provider, config, {
        type: 'arena.web.read',
        taskId: task.id,
        selectors: configsForDriver(config),
        scope: scopeFor(config),
      });
    } catch (error) {
      await pauseSeat(id, provider, task, '读取回答失败', messageOf(error));
      return;
    }
    if (reply.ok && DONE_STATUSES.has(reply.status) && reply.text.trim()) {
      await acceptAnswer(id, provider, task, reply, coords);
      return;
    }
    if (reply.ok && WAIT_STATUSES.has(reply.status)) {
      await noteSeat(
        id,
        provider,
        task,
        'waiting',
        reply.status === 'pending' || reply.status === 'waiting'
          ? '页面仍在生成'
          : `驱动状态 ${reply.status}`,
      );
      return;
    }
    if (reply.ok && DONE_STATUSES.has(reply.status) && !reply.text.trim()) {
      await pauseSeat(id, provider, task, '回答已结束但正文为空', '请打开原页核对');
      return;
    }
    await pauseSeat(
      id,
      provider,
      task,
      '无法确认回答状态',
      reply.error || `驱动状态 ${reply.status || '未知'}`,
    );
    return;
  }

  if (intent.phase === 'paused') {
    await pauseSeat(
      id,
      provider,
      task,
      '上次提交未确认',
    );
    return;
  }

  // answered/stale while the task is still pending: never resubmit.
  if (intent.phase === 'answered' || intent.phase === 'stale') {
    await pauseSeat(
      id,
      provider,
      task,
      '任务记录与场次状态不一致',
      '本模块不会重发；请打开原页核对或人工补录',
    );
  }
}

async function pumpSession(id) {
  const store = await loadStore();
  const run = store.runs[id];
  if (!run || !run.enabled) return;

  let session;
  try {
    session = await deps.getSession(id);
  } catch (error) {
    await updateRun(id, (draft) => {
      draft.lastError = messageOf(error);
    });
    return;
  }
  if (!session || !Array.isArray(session.tasks)) {
    await updateRun(id, (draft) => {
      draft.enabled = false;
      draft.lastError = '场次不存在或已删除';
      draft.seats = {};
    });
    return;
  }

  if (session.stage === 'done') {
    await updateRun(id, (draft) => {
      draft.enabled = false;
      draft.completed = true;
      draft.lastError = '';
    });
    return;
  }

  if (session.paused) {
    for (const provider of session.providers || []) {
      if (!AUTOMATION_SET.has(provider)) continue;
      const task = pendingTaskForProvider(session, provider);
      if (task) {
        await noteSeat(id, provider, task, 'waiting', '讨论已暂停，暂停派发');
      }
    }
    return;
  }

  const providers = (session.providers || []).filter(
    (provider) => AUTOMATION_SET.has(provider) && pendingTaskForProvider(session, provider),
  );
  if (providers.length === 0) {
    await updateRun(id, (draft) => {
      for (const provider of AUTOMATION_PROVIDERS) {
        const seat = draft.seats[provider];
        if (seat && ['waiting', 'dispatching', 'probing'].includes(seat.status)) {
          draft.seats[provider] = {
            ...seat,
            status: 'idle',
            detail: '',
            paused: false,
            at: Date.now(),
          };
        }
      }
    });
    return;
  }

  const configs = store.configs;
  await Promise.allSettled(
    providers.map((provider) =>
      pumpSeat(id, session, provider, configs[provider] || null),
    ),
  );
}

async function pumpAllOnce() {
  const store = await loadStore();
  const ids = Object.keys(store.runs).filter((id) => store.runs[id].enabled);
  for (const id of ids) {
    try {
      await pumpSession(id);
    } catch (error) {
      try {
        await updateRun(id, (draft) => {
          draft.lastError = messageOf(error);
        });
      } catch {
        /* storage itself is failing; nothing more to persist */
      }
    }
  }
}

function scheduleNextPoll() {
  if (pollTimer) {
    clearTimeout(pollTimer);
    pollTimer = null;
  }
  const timer = setTimeout(async () => {
    pollTimer = null;
    try {
      const store = await loadStore();
      const active = Object.values(store.runs).some(
        (run) => run.enabled && !run.completed,
      );
      if (active) kickPump();
    } catch {
      /* alarms remain the durable fallback */
    }
  }, POLL_MS);
  pollTimer = timer;
}

function kickPump() {
  if (pumpPromise) {
    pumpQueued = true;
    return pumpPromise;
  }
  pumpPromise = (async () => {
    try {
      await pumpAllOnce();
    } catch (error) {
      // A failing pump must not become an unhandled rejection; the alarm and
      // the next UI info call will try again.
      try {
        const store = await loadStore();
        for (const [id, run] of Object.entries(store.runs)) {
          if (!run.enabled) continue;
          await updateRun(id, (draft) => {
            draft.lastError = messageOf(error);
          });
        }
      } catch {
        /* storage trouble: nothing to record */
      }
    } finally {
      pumpPromise = null;
      if (pumpQueued) {
        pumpQueued = false;
        queueMicrotask(() => kickPump());
      } else {
        scheduleNextPoll();
      }
    }
  })();
  return pumpPromise;
}

// ---------------------------------------------------------------------------
// Message API
// ---------------------------------------------------------------------------

async function handleConfig(message) {
  const provider = requireAutomationProvider(message.provider);
  if (message.config === null || message.config === undefined) {
    await withStore((store) => {
      delete store.configs[provider];
      for (const run of Object.values(store.runs)) {
        if (!run.enabled) continue;
        delete run.tabs[provider];
        const seat = run.seats[provider];
        if (seat && ['dispatching', 'waiting', 'probing'].includes(seat.status)) {
          run.seats[provider] = {
            ...seat,
            status: 'paused',
            paused: true,
            detail: '该席配置已移除，请人工处理或重新配置后开始自动化',
            at: Date.now(),
          };
        }
      }
    });
    return {};
  }

  const config = normalizeConfig(message.config);
  await withStore((store) => {
    store.configs[provider] = config;
    for (const run of Object.values(store.runs)) {
      if (!run.enabled) continue;
      const binding = run.tabs[provider];
      if (binding && binding.origin !== config.origin) delete run.tabs[provider];
      const seat = run.seats[provider];
      if (seat && ['dispatching', 'waiting', 'probing'].includes(seat.status)) {
        run.seats[provider] = {
          ...seat,
          status: 'paused',
          paused: true,
          detail: '配置已更新，为避免用新选择器读旧页面，请再次开始自动化',
          at: Date.now(),
        };
      }
    }
  });
  return {};
}

async function handleInfo() {
  // Opening or refreshing the workspace is also a progress tick. The pump is
  // not awaited so a slow page can not block the info response.
  kickPump();
  const store = await loadStore();
  const configs = {};
  for (const provider of AUTOMATION_PROVIDERS) {
    if (store.configs[provider]) {
      configs[provider] = publicConfig(provider, store.configs[provider]);
    }
  }
  const runs = {};
  for (const [id, run] of Object.entries(store.runs)) {
    runs[id] = publicRun(run);
  }
  return { configs, runs, providers: AUTOMATION_PROVIDERS.slice() };
}

async function handleStart(message) {
  const id = requireSessionId(message.id);
  let session;
  try {
    session = await deps.getSession(id);
  } catch (error) {
    throw new Error(`无法读取场次：${messageOf(error)}`);
  }
  if (!session || !Array.isArray(session.tasks)) throw new Error('未找到该场次');
  const seats = (session.providers || []).filter((provider) =>
    AUTOMATION_SET.has(provider),
  );
  if (seats.length === 0) {
    throw new Error('本场没有 local-a / local-b 席位，无法启用网页自动化');
  }

  const store = await loadStore();
  if (!seats.some((provider) => store.configs[provider])) {
    throw new Error('请先为 local-a 或 local-b 配置本机网页地址与 CSS 选择器');
  }

  let run = null;
  await withStore((draft) => {
    run = draft.runs[id] || normalizeRun(id, {});
    run.enabled = true;
    run.completed = false;
    run.stoppedAt = null;
    run.lastError = '';
    run.bootId = bootId;
    run.startedAt = Date.now();
    run.updatedAt = Date.now();
    for (const provider of seats) {
      const seat = run.seats[provider];
      if (seat && seat.paused) {
        // Explicit start is the user's acknowledgement. It clears the pause but
        // keeps the dispatch intent, so a previously ambiguous submit is still
        // only read, never resent.
        run.seats[provider] = {
          ...seat,
          paused: false,
          status: 'idle',
          detail: '',
          at: Date.now(),
        };
      }
    }
    draft.runs[id] = run;
  });

  ensureAlarm();
  kickPump();
  return { run: run ? publicRun(run) : null };
}

async function handleStop(message) {
  const id = requireSessionId(message.id);
  const run = await updateRun(id, (draft) => {
    draft.enabled = false;
    draft.stoppedAt = Date.now();
    draft.lastError = '';
    // "Detach": stop touching the page. Tabs stay open for the user, but this
    // run no longer owns or drives them.
    draft.tabs = {};
    for (const provider of AUTOMATION_PROVIDERS) {
      const seat = draft.seats[provider];
      if (seat) {
        draft.seats[provider] = {
          ...seat,
          status: 'detached',
          paused: false,
          detail: '用户已停止自动化；原页保留供人工接管',
          at: Date.now(),
        };
      }
    }
  });
  return run ? { run: publicRun(run) } : {};
}

const MESSAGE_TYPES = new Set([
  'automation.config',
  'automation.info',
  'automation.start',
  'automation.stop',
]);

function isTrustedExtensionPage(sender) {
  try {
    if (!sender || sender.id !== chrome.runtime.id) return false;
    const base = chrome.runtime.getURL('');
    const url = typeof sender.url === 'string' ? sender.url : '';
    if (!url.startsWith(base)) return false;
    const path = url.slice(base.length).split(/[?#]/)[0];
    return /^[A-Za-z0-9._-]+\.html$/.test(path);
  } catch {
    return false;
  }
}

function errorPayload(error) {
  return { ok: false, error: messageOf(error) };
}

function onMessage(message, sender, sendResponse) {
  if (!isPlainObject(message) || !MESSAGE_TYPES.has(message.type)) {
    return false; // not ours: let the worker's own listener handle it
  }
  if (!isTrustedExtensionPage(sender)) {
    sendResponse(errorPayload(new Error('只接受本扩展页面发来的自动化请求')));
    return false;
  }

  let replied = false;
  const reply = (value) => {
    if (replied) return;
    replied = true;
    try {
      sendResponse(value);
    } catch {
      /* the page may already be gone */
    }
  };

  (async () => {
    switch (message.type) {
      case 'automation.config':
        return handleConfig(message);
      case 'automation.info':
        return handleInfo();
      case 'automation.start':
        return handleStart(message);
      case 'automation.stop':
        return handleStop(message);
      default:
        throw new Error(`未知自动化命令：${String(message.type)}`);
    }
  })().then(
    (data) => reply({ ok: true, ...(data || {}) }),
    (error) => reply(errorPayload(error)),
  );
  return true;
}

// ---------------------------------------------------------------------------
// Alarms, recovery and installation
// ---------------------------------------------------------------------------

function ensureAlarm() {
  try {
    if (chrome.alarms && chrome.alarms.create) {
      chrome.alarms.create(ALARM_NAME, { periodInMinutes: 1 });
    }
  } catch {
    /* polling timers remain while the worker lives */
  }
}

function settleRecoveredRuns() {
  // A run that was left enabled is resumed by reading. Any dispatch intent in
  // `dispatching` naturally becomes a read-only reconciliation because its
  // bootId belongs to a previous worker instance.
  kickPump();
}

/**
 * Install the automation background module once. Safe to call again: the
 * dependency functions are replaced but listeners are not duplicated.
 */
export function installAutomation(next) {
  if (!next || typeof next.getSession !== 'function' || typeof next.act !== 'function') {
    throw new Error('installAutomation 需要 { getSession, act }');
  }
  deps = { getSession: next.getSession, act: next.act };

  if (!installed) {
    installed = true;
    if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.onMessage) {
      chrome.runtime.onMessage.addListener(onMessage);
    }
    try {
      if (chrome.alarms && chrome.alarms.onAlarm) {
        chrome.alarms.onAlarm.addListener((alarm) => {
          if (alarm && alarm.name === ALARM_NAME) kickPump();
        });
      }
      if (chrome.runtime && chrome.runtime.onStartup) {
        chrome.runtime.onStartup.addListener(() => settleRecoveredRuns());
      }
      if (chrome.runtime && chrome.runtime.onInstalled) {
        chrome.runtime.onInstalled.addListener(() => {
          ensureAlarm();
          settleRecoveredRuns();
        });
      }
    } catch {
      /* listeners are best effort in a minimal test harness */
    }
    ensureAlarm();
  }

  // The service worker starts, so re-enter any enabled runs. Dispatch intents
  // from the previous boot will be read-only.
  queueMicrotask(() => settleRecoveredRuns());

  return {
    pump: () => kickPump(),
    info: handleInfo,
    bootId,
    providers: AUTOMATION_PROVIDERS.slice(),
  };
}
