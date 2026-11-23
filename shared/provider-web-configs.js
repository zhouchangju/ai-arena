/**
 * AI Arena — built-in site adapters for the three public web seats
 * (G1, G3; R02, R06, R09).
 *
 * The coordinator publishes the fixed HTTPS origins of `chatgpt`, `gemini` and
 * `deepseek` in `providers.js` and in the manifest's optional host
 * permissions. This module only describes *how* to read and write those pages:
 *
 *   - `blankUrl` is the provider's own new-conversation entry page, taken from
 *     the registry so a URL change happens in exactly one place;
 *   - `selectors` are ordered CSS candidates per driver key (the page driver
 *     tries them in order and fails closed when nothing unique is visible);
 *   - `allowNavigation` lets an in-page SPA route change (chatgpt.com/ →
 *     /c/<id>) stay attached to the same task, but only after the driver has
 *     matched the exact user message of this round.
 *
 * Nothing here performs network access, requests permissions, injects scripts
 * or changes site behaviour. Reading and writing only happen after the user has
 * granted the matching optional host permission, and only through the ordinary
 * page driver.
 *
 * Real-site status: selectors were derived from the sibling reference
 * implementation (`../ai-arena-extension/src/selectors-config.js` and the
 * three content scripts) plus the recorded site notes in docs/iterations.md.
 * They are declared "待验证" until a logged-in manual run is recorded; a
 * mismatch fails one seat into takeover instead of sending twice.
 */

import { PROVIDERS, PUBLIC_AUTOMATION_PROVIDER_IDS } from './providers.js';

const MAX_SELECTOR_CHARS = 400;

/**
 * Ordered candidates. The order matters: the first candidate that matches
 * anything on the page supplies the node set for that key. Broad fallbacks are
 * last so a renamed stable hook still wins when it exists.
 */
const ADAPTERS = {
  chatgpt: {
    label: 'ChatGPT',
    allowNavigation: true,
    selectors: {
      input: [
        'div.ProseMirror[contenteditable="true"]',
        '#prompt-textarea',
      ],
      /**
       * 站点见证（2026-11-22，原生 WK 英文页）：题面已填入，发送箭头尚未点击，
       * 该布局没有 `data-testid`，旧候选因此匹配不到发送控件。新增的
       * `aria-label="Send"` 取自参考适配器（../ai-arena-extension）里同一站点的
       * 精确标签；只收精确 label，不用 `*="Send"`，避免把语音、停止、附件或
       * 编辑控件当成发送。若这些标记都不存在，驱动返回 send-pending 且不点击，
       * 也不以回车或任意箭头兜底。已在登录态 WK 原页核对 Send 按钮与本轮用户消息。
       */
      send: [
        'button[data-testid="send-button"]',
        'button[aria-label="发送"]',
        'button[aria-label="Send prompt"]',
        'button[aria-label="Send"]',
      ],
      user: ['[data-content-search-unit-key$=":user"]', '[data-message-author-role="user"]'],
      answer: ['[data-response-body]', '[data-message-author-role="assistant"] .markdown', '[data-message-author-role="assistant"]'],
      stop: [
        'button[data-testid="stop-button"]',
        'button[aria-label="Stop generating"]',
        'button[aria-label="Stop streaming"]',
        'button[aria-label="Stop"]',
        'button[aria-label^="停止"]',
      ],
      done: [
        '[data-turn-key]:has([data-response-body]) button:is([aria-label="Read aloud"], [aria-label="朗读"])',
        'article:has([data-response-body]) button[data-testid="copy-turn-action-button"]',
        '[data-message-author-role="assistant"] button[data-testid="copy-turn-action-button"]',
        'article:has([data-response-body]) button:is([aria-label="复制"], [aria-label="Copy"])',
      ],
    },
    options: {
      sampleMs: 300,
      stableSamples: 4,
      stableMs: 1200,
      submitTimeoutMs: 30000,
      turnGraceMs: 1500,
      pendingTimeoutMs: 600000,
    },
  },
  gemini: {
    label: 'Gemini',
    allowNavigation: true,
    selectors: {
      input: [
        'rich-textarea .ql-editor[contenteditable="true"]',
        'div.ql-editor[contenteditable="true"]',
        'rich-textarea [contenteditable="true"]',
      ],
      send: [
        'button[aria-label="Send message"]',
        'button[aria-label="发送"]',
        'button.send-button',
      ],
      user: ['user-query'],
      answer: [
        'model-response message-content',
        'model-response .model-response-text .markdown',
        'model-response .markdown',
      ],
      stop: [
        'button[aria-label="Stop response"]',
        'button[aria-label*="Stop"]',
        'button[aria-label*="停止"]',
        'model-response .loading-indicator',
        'model-response .thinking-indicator',
        'model-response mat-spinner',
      ],
      /**
       * Real-site observation (2026-11-22, logged-in page): a finished answer
       * exposes `button[aria-label="复制"]` inside its own `model-response`;
       * a second copy hint sits on the user message, so every candidate stays
       * scoped to `model-response` and is further filtered by the driver's
       * after-user-turn anchor. The `复制回答` / `Copy response` candidate is
       * kept first for the localized/renamed toolbar.
       *
       * Real vote page (2026-11-22) had no copy button; the finished response
       * exposed `gem-icon-button[data-test-id="regenerate-button"]` in its own
       * toolbar next to thumb-up/down. That action is the last candidate: it
       * stays scoped to `model-response`, still requires the driver's
       * after-user-turn binding so an older answer can not finish this round,
       * and the stop signal plus the stability sampling still gate completion.
       *
       * Since the three-seat run also finished a seat on a 9-character title,
       * Gemini additionally sets `options.requireDoneMarker` below: one of
       * these finished-action controls must be seen *live* after this round's
       * user message. A stop control that appeared and disappeared plus stable
       * text is no longer enough on this site.
       */
      done: [
        'model-response button:is([aria-label="复制回答"], [aria-label="Copy response"])',
        'model-response button[aria-label="复制"]',
        'model-response button[aria-label="Copy"]',
        'model-response gem-icon-button[data-test-id="regenerate-button"]',
      ],
    },
    options: {
      /**
       * Real-site observation (2026-11-22): right after the first Gemini task
       * created its composer and accepted the text, the send button was hidden
       * for several seconds and then appeared as the only
       * `button[aria-label="发送"]`. Widen only the visibility wait; the
       * pre-click full-text check and the single-submit guard stay unchanged.
       */
      sendEnableMs: 8000,
      /**
       * Real-site observation (2026-11-22, three-seat run): a Gemini seat was
       * declared complete with only the 9-character title
       * 「明确判断与主要理由」. The stop control had been visible and then
       * vanished, and the title alone stayed unchanged for several samples, so
       * the generic "stop disappeared + stable text" rule saved a heading as
       * the answer. Gemini keeps the stop button only while it streams, and it
       * renders the title before the body, so text stability plus a fleeting
       * stop is not completion evidence here. Only the native finished-action
       * control, bound after this round's user message, may finish the seat.
       * The other two sites keep the default (stop-observed) rule.
       */
      requireDoneMarker: true,
      sampleMs: 300,
      stableSamples: 4,
      stableMs: 1200,
      submitTimeoutMs: 30000,
      turnGraceMs: 1500,
      pendingTimeoutMs: 600000,
    },
  },
  deepseek: {
    label: 'DeepSeek',
    allowNavigation: true,
    selectors: {
      input: ['textarea[name="search"]', '#chat-input'],
      send: [
        '[role="button"].ds-button--primary.ds-button--circle:not(.ds-button--disabled)',
        'button[data-testid="send-button"]',
        'button[aria-label*="发送"]',
        'button[aria-label*="Send"]',
      ],
      user: ['.ds-message:not(:has(.ds-assistant-message-main-content)):not(:has(.ds-markdown))', '.fbb737a4'],
      answer: ['.ds-assistant-message-main-content', '.ds-markdown'],
      stop: ['.ds-loading', 'button[aria-label*="停止"]', 'button[aria-label*="Stop"]'],
      /**
       * Real-site observation (2026-11-22): DeepSeek only renders the answer
       * action toolbar (`.ds-flex` around the read-aloud control) under
       * `.ds-assistant-message-main-content`'s grandparent once generation has
       * really finished. The driver also filters `done` by document order after
       * this round's matched user message, so an older answer's toolbar can not
       * complete the current round. Precise message-scoped candidates come
       * first; the unscoped one is a fallback for DOM depth changes and still
       * relies on that after-user-turn binding.
       */
      done: [
        '.ds-message:has(.ds-assistant-message-main-content) .ds-flex :is(button, [role="button"])[aria-label="朗读"]',
        '.ds-message:has(.ds-assistant-message-main-content) :is(button, [role="button"])[aria-label="朗读"]',
        '.ds-message:has(.ds-assistant-message-main-content) .ds-flex :is(button, [role="button"])[aria-label="Read aloud"]',
        '.ds-message:has(.ds-assistant-message-main-content) :is(button, [role="button"])[aria-label="Read aloud"]',
        '.ds-flex :is(button, [role="button"])[aria-label="朗读"]',
        '.ds-flex :is(button, [role="button"])[aria-label="Read aloud"]',
      ],
    },
    options: {
      sampleMs: 300,
      stableSamples: 4,
      stableMs: 1200,
      submitTimeoutMs: 30000,
      turnGraceMs: 1500,
      pendingTimeoutMs: 600000,
    },
  },
};

export const WEB_SITE_PROVIDER_IDS = Object.freeze(
  PUBLIC_AUTOMATION_PROVIDER_IDS.filter((id) => Object.prototype.hasOwnProperty.call(ADAPTERS, id)),
);

const SELECTOR_KEYS = ['input', 'send', 'user', 'answer', 'stop', 'done', 'container'];
const REQUIRED_SELECTOR_KEYS = ['input', 'send', 'user', 'answer'];

function adapterFor(provider) {
  if (typeof provider !== 'string') return null;
  if (!Object.prototype.hasOwnProperty.call(ADAPTERS, provider)) return null;
  if (!PUBLIC_AUTOMATION_PROVIDER_IDS.includes(provider)) return null;
  return ADAPTERS[provider];
}

export function isWebSiteProvider(provider) {
  return Boolean(adapterFor(provider));
}

/** Exact HTTPS origin of the registry entry page, e.g. https://chatgpt.com. */
export function webSiteOrigin(provider) {
  const adapter = adapterFor(provider);
  const entry = PROVIDERS[provider];
  if (!adapter || !entry || typeof entry.url !== 'string') return '';
  try {
    const url = new URL(entry.url);
    if (url.protocol !== 'https:') return '';
    return url.origin;
  } catch {
    return '';
  }
}

function normalizeCandidateList(value, key) {
  const raw = Array.isArray(value) ? value : [value];
  const out = [];
  for (const item of raw) {
    if (typeof item !== 'string') continue;
    const css = item.trim();
    if (!css || css.length > MAX_SELECTOR_CHARS || /[\r\n]/.test(css)) continue;
    if (!out.includes(css)) out.push(css);
  }
  if (out.length === 0 && REQUIRED_SELECTOR_KEYS.includes(key)) return null;
  return out;
}

function buildSelectors(raw) {
  const selectors = {};
  for (const key of SELECTOR_KEYS) {
    if (raw[key] === undefined) continue;
    const list = normalizeCandidateList(raw[key], key);
    if (!list) return null;
    if (list.length > 0) selectors[key] = Object.freeze(list);
  }
  return Object.freeze(selectors);
}

const STATIC = {};
for (const provider of WEB_SITE_PROVIDER_IDS) {
  const adapter = ADAPTERS[provider];
  const entry = PROVIDERS[provider];
  let blankUrl = '';
  let origin = '';
  try {
    const url = new URL(entry.url);
    if (url.protocol === 'https:') {
      origin = url.origin;
      blankUrl = url.href;
    }
  } catch {
    /* reported as unavailable below */
  }
  const selectors = buildSelectors(adapter.selectors || {});
  STATIC[provider] = Object.freeze({
    provider,
    label: adapter.label || provider,
    blankUrl,
    origin,
    selectors,
    options: Object.freeze({ ...(adapter.options || {}) }),
    allowNavigation: adapter.allowNavigation === true,
  });
}

/**
 * Full internal config for one public seat, or null when the registry entry is
 * missing/not HTTPS or the adapter is incomplete. The caller pauses that one
 * seat with the returned reason instead of guessing a page.
 */
export function webSiteConfig(provider) {
  const adapter = adapterFor(provider);
  if (!adapter) return null;
  const staticConfig = STATIC[provider];
  if (!staticConfig || !staticConfig.blankUrl || !staticConfig.origin || !staticConfig.selectors) {
    return null;
  }
  return {
    mode: 'site',
    provider,
    label: staticConfig.label,
    url: staticConfig.blankUrl,
    origin: staticConfig.origin,
    selectors: staticConfig.selectors,
    options: staticConfig.options,
    allowNavigation: staticConfig.allowNavigation,
    updatedAt: 0,
  };
}

/** Human-readable reason a public seat has no usable adapter. */
export function webSiteConfigProblem(provider) {
  const adapter = adapterFor(provider);
  if (!adapter) return '该站点没有内置网页适配器';
  const staticConfig = STATIC[provider];
  if (!staticConfig.origin) return '登记表里的站点入口不是固定的 HTTPS 地址';
  if (!staticConfig.selectors) return '内置网页选择器不完整';
  return '';
}
