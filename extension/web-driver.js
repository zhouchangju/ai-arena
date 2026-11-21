/**
 * AI Arena · 网页席位驱动（隔离世界内容脚本）
 *
 * 目标编号：G1 / R09。
 * 适用：用户本人已登录、且由工作台显式绑定的网页版 AI（例如本机 Open WebUI）。
 * 形态：普通 JS，无构建、无依赖、无任何网络请求；不读写 chrome.storage，不碰账号。
 *       所有任务状态只保存在当前页面内存里，页面刷新即清空（这是故意的，见“未知任务”）。
 *
 * 集成方式（扩展后台 / 工作台）：
 *   await chrome.scripting.executeScript({
 *     target: { tabId, frameIds: [0] },
 *     files: ['web-driver.js'],        // 相对扩展根；本仓库位于 extension/web-driver.js
 *   });
 *   const reply = await chrome.tabs.sendMessage(tabId, {
 *     type: 'arena.web.probe' | 'arena.web.submit' | 'arena.web.read',
 *     taskId: 'round1.seatA',
 *     prompt: '本轮要发送的原文',          // submit 必填
 *     selectors: {
 *       input: '#composer',                 // 输入框（必填）
 *       send: '#send',                     // 发送控件（必填）
 *       user: '.turn.user .msg',           // 用户消息（必填，可多节点）
 *       answer: '.turn.answer .msg',       // 回答消息（必填，可多节点）
 *       stop: '#stop',                     // 生成中控件（可选，强烈建议）
 *       done: '#done',                     // 完成标记（可选，强烈建议）
 *       container: '#log',                 // 可选：仅限定会话消息（user/answer）所在区域
 *     },
 *     options: { sampleMs: 250, stableSamples: 3, stableMs: 600 },
 *     scope: { origin: 'http://localhost:3000', hrefPrefix: 'http://localhost:3000/' },
 *   }, { frameId: 0 });
 *
 * 回应：{ ok, status, text?, error?, detail? }
 *   status: 'ready' | 'submitted' | 'pending' | 'done' | 'unknown' | 'error'
 *   ok     : 仅 ready / submitted / pending / done 为 true
 *   text   : 仅 done 返回完整回答；pending 不回传半截文本（只给 detail.partialChars）
 *   error  : 稳定错误码（见 README/交接说明）
 *   detail : 诊断信息（基线计数、拒绝原因、稳定采样结果等），可直接记日志
 *
 * 硬性行为：
 *   1. read 绝不填写、绝不点击、绝不改页面（无提交副作用）。
 *   2. submit 前记录基线；只接受“提交后新出现、且文本等于本轮 prompt”的用户消息，
 *      再取其后新出现、且不等于基线旧文本的回答消息。
 *   3. 已有非空且与本轮 prompt 不同的草稿：拒绝（draft-conflict），绝不覆盖。
 *   4. 同一 taskId 只提交一次；重复 submit 返回当前状态，不重复点击。
 *   5. 完成证据只认两种：
 *        a) 显式 done 标记可见 + 文本稳定采样；
 *        b) 亲眼看到 stop 可见，之后 stop 消失 + 文本稳定采样。
 *      没有证据就保持 pending；沉默、截断、部分文本都不算完成。
 *   6. 页面刷新/换地址/历史节点减少：read 返回 unknown，不猜测。
 *
 * 错误码（status:error 时 error 字段）：
 *   bad-message, foreign-sender, not-authorized-page, document-not-ready,
 *   selector-invalid, selector-missing, selector-hidden, selector-ambiguous,
 *   selector-overlap, out-of-scope, prompt-empty, prompt-too-long,
 *   prompt-already-sent, task-id-conflict, selector-changed,
 *   input-uneditable, input-disabled, input-readonly, draft-conflict, busy,
 *   fill-failed, fill-mismatch, send-unavailable, send-click-ignored,
 *   submit-unconfirmed, user-turn-mismatch, internal
 *
 * 未知任务（status:unknown 时 error 字段）：
 *   task-unknown（页面重载/丢状态）, page-changed, history-changed
 *
 * pending 的 detail.reason：
 *   awaiting-user-turn, generating, awaiting-answer, answer-equal-old,
 *   answer-empty, answer-before-user-turn, answer-order-unverified,
 *   answer-updating, answer-disappeared, completion-signal-missing
 */

(function () {
  'use strict';

  const VERSION = '1.0.0';
  const STATE_KEY = '__arenaWebDriverState__';
  const HOOK_KEY = '__arenaWebDriver';
  const TYPES = Object.freeze({
    probe: 'arena.web.probe',
    submit: 'arena.web.submit',
    read: 'arena.web.read',
  });
  const TASK_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/;
  const MAX_PROMPT_CHARS = 100000;
  const MAX_SELECTOR_CHARS = 400;
  const SELECTOR_KEYS = ['input', 'send', 'user', 'answer', 'stop', 'done', 'container'];
  const REQUIRED_SELECTOR_KEYS = ['input', 'send', 'user', 'answer'];
  const DEFAULT_OPTIONS = Object.freeze({
    sampleMs: 250,
    stableSamples: 3,
    stableMs: 600,
    submitTimeoutMs: 15000,
    sendEnableMs: 4000,
    pollMs: 150,
    turnGraceMs: 800,
    pendingTimeoutMs: 180000,
  });
  const RECORD_TTL_MS = 15 * 60 * 1000;
  const MAX_RECORDS = 50;

  // ---------------------------------------------------------------------------
  // 基础工具
  // ---------------------------------------------------------------------------

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  function noop() {}

  function reply(status, fields) {
    const ok = status === 'ready' || status === 'submitted' || status === 'pending' || status === 'done';
    const out = { ok: ok, status: status };
    if (fields) {
      for (const key of Object.keys(fields)) {
        if (fields[key] !== undefined) out[key] = fields[key];
      }
    }
    return out;
  }

  function fail(code, detail) {
    return reply('error', { error: code, detail: detail });
  }

  function unknown(code, detail) {
    return reply('unknown', { error: code, detail: detail });
  }

  function getRuntime() {
    try {
      if (typeof chrome !== 'undefined' && chrome && chrome.runtime) return chrome.runtime;
    } catch (e) {
      /* 普通页面无扩展环境 */
    }
    return null;
  }

  function isArenaMessage(message) {
    return Boolean(message) &&
      typeof message === 'object' &&
      typeof message.type === 'string' &&
      (message.type === TYPES.probe || message.type === TYPES.submit || message.type === TYPES.read);
  }

  function cleanText(value) {
    return String(value == null ? '' : value)
      .replace(/\u00a0/g, ' ')
      .replace(/\r\n?/g, '\n')
      .replace(/[ \t]+$/gm, '')
      .replace(/\n{3,}/g, '\n\n')
      .replace(/^\s+|\s+$/g, '');
  }

  function collapse(value) {
    return cleanText(value)
      .replace(/[\u200b-\u200d\ufeff]/g, '')
      .replace(/\s+/g, ' ')
      .trim();
  }

  function sameText(a, b) {
    return collapse(a) === collapse(b) && collapse(a) !== '';
  }

  function textOf(node) {
    if (!node) return '';
    if (typeof node.innerText === 'string') return node.innerText;
    return node.textContent || '';
  }

  function isElement(node) {
    return Boolean(node) && node.nodeType === 1;
  }

  function isVisible(el) {
    if (!isElement(el) || !el.isConnected) return false;
    if (el.closest && el.closest('[hidden]')) return false;
    let style;
    try {
      style = window.getComputedStyle(el);
    } catch (e) {
      return false;
    }
    if (!style) return false;
    if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return false;
    if (parseFloat(style.opacity) === 0) return false;
    if (typeof el.checkVisibility === 'function') {
      try {
        if (!el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
      } catch (e) {
        /* 旧实现忽略 */
      }
    }
    const rect = el.getBoundingClientRect();
    return rect.width > 0 || rect.height > 0;
  }

  function elementEnabled(el) {
    if (!isElement(el)) return false;
    if (el.disabled === true) return false;
    if (el.getAttribute && el.getAttribute('aria-disabled') === 'true') return false;
    try {
      if (el.matches(':disabled')) return false;
    } catch (e) {
      /* 某些自定义元素不支持 :disabled */
    }
    return true;
  }

  function isValidSelector(css) {
    try {
      document.createDocumentFragment().querySelector(css);
      return true;
    } catch (e) {
      return false;
    }
  }

  function listNodes(css, container) {
    if (!css) return [];
    try {
      return Array.from((container || document).querySelectorAll(css)).filter((node) => node.isConnected);
    } catch (e) {
      return [];
    }
  }

  function touchesSelector(node, css) {
    if (!node || !css || !isElement(node)) return false;
    try {
      if (typeof node.matches === 'function' && node.matches(css)) return true;
      if (typeof node.closest === 'function' && node.closest(css)) return true;
      if (typeof node.querySelector === 'function' && node.querySelector(css)) return true;
    } catch (e) {
      return false;
    }
    return false;
  }

  function selectorSignature(selectors) {
    return SELECTOR_KEYS.map((key) => key + '=' + (selectors[key] || '')).join('|');
  }

  function parseOptions(raw) {
    const src = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
    function pick(key, fallback, min, max) {
      const value = src[key];
      if (typeof value !== 'number' || !isFinite(value)) return fallback;
      return Math.min(max, Math.max(min, Math.round(value)));
    }
    return {
      sampleMs: pick('sampleMs', DEFAULT_OPTIONS.sampleMs, 50, 2000),
      stableSamples: pick('stableSamples', DEFAULT_OPTIONS.stableSamples, 1, 10),
      stableMs: pick('stableMs', DEFAULT_OPTIONS.stableMs, 0, 10000),
      submitTimeoutMs: pick('submitTimeoutMs', DEFAULT_OPTIONS.submitTimeoutMs, 1000, 120000),
      sendEnableMs: pick('sendEnableMs', DEFAULT_OPTIONS.sendEnableMs, 200, 30000),
      pollMs: pick('pollMs', DEFAULT_OPTIONS.pollMs, 50, 2000),
      turnGraceMs: pick('turnGraceMs', DEFAULT_OPTIONS.turnGraceMs, 0, 5000),
      pendingTimeoutMs: pick('pendingTimeoutMs', DEFAULT_OPTIONS.pendingTimeoutMs, 10000, 3600000),
    };
  }

  function parseScope(raw) {
    if (raw === undefined || raw === null) return { value: null };
    if (typeof raw !== 'object' || Array.isArray(raw)) return { error: 'not-an-object' };
    const scope = {};
    if (raw.origin !== undefined && raw.origin !== null && raw.origin !== '') {
      if (typeof raw.origin !== 'string' || raw.origin.length > 300) return { error: 'origin' };
      scope.origin = raw.origin;
    }
    if (raw.hrefPrefix !== undefined && raw.hrefPrefix !== null && raw.hrefPrefix !== '') {
      if (typeof raw.hrefPrefix !== 'string' || raw.hrefPrefix.length > 2000) return { error: 'hrefPrefix' };
      scope.hrefPrefix = raw.hrefPrefix;
    }
    return { value: scope };
  }

  function parseSelectors(raw) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      return { error: fail('selector-invalid', { which: 'selectors', reason: 'not-an-object' }) };
    }
    const out = {};
    for (const key of SELECTOR_KEYS) {
      const value = raw[key];
      if (value === undefined || value === null || value === '') {
        if (REQUIRED_SELECTOR_KEYS.indexOf(key) !== -1) {
          return { error: fail('selector-invalid', { which: key, reason: 'missing' }) };
        }
        continue;
      }
      if (typeof value !== 'string') {
        return { error: fail('selector-invalid', { which: key, reason: 'not-a-string' }) };
      }
      const css = value.trim();
      if (!css || css.length > MAX_SELECTOR_CHARS) {
        return { error: fail('selector-invalid', { which: key, reason: 'length' }) };
      }
      if (!isValidSelector(css)) {
        return { error: fail('selector-invalid', { which: key, reason: 'css' }) };
      }
      out[key] = css;
    }
    if (out.user === out.answer) {
      return { error: fail('selector-overlap', { which: 'user/answer' }) };
    }
    return { value: out };
  }

  function parseCommon(message, needPrompt) {
    const scope = parseScope(message.scope);
    if (scope.error) {
      return { error: fail('bad-message', { field: 'scope', reason: scope.error }) };
    }
    if (typeof message.taskId !== 'string' || !TASK_ID_RE.test(message.taskId)) {
      return { error: fail('bad-message', { field: 'taskId' }) };
    }
    const selectors = parseSelectors(message.selectors);
    if (selectors.error) return { error: selectors.error };
    let prompt = null;
    if (needPrompt) {
      if (typeof message.prompt !== 'string' || !collapse(message.prompt)) {
        return { error: fail('prompt-empty') };
      }
      if (message.prompt.length > MAX_PROMPT_CHARS) {
        return { error: fail('prompt-too-long', { max: MAX_PROMPT_CHARS }) };
      }
      if (message.prompt.indexOf('\u0000') !== -1) {
        return { error: fail('prompt-empty', { reason: 'nul' }) };
      }
      prompt = message.prompt;
    }
    return {
      taskId: message.taskId,
      prompt: prompt,
      selectors: selectors.value,
      options: parseOptions(message.options),
      scope: scope.value,
    };
  }

  function authorizeDocument(scope) {
    const protocol = String(location.protocol || '');
    if (protocol !== 'http:' && protocol !== 'https:' && protocol !== 'file:') {
      return fail('not-authorized-page', { protocol: protocol });
    }
    if (!document.documentElement || !document.body) {
      return fail('document-not-ready', { url: location.href });
    }
    if (scope) {
      if (scope.origin && location.origin !== scope.origin) {
        return fail('out-of-scope', { expectedOrigin: scope.origin, actualOrigin: location.origin });
      }
      if (scope.hrefPrefix && location.href.indexOf(scope.hrefPrefix) !== 0) {
        return fail('out-of-scope', { expectedHrefPrefix: scope.hrefPrefix, actualHref: location.href });
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // DOM 解析：选择器 → 唯一控件 / 可选信号
  // ---------------------------------------------------------------------------

  /**
   * container 只限定“会话消息”范围（user / answer 及其基线），
   * 不限定输入框、发送键、stop/done 这些页面控件——它们本来就在会话区之外。
   */
  function resolveContainer(selectors) {
    if (!selectors.container) return { value: null };
    const resolved = resolveUnique(selectors, 'container', null, { requireVisible: false });
    if (resolved.error) return resolved;
    return { value: resolved.value, matched: resolved.matched };
  }

  /**
   * 单控件解析。
   * - requireVisible=true：必须恰有一个可见匹配；隐藏的旧节点被忽略。
   * - requireVisible=false（如发送键在空输入时隐藏）：允许隐藏，但多个匹配时必须只有一个是可见的。
   */
  function resolveUnique(selectors, key, container, opts) {
    const requireVisible = !opts || opts.requireVisible !== false;
    let all;
    try {
      all = Array.from((container || document).querySelectorAll(selectors[key])).filter((node) => node.isConnected);
    } catch (e) {
      return { error: fail('selector-invalid', { which: key }) };
    }
    if (!all.length) {
      return { error: fail('selector-missing', { which: key, selector: selectors[key] }) };
    }
    const visible = all.filter(isVisible);
    if (visible.length > 1) {
      return { error: fail('selector-ambiguous', { which: key, visible: visible.length, total: all.length }) };
    }
    if (requireVisible) {
      if (!visible.length) {
        return { error: fail('selector-hidden', { which: key, total: all.length }) };
      }
      return { value: visible[0], matched: all.length };
    }
    if (visible.length === 1) return { value: visible[0], matched: all.length };
    if (all.length === 1) return { value: all[0], matched: all.length };
    return { error: fail('selector-ambiguous', { which: key, visible: 0, total: all.length }) };
  }

  function optionalSignal(selectors, key, container) {
    const css = selectors[key];
    if (!css) return { present: false, active: false, element: null };
    let all;
    try {
      all = Array.from((container || document).querySelectorAll(css)).filter((node) => node.isConnected);
    } catch (e) {
      return { error: fail('selector-invalid', { which: key }) };
    }
    if (!all.length) return { present: false, active: false, element: null };
    const visible = all.filter(isVisible);
    if (visible.length > 1) {
      return { error: fail('selector-ambiguous', { which: key, visible: visible.length, total: all.length }) };
    }
    return { present: true, active: visible.length === 1, element: visible[0] || null };
  }

  // ---------------------------------------------------------------------------
  // 历史消息：基线、用户轮、对应回答
  // ---------------------------------------------------------------------------

  function snapshotHistory(selectors, container) {
    const users = listNodes(selectors.user, container);
    const answers = listNodes(selectors.answer, container);
    return {
      userCount: users.length,
      answerCount: answers.length,
      userTexts: users.map((node) => collapse(textOf(node))),
      answerTexts: answers.map((node) => collapse(textOf(node))),
      href: location.href,
      at: Date.now(),
    };
  }

  function detectOverlap(selectors, container) {
    const users = listNodes(selectors.user, container);
    const answers = listNodes(selectors.answer, container);
    for (const answer of answers) {
      for (const user of users) {
        if (answer === user || (user.contains && user.contains(answer)) || (answer.contains && answer.contains(user))) {
          return { user: user, answer: answer };
        }
      }
    }
    return null;
  }

  /**
   * 只认提交基线之后新出现的用户消息，且其文本必须等于本轮 prompt。
   * 有新的用户消息但文本不符 → user-turn-mismatch（失败关闭），不退化成“取最后一条”。
   */
  function locateUserTurn(record, selectors, container, options) {
    const users = listNodes(selectors.user, container);
    if (users.length < record.baseline.userCount) {
      return {
        error: unknown('history-changed', {
          expectedUsers: record.baseline.userCount,
          actualUsers: users.length,
        }),
      };
    }
    const fresh = [];
    for (let index = record.baseline.userCount; index < users.length; index += 1) {
      const node = users[index];
      const raw = textOf(node);
      fresh.push({
        node: node,
        index: index,
        text: cleanText(raw),
        collapsed: collapse(raw),
        chrome: touchesSelector(node, selectors.input) || touchesSelector(node, selectors.send),
      });
    }
    if (!fresh.length) return { pending: true, turn: null };
    const matches = fresh.filter((item) => item.collapsed === record.promptCollapsed && !item.chrome);
    if (!matches.length) {
      const allBlank = fresh.every((item) => !item.collapsed);
      const settled = Date.now() - record.startedAt >= options.turnGraceMs;
      if (allBlank || !settled) return { pending: true, turn: null };
      const last = fresh[fresh.length - 1];
      return {
        error: fail('user-turn-mismatch', {
          freshCount: fresh.length,
          lastText: last.text.slice(0, 200),
          expectedChars: record.promptCollapsed.length,
        }),
      };
    }
    const turn = matches[matches.length - 1];
    return { turn: turn, index: turn.index, matchCount: matches.length };
  }

  function compareOrder(node, reference) {
    if (!node || !reference) return 'unknown';
    try {
      const rel = reference.compareDocumentPosition(node);
      if (rel & 4) return 'after'; // DOCUMENT_POSITION_FOLLOWING
      if (rel & 2) return 'before'; // DOCUMENT_POSITION_PRECEDING
    } catch (e) {
      return 'unknown';
    }
    return 'unknown';
  }

  /**
   * 在基线之后寻找“对应”的回答：必须排在已匹配的用户轮之后，
   * 文本非空、不等于基线里的任何旧回答、也不是输入控件本身。
   */
  function locateAnswer(record, selectors, userNode, container) {
    const answers = listNodes(selectors.answer, container);
    if (answers.length < record.baseline.answerCount) {
      return {
        error: unknown('history-changed', {
          expectedAnswers: record.baseline.answerCount,
          actualAnswers: answers.length,
        }),
      };
    }
    const rejected = { empty: 0, equalOld: 0, beforeTurn: 0, touching: 0, chrome: 0, orderUnverified: 0 };
    for (let index = record.baseline.answerCount; index < answers.length; index += 1) {
      const node = answers[index];
      if (!node) continue;
      if (node === userNode || (node.contains && node.contains(userNode)) || (userNode.contains && userNode.contains(node))) {
        rejected.touching += 1;
        continue;
      }
      if (touchesSelector(node, selectors.input) || touchesSelector(node, selectors.send)) {
        rejected.chrome += 1;
        continue;
      }
      const raw = textOf(node);
      const text = cleanText(raw);
      if (!text) {
        rejected.empty += 1;
        continue;
      }
      const collapsed = collapse(raw);
      if (record.baseline.answerTexts.indexOf(collapsed) !== -1) {
        rejected.equalOld += 1;
        continue;
      }
      const order = compareOrder(node, userNode);
      if (order === 'before' || order === 'same') {
        rejected.beforeTurn += 1;
        continue;
      }
      if (order !== 'after') {
        rejected.orderUnverified += 1;
        continue;
      }
      return { node: node, index: index, text: text, collapsed: collapsed, rejected: rejected };
    }
    return { pending: true, node: null, rejected: rejected };
  }

  // ---------------------------------------------------------------------------
  // 输入框读写
  // ---------------------------------------------------------------------------

  function composerRoot(el) {
    if (!isElement(el)) return el;
    if (composerKind(el) !== 'contenteditable') return el;
    try {
      return el.closest('[contenteditable=""],[contenteditable="true"],[contenteditable="plaintext-only"]') || el;
    } catch (e) {
      return el;
    }
  }

  function composerKind(el) {
    if (!isElement(el)) return null;
    if (el.tagName === 'TEXTAREA') return 'value';
    if (el.tagName === 'INPUT') {
      const type = String(el.getAttribute('type') || 'text').toLowerCase();
      return ['text', 'search', 'url', 'email', 'tel'].indexOf(type) !== -1 ? 'value' : null;
    }
    if (el.isContentEditable) return 'contenteditable';
    if (el.getAttribute && el.getAttribute('contenteditable') === 'true') return 'contenteditable';
    try {
      if (el.closest && el.closest('[contenteditable=""],[contenteditable="true"],[contenteditable="plaintext-only"]')) {
        return 'contenteditable';
      }
    } catch (e) {
      /* ignore */
    }
    return null;
  }

  function composerText(el) {
    if (!el) return '';
    if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') return String(el.value || '');
    if (typeof el.innerText === 'string') return el.innerText;
    return String(el.textContent || '');
  }

  function dispatchInput(el, text) {
    try {
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
    } catch (e) {
      try {
        el.dispatchEvent(new Event('input', { bubbles: true }));
      } catch (err) {
        /* ignore */
      }
    }
    try {
      el.dispatchEvent(new Event('change', { bubbles: true }));
    } catch (e) {
      /* ignore */
    }
  }

  function selectAllContents(el) {
    try {
      const range = document.createRange();
      range.selectNodeContents(el);
      const selection = window.getSelection();
      if (!selection) return false;
      selection.removeAllRanges();
      selection.addRange(range);
      return true;
    } catch (e) {
      return false;
    }
  }

  function setComposerValue(el, text) {
    const kind = composerKind(el);
    if (!kind) return { ok: false, code: 'input-uneditable' };
    const root = composerRoot(el);
    if (kind === 'value') {
      try {
        root.focus();
        const proto = root.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
        if (descriptor && typeof descriptor.set === 'function') descriptor.set.call(root, text);
        else root.value = text;
        dispatchInput(root, text);
      } catch (e) {
        return { ok: false, code: 'fill-failed', detail: { message: String((e && e.message) || e) } };
      }
      if (!sameText(composerText(root), text)) {
        return { ok: false, code: 'fill-mismatch', detail: { kind: 'value', expectedChars: text.length, actualChars: composerText(root).length } };
      }
      return { ok: true };
    }
    try {
      root.focus();
      selectAllContents(root);
      try {
        document.execCommand('insertText', false, text);
      } catch (e) {
        /* 走下面的兜底 */
      }
      if (!sameText(composerText(root), text)) {
        root.textContent = text;
        dispatchInput(root, text);
      }
    } catch (e) {
      return { ok: false, code: 'fill-failed', detail: { message: String((e && e.message) || e) } };
    }
    if (!sameText(composerText(root), text)) {
      return { ok: false, code: 'fill-mismatch', detail: { kind: 'contenteditable', expectedChars: text.length, actualChars: composerText(root).length } };
    }
    return { ok: true };
  }

  function clickElement(el) {
    if (!isElement(el) || typeof el.click !== 'function') return false;
    try {
      el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    } catch (e) {
      /* ignore */
    }
    try {
      el.focus({ preventScroll: true });
    } catch (e) {
      /* ignore */
    }
    try {
      el.click();
    } catch (e) {
      return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // 任务记录与串行执行
  // ---------------------------------------------------------------------------

  function runExclusive(state, task) {
    const next = state.chain.then(task, task);
    state.chain = next.then(noop, noop);
    return next;
  }

  function remember(state, record) {
    state.records.set(record.taskId, record);
    if (state.records.size > MAX_RECORDS) {
      const finished = [];
      state.records.forEach((item, key) => {
        if (item.completedText != null || Date.now() - item.startedAt > RECORD_TTL_MS) finished.push(key);
      });
      for (const key of finished) {
        if (state.records.size <= MAX_RECORDS - 10) break;
        state.records.delete(key);
      }
    }
  }

  function taskDetail(record, extra) {
    const detail = {
      taskId: record.taskId,
      userTurnVerified: Boolean(record.verified),
      sawGenerating: Boolean(record.sawGenerating),
      sawDoneMarker: Boolean(record.sawDoneMarker),
      elapsedMs: Date.now() - record.startedAt,
      url: location.href,
    };
    if (extra) {
      for (const key of Object.keys(extra)) {
        if (extra[key] !== undefined) detail[key] = extra[key];
      }
    }
    return detail;
  }

  function historyRejected(rejected) {
    if (!rejected) return undefined;
    return {
      empty: rejected.empty,
      equalOld: rejected.equalOld,
      beforeTurn: rejected.beforeTurn,
      touching: rejected.touching,
      chrome: rejected.chrome,
      orderUnverified: rejected.orderUnverified,
    };
  }

  // ---------------------------------------------------------------------------
  // probe
  // ---------------------------------------------------------------------------

  function probe(state, message) {
    const req = parseCommon(message, false);
    if (req.error) return req.error;
    const denied = authorizeDocument(req.scope);
    if (denied) return denied;

    const containerRes = resolveContainer(req.selectors);
    if (containerRes.error) return containerRes.error;
    const container = containerRes.value;

    const inputRes = resolveUnique(req.selectors, 'input', null, { requireVisible: true });
    if (inputRes.error) return inputRes.error;
    const input = inputRes.value;
    const kind = composerKind(input);
    if (!kind) return fail('input-uneditable', { tag: String(input.tagName || '').toLowerCase() });
    if (!elementEnabled(input)) return fail('input-disabled');
    if (input.readOnly === true) return fail('input-readonly');

    const sendRes = resolveUnique(req.selectors, 'send', null, { requireVisible: false });
    if (sendRes.error) return sendRes.error;
    const send = sendRes.value;

    const stop = optionalSignal(req.selectors, 'stop', null);
    if (stop.error) return stop.error;
    const done = optionalSignal(req.selectors, 'done', null);
    if (done.error) return done.error;

    const overlap = detectOverlap(req.selectors, container);
    if (overlap) return fail('selector-overlap', { which: 'user/answer' });

    const users = listNodes(req.selectors.user, container);
    const answers = listNodes(req.selectors.answer, container);
    const draft = cleanText(composerText(composerRoot(input)));
    const record = state.records.get(req.taskId) || null;

    return reply('ready', {
      detail: {
        version: VERSION,
        taskId: req.taskId,
        url: location.href,
        frame: window.top === window ? 'top' : 'sub',
        composer: {
          kind: kind,
          draftChars: draft.length,
          draftEmpty: !collapse(draft),
          enabled: elementEnabled(input),
        },
        send: { visible: isVisible(send), enabled: elementEnabled(send) },
        stop: { configured: Boolean(req.selectors.stop), present: stop.present, active: stop.active },
        done: { configured: Boolean(req.selectors.done), present: done.present, active: done.active },
        history: { userCount: users.length, answerCount: answers.length },
        knownTask: record
          ? {
              taskId: record.taskId,
              status: record.completedText != null ? 'done' : 'submitted',
              verified: Boolean(record.verified),
              startedAt: record.startedAt,
            }
          : null,
      },
    });
  }

  // ---------------------------------------------------------------------------
  // submit
  // ---------------------------------------------------------------------------

  function checkBusy(state, selectors, container, taskId) {
    if (!optionalSignal(selectors, 'stop', null).active) return null;
    const now = Date.now();
    for (const record of state.records.values()) {
      if (record.taskId === taskId) continue;
      if (record.completedText != null) continue;
      if (now - record.startedAt > RECORD_TTL_MS) continue;
      return fail('busy', { activeTaskId: record.taskId, activeSince: record.startedAt });
    }
    return null;
  }

  async function waitForSend(selectors, options) {
    const deadline = Date.now() + options.sendEnableMs;
    let lastError = null;
    while (true) {
      const resolved = resolveUnique(selectors, 'send', null, { requireVisible: true });
      if (!resolved.error) {
        if (elementEnabled(resolved.value)) return { value: resolved.value };
        lastError = fail('send-unavailable', { reason: 'disabled' });
      } else {
        lastError = resolved.error;
      }
      if (Date.now() >= deadline) return { error: lastError || fail('send-unavailable') };
      await sleep(100);
    }
  }

  async function waitForUserTurn(record, selectors, container, options) {
    const deadline = Date.now() + options.submitTimeoutMs;
    while (true) {
      const located = locateUserTurn(record, selectors, container, options);
      if (located.error) return { error: located.error };
      if (located.turn) return { value: located };
      const stop = optionalSignal(selectors, 'stop', null);
      if (stop.error) return { error: stop.error };
      if (stop.active) record.sawGenerating = true;
      if (Date.now() >= deadline) return { timeout: true };
      await sleep(options.pollMs);
    }
  }

  async function submit(state, message) {
    const req = parseCommon(message, true);
    if (req.error) return req.error;
    const denied = authorizeDocument(req.scope);
    if (denied) return denied;

    const containerRes = resolveContainer(req.selectors);
    if (containerRes.error) return containerRes.error;
    const container = containerRes.value;

    const inputRes = resolveUnique(req.selectors, 'input', null, { requireVisible: true });
    if (inputRes.error) return inputRes.error;
    const input = inputRes.value;
    const kind = composerKind(input);
    if (!kind) return fail('input-uneditable', { tag: String(input.tagName || '').toLowerCase() });
    if (!elementEnabled(input)) return fail('input-disabled');
    if (input.readOnly === true) return fail('input-readonly');

    const overlap = detectOverlap(req.selectors, container);
    if (overlap) return fail('selector-overlap', { which: 'user/answer' });

    // 去重：同一 taskId 只提交一次，后续调用只读当前状态。
    const existing = state.records.get(req.taskId);
    if (existing) {
      if (collapse(existing.prompt) !== collapse(req.prompt)) {
        return fail('task-id-conflict', { taskId: req.taskId });
      }
      if (existing.selectorSignature !== selectorSignature(req.selectors)) {
        return fail('selector-changed', { taskId: req.taskId });
      }
      const current = await evaluate(existing, req.selectors, req.options, container);
      if (current.detail) current.detail.deduped = true;
      return current;
    }

    const promptCollapsed = collapse(req.prompt);
    const draft = composerText(composerRoot(input));
    const draftCollapsed = collapse(draft);
    if (draftCollapsed && draftCollapsed !== promptCollapsed) {
      return fail('draft-conflict', { draftChars: cleanText(draft).length });
    }

    // 刷新/丢状态后，最后一条用户消息已经等于本轮 prompt：多半是重复发送，失败关闭。
    const users = listNodes(req.selectors.user, container);
    if (users.length) {
      const lastUser = collapse(textOf(users[users.length - 1]));
      if (lastUser && lastUser === promptCollapsed) {
        return fail('prompt-already-sent', { historyUsers: users.length });
      }
    }

    const busy = checkBusy(state, req.selectors, container, req.taskId);
    if (busy) return busy;

    // 只有空输入或内容已完全一致才写；绝不覆盖不同草稿。
    let filled = false;
    if (draftCollapsed !== promptCollapsed) {
      const write = setComposerValue(input, req.prompt);
      if (!write.ok) {
        // 写失败时尽量把空输入框还原，避免留下被截断的 prompt。
        if (!draftCollapsed) setComposerValue(input, '');
        return fail(write.code, write.detail);
      }
      filled = true;
      await sleep(60);
      if (!sameText(composerText(composerRoot(input)), req.prompt)) {
        if (!draftCollapsed) setComposerValue(input, '');
        return fail('fill-mismatch', { phase: 'after-fill' });
      }
    }

    const sendRes = await waitForSend(req.selectors, req.options);
    if (sendRes.error) return sendRes.error;
    const send = sendRes.value;

    // 点击前记录基线：此后只认新节点。
    const baseline = snapshotHistory(req.selectors, container);
    const record = {
      taskId: req.taskId,
      prompt: req.prompt,
      promptCollapsed: promptCollapsed,
      selectorSignature: selectorSignature(req.selectors),
      selectors: req.selectors,
      baseline: baseline,
      href: location.href,
      startedAt: Date.now(),
      attempted: true,
      verified: false,
      verifiedAt: null,
      sawGenerating: false,
      sawDoneMarker: false,
      lastAnswerText: null,
      stableSince: null,
      completedText: null,
      completedAt: null,
    };
    remember(state, record);

    if (!clickElement(send)) {
      state.records.delete(req.taskId);
      return fail('send-unavailable', { reason: 'not-clickable' });
    }

    const located = await waitForUserTurn(record, req.selectors, container, req.options);
    if (located.error) return located.error;
    if (located.timeout) {
      const stop = optionalSignal(req.selectors, 'stop', null);
      const stopActive = !stop.error && stop.active;
      const inputNow = resolveUnique(req.selectors, 'input', null, { requireVisible: true });
      const stillPrompt = !inputNow.error && sameText(composerText(composerRoot(inputNow.value)), req.prompt);
      const sendNow = resolveUnique(req.selectors, 'send', null, { requireVisible: false });
      const sendReady = !sendNow.error && elementEnabled(sendNow.value);
      if (!stopActive && stillPrompt && sendReady) {
        // 输入框还留着原文、没有生成迹象：点击大概率没生效，允许调用方安全重试。
        state.records.delete(req.taskId);
        return fail('send-click-ignored', { detail: { timeoutMs: req.options.submitTimeoutMs } });
      }
      return fail('submit-unconfirmed', {
        detail: { possiblySubmitted: true, timeoutMs: req.options.submitTimeoutMs, stopActive: stopActive },
      });
    }

    record.verified = true;
    record.verifiedAt = Date.now();
    const answer = locateAnswer(record, req.selectors, located.value.turn.node, container);
    return reply('submitted', {
      detail: {
        taskId: req.taskId,
        filled: filled,
        userTurnIndex: located.value.index,
        userTurnMatches: located.value.matchCount,
        answerDetected: Boolean(!answer.error && answer.node),
        sawGenerating: Boolean(record.sawGenerating),
        elapsedMs: Date.now() - record.startedAt,
        url: location.href,
      },
    });
  }

  // ---------------------------------------------------------------------------
  // read / evaluate
  // ---------------------------------------------------------------------------

  async function sampleAnswer(record, selectors, container, userNode, options) {
    let located = locateAnswer(record, selectors, userNode, container);
    if (located.error) return { error: located.error };
    if (!located.node) {
      const rejected = located.rejected || {};
      let reason = 'awaiting-answer';
      if (rejected.equalOld) reason = 'answer-equal-old';
      else if (rejected.empty) reason = 'answer-empty';
      else if (rejected.beforeTurn) reason = 'answer-before-user-turn';
      else if (rejected.orderUnverified) reason = 'answer-order-unverified';
      return { pendingReason: reason, rejected: historyRejected(located.rejected) };
    }

    let text = located.text;
    let lastChangeAt = record.lastAnswerText === text && record.stableSince ? record.stableSince : Date.now();
    let observations = 0;
    let sawMarker = record.sawDoneMarker;

    for (let index = 0; index < options.stableSamples; index += 1) {
      await sleep(options.sampleMs);

      const stop = optionalSignal(selectors, 'stop', null);
      if (stop.error) return { error: stop.error };
      if (stop.active) {
        record.sawGenerating = true;
        record.lastAnswerText = text;
        record.stableSince = Date.now();
        return { pendingReason: 'generating', partialChars: text.length };
      }

      const done = optionalSignal(selectors, 'done', null);
      if (done.error) return { error: done.error };
      if (done.active) {
        record.sawDoneMarker = true;
        sawMarker = true;
      }

      const again = locateAnswer(record, selectors, userNode, container);
      if (again.error) return { error: again.error };
      if (!again.node) {
        return { pendingReason: 'answer-disappeared', rejected: historyRejected(again.rejected) };
      }
      observations += 1;
      if (again.text !== text) {
        text = again.text;
        lastChangeAt = Date.now();
      }
    }

    const stableFor = Date.now() - lastChangeAt;
    record.lastAnswerText = text;
    record.stableSince = lastChangeAt;

    const partial = {
      observations: observations,
      stableMs: stableFor,
      sawGenerating: Boolean(record.sawGenerating),
      sawDoneMarker: Boolean(sawMarker),
    };

    if (!text) return { pendingReason: 'answer-empty', partial: partial };
    if (observations < options.stableSamples || stableFor < options.stableMs) {
      return { pendingReason: 'answer-updating', partial: partial, partialChars: text.length };
    }

    const stopNow = optionalSignal(selectors, 'stop', null);
    if (stopNow.error) return { error: stopNow.error };
    if (stopNow.active) {
      record.sawGenerating = true;
      return { pendingReason: 'generating', partial: partial, partialChars: text.length };
    }

    if (record.sawGenerating) {
      return { done: true, text: text, evidence: 'stop-observed', partial: partial };
    }
    if (sawMarker) {
      return { done: true, text: text, evidence: 'done-marker', partial: partial };
    }
    return { pendingReason: 'completion-signal-missing', partial: partial, partialChars: text.length };
  }

  async function evaluate(record, selectors, options, container) {
    // 已完成的任务保持幂等；不因轮询重复判定。
    if (record.completedText != null) {
      return reply('done', {
        text: record.completedText,
        detail: {
          taskId: record.taskId,
          source: 'recorded',
          completedAt: record.completedAt,
          userTurnVerified: true,
          url: location.href,
        },
      });
    }

    const located = locateUserTurn(record, selectors, container, options);
    if (located.error) return located.error;
    if (!located.turn) {
      const stop = optionalSignal(selectors, 'stop', null);
      if (stop.error) return stop.error;
      if (stop.active) record.sawGenerating = true;
      const elapsed = Date.now() - record.startedAt;
      return reply('pending', {
        detail: taskDetail(record, {
          reason: stop.active ? 'generating' : 'awaiting-user-turn',
          timedOut: elapsed > options.pendingTimeoutMs,
        }),
      });
    }

    if (!record.verified) {
      record.verified = true;
      record.verifiedAt = Date.now();
    }

    const stop = optionalSignal(selectors, 'stop', null);
    if (stop.error) return stop.error;
    if (stop.active) {
      record.sawGenerating = true;
      const partial = locateAnswer(record, selectors, located.turn.node, container);
      return reply('pending', {
        detail: taskDetail(record, {
          reason: 'generating',
          userTurnIndex: located.index,
          userTurnMatches: located.matchCount,
          partialChars: !partial.error && partial.node ? partial.text.length : 0,
          timedOut: Date.now() - record.startedAt > options.pendingTimeoutMs,
        }),
      });
    }

    const done = optionalSignal(selectors, 'done', null);
    if (done.error) return done.error;
    if (done.active) record.sawDoneMarker = true;

    const sampled = await sampleAnswer(record, selectors, container, located.turn.node, options);
    if (sampled.error) return sampled.error;
    if (sampled.done) {
      record.completedText = sampled.text;
      record.completedAt = Date.now();
      return reply('done', {
        text: sampled.text,
        detail: taskDetail(record, {
          evidence: sampled.evidence,
          userTurnIndex: located.index,
          userTurnMatches: located.matchCount,
          stableMs: sampled.partial ? sampled.partial.stableMs : undefined,
          sampled: sampled.partial ? sampled.partial.observations : undefined,
          completedAt: record.completedAt,
        }),
      });
    }

    return reply('pending', {
      detail: taskDetail(record, {
        reason: sampled.pendingReason,
        userTurnIndex: located.index,
        userTurnMatches: located.matchCount,
        partialChars: sampled.partialChars,
        baselineUsers: record.baseline.userCount,
        baselineAnswers: record.baseline.answerCount,
        rejected: sampled.rejected,
        stableMs: sampled.partial ? sampled.partial.stableMs : undefined,
        sampled: sampled.partial ? sampled.partial.observations : undefined,
        timedOut: Date.now() - record.startedAt > options.pendingTimeoutMs,
      }),
    });
  }

  async function read(state, message) {
    const req = parseCommon(message, false);
    if (req.error) return req.error;
    const denied = authorizeDocument(req.scope);
    if (denied) return denied;

    const containerRes = resolveContainer(req.selectors);
    if (containerRes.error) return containerRes.error;
    const container = containerRes.value;

    const record = state.records.get(req.taskId);
    if (!record) {
      return unknown('task-unknown', {
        taskId: req.taskId,
        url: location.href,
        hint: '页面刷新或换了标签后驱动不保留任务；请打开原页人工接管，不能靠猜。',
      });
    }
    if (record.selectorSignature !== selectorSignature(req.selectors)) {
      return fail('selector-changed', { taskId: req.taskId });
    }
    if (location.href !== record.baseline.href) {
      return unknown('page-changed', { expectedHref: record.baseline.href, actualHref: location.href });
    }

    const overlap = detectOverlap(req.selectors, container);
    if (overlap) return fail('selector-overlap', { which: 'user/answer' });

    return evaluate(record, req.selectors, req.options, container);
  }

  // ---------------------------------------------------------------------------
  // 消息分发与安装
  // ---------------------------------------------------------------------------

  async function dispatch(state, message, sender) {
    if (!isArenaMessage(message)) return fail('bad-message', { reason: 'type' });
    const runtime = getRuntime();
    if (sender && sender.id && runtime && sender.id && sender.id !== runtime.id) {
      return fail('foreign-sender');
    }
    if (message.type === TYPES.probe) return probe(state, message);
    if (message.type === TYPES.submit) return submit(state, message);
    return read(state, message);
  }

  function createState() {
    return {
      version: VERSION,
      records: new Map(),
      chain: Promise.resolve(),
    };
  }

  function install(state) {
    const runtime = getRuntime();
    if (!runtime || !runtime.onMessage) return false;
    const listener = (message, sender, sendResponse) => {
      if (!isArenaMessage(message)) return false;
      runExclusive(state, () => dispatch(state, message, sender)).then(
        (result) => {
          try {
            sendResponse(result);
          } catch (e) {
            /* 端口已关闭 */
          }
        },
        (error) => {
          try {
            sendResponse(fail('internal', { message: String((error && error.message) || error) }));
          } catch (e) {
            /* 端口已关闭 */
          }
        }
      );
      return true; // 异步回应
    };
    try {
      runtime.onMessage.addListener(listener);
      return true;
    } catch (e) {
      return false;
    }
  }

  function boot() {
    let state = globalThis[STATE_KEY];
    if (!state || state.version !== VERSION) {
      state = createState();
      globalThis[STATE_KEY] = state;
      install(state);
    }
    // 手动验收钩子：普通页面（未装扩展）也能用控制台调用同一套逻辑。
    globalThis[HOOK_KEY] = {
      version: VERSION,
      handle: (message) => runExclusive(state, () => dispatch(state, message, null)),
      inspect: () =>
        Array.from(state.records.values()).map((record) => ({
          taskId: record.taskId,
          href: record.baseline.href,
          verified: Boolean(record.verified),
          completed: record.completedText != null,
          startedAt: record.startedAt,
        })),
      reset: () => {
        state.records.clear();
        return true;
      },
    };
  }

  boot();
})();
