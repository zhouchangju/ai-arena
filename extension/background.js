// AI Arena — MV3 service worker (G1, G3, G4)
//
// UI ⇄ worker contract:
//   sendMessage({ type: 'list' })
//   sendMessage({ type: 'get', id })
//   sendMessage({ type: 'create', question, providers: [idA, idB] })
//   sendMessage({ type: 'act', id, action, payload })
//      actions: 'answer' {taskId, text, stance?, version?, stage?, round?}
//               'correct' {taskId, text, previousText, stage?, round?}
//               'skip' {taskId} | 'guide' {text} | 'pause' | 'resume' | 'finish'
//   sendMessage({ type: 'delete', id })
//   sendMessage({ type: 'open', id, provider })
//   → { ok: true, sessions? | session? } or { ok: false, error }
//
// Session ownership: core.js owns the debate state machine. This worker does
// not duplicate stages, prompts, transitions or reports, and it does not try to
// repair a failing core. createSession/applyAction are imported statically (a
// dynamic import() is not available to an MV3 service worker started from the
// extension root) and every returned session is stored and returned unchanged.
// That keeps `sourceId`, proposal `version`, `stopReason` and `report` intact on
// the way to IndexedDB and back to the workspace. Validation errors thrown by
// core.js abort the transaction and are propagated to the UI.
//
// Rules enforced here (the worker is the only writer of session state):
// - Only this extension's own workspace.html page may send commands. Provider
//   pages and external senders are rejected; no onMessageExternal bridge exists.
// - Command names, ids, actions and provider ids are validated against fixed
//   allowlists. `create` needs two or three distinct canonical lowercase
//   provider ids from providers.js; `open` only opens a registry URL for a seat
//   that is actually part of the session.
// - `open` reuses the seat's bound tab when the `tabs` metadata permission shows
//   its URL still belongs to the intended page (see `tabMatchesEntry`). It never
//   reads page content, never queries unrelated tabs, and never navigates a tab
//   that was repurposed elsewhere.
//
// Persistence: one IndexedDB database. Every read-modify-write command runs
// through a promise queue *and* inside a single readwrite transaction, so two
// workspace windows or a double click can not lose each other's update. A
// failing mutator aborts the transaction, so no partial state is written.

import { createSession, applyAction, MIN_SEATS, MAX_SEATS } from './core.js';
import { installAutomation } from './automation.js';
import {
  PROVIDERS,
  AUTOMATION_PROVIDER_IDS,
  isProviderId,
} from './providers.js';

const AUTOMATION_SEATS = new Set(AUTOMATION_PROVIDER_IDS);
const STANCES = new Set(['agree', 'conditional', 'oppose']);
const COMMAND_TYPES = new Set(['list', 'get', 'create', 'act', 'delete', 'open']);
const ACTIONS = new Set(['answer', 'skip', 'guide', 'pause', 'resume', 'finish', 'correct']);

const MAX_QUESTION = 8000;
const MAX_ANSWER = 200000;
const MAX_GUIDANCE = 2000;
const ID_PATTERN = /^[A-Za-z0-9_-]{1,200}$/;

// ---------------------------------------------------------------------------
// Errors and small helpers
// ---------------------------------------------------------------------------

class ArenaError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ArenaError';
  }
}

function errorMessage(error) {
  if (error instanceof ArenaError) return error.message;
  if (error && typeof error.message === 'string' && error.message) {
    // core.js speaks English; keep its exact validation text so stale-task,
    // stance and citation errors stay actionable instead of being hidden.
    return `操作失败：${error.message}`;
  }
  return '操作失败：未知错误';
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/**
 * The question is stored as the user wrote it (only NUL is removed); trimming
 * would silently change the题面 that every seat later quotes.
 */
function requireQuestion(value) {
  if (typeof value !== 'string') throw new ArenaError('question 必须是文本');
  const text = value.replace(/\u0000/g, '');
  if (!text.trim()) throw new ArenaError('question 不能为空');
  if (text.length > MAX_QUESTION) {
    throw new ArenaError(`question 超过 ${MAX_QUESTION} 字符上限`);
  }
  return text;
}

function requireToken(value, field) {
  if (typeof value !== 'string' || !ID_PATTERN.test(value)) {
    throw new ArenaError(`${field} 格式无效`);
  }
  return value;
}

/** Task ids come from stored core state, so allow any short printable id. */
function requireTaskId(value) {
  if (typeof value !== 'string') throw new ArenaError('taskId 必须是文本');
  const id = value.replace(/\u0000/g, '').trim();
  if (!id) throw new ArenaError('taskId 不能为空');
  if (id.length > 256) throw new ArenaError('taskId 过长');
  return id;
}

function requireProviders(value) {
  if (!Array.isArray(value) || value.length < MIN_SEATS || value.length > MAX_SEATS) {
    throw new ArenaError(`本版本需要 ${MIN_SEATS} 或 ${MAX_SEATS} 个参与席位`);
  }
  const providers = value.map((provider) => {
    if (!isProviderId(provider)) {
      throw new ArenaError(
        `未知或不规范的席位标识：${String(provider)}；必须使用小写规范 id`,
      );
    }
    return provider;
  });
  if (new Set(providers).size !== providers.length) {
    throw new ArenaError('参与席位不能重复');
  }
  return providers;
}

/**
 * Keep the payload fields core.js understands, including the optional vote
 * `version` and stale-submission `stage`/`round` coordinates. Dropping them
 * would let an overdue answer attach itself to the wrong round, which is the
 * exact failure mode R03/R04 are meant to prevent.
 */
function normalizeActPayload(action, raw) {
  if (raw !== undefined && raw !== null && (typeof raw !== 'object' || Array.isArray(raw))) {
    throw new ArenaError('payload 必须是对象');
  }
  const payload = raw || {};

  if (action === 'answer') {
    const taskId = requireTaskId(payload.taskId);
    if (typeof payload.text !== 'string') throw new ArenaError('text 必须是文本');
    if (!payload.text.trim()) throw new ArenaError('text 不能为空');
    if (payload.text.length > MAX_ANSWER) {
      throw new ArenaError(`text 超过 ${MAX_ANSWER} 字符上限`);
    }
    const next = { taskId, text: payload.text };
    if (payload.stance !== undefined && payload.stance !== null) {
      if (!STANCES.has(payload.stance)) {
        throw new ArenaError('stance 只能是 agree、conditional 或 oppose');
      }
      next.stance = payload.stance;
    }
    if (payload.version !== undefined && payload.version !== null) {
      next.version = payload.version;
    }
    if (payload.stage !== undefined && payload.stage !== null) {
      next.stage = payload.stage;
    }
    if (payload.round !== undefined && payload.round !== null) {
      next.round = payload.round;
    }
    return next;
  }

  if (action === 'correct') {
    const taskId = requireTaskId(payload.taskId);
    if (typeof payload.text !== 'string') throw new ArenaError('text 必须是文本');
    if (!payload.text.trim()) throw new ArenaError('text 不能为空');
    if (payload.text.length > MAX_ANSWER) {
      throw new ArenaError(`text 超过 ${MAX_ANSWER} 字符上限`);
    }
    // The exact text the user was looking at. core.js rejects the correction
    // when another window already replaced it, so a stale card cannot
    // silently overwrite a newer correction.
    if (typeof payload.previousText !== 'string') {
      throw new ArenaError('previousText 必须是文本');
    }
    const next = { taskId, text: payload.text, previousText: payload.previousText };
    if (payload.stage !== undefined && payload.stage !== null) {
      next.stage = payload.stage;
    }
    if (payload.round !== undefined && payload.round !== null) {
      next.round = payload.round;
    }
    return next;
  }

  if (action === 'skip') {
    return { taskId: requireTaskId(payload.taskId) };
  }

  // A user condition is stored trimmed; core.js records where and when it was
  // added and appends it only to prompts constructed afterwards.
  if (action === 'guide') {
    if (typeof payload.text !== 'string') throw new ArenaError('text 必须是文本');
    const text = payload.text.trim();
    if (!text) throw new ArenaError('补充条件不能为空');
    if (text.length > MAX_GUIDANCE) {
      throw new ArenaError(`补充条件超过 ${MAX_GUIDANCE} 字符上限`);
    }
    return { text };
  }

  return {};
}

/**
 * Guard the storage boundary without transforming core output. A nothing-but
 * sanity check: if core ever returns something that could corrupt the database,
 * the transaction is aborted instead of persisting it.
 */
function assertCoreSession(value) {
  if (!value || typeof value !== 'object') {
    throw new ArenaError('核心引擎没有返回会话');
  }
  if (typeof value.id !== 'string' || !value.id) {
    throw new ArenaError('核心引擎返回的会话缺少标识');
  }
  if (!Array.isArray(value.providers) || !Array.isArray(value.tasks) || !Array.isArray(value.history)) {
    throw new ArenaError('核心引擎返回的会话结构不完整');
  }
  // Older stored sessions have no guidance field; only a wrong type is fatal.
  if (value.guidance !== undefined && !Array.isArray(value.guidance)) {
    throw new ArenaError('核心引擎返回的补充条件结构不完整');
  }
  if (typeof value.stage !== 'string') {
    throw new ArenaError('核心引擎返回的会话缺少阶段');
  }
  return value;
}

function assertNextSession(next, current) {
  assertCoreSession(next);
  if (next.id !== current.id) {
    throw new ArenaError('核心引擎返回的会话标识不一致');
  }
  const sameProviders =
    next.providers.length === current.providers.length &&
    next.providers.every((provider, index) => provider === current.providers[index]);
  if (!sameProviders) {
    throw new ArenaError('核心引擎返回的参与席位不一致');
  }
  return next;
}

// ---------------------------------------------------------------------------
// IndexedDB (single database, transactional read-modify-write)
// ---------------------------------------------------------------------------

const DB_NAME = 'ai-arena';
const DB_VERSION = 1;
const SESSIONS_STORE = 'sessions';
const TABS_STORE = 'tabs';

let dbPromise = null;

function openDatabase() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    let request;
    try {
      request = indexedDB.open(DB_NAME, DB_VERSION);
    } catch (error) {
      dbPromise = null;
      reject(error);
      return;
    }
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(SESSIONS_STORE)) {
        const store = db.createObjectStore(SESSIONS_STORE, { keyPath: 'id' });
        store.createIndex('updatedAt', 'updatedAt');
      }
      if (!db.objectStoreNames.contains(TABS_STORE)) {
        db.createObjectStore(TABS_STORE);
      }
    };
    request.onsuccess = () => {
      const db = request.result;
      db.onversionchange = () => {
        db.close();
        dbPromise = null;
      };
      resolve(db);
    };
    request.onerror = () => {
      const error = request.error || new Error('无法打开本机数据库');
      dbPromise = null;
      reject(error);
    };
  });
  return dbPromise;
}

function requestResult(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error('本机数据库操作失败'));
  });
}

function txComplete(tx) {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error || new Error('本机数据库事务失败'));
    tx.onabort = () => reject(tx.error || new Error('本机数据库事务已中止'));
  });
}

async function readSession(id) {
  const db = await openDatabase();
  const tx = db.transaction(SESSIONS_STORE, 'readonly');
  const done = txComplete(tx);
  done.catch(() => {});
  const value = await requestResult(tx.objectStore(SESSIONS_STORE).get(id));
  await done;
  return value || null;
}

async function listSessions() {
  const db = await openDatabase();
  const tx = db.transaction(SESSIONS_STORE, 'readonly');
  const done = txComplete(tx);
  done.catch(() => {});
  const all = await requestResult(tx.objectStore(SESSIONS_STORE).getAll());
  await done;
  return all
    .slice()
    .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0))
    .map((session) => ({
      id: session.id,
      question: session.question,
      updatedAt: session.updatedAt || 0,
    }));
}

async function putSession(session, isNew) {
  const db = await openDatabase();
  const tx = db.transaction(SESSIONS_STORE, 'readwrite');
  const done = txComplete(tx);
  done.catch(() => {});
  const store = tx.objectStore(SESSIONS_STORE);
  if (isNew) {
    store.add(session);
  } else {
    store.put(session);
  }
  await done;
}

async function deleteSessionRecord(id) {
  const db = await openDatabase();
  const tx = db.transaction(SESSIONS_STORE, 'readwrite');
  const done = txComplete(tx);
  done.catch(() => {});
  const store = tx.objectStore(SESSIONS_STORE);
  const current = await requestResult(store.get(id));
  if (!current) {
    await done;
    return false;
  }
  store.delete(id);
  await done;
  return true;
}

/**
 * Serialized read-modify-write in one readwrite transaction. `mutator` is
 * synchronous and either returns the next core session or throws. The stored
 * core session is passed through untouched; no revision bookkeeping or
 * timestamp rewriting is layered on top of it.
 */
async function mutateSession(id, mutator) {
  const db = await openDatabase();
  const tx = db.transaction(SESSIONS_STORE, 'readwrite');
  const done = txComplete(tx);
  done.catch(() => {});
  const store = tx.objectStore(SESSIONS_STORE);
  try {
    const current = await requestResult(store.get(id));
    if (!current) throw new ArenaError('未找到该场次');
    const next = mutator(current);
    store.put(next);
    await done;
    return next;
  } catch (error) {
    try {
      tx.abort();
    } catch {
      /* already finished */
    }
    throw error;
  }
}

// ---------------------------------------------------------------------------
// Seat tab bindings and user-initiated "open"
// ---------------------------------------------------------------------------

function bindingKey(sessionId, providerId) {
  return `${sessionId}::${providerId}`;
}

async function getBinding(key) {
  const db = await openDatabase();
  const tx = db.transaction(TABS_STORE, 'readonly');
  const done = txComplete(tx);
  done.catch(() => {});
  const value = await requestResult(tx.objectStore(TABS_STORE).get(key));
  await done;
  return value || null;
}

async function setBinding(key, value) {
  const db = await openDatabase();
  const tx = db.transaction(TABS_STORE, 'readwrite');
  const done = txComplete(tx);
  done.catch(() => {});
  tx.objectStore(TABS_STORE).put(value, key);
  await done;
}

async function dropBinding(key) {
  const db = await openDatabase();
  const tx = db.transaction(TABS_STORE, 'readwrite');
  const done = txComplete(tx);
  done.catch(() => {});
  tx.objectStore(TABS_STORE).delete(key);
  await done;
}

async function clearBindings(sessionId) {
  const db = await openDatabase();
  const tx = db.transaction(TABS_STORE, 'readwrite');
  const done = txComplete(tx);
  done.catch(() => {});
  const store = tx.objectStore(TABS_STORE);
  const keys = await requestResult(store.getAllKeys());
  const prefix = `${sessionId}::`;
  for (const key of keys) {
    if (typeof key === 'string' && key.startsWith(prefix)) store.delete(key);
  }
  await done;
}

/**
 * Reuse decisions read tab metadata only. The manifest holds the `tabs`
 * permission, which exposes `url`/`pendingUrl` for the bound tab but grants no
 * page-content access (automation still needs `scripting` plus the optional
 * loopback host permission). No `chrome.tabs.query` is used: the worker only
 * inspects the tab id it bound for this session+seat, so an unrelated user tab
 * is never touched.
 *
 * Verification is intentionally conservative:
 * - scheme+host+port must match the intended entry origin exactly, so two
 *   loopback seats on different ports are never confused;
 * - if the configured entry URL names a seat (`?seat=A`, used when both loopback
 *   seats share one fixture origin), the tab must name the same seat;
 * - the tab's destination URL is the decisive one (`pendingUrl` while a
 *   navigation is pending, otherwise `url`), so a tab mid-redirect to another
 *   site is never focused even though its old page still matches;
 * - a tab whose readable URL no longer matches, or whose URL is unreadable, is
 *   never focused and never navigated: the stale binding is dropped and a fresh
 *   dedicated tab is opened at the allowlisted entry URL.
 *
 * Because the binding lives in IndexedDB and re-verified from tab metadata,
 * reuse keeps working after the MV3 worker restarts; no in-memory "we once
 * opened it" state is required.
 */
function tabEntryUrl(tab) {
  if (!tab || typeof tab !== 'object') return '';
  // While a navigation is pending Chrome keeps the committed page in `url` and
  // exposes the destination in `pendingUrl`. Trust the destination: it is the
  // page the tab is actually becoming. A freshly created tab commonly reports
  // `url: "about:blank"` plus the real `pendingUrl`, so `url` alone would
  // wrongly look like a repurposed tab.
  if (typeof tab.pendingUrl === 'string' && tab.pendingUrl) return tab.pendingUrl;
  if (typeof tab.url === 'string' && tab.url) return tab.url;
  return '';
}

function originOf(url) {
  try {
    return new URL(url).origin;
  } catch {
    return '';
  }
}

/** Compare scheme+host+port; `http://127.0.0.1:8765` ≠ `...:8766`. */
function sameOrigin(left, right) {
  const a = originOf(left);
  const b = originOf(right);
  return Boolean(a) && a === b;
}

/** Seat marker used by the shared loopback fixture (`?seat=A` / `?seat=B`). */
function seatOf(url) {
  try {
    const value = new URL(url).searchParams.get('seat');
    if (value === null) return null;
    const seat = value.trim().toUpperCase();
    return seat || null;
  } catch {
    return null;
  }
}

/**
 * A tab is the intended seat tab only when the URL it is showing/becoming still
 * belongs to the configured entry page. New-chat routes on the same origin
 * (path/query changed) stay reusable; another site, another port or the other
 * fixture seat does not.
 */
function tabMatchesEntry(tab, entryUrl) {
  const url = tabEntryUrl(tab);
  if (!url || !sameOrigin(url, entryUrl)) return false;
  const expectedSeat = seatOf(entryUrl);
  if (expectedSeat && seatOf(url) !== expectedSeat) return false;
  return true;
}

async function focusTab(tab, tabsApi = chrome.tabs, windowsApi = chrome.windows) {
  await tabsApi.update(tab.id, { active: true });
  if (Number.isInteger(tab.windowId) && windowsApi && windowsApi.update) {
    try {
      await windowsApi.update(tab.windowId, { focused: true });
    } catch {
      /* focusing the window is best effort */
    }
  }
}

/**
 * One in-flight open per session+seat. Two clicks before the first tab appears
 * join the same attempt, so a slow provider page can not produce two
 * conversations. After the worker restarts this map is empty again; the
 * persisted binding plus readable tab metadata is what then prevents a
 * duplicate (see `tabMatchesEntry`).
 */
const pendingOpens = new Map();

async function openProviderTab(sessionId, providerId, configuredUrl = '', overrides = {}) {
  const key = bindingKey(sessionId, providerId);
  const inFlight = pendingOpens.get(key);
  if (inFlight) {
    // Same session+seat already opening: share that attempt. A failure is
    // reported to both callers; the user can click again.
    return inFlight;
  }
  const attempt = openProviderTabOnce(sessionId, providerId, configuredUrl, key, overrides);
  pendingOpens.set(key, attempt);
  try {
    return await attempt;
  } finally {
    if (pendingOpens.get(key) === attempt) pendingOpens.delete(key);
  }
}

/**
 * Reuse the bound seat tab only when its readable metadata still proves it is
 * the configured entry page; otherwise leave that tab untouched and open a
 * fresh one. `overrides` exists for the Node regression test (fake tabs and
 * binding store); the extension always uses the real Chrome APIs.
 */
async function openProviderTabOnce(sessionId, providerId, configuredUrl, key, overrides) {
  const provider = PROVIDERS[providerId];
  if (!provider) throw new ArenaError('未知或不规范的席位标识');
  const tabsApi = overrides.tabs || chrome.tabs;
  const store = overrides.bindings || {
    get: getBinding,
    set: setBinding,
    drop: dropBinding,
  };
  const targetUrl = typeof configuredUrl === 'string' && configuredUrl
    ? configuredUrl
    : provider.url;

  let binding = null;
  try {
    binding = await store.get(key);
  } catch {
    binding = null;
  }

  if (binding && Number.isInteger(binding.tabId)) {
    let tab = null;
    try {
      // Only the tab bound to this session+seat is inspected; never query all
      // tabs, so the user's other windows are out of reach.
      tab = await tabsApi.get(binding.tabId);
    } catch {
      tab = null;
    }

    try { await chrome.storage.local.set({ ['dbg.' + Date.now()]: { step: 'get', binding: binding.tabId, url: tab && tab.url, pendingUrl: tab && tab.pendingUrl, status: tab && tab.status, match: tab && tabMatchesEntry(tab, targetUrl) } }); } catch {}
    if (tab && Number.isInteger(tab.id) && tabMatchesEntry(tab, targetUrl)) {
      await focusTab(tab, tabsApi, overrides.windows);
      await store.set(key, {
        ...binding,
        provider: providerId,
        sessionId,
        entryUrl: targetUrl,
        lastOpenedAt: Date.now(),
      });
      return tab.id;
    }

    // Closed, unreadable, another origin or another fixture seat: this is no
    // longer provably the seat tab. Never focus or navigate it; forget the
    // binding and open a clean tab at the allowlisted entry URL.
    try {
      await store.drop(key);
    } catch {
      /* the fresh tab below is still the safe outcome */
    }
  }

  try { await chrome.storage.local.set({ ['dbg.' + Date.now()]: { step: 'create-before', targetUrl } }); } catch {}
  const tab = await tabsApi.create({ url: targetUrl, active: true });
  try { await chrome.storage.local.set({ ['dbg.' + Date.now()]: { step: 'created', id: tab && tab.id, url: tab && tab.url, pendingUrl: tab && tab.pendingUrl } }); } catch {}
  if (!tab || !Number.isInteger(tab.id)) throw new ArenaError('无法打开网页标签');
  await store.set(key, {
    tabId: tab.id,
    provider: providerId,
    sessionId,
    entryUrl: targetUrl,
    openedAt: Date.now(),
    lastOpenedAt: Date.now(),
  });
  return tab.id;
}

// ---------------------------------------------------------------------------
// Command handling
// ---------------------------------------------------------------------------

let queueTail = Promise.resolve();
let automationApi = null;

/** Serialize every command so two UI windows can not interleave writes. */
function serialize(task) {
  const run = queueTail.then(task, task);
  queueTail = run.then(
    () => undefined,
    () => undefined,
  );
  return run;
}

async function commandList() {
  const sessions = await serialize(() => listSessions());
  return { sessions };
}

async function commandGet(message) {
  const id = requireToken(message.id, 'id');
  const session = await serialize(() => readSession(id));
  if (!session) throw new ArenaError('未找到该场次');
  return { session };
}

async function commandCreate(message) {
  const question = requireQuestion(message.question);
  const providers = requireProviders(message.providers);

  const session = await serialize(async () => {
    // No fallback: a rejected question/provider pair surfaces to the UI and
    // nothing is written.
    const created = assertCoreSession(createSession(question, providers));
    if (
      created.providers.length !== providers.length ||
      created.providers.some((provider, index) => provider !== providers[index])
    ) {
      throw new ArenaError('核心引擎返回的参与席位与请求不一致');
    }
    await putSession(created, true);
    return created;
  });
  return { session };
}

async function commandAct(message) {
  const id = requireToken(message.id, 'id');
  const action = message.action;
  if (typeof action !== 'string' || !ACTIONS.has(action)) {
    throw new ArenaError(`未知动作：${String(action)}`);
  }
  // Validate the payload before opening a transaction; core validates again
  // (staleness, citations, vote rules) and its error aborts the write.
  const payload = normalizeActPayload(action, message.payload);

  const session = await serialize(() =>
    mutateSession(id, (current) => {
      const next = applyAction(current, action, payload);
      return assertNextSession(next, current);
    }),
  );
  return { session };
}

async function commandDelete(message) {
  const id = requireToken(message.id, 'id');
  await serialize(async () => {
    const removed = await deleteSessionRecord(id);
    if (!removed) throw new ArenaError('未找到该场次');
    try {
      await clearBindings(id);
    } catch {
      /* bindings are best effort; the session is already gone */
    }
  });
  return {};
}

/**
 * Local seats have no meaningful public entry URL: the user's saved
 * automation.config address is the only real target. Refuse to guess
 * `http://localhost/` (port 80) when nothing was saved.
 */
async function configuredLocalEntryUrl(provider) {
  if (!automationApi) {
    throw new ArenaError('自动化后台尚未就绪，请重新加载扩展后再试');
  }
  let info;
  try {
    info = await automationApi.info();
  } catch (error) {
    throw new ArenaError(`无法读取本机连接设置：${errorMessage(error)}`);
  }
  const config = info && info.configs ? info.configs[provider] : null;
  const url = config && typeof config.url === 'string' ? config.url.trim() : '';
  if (!url) {
    throw new ArenaError(
      `本机席位 ${provider} 尚未配置网页地址；请先在“连接设置”保存 local-a / local-b 的实际地址与 CSS 选择器`,
    );
  }
  return url;
}

async function commandOpen(message) {
  const id = requireToken(message.id, 'id');
  if (!isProviderId(message.provider)) {
    throw new ArenaError('未知或不规范的席位标识');
  }
  const provider = message.provider;
  return serialize(async () => {
    const session = await readSession(id);
    if (!session) throw new ArenaError('未找到该场次');
    if (!session.providers.includes(provider)) {
      throw new ArenaError('该席位不在本场名单中');
    }
    const entryUrl = AUTOMATION_SEATS.has(provider)
      ? await configuredLocalEntryUrl(provider)
      : '';
    await openProviderTab(session.id, provider, entryUrl);
    return { session };
  });
}

async function handleCommand(message) {
  if (!message || typeof message !== 'object') throw new ArenaError('命令格式无效');
  const type = message.type;
  if (typeof type !== 'string' || !COMMAND_TYPES.has(type)) {
    throw new ArenaError(`未知命令：${String(type)}`);
  }
  switch (type) {
    case 'list':
      return commandList();
    case 'get':
      return commandGet(message);
    case 'create':
      return commandCreate(message);
    case 'act':
      return commandAct(message);
    case 'delete':
      return commandDelete(message);
    case 'open':
      return commandOpen(message);
    default:
      throw new ArenaError(`未知命令：${String(type)}`);
  }
}

function isTrustedSender(sender) {
  try {
    if (!sender || sender.id !== chrome.runtime.id) return false;
    const base = chrome.runtime.getURL('');
    const url = typeof sender.url === 'string' ? sender.url : '';
    if (!url.startsWith(base)) return false;
    const path = url.slice(base.length).split(/[?#]/)[0];
    return path === 'workspace.html';
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

// automation.js owns every automation.* message and validates its own sender.
// It only writes through the same two command paths used by the UI, so the
// stored session remains the single source of truth.
if (typeof chrome !== 'undefined' && chrome.runtime) {
  automationApi = installAutomation({
    getSession: async (id) => (await commandGet({ id })).session,
    act: async (id, action, payload) => (await commandAct({ id, action, payload })).session,
  });
}

if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.onMessage) {
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (
      message
      && typeof message === 'object'
      && typeof message.type === 'string'
      && message.type.startsWith('automation.')
    ) {
      // Not ours: do not answer, do not keep the channel open, and do not
      // shadow automation.js's own listener.
      return false;
    }

    let replied = false;
    const reply = (value) => {
      if (replied) return;
      replied = true;
      try {
        sendResponse(value);
      } catch {
        /* the UI channel may already be closed */
      }
    };

    if (!isTrustedSender(sender)) {
      reply({ ok: false, error: '只接受本扩展工作台页面的请求' });
      return false;
    }

    handleCommand(message).then(
      (data) => reply({ ok: true, ...data }),
      (error) => reply({ ok: false, error: errorMessage(error) }),
    );
    return true;
  });
}

// ---------------------------------------------------------------------------
// Toolbar entry: one workspace tab, never a second copy
// ---------------------------------------------------------------------------

const WORKSPACE_PAGE = 'workspace.html';

/**
 * True only for this extension's own workspace page. The path must match
 * exactly, so `workspace.html.evil`, another extension's page or a provider
 * tab that merely mentions the name never counts as the workspace.
 */
function isWorkspaceTabUrl(url, baseUrl) {
  if (typeof url !== 'string' || !url || typeof baseUrl !== 'string' || !baseUrl) return false;
  let target;
  let base;
  try {
    target = new URL(url);
    base = new URL(baseUrl);
  } catch {
    return false;
  }
  if (target.protocol !== base.protocol || target.host !== base.host) return false;
  return target.pathname === base.pathname;
}

/**
 * The tab's destination URL decides: a tab that is loading the workspace is
 * reusable, one that is leaving it (pendingUrl points elsewhere) is not.
 */
function workspaceTabUrl(tab) {
  return tabEntryUrl(tab);
}

/**
 * Query only this extension's own workspace page. The URL filter is applied by
 * the browser, so no other tab's address is even read back; the strict URL check
 * afterwards rejects anything the pattern still let through. The focused window
 * is asked first, so a workspace open in the window the user clicked in wins
 * over one in a background window; if that window has none, all windows are
 * searched rather than opening a duplicate.
 */
async function queryWorkspaceTabs(tabsApi, baseUrl) {
  const pattern = `${baseUrl}*`;
  const found = new Map();
  for (const filter of [{ url: pattern, lastFocusedWindow: true }, { url: pattern }]) {
    let tabs;
    try {
      tabs = await tabsApi.query(filter);
    } catch {
      // No filtered query (older browser): report nothing instead of reading
      // every tab's address. The click then opens one tab, as it did before.
      continue;
    }
    for (const tab of Array.isArray(tabs) ? tabs : []) {
      if (tab && Number.isInteger(tab.id) && isWorkspaceTabUrl(workspaceTabUrl(tab), baseUrl)) {
        found.set(tab.id, tab);
      }
    }
    if (found.size) break;
  }
  return [...found.values()];
}

/**
 * Prefer the workspace the user is looking at, then the most recently used one,
 * so several open workspaces still produce one deterministic tab to focus.
 */
function pickWorkspaceTab(tabs, baseUrl) {
  const usable = (Array.isArray(tabs) ? tabs : []).filter(
    (tab) => tab && Number.isInteger(tab.id) && isWorkspaceTabUrl(workspaceTabUrl(tab), baseUrl),
  );
  if (!usable.length) return null;
  const active = usable.filter((tab) => tab.active === true);
  const pool = active.length ? active : usable;
  return pool.reduce((best, tab) => (
    (Number(tab.lastAccessed) || 0) > (Number(best.lastAccessed) || 0) ? tab : best
  ), pool[0]);
}

async function openWorkspaceTabOnce({ tabs = chrome.tabs, windows = chrome.windows } = {}) {
  const baseUrl = chrome.runtime.getURL(WORKSPACE_PAGE);
  const existing = pickWorkspaceTab(await queryWorkspaceTabs(tabs, baseUrl), baseUrl);
  if (existing) {
    try {
      // Activating keeps the tab's URL, `#s=<session>` route and in-memory draft
      // untouched: nothing here navigates, reloads or rewrites the hash.
      await focusTab(existing, tabs, windows);
      return { tabId: existing.id, created: false };
    } catch {
      // Closed or replaced between the query and the focus: open a fresh tab.
    }
  }
  const created = await tabs.create({ url: baseUrl, active: true });
  if (!created || !Number.isInteger(created.id)) throw new ArenaError('无法打开工作台标签');
  return { tabId: created.id, created: true };
}

/**
 * Two clicks before the first tab exists join one attempt, so a slow open can
 * not produce two workspaces. After a worker restart this map is empty again and
 * the filtered query alone prevents the duplicate.
 */
let pendingWorkspaceOpen = null;

function openWorkspaceTab(overrides = {}) {
  if (pendingWorkspaceOpen) return pendingWorkspaceOpen;
  const attempt = openWorkspaceTabOnce(overrides);
  pendingWorkspaceOpen = attempt;
  return attempt.finally(() => {
    if (pendingWorkspaceOpen === attempt) pendingWorkspaceOpen = null;
  });
}

async function handleWorkspaceClick() {
  try {
    await openWorkspaceTab();
  } catch {
    /* opening the workspace is a convenience, not state */
  }
}

if (typeof chrome !== 'undefined' && chrome.action && chrome.action.onClicked) {
  chrome.action.onClicked.addListener(() => {
    void handleWorkspaceClick();
  });
}

// Test surface for tests/tab-reuse.mjs and tests/workspace-entry.mjs. A service
// worker ignores exports; the real wiring above is unchanged.
export {
  openProviderTab,
  tabMatchesEntry,
  tabEntryUrl,
  sameOrigin,
  seatOf,
  openWorkspaceTab,
  pickWorkspaceTab,
  isWorkspaceTabUrl,
};
