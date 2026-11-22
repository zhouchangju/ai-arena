/**
 * AI Arena — background automation for real web pages (G1, G3; R02, R06, R09).
 *
 * Two kinds of seats can be driven:
 *   - user-configured loopback pages (`local-a`, `local-b`) with CSS selectors
 *     saved under 连接设置; behaviour is unchanged from the previous version;
 *   - the three public sites `chatgpt`, `gemini`, `deepseek`, whose fixed HTTPS
 *     origins are published in `providers.js` and in the manifest's optional
 *     host permissions. Their selectors come from `provider-web-configs.js`.
 *     They only work after the user grants the matching origin permission at
 *     the moment automation is started; without it that one seat pauses.
 *
 * No credentials, API keys, network interception, debugger attachment or site
 * policy changes are involved. The page keeps its own login and markup.
 *
 * Wiring contract:
 *   installAutomation({ getSession, act })
 *     getSession(id) -> full raw session (all fields, including tasks/history)
 *     act(id, action, payload) -> updated raw session
 *
 * Trusted extension-page messages (workspace.html or another extension page):
 *   { type: 'automation.config', provider, config: { url, selectors } | null }
 *   { type: 'automation.info' }
 *   { type: 'automation.start', id, windowId? }
 *   { type: 'automation.stop', id }
 *   { type: 'automation.takeover', id, provider, taskId? }
 *   -> { ok: true, ... } | { ok: false, error }
 *
 * Driver contract, delivered to the page as `web-driver.js`:
 *   { type: 'arena.web.submit' | 'arena.web.read' | 'arena.web.probe',
 *     taskId, prompt?, selectors, options?, scope? }
 *   -> { ok, status, text?, error?, detail? }
 *
 * Safety properties enforced here:
 * - Local URLs must be http(s) on exactly `localhost` or `127.0.0.1`. Public
 *   seats use only the origin published in the provider registry.
 * - Every driver call re-checks that the dedicated tab's origin is the exact
 *   configured origin, not merely a similar hostname.
 * - Public seats are opened once at their blank new-conversation entry page and
 *   that same tab/conversation is reused for the rest of the run.
 * - The dispatch intent is persisted *before* the submit command. After a
 *   worker restart, an intent in `dispatching`/`verifying` is only ever
 *   re-read, never re-submitted. Unknown state produces a per-seat pause.
 * - A seat is marked `submitted` only after the driver matched the exact user
 *   message of this round in the page. A click that was observed but not
 *   verified stays `verifying` and is only read afterwards.
 * - A send control that is still hidden/missing **before any click** is a safe,
 *   bounded wait: the driver returns `send-pending` with
 *   `clickAttempted:false`, and this module retries for at most ~45 s with
 *   pause/takeover checks between attempts. Once a click happened, any
 *   unconfirmed state is read-only and never retried.
 * - Two public-site states may borrow the front for 3–5 s, at most once per
 *   task, and only while this workbench is still the active tab: a Gemini send
 *   control that the driver proved un-clicked, and a DeepSeek read-only
 *   reconciliation after that page's own same-origin address change. A third,
 *   separate one-per-task allowance belongs to the read lane only: a confirmed
 *   transport timeout of `arena.web.read`, a clicked same-page round that
 *   stays unverified past a grace window, or an already-verified round whose
 *   stable body is still missing the site's native completion marker, gets one
 *   bounded foreground look so the page can paint this round's transcript. It
 *   is read-only (never a submit), it requires the run's own bound tab at the
 *   exact configured origin, and it expires into a per-seat pause if the round
 *   is still unproven afterwards. The workbench gets the front back afterwards;
 *   a user who already moved elsewhere is never pulled back, and nothing is
 *   ever sent.
 * - Before any dispatch intent exists, a public-site composer that is not ready
 *   is probed read-only for a bounded ~38 s, with one bounded foreground look
 *   from those same ownership checks. A discussion pause, seat pause, stop or
 *   takeover ends that wait immediately; nothing is filled or sent.
 * - A new-conversation page may restore the previous prompt that Arena itself
 *   confirmed sending to the same provider. Only then may the driver replace
 *   it, and only when the page is the configured new-conversation home with an
 *   empty user/answer baseline and the draft's precomputed SHA-256 matches one
 *   of a few recent confirmed dispatch prompts for this provider. The page
 *   receives digests only; historical prompt text is never sent to the site.
 * - Answers are written only through `act('answer', ...)` after re-reading the
 *   session: stale tasks, paused sessions and changed votes are never attached
 *   to the wrong round.
 * - A running answer is exposed as `run.seats[provider].preview` bound to its
 *   taskId. A preview is never written as an answer, never enters cross-review
 *   and is cleared when the task changes or the formal answer is saved.
 * - `automation.takeover` stops exactly one seat for the rest of the run: it
 *   never sends again and keeps its dispatch record for audit.
 * - Votes are recognized only from one exact `STANCE: ...` line. Anything else
 *   is handled manually, never guessed.
 * - The module keeps a single pump lock, so two UI polls can not submit the
 *   same task twice.
 */

import {
  AUTOMATION_PROVIDER_IDS,
  LOCAL_AUTOMATION_PROVIDER_IDS,
} from './providers.js';
import { isWebSiteProvider, webSiteConfig, webSiteConfigProblem } from './provider-web-configs.js';
import { PUBLIC_WEB_VOTE_FORMAT } from './core.js';

/** Seats this module may drive: two local pages and three public sites. */
export const AUTOMATION_PROVIDERS = Object.freeze([...AUTOMATION_PROVIDER_IDS]);

const LOCAL_SET = new Set(LOCAL_AUTOMATION_PROVIDER_IDS);
const AUTOMATION_SET = new Set(AUTOMATION_PROVIDERS);
const STORE_KEY = 'arena.automation.v1';
const DRIVER_FILE = 'web-driver.js';
const ALARM_NAME = 'arena.automation.poll';
const POLL_MS = 1500;
const DRIVER_TIMEOUT_MS = 45000;
const TAB_READY_TIMEOUT_MS = 20000;
/**
 * Some public pages keep `tab.status === 'loading'` long after their composer
 * is usable (long-poll / streaming sub-resources). Once the tab has been
 * loading this long at the exact same origin with no pending navigation, the
 * page driver's own composer probe decides readiness instead of the load flag.
 */
const TAB_LOADING_GRACE_MS = 2500;
const TAB_READY_PROBE_MS = 1200;
/**
 * A freshly created background tab can keep its first navigation uncommitted,
 * especially in a second arena of the same workbench. Once this long has passed
 * without the configured origin committing, the same tab is briefly activated
 * to start that navigation and the workbench is put back in front.
 */
const FIRST_NAVIGATION_GRACE_MS = 4000;
/** How long the freshly activated tab may stay in front while it starts. */
const FIRST_NAVIGATION_START_MS = 1500;
const FIRST_NAVIGATION_POLL_MS = 250;
/**
 * Some public pages only paint their send control or their conversation body
 * once they have been the active tab (a background tab is throttled or keeps a
 * virtualized transcript unmounted). The bounded fallback below may bring one
 * seat's bound page to the front for a few seconds, then give the workbench
 * back. It never navigates, reads, clicks or sends by itself.
 */
const FOREGROUND_FALLBACK_WAIT_MS = 3500;
const FOREGROUND_FALLBACK_MIN_MS = 3000;
const FOREGROUND_FALLBACK_MAX_MS = 5000;
const FOREGROUND_FALLBACK_POLL_MS = 250;
/** Seats allowed the pre-click fallback; only an un-clicked Gemini composer. */
const PRE_CLICK_FOREGROUND_PROVIDERS = new Set(['gemini']);
/** Seats allowed the read-only reconciliation fallback after a same-origin move. */
const RECONCILE_FOREGROUND_PROVIDERS = new Set(['deepseek']);
/**
 * Read-lane recovery (G3/R06). A clicked seat that stays `verifying` on its own
 * bound page this long gets one bounded, read-only foreground look; if it is
 * still unproven this long after that look, it becomes a per-seat takeover.
 * `readRecoveryAt` is a separate allowance from the pre-click / address-change
 * fallback, so neither can consume the other, and no click is ever involved.
 */
const READ_RECOVERY_STUCK_MS = 15000;
const READ_RECOVERY_GRACE_MS = 15000;
/**
 * The third read-lane case (G2/G3, R06; real Gemini page 2026-11-22): this
 * round's user turn is verified and the driver already reads body text that
 * stays unchanged, but the site never paints its native finished-action control
 * while the bound tab stays in the background. The driver then answers
 * `completion-signal-missing` for as long as the tab is throttled (observed
 * ~90 s with an 11-character title), and no transport error exists to justify
 * the timeout lane. A short title must never finish the seat, so after this much
 * driver-measured wall-clock stability on exactly this pending shape, the same
 * single per-task read allowance may be spent on one bounded foreground look;
 * the round keeps waiting and the next tick reads the original page again.
 */
const COMPLETION_FOREGROUND_MIN_STABLE_MS = 8000;
/** Only the site that requires a live native done marker is affected. */
const COMPLETION_FOREGROUND_PROVIDERS = new Set(['gemini']);
/** Read-only probe id; it never creates a driver task record. */
const READINESS_TASK_ID = 'arena.readiness.probe';
/**
 * After a click, a public site may route a new conversation to its own URL
 * (`deepseek` /a/chat/ → /a/chat/s/<id>). While the driver has not yet matched
 * this round's exact user message on the new address it answers
 * `page-changed`. That is retried read-only for this long before pausing.
 */
const NAVIGATION_RECOVERY_MS = 45000;
const MAX_URL_LENGTH = 2000;
const MAX_SELECTOR_LENGTH = 400;
const MAX_RUNS = 50;
const MAX_PREVIEW_CHARS = 12000;
const RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const DRIVER_TASK_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/;

const SELECTOR_KEYS = ['input', 'send', 'user', 'answer', 'stop', 'done', 'container'];
const REQUIRED_SELECTOR_KEYS = ['input', 'send', 'user', 'answer'];

/** Dispatch intent phases. `verifying` means "clicked, user turn not proven". */
const DISPATCH_PHASES = [
  'probing',
  'dispatching',
  'waiting-send',
  'verifying',
  'submitted',
  'streaming',
  'answered',
  'stale',
  'paused',
];
/** Dispatch phases that only exist after this round's user turn was verified. */
const CONFIRMED_DISPATCH_PHASES = new Set(['submitted', 'streaming', 'answered']);
/** A pre-click send control that is not visible yet may be retried for this long. */
const PRE_CLICK_RETRY_DEADLINE_MS = 45000;
/** Delays between pre-click attempts; the pump itself ticks about every 1.5 s. */
const PRE_CLICK_RETRY_DELAYS_MS = [0, 1200, 2000, 3000, 4500, 6000];
const PRE_CLICK_RETRY_MAX_ATTEMPTS = 6;
/**
 * Public-site composer readiness before any dispatch intent exists (G1/R06).
 * A fresh conversation tab may commit late, or paint its composer only once it
 * has been in front, so a page that answered `selector-missing` at 12 s can be
 * complete shortly after. Readiness is still only a page probe: this path never
 * fills, clicks or sends, so no sent state or login judgement is involved. The
 * wait stays bounded at ~38 s with one bounded foreground look inside it; a
 * pause or takeover ends it immediately and other seats keep their own ticks.
 */
const PROBE_READY_DEADLINE_MS = 38000;
const PROBE_FOREGROUND_AFTER_CHECKS = 4;
const PROBE_RETRY_DELAYS_MS = [500, 500, 750, 1000, 1500];
/** Readiness errors that only mean "the composer is not there yet". */
const PROBE_RETRY_ERRORS = new Set([
  'selector-missing',
  'selector-hidden',
  'document-not-ready',
]);
/** Only recent runs and a small number of exact old prompts are considered. */
const KNOWN_DRAFT_RUN_LIMIT = 5;
const KNOWN_DRAFT_DIGEST_LIMIT = 8;
/** Seats that still mean "this module is driving the page". */
const ACTIVE_SEAT_STATUSES = new Set([
  'probing',
  'dispatching',
  'verifying',
  'submitted',
  'streaming',
  'waiting',
]);

const DONE_STATUSES = new Set(['done', 'complete', 'completed', 'finished']);
const READY_STATUSES = new Set(['ready', 'ok']);

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
    mode: 'local',
    url: url.href,
    origin: url.origin,
    selectors,
    options: {},
    allowNavigation: false,
    updatedAt: Date.now(),
  };
}

/** Local seats are configured from 连接设置; public sites come from the adapter. */
function requireLocalAutomationProvider(value) {
  if (typeof value !== 'string' || !LOCAL_SET.has(value)) {
    throw new Error(`该席位不使用网页连接设置：${String(value)}`);
  }
  return value;
}

/**
 * Resolve the internal config for one seat. Public adapters are built in; a
 * missing/broken adapter yields a reason that pauses only that seat.
 */
function resolveConfig(provider, stored) {
  if (isWebSiteProvider(provider)) {
    const config = webSiteConfig(provider);
    if (config) return { config, problem: '' };
    return { config: null, problem: webSiteConfigProblem(provider) || '该站点适配器不可用' };
  }
  if (LOCAL_SET.has(provider)) {
    return stored
      ? { config: stored, problem: '' }
      : { config: null, problem: '该席尚未配置本机网址与 CSS，可人工处理' };
  }
  return { config: null, problem: '该席位不支持自动驱动' };
}

function configsForDriver(config) {
  const selectors = {};
  for (const key of SELECTOR_KEYS) {
    if (config.selectors[key]) selectors[key] = config.selectors[key];
  }
  return selectors;
}

function optionsForDriver(config, overrides) {
  const base = config.mode === 'site'
    ? { previewChars: MAX_PREVIEW_CHARS, ...config.options }
    : {};
  return overrides ? { ...base, ...overrides } : base;
}

function scopeFor(config) {
  // The driver re-checks its own location against this exact origin, in
  // addition to the tab-origin assertion in this module. Only the built-in
  // site adapters may follow a same-origin SPA route change, and the driver
  // still requires the exact user turn of this round before it does.
  // `homeHref` is the provider's own new-conversation entry page; the driver
  // requires it (plus an empty history) before it may replace a restored old
  // prompt in the composer.
  return {
    origin: config.origin,
    homeHref: config.url,
    allowNavigation: config.allowNavigation === true,
  };
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
    for (const provider of LOCAL_AUTOMATION_PROVIDER_IDS) {
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
    windowId: Number.isInteger(raw.windowId) && raw.windowId >= 0 ? raw.windowId : null,
    openerTabId: Number.isInteger(raw.openerTabId) && raw.openerTabId >= 0 ? raw.openerTabId : null,
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
      const phase = DISPATCH_PHASES.includes(item.phase) ? item.phase : 'paused';
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
        clickAttempted: item.clickAttempted === true,
        preClickAttempts:
          Number.isInteger(item.preClickAttempts) && item.preClickAttempts >= 0
            ? item.preClickAttempts
            : 0,
        preClickFirstAt: Number.isFinite(item.preClickFirstAt) ? item.preClickFirstAt : 0,
        preClickNextAt: Number.isFinite(item.preClickNextAt) ? item.preClickNextAt : 0,
        preClickDeadline: Number.isFinite(item.preClickDeadline) ? item.preClickDeadline : 0,
        lastPreClickReason:
          typeof item.lastPreClickReason === 'string' ? item.lastPreClickReason : '',
        foregroundFallbackAt:
          Number.isFinite(item.foregroundFallbackAt) ? item.foregroundFallbackAt : 0,
        verifyingSince: Number.isFinite(item.verifyingSince) ? item.verifyingSince : 0,
        readRecoveryAt: Number.isFinite(item.readRecoveryAt) ? item.readRecoveryAt : 0,
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
        takenOver: seat.takenOver === true,
        preview: normalizePreview(seat.preview),
        at: Number.isFinite(seat.at) ? seat.at : Date.now(),
      };
    }
  }

  return run;
}

/** A preview is a bounded page snippet tied to exactly one task id. */
function normalizePreview(raw) {
  if (!isPlainObject(raw)) return null;
  if (typeof raw.taskId !== 'string' || !raw.taskId) return null;
  if (typeof raw.text !== 'string' || raw.text.trim().length === 0) return null;
  return {
    taskId: raw.taskId,
    text: raw.text.slice(0, MAX_PREVIEW_CHARS),
    chars: Number.isFinite(raw.chars) && raw.chars > 0 ? Math.floor(raw.chars) : raw.text.length,
    truncated: raw.truncated === true,
    at: Number.isFinite(raw.at) ? raw.at : Date.now(),
  };
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

function publicRun(run) {
  return {
    id: run.id,
    enabled: run.enabled,
    completed: run.completed,
    startedAt: run.startedAt,
    updatedAt: run.updatedAt,
    stoppedAt: run.stoppedAt,
    windowId: Number.isInteger(run.windowId) ? run.windowId : null,
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

function assertConfigOrigin(config) {
  let url;
  try {
    url = new URL(config.origin);
  } catch {
    throw new Error('配置的来源无效');
  }
  if (config.mode === 'site') {
    if (url.protocol !== 'https:') throw new Error('公开站点只接受固定 HTTPS 来源');
    return url.origin;
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
  // Match patterns do not take ports; this grants the host only.
  return `${url.protocol}//${url.hostname}/*`;
}

/**
 * Check the exact optional host permission for one seat. The request itself
 * must happen in the UI on a user gesture; here we only verify it and fail one
 * seat, never the whole run.
 */
async function ensureOriginPermission(config) {
  const pattern = permissionPattern(config.origin);
  if (!chrome.permissions?.contains || !(await chrome.permissions.contains({ origins: [pattern] }))) {
    throw new Error(`尚未授予 ${pattern} 的访问权限；请在工作台允许该站点后重新开始`);
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
  let loadingSince = 0;
  let lastProbeAt = 0;
  while (Date.now() < deadline) {
    const tab = await getTab(tabId);
    if (!tab) throw new Error('自动化标签页已关闭');
    if (tab.discarded) throw new Error('自动化标签页已被浏览器丢弃，请重新开始');
    if (typeof tab.url === 'string' && tab.url) {
      const origin = originOf(tab.url);
      const pendingOrigin = originOf(tab.pendingUrl);
      if (origin === config.origin) {
        if (tab.status !== 'loading' && !tab.pendingUrl) return tab;
        if (tab.status === 'loading' && !tab.pendingUrl) {
          // No pending navigation: the same-origin document is already
          // committed, so probing it can not touch a previous page. Gemini
          // stays `loading` while its composer is fully usable; judge by the
          // composer instead of by every sub-resource finishing.
          if (!loadingSince) loadingSince = Date.now();
          if (
            Date.now() - loadingSince >= TAB_LOADING_GRACE_MS &&
            Date.now() - lastProbeAt >= TAB_READY_PROBE_MS
          ) {
            lastProbeAt = Date.now();
            if (await composerReady(tabId, config)) return tab;
          }
          lastError = '页面仍在加载（输入框尚未就绪）';
        } else {
          lastError = '页面仍在加载';
        }
      } else if (tab.status === 'loading' || pendingOrigin === config.origin || tab.url === 'about:blank') {
        loadingSince = 0;
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
 * Composer-based readiness for a same-origin tab that still reports `loading`.
 * Read-only: it asks the page driver for one `probe` (no fill, no click) and
 * accepts only `ready`, then re-reads the tab to make sure the document did not
 * swap under it. A same-origin SPA route change keeps its record, so this never
 * turns a half-navigated tab into a submit target by itself.
 */
async function composerReady(tabId, config) {
  const before = await getTab(tabId);
  if (!before || !before.url || before.pendingUrl) return false;
  if (originOf(before.url) !== config.origin) return false;
  let reply;
  try {
    reply = await withTimeout(
      deliver(tabId, {
        type: 'arena.web.probe',
        taskId: READINESS_TASK_ID,
        selectors: configsForDriver(config),
        options: optionsForDriver(config),
        scope: scopeFor(config),
      }),
      DRIVER_TIMEOUT_MS,
      '网页驱动调用',
    );
  } catch {
    return false;
  }
  const probe = normalizeReply(reply);
  if (!probe.ok || !READY_STATUSES.has(probe.status)) return false;
  const after = await getTab(tabId);
  return Boolean(
    after &&
      !after.pendingUrl &&
      after.url === before.url &&
      originOf(after.url) === config.origin,
  );
}

/**
 * Serialize the short "activate the new tab, then give the workbench back"
 * switch so two fresh seats in one window can never fight for the front tab.
 */
let firstNavigationLock = Promise.resolve();

function withFirstNavigationLock(task) {
  const run = firstNavigationLock.then(task, task);
  firstNavigationLock = run.then(
    () => undefined,
    () => undefined,
  );
  return run;
}

/** The workbench that started this run is still the active tab of its window. */
function workbenchIsActive(opener, run) {
  if (!opener || !Number.isInteger(opener.id) || !opener.active) return false;
  if (opener.windowId !== run.windowId) return false;
  const workbench = chrome.runtime.getURL('workspace.html');
  return String(opener.url || '').split(/[?#]/, 1)[0] === workbench;
}

/**
 * Best effort for a newly created seat tab only: wait briefly for the first
 * navigation to commit, then activate that same bound tab once if it is still
 * stuck. Nothing is re-navigated, read or sent. The switch happens only while
 * this run still owns the tab and the workbench initiated from this window is
 * the active tab; if the user has moved elsewhere, no tab is taken back.
 */
async function startFirstNavigation(id, provider, tabId, config) {
  const deadline = Date.now() + FIRST_NAVIGATION_GRACE_MS;
  while (Date.now() < deadline) {
    const tab = await getTab(tabId);
    if (!tab || tab.discarded) return;
    if (originOf(tab.url) === config.origin) return;
    const pending = originOf(tab.pendingUrl);
    const waitingForOrigin =
      tab.status === 'loading' ||
      pending === config.origin ||
      !tab.url ||
      tab.url === 'about:blank';
    if (!waitingForOrigin) return;
    await sleep(FIRST_NAVIGATION_POLL_MS);
  }

  await withFirstNavigationLock(async () => {
    const store = await loadStore();
    const run = store.runs[id];
    if (!run || !run.enabled || run.completed) return;
    const seat = run.seats[provider];
    if (seat && (seat.paused || seat.takenOver)) return;
    const binding = run.tabs[provider];
    if (!binding || binding.tabId !== tabId || binding.origin !== config.origin) return;

    const tab = await getTab(tabId);
    if (!tab || tab.active || tab.discarded) return;
    if (originOf(tab.url) === config.origin) return;
    const opener = Number.isInteger(run.openerTabId) ? await getTab(run.openerTabId) : null;
    if (!workbenchIsActive(opener, run) || tab.windowId !== opener.windowId) return;

    await chrome.tabs.update(tabId, { active: true }).catch(() => {});

    const startDeadline = Date.now() + FIRST_NAVIGATION_START_MS;
    while (Date.now() < startDeadline) {
      const moved = await getTab(tabId);
      if (!moved || originOf(moved.url) === config.origin) break;
      await sleep(FIRST_NAVIGATION_POLL_MS);
    }

    const current = await getTab(tabId);
    if (!current || !current.active) return;
    const back = await getTab(opener.id);
    if (!back || back.windowId !== current.windowId) return;
    await chrome.tabs.update(opener.id, { active: true }).catch(() => {});
  });
}

/**
 * Claim the one-per-task foreground fallback without touching the dispatch
 * intent's own `at` clock (that clock bounds the address-change recovery).
 * Returns false when it was already used, or when the run/seat/intent is gone.
 */
async function claimForegroundFallback(id, provider, taskId) {
  let claimed = false;
  await updateRun(id, (run) => {
    if (!run.enabled || run.completed) return;
    const seat = run.seats[provider];
    if (seat && (seat.paused || seat.takenOver)) return;
    const intent = run.dispatch[taskId];
    if (!intent || intent.foregroundFallbackAt) return;
    intent.foregroundFallbackAt = Date.now();
    claimed = true;
  });
  return claimed;
}

/**
 * Minimal foreground fallback for one seat page (G1/R06): bring exactly this
 * seat's bound tab to the front for `waitMs` (clamped to 3–5 s), then give the
 * workbench back. The switch happens only while the run still owns that same
 * tab at the configured origin in the workbench's window and the workbench is
 * still the active tab; a user who already moved elsewhere is never pulled
 * back, and a switch away during the wait is not undone. Nothing is navigated
 * or sent here — the caller's own safe retry or read does the rest.
 *
 * Returns `shown`, `already-front`, `respected` (the user is elsewhere, so the
 * front is left alone) or `retry` (the page is momentarily not showable).
 */
async function brieflyShowSeatPage(id, provider, config, waitMs) {
  const bounded = Math.min(
    FOREGROUND_FALLBACK_MAX_MS,
    Math.max(
      FOREGROUND_FALLBACK_MIN_MS,
      Number.isFinite(waitMs) ? waitMs : FOREGROUND_FALLBACK_WAIT_MS,
    ),
  );

  return withFirstNavigationLock(async () => {
    const store = await loadStore();
    const run = store.runs[id];
    if (!run || !run.enabled || run.completed) return 'retry';
    const seat = run.seats[provider];
    if (seat && (seat.paused || seat.takenOver)) return 'retry';
    const binding = run.tabs[provider];
    if (!binding || !Number.isInteger(binding.tabId)) return 'retry';
    if (binding.origin !== config.origin) return 'retry';
    if (!Number.isInteger(run.openerTabId)) return 'retry';

    const opener = await getTab(run.openerTabId);
    if (!workbenchIsActive(opener, run)) return 'respected';

    const tab = await getTab(binding.tabId);
    if (!tab || tab.discarded || tab.pendingUrl) return 'retry';
    if (tab.windowId !== opener.windowId) return 'retry';
    if (originOf(tab.url) !== config.origin) return 'retry';
    if (tab.active) return 'already-front';

    // Any activation of another tab (the user coming back, or switching away)
    // ends the fallback without taking the front back from them.
    let userMoved = false;
    const activated = chrome.tabs.onActivated;
    const watch = (info) => {
      if (info && info.tabId !== binding.tabId) userMoved = true;
    };
    const canWatch = Boolean(activated && typeof activated.addListener === 'function');
    if (canWatch) activated.addListener(watch);
    try {
      await chrome.tabs.update(binding.tabId, { active: true }).catch(() => {});
      const deadline = Date.now() + bounded;
      while (!userMoved && Date.now() < deadline) {
        await sleep(FOREGROUND_FALLBACK_POLL_MS);
        const live = await getTab(binding.tabId);
        if (!live || !live.active) break;
      }

      const current = await getTab(binding.tabId);
      const back = await getTab(opener.id);
      if (
        !userMoved &&
        current &&
        current.active &&
        !current.pendingUrl &&
        originOf(current.url) === config.origin &&
        back &&
        back.windowId === current.windowId
      ) {
        await chrome.tabs.update(opener.id, { active: true }).catch(() => {});
      }
      return 'shown';
    } finally {
      if (canWatch) {
        try {
          activated.removeListener(watch);
        } catch {
          /* ignore */
        }
      }
    }
  });
}

/** Give a claimed fallback back so a later tick may try once more. */
async function releaseForegroundFallback(id, provider, taskId) {
  await updateRun(id, (run) => {
    const intent = run.dispatch[taskId];
    if (!intent) return;
    intent.foregroundFallbackAt = 0;
  });
}

/**
 * The whole fallback for one task: claim it, show the page if it really is
 * showable now, and hand the claim back when it was not. A transient page state
 * therefore does not consume the task's single allowance.
 */
async function showSeatPageOnce(id, provider, config, taskId) {
  if (!(await claimForegroundFallback(id, provider, taskId))) return false;
  const outcome = await brieflyShowSeatPage(
    id,
    provider,
    config,
    FOREGROUND_FALLBACK_WAIT_MS,
  );
  if (outcome === 'retry') {
    await releaseForegroundFallback(id, provider, taskId);
    return false;
  }
  return outcome === 'shown';
}

/** This module's own read transport timeout, not a site-side "generation timed out". */
function readTransportTimeout(error) {
  return /网页驱动调用超时/.test(messageOf(error));
}

/**
 * Claim the single read-only foreground look for this task. It is deliberately
 * separate from `foregroundFallbackAt` so the pre-click and address-change
 * allowances cannot consume it (or be consumed by it).
 */
async function claimReadRecovery(id, provider, taskId) {
  let claimed = false;
  await updateRun(id, (run) => {
    if (!run.enabled || run.completed) return;
    const seat = run.seats[provider];
    if (seat && (seat.paused || seat.takenOver)) return;
    const intent = run.dispatch[taskId];
    if (!intent || intent.readRecoveryAt) return;
    intent.readRecoveryAt = Date.now();
    claimed = true;
  });
  return claimed;
}

/** Hand the allowance back when no front was actually taken. */
async function releaseReadRecovery(id, provider, taskId) {
  await updateRun(id, (run) => {
    const intent = run.dispatch[taskId];
    if (!intent) return;
    intent.readRecoveryAt = 0;
  });
}

/**
 * One bounded foreground look at exactly this seat's own bound page, then the
 * workbench comes back. Public site seats only; the run, seat, binding, exact
 * origin and active workbench checks live in `brieflyShowSeatPage`, and no
 * navigation, click or submit is involved. `skipped` means the front was left
 * alone (the user is elsewhere or the page is momentarily not showable) and the
 * allowance was handed back, so a later tick may still use it.
 */
async function borrowSeatPageForRead(id, provider, config, taskId) {
  if (!isWebSiteProvider(provider)) return 'unsupported';
  if (!(await claimReadRecovery(id, provider, taskId))) return 'unavailable';
  const outcome = await brieflyShowSeatPage(
    id,
    provider,
    config,
    FOREGROUND_FALLBACK_WAIT_MS,
  );
  if (outcome === 'shown') return 'shown';
  await releaseReadRecovery(id, provider, taskId);
  return 'skipped';
}

/**
 * The clicked-and-still-unproven branch: after the stuck window one bounded
 * front look is allowed; once that look also failed to prove the turn for the
 * grace window, the seat is handed to the user instead of looping read-only
 * forever. `intent` is the pre-read record; `markDispatch` keeps both clocks.
 */
async function readRecoveryState(id, provider, config, task, intent) {
  // `verifying` itself means "clicked, user turn not proven"; a driver that
  // explicitly reported a click is equally sufficient.
  const clicked = intent.phase === 'verifying' || intent.clickAttempted === true;
  if (!clicked || !isWebSiteProvider(provider)) return 'none';
  const since = Number.isFinite(intent.verifyingSince) ? intent.verifyingSince : 0;
  if (!since || Date.now() - since < READ_RECOVERY_STUCK_MS) return 'none';
  const usedAt = Number.isFinite(intent.readRecoveryAt) ? intent.readRecoveryAt : 0;
  if (usedAt > 0) {
    return Date.now() - usedAt >= READ_RECOVERY_GRACE_MS ? 'exhausted' : 'none';
  }
  const borrow = await borrowSeatPageForRead(id, provider, config, task.id);
  return borrow === 'shown' ? 'shown' : 'none';
}

/**
 * Reuse only our own bound tab whose origin exactly matches the configured
 * origin. A user tab is never navigated; a mismatched tab is left alone and a
 * fresh dedicated tab is opened for this seat. Public seats start at their
 * blank new-conversation entry page and keep that same tab for later rounds.
 */
async function ensureTab(id, provider, config) {
  assertConfigOrigin(config);
  await ensureOriginPermission(config);

  const store = await loadStore();
  const run = store.runs[id] || null;
  if (!run || !run.enabled) throw new Error('自动化已停止，不再打开或读取网页');
  const binding = run.tabs[provider];
  if (binding && Number.isInteger(binding.tabId)) {
    const tab = await getTab(binding.tabId);
    if (tab && originOf(tab.url) === config.origin) {
      return waitForTabReady(binding.tabId, config);
    }
  }

  const createOptions = { url: 'about:blank', active: false };
  if (Number.isInteger(run.windowId) && run.windowId >= 0) {
    createOptions.windowId = run.windowId;
  }
  const opener = Number.isInteger(run.openerTabId) ? await getTab(run.openerTabId) : null;
  const workbench = chrome.runtime.getURL('workspace.html');
  if (opener?.windowId === run.windowId && originOf(opener.url) === originOf(workbench)
    && opener.url.split(/[?#]/, 1)[0] === workbench) {
    createOptions.openerTabId = opener.id;
  }
  const created = await chrome.tabs.create(createOptions);
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
  if (createOptions.openerTabId !== undefined && Number.isInteger(opener.groupId)
    && opener.groupId >= 0 && typeof chrome.tabs.group === 'function') {
    await chrome.tabs.group({ tabIds: created.id, groupId: opener.groupId }).catch(() => {});
  }
  if (!(await canContinue(id, provider))) throw new Error('这一席已暂停或交给人工');
  await chrome.tabs.update(created.id, { url: config.url });
  await startFirstNavigation(id, provider, created.id, config);
  return waitForTabReady(created.id, config);
}

async function assertTabOrigin(tabId, config) {
  const tab = await getTab(tabId);
  if (!tab) throw new Error('自动化标签页已关闭');
  const origin = originOf(tab.pendingUrl || tab.url);
  if (!origin) throw new Error('自动化标签页没有可读地址');
  if (origin !== config.origin) {
    throw new Error(`标签页来源已变为 ${origin}，与配置的 ${config.origin} 不一致`);
  }
  assertConfigOrigin(config);
  return tab;
}

function normalizeReply(reply) {
  if (!isPlainObject(reply)) {
    return { ok: false, status: 'unknown', text: '', error: '驱动没有返回有效结果', detail: {} };
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
    detail: isPlainObject(reply.detail) ? reply.detail : {},
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

async function callDriver(id, provider, config, command, optionOverrides) {
  let tab;
  if (command.type === 'arena.web.probe') {
    tab = await ensureTab(id, provider, config);
  } else {
    await ensureOriginPermission(config);
    const { runs } = await loadStore();
    const tabId = runs[id]?.tabs?.[provider]?.tabId;
    if (!Number.isInteger(tabId)) throw new Error('原页已失去绑定，请人工核对');
    tab = await waitForTabReady(tabId, config);
  }
  if (!(await canContinue(id, provider))) throw new Error('这一席已暂停或交给人工');
  await assertTabOrigin(tab.id, config);
  const payload = {
    ...command,
    selectors: configsForDriver(config),
    options: optionsForDriver(config, optionOverrides),
    scope: scopeFor(config),
  };
  let reply;
  try {
    reply = await withTimeout(
      deliver(tab.id, payload),
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

function previewFromReply(reply, taskId) {
  const raw = reply && reply.detail && reply.detail.preview;
  if (!isPlainObject(raw)) return undefined;
  if (typeof raw.text !== 'string' || raw.text.trim().length === 0) return undefined;
  return {
    taskId,
    text: raw.text.slice(0, MAX_PREVIEW_CHARS),
    chars: Number.isFinite(raw.chars) && raw.chars > 0 ? Math.floor(raw.chars) : raw.text.length,
    truncated: raw.truncated === true,
  };
}

/**
 * `preview === undefined` keeps the snippet when it belongs to the same task;
 * `preview === null` clears it; an object replaces it. Previews are only ever
 * stored here, never passed to `deps.act`, so they can not enter cross-review.
 */
function resolveSeatPreview(existing, taskId, preview) {
  if (preview === null) return null;
  if (preview && typeof preview === 'object') {
    const normalized = normalizePreview(preview);
    if (!normalized || normalized.taskId !== taskId) return null;
    const same = existing && existing.taskId === taskId && existing.text === normalized.text;
    return { ...normalized, at: same ? existing.at : Date.now() };
  }
  if (existing && existing.taskId === taskId) return existing;
  return null;
}

async function pauseSeat(id, provider, task, reason, detail, preview) {
  if (!(await runEnabled(id))) return;
  const actionHint =
    '该席不会自动重发。若仍可查看原对话，请先核对。已有完整回答可在工作台粘贴，也可跳过这一席。';
  const taskId = task ? task.id : '';
  return updateRun(id, (run) => {
    const seat = run.seats[provider] || {};
    if (!run.enabled || seat.takenOver) return;
    run.seats[provider] = {
      ...seat,
      status: 'paused',
      taskId,
      paused: true,
      detail: `${reason}${detail ? `：${detail}` : ''}。${actionHint}`,
      preview: resolveSeatPreview(seat.preview, taskId, preview),
      at: Date.now(),
    };
  });
}

async function noteSeat(id, provider, task, status, detail, preview) {
  if (!(await runEnabled(id))) return;
  const taskId = task ? task.id : '';
  return updateRun(id, (run) => {
    const seat = run.seats[provider] || {};
    if (!run.enabled || seat.takenOver) return;
    run.seats[provider] = {
      ...seat,
      status,
      taskId,
      paused: false,
      detail: detail || '',
      preview: resolveSeatPreview(seat.preview, taskId, preview),
      at: Date.now(),
    };
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
    if (!(await canContinue(id, provider))) return { outcome: 'stale', error: '该席已经暂停' };
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
    // Takeover or pause may land while the page driver call is in flight.
    if (!(await canContinue(id, provider))) {
      return { outcome: 'session-paused', error: '该席已暂停或由本人接管，不再写入回答' };
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
  if (stage !== 'vote' || task.prompt.endsWith(PUBLIC_WEB_VOTE_FORMAT)) return task.prompt;
  return `${task.prompt}${VOTE_INSTRUCTION}`;
}

// ---------------------------------------------------------------------------
// Known old prompt digests (draft-conflict recovery)
// ---------------------------------------------------------------------------

/** Must be byte-for-byte the driver's `collapse()` before hashing. */
function collapseForDigest(value) {
  return String(value == null ? '' : value)
    .replace(/\u00a0/g, ' ')
    .replace(/\r\n?/g, '\n')
    .replace(/[ \t]+$/gm, '')
    .replace(/\n{3,}/g, '\n\n')
    .replace(/^\s+|\s+$/g, '')
    .replace(/[\u200b-\u200d\ufeff]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

async function promptDigest(normalized) {
  const subtle = globalThis.crypto && globalThis.crypto.subtle;
  if (!subtle || typeof TextEncoder !== 'function' || typeof normalized !== 'string') {
    return '';
  }
  try {
    const hash = await subtle.digest('SHA-256', new TextEncoder().encode(normalized));
    return Array.from(new Uint8Array(hash))
      .map((byte) => byte.toString(16).padStart(2, '0'))
      .join('');
  } catch {
    return '';
  }
}

/**
 * Digests of prompts Arena already **confirmed as sent** to this one provider.
 * They come only from recent runs' dispatch records plus the exact archived
 * task prompt in that run's session; nothing is inferred from titles/prefixes.
 * Only the digest list is handed to the page, never the old prompt text.
 */
async function knownDraftDigests(provider) {
  let store;
  try {
    store = await loadStore();
  } catch {
    return [];
  }
  const runs = Object.values(store.runs)
    .filter((run) => run.dispatch && Object.keys(run.dispatch).length > 0)
    .sort((left, right) => right.updatedAt - left.updatedAt)
    .slice(0, KNOWN_DRAFT_RUN_LIMIT);

  const digests = [];
  for (const run of runs) {
    const entries = Object.entries(run.dispatch)
      .filter(
        ([, item]) =>
          item.provider === provider && CONFIRMED_DISPATCH_PHASES.has(item.phase),
      )
      .sort((left, right) => (right[1].at || 0) - (left[1].at || 0));
    if (entries.length === 0) continue;

    let session;
    try {
      session = await deps.getSession(run.id);
    } catch {
      session = null;
    }
    if (!session) continue;
    const pool = [
      ...(Array.isArray(session.history) ? session.history : []),
      ...(Array.isArray(session.tasks) ? session.tasks : []),
    ];

    for (const [taskId, item] of entries) {
      const task = pool.find(
        (candidate) =>
          candidate &&
          candidate.id === taskId &&
          candidate.provider === provider,
      );
      if (!task || typeof task.prompt !== 'string') continue;
      const stage =
        typeof item.stage === 'string' && item.stage
          ? item.stage
          : typeof task.stage === 'string'
            ? task.stage
            : '';
      const prompt = stagePrompt(task, stage);
      if (!prompt) continue;
      const digest = await promptDigest(collapseForDigest(prompt));
      if (!digest || digests.includes(digest)) continue;
      digests.push(digest);
      if (digests.length >= KNOWN_DRAFT_DIGEST_LIMIT) return digests;
    }
  }
  return digests;
}

async function markDispatch(id, provider, task, coords, patch) {
  return updateRun(id, (run) => {
    if (!run.enabled || run.seats[provider]?.takenOver) return;
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
    if (existing.phase === 'verifying') {
      // `at` is refreshed by every progress write, so it cannot measure how
      // long this round has gone unproven. Keep one stable clock instead.
      if (!existing.verifyingSince) existing.verifyingSince = Date.now();
    } else {
      existing.verifyingSince = 0;
    }
    run.dispatch[task.id] = existing;
  });
}

/** Stop, config edits and takeover win over an in-flight driver call. */
async function canContinue(id, provider) {
  try {
    const store = await loadStore();
    const run = store.runs[id];
    if (!run || !run.enabled || run.completed) return false;
    const seat = run.seats[provider];
    return !(seat && (seat.paused || seat.takenOver));
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
    // The formal answer now lives in the session; the page preview is retired.
    await noteSeat(id, provider, task, 'answered', '已把原文写入本会场次', null);
    kickPump();
    return true;
  }
  if (verdict.outcome === 'stale') {
    await markDispatch(id, provider, task, coords, {
      phase: 'stale',
      status: reply.status || 'done',
    });
    await noteSeat(id, provider, task, 'stale', verdict.error);
    return true;
  }
  if (verdict.outcome === 'session-paused') {
    // The pause/takeover already owns the seat status; do not overwrite it.
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
 * Only the driver's "same-origin SPA address change, this round's user message
 * not proven yet" answer is retried read-only, and only for a bounded time after
 * the click. Cross-origin `page-changed`, `task-unknown` (the page reloaded) and
 * every other unknown state still pause the seat for a human.
 */
function sameOriginNavigationPending(reply, intent) {
  if (!reply || reply.ok !== false || reply.status !== 'unknown') return false;
  if (reply.error !== 'page-changed') return false;
  if (!reply.detail || reply.detail.reason !== 'spa-navigation-unverified') return false;
  const since = Number.isFinite(intent && intent.at) ? intent.at : 0;
  return since > 0 && Date.now() - since <= NAVIGATION_RECOVERY_MS;
}

/**
 * After a restart (or a click that was observed but not verified) the only
 * safe action is a read. Never resend; a page that no longer proves this
 * task's user turn ends in a per-seat pause.
 */
async function reconcileDispatch(id, provider, config, task, intent, coords) {
  let reply;
  try {
    reply = await callDriver(id, provider, config, {
      type: 'arena.web.read',
      taskId: task.id,
    });
  } catch (error) {
    if (!(await canContinue(id, provider))) return;
    if (readTransportTimeout(error)) {
      // The page never answered the read call itself. One bounded front look is
      // read-only; after that the next tick reads again and nothing is re-sent.
      const borrow = await borrowSeatPageForRead(id, provider, config, task.id);
      if (!(await canContinue(id, provider))) return;
      if (borrow === 'shown') {
        await noteSeat(
          id,
          provider,
          task,
          'verifying',
          '读取核对超时，已把该原页短暂置前，下一轮只读重试；不会重发',
        );
        return;
      }
    }
    await pauseSeat(
      id,
      provider,
      task,
      '发送结果待确认',
      `${messageOf(error)}。为避免重复提交，本次只读不重发`,
    );
    return;
  }
  if (!(await canContinue(id, provider))) return;

  if (reply.ok && DONE_STATUSES.has(reply.status) && reply.text.trim()) {
    await acceptAnswer(id, provider, task, reply, coords);
    return;
  }

  if (reply.ok && reply.status === 'pending') {
    const preview = previewFromReply(reply, task.id);
    if (reply.detail.userTurnVerified === true) {
      await markDispatch(id, provider, task, coords, {
        phase: 'streaming',
        status: 'pending',
      });
      await noteSeat(
        id,
        provider,
        task,
        'streaming',
        '重启后核对到本轮用户消息，继续读取原页回答',
        preview,
      );
      return;
    }
    const recovery = reply.detail.userTurnVerified === false
      ? await readRecoveryState(id, provider, config, task, intent)
      : 'none';
    if (!(await canContinue(id, provider))) return;
    if (recovery === 'exhausted') {
      await pauseSeat(
        id,
        provider,
        task,
        '已点击但长时间未核对到本轮用户消息',
        '已做一次只读前台复核仍未确认；不会重发，请核对原页或人工补录',
        preview,
      );
      return;
    }
    await markDispatch(id, provider, task, coords, {
      phase: 'verifying',
      status: 'pending',
    });
    await noteSeat(
      id,
      provider,
      task,
      'verifying',
      recovery === 'shown'
        ? '已点击但久未核对到本轮用户消息，已把该原页短暂置前做一次只读复核；不会重发'
        : '已提交，但还没核对到本轮用户消息；只读核对，不会重发',
      preview,
    );
    return;
  }

  if (sameOriginNavigationPending(reply, intent)) {
    // The page already moved to its own conversation URL and the driver has
    // not matched this round's exact user message there yet. Keep the intent
    // in `verifying` and read again; never send again.
    // DeepSeek's new transcript only paints once the page is in front, so one
    // bounded foreground fallback per task helps this read-only check; the
    // next tick reads again and nothing is ever re-sent.
    if (RECONCILE_FOREGROUND_PROVIDERS.has(provider)) {
      await showSeatPageOnce(id, provider, config, task.id);
      if (!(await canContinue(id, provider))) return;
    }
    await noteSeat(
      id,
      provider,
      task,
      'verifying',
      '同源换到新对话地址，仍在只读核对本轮用户消息；不会重发',
      previewFromReply(reply, task.id),
    );
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

function pendingDetail(reply) {
  const reason = reply.detail && typeof reply.detail.reason === 'string' ? reply.detail.reason : '';
  return ({
    'awaiting-answer': '已发送，等待原页开始回答',
    'answer-empty': '已发送，等待原页正文出现',
    'answer-updating': '原页正文仍在变化',
    'completion-signal-missing': '已读到原页正文，等待生成结束',
  })[reason] || '';
}

/**
 * The one already-submitted pending shape that may spend the read lane's single
 * foreground look: this round's own user turn was verified, the driver read real
 * body text, its own stability clock (wall time persisted across reads) already
 * exceeds the threshold, and the only missing piece is the site's native
 * completion marker. A short stable title therefore keeps waiting instead of
 * being saved; only the page's own marker may finish the seat. The provider set
 * restricts this to the site that requires a live marker at all.
 */
function completionSignalStuck(reply, provider) {
  if (!COMPLETION_FOREGROUND_PROVIDERS.has(provider)) return false;
  const detail = (reply && reply.detail) || {};
  if (detail.reason !== 'completion-signal-missing') return false;
  if (detail.userTurnVerified === false) return false;
  if (!(Number.isFinite(detail.partialChars) && detail.partialChars > 0)) return false;
  return (
    Number.isFinite(detail.stableMs) && detail.stableMs >= COMPLETION_FOREGROUND_MIN_STABLE_MS
  );
}

/**
 * The readiness wait is read-only, but it can last ~38 s, so a discussion pause
 * or a stop/takeover must end it promptly instead of letting a late composer
 * become a send after the user already paused. Seat/run state is checked by
 * `canContinue`; the session pause is read live because `session` passed into
 * the pump is a snapshot from the start of the tick.
 */
async function canProbeSeat(id, provider) {
  if (!(await canContinue(id, provider))) return false;
  try {
    const session = await deps.getSession(id);
    return Boolean(session && !session.paused);
  } catch {
    return false;
  }
}

/**
 * Pre-dispatch readiness probe (G1/R06). Site seats keep checking their own
 * composer for a bounded ~38 s instead of 12 s, and use exactly one bounded
 * foreground look partway through because some pages finish painting only
 * while active. Only `selector-missing` / `selector-hidden` /
 * `document-not-ready` are "not yet" answers; a login or unauthorized page is
 * returned at once and pauses the seat as before. Nothing here fills, clicks
 * or sends, and the reply carries what actually happened so the terminal pause
 * text can state it.
 */
async function probeSeat(id, provider, config, taskId) {
  const startedAt = Date.now();
  const deadline = startedAt + PROBE_READY_DEADLINE_MS;
  let checks = 0;
  let foreground = 'none';
  let foregroundTried = false;
  let reply;

  for (;;) {
    if (checks > 0 && !(await canProbeSeat(id, provider))) break;
    reply = await callDriver(id, provider, config, { type: 'arena.web.probe', taskId });
    checks += 1;
    if (config.mode !== 'site' || !PROBE_RETRY_ERRORS.has(reply.error)) break;
    if (Date.now() >= deadline) break;

    if (!foregroundTried && checks >= PROBE_FOREGROUND_AFTER_CHECKS) {
      // One read-only look at this seat's own bound page. `brieflyShowSeatPage`
      // itself re-checks the run, seat, bound tab, exact origin and that the
      // workbench is still the active tab, so a user elsewhere keeps the front.
      foregroundTried = true;
      foreground = await brieflyShowSeatPage(
        id,
        provider,
        config,
        FOREGROUND_FALLBACK_WAIT_MS,
      );
      if (!(await canProbeSeat(id, provider))) break;
    }

    await sleep(
      PROBE_RETRY_DELAYS_MS[Math.min(checks - 1, PROBE_RETRY_DELAYS_MS.length - 1)],
    );
  }

  let sessionPaused = false;
  try {
    const session = await deps.getSession(id);
    sessionPaused = Boolean(session && session.paused);
  } catch {
    sessionPaused = true; // unreadable session: never turn a probe into a send
  }

  return {
    ...reply,
    readiness: {
      waitedMs: Math.max(0, Date.now() - startedAt),
      checks,
      foreground,
      sessionPaused,
    },
  };
}

/**
 * The driver's explicit "no click happened yet" answer. Only this exact shape
 * is retryable; a missing detail, any click, or a transport error is not.
 */
function preClickSendPending(reply) {
  if (!reply || reply.ok || reply.error !== 'send-pending') return false;
  const detail = reply.detail || {};
  return detail.phase === 'pre-click' && detail.clickAttempted === false;
}

/**
 * Persist a bounded pre-click retry. The deadline is measured from the first
 * attempt so the whole seat spends at most ~45 s waiting for a send control,
 * not 45 s per attempt. Pause/takeover are re-checked before every write.
 */
async function schedulePreClickRetry(id, provider, task, coords, reply, intent) {
  if (!(await canContinue(id, provider))) return;
  const now = Date.now();
  const firstAt = intent.preClickFirstAt || now;
  const deadline = intent.preClickDeadline || firstAt + PRE_CLICK_RETRY_DEADLINE_MS;
  const attempts = (intent.preClickAttempts || 0) + 1;
  const delay = PRE_CLICK_RETRY_DELAYS_MS[
    Math.min(attempts, PRE_CLICK_RETRY_DELAYS_MS.length - 1)
  ];
  const nextAt = Math.min(now + delay, deadline);
  const reason = (reply.detail && reply.detail.reason) || 'hidden';

  if (attempts >= PRE_CLICK_RETRY_MAX_ATTEMPTS || nextAt >= deadline) {
    await markDispatch(id, provider, task, coords, {
      phase: 'paused',
      status: reply.status || 'error',
      clickAttempted: false,
      preClickAttempts: attempts,
      preClickNextAt: 0,
      preClickDeadline: deadline,
      lastPreClickReason: reason,
    });
    const waited = Math.max(0, Math.round((now - firstAt) / 1000));
    await pauseSeat(
      id,
      provider,
      task,
      '发送前检查一直未通过',
      `等待约 ${waited} 秒后仍无法完成发送前检查（${reason}）；全程未点击，请人工处理`,
    );
    return;
  }

  await markDispatch(id, provider, task, coords, {
    phase: 'waiting-send',
    status: reply.status || 'error',
    clickAttempted: false,
    preClickAttempts: attempts,
    preClickNextAt: nextAt,
    preClickDeadline: deadline,
    lastPreClickReason: reason,
  });
  const waitSec = Math.max(1, Math.ceil((nextAt - now) / 1000));
  await noteSeat(
    id,
    provider,
    task,
    'dispatching',
    `发送前检查未通过（${reason}），约 ${waitSec} 秒后重试；尚未点击发送`,
  );
}

/** Shared reply handling for the first submit and every pre-click retry. */
async function handleSubmitReply(id, provider, task, coords, reply, intent) {
  if (!(await canContinue(id, provider))) return;

  if (preClickSendPending(reply)) {
    await schedulePreClickRetry(id, provider, task, coords, reply, intent);
    return;
  }

  if (!reply.ok) {
    const detail = reply.detail || {};
    const possiblySubmitted =
      detail.clickAttempted === true ||
      detail.possiblySubmitted === true ||
      reply.error === 'submit-unconfirmed';
    if (possiblySubmitted) {
      await markDispatch(id, provider, task, coords, {
        phase: 'verifying',
        status: reply.status || 'error',
        clickAttempted: true,
      });
      await noteSeat(
        id,
        provider,
        task,
        'verifying',
        `${reply.error || '提交未确认'}；已点击发送但没核对到本轮用户消息，只读复核，不会重发`,
        previewFromReply(reply, task.id),
      );
      return;
    }
    await markDispatch(id, provider, task, coords, {
      phase: 'paused',
      status: reply.status || 'error',
      clickAttempted: false,
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

  const preview = previewFromReply(reply, task.id);
  const userTurnVerified =
    reply.status === 'submitted' ||
    reply.detail.userTurnVerified === true ||
    (DONE_STATUSES.has(reply.status) && Boolean(reply.text.trim()));
  if (!userTurnVerified) {
    // The click was accepted by the page driver, but this round's user
    // message was not proven. Keep the intent read-only from here on.
    await markDispatch(id, provider, task, coords, {
      phase: 'verifying',
      status: reply.status || 'submitted',
      clickAttempted: true,
    });
    await noteSeat(
      id,
      provider,
      task,
      'verifying',
      '已点击发送，但还没核对到本轮用户消息；只读复核，不会重发',
      preview,
    );
    return;
  }
  await markDispatch(id, provider, task, coords, {
    phase: 'submitted',
    status: reply.status || 'submitted',
    clickAttempted: true,
  });
  if (DONE_STATUSES.has(reply.status) && reply.text.trim()) {
    await acceptAnswer(id, provider, task, reply, coords);
    return;
  }
  await noteSeat(
    id,
    provider,
    task,
    'submitted',
    reply.detail.draftReplaced === 'known-old-prompt'
      ? '已精确识别并替换站点恢复的上一轮提示，核对到本轮用户消息，等待完整回答'
      : '已核对本轮用户消息，等待完整回答',
    preview,
  );
}

/**
 * One submit call plus shared handling. `knownDraftDigests` is computed from
 * this provider's recent confirmed dispatches and only digests leave the
 * worker; the historical prompt text is never sent to the site.
 */
async function submitTaskPrompt(id, provider, config, task, prompt, coords, optionOverrides) {
  if (!(await canContinue(id, provider))) return;
  let reply;
  try {
    const command = {
      type: 'arena.web.submit',
      taskId: task.id,
      prompt,
    };
    const digests = await knownDraftDigests(provider);
    if (digests.length > 0) command.knownDraftDigests = digests;
    reply = await callDriver(id, provider, config, command, optionOverrides);
  } catch (error) {
    if (!(await canContinue(id, provider))) return;
    await markDispatch(id, provider, task, coords, { phase: 'verifying', status: '' });
    await noteSeat(
      id,
      provider,
      task,
      'verifying',
      `${messageOf(error)}；为避免重复提交，只会读核对，不会重发`,
    );
    return;
  }

  let intent;
  try {
    const { runs } = await loadStore();
    intent = (runs[id] && runs[id].dispatch && runs[id].dispatch[task.id]) || null;
  } catch {
    intent = null;
  }
  if (!intent) {
    intent = {
      preClickAttempts: 0,
      preClickFirstAt: Date.now(),
      preClickNextAt: 0,
      preClickDeadline: Date.now() + PRE_CLICK_RETRY_DEADLINE_MS,
    };
  }
  await handleSubmitReply(id, provider, task, coords, reply, intent);
}

async function pumpSeat(id, session, provider, resolved) {
  const task = pendingTaskForProvider(session, provider);

  if (!task) {
    const store = await loadStore();
    const run = store.runs[id];
    const previous = run && run.seats[provider];
    if (previous && ACTIVE_SEAT_STATUSES.has(previous.status)) {
      await noteSeat(id, provider, null, 'idle', '', null);
    }
    return;
  }

  const store = await loadStore();
  const run = store.runs[id];
  if (!run || !run.enabled || run.completed) return;
  const seatState = run.seats[provider] || null;

  // Takeover is persistent for the rest of the run: never touch this seat.
  if (seatState && seatState.takenOver) return;

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

  const config = resolved && resolved.config;
  if (!config) {
    const problem = (resolved && resolved.problem) || '该席位没有可用的网页配置';
    await noteSeat(id, provider, task, 'idle', `${problem}，可人工处理`);
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
      probe = await probeSeat(id, provider, config, task.id);
    } catch (error) {
      if (!(await canContinue(id, provider))) return;
      await pauseSeat(id, provider, task, '页面不可用', messageOf(error));
      return;
    }
    if (!(await canContinue(id, provider))) return;
    // A discussion pause during the longer readiness wait ends this seat's
    // attempt without a dispatch intent; the pause flow owns the seat status.
    if (probe.readiness && probe.readiness.sessionPaused) return;
    if (!probe.ok || !READY_STATUSES.has(probe.status)) {
      const facts = probe.readiness || {};
      const waitedSec = Math.round((facts.waitedMs || 0) / 1000);
      let frontNote = '';
      if (facts.foreground === 'shown') frontNote = '（含一次前台复核）';
      else if (facts.foreground === 'respected') frontNote = '（前台复核因你不在工作台而跳过）';
      const checked =
        waitedSec >= 2
          ? `等待约 ${waitedSec} 秒、${facts.checks || 1} 次只读检查${frontNote}后`
          : '只读检查后';
      await pauseSeat(
        id,
        provider,
        task,
        '输入框仍未就绪',
        `${checked}仍不可用（${probe.error || `驱动状态 ${probe.status || '未知'}`}）；未填入、未发送`,
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
        if ((seat && seat.paused) || (seat && seat.takenOver)) return;
        if (LOCAL_SET.has(provider)) {
          const live = store.configs[provider];
          if (
            !live ||
            live.origin !== config.origin ||
            JSON.stringify(live.selectors) !== JSON.stringify(config.selectors)
          ) {
            // Configuration changed between probe and submit.
            return;
          }
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
          clickAttempted: false,
          preClickAttempts: 0,
          preClickFirstAt: Date.now(),
          preClickNextAt: 0,
          preClickDeadline: Date.now() + PRE_CLICK_RETRY_DEADLINE_MS,
          lastPreClickReason: '',
        };
        draft.seats[provider] = {
          status: 'dispatching',
          taskId: task.id,
          detail: '已记录发送意图，正在提交',
          paused: false,
          takenOver: false,
          preview: null,
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

    await submitTaskPrompt(id, provider, config, task, prompt, coords);
    return;
  }

  if (intent.phase === 'waiting-send') {
    // The driver explicitly reported no click, so a bounded retry is safe.
    // A worker restart makes the wait unverifiable: hand it to a human.
    if (intent.bootId !== bootId) {
      await markDispatch(id, provider, task, coords, {
        phase: 'paused',
        status: 'waiting-send',
      });
      await pauseSeat(
        id,
        provider,
        task,
        '发送控件等待被中断',
        '后台进程已重启，无法确认这次等待；请人工核对原页。为避免重复提交，不会自动重发',
      );
      return;
    }
    const now = Date.now();
    const deadline = intent.preClickDeadline || 0;
    const attempts = intent.preClickAttempts || 0;
    if (
      !deadline ||
      now >= deadline ||
      attempts >= PRE_CLICK_RETRY_MAX_ATTEMPTS
    ) {
      await markDispatch(id, provider, task, coords, {
        phase: 'paused',
        status: 'waiting-send',
        preClickNextAt: 0,
      });
      await pauseSeat(
        id,
        provider,
        task,
        '发送前检查一直未通过',
        `已等待约 ${Math.max(0, Math.round((now - (intent.preClickFirstAt || now)) / 1000))} 秒（${intent.lastPreClickReason || 'hidden'}）；全程未点击，请人工处理`,
      );
      return;
    }
    if (now < (intent.preClickNextAt || 0)) {
      const remaining = Math.max(1, Math.ceil((deadline - now) / 1000));
      await noteSeat(
        id,
        provider,
        task,
        'dispatching',
        `发送前检查未通过，等待重试；剩余约 ${remaining} 秒，尚未点击发送`,
      );
      return;
    }

    const prompt = stagePrompt(task, coords.stage);
    if (!prompt) {
      await pauseSeat(id, provider, task, '任务缺少提示正文', '无法发送空提示');
      return;
    }
    if (!(await canContinue(id, provider))) return;

    // Gemini only paints its send control once the page has been in front.
    // The driver proved that no click happened yet, so one bounded foreground
    // fallback per task is safe here; it never sends anything by itself.
    if (PRE_CLICK_FOREGROUND_PROVIDERS.has(provider)) {
      await showSeatPageOnce(id, provider, config, task.id);
      if (!(await canContinue(id, provider))) return;
    }

    const remaining = Math.max(300, deadline - now);
    const configuredSend =
      (config.options && config.options.sendEnableMs) || 4000;
    await noteSeat(
      id,
      provider,
      task,
      'dispatching',
      `第 ${attempts + 1} 次等待发送控件（剩余约 ${Math.ceil(remaining / 1000)} 秒）；尚未点击发送`,
    );
    await submitTaskPrompt(id, provider, config, task, prompt, coords, {
      sendEnableMs: Math.min(configuredSend, remaining),
    });
    return;
  }

  if (intent.phase === 'dispatching' || intent.phase === 'verifying') {
    // A dispatch intent without a confirmed submit means "ambiguous". Read
    // only; never call submit again.
    await noteSeat(id, provider, task, 'verifying', '只读核对原页，不会重发');
    await reconcileDispatch(id, provider, config, task, intent, coords);
    return;
  }

  if (intent.phase === 'submitted' || intent.phase === 'streaming') {
    let reply;
    try {
      reply = await callDriver(id, provider, config, {
        type: 'arena.web.read',
        taskId: task.id,
      });
    } catch (error) {
      if (!(await canContinue(id, provider))) return;
      if (readTransportTimeout(error)) {
        // Confirmed transport timeout of the read lane: one bounded front look,
        // then the next tick reads again. The dispatch intent stays
        // submitted/streaming, so no submit path can run from here.
        const borrow = await borrowSeatPageForRead(id, provider, config, task.id);
        if (!(await canContinue(id, provider))) return;
        if (borrow === 'shown') {
          await noteSeat(
            id,
            provider,
            task,
            intent.phase === 'streaming' ? 'streaming' : 'submitted',
            '读取原页超时，已把该原页短暂置前，下一轮只读重试；不会重发',
          );
          return;
        }
      }
      await pauseSeat(id, provider, task, '读取回答失败', messageOf(error));
      return;
    }
    if (!(await canContinue(id, provider))) return;
    if (reply.ok && DONE_STATUSES.has(reply.status) && reply.text.trim()) {
      await acceptAnswer(id, provider, task, reply, coords);
      return;
    }
    if (reply.ok && reply.status === 'pending') {
      const preview = previewFromReply(reply, task.id);
      if (reply.detail.userTurnVerified === false) {
        await markDispatch(id, provider, task, coords, {
          phase: 'verifying',
          status: 'pending',
        });
        await noteSeat(
          id,
          provider,
          task,
          'verifying',
          '还没核对到本轮用户消息；只读核对，不会重发',
          preview,
        );
        return;
      }
      if (reply.detail.timedOut === true) {
        await pauseSeat(
          id,
          provider,
          task,
          '回答仍未确认完成',
          `${pendingDetail(reply)}；页面片段只作预览，未写入讨论`,
          preview,
        );
        return;
      }
      if (completionSignalStuck(reply, provider)) {
        // Verified round, real body text, stable past the threshold, yet the
        // site's own finished marker is still absent. One bounded, read-only
        // front look can let that tab paint the marker; the intent stays in the
        // already-submitted read lane, so nothing here can ever re-send. The
        // claim is the same single per-task allowance as the other read cases.
        const borrow = await borrowSeatPageForRead(id, provider, config, task.id);
        if (!(await canContinue(id, provider))) return;
        if (borrow === 'shown') {
          await markDispatch(id, provider, task, coords, {
            phase: 'streaming',
            status: 'pending',
          });
          await noteSeat(
            id,
            provider,
            task,
            'streaming',
            `${pendingDetail(reply)}；已把该原页短暂置前做一次只读核对，下一轮继续只读读取；不会重发`,
            preview,
          );
          return;
        }
      }
      await markDispatch(id, provider, task, coords, {
        phase: 'streaming',
        status: 'pending',
      });
      await noteSeat(
        id,
        provider,
        task,
        'streaming',
        pendingDetail(reply),
        preview,
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

const seatPumps = new Set();

function launchSeatPump(id, session, provider, config) {
  const key = `${id}:${provider}`;
  if (seatPumps.has(key)) return;
  seatPumps.add(key);
  void (async () => {
    try {
      await pumpSeat(id, session, provider, config);
    } catch (error) {
      const task = pendingTaskForProvider(session, provider);
      await pauseSeat(id, provider, task, '该席自动化中断', messageOf(error)).catch(() => {});
    } finally {
      seatPumps.delete(key);
    }
  })();
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
      if (!task) continue;
      const seat = run.seats[provider];
      if (seat && (seat.paused || seat.takenOver)) continue;
      await noteSeat(id, provider, task, 'session-paused', '讨论已暂停，暂停派发');
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
        if (seat && ACTIVE_SEAT_STATUSES.has(seat.status)) {
          draft.seats[provider] = {
            ...seat,
            status: 'idle',
            taskId: '',
            detail: '',
            paused: false,
            preview: null,
            at: Date.now(),
          };
        }
      }
    });
    return;
  }

  for (const provider of providers) {
    launchSeatPump(id, session, provider, resolveConfig(provider, store.configs[provider]));
  }
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
  const provider = requireLocalAutomationProvider(message.provider);
  if (message.config === null || message.config === undefined) {
    await withStore((store) => {
      delete store.configs[provider];
      for (const run of Object.values(store.runs)) {
        if (!run.enabled) continue;
        delete run.tabs[provider];
        const seat = run.seats[provider];
        if (seat && ACTIVE_SEAT_STATUSES.has(seat.status)) {
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
      if (seat && ACTIVE_SEAT_STATUSES.has(seat.status)) {
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
  for (const provider of LOCAL_AUTOMATION_PROVIDER_IDS) {
    if (store.configs[provider]) {
      configs[provider] = publicConfig(provider, store.configs[provider]);
    }
  }
  const runs = {};
  for (const [id, run] of Object.entries(store.runs)) {
    runs[id] = publicRun(run);
  }
  // Public seats are built in; the workspace can show their capability without
  // exposing (or accepting) an editable connection config for them.
  const sites = {};
  for (const provider of AUTOMATION_PROVIDERS) {
    if (!isWebSiteProvider(provider)) continue;
    const config = webSiteConfig(provider);
    sites[provider] = config
      ? {
        origin: config.origin,
        label: config.label,
        pattern: permissionPattern(config.origin),
        ready: true,
      }
      : { origin: '', label: '', pattern: '', ready: false, problem: webSiteConfigProblem(provider) };
  }
  return { configs, runs, sites, providers: AUTOMATION_PROVIDERS.slice() };
}

function requireWindowId(value, sender) {
  const senderWindow = Number.isInteger(sender && sender.tab && sender.tab.windowId)
    ? sender.tab.windowId
    : null;
  if (value === undefined || value === null) return senderWindow;
  if (!Number.isInteger(value) || value < 0) {
    throw new Error('windowId 必须是有效的窗口编号');
  }
  if (senderWindow !== null && value !== senderWindow) {
    throw new Error('windowId 与请求来自的工作台窗口不一致');
  }
  return value;
}

/**
 * Report (never request) the optional host permission for each public seat.
 * A missing permission pauses only that seat; other seats keep running.
 */
async function preflightSiteSeats(id, seats, session) {
  if (!chrome.permissions || !chrome.permissions.contains) return;
  for (const provider of seats) {
    if (!isWebSiteProvider(provider)) continue;
    const config = webSiteConfig(provider);
    if (!config) continue;
    const pattern = permissionPattern(config.origin);
    let granted = false;
    try {
      granted = await chrome.permissions.contains({ origins: [pattern] });
    } catch {
      continue;
    }
    if (granted) continue;
    const pending = pendingTaskForProvider(session, provider);
    await updateRun(id, (run) => {
      const seat = run.seats[provider] || {};
      if (seat.takenOver) return;
      run.seats[provider] = {
        ...seat,
        status: 'paused',
        taskId: pending ? pending.id : (typeof seat.taskId === 'string' ? seat.taskId : ''),
        paused: true,
        takenOver: false,
        detail: `尚未授予 ${pattern} 的访问权限：请点击“开始自动化”时允许该站点，然后重新开始。该席不会拖住其他席位。`,
        at: Date.now(),
      };
    });
  }
}

async function handleStart(message, sender) {
  const id = requireSessionId(message.id);
  const windowId = requireWindowId(message.windowId, sender);
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
    throw new Error('本场没有可自动驱动的席位，无法启用网页自动化');
  }

  const store = await loadStore();
  const siteSeats = seats.filter((provider) => isWebSiteProvider(provider));
  const localSeats = seats.filter((provider) => LOCAL_SET.has(provider));
  if (localSeats.length + siteSeats.length === 0) {
    throw new Error('本场没有可自动驱动的席位，无法启用网页自动化');
  }
  if (
    siteSeats.length === 0 &&
    !localSeats.some((provider) => store.configs[provider])
  ) {
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
    if (Number.isInteger(windowId)) run.windowId = windowId;
    if (Number.isInteger(sender?.tab?.id) && sender.tab.windowId === windowId) {
      run.openerTabId = sender.tab.id;
    }
    for (const provider of seats) {
      const seat = run.seats[provider];
      if (seat && seat.paused && !seat.takenOver) {
        // Explicit start is the user's acknowledgement. It clears the pause but
        // keeps the dispatch intent, so a previously ambiguous submit is still
        // only read, never resent. A takeover stays stopped on purpose.
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

  await preflightSiteSeats(id, siteSeats, session);  ensureAlarm();
  kickPump();
  const latest = await loadStore();
  return { run: latest.runs[id] ? publicRun(latest.runs[id]) : run ? publicRun(run) : null };
}

async function handleStop(message) {
  const id = requireSessionId(message.id);
  const run = await updateRun(id, (draft) => {
    draft.enabled = false;
    draft.stoppedAt = Date.now();
    draft.lastError = '';
    // Keep the original conversation reachable while the run is disabled.
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

/**
 * Hand exactly one seat to the user for the rest of this run. The dispatch
 * record is kept (phase `paused`) so nothing can resend; the last page preview
 * stays visible but remains a preview and is never written as an answer.
 */
async function handleTakeover(message) {
  const id = requireSessionId(message.id);
  const provider = requireAutomationProvider(message.provider);
  const taskId = typeof message.taskId === 'string' ? message.taskId : '';
  if (taskId && !DRIVER_TASK_ID_RE.test(taskId)) {
    throw new Error('taskId 格式无效');
  }

  const updated = await serializeWrite(async () => {
    const session = await deps.getSession(id);
    const task = session && pendingTaskForProvider(session, provider);
    if (!task || (taskId && task.id !== taskId)) {
      throw new Error('这一席的任务已变更，请刷新后核对');
    }
    return updateRun(id, (draft) => {
      const seat = draft.seats[provider] || {};
      draft.seats[provider] = {
        ...seat,
        status: 'paused',
        taskId: task.id,
        paused: true,
        takenOver: true,
        detail: '已手动接管。请到原页核对，完整回答可以粘贴回工作台。',
        preview: resolveSeatPreview(seat.preview, task.id),
        at: Date.now(),
      };
      const dispatch = draft.dispatch[task.id];
      if (dispatch?.provider === provider) {
        draft.dispatch[task.id] = { ...dispatch, phase: 'paused', status: 'taken-over', at: Date.now() };
      }
    });
  });
  if (!updated) throw new Error('该场次还没有自动记录');
  return { run: publicRun(updated) };
}

const MESSAGE_TYPES = new Set([
  'automation.config',
  'automation.info',
  'automation.start',
  'automation.stop',
  'automation.takeover',
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
        return handleStart(message, sender);
      case 'automation.stop':
        return handleStop(message);
      case 'automation.takeover':
        return handleTakeover(message);
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
    takeover: handleTakeover,
    bootId,
    providers: AUTOMATION_PROVIDERS.slice(),
  };
}
