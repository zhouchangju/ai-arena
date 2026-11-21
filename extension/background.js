// AI Arena — MV3 service worker (G1, G3, G4)
//
// UI ⇄ worker contract:
//   sendMessage({ type: 'list' })
//   sendMessage({ type: 'get', id })
//   sendMessage({ type: 'create', question, providers: [idA, idB] })
//   sendMessage({ type: 'act', id, action, payload })
//      actions: 'answer' {taskId, text, stance?, version?, stage?, round?}
//               'skip' {taskId} | 'pause' | 'resume' | 'finish'
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
//   allowlists. `create` needs exactly two distinct canonical lowercase provider
//   ids from providers.js; `open` only opens a registry URL for a seat that is
//   actually part of the session.
//
// Persistence: one IndexedDB database. Every read-modify-write command runs
// through a promise queue *and* inside a single readwrite transaction, so two
// workspace windows or a double click can not lose each other's update. A
// failing mutator aborts the transaction, so no partial state is written.

import { createSession, applyAction } from './core.js';
import { PROVIDERS, isProviderId } from './providers.js';

const STANCES = new Set(['agree', 'conditional', 'oppose']);
const COMMAND_TYPES = new Set(['list', 'get', 'create', 'act', 'delete', 'open']);
const ACTIONS = new Set(['answer', 'skip', 'pause', 'resume', 'finish']);

const MAX_QUESTION = 8000;
const MAX_ANSWER = 200000;
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
  if (!Array.isArray(value) || value.length !== 2) {
    throw new ArenaError('本版本需要恰好两个参与席位');
  }
  const providers = value.map((provider) => {
    if (!isProviderId(provider)) {
      throw new ArenaError(
        `未知或不规范的席位标识：${String(provider)}；必须使用小写规范 id`,
      );
    }
    return provider;
  });
  if (providers[0] === providers[1]) throw new ArenaError('两个席位不能相同');
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

  if (action === 'skip') {
    return { taskId: requireTaskId(payload.taskId) };
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
 * Chrome withholds a provider tab's URL unless the extension holds `tabs` or a
 * matching host permission (the current manifest has neither). To avoid
 * focusing a dedicated tab the user navigated elsewhere, remember the tabs we
 * opened during this worker lifetime and watch their load events: a tab is
 * reusable without a readable URL only after it completed its initial load and
 * before any later navigation starts. After a worker restart this memory is
 * empty, so the conservative path (open a fresh tab) is taken instead of
 * guessing. URL-readable tabs are always verified by origin at open time.
 */
const seatTabState = new Map();

function rememberSeatTab(tabId, sessionId, providerId) {
  seatTabState.set(tabId, { sessionId, providerId, phase: 'loading' });
}

function seatTabIsTrusted(tabId, sessionId, providerId) {
  const seat = seatTabState.get(tabId);
  if (!seat) return false;
  if (seat.sessionId !== sessionId || seat.providerId !== providerId) return false;
  return seat.phase === 'ready';
}

function watchSeatTabs() {
  if (typeof chrome === 'undefined' || !chrome.tabs) return;
  if (chrome.tabs.onUpdated) {
    chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
      const seat = seatTabState.get(tabId);
      if (!seat) return;
      if (changeInfo.status === 'complete') {
        if (seat.phase === 'loading') seat.phase = 'ready';
        return;
      }
      if (changeInfo.status === 'loading' && seat.phase === 'ready') {
        // A load after the seat page was ready may be another site entirely;
        // stop treating this tab as reusable without a URL check.
        seat.phase = 'dirty';
      }
    });
  }
  if (chrome.tabs.onRemoved) {
    chrome.tabs.onRemoved.addListener((tabId) => seatTabState.delete(tabId));
  }
  if (chrome.tabs.onReplaced) {
    chrome.tabs.onReplaced.addListener((addedTabId, removedTabId) => {
      seatTabState.delete(removedTabId);
      seatTabState.delete(addedTabId);
    });
  }
}

watchSeatTabs();

function readableTabUrl(tab) {
  if (!tab || typeof tab !== 'object') return '';
  if (typeof tab.url === 'string' && tab.url) return tab.url;
  if (typeof tab.pendingUrl === 'string' && tab.pendingUrl) return tab.pendingUrl;
  return '';
}

function sameOrigin(left, right) {
  try {
    return new URL(left).origin === new URL(right).origin;
  } catch {
    return false;
  }
}

async function focusTab(tab) {
  await chrome.tabs.update(tab.id, { active: true });
  if (Number.isInteger(tab.windowId) && chrome.windows && chrome.windows.update) {
    try {
      await chrome.windows.update(tab.windowId, { focused: true });
    } catch {
      /* focusing the window is best effort */
    }
  }
}

/**
 * Reuse the dedicated seat tab only when Chrome lets us prove it still points
 * at the provider origin.
 *
 * With the current manifest (extension has only `storage`), Chrome hides
 * `tab.url`/`pendingUrl` for provider tabs. An unreadable URL therefore means
 * "unverified", not "matches". The tab is reused only when this worker watched
 * it complete its initial load and start no later navigation (see
 * `seatTabState`); otherwise focusing it would treat a tab the user (or the
 * site) navigated elsewhere as the seat page — the hijacking case this function
 * must avoid. In that case the stale binding is dropped and a fresh dedicated
 * tab is opened at the allowlisted entry URL, leaving the user's navigated tab
 * untouched. Adding a `tabs`/host permission later makes origin reuse work even
 * after a worker restart, with no other change here.
 */
async function openProviderTab(sessionId, providerId) {
  const provider = PROVIDERS[providerId];
  const key = bindingKey(sessionId, providerId);

  let binding = null;
  try {
    binding = await getBinding(key);
  } catch {
    binding = null;
  }

  if (binding && Number.isInteger(binding.tabId)) {
    let tab = null;
    try {
      tab = await chrome.tabs.get(binding.tabId);
    } catch {
      tab = null;
    }

    if (tab && Number.isInteger(tab.id)) {
      const url = readableTabUrl(tab);
      if (url && sameOrigin(url, provider.url)) {
        await focusTab(tab);
        await setBinding(key, {
          ...binding,
          provider: providerId,
          sessionId,
          entryUrl: provider.url,
          lastOpenedAt: Date.now(),
        });
        return tab.id;
      }
      if (!url && seatTabIsTrusted(tab.id, sessionId, providerId)) {
        await focusTab(tab);
        await setBinding(key, {
          ...binding,
          provider: providerId,
          sessionId,
          entryUrl: provider.url,
          lastOpenedAt: Date.now(),
        });
        return tab.id;
      }
      // Readable mismatch: the seat tab now shows another site. Unreadable and
      // untrusted: we cannot prove it is still the provider tab. In both cases,
      // never yank/focus it; discard the binding and open a clean tab below.
      seatTabState.delete(tab.id);
      try {
        await dropBinding(key);
      } catch {
        /* the fresh tab below is still the safe outcome */
      }
    } else {
      if (Number.isInteger(binding.tabId)) seatTabState.delete(binding.tabId);
      try {
        await dropBinding(key);
      } catch {
        /* closed tab: fall through to a fresh one */
      }
    }
  }

  const tab = await chrome.tabs.create({ url: provider.url, active: true });
  if (!tab || !Number.isInteger(tab.id)) throw new ArenaError('无法打开网页标签');
  rememberSeatTab(tab.id, sessionId, providerId);
  await setBinding(key, {
    tabId: tab.id,
    provider: providerId,
    sessionId,
    entryUrl: provider.url,
    openedAt: Date.now(),
    lastOpenedAt: Date.now(),
  });
  return tab.id;
}

// ---------------------------------------------------------------------------
// Command handling
// ---------------------------------------------------------------------------

let queueTail = Promise.resolve();

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
    await openProviderTab(session.id, provider);
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

if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.onMessage) {
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
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

if (typeof chrome !== 'undefined' && chrome.action && chrome.action.onClicked) {
  chrome.action.onClicked.addListener(() => {
    try {
      const result = chrome.tabs.create({ url: chrome.runtime.getURL('workspace.html') });
      if (result && typeof result.catch === 'function') result.catch(() => {});
    } catch {
      /* opening the workspace is a convenience, not state */
    }
  });
}
