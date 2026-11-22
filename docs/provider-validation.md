# 网页站点验证表

两库合计出现 14 个不同的内置站点入口。Arena 为其中 9 个站点提供回答读取脚本。Panelize 的 14 个入口中，注册表将 8 个列为常规、6 个列为可选授权。下表的“临时”仅表示 Panelize 在描述符内声明了临时会话配置。本站清单全部处于**自用版未实测**状态。[Arena 站点清单](../../ai-arena-extension/src/manifest.json) · [Panelize 描述符](../../Panelize/modules/provider-registry.js)

| 站点 | Arena 源码 | Panelize 接入 / 临时配置 | 该站首个差异用例 |
|---|---|---|---|
| ChatGPT | [适配器](../../ai-arena-extension/src/content-chatgpt.js) | 常规 / 有 | 同时存在隐藏旧编辑器、桌面和窄屏输入；记录可见编辑器及原生发送状态。 |
| Claude | [适配器](../../ai-arena-extension/src/content-claude.js) | 常规 / 有 | 带长引用的回复，检查正文清理后引用仍在；新对话控件与正文里的链接区分。 |
| Gemini | [适配器](../../ai-arena-extension/src/content-gemini.js) | 常规 / 有 | 中文与英文界面、输入框延迟出现；区分未登录、加载中和可以发送。 |
| Grok | [适配器](../../ai-arena-extension/src/content-grok.js) | 常规 / 有 | 在正常网页确认可进入对话；单独验证隐私对话，记录原页状态。 |
| DeepSeek | [适配器](../../ai-arena-extension/src/content-deepseek.js) | 常规 / 无 | 思考段、正式答案、长停顿共存；只采纳正式答案。 |
| Kimi | [适配器](../../ai-arena-extension/src/content-kimi.js) | 常规 / 无 | 登录跳转与窄屏布局，确认回复对应同一对话，长输入未变成空白。 |
| Google 搜索 / AI 模式 | — | 常规 / 无 | 切搜索与 AI 模式，检测只有搜索结果时不能参与多轮。 |
| 豆包 | [适配器](../../ai-arena-extension/src/content-doubao.js) | 常规 / 无 | 富文本编辑器更新后，用多段中文试填写与提交，核对换行及完整题面。 |
| 千问中国版 | [适配器](../../ai-arena-extension/src/content-qwen.js) | 可选 / 无 | 专测两轮长文与旧答残留，核对两种加人顺序；通过验证后再决定新版组合限制。 |
| Qwen Global | — | 可选 / 无 | 区分中国站与海外站的域名、登录状态和收件人，撤权仅影响海外席位。 |
| 智谱清言 | — | 可选 / 无 | 同意及拒绝授权各试一次，再验证新会话和中文输入。 |
| Z.ai | — | 可选 / 无 | 与智谱清言同时登记时，核对来源和站点身份不会互换。 |
| 腾讯元宝 | [适配器](../../ai-arena-extension/src/content-yuanbao.js) | 可选 / 有 | 新对话与临时对话都需确认页面状态；切换失败时明确标明。 |
| Google AI Studio | — | 可选 / 有 | 无痕/临时模式切回常规后，再开一题，核对新题实际模式。 |

### 一条“兼容”记录需要什么

自用工作台的 ChatGPT、Gemini、DeepSeek 已通过隔离三席回放和授权账号实跑。实跑只点一次开始，共核对 10 次派发和读回，完成独立作答、互评、候选和同版表态。隔离用例另覆盖单席接管、暂停和异常读回。 [本轮记录](iterations.md)

1. 写下日期、Chrome 版本、扩展/适配器版本、语言、宽/窄布局、账号类型和站点可见模型名。账号身份、私有对话链接、凭据不进入样本。
2. 为每项能力分别记“通过 / 失败 / 人工 / 未测”。最小矩阵是开会话、输入、确认提交、识别本轮答复、识别结束、连续两轮、刷新恢复。填写成功只能勾选输入一项。
3. 使用不含隐私的唯一题面。在允许的实际操作方式下完成两轮，逐席比对原页与工作台的正文、所属轮次、答复数量，保留失败现象。模型选择不明、登录缺失、限流、内容截断分开记。
4. 从故障提炼最小脱敏页面样本，用浏览器层回放。先让旧适配器在该样本上表现出故障，再用新版本通过；重跑其他站共享用例。真实站再测的结果另记。平台条款与账号授权记录另列，不从技术测试推断许可。

参考测试可从 [Arena 的真实辩论脚本](../../ai-arena-extension/tests/e2e/real-debate.mjs)、[流式状态测试](../../ai-arena-extension/src/test/streaming-detect.test.mjs)、[恢复测试](../../ai-arena-extension/src/test/chat-bus-resume.test.mjs)、[Panelize 的浏览器回放](../../Panelize/tests/e2e/chatgpt-send-all.e2e.test.js)和[真实网站测试](../../Panelize/tests/live/providers.live.test.js)开始。两家真实站完整跑通、一个站点自动加另一个站点人工、两个自建测试页自动跑通，应在验收记录中写出各自的条件。
