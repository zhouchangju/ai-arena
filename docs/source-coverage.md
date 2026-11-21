# 源码覆盖对账

2026-11-21，按[两个固定提交](reference-review.md)核对。下表允许从任一列入的源码文件反查到功能、取舍和验收。它检验文件与入口有归属；一个文件可能承载多个功能，表内匹配不能证明每个分支都已在浏览器执行。

Arena 枚举 src 根的 JS、HTML 和 JSON、PPT-SUPER 根脚本与模板索引，以及构建脚本和选择器覆盖文件。Panelize 枚举 manifest、background、modules、content-scripts、multi-panel、options、api-panel 的 JS/HTML 及 rules 下的 JSON。另逐项比对 Arena 后台 switch 中的字符串 case 与 Panelize 显式面板消息契约。样式和图片随对应 UI 登记，单个 PPT 版式、语言包、第三方库、测试开发工具、发布物、Arena 的 poc 实验目录不单列为用户功能。上游新增文件或动作时应更新此对账。

## ai-arena-extension（84 个文件）

| 功能条目 | 对应文件 |
|---|---|
| [A29](arena-features.md#a29) | [build.mjs](../../ai-arena-extension/build.mjs)、[selectors-override.json](../../ai-arena-extension/selectors-override.json)、[src/dnr-rules.json](../../ai-arena-extension/src/dnr-rules.json)、[src/manifest.json](../../ai-arena-extension/src/manifest.json)、[src/selectors-config.js](../../ai-arena-extension/src/selectors-config.js)、[src/selectors-remote.js](../../ai-arena-extension/src/selectors-remote.js) |
| [A27](arena-features.md#a27) | [src/arena-errors.js](../../ai-arena-extension/src/arena-errors.js)、[src/popup-doctor.js](../../ai-arena-extension/src/popup-doctor.js)、[src/popup-log.js](../../ai-arena-extension/src/popup-log.js)、[src/popup-stuck-sentinel.js](../../ai-arena-extension/src/popup-stuck-sentinel.js)、[src/popup-toast.js](../../ai-arena-extension/src/popup-toast.js) |
| [A01](arena-features.md#a01)、[A04](arena-features.md#a04)、[A05](arena-features.md#a05)、[A06](arena-features.md#a06)、[A07](arena-features.md#a07)、[A08](arena-features.md#a08)、[A10](arena-features.md#a10)、[A14](arena-features.md#a14)、[A16](arena-features.md#a16)、[A17](arena-features.md#a17)、[A18](arena-features.md#a18)、[A20](arena-features.md#a20)、[A22](arena-features.md#a22)、[A33](arena-features.md#a33) | [src/background.js](../../ai-arena-extension/src/background.js) |
| [A21](arena-features.md#a21) | [src/baton-prompts.js](../../ai-arena-extension/src/baton-prompts.js) |
| [A33](arena-features.md#a33) | [src/bootstrap-main-world.js](../../ai-arena-extension/src/bootstrap-main-world.js)、[src/cdp-extractor.js](../../ai-arena-extension/src/cdp-extractor.js) |
| [A19](arena-features.md#a19) | [src/captain-mode.js](../../ai-arena-extension/src/captain-mode.js)、[src/popup-role-hats.js](../../ai-arena-extension/src/popup-role-hats.js) |
| [A04](arena-features.md#a04)、[A11](arena-features.md#a11)、[A28](arena-features.md#a28) | [src/chat-bus.js](../../ai-arena-extension/src/chat-bus.js) |
| [A10](arena-features.md#a10)、[A11](arena-features.md#a11) | [src/content-chatgpt.js](../../ai-arena-extension/src/content-chatgpt.js)、[src/content-claude.js](../../ai-arena-extension/src/content-claude.js)、[src/content-deepseek.js](../../ai-arena-extension/src/content-deepseek.js)、[src/content-doubao.js](../../ai-arena-extension/src/content-doubao.js)、[src/content-gemini.js](../../ai-arena-extension/src/content-gemini.js)、[src/content-grok.js](../../ai-arena-extension/src/content-grok.js)、[src/content-kimi.js](../../ai-arena-extension/src/content-kimi.js)、[src/content-qwen.js](../../ai-arena-extension/src/content-qwen.js)、[src/content-yuanbao.js](../../ai-arena-extension/src/content-yuanbao.js) |
| [A10](arena-features.md#a10)、[A11](arena-features.md#a11)、[A25](arena-features.md#a25) | [src/content-shared.js](../../ai-arena-extension/src/content-shared.js) |
| [A15](arena-features.md#a15)、[A17](arena-features.md#a17)、[A20](arena-features.md#a20) | [src/debate-engine.js](../../ai-arena-extension/src/debate-engine.js) |
| [A20](arena-features.md#a20) | [src/debate-summary-template.js](../../ai-arena-extension/src/debate-summary-template.js) |
| [A22](arena-features.md#a22) | [src/export-engine.js](../../ai-arena-extension/src/export-engine.js)、[src/popup-compare.js](../../ai-arena-extension/src/popup-compare.js) |
| [A26](arena-features.md#a26) | [src/gatekeeper-engine.js](../../ai-arena-extension/src/gatekeeper-engine.js)、[src/gatekeeper-rules.js](../../ai-arena-extension/src/gatekeeper-rules.js)、[src/gatekeeper-store.js](../../ai-arena-extension/src/gatekeeper-store.js)、[src/popup-gatekeeper-bridge.js](../../ai-arena-extension/src/popup-gatekeeper-bridge.js) |
| [A09](arena-features.md#a09) | [src/inject-images.js](../../ai-arena-extension/src/inject-images.js)、[src/popup.html](../../ai-arena-extension/src/popup.html) |
| [A25](arena-features.md#a25) | [src/memo-store.js](../../ai-arena-extension/src/memo-store.js)、[src/popup-memos.js](../../ai-arena-extension/src/popup-memos.js) |
| [A02](arena-features.md#a02) | [src/onboarding-core.js](../../ai-arena-extension/src/onboarding-core.js)、[src/popup-help-fab.js](../../ai-arena-extension/src/popup-help-fab.js)、[src/popup-onboarding.js](../../ai-arena-extension/src/popup-onboarding.js)、[src/popup-tutorial.js](../../ai-arena-extension/src/popup-tutorial.js)、[src/welcome.html](../../ai-arena-extension/src/welcome.html)、[src/welcome.js](../../ai-arena-extension/src/welcome.js) |
| [A31](arena-features.md#a31) | [src/popup-achievements.js](../../ai-arena-extension/src/popup-achievements.js)、[src/popup-stats.js](../../ai-arena-extension/src/popup-stats.js) |
| [A12](arena-features.md#a12) | [src/popup-action-icons.js](../../ai-arena-extension/src/popup-action-icons.js)、[src/popup-arena-badge.js](../../ai-arena-extension/src/popup-arena-badge.js)、[src/popup-compact-mode.js](../../ai-arena-extension/src/popup-compact-mode.js) |
| [A12](arena-features.md#a12)、[A19](arena-features.md#a19) | [src/popup-bubble-actions.js](../../ai-arena-extension/src/popup-bubble-actions.js) |
| [A13](arena-features.md#a13) | [src/popup-codepreview.js](../../ai-arena-extension/src/popup-codepreview.js)、[src/popup-markdown.js](../../ai-arena-extension/src/popup-markdown.js) |
| [A03](arena-features.md#a03) | [src/popup-feature-tour.js](../../ai-arena-extension/src/popup-feature-tour.js)、[src/popup-more-menu.js](../../ai-arena-extension/src/popup-more-menu.js)、[src/popup-progressive.js](../../ai-arena-extension/src/popup-progressive.js)、[src/popup-rightpanel.js](../../ai-arena-extension/src/popup-rightpanel.js)、[src/popup-simple-mode.js](../../ai-arena-extension/src/popup-simple-mode.js) |
| [A23](arena-features.md#a23) | [src/popup-history.js](../../ai-arena-extension/src/popup-history.js) |
| [A32](arena-features.md#a32) | [src/popup-logo-style.js](../../ai-arena-extension/src/popup-logo-style.js)、[src/popup-settings.js](../../ai-arena-extension/src/popup-settings.js)、[src/popup-update-check.js](../../ai-arena-extension/src/popup-update-check.js) |
| [A04](arena-features.md#a04)、[A05](arena-features.md#a05)、[A31](arena-features.md#a31) | [src/popup-members.js](../../ai-arena-extension/src/popup-members.js) |
| [A06](arena-features.md#a06) | [src/popup-mini-mode.js](../../ai-arena-extension/src/popup-mini-mode.js)、[src/popup-mini-roster.js](../../ai-arena-extension/src/popup-mini-roster.js)、[src/popup-window-mode.js](../../ai-arena-extension/src/popup-window-mode.js) |
| [A14](arena-features.md#a14) | [src/popup-modal.js](../../ai-arena-extension/src/popup-modal.js) |
| [A07](arena-features.md#a07)、[A16](arena-features.md#a16) | [src/popup-roster.js](../../ai-arena-extension/src/popup-roster.js) |
| [A07](arena-features.md#a07)、[A15](arena-features.md#a15) | [src/popup-task-menu.js](../../ai-arena-extension/src/popup-task-menu.js) |
| [A14](arena-features.md#a14)、[A17](arena-features.md#a17)、[A18](arena-features.md#a18)、[A21](arena-features.md#a21)、[A23](arena-features.md#a23)、[A30](arena-features.md#a30) | [src/popup-tasks.js](../../ai-arena-extension/src/popup-tasks.js) |
| [A24](arena-features.md#a24) | [src/popup-templates.js](../../ai-arena-extension/src/popup-templates.js)、[src/template-store.js](../../ai-arena-extension/src/template-store.js) |
| [A01](arena-features.md#a01)、[A07](arena-features.md#a07)、[A12](arena-features.md#a12) | [src/popup.js](../../ai-arena-extension/src/popup.js) |
| [A30](arena-features.md#a30) | [src/ppt-prompts.js](../../ai-arena-extension/src/ppt-prompts.js)、[src/ppt-super/jszip.min.js](../../ai-arena-extension/src/ppt-super/jszip.min.js)、[src/ppt-super/ppt-fill.js](../../ai-arena-extension/src/ppt-super/ppt-fill.js)、[src/ppt-super/ppt-super.js](../../ai-arena-extension/src/ppt-super/ppt-super.js)、[src/ppt-super/templates.json](../../ai-arena-extension/src/ppt-super/templates.json) |
| [A11](arena-features.md#a11) | [src/qwen-noise-filter.js](../../ai-arena-extension/src/qwen-noise-filter.js) |
| [A01](arena-features.md#a01) | [src/sidepanel.html](../../ai-arena-extension/src/sidepanel.html) |
| [A01](arena-features.md#a01)、[A07](arena-features.md#a07)、[A09](arena-features.md#a09)、[A12](arena-features.md#a12)、[A33](arena-features.md#a33) | [src/sidepanel.js](../../ai-arena-extension/src/sidepanel.js) |
| [A23](arena-features.md#a23)、[A28](arena-features.md#a28) | [src/state-machine.js](../../ai-arena-extension/src/state-machine.js) |
| [A15](arena-features.md#a15)、[A24](arena-features.md#a24) | [src/templates-builtin.js](../../ai-arena-extension/src/templates-builtin.js) |

### 后台分派动作（48 项）

| 功能条目 | 源码中的动作名 |
|---|---|
| [A04](arena-features.md#a04) | `addParticipant`、`removeParticipant` |
| [A05](arena-features.md#a05) | `recheckLogin`、`activateParticipantTab`、`reopenParticipantTab`、`reloadParticipantTab` |
| [A01](arena-features.md#a01) | `openArenaPopup`、`openChatPopup`、`popupReady`、`openSidepanel` |
| [A27](arena-features.md#a27) | `runDiagnosis`、`chatReextractOne`、`chatSkipParticipant`、`retryInject` |
| [A07](arena-features.md#a07) | `broadcast`、`chatBroadcast`、`sendToOne` |
| [A15](arena-features.md#a15) | `debateRound` |
| [A18](arena-features.md#a18) | `debateRoundSequential` |
| [A20](arena-features.md#a20) | `summary` |
| [A11](arena-features.md#a11) | `checkAllCompletion`、`readOneResponse` |
| [A06](arena-features.md#a06) | `focusTab`、`focusAllAiTabs`、`focusServiceTabThenPopup`、`setWindowMode`、`arrangeWindows`、`miniModeToggle`、`miniMenuExpand` |
| [A30](arena-features.md#a30) | `readLastImage`、`pptBuildPrompt` |
| [A10](arena-features.md#a10) | `sendPromptToService` |
| [A22](arena-features.md#a22) | `exportSession` |
| [A28](arena-features.md#a28) | `getState` |
| [A29](arena-features.md#a29) | `getSelectors` |
| [A26](arena-features.md#a26) | `_bumpGatekeeperStat` |
| [A23](arena-features.md#a23) | `chatRestoreLog`、`chatClear`、`resetSession`、`hardReset` |
| [A12](arena-features.md#a12) | `chatJumpToOrigin`、`getSentPrompt` |
| [A16](arena-features.md#a16) | `setParticipantResponse` |
| [A17](arena-features.md#a17) | `retryDebateInjectForParticipant` |
| [A25](arena-features.md#a25) | `memoAdd`、`memoList`、`memoRemove`、`memoClear` |

## Panelize（71 个文件）

| 功能条目 | 对应文件 |
|---|---|
| [P11](panelize-features.md#p11) | [api-panel/api-panel.html](../../Panelize/api-panel/api-panel.html)、[api-panel/api-panel.js](../../Panelize/api-panel/api-panel.js)、[modules/custom-api-bridge.js](../../Panelize/modules/custom-api-bridge.js)、[modules/custom-api-secrets.js](../../Panelize/modules/custom-api-secrets.js)、[modules/html-utils.js](../../Panelize/modules/html-utils.js)、[modules/markdown-dom.js](../../Panelize/modules/markdown-dom.js)、[modules/openai-chat-client.js](../../Panelize/modules/openai-chat-client.js) |
| [P01](panelize-features.md#p01)、[P15](panelize-features.md#p15)、[P22](panelize-features.md#p22) | [background/service-worker.js](../../Panelize/background/service-worker.js) |
| [P04](panelize-features.md#p04) | [content-scripts/button-finder-utils.js](../../Panelize/content-scripts/button-finder-utils.js)、[content-scripts/chatgpt-composer.js](../../Panelize/content-scripts/chatgpt-composer.js)、[modules/text-injector.js](../../Panelize/modules/text-injector.js) |
| [P14](panelize-features.md#p14) | [content-scripts/custom-provider-cookie-consent.js](../../Panelize/content-scripts/custom-provider-cookie-consent.js)、[content-scripts/grok-cookie-consent.js](../../Panelize/content-scripts/grok-cookie-consent.js)、[modules/grok-websocket-cookies.js](../../Panelize/modules/grok-websocket-cookies.js) |
| [P10](panelize-features.md#p10) | [content-scripts/custom-provider-driver.js](../../Panelize/content-scripts/custom-provider-driver.js)、[modules/custom-providers.js](../../Panelize/modules/custom-providers.js)、[modules/url-validator.js](../../Panelize/modules/url-validator.js) |
| [P05](panelize-features.md#p05) | [content-scripts/enter-behavior-aistudio.js](../../Panelize/content-scripts/enter-behavior-aistudio.js)、[content-scripts/enter-behavior-chatglm.js](../../Panelize/content-scripts/enter-behavior-chatglm.js)、[content-scripts/enter-behavior-chatgpt.js](../../Panelize/content-scripts/enter-behavior-chatgpt.js)、[content-scripts/enter-behavior-claude.js](../../Panelize/content-scripts/enter-behavior-claude.js)、[content-scripts/enter-behavior-deepseek.js](../../Panelize/content-scripts/enter-behavior-deepseek.js)、[content-scripts/enter-behavior-doubao.js](../../Panelize/content-scripts/enter-behavior-doubao.js)、[content-scripts/enter-behavior-gemini.js](../../Panelize/content-scripts/enter-behavior-gemini.js)、[content-scripts/enter-behavior-google.js](../../Panelize/content-scripts/enter-behavior-google.js)、[content-scripts/enter-behavior-grok.js](../../Panelize/content-scripts/enter-behavior-grok.js)、[content-scripts/enter-behavior-kimi.js](../../Panelize/content-scripts/enter-behavior-kimi.js)、[content-scripts/enter-behavior-qwen-cn.js](../../Panelize/content-scripts/enter-behavior-qwen-cn.js)、[content-scripts/enter-behavior-qwen-global.js](../../Panelize/content-scripts/enter-behavior-qwen-global.js)、[content-scripts/enter-behavior-utils.js](../../Panelize/content-scripts/enter-behavior-utils.js)、[content-scripts/enter-behavior-yuanbao.js](../../Panelize/content-scripts/enter-behavior-yuanbao.js)、[content-scripts/enter-behavior-zai-global.js](../../Panelize/content-scripts/enter-behavior-zai-global.js)、[content-scripts/focus-toggle.js](../../Panelize/content-scripts/focus-toggle.js)、[modules/pointer-guard.js](../../Panelize/modules/pointer-guard.js) |
| [P19](panelize-features.md#p19) | [content-scripts/language-detector.js](../../Panelize/content-scripts/language-detector.js)、[modules/i18n.js](../../Panelize/modules/i18n.js)、[modules/theme-manager.js](../../Panelize/modules/theme-manager.js) |
| [P15](panelize-features.md#p15) | [content-scripts/page-content-extractor.js](../../Panelize/content-scripts/page-content-extractor.js) |
| [P06](panelize-features.md#p06)、[P07](panelize-features.md#p07) | [content-scripts/text-injection-all-providers.js](../../Panelize/content-scripts/text-injection-all-providers.js) |
| [P01](panelize-features.md#p01)、[P08](panelize-features.md#p08) | [manifest.json](../../Panelize/manifest.json) |
| [P12](panelize-features.md#p12) | [modules/custom-sw-recovery.js](../../Panelize/modules/custom-sw-recovery.js)、[modules/frame-header-rules.js](../../Panelize/modules/frame-header-rules.js)、[rules/bypass-headers.json](../../Panelize/rules/bypass-headers.json) |
| [P09](panelize-features.md#p09) | [modules/google-mode.js](../../Panelize/modules/google-mode.js) |
| [P03](panelize-features.md#p03) | [modules/layout-auto-adjust.js](../../Panelize/modules/layout-auto-adjust.js)、[modules/panel-fit.js](../../Panelize/modules/panel-fit.js)、[modules/panel-resize.js](../../Panelize/modules/panel-resize.js) |
| [P13](panelize-features.md#p13) | [modules/messaging.js](../../Panelize/modules/messaging.js) |
| [P01](panelize-features.md#p01) | [modules/open-mode-switcher.js](../../Panelize/modules/open-mode-switcher.js) |
| [P08](panelize-features.md#p08) | [modules/optional-provider-access.js](../../Panelize/modules/optional-provider-access.js)、[modules/provider-defaults.js](../../Panelize/modules/provider-defaults.js)、[modules/provider-open-url.js](../../Panelize/modules/provider-open-url.js)、[modules/provider-order.js](../../Panelize/modules/provider-order.js)、[modules/providers.js](../../Panelize/modules/providers.js) |
| [P04](panelize-features.md#p04)、[P06](panelize-features.md#p06)、[P13](panelize-features.md#p13) | [modules/panel-action-results.js](../../Panelize/modules/panel-action-results.js) |
| [P12](panelize-features.md#p12)、[P13](panelize-features.md#p13) | [modules/panel-message-contract.js](../../Panelize/modules/panel-message-contract.js) |
| [P16](panelize-features.md#p16)、[P18](panelize-features.md#p18) | [modules/prompt-manager.js](../../Panelize/modules/prompt-manager.js) |
| [P07](panelize-features.md#p07)、[P08](panelize-features.md#p08) | [modules/provider-registry.js](../../Panelize/modules/provider-registry.js) |
| [P20](panelize-features.md#p20) | [modules/rating-prompt.js](../../Panelize/modules/rating-prompt.js) |
| [P18](panelize-features.md#p18) | [modules/settings.js](../../Panelize/modules/settings.js) |
| [P17](panelize-features.md#p17)、[P21](panelize-features.md#p21) | [modules/share-snapshot.js](../../Panelize/modules/share-snapshot.js) |
| [P17](panelize-features.md#p17) | [modules/share-trigger.js](../../Panelize/modules/share-trigger.js)、[modules/snapshot-capture.js](../../Panelize/modules/snapshot-capture.js)、[modules/snapshot-stitch.js](../../Panelize/modules/snapshot-stitch.js)、[modules/tab-capture.js](../../Panelize/modules/tab-capture.js) |
| [P22](panelize-features.md#p22) | [modules/version-checker.js](../../Panelize/modules/version-checker.js)、[modules/version-utils.js](../../Panelize/modules/version-utils.js) |
| [P02](panelize-features.md#p02)、[P16](panelize-features.md#p16)、[P20](panelize-features.md#p20) | [multi-panel/multi-panel.html](../../Panelize/multi-panel/multi-panel.html) |
| [P02](panelize-features.md#p02)、[P04](panelize-features.md#p04)、[P06](panelize-features.md#p06)、[P09](panelize-features.md#p09)、[P12](panelize-features.md#p12)、[P15](panelize-features.md#p15) | [multi-panel/multi-panel.js](../../Panelize/multi-panel/multi-panel.js) |
| [P05](panelize-features.md#p05)、[P19](panelize-features.md#p19)、[P21](panelize-features.md#p21) | [options/options.html](../../Panelize/options/options.html) |
| [P08](panelize-features.md#p08)、[P10](panelize-features.md#p10)、[P16](panelize-features.md#p16)、[P18](panelize-features.md#p18) | [options/options.js](../../Panelize/options/options.js) |

### 面板通信协议（20 项）

| 功能条目 | 源码中的动作名 |
|---|---|
| [P04](panelize-features.md#p04) | `INJECT_TEXT`、`TRIGGER_SEND`、`CLEAR_INPUT` |
| [P06](panelize-features.md#p06) | `INJECT_TEXT_WITH_IMAGES` |
| [P07](panelize-features.md#p07) | `NEW_CHAT`、`ENABLE_TEMP_CHAT`、`DISABLE_TEMP_CHAT`、`PANELIZE_TEMP_CHAT_ENABLED`、`PANELIZE_TEMP_CHAT_DISABLED` |
| [P05](panelize-features.md#p05) | `PANELIZE_RESTORE_USER_FOCUS`、`PANELIZE_PROVIDER_BUSY`、`PANELIZE_PROVIDER_IDLE`、`PANELIZE_PROVIDER_USER_INTERACTION` |
| [P17](panelize-features.md#p17) | `PANELIZE_SNAPSHOT_PREPARE`、`PANELIZE_SNAPSHOT_SCROLL`、`PANELIZE_SNAPSHOT_RESTORE`、`PANELIZE_SNAPSHOT_STATE` |
| [P13](panelize-features.md#p13) | `PANELIZE_ACTION_RESULT` |
| [P12](panelize-features.md#p12) | `PANELIZE_PROVIDER_LOCATION` |
| [P03](panelize-features.md#p03) | `PANELIZE_PAGE_WIDTH` |
