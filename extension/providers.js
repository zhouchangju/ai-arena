// AI Arena — provider registry (G1, G3, R09)
//
// One entry per supported consumer chat site. The service worker uses this
// registry as the single allowlist for session membership and for the tabs the
// user explicitly asks to open. Nothing here performs network access: opening
// a site is an ordinary user-initiated tab, and the page keeps its own login.
//
// `url` is only the entry page. It is never used as a "send" target, and no
// automation capability is assumed for any site.

export const PROVIDERS = Object.freeze({
  chatgpt: { name: 'ChatGPT', url: 'https://chatgpt.com/' },
  claude: { name: 'Claude', url: 'https://claude.ai/new' },
  gemini: { name: 'Gemini', url: 'https://gemini.google.com/app' },
  deepseek: { name: 'DeepSeek', url: 'https://chat.deepseek.com/' },
  doubao: { name: '豆包', url: 'https://www.doubao.com/chat/' },
  kimi: { name: 'Kimi', url: 'https://www.kimi.com/' },
  // Chinese Tongyi Qianwen portal. chat.qwen.ai is the international Qwen
  // entry and is intentionally not used as the seat page here.
  qwen: { name: '通义千问', url: 'https://www.qianwen.com/' },
  yuanbao: { name: '腾讯元宝', url: 'https://yuanbao.tencent.com/chat/' },
  grok: { name: 'Grok', url: 'https://grok.com/' },
});

/** Canonical, lowercase provider ids in display order. */
export const PROVIDER_IDS = Object.freeze(Object.keys(PROVIDERS));

/**
 * Strict canonical allowlist check: only the exact lowercase ids above pass.
 * 'ChatGPT', ' gpt' or 'gpt-4' are rejected on purpose so stored sessions can
 * not silently reference a provider the registry does not describe.
 */
export function isProviderId(value) {
  return (
    typeof value === 'string' &&
    Object.prototype.hasOwnProperty.call(PROVIDERS, value)
  );
}

/** Origin of a provider entry page, e.g. "https://chatgpt.com". */
export function providerOrigin(id) {
  if (!isProviderId(id)) return '';
  try {
    return new URL(PROVIDERS[id].url).origin;
  } catch {
    return '';
  }
}
