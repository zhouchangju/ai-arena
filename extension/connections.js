/* AI Arena — 网页连接设置（G1 / G4 / R09）
 *
 * 只处理两席本机网页的连接配置：校验地址与选择器、在用户点击时请求该地址的
 * 浏览器权限、把配置交给扩展后台，并读取后台记录的最近运行状态。
 *
 * 边界：
 *   - 只接受 127.0.0.1 / localhost 的 http 地址；不连接其他站点。
 *   - 不在加载时预填任何地址；测试页配置只由用户点击按钮填入。
 *   - 权限请求必须在点击手势中发起，因此 request() 在 await 之前同步调用。
 *   - 本文件只通过 chrome.runtime 消息读写，不直接操作目标网页或存储后台数据。
 */

const SEATS = [
  { key: 'a', provider: 'local-a', label: '本机 A' },
  { key: 'b', provider: 'local-b', label: '本机 B' },
];

const FIELD_KEYS = ['url', 'input', 'send', 'user', 'answer', 'stop', 'done'];
const REQUIRED_KEYS = ['input', 'send', 'user', 'answer'];
const FIELD_LABELS = {
  url: '网页地址',
  input: '输入框',
  send: '发送按钮',
  user: '用户消息',
  answer: '回答消息',
  stop: '停止按钮',
  done: '完成标记',
};

const SAMPLE_BASE = 'http://127.0.0.1:8877/web-driver-fixture.html';
const SAMPLE_SELECTORS = {
  input: '#composer',
  send: '#send',
  user: '#log .turn.user .msg',
  answer: '#log .turn.answer .msg',
  stop: '#stop',
  done: '#done',
};
const SAMPLE = {
  a: { url: `${SAMPLE_BASE}?seat=A`, ...SAMPLE_SELECTORS },
  b: { url: `${SAMPLE_BASE}?seat=B`, ...SAMPLE_SELECTORS },
};

const DRAFT_KEY = 'aiArena.connections.drafts.v1';
const CALL_TIMEOUT_MS = 20000;
const MAX_SELECTOR_CHARS = 400;
const LOCAL_HOSTS = new Set(['127.0.0.1', 'localhost']);

const STATUS_LABELS = {
  done: '完成',
  completed: '完成',
  complete: '完成',
  finished: '完成',
  answered: '已作答',
  ok: '完成',
  success: '完成',
  ready: '就绪',
  submitted: '已提交',
  dispatching: '发送中',
  pending: '进行中',
  running: '进行中',
  streaming: '进行中',
  generating: '进行中',
  queued: '排队中',
  waiting: '等待中',
  probing: '检查中',
  idle: '待开始',
  paused: '已暂停',
  detached: '已停止',
  error: '失败',
  failed: '失败',
  stopped: '已停止',
  timeout: '超时',
  unknown: '状态未知',
};

const toastEl = document.getElementById('toast');
const backendNoticeEl = document.getElementById('backend-notice');
const backendNoticeTextEl = document.getElementById('backend-notice-text');
const backendRetryEl = document.getElementById('backend-retry');
const fillSampleEl = document.getElementById('fill-sample');

const refs = new Map();
for (const seat of SEATS) {
  const byId = (suffix) => document.getElementById(`seat-${seat.key}-${suffix}`);
  const fields = {};
  for (const key of FIELD_KEYS) fields[key] = byId(key);
  refs.set(seat.key, {
    seat,
    fields,
    status: byId('status'),
    feedback: byId('feedback'),
    run: byId('run'),
    origin: byId('origin'),
    save: byId('save'),
    touched: false,
    saving: false,
  });
}

const state = {
  savedConfigs: new Map(),
  runs: [],
  drafts: {},
  initialized: false,
  toastTimer: null,
};

/* ------------------------------ 后台通信 ------------------------------ */

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
      reject(new Error('未检测到扩展后台。请从 Chrome 的扩展页打开本页。'));
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
        finish(reject, new Error(typeof reply.error === 'string' && reply.error
          ? reply.error
          : '操作失败，后台未提供原因。'));
        return;
      }
      finish(resolve, reply);
    };

    timer = setTimeout(() => {
      finish(reject, new Error('扩展后台在 20 秒内没有响应。'));
    }, CALL_TIMEOUT_MS);

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

/* ------------------------------ 小工具 ------------------------------ */

function friendlyError(error, prefix = '') {
  const message = error && error.message ? error.message : String(error || '未知错误');
  return prefix ? `${prefix}：${message}` : message;
}

function permissionErrorMessage(error) {
  const message = error && error.message ? error.message : String(error || '未知错误');
  if (/Only permissions specified in the manifest/i.test(message)) {
    return '扩展尚未声明可选的网页权限（optional_host_permissions）。请更新扩展后重试。';
  }
  if (/must be called during a user gesture/i.test(message)) {
    return '浏览器要求由点击直接触发权限请求，请重新点击「保存本席」。';
  }
  return friendlyError(error, '无法请求网页权限');
}

function oneLine(text, limit = 80) {
  const value = String(text || '').replace(/\s+/g, ' ').trim();
  return value.length > limit ? `${value.slice(0, limit)}…` : value;
}

function toast(message, kind = 'info') {
  if (!toastEl) return;
  toastEl.textContent = String(message || '');
  toastEl.dataset.kind = kind;
  toastEl.hidden = false;
  if (state.toastTimer) clearTimeout(state.toastTimer);
  state.toastTimer = setTimeout(() => {
    toastEl.hidden = true;
  }, 3600);
}

function blankSnapshot() {
  const snapshot = {};
  for (const key of FIELD_KEYS) snapshot[key] = '';
  return snapshot;
}

function snapshotFrom(ui) {
  const snapshot = blankSnapshot();
  for (const key of FIELD_KEYS) snapshot[key] = ui.fields[key].value.trim();
  return snapshot;
}

function normalizeSnapshot(raw) {
  const snapshot = blankSnapshot();
  if (!raw || typeof raw !== 'object') return snapshot;
  for (const key of FIELD_KEYS) {
    if (typeof raw[key] === 'string') snapshot[key] = raw[key].trim();
  }
  return snapshot;
}

function sameSnapshot(a, b) {
  return FIELD_KEYS.every((key) => (a[key] || '') === (b[key] || ''));
}

function applySnapshot(ui, snapshot) {
  for (const key of FIELD_KEYS) {
    ui.fields[key].value = snapshot[key] || '';
  }
}

function isValidSelector(css) {
  try {
    document.createDocumentFragment().querySelector(css);
    return true;
  } catch {
    return false;
  }
}

/* ------------------------------ 地址校验 ------------------------------ */

/**
 * 只接受本机 http 页面：
 *   http://127.0.0.1[:端口]/...  或  http://localhost[:端口]/...
 * 权限匹配模式有意不含端口（Chrome 的 match pattern 规则如此），
 * 但界面始终显示带端口的实际来源。
 */
function parseLocalUrl(raw) {
  const text = String(raw || '').trim();
  if (!text) return { error: '请填写网页地址。', field: 'url' };
  if (text.length > 2048) return { error: '网页地址过长。', field: 'url' };

  let url;
  try {
    url = new URL(text);
  } catch {
    return { error: '网页地址格式不正确，应形如 http://127.0.0.1:8877/。', field: 'url' };
  }

  if (url.protocol !== 'http:') {
    return { error: '只支持 http:// 开头的本机地址。', field: 'url' };
  }

  const host = url.hostname.toLowerCase();
  if (!LOCAL_HOSTS.has(host)) {
    return { error: '只允许 127.0.0.1 或 localhost：请填写你本人控制的网页。', field: 'url' };
  }

  if (url.username || url.password) {
    return { error: '地址里不能包含用户名或密码。', field: 'url' };
  }

  url.hash = '';

  return {
    url: url.href,
    origin: url.origin,
    pattern: `http://${host}/*`,
    host,
  };
}

function validateSeat(ui) {
  const snapshot = snapshotFrom(ui);
  const parsed = parseLocalUrl(snapshot.url);
  if (parsed.error) return parsed;

  const selectors = {};
  for (const key of REQUIRED_KEYS) {
    const css = snapshot[key];
    if (!css) return { error: `请填写「${FIELD_LABELS[key]}」选择器。`, field: key };
    if (css.length > MAX_SELECTOR_CHARS) {
      return { error: `「${FIELD_LABELS[key]}」选择器太长（最多 ${MAX_SELECTOR_CHARS} 个字符）。`, field: key };
    }
    if (!isValidSelector(css)) {
      return { error: `「${FIELD_LABELS[key]}」不是有效的 CSS 选择器。`, field: key };
    }
    selectors[key] = css;
  }

  for (const key of ['stop', 'done']) {
    const css = snapshot[key];
    if (!css) continue;
    if (css.length > MAX_SELECTOR_CHARS) {
      return { error: `「${FIELD_LABELS[key]}」选择器太长（最多 ${MAX_SELECTOR_CHARS} 个字符）。`, field: key };
    }
    if (!isValidSelector(css)) {
      return { error: `「${FIELD_LABELS[key]}」不是有效的 CSS 选择器。`, field: key };
    }
    selectors[key] = css;
  }

  if (selectors.user === selectors.answer) {
    return { error: '用户消息与回答消息必须使用不同的选择器。', field: 'answer' };
  }

  return {
    url: parsed.url,
    origin: parsed.origin,
    pattern: parsed.pattern,
    selectors,
    snapshot: { ...snapshot, url: parsed.url },
  };
}

/* ------------------------------ 网页权限 ------------------------------ */

function permissionsAvailable() {
  try {
    return typeof chrome !== 'undefined'
      && !!chrome.permissions
      && typeof chrome.permissions.request === 'function';
  } catch {
    return false;
  }
}

/**
 * 必须在点击处理函数内同步调用：Chrome 只接受由用户手势触发的权限请求。
 * Promise 构造器同步执行 chrome.permissions.request，因此即使外层随后 await，
 * 手势仍然有效。
 */
function requestOriginPermission(pattern) {
  return new Promise((resolve, reject) => {
    if (!permissionsAvailable()) {
      reject(new Error('当前环境不能请求网页权限。请从 Chrome 的扩展页打开本页。'));
      return;
    }
    try {
      chrome.permissions.request({ origins: [pattern] }, (granted) => {
        const lastError = chrome.runtime && chrome.runtime.lastError;
        if (lastError) {
          reject(new Error(lastError.message || '浏览器没有响应权限请求。'));
          return;
        }
        resolve(Boolean(granted));
      });
    } catch (error) {
      reject(error);
    }
  });
}

/* ------------------------------ 配置读取 ------------------------------ */

function normalizeProviderId(value) {
  const id = String(value || '').trim().toLowerCase();
  if (id === 'a' || id === 'local-a' || id === 'local a') return 'local-a';
  if (id === 'b' || id === 'local-b' || id === 'local b') return 'local-b';
  return id;
}

function normalizeConfigs(raw) {
  const configs = new Map();

  const add = (value, key) => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return;
    const provider = normalizeProviderId(value.provider || value.id || value.seat || key);
    if (!provider) return;
    const config = value.config && typeof value.config === 'object' ? value.config : value;
    const selectors = config.selectors && typeof config.selectors === 'object' ? config.selectors : {};
    const snapshot = blankSnapshot();
    if (typeof config.url === 'string') snapshot.url = config.url.trim();
    for (const field of FIELD_KEYS) {
      if (field !== 'url' && typeof selectors[field] === 'string') {
        snapshot[field] = selectors[field].trim();
      }
    }
    configs.set(provider, snapshot);
  };

  if (Array.isArray(raw)) {
    raw.forEach((value) => add(value));
  } else if (raw && typeof raw === 'object') {
    for (const [key, value] of Object.entries(raw)) add(value, key);
  }

  return configs;
}

function toMillis(value) {
  if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
    return value < 1e11 ? value * 1000 : value;
  }
  if (typeof value === 'string' && value.trim()) {
    const numeric = Number(value);
    if (Number.isFinite(numeric) && numeric > 0) {
      return numeric < 1e11 ? numeric * 1000 : numeric;
    }
    const parsed = Date.parse(value);
    if (!Number.isNaN(parsed)) return parsed;
  }
  return 0;
}

function normalizeRuns(raw) {
  const runs = [];
  const automated = new Set(['local-a', 'local-b']);

  // 后台的 runs 以场次 id 为键，每个席位的过程状态在 run.seats[provider]。
  const addSeat = (provider, seat, run) => {
    const id = normalizeProviderId(provider);
    if (!automated.has(id)) return;

    let status = typeof seat.status === 'string' ? seat.status.trim().toLowerCase() : '';
    if (seat.paused === true && (!status || status === 'idle')) status = 'paused';

    let note = typeof seat.detail === 'string' ? seat.detail.trim() : '';
    if (!note && typeof run.lastError === 'string') {
      note = (status === 'error' || status === 'unknown') ? run.lastError.trim() : '';
    }

    // 从未真正开始的场次没有可展示的运行证据。
    if ((!status || status === 'idle') && !note) return;

    const at = toMillis(seat.at)
      || toMillis(run.updatedAt)
      || toMillis(run.stoppedAt)
      || toMillis(run.startedAt);

    runs.push({ provider: id, status, note, at });
  };

  // 兼容更扁平的记录：{provider, status, at, error|message}。
  const addFlat = (value, key) => {
    const provider = normalizeProviderId(
      value.provider || value.providerId || value.seat || value.id || key,
    );
    if (!automated.has(provider)) return;

    let status = '';
    for (const candidate of [value.status, value.state, value.result]) {
      if (typeof candidate === 'string' && candidate.trim()) {
        status = candidate.trim().toLowerCase();
        break;
      }
    }
    if (!status && value.ok === false) status = 'error';
    if (!status && value.ok === true) status = 'done';

    let note = '';
    for (const candidate of [value.error, value.message, value.detail, value.note]) {
      if (typeof candidate === 'string' && candidate.trim()) {
        note = candidate.trim();
        break;
      }
    }

    const at = toMillis(value.at)
      || toMillis(value.ts)
      || toMillis(value.time)
      || toMillis(value.updatedAt)
      || toMillis(value.finishedAt)
      || toMillis(value.startedAt);

    runs.push({ provider, status, note, at });
  };

  const visit = (value, key) => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return;
    if (value.seats && typeof value.seats === 'object' && !Array.isArray(value.seats)) {
      for (const [provider, seat] of Object.entries(value.seats)) {
        if (seat && typeof seat === 'object' && !Array.isArray(seat)) {
          addSeat(provider, seat, value);
        }
      }
      return;
    }
    addFlat(value, key);
  };

  if (Array.isArray(raw)) {
    raw.forEach((value) => visit(value));
  } else if (raw && typeof raw === 'object') {
    for (const [key, value] of Object.entries(raw)) visit(value, key);
  }

  return runs;
}

function latestRun(provider) {
  let latest = null;
  for (const run of state.runs) {
    if (run.provider !== provider) continue;
    if (!latest) {
      latest = run;
      continue;
    }
    if ((run.at || 0) >= (latest.at || 0)) latest = run;
  }
  return latest;
}

function formatWhen(at) {
  if (!at) return '';
  const date = new Date(at);
  if (Number.isNaN(date.getTime())) return '';
  return new Intl.DateTimeFormat('zh-CN', {
    month: 'numeric',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(date);
}

function runLabel(status) {
  if (!status) return '状态未知';
  return STATUS_LABELS[status] || oneLine(status, 24);
}

/* ------------------------------ 界面更新 ------------------------------ */

function setFeedback(ui, text, kind = '') {
  ui.feedback.textContent = text ? String(text) : '';
  if (kind) ui.feedback.dataset.kind = kind;
  else delete ui.feedback.dataset.kind;
}

function markInvalid(ui, field) {
  const input = ui.fields[field];
  if (!input) return;
  input.setAttribute('aria-invalid', 'true');
}

function clearFieldInvalid(ui, field) {
  const input = ui.fields[field];
  if (input) input.removeAttribute('aria-invalid');
}

function clearInvalid(ui) {
  for (const key of FIELD_KEYS) clearFieldInvalid(ui, key);
}

function updateOrigin(ui) {
  const raw = ui.fields.url.value.trim();
  if (!raw) {
    ui.origin.hidden = true;
    ui.origin.textContent = '';
    delete ui.origin.dataset.state;
    return;
  }

  const parsed = parseLocalUrl(raw);
  ui.origin.hidden = false;
  if (parsed.error) {
    ui.origin.dataset.state = 'warn';
    ui.origin.textContent = `还不能保存：${parsed.error}`;
    return;
  }

  delete ui.origin.dataset.state;
  ui.origin.textContent = `实际来源 ${parsed.origin} · 权限范围 ${parsed.pattern}（不含端口）`;
}

function refreshStatus(seat) {
  const ui = refs.get(seat.key);
  const current = snapshotFrom(ui);
  const saved = state.savedConfigs.get(seat.provider);
  const hasAny = FIELD_KEYS.some((key) => current[key]);

  let status = 'empty';
  let label = '未配置';
  if (saved && sameSnapshot(saved, current)) {
    status = 'saved';
    label = '已保存';
  } else if (saved) {
    status = 'dirty';
    label = '有修改';
  } else if (hasAny) {
    status = 'draft';
    label = '未保存';
  }

  ui.status.dataset.state = status;
  ui.status.textContent = label;
}

function renderRun(ui) {
  const run = latestRun(ui.seat.provider);
  if (!run) {
    ui.run.textContent = '还没有运行记录。';
    return;
  }

  const when = formatWhen(run.at);
  const label = runLabel(run.status);
  const note = run.note ? ` · ${oneLine(run.note, 64)}` : '';
  ui.run.textContent = `最近运行：${when ? `${when} · ` : ''}${label}${note}`;
}

function showBackendNotice(detail) {
  if (!backendNoticeEl) return;
  backendNoticeEl.hidden = false;
  if (backendNoticeTextEl) {
    const note = detail ? `原因：${oneLine(detail, 120)}。` : '';
    backendNoticeTextEl.textContent = `${note}你仍可以先填写表单，点击「保存本席」时会再次尝试。若持续失败，请重新加载扩展后再打开本页。`;
  }
}

function hideBackendNotice() {
  if (backendNoticeEl) backendNoticeEl.hidden = true;
}

/* ------------------------------ 草稿 ------------------------------ */

function readDrafts() {
  try {
    const raw = JSON.parse(localStorage.getItem(DRAFT_KEY) || '{}');
    return raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  } catch {
    return {};
  }
}

function persistDrafts() {
  const payload = {};
  for (const seat of SEATS) {
    const ui = refs.get(seat.key);
    const snapshot = snapshotFrom(ui);
    if (FIELD_KEYS.some((key) => snapshot[key])) payload[seat.key] = snapshot;
  }
  state.drafts = payload;
  try {
    localStorage.setItem(DRAFT_KEY, JSON.stringify(payload));
  } catch {
    /* 本地草稿只是辅助，写入失败不影响保存。 */
  }
}

function clearSeatDraft(seatKey) {
  delete state.drafts[seatKey];
  try {
    localStorage.setItem(DRAFT_KEY, JSON.stringify(state.drafts));
  } catch {
    /* 同上。 */
  }
}

function restoreDrafts() {
  state.drafts = readDrafts();
  for (const seat of SEATS) {
    const ui = refs.get(seat.key);
    const snapshot = normalizeSnapshot(state.drafts[seat.key]);
    if (!FIELD_KEYS.some((key) => snapshot[key])) continue;
    applySnapshot(ui, snapshot);
    setFeedback(ui, '已恢复本机草稿，尚未保存。', 'warn');
  }
}

/* ------------------------------ 读取后台 ------------------------------ */

function applyInfo(configs, runs) {
  state.runs = runs;

  for (const seat of SEATS) {
    const ui = refs.get(seat.key);
    const config = configs.get(seat.provider);
    if (config) {
      state.savedConfigs.set(seat.provider, config);
      if (!state.initialized && !ui.touched) {
        applySnapshot(ui, config);
        clearSeatDraft(seat.key);
        setFeedback(ui, '');
      }
    }
    updateOrigin(ui);
    refreshStatus(seat);
    renderRun(ui);
  }

  state.initialized = true;
}

async function loadInfo({ announce = false } = {}) {
  try {
    const reply = await callBackground({ type: 'automation.info' });
    hideBackendNotice();
    const configs = normalizeConfigs(reply.configs);
    const runs = normalizeRuns(reply.runs);
    applyInfo(configs, runs);
    if (announce) toast('已读取当前连接设置');
  } catch (error) {
    showBackendNotice(error.message);
    if (announce) toast(friendlyError(error, '读取连接设置失败'), 'error');
  }
}

async function refreshRuns() {
  try {
    const reply = await callBackground({ type: 'automation.info' });
    state.runs = normalizeRuns(reply.runs);
    hideBackendNotice();
    for (const seat of SEATS) renderRun(refs.get(seat.key));
  } catch {
    /* 保存已经成功；运行状态读取失败不改变配置结果。 */
  }
}

/* ------------------------------ 保存 ------------------------------ */

async function saveSeat(seat) {
  const ui = refs.get(seat.key);
  if (ui.saving) return;

  const result = validateSeat(ui);
  if (result.error) {
    markInvalid(ui, result.field);
    setFeedback(ui, result.error, 'error');
    ui.fields[result.field]?.focus();
    return;
  }

  clearInvalid(ui);
  ui.saving = true;
  setFeedback(ui, '正在请求该地址的访问权限…');

  try {
    let granted = false;
    try {
      granted = await requestOriginPermission(result.pattern);
    } catch (error) {
      setFeedback(ui, permissionErrorMessage(error), 'error');
      return;
    }

    if (!granted) {
      setFeedback(ui, `没有获得 ${result.origin} 的访问权限，配置未保存。允许后可以重试。`, 'warn');
      return;
    }

    ui.save.disabled = true;
    const originalLabel = ui.save.textContent;
    ui.save.textContent = '保存中…';

    try {
      await callBackground({
        type: 'automation.config',
        provider: seat.provider,
        config: {
          url: result.url,
          selectors: result.selectors,
        },
      });

      applySnapshot(ui, result.snapshot);
      state.savedConfigs.set(seat.provider, result.snapshot);
      clearSeatDraft(seat.key);
      ui.touched = false;
      refreshStatus(seat);
      updateOrigin(ui);
      setFeedback(
        ui,
        `已保存。实际来源 ${result.origin} · 权限 ${result.pattern}（不含端口）。`,
        'ok',
      );
      toast(`已保存${seat.label}的连接设置`);
      void refreshRuns();
    } catch (error) {
      setFeedback(ui, friendlyError(error, '保存失败'), 'error');
    } finally {
      ui.save.disabled = false;
      ui.save.textContent = originalLabel;
    }
  } finally {
    ui.saving = false;
  }
}

/* ------------------------------ 事件 ------------------------------ */

function bindSeat(seat) {
  const ui = refs.get(seat.key);

  for (const key of FIELD_KEYS) {
    const input = ui.fields[key];
    input.addEventListener('input', () => {
      ui.touched = true;
      clearFieldInvalid(ui, key);
      updateOrigin(ui);
      refreshStatus(seat);
      persistDrafts();
      setFeedback(ui, '');
    });
  }

  ui.save.addEventListener('click', () => {
    void saveSeat(seat);
  });
}

function fillSample() {
  for (const seat of SEATS) {
    const ui = refs.get(seat.key);
    applySnapshot(ui, SAMPLE[seat.key]);
    ui.touched = true;
    clearInvalid(ui);
    updateOrigin(ui);
    refreshStatus(seat);
    setFeedback(ui, '已填入固定样本。确认无误后点击「保存本席」。', 'warn');
  }

  persistDrafts();
  toast('已填入本机测试页配置（固定样本，不是 AI）');
  refs.get('a').save.focus();
}

function init() {
  restoreDrafts();

  for (const seat of SEATS) {
    bindSeat(seat);
    const ui = refs.get(seat.key);
    updateOrigin(ui);
    refreshStatus(seat);
    renderRun(ui);
  }

  if (backendRetryEl) {
    backendRetryEl.addEventListener('click', () => {
      void loadInfo({ announce: true });
    });
  }

  if (fillSampleEl) {
    fillSampleEl.addEventListener('click', fillSample);
  }

  void loadInfo();
}

init();
