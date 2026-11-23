# 网页站点验证

## macOS 原生工作台

2026-11-22，ChatGPT、Gemini、DeepSeek 在已登录的原生 WebView 中各自完成了独立作答、读取另外两席原文并互评、对同一候选版本表态。一场新讨论只触发一次“开始”，在一轮上限保留了一席的附加条件。另一场从旧记录恢复，第二轮三席同意 v2。0.3.0 的界面更新另用独立 QA 应用和回环测试页验收。 [原生验收记录](iterations.md#2026-11-22--原生英文发送长提示核对和多轮收敛) · [桌面版测试入口](../desktop/README.md#构建和验收)

0.5.0 的改动仅使用回环夹具进行行为验收。ChatGPT、Gemini 和 DeepSeek 的真实站点复测待完成。

### 0.6.0 开场附件（构建 7）

本地 AppKit 已验证从包含多条文件记录的剪贴板加入附件、连续粘贴图片、读取 PNG 和 TIFF 剪贴板图像，以及将普通文字插入光标所在位置。混合批次含不支持类型时，整批拒绝，原草稿保留。测试使用应用的实际输入控件和独立剪贴板。另在原生 QA 窗口核对了两图一文的显示，并通过系统粘贴菜单添加一张 PNG。[附件验收命令](../desktop/README.md#构建和验收)

三席正常场的 WebKit 回环验收逐一比对首轮两张图片的 SHA-256、顺序、同条消息中的附件和文本文件正文。三席均取得回执，后续七次派发均未再次挂图。移除 Finder 原文件后重启，场次报告和 Markdown 导出可读，发送总数仍为 10。

回环页另覆盖两种真实站点上观察到的显示方式。ChatGPT 的文件名与正文同时显示时仍能核对题面。Gemini 的预览和已发图片都没有文件名时，按整张图片的像素和顺序核对。交换两张无名图片的顺序后，该席没有点击发送，其余席位照常作答。

WebKit 回环页还复现了三类单席异常。只挂上一张图的席位没有点击发送。已有用户附件的席位保留原草稿。点击后消息缺第二张图的席位保持待核对，重启后没有再次上传。恢复测试还用新建的 WebKit 视图离线重放绑定会话，按保存的像素摘要成功读取原答复。交换图片顺序后拒收答复。两次恢复均未点击发送。

2026-11-23 在 macOS 27.0.1 上用原生开发探针操作真实 WebKit 网页。三个新对话各发送一次相同问题和两张 400 × 300 的合成图。对每条已发用户消息内的两张图按顺序读取 RGBA 像素，与本地图片的像素 SHA-256 逐一比对。答复检查按红、圆、左、蓝、三角、右六个预期词项分别匹配。

| 席位 | 编辑区挂图 | 已发消息核对 | 答复词项检查 |
| --- | --- | --- | --- |
| ChatGPT（en-US） | 经 Attach files 入口可见两图 | 两图像素和顺序吻合 | 六项均命中 |
| Gemini（zh-CN） | 可见两张预览，预览未显示文件名 | 两图像素和顺序吻合 | 六项均命中 |
| DeepSeek（en-US） | 可见两张预览，文件名与顺序吻合 | 两图像素和顺序吻合 | 六项均命中 |

另用 0.6.0 应用分场检验自动派发。三席场中，Gemini 取得首轮材料回执，回答正确描述了两图的颜色、形状和方位。双席场中，DeepSeek 也取得回执并给出正确描述。ChatGPT 因原页残留测试草稿及上传入口未就绪停下处理。清理该测试草稿并修正上传入口的就绪判断后，从同一场继续，ChatGPT 取得回执，保存的首轮答案准确描述了两图。已答的 DeepSeek 没有重复收到首轮问题。双席场最终完成 7 个任务，后续各轮均未再次附图。对候选 v1，ChatGPT 有条件同意，DeepSeek 同意，生成了 5768 字的 Markdown 报告。三席同场从附图开场到报告的真实账号全程验收仍待完成。

在真实站点复验时，可使用两张自制图，在一张画圆，另一张画三角形。用同一问题请各席按图号说出形状。先看编辑区能否按顺序挂齐两张图，再核对发送后的同一条用户消息带了哪些图，最后看答复能否正确区分两图。某一项无法判断时记录具体可见现象。限额、模型视觉能力和原页回执分别记录。

## 如何记录兼容性

1. 写下日期、macOS 与应用版本、界面语言、窗口尺寸、账号类型和站点可见模型名。账号身份、私有对话链接、凭据不进入样本。
2. 为每项能力分别记“通过 / 失败 / 人工 / 未测”。最小矩阵是开会话、输入、确认提交、识别本轮答复、识别结束、连续两轮、刷新恢复。填写成功只能勾选输入一项。
3. 使用不含隐私的唯一题面。在允许的实际操作方式下完成两轮，逐席比对原页与工作台的正文、所属轮次、答复数量，保留失败现象。模型选择不明、登录缺失、限流、内容截断分开记。
4. 从故障提炼最小脱敏页面样本，用 WebKit 回环夹具回放。先让旧适配器在该样本上表现出故障，再用新版本通过；重跑其他站共享用例。真实站再测的结果另记。平台条款与账号授权记录另列，不从技术测试推断许可。

## 早期 Chrome 扩展验证

自用工作台的 ChatGPT、Gemini、DeepSeek 已通过隔离三席回放和授权账号实跑。实跑只点一次开始，共核对 10 次派发和读回，完成独立作答、互评、候选和同版表态。隔离用例另覆盖单席接管、暂停和异常读回。 [本轮记录](iterations.md)

## 参考项目站点清单

两库合计出现 14 个不同的内置站点入口。Arena 为其中 9 个站点提供回答读取脚本。Panelize 的 14 个入口中，注册表将 8 个列为常规、6 个列为可选授权。下表的“临时”仅表示 Panelize 在描述符内声明了临时会话配置。表中列的是参考项目的入口与逐站待核场景。[Arena 站点清单](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/manifest.json) · [Panelize 描述符](https://github.com/Manho/Panelize/blob/e6d15b4f1e8222de02c770c6d5d78898252f8301/modules/provider-registry.js)

| 站点 | Arena 源码 | Panelize 接入 / 临时配置 | 该站首个差异用例 |
|---|---|---|---|
| ChatGPT | [适配器](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-chatgpt.js) | 常规 / 有 | 同时存在隐藏旧编辑器、桌面和窄屏输入；记录可见编辑器及原生发送状态。 |
| Claude | [适配器](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-claude.js) | 常规 / 有 | 带长引用的回复，检查正文清理后引用仍在；新对话控件与正文里的链接区分。 |
| Gemini | [适配器](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-gemini.js) | 常规 / 有 | 中文与英文界面、输入框延迟出现；区分未登录、加载中和可以发送。 |
| Grok | [适配器](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-grok.js) | 常规 / 有 | 在正常网页确认可进入对话；单独验证隐私对话，记录原页状态。 |
| DeepSeek | [适配器](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-deepseek.js) | 常规 / 无 | 思考段、正式答案、长停顿共存；只采纳正式答案。 |
| Kimi | [适配器](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-kimi.js) | 常规 / 无 | 登录跳转与窄屏布局，确认回复对应同一对话，长输入未变成空白。 |
| Google 搜索 / AI 模式 | — | 常规 / 无 | 切搜索与 AI 模式，检测只有搜索结果时不能参与多轮。 |
| 豆包 | [适配器](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-doubao.js) | 常规 / 无 | 富文本编辑器更新后，用多段中文试填写与提交，核对换行及完整题面。 |
| 千问中国版 | [适配器](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-qwen.js) | 可选 / 无 | 专测两轮长文与旧答残留，核对两种加人顺序；通过验证后再决定新版组合限制。 |
| Qwen Global | — | 可选 / 无 | 区分中国站与海外站的域名、登录状态和收件人，撤权仅影响海外席位。 |
| 智谱清言 | — | 可选 / 无 | 同意及拒绝授权各试一次，再验证新会话和中文输入。 |
| Z.ai | — | 可选 / 无 | 与智谱清言同时登记时，核对来源和站点身份不会互换。 |
| 腾讯元宝 | [适配器](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-yuanbao.js) | 可选 / 有 | 新对话与临时对话都需确认页面状态；切换失败时明确标明。 |
| Google AI Studio | — | 可选 / 有 | 无痕/临时模式切回常规后，再开一题，核对新题实际模式。 |

上游测试入口包括 [Arena 真实辩论](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/tests/e2e/real-debate.mjs)、[流式状态](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/test/streaming-detect.test.mjs)、[恢复](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/test/chat-bus-resume.test.mjs)、[Panelize 浏览器回放](https://github.com/Manho/Panelize/blob/e6d15b4f1e8222de02c770c6d5d78898252f8301/tests/e2e/chatgpt-send-all.e2e.test.js)和[真实网站测试](https://github.com/Manho/Panelize/blob/e6d15b4f1e8222de02c770c6d5d78898252f8301/tests/live/providers.live.test.js)。
