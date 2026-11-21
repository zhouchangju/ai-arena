# 两份参考源码里，哪些值得借

截至 2026-11-21，两份本地检出的提交均与各自公开上游默认分支的最新提交相符。Arena 的扩展清单为 **5.0.75**，对应 7 月 19 日的 `00953eb`。其 README 徽标仍是 5.0.74，package.json 仍是 5.0.63。Panelize 为 **2.2.4**，对应 11 月 19 日的 `e6d15b4`。前者值得逐站复测，后者最近仍在修复使用问题。提交日期本身无法证明某个网站今天可用或失效。[Arena 上游提交](https://github.com/TianLin0509/ai-arena-extension/commit/00953ebff7ab2b73525c949f56302f06b4db121b) · [Panelize 上游提交](https://github.com/Manho/Panelize/commit/e6d15b4f1e8222de02c770c6d5d78898252f8301)

## Arena 已经做到了哪一步

官方材料列出九家平台。其群聊式主控提供成员选择、同时提问、自由辩论、群策群力、顺序接力和指定裁判。原项目展示图里，左侧是历史，中间读对话，右侧选成员和任务。精简模式把辩论、协作、总结放在主要操作区。保留“在一处读完整讨论”和“随时跳回原网页”两项体验，特别适合个人判断问题。[项目说明](../../ai-arena-extension/README.md) · [原项目界面图](../../ai-arena-extension/docs/v5.0-beta/v5.0-screenshots/01-popup-overview.png)

| 一次辩论的环节 | 源码实际做的事 | 我们怎样借 |
|---|---|---|
| 发起 | 后台维护成员与标签页，广播同一问题。各站点脚本负责找到输入框、提交、读回答。 | 沿用一位成员对应一个专用对话页，避免碰到用户已有草稿。[后台入口](../../ai-arena-extension/src/background.js) · [选择器配置](../../ai-arena-extension/src/selectors-config.js) |
| 收集 | 每个站独立轮询，检查正文是否稳定、是否仍在生成；拒绝一部分用户消息回显和上轮残留。当前台关闭或后台重新启动，能恢复一部分待处理任务。 | 借流式检测和恢复用例；每条已采纳回答保留独立轮次与原文标识。[ChatBus](../../ai-arena-extension/src/chat-bus.js) · [状态存储](../../ai-arena-extension/src/state-machine.js) |
| 交叉质询 | 控制台可以发起下一轮。`buildDebatePrompt` 排除接收者自己，将其他人的回答连同本轮引导发给它；接力模式按给定顺序让后发者看到先发者。 | 首版借并行互评。先冻结本轮输入，让所有成员看同一批材料，避免先返回的成员影响仍在独立作答的人。[轮次引擎](../../ai-arena-extension/src/debate-engine.js) · [控制台动作](../../ai-arena-extension/src/popup-tasks.js) |
| 总结 | 用户指定在场成员担任裁判，可输出文本或结构化 HTML，呈现共识、分歧和未决问题。JSON 解析还处理模板回显与截断。 | 借报告结构和易读的文本回退。增加逐条引用校验、完成状态校验和参与者确认。[总结构造](../../ai-arena-extension/src/debate-engine.js) · [报告解析与呈现](../../ai-arena-extension/src/debate-summary-template.js) |

### 三个会影响结论质量的细节

1. **最早的反例可能在总结时消失。** `buildSummaryPrompt` 遍历历史时只写轮号、风格和用户引导，再附当前各方观点。即使历史里存着第一轮原文，裁判收到的这份汇总也不会逐轮列出它们。负责总结的模型在自己的网页中可能看过部分历史，但换裁判或重新开会话就不能依赖这段记忆。新工具应让每个重要反例有出处和处理结果。[总结提示词](../../ai-arena-extension/src/debate-engine.js)
2. **发送重试存在路径差异。** `handleDebateRound` 的超时重试复用同一注入令牌；侧栏的 `handleBroadcast` 路径也会重试，却没把令牌传给文本注入。如果网页已经提交、回执才超时，同一问题有机会被发两次。接收端去重表也只在当前页面内存里。这里识别的是代码条件，本次没有复现双发。[侧栏广播](../../ai-arena-extension/src/sidepanel.js) · [后台两个发送入口](../../ai-arena-extension/src/background.js) · [令牌去重](../../ai-arena-extension/src/content-shared.js)
3. **超时和完整回答可能在界面上都显示为已结束。** `pollOnce` 达到轮询上限时保留已读文字，向界面同时发送 `isDone: true` 和 `forcedTimeout: true`。保留半篇回答很有用，但它还需要一个独立的“内容不完整”状态，防止下一轮把半篇当作该成员的最终立场。[轮询结束分支](../../ai-arena-extension/src/chat-bus.js)

## Panelize 补上什么

Panelize 的主流程是统一输入、分别填入或发送、在并排网页里阅读。截图中用户可以直接操作各站原生界面，也可以从底部一次发送。它还支持调整列宽、自定义网页或 API 提供方、分享长回答截图。在所查的广播、消息协议和界面入口里，没有发现类似 Arena 的跨轮质询和共识裁决流程。[主界面](../../Panelize/assets/screenshots/main-panel.png) · [广播入口](../../Panelize/multi-panel/multi-panel.js) · [消息协议](../../Panelize/modules/panel-message-contract.js)

| 可借的具体做法 | 带来的改进 |
|---|---|
| 提供方注册表把域名、入口及能力写在一起。部分面板动作以请求 ID、动作、提供方、来源窗口和来源域共同匹配回执。 | 接入新站可以单独验证发送、读取及完成判断。A 站的晚到消息不能确认 B 站的任务。[注册表](../../Panelize/modules/provider-registry.js) · [动作回执](../../Panelize/modules/panel-action-results.js) |
| ChatGPT 的编辑器定位被单独抽成模块，区分桌面、窄屏和旧布局，优先使用可见候选；仓库有从统一输入到发送按钮的浏览器回归用例。 | 将这些布局做成测试样本。Arena 的配置仍优先查 ProseMirror，Panelize 已覆盖另一套表单结构。两份选择器的差异给出了实测方向，线上是否命中要另测。[Panelize 定位器](../../Panelize/content-scripts/chatgpt-composer.js) · [浏览器用例](../../Panelize/tests/e2e/chatgpt-send-all.e2e.test.js) |
| 2.2.4 修复了切换标签页与独立窗口时重载页面、丢失活动会话的问题，改为移动原标签。既有测试还分别覆盖本地页面样本和依赖登录的真实网站。 | 将“切换视图、关闭工作台、回来继续”设为验收场景。固定样本稳定通过、真实账号网页验证分别记录。[更新记录](../../Panelize/CHANGELOG.md) · [窗口切换](../../Panelize/modules/open-mode-switcher.js) · [真实网站测试](../../Panelize/tests/live/providers.live.test.js) |

Panelize 的完整网页并排依赖 iframe。它自己的历史记录就包括嵌入后登录状态异常、网页缓存影响再次打开、输入焦点被抢等维护成本。我们的对照视图只展示已收集的本轮答案，想操作网站时打开原标签。这样仍能并排阅读，也少维护一层网页嵌入行为。[变更历史](../../Panelize/CHANGELOG.md)

## 代码复用顺序

- **先提取小而独立的实现。** 优先候选是 Arena 的文本预算处理及其边界用例、Panelize 的提供方描述和请求匹配思路。迁入时逐项对照新行为，给每段实质复制的代码记录源文件、提交和原许可证。两库根许可证均为 MIT。Arena 署名 TianLin0509，Panelize 署名 Xiaolai、Wenhao。图标、品牌素材、打包的第三方库另查来源。[Arena 许可证](../../ai-arena-extension/LICENSE) · [Panelize 许可证](../../Panelize/LICENSE)
- **保留机制，重写协调逻辑。** Arena 把窗口管理、发送、重试、轮次、总结等放在同一个后台入口里，Panelize 的回执又与 iframe 绑定。新项目只需要一套轮次状态和一套标签页归属规则，同时移植两套后台会增加排查成本。
- **将已有故障转成输入样本。** 首批样本取自编辑器换版、旧回答仍在页面、后台超时、网页刷新、慢成员晚到、切换窗口丢草稿。平台适配只有在当前日期、对应登录态和布局下通过真实闭环，才标记为已验证。

本次检查覆盖两库清单、关键入口、交互截图、变更记录和上述测试源码。没有运行参考扩展或向第三方 AI 发送问题。用户此前遇到的具体故障尚无复现记录，以上代码风险和上游已修问题可作为第一批排查线索。
