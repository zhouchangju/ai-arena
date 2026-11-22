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
 *     options: { sampleMs: 250, stableSamples: 3, stableMs: 600, requireDoneMarker: false },
 *     scope: { origin: 'http://localhost:3000', hrefPrefix: 'http://localhost:3000/' },
 *     verifiedReadPrompt: '同一 taskId 持久化过的发送原文（仅 read，可选）',
 *   }, { frameId: 0 });
 *
 * 每个 selector 既可以是字符串，也可以是有序候选数组（先命中的一组生效）。
 * scope.allowNavigation=true 时，允许同源 SPA 换地址（新建页 → 对话页），
 * 前提是本轮用户消息已经被核对；跨源或未核对时仍返回 unknown/page-changed。
 *
 * scope.href（可选、向后兼容）：本席已核验过的对话地址（origin+path，已规范化，
 * 不含账号/查询串/片段）。给了就要求当前页规范化后完全一致：probe/read 在
 * 授权阶段核对，submit 还会在真正填入前和最后一次点击前各核对一次。不一致
 * 立即返回 conversation-changed（pre-click，不填、不点、不重发）。没给时行为
 * 与旧版完全相同；同源首页 → 首个已核对会话的 SPA 进展不受影响。
 *
 * 回应：{ ok, status, text?, error?, detail? }
 *   status: 'ready' | 'submitted' | 'pending' | 'done' | 'unknown' | 'error'
 *   ok     : 仅 ready / submitted / pending / done 为 true
 *   text   : 仅 done 返回完整回答；pending 只给 detail.preview 正文片段
 *   detail.preview: { text, chars, truncated } 生成中的预览片段（绝不作为回答写入）
 *   error  : 稳定错误码（见 README/交接说明）
 *   detail : 诊断信息（基线计数、拒绝原因、稳定采样结果等），可直接记日志
 *
 * 硬性行为：
 *   1. read 绝不填写、绝不点击发送、绝不改提交内容。唯一允许的页面动作是点开
 *      当前用户消息自身的原生“显示更多/Show more”，以便读到本轮全文；点开后
 *      仍必须逐字等价比对，前缀永远不算送达。
 *   2. submit 前记录基线；只接受“提交后新出现、且文本等于本轮 prompt”的用户消息，
 *      再取其后新出现、且不等于基线旧文本的回答消息。
 *   3. 已有非空且与本轮 prompt 不同的草稿：拒绝（draft-conflict），绝不覆盖。
 *      唯一例外（G1/G3 回环复现的站点缓存恢复）：调用方通过
 *      `knownDraftDigests` 传入**预先算好的 SHA-256**，且当前页必须同时满足
 *      a) 位于 scope.homeHref 的新会话首页；b) 用户消息与回答基线都为 0；
 *      c) 草稿规范化后恰好等于其中某个旧提示摘要。
 *      这时才把它替换成本轮 prompt，并在 detail 里标记
 *      `draftReplaced='known-old-prompt'`。只认摘要，绝不回传历史正文；标题、
 *      前缀、相似文本或其它站点的摘要都不会命中。
 *   4. 同一 taskId 只提交一次；重复 submit 返回当前状态，不重复点击。
 *   5. 发送控件在点击**前**暂时隐藏/缺失/禁用：返回 send-pending，detail 明确
 *      标注 `phase:'pre-click', clickAttempted:false`。调用方可以安全地有限重试。
 *      只要已经调用过 click，之后任何没核对到本轮用户消息的状态一律返回
 *      submit-unconfirmed（detail.possiblySubmitted=true），只能只读复核，绝不重发。
 *   6. 完成证据只认两种：
 *        a) 显式 done 标记可见（排在本轮用户消息之后）+ 文本稳定采样；
 *        b) 亲眼看到 stop 可见，之后 stop 消失 + 文本稳定采样。
 *      站点在 options.requireDoneMarker=true 时只认 a)：即使 stop 曾出现又消失、
 *      文本看起来已经稳定，也必须看到绑定本轮用户消息之后的原生完成控件才能
 *      保存（Gemini 实测会先把“明确判断与主要理由”这类标题稳定展示一段时间）。
 *      没有证据就保持 pending；沉默、截断、部分文本都不算完成。
 *   7. 页面刷新、跨源换地址、历史节点减少：read 返回 unknown，不猜测。
 *      同源 SPA 换地址（新建页 → 对话页）只有在本轮用户消息已核对后才接受。
 *      提交后页面自己换到同源新地址时，read 允许一次只读核对：新地址上必须
 *      出现唯一一条、规范化后与本轮 prompt 完全相同的、位于提交基线之后的
 *      用户消息；核对成功即固定对话上下文（detail.navigation），否则仍返回
 *      page-changed（reason=spa-navigation-unverified）。任何情况都不重发。
 *      唯一例外是已登记的对话地址（ChatGPT https://chatgpt.com/c/<id>、
 *      DeepSeek https://chat.deepseek.com/a/chat/s/<id>）上的
 *      同会话窗口裁切：页面上只留下本轮的候选用户节点时，必须在同一地址、
 *      已点击、该题不在基线、候选节点唯一且排在最后、仍保留的旧用户节点按顺序
 *      等于基线后缀（且确实少了一个）时才核对成功（detail.historyTrimmed）；
 *      回答仍必须排在本轮用户节点之后并排除基线里的全部旧回答文本。
 *      没有可识别旧节点、后缀不匹配或同题多份时保持原判定。其它站点不变。
 *      ChatGPT 前端会先跳到临时路由 /c/local-chatgpt:<uuid>（也可能百分号
 *      编码），再换成稳定 /c/<id>。临时路由不是会话地址：既不能作为
 *      scope.href 的恢复目的地，也不能用于窗口裁切恢复。同源换址仍可
 *      只读经过它，但每换一次地址都必须重新核对唯一本轮用户消息。
 *
 *   8. 只读重建（跨重开/换进程）：页面重载后驱动没有记录时，read 可以带
 *      `verifiedReadPrompt`（原生只在确实持久化过发送意图时才携带）。仅当
 *      scope.href 是一个可信的同站稳定会话地址（非首页、非临时路由；
 *      ChatGPT /c/<id>、DeepSeek /a/chat/s/<id>、Gemini /app/<id>）且当前页
 *      就是它时，才用原文重建一条只读记录：最新用户节点必须唯一、规范化后
 *      与原文全等，回答与完成/生成标记都必须严格排在它之后，再走同一套
 *      稳定采样。重建不会进入发送路径：没有 attempted，后续 submit 只会
 *      返回既有状态。消息暂时没挂载或被窗口裁切时只读重试到 pendingTimeoutMs，
 *      超时返回 unknown/recovery-timeout，由人接管。原文对不上返回
 *      error/task-prompt-mismatch；没有稳定绑定返回 unknown/task-unknown。
 *      已有记录上遇到 user-turn-mismatch / history-changed 且携带原文一致时，
 *      同样在期限内保持 pending（detail.reason=read-recovery-pending），
 *      不因一次没找到就永久停下。
 *
 * 错误码（status:error 时 error 字段）：
 *   bad-message, foreign-sender, not-authorized-page, document-not-ready,
 *   selector-invalid, selector-missing, selector-hidden, selector-ambiguous,
 *   selector-overlap, out-of-scope, conversation-changed, prompt-empty,
 *   prompt-too-long, prompt-already-sent, task-id-conflict, selector-changed,
 *   input-uneditable, input-disabled, input-readonly, draft-conflict, busy,
 *   fill-failed, fill-mismatch, send-pending, send-unavailable,
 *   submit-unconfirmed, user-turn-mismatch, task-prompt-mismatch, internal
 *
 * send-pending（点击前，安全重试）：
 *   detail = { which:'send'|'composer', phase:'pre-click',
 *              clickAttempted:false,
 *              reason:'hidden'|'missing'|'disabled'|'not-clickable'|'composer-changed',
 *              waitedMs? }
 *
 * submit-unconfirmed（可能已点击，只能只读）：
 *   detail = { possiblySubmitted:true, clickAttempted:true, ... }
 *
 * 未知任务（status:unknown 时 error 字段）：
 *   task-unknown（页面重载/丢状态）, page-changed, history-changed,
 *   recovery-timeout（只读重建在期限内仍未挂载）
 *
 * pending 的 detail.reason：
 *   awaiting-user-turn, generating, awaiting-answer, answer-equal-old,
 *   answer-empty, answer-before-user-turn, answer-order-unverified,
 *   answer-updating, answer-disappeared, completion-signal-missing,
 *   read-recovery-pending（只读重建暂缺，detail.transientCode 说明原因）
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
  const MAX_KNOWN_DRAFT_DIGESTS = 8;
  const SELECTOR_KEYS = ['input', 'send', 'user', 'answer', 'stop', 'done', 'container'];
  /**
   * 允许“同会话窗口裁切恢复”的站点，只限 providers.js 里登记过的对话地址：
   *
   *   chatgpt  https://chatgpt.com/c/<id>
   *   deepseek https://chat.deepseek.com/a/chat/s/<id>（会话 ID 非空）
   *
   * 只按当前页地址判断，消息里自报的 provider 不能放宽这里的门禁；
   * 两个站点的新建会话首页（`/`）和任何未登记路径都不适用，
   * 其它站点行为完全不变。
   */
  const CHATGPT_ORIGIN = 'https://chatgpt.com';
  const CHATGPT_CONVERSATION_RE = /^\/c\/[A-Za-z0-9][A-Za-z0-9-]{5,}$/;
  const DEEPSEEK_ORIGIN = 'https://chat.deepseek.com';
  const DEEPSEEK_CONVERSATION_RE = /^\/a\/chat\/s\/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
  const GEMINI_ORIGIN = 'https://gemini.google.com';
  const GEMINI_CONVERSATION_RE = /^\/app\/[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;
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
    previewChars: 800,
    /**
     * false（默认）：stop 出现后又消失 + 文本稳定即可判定完成。
     * true：只认绑定本轮用户消息之后的 done 标记；站点会把短标题先稳定展示，
     *       stop 也可能闪一下就消失，因此不能只凭这两点保存。
     */
    requireDoneMarker: false,
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

  /**
   * SHA-256 of the already-normalized (collapse) prompt. The background
   * computes the same digest from its own archived task prompt, so the page
   * never receives the old prompt text. If Web Crypto is unavailable we fail
   * closed: no draft is ever replaced on that page.
   */
  async function promptDigest(normalized) {
    const subtle = globalThis.crypto && globalThis.crypto.subtle;
    if (!subtle || typeof TextEncoder !== 'function' || typeof normalized !== 'string') {
      return null;
    }
    try {
      const bytes = new TextEncoder().encode(normalized);
      const hash = await subtle.digest('SHA-256', bytes);
      let out = '';
      const view = new Uint8Array(hash);
      for (let index = 0; index < view.length; index += 1) {
        out += view[index].toString(16).padStart(2, '0');
      }
      return out;
    } catch (e) {
      return null;
    }
  }

  /**
   * 允许用来固定会话的地址（与 desktop/SitePane.swift 的白名单同规则）：
   * http(s)、无账号密码、丢弃查询串与片段，只留 origin + 规范化 path。
   * 路径像登录/授权/回调页时返回 null：这类地址既不比对也不保存。
   * 仅供 scope.href 使用，旧调用方不传就完全不受影响。
   */
  function normalizePathname(pathname) {
    const value = (pathname || '/').replace(/\/+$/g, '');
    return value || '/';
  }

  function canonicalHref(value) {
    if (typeof value !== 'string' || !value) return null;
    try {
      const url = new URL(value);
      if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
      if (url.username || url.password) return null;
      const path = normalizePathname(url.pathname);
      if (path.length > 1000 || path.indexOf('//') !== -1) return null;
      const segments = path.split('/').filter(Boolean).map((part) => part.toLowerCase());
      const authentication = [
        'auth', 'authorize', 'callback', 'login', 'logout', 'oauth',
        'signin', 'sign-in', 'signout', 'sign-out', 'sso',
      ];
      if (segments.some((part) => authentication.indexOf(part) !== -1)) return null;
      return url.origin + path;
    } catch (e) {
      return null;
    }
  }

  function newConversationHome(scope) {
    if (!scope || typeof scope.homeHref !== 'string' || !scope.homeHref) return false;
    try {
      const home = new URL(scope.homeHref);
      const here = new URL(location.href);
      if (home.origin !== here.origin) return false;
      return normalizePathname(home.pathname) === normalizePathname(here.pathname);
    } catch (e) {
      return false;
    }
  }

  /**
   * ChatGPT 前端在落稳之前会先给出 `/c/local-chatgpt:<uuid>` 这类临时路由
   * （路径里的冒号也可能是百分号编码，甚至被双重编码）。它不是可保存的
   * 会话地址，也不是恢复目的地。这里按解码后的路径判断，宁可多拒绝。
   */
  function isTemporaryChatGPTConversationPath(pathname) {
    if (typeof pathname !== 'string' || !pathname) return false;
    let decoded = pathname;
    for (let index = 0; index < 2; index += 1) {
      let next;
      try {
        next = decodeURIComponent(decoded);
      } catch (e) {
        break;
      }
      if (next === decoded) break;
      decoded = next;
    }
    return decoded.toLowerCase().indexOf('local-chatgpt') !== -1;
  }

  /**
   * 已登记的对话地址：ChatGPT（`/c/<id>`）与 DeepSeek（`/a/chat/s/<id>`），
   * 都要求无查询串与片段。只有这种“发前就已存在”的对话地址才允许窗口裁切
   * 恢复；两边的新建会话首页和任何其它站点都不适用。
   */
  function chatConversationHref(value) {
    if (typeof value !== 'string' || !value) return false;
    try {
      const url = new URL(value);
      if (url.protocol !== 'https:') return false;
      if (url.search || url.hash) return false;
      if (url.origin === CHATGPT_ORIGIN) {
        if (isTemporaryChatGPTConversationPath(url.pathname)) return false;
        return CHATGPT_CONVERSATION_RE.test(url.pathname);
      }
      if (url.origin === DEEPSEEK_ORIGIN) return DEEPSEEK_CONVERSATION_RE.test(url.pathname);
      return false;
    } catch (e) {
      return false;
    }
  }

  function textOf(node) {
    if (!node) return '';
    if (typeof node.innerText === 'string') return node.innerText;
    return node.textContent || '';
  }

  const EXPAND_CONTROL_LABEL = /^(显示更多|展开全文|展开|收起|Show more|Show less|Read more|Read less)$/i;

  /** The one visible native expander inside a user message, if exactly one. */
  function expandControlOf(node) {
    const controls = Array.from(node.querySelectorAll('button,[role="button"]')).filter(
      (control) => isVisible(control) && EXPAND_CONTROL_LABEL.test(collapse(control.textContent)),
    );
    return controls.length === 1 ? controls[0] : null;
  }

  /**
   * Remove only the trailing UI-only expander marker the page rendered around a
   * long user message. Two different real renderings exist:
   *
   *   full text … Show more   -> the DOM already holds the whole round;
   *   prefix    … Show more   -> only a prefix is rendered.
   *
   * The marker is removed when either the remaining text is *exactly* the
   * expected round (proof of the full message), or the removed suffix carries
   * a real ellipsis (a genuine prefix; never accepted as the full round).
   * A bare trailing label without an ellipsis is only removed when it leaves
   * the exact expected text, so a message genuinely ending in those words is
   * kept intact.
   */
  function stripExpandMarker(text, label, expected) {
    const value = String(text == null ? '' : text);
    if (!label) return value;
    const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const withEllipsis = new RegExp('(?:…|⋯|\\.{3})\\s*' + escaped + '\\s*$', 'i');
    const trimmed = value.replace(withEllipsis, '');
    if (trimmed !== value) return trimmed;
    const plain = new RegExp('\\s*' + escaped + '\\s*$', 'i');
    const withoutLabel = value.replace(plain, '');
    if (withoutLabel !== value && expected && collapse(withoutLabel) === collapse(expected)) {
      return withoutLabel;
    }
    return value;
  }

  /**
   * User-message text as the page actually shows it. For ChatGPT's
   * `data-content-search-unit-key="…:user"` node the visible `innerText` is the
   * evidence (a clone's `textContent` can include hidden/duplicated content),
   * so only the exact native expander suffix is stripped and everything else
   * is compared verbatim.
   */
  function userTextOf(node, expected = '') {
    if (node.localName === 'user-query') {
      const lines = Array.from(node.querySelectorAll('.query-text-line'));
      if (lines.length) return lines.map((line) => line.textContent.trim()).join('\n');
    }
    if (!node.matches('[data-content-search-unit-key$=":user"]')) return textOf(node);
    const visible = textOf(node);
    const control = expandControlOf(node);
    if (!control) return visible;
    const stripped = stripExpandMarker(visible, collapse(control.textContent), expected);
    if (stripped === visible) return visible;
    const shown = collapse(stripped);
    const wanted = collapse(expected);
    if (!wanted || shown === wanted) return stripped;
    // A rendered prefix is still a prefix: expand this one native control and
    // report no text for this sample. The next read compares the full message.
    if (shown && wanted.startsWith(shown)) {
      clickElement(control);
      return '';
    }
    return stripped;
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
    const candidates = Array.isArray(css) ? css : [css];
    for (const candidate of candidates) {
      let nodes;
      try {
        nodes = Array.from((container || document).querySelectorAll(candidate)).filter((node) => node.isConnected);
      } catch (e) {
        continue;
      }
      if (nodes.length) return nodes;
    }
    return [];
  }

  function touchesSelector(node, css) {
    if (!node || !css || !isElement(node)) return false;
    for (const candidate of Array.isArray(css) ? css : [css]) {
      try {
        if (typeof node.matches === 'function' && node.matches(candidate)) return true;
        if (typeof node.closest === 'function' && node.closest(candidate)) return true;
        if (typeof node.querySelector === 'function' && node.querySelector(candidate)) return true;
      } catch (e) {
        /* 下一条候选 */
      }
    }
    return false;
  }

  function selectorSignature(selectors) {
    return SELECTOR_KEYS.map((key) => {
      const value = selectors[key];
      const text = Array.isArray(value) ? value.join(' || ') : (value || '');
      return key + '=' + text;
    }).join('|');
  }

  function selectorText(value) {
    return Array.isArray(value) ? value.join(' || ') : String(value || '');
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
      previewChars: pick('previewChars', DEFAULT_OPTIONS.previewChars, 120, 12000),
      requireDoneMarker: src.requireDoneMarker === true,
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
    if (raw.homeHref !== undefined && raw.homeHref !== null && raw.homeHref !== '') {
      if (typeof raw.homeHref !== 'string' || raw.homeHref.length > 2000) return { error: 'homeHref' };
      scope.homeHref = raw.homeHref;
    }
    // 可选会话约束：已核验的对话地址。规范化后仍不合格就整条拒绝，
    // 绝不解成“只比 origin”。ChatGPT 的临时路由（local-chatgpt:，含编码
    // 形式）不是会话地址：即使旧调用方把它当 href 传来，也在这里失败关闭。
    if (raw.href !== undefined && raw.href !== null && raw.href !== '') {
      if (typeof raw.href !== 'string' || raw.href.length > 2000) return { error: 'href' };
      const canonical = canonicalHref(raw.href);
      if (!canonical) return { error: 'href' };
      try {
        const parsed = new URL(canonical);
        if (parsed.origin === CHATGPT_ORIGIN && isTemporaryChatGPTConversationPath(parsed.pathname)) {
          return { error: 'href-temporary' };
        }
      } catch (e) {
        return { error: 'href' };
      }
      scope.href = canonical;
    }
    if (raw.allowNavigation === true) scope.allowNavigation = true;
    return { value: scope };
  }

  /** Only 64-char hex SHA-256 digests, at most eight, de-duplicated. */
  function parseDraftDigests(raw) {
    if (raw === undefined || raw === null) return { value: [] };
    if (!Array.isArray(raw) || raw.length > MAX_KNOWN_DRAFT_DIGESTS) {
      return { error: 'shape' };
    }
    const out = [];
    for (const item of raw) {
      if (typeof item !== 'string' || !/^[0-9a-f]{64}$/i.test(item)) {
        return { error: 'digest' };
      }
      const digest = item.toLowerCase();
      if (out.indexOf(digest) === -1) out.push(digest);
    }
    return { value: out };
  }

  /**
   * 每个 key 可以是一个字符串，也可以是一组有序候选：先命中的一组生效。
   * 只校验形状与 CSS 语法，不猜测站点结构。
   */
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
      const list = [];
      for (const item of Array.isArray(value) ? value : [value]) {
        if (typeof item !== 'string') {
          return { error: fail('selector-invalid', { which: key, reason: 'not-a-string' }) };
        }
        const css = item.trim();
        if (!css || css.length > MAX_SELECTOR_CHARS) {
          return { error: fail('selector-invalid', { which: key, reason: 'length' }) };
        }
        if (!isValidSelector(css)) {
          return { error: fail('selector-invalid', { which: key, reason: 'css' }) };
        }
        if (list.indexOf(css) === -1) list.push(css);
      }
      if (!list.length) {
        if (REQUIRED_SELECTOR_KEYS.indexOf(key) !== -1) {
          return { error: fail('selector-invalid', { which: key, reason: 'missing' }) };
        }
        continue;
      }
      out[key] = list.length === 1 ? list[0] : list;
    }
    if (selectorText(out.user) === selectorText(out.answer)) {
      return { error: fail('selector-overlap', { which: 'user/answer' }) };
    }
    return { value: out };
  }

  function parseCommon(message, needPrompt) {
    const scope = parseScope(message.scope);
    if (scope.error) {
      return { error: fail('bad-message', { field: 'scope', reason: scope.error }) };
    }
    const draftDigests = parseDraftDigests(message.knownDraftDigests);
    if (draftDigests.error) {
      return {
        error: fail('bad-message', {
          field: 'knownDraftDigests',
          reason: draftDigests.error,
        }),
      };
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
    // 可选、只读：调用方点名要核对「输入框是否正好是本轮完整提示」时才解析。
    // 缺省为 null，既有 probe 回执的形状与语义完全不变。
    let expectedPrompt = null;
    if (message.expectedPrompt !== undefined && message.expectedPrompt !== null) {
      if (typeof message.expectedPrompt !== 'string') {
        return { error: fail('bad-message', { field: 'expectedPrompt' }) };
      }
      if (
        !collapse(message.expectedPrompt) ||
        message.expectedPrompt.length > MAX_PROMPT_CHARS ||
        message.expectedPrompt.indexOf('\u0000') !== -1
      ) {
        return { error: fail('bad-message', { field: 'expectedPrompt' }) };
      }
      expectedPrompt = message.expectedPrompt;
    }
    return {
      taskId: message.taskId,
      prompt: prompt,
      expectedPrompt: expectedPrompt,
      selectors: selectors.value,
      options: parseOptions(message.options),
      scope: scope.value,
      knownDraftDigests: draftDigests.value,
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
      if (scope.href) {
        const here = canonicalHref(location.href);
        if (here !== scope.href) {
          return fail('conversation-changed', {
            expectedHref: scope.href,
            actualHref: here || location.href,
            phase: 'authorize',
            clickAttempted: false,
          });
        }
      }
    }
    return null;
  }

  /**
   * 最后一次真正填入/点击前的地址核对。同源不同对话也算换窗口：
   * 只认规范化后与 scope.href 完全一致，绝不退化成“同 origin 就行”。
   */
  function conversationGate(scope, phase) {
    if (!scope || !scope.href) return null;
    const here = canonicalHref(location.href);
    if (here === scope.href) return null;
    return fail('conversation-changed', {
      expectedHref: scope.href,
      actualHref: here || location.href,
      phase: phase,
      clickAttempted: false,
    });
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
   * 单控件解析。候选按顺序尝试：取第一组“有可见匹配”的候选；
   * 若所有候选都没有可见匹配，则取第一组“有匹配但不可见”的候选做判断。
   * - requireVisible=true：必须恰有一个可见匹配；隐藏的旧节点被忽略。
   * - requireVisible=false（如发送键在空输入时隐藏）：允许隐藏，但多个匹配时必须只有一个是可见的。
   */
  function resolveUnique(selectors, key, container, opts) {
    const requireVisible = !opts || opts.requireVisible !== false;
    const candidates = Array.isArray(selectors[key]) ? selectors[key] : [selectors[key]];
    let hiddenFallback = null;
    for (const candidate of candidates) {
      let all;
      try {
        all = Array.from((container || document).querySelectorAll(candidate)).filter((node) => node.isConnected);
      } catch (e) {
        continue;
      }
      if (!all.length) continue;
      const visible = all.filter(isVisible);
      if (visible.length > 1) {
        return { error: fail('selector-ambiguous', { which: key, visible: visible.length, total: all.length }) };
      }
      if (visible.length === 1) return { value: visible[0], matched: all.length };
      if (!hiddenFallback) hiddenFallback = { all: all.length };
    }
    if (!hiddenFallback) {
      return { error: fail('selector-missing', { which: key, selector: selectorText(selectors[key]) }) };
    }
    if (requireVisible) {
      return { error: fail('selector-hidden', { which: key, total: hiddenFallback.all }) };
    }
    if (hiddenFallback.all === 1) {
      for (const candidate of candidates) {
        let all;
        try {
          all = Array.from((container || document).querySelectorAll(candidate)).filter((node) => node.isConnected);
        } catch (e) {
          continue;
        }
        if (all.length === 1) return { value: all[0], matched: 1 };
      }
    }
    return { error: fail('selector-ambiguous', { which: key, visible: 0, total: hiddenFallback.all }) };
  }

  function optionalSignal(selectors, key, container, after) {
    const css = selectors[key];
    if (!css) return { present: false, active: false, element: null };
    const candidates = Array.isArray(css) ? css : [css];
    let lastTotal = 0;
    for (const candidate of candidates) {
      let all;
      try {
        all = Array.from((container || document).querySelectorAll(candidate)).filter((node) => node.isConnected);
      } catch (e) {
        return { error: fail('selector-invalid', { which: key }) };
      }
      if (!all.length) continue;
      lastTotal = all.length;
      const visible = all.filter((node) => isVisible(node)
        && (!after || compareOrder(node, after) === 'after'));
      if (visible.length > 1) {
        if (after && key === 'done') return { present: true, active: true, element: visible[0] };
        return { error: fail('selector-ambiguous', { which: key, visible: visible.length, total: all.length }) };
      }
      if (!visible.length && after) continue;
      return { present: true, active: visible.length === 1, element: visible[0] || null };
    }
    return { present: lastTotal > 0, active: false, element: null };
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
      userTexts: users.map((node) => collapse(userTextOf(node))),
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
   * 同会话窗口裁切恢复（只对已登记的对话地址生效：ChatGPT `/c/<id>`、
   * DeepSeek `/a/chat/s/<id>`）。
   *
   * 真实站点会虚拟化长对话：发送后，最早的用户消息和回答被移出 DOM，
   * 于是“提交基线之后的新节点”可能一个都不剩（总数甚至少于基线），
   * 本轮用户消息明明在页面上却一直 verifying。这里只做保守的只读核对：
   *
   *   1. 页面仍是本任务发前就已存在的已登记对话地址（同址、未换址、未换源）；
   *   2. 点击已发生（记录存在即已点击）；
   *   3. 页面上规范化后与本轮 prompt 全等的用户节点必须唯一，并排在最后；
   *   4. 该题在提交基线里没出现过（否则分不清新旧）；
   *   5. 仍留在页面上的旧用户节点必须按顺序等于基线用户文本的后缀，且确实
   *      至少少了一个（必须还有可识别的旧节点）。
   *
   * 没有可识别旧节点、后缀不匹配、同一题出现多份、不是最后一轮 → 不接管，
   * 调用方保持原来的 pending / history-changed。回答侧见 locateAnswer 的
   * allNodes 分支：必须排在本轮用户节点之后，并排除基线里的旧回答文本。
   */
  function locateTrimmedTurn(record, selectors, container) {
    if (!record.attempted) return { applies: false };
    if (record.navigationCount) return { applies: false };
    if (location.href !== record.baseline.href) return { applies: false };
    if (!chatConversationHref(record.baseline.href)) return { applies: false };
    if (record.baseline.userTexts.indexOf(record.promptCollapsed) !== -1) {
      return { applies: true, declined: 'prompt-in-baseline' };
    }
    const users = listNodes(selectors.user, container);
    const items = users.map((node, index) => {
      const raw = userTextOf(node, record.promptCollapsed);
      return {
        node: node,
        index: index,
        text: cleanText(raw),
        collapsed: collapse(raw),
        chrome: touchesSelector(node, selectors.input) || touchesSelector(node, selectors.send),
      };
    });
    const matches = items.filter((item) => item.collapsed === record.promptCollapsed && !item.chrome);
    if (matches.length > 1) return { applies: true, declined: 'prompt-not-unique' };
    if (!matches.length) return { applies: true, pending: true };
    const turn = matches[0];
    if (turn.index !== items.length - 1) return { applies: true, declined: 'not-last-user' };
    const kept = items.filter((item) => item.index !== turn.index);
    if (!kept.length) return { applies: true, declined: 'no-known-history' };
    const baselineTexts = record.baseline.userTexts;
    const offset = baselineTexts.length - kept.length;
    if (offset <= 0) return { applies: true, declined: 'no-eviction' };
    for (let index = 0; index < kept.length; index += 1) {
      if (baselineTexts[offset + index] !== kept[index].collapsed) {
        return { applies: true, declined: 'history-mismatch' };
      }
    }
    return {
      applies: true,
      turn: turn,
      index: turn.index,
      matchCount: 1,
      trimmed: true,
      trimmedEvidence: { evictedUsers: offset, keptUsers: kept.length },
    };
  }

  /**
   * 只认提交基线之后新出现的用户消息，且其文本必须等于本轮 prompt。
   * 有新的用户消息但文本不符 → user-turn-mismatch（失败关闭），不退化成“取最后一条”。
   * 历史节点变少或一个不剩时，先试一次同会话窗口裁切恢复；不适用时保持原判定。
   */
  function locateUserTurn(record, selectors, container, options) {
    const users = listNodes(selectors.user, container);
    if (users.length < record.baseline.userCount) {
      const trimmed = locateTrimmedTurn(record, selectors, container);
      if (trimmed.turn) return trimmed;
      if (trimmed.pending) return { pending: true, turn: null, trimmedPending: true };
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
      const raw = userTextOf(node, record.promptCollapsed);
      fresh.push({
        node: node,
        index: index,
        text: cleanText(raw),
        collapsed: collapse(raw),
        chrome: touchesSelector(node, selectors.input) || touchesSelector(node, selectors.send),
      });
    }
    if (!fresh.length) {
      const trimmed = locateTrimmedTurn(record, selectors, container);
      if (trimmed.turn) return trimmed;
      return { pending: true, turn: null };
    }
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
   *
   * allNodes=true 时（仅同会话窗口裁切恢复使用）忽略“只从基线计数之后找”：
   * 窗口裁切会让回答总数不再单调增长，所以从所有当前 DOM 节点里筛，
   * 但仍然要求严格排在本轮用户节点之后，并排除基线里的全部旧回答文本，
   * 因此旧答案永远不会被当成本轮结果。
   */
  function locateAnswer(record, selectors, userNode, container, allNodes) {
    const answers = listNodes(selectors.answer, container);
    if (!allNodes && answers.length < record.baseline.answerCount) {
      return {
        error: unknown('history-changed', {
          expectedAnswers: record.baseline.answerCount,
          actualAnswers: answers.length,
        }),
      };
    }
    const start = allNodes ? 0 : record.baseline.answerCount;
    const rejected = { empty: 0, equalOld: 0, beforeTurn: 0, touching: 0, chrome: 0, orderUnverified: 0 };
    for (let index = start; index < answers.length; index += 1) {
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
      requireDoneMarker: Boolean(record.requireDoneMarker),
      elapsedMs: Date.now() - record.startedAt,
      url: location.href,
      href: canonicalHref(location.href),
      contextHref: record.contextHref || record.baseline.href,
    };
    if (record.navigation) {
      detail.navigation = {
        from: record.navigation.from,
        to: record.navigation.to,
        firstRoute: Boolean(record.navigation.firstRoute),
        at: record.navigation.at,
      };
    }
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

  /**
   * 生成中的正文片段只作预览：有界、标明总长度与是否截断。
   * 调用方不得把它当作完成回答写入；正式回答只在 status=done 的 text 里。
   */
  function answerPreview(text, limit) {
    const value = cleanText(text);
    if (!value) return undefined;
    if (value.length <= limit) {
      return { text: value, chars: value.length, truncated: false };
    }
    return { text: value.slice(-limit), chars: value.length, truncated: true };
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
    // Some public composers mount the send button only after text is entered.
    if (sendRes.error && !(req.scope?.allowNavigation && sendRes.error.error === 'selector-missing')) {
      return sendRes.error;
    }
    const send = sendRes.value;

    const stop = optionalSignal(req.selectors, 'stop', null);
    if (stop.error) return stop.error;
    const done = req.scope?.allowNavigation ? { present: false, active: false }
      : optionalSignal(req.selectors, 'done', null);
    if (done.error) return done.error;

    const overlap = detectOverlap(req.selectors, container);
    if (overlap) return fail('selector-overlap', { which: 'user/answer' });

    const users = listNodes(req.selectors.user, container);
    const answers = listNodes(req.selectors.answer, container);
    const draft = cleanText(composerText(composerRoot(input)));
    const record = state.records.get(req.taskId) || null;
    const composer = {
      kind: kind,
      draftChars: draft.length,
      draftEmpty: !collapse(draft),
      enabled: elementEnabled(input),
    };
    // 只读比对：只有调用方带 expectedPrompt 时才多返回一个布尔值；它用与
    // submit 相同的规范化 sameText，绝不写入输入框，也不授权点击。
    if (req.expectedPrompt !== null) {
      composer.matchesExpectedPrompt = sameText(draft, req.expectedPrompt);
    }

    return reply('ready', {
      detail: {
        version: VERSION,
        taskId: req.taskId,
        url: location.href,
        href: canonicalHref(location.href),
        frame: window.top === window ? 'top' : 'sub',
        composer: composer,
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

  /**
   * Wait only for the visibility/enabled state **before any click**. Every
   * outcome here is explicitly `pre-click`; a missing or hidden send control is
   * safe for the background to retry. Ambiguous/invalid selectors still fail
   * closed and are not retried as if they were a transient visibility change.
   */
  async function waitForSend(selectors, options) {
    const startedAt = Date.now();
    const deadline = startedAt + options.sendEnableMs;
    let lastReason = 'missing';
    while (true) {
      const resolved = resolveUnique(selectors, 'send', null, { requireVisible: true });
      if (!resolved.error) {
        if (elementEnabled(resolved.value)) return { value: resolved.value };
        lastReason = 'disabled';
      } else if (resolved.error.error === 'selector-hidden') {
        lastReason = 'hidden';
      } else if (resolved.error.error === 'selector-missing') {
        lastReason = 'missing';
      } else {
        return { error: resolved.error };
      }
      if (Date.now() >= deadline) {
        return {
          error: fail('send-pending', {
            which: 'send',
            phase: 'pre-click',
            clickAttempted: false,
            reason: lastReason,
            waitedMs: Date.now() - startedAt,
          }),
        };
      }
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

  /**
   * The only accepted non-empty draft is an exact old Arena prompt on a blank
   * new-conversation page. We compare a SHA-256 of the normalized draft with
   * the background's precomputed digests, so the page never sees old text.
   */
  async function knownOldDraft(req, draftCollapsed, users, answers) {
    if (!req.knownDraftDigests || req.knownDraftDigests.length === 0) return null;
    if (users.length !== 0 || answers.length !== 0) return null;
    if (!newConversationHome(req.scope)) return null;
    const digest = await promptDigest(draftCollapsed);
    if (!digest) return null;
    return req.knownDraftDigests.indexOf(digest) === -1 ? null : digest;
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
    const users = listNodes(req.selectors.user, container);
    const answers = listNodes(req.selectors.answer, container);
    let draftDigest = null;
    let draftReplaced = false;
    if (draftCollapsed && draftCollapsed !== promptCollapsed) {
      draftDigest = await knownOldDraft(
        req,
        draftCollapsed,
        users,
        answers,
      );
      if (!draftDigest) {
        return fail('draft-conflict', { draftChars: cleanText(draft).length });
      }
      // Exact known old prompt on a blank new-conversation home page: replace
      // only now, and only with this round's prompt.
      draftReplaced = true;
    }

    // 刷新/丢状态后，最后一条用户消息已经等于本轮 prompt：多半是重复发送，失败关闭。
    if (users.length) {
      const lastUser = collapse(userTextOf(users[users.length - 1]));
      if (lastUser && lastUser === promptCollapsed) {
        return fail('prompt-already-sent', { historyUsers: users.length });
      }
    }

    const busy = checkBusy(state, req.selectors, container, req.taskId);
    if (busy) return busy;

    // 只有空输入或内容已完全一致才写；绝不覆盖不同草稿。
    // 真正填入前再核对一次会话地址：上面算摘要/等控件期间用户可能已经换窗口。
    const beforeFill = conversationGate(req.scope, 'pre-fill');
    if (beforeFill) return beforeFill;
    let filled = false;
    if (draftCollapsed !== promptCollapsed) {
      const write = setComposerValue(input, req.prompt);
      if (!write.ok) {
        // 写失败时尽量还原：空输入回到空；已知旧提示回到原草稿。
        if (!draftCollapsed) setComposerValue(input, '');
        else if (draftReplaced) setComposerValue(input, draft);
        return fail(write.code, write.detail);
      }
      filled = true;
      await sleep(60);
      if (!sameText(composerText(composerRoot(input)), req.prompt)) {
        if (!draftCollapsed) setComposerValue(input, '');
        else if (draftReplaced) setComposerValue(input, draft);
        return fail('fill-mismatch', { phase: 'after-fill' });
      }
    }

    const sendRes = await waitForSend(req.selectors, req.options);
    if (sendRes.error) return sendRes.error;
    const send = sendRes.value;

    // Re-check the exact composer text immediately before the click. If a site
    // restored/cleared it while the send control was appearing, do not click:
    // report a pre-click failure so the caller can retry from the top, where
    // the draft rules (empty / known old prompt / human draft) are applied.
    if (!sameText(composerText(composerRoot(input)), req.prompt)) {
      return fail('send-pending', {
        which: 'composer',
        phase: 'pre-click',
        clickAttempted: false,
        reason: 'composer-changed',
      });
    }

    // 最后一次点击前的地址核对。等发送控件期间页面仍可能被换到同站别的
    // 对话；只要不是本席核验过的地址就停在这里（不点、不建基线、不重发）。
    const beforeClick = conversationGate(req.scope, 'pre-click');
    if (beforeClick) return beforeClick;

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
      lastHref: location.href,
      contextHref: null,
      navigation: null,
      navigationCount: 0,
      allowNavigation: Boolean(req.scope && req.scope.allowNavigation),
      requireDoneMarker: req.options.requireDoneMarker === true,
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
      completedHref: null,
    };
    remember(state, record);

    if (!clickElement(send)) {
      state.records.delete(req.taskId);
      // clickElement() never reached the page's click handler: still pre-click.
      return fail('send-pending', {
        which: 'send',
        phase: 'pre-click',
        clickAttempted: false,
        reason: 'not-clickable',
      });
    }

    const located = await waitForUserTurn(record, req.selectors, container, req.options);
    if (located.error) {
      return fail('submit-unconfirmed', {
        cause: located.error.error, possiblySubmitted: true, clickAttempted: true,
      });
    }
    if (located.timeout) {
      const stop = optionalSignal(req.selectors, 'stop', null);
      const stopActive = !stop.error && stop.active;
      const inputNow = resolveUnique(req.selectors, 'input', null, { requireVisible: true });
      const stillPrompt = !inputNow.error && sameText(composerText(composerRoot(inputNow.value)), req.prompt);
      const sendNow = resolveUnique(req.selectors, 'send', null, { requireVisible: false });
      const sendReady = !sendNow.error && elementEnabled(sendNow.value);
      // A click was attempted. Even when the composer still looks unchanged,
      // that is not proof the page ignored it (async handlers/SPA routing).
      // Never treat this as safe to resend: keep the record and report it as
      // possibly submitted so the caller only reads from here on.
      return fail('submit-unconfirmed', {
        possiblySubmitted: true,
        clickAttempted: true,
        timeoutMs: req.options.submitTimeoutMs,
        stopActive: stopActive,
        composerStillPrompt: stillPrompt,
        sendReady: sendReady,
      });
    }

    record.verified = true;
    record.verifiedAt = Date.now();
    const stop = optionalSignal(req.selectors, 'stop', null);
    if (!stop.error && stop.active) record.sawGenerating = true;
    const answer = locateAnswer(record, req.selectors, located.value.turn.node, container, located.value.trimmed);
    const preview = answerPreview(!answer.error && answer.node ? answer.text : '', req.options.previewChars);
    return reply('submitted', {
      detail: {
        taskId: req.taskId,
        filled: filled,
        draftReplaced: draftReplaced ? 'known-old-prompt' : undefined,
        userTurnIndex: located.value.index,
        userTurnMatches: located.value.matchCount,
        historyTrimmed: located.value.trimmed ? located.value.trimmedEvidence : undefined,
        answerDetected: Boolean(!answer.error && answer.node),
        sawGenerating: Boolean(record.sawGenerating),
        elapsedMs: Date.now() - record.startedAt,
        url: location.href,
        href: canonicalHref(location.href),
        userTurnVerified: true,
        preview: preview,
      },
    });
  }

  // ---------------------------------------------------------------------------
  // read / evaluate
  // ---------------------------------------------------------------------------

  /**
   * 完成标记必须绑定到本轮用户消息之后：
   * - allowNavigation 的站点（同一会话里旧回答与新回答并存）一直如此；
   * - requireDoneMarker 的站点更严格：任何被当作完成证据的标记都必须排在本轮
   *   用户消息之后，否则上一轮工具栏的闪现会让本轮提前结束；
   * - 只读重建的任务没有提交基线可依赖，完成控件同样必须在本轮用户节点之后。
   */
  function doneAnchor(record, userNode) {
    return record.allowNavigation || record.requireDoneMarker || record.readOnlyRecovery ? userNode : null;
  }

  async function sampleAnswer(record, selectors, container, userNode, options, allNodes) {
    let located = locateAnswer(record, selectors, userNode, container, allNodes);
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
        return { pendingReason: 'generating', partialChars: text.length, previewText: text };
      }

      const done = optionalSignal(selectors, 'done', null, doneAnchor(record, userNode));
      if (done.error) return { error: done.error };
      if (done.active) {
        record.sawDoneMarker = true;
        sawMarker = true;
      }

      const again = locateAnswer(record, selectors, userNode, container, allNodes);
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
      return { pendingReason: 'answer-updating', partial: partial, partialChars: text.length, previewText: text };
    }

    const stopNow = optionalSignal(selectors, 'stop', null);
    if (stopNow.error) return { error: stopNow.error };
    if (stopNow.active) {
      record.sawGenerating = true;
      return { pendingReason: 'generating', partial: partial, partialChars: text.length, previewText: text };
    }

    if (record.requireDoneMarker) {
      // 站点要求原生完成控件：stop 出现又消失、文本暂时稳定都不算完成。
      // 标记必须此刻仍可见，并且排在本轮用户消息之后（doneAnchor）。
      const marker = optionalSignal(selectors, 'done', null, doneAnchor(record, userNode));
      if (marker.error) return { error: marker.error };
      if (!marker.active) {
        return {
          pendingReason: 'completion-signal-missing',
          partial: partial,
          partialChars: text.length,
          previewText: text,
        };
      }
      record.sawDoneMarker = true;
      return { done: true, text: text, evidence: 'done-marker', partial: partial };
    }
    if (record.sawGenerating) {
      return { done: true, text: text, evidence: 'stop-observed', partial: partial };
    }
    if (sawMarker) {
      return { done: true, text: text, evidence: 'done-marker', partial: partial };
    }
    return { pendingReason: 'completion-signal-missing', partial: partial, partialChars: text.length, previewText: text };
  }

  async function evaluate(record, selectors, options, container) {
    // 已完成的任务保持幂等；但只对完成时所在的那个地址生效。同源换址
    // （首页 → 临时路由 → 正式对话）之后必须在新页面上重新核对本轮用户
    // 消息和对应回答，不能把上一地址的缓存正文直接当作本页结果。
    if (record.completedText != null && record.completedHref === location.href) {
      return reply('done', {
        text: record.completedText,
        detail: {
          taskId: record.taskId,
          source: 'recorded',
          completedAt: record.completedAt,
          userTurnVerified: true,
          url: location.href,
          href: canonicalHref(location.href),
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
          userTurnVerified: false,
          timedOut: elapsed > options.pendingTimeoutMs,
        }),
      });
    }

    if (!record.verified) {
      record.verified = true;
      record.verifiedAt = Date.now();
    }
    if (!record.contextHref) record.contextHref = location.href;

    const stop = optionalSignal(selectors, 'stop', null);
    if (stop.error) return stop.error;
    if (stop.active) {
      record.sawGenerating = true;
      const partial = locateAnswer(record, selectors, located.turn.node, container, located.trimmed);
      const previewText = !partial.error && partial.node ? partial.text : '';
      return reply('pending', {
        detail: taskDetail(record, {
          reason: 'generating',
          userTurnIndex: located.index,
          userTurnMatches: located.matchCount,
          partialChars: previewText.length,
          preview: answerPreview(previewText, options.previewChars),
          timedOut: Date.now() - record.startedAt > options.pendingTimeoutMs,
        }),
      });
    }

    const done = optionalSignal(selectors, 'done', null, doneAnchor(record, located.turn.node));
    if (done.error) return done.error;
    if (done.active) record.sawDoneMarker = true;

    const verifiedHref = location.href;
    const sampled = await sampleAnswer(record, selectors, container, located.turn.node, options, located.trimmed);
    if (verifiedHref !== location.href) {
      return unknown('page-changed', {reason: 'navigation-during-sampling'});
    }
    if (sampled.error) return sampled.error;
    if (!located.turn.node.isConnected ||
        collapse(userTextOf(located.turn.node, record.promptCollapsed)) !== record.promptCollapsed) {
      return unknown('history-changed', {reason: 'user-turn-changed-during-sampling'});
    }
    if (sampled.done) {
      record.completedText = sampled.text;
      record.completedAt = Date.now();
      record.completedHref = location.href;
      return reply('done', {
        text: sampled.text,
        detail: taskDetail(record, {
          evidence: sampled.evidence,
          userTurnIndex: located.index,
          userTurnMatches: located.matchCount,
          historyTrimmed: located.trimmed ? located.trimmedEvidence : undefined,
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
        historyTrimmed: located.trimmed ? located.trimmedEvidence : undefined,
        partialChars: sampled.partialChars,
        preview: answerPreview(sampled.previewText, options.previewChars),
        baselineUsers: record.baseline.userCount,
        baselineAnswers: record.baseline.answerCount,
        rejected: sampled.rejected,
        stableMs: sampled.partial ? sampled.partial.stableMs : undefined,
        sampled: sampled.partial ? sampled.partial.observations : undefined,
        timedOut: Date.now() - record.startedAt > options.pendingTimeoutMs,
      }),
    });
  }

  /**
   * 同源换址的只读核对（G3）。
   *
   * 真实站点会在点击发送后把“新建页”换成“对话页”（chatgpt.com/ → /c/<id>、
   * deepseek /a/chat/ → /a/chat/s/<id>），提交结果还没来得及核对，地址就变了。
   * 这里允许**一次只读核对**：新地址上必须出现唯一一条、规范化后与本轮
   * prompt 完全相同的用户消息，且位于提交基线之后。
   *
   * 没有放宽的部分：
   *   - 只对 scope 声明 allowNavigation 的同源换址生效，跨源仍返回 page-changed；
   *   - 只做精确匹配（collapse 后全等），不做前缀、相似度或“取最后一条”；
   *   - 多条相同消息（可能重复发送）视为不确定，保持 unknown；
   *   - 不填写、不点击、不重发；核对成功只把上下文固定到记录上。
   */
  async function recoverSameOriginNavigation(record, selectors, container, options) {
    const startedAt = Date.now();
    const graceMs = Math.min(3000, Math.max(options.turnGraceMs, 1200));
    let located = null;
    let waitedMs = 0;
    while (true) {
      located = locateUserTurn(record, selectors, container, options);
      if (located.error) return { error: located.error };
      waitedMs = Date.now() - startedAt;
      if (located.turn && located.matchCount === 1) break;
      if (located.turn && located.matchCount > 1) {
        return { verified: false, ambiguous: true, matchCount: located.matchCount, waitedMs: waitedMs };
      }
      if (waitedMs >= graceMs) return { verified: false, waitedMs: waitedMs };
      await sleep(options.pollMs);
    }

    const href = location.href;
    const previousHref = record.lastHref || record.baseline.href;
    record.navigationCount = (record.navigationCount || 0) + 1;
    record.verified = true;
    record.verifiedAt = Date.now();
    record.lastHref = href;
    record.contextHref = href;
    record.navigation = {
      from: previousHref,
      to: href,
      firstRoute: record.navigationCount === 1 && previousHref === record.baseline.href,
      evidence: 'same-origin-user-turn',
      userTurnIndex: located.index,
      at: record.verifiedAt,
    };
    return {
      verified: true,
      userTurnIndex: located.index,
      firstRoute: record.navigation.firstRoute,
      waitedMs: waitedMs,
    };
  }

  // ---------------------------------------------------------------------------
  // read：同一已绑定会话上的只读重建与暂缺恢复（G1/G3）
  // ---------------------------------------------------------------------------

  /**
   * 可信的稳定对话地址：与 desktop/SitePane.swift 的绑定白名单同规则，
   * 只认三家已登记的会话路径，且排除临时路由（ChatGPT local-chatgpt:）。
   * Gemini 的 `/app/<id>` 与 DeepSeek 的 `/a/chat/s/<id>` 同样适用。
   */
  function stableConversationHref(value) {
    const canonical = canonicalHref(value);
    if (!canonical) return null;
    try {
      const url = new URL(canonical);
      if (url.protocol !== 'https:') return null;
      if (url.search || url.hash) return null;
      if (url.origin === CHATGPT_ORIGIN) {
        if (isTemporaryChatGPTConversationPath(url.pathname)) return null;
        return CHATGPT_CONVERSATION_RE.test(url.pathname) ? canonical : null;
      }
      if (url.origin === DEEPSEEK_ORIGIN) {
        return DEEPSEEK_CONVERSATION_RE.test(url.pathname) ? canonical : null;
      }
      if (url.origin === GEMINI_ORIGIN) {
        return GEMINI_CONVERSATION_RE.test(url.pathname) ? canonical : null;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /**
   * 只读重建的唯一入口：当前页必须就是本席传入的那个稳定会话地址
   * （scope.href，已由原生按白名单核验），同源、非新建首页、非临时路由。
   * 任何一个条件缺失都返回 null，调用方只能回到 task-unknown。
   */
  function stableReadBinding(req) {
    const scope = req.scope;
    if (!scope || !scope.href) return null;
    const canonical = canonicalHref(location.href);
    if (!canonical || canonical !== scope.href) return null;
    try {
      if (scope.origin && new URL(canonical).origin !== scope.origin) return null;
    } catch (e) {
      return null;
    }
    if (scope.homeHref) {
      const home = canonicalHref(scope.homeHref);
      if (home && home === canonical) return null;
    }
    return stableConversationHref(canonical);
  }

  /** `verifiedReadPrompt` 只允许出现在 read 上，且必须是完整的原文。 */
  function readRecoveryPrompt(message) {
    const raw = message.verifiedReadPrompt;
    if (raw === undefined || raw === null || raw === '') return { value: null };
    if (typeof raw !== 'string' || raw.length > MAX_PROMPT_CHARS) {
      return { error: fail('bad-message', { field: 'verifiedReadPrompt' }) };
    }
    if (raw.indexOf('\u0000') !== -1 || !collapse(raw)) {
      return { error: fail('bad-message', { field: 'verifiedReadPrompt', reason: 'empty' }) };
    }
    return { value: raw };
  }

  /**
   * 页面重载/换进程后驱动不保留记录。只有原生确实持久化过发送意图、
   * 仍然绑定同一稳定会话时，才允许用原文重建一个**只读**记录：
   * attempted=false，之后的 submit 只会走既有记录的 evaluate，绝不会再点击。
   */
  function createReadOnlyRecoveryRecord(req, prompt) {
    const now = Date.now();
    return {
      taskId: req.taskId,
      prompt: prompt,
      promptCollapsed: collapse(prompt),
      selectorSignature: selectorSignature(req.selectors),
      selectors: req.selectors,
      baseline: {
        userCount: 0,
        answerCount: 0,
        userTexts: [],
        answerTexts: [],
        href: location.href,
        at: now,
      },
      href: location.href,
      lastHref: location.href,
      contextHref: location.href,
      navigation: null,
      navigationCount: 0,
      allowNavigation: false,
      requireDoneMarker: true,
      startedAt: now,
      attempted: false,
      readOnlyRecovery: true,
      recoverySince: now,
      verified: false,
      verifiedAt: null,
      sawGenerating: false,
      sawDoneMarker: false,
      lastAnswerText: null,
      stableSince: null,
      completedText: null,
      completedAt: null,
      completedHref: null,
    };
  }

  /**
   * 用当前页面构造“提交基线”，好让既有 locateUserTurn/locateAnswer/evaluate
   * 全部复用，而不另写一套采样：
   *   - 最新用户节点必须唯一、与原文规范化后全等，并且就是最后一个用户节点；
   *   - 它之前的全部用户/回答都进入基线，回答必须严格排在它之后。
   * 任何一条不满足都只返回 pending（稍后只读重试），绝不猜、绝不点击。
   */
  function prepareRecoveryBaseline(record, selectors, container) {
    const users = listNodes(selectors.user, container);
    if (!users.length) return { pending: true };
    const items = users.map((node, index) => {
      const raw = userTextOf(node, record.promptCollapsed);
      return {
        node: node,
        index: index,
        collapsed: collapse(raw),
        chrome: touchesSelector(node, selectors.input) || touchesSelector(node, selectors.send),
      };
    });
    const matches = items.filter((item) => item.collapsed === record.promptCollapsed && !item.chrome);
    if (!matches.length) return { pending: true };
    if (matches.length > 1) return { pending: true, duplicate: matches.length };
    const turn = matches[0];
    if (turn.index !== items.length - 1) return { pending: true, notLast: true };
    const answers = listNodes(selectors.answer, container);
    const before = answers.filter((answer) => compareOrder(answer, turn.node) !== 'after');
    record.baseline = {
      userCount: turn.index,
      answerCount: before.length,
      userTexts: items.slice(0, turn.index).map((item) => item.collapsed),
      answerTexts: before.map((answer) => collapse(textOf(answer))),
      href: record.baseline.href,
      at: Date.now(),
    };
    return { ok: true, index: turn.index };
  }

  /**
   * 只读的“暂缺”状态：消息还没挂载、窗口裁切或 DOM 正在重排时，一次读不到
   * 不代表任务失败。限定在 pendingTimeoutMs 内继续 pending，超时才报
   * recovery-timeout 交人工。绝不填入、绝不点击、绝不重发。
   */
  function recoveryHold(record, options, extra) {
    const now = Date.now();
    if (!record.recoverySince) record.recoverySince = now;
    const waited = now - record.recoverySince;
    if (waited > options.pendingTimeoutMs) {
      return unknown('recovery-timeout', Object.assign({
        taskId: record.taskId,
        waitedMs: waited,
        url: location.href,
      }, extra));
    }
    return reply('pending', {
      detail: Object.assign({
        taskId: record.taskId,
        reason: 'read-recovery-pending',
        userTurnVerified: false,
        waitedMs: waited,
        timedOut: false,
        url: location.href,
        href: canonicalHref(location.href),
      }, extra),
    });
  }

  /** 已有记录上的暂时失配（临时未挂载/裁切）也只读重试到期限。 */
  function holdTransientMiss(record, options, result) {
    const code = result && result.error;
    const transient = (result.status === 'error' && code === 'user-turn-mismatch')
      || (result.status === 'unknown' && code === 'history-changed');
    if (!transient) return result;
    return recoveryHold(record, options, {
      transientCode: code,
      cause: 'unmounted-or-clipped',
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

    const recoveryPrompt = readRecoveryPrompt(message);
    if (recoveryPrompt.error) return recoveryPrompt.error;
    const expectedPrompt = recoveryPrompt.value;

    let record = state.records.get(req.taskId);
    if (!record && expectedPrompt) {
      // 只有“原生确实持久化过发送意图 + 仍是同一稳定会话”才重建记录；
      // 重建出来的记录只读，没有 attempted，后续 submit 也不会再点击。
      if (!stableReadBinding(req)) {
        return unknown('task-unknown', {
          taskId: req.taskId,
          url: location.href,
          hint: '没有稳定的已绑定会话地址（非首页、非临时路由）可供只读重建；请打开原页人工核对。',
        });
      }
      record = createReadOnlyRecoveryRecord(req, expectedPrompt);
      remember(state, record);
    }
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
    const canHold = Boolean(expectedPrompt) && record.promptCollapsed === collapse(expectedPrompt);
    if (expectedPrompt && !canHold) {
      // 同一 taskId 的原文对不上：绝不把另一轮的用户消息认成本轮。
      return fail('task-prompt-mismatch', { taskId: req.taskId });
    }

    if (record.readOnlyRecovery) {
      // 每轮先用当前页面重建基线；消息暂时没挂载/被裁切时继续只读等待。
      const prepared = prepareRecoveryBaseline(record, req.selectors, container);
      if (!prepared.ok) {
        return recoveryHold(record, req.options, {
          duplicateUserTurns: prepared.duplicate,
          turnNotLast: prepared.notLast,
        });
      }
    }

    const currentHref = location.href;
    const trackedHref = record.lastHref || record.baseline.href;
    if (currentHref !== record.baseline.href) {
      let sameOrigin = false;
      try {
        sameOrigin = new URL(currentHref).origin === new URL(record.baseline.href).origin;
      } catch (e) {
        sameOrigin = false;
      }
      if (!record.allowNavigation || !sameOrigin) {
        return unknown('page-changed', { expectedHref: record.baseline.href, actualHref: currentHref });
      }
      if (currentHref !== trackedHref || !record.verified) {
        // 提交后页面自己换了同源地址（首页 → 临时路由 → 正式对话）：每次换址
        // 都只读重新核对唯一本轮用户消息，绝不重发。上一地址已核对过也不能
        // 沿用：临时路由（ChatGPT local-chatgpt:）不能被当成本轮上下文。
        const recovery = await recoverSameOriginNavigation(record, req.selectors, container, req.options);
        if (recovery.error) return recovery.error;
        if (!recovery.verified) {
          return unknown('page-changed', {
            reason: 'spa-navigation-unverified',
            expectedHref: record.baseline.href,
            actualHref: currentHref,
            waitedMs: recovery.waitedMs,
          });
        }
      }
      record.lastHref = currentHref;
    }

    const overlap = detectOverlap(req.selectors, container);
    if (overlap) return fail('selector-overlap', { which: 'user/answer' });

    const result = await evaluate(record, req.selectors, req.options, container);
    // A live renderer can evict the same nodes as a reloaded renderer. If
    // this attempt still cannot locate the round, apply the same strict
    // bound-conversation recovery without waiting for an app restart.
    const reason = result.detail && result.detail.reason;
    const lostWindow = result.error === 'history-changed' || result.error === 'user-turn-mismatch'
      || (result.status === 'pending' && (result.detail?.userTurnVerified === false || reason === 'awaiting-answer'));
    if (lostWindow && canHold && !record.readOnlyRecovery && stableReadBinding(req)
        && !record.baseline.userTexts.includes(record.promptCollapsed)) {
      const recovered = createReadOnlyRecoveryRecord(req, expectedPrompt);
      if (prepareRecoveryBaseline(recovered, req.selectors, container).ok) {
        remember(state, recovered);
        return evaluate(recovered, req.selectors, req.options, container);
      }
    }
    return canHold ? holdTransientMiss(record, req.options, result) : result;
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
