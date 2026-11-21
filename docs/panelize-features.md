# Panelize 功能与验证清单

每项记录参考版本的行为、自用版的取舍、开发时应执行的验证。排除项验证其从自用版界面、导出或运行时移除。以下为源码分析与验收设计，实测结果尚待填写。版本见[源码分析](reference-review.md)。

<a id="p01"></a>

### P01　打开与复用工作台

扩展图标及快捷键打开/聚焦面板；可选标签或独立窗口，2.2.4 尽量移动已有标签保留活动页和草稿。

- **参照版复核**　分别用工具栏、打开快捷键和提示库快捷键启动；在含未发送草稿时切标签/独立窗口。
- **自用版取舍**　首版·复用讨论标签。
- **验证**　有未发草稿时反复打开、切窗和返回，页面实例与草稿不变。
- **源码**　[service-worker.js](../../Panelize/background/service-worker.js) · [open-mode-switcher.js](../../Panelize/modules/open-mode-switcher.js)

<a id="p02"></a>

### P02　面板编排

添加、移除、更换提供方，面板内刷新，顶部选择器管理席位；可折叠工具栏。

- **参照版复核**　增加、替换、刷新、移除一列，再折叠工具栏；观察哪些操作重建页面、哪些仅改布局。
- **自用版取舍**　首版·成员栏和对照视图。
- **验证**　只刷新 B 时 A 的长答与用户滚动位置保留；删除/更换参与者留下历史归属。
- **源码**　[multi-panel.js](../../Panelize/multi-panel/multi-panel.js) · [multi-panel.html](../../Panelize/multi-panel/multi-panel.html)

<a id="p03"></a>

### P03　网格与列宽

选择单列至多列、堆叠和网格；随成员数调整布局，拖拽或键盘改列宽，双击重置，窄列适配原页。

- **参照版复核**　切 1×2 和网格，拖列边、键盘调宽、双击重置，切回原布局检查列宽记忆。
- **自用版取舍**　首版两席对照；任意布局后续。
- **验证**　改变宽度后可读同一句、保留完整代码；用键盘调整并还原。
- **源码**　[layout-auto-adjust.js](../../Panelize/modules/layout-auto-adjust.js) · [panel-fit.js](../../Panelize/modules/panel-fit.js) · [panel-resize.js](../../Panelize/modules/panel-resize.js)

<a id="p04"></a>

### P04　统一填写与发送

底部输入可只填、群发、清除；已有各页草稿时可触发各页发送；群发期间锁住重复操作。

- **参照版复核**　同一条文本依次做仅填、群发、清空；留空统一框、在原页有草稿时试“发送”。
- **自用版取舍**　首版·只对本场草稿操作。
- **验证**　只填后页面无新增轮次；连续两次 Enter 至多提交一次；在已有用户草稿的页面拒绝覆盖。
- **源码**　[multi-panel.js](../../Panelize/multi-panel/multi-panel.js) · [panel-action-results.js](../../Panelize/modules/panel-action-results.js)

<a id="p05"></a>

### P05　输入焦点与快捷键

全局打开工作台和提示库；设置启停快捷键，提供 Enter 换行/发送预设及自定义。保护统一输入焦点，也允许用户点回单页编辑。

- **参照版复核**　修改 Enter 预设，在统一框和原页编辑器分别按键；填入后检查下次按键所在焦点。
- **自用版取舍**　首版·键盘发送与焦点；全局定制后续。
- **验证**　中文输入法选词时 Enter 不误发；填入后下一次发送给正确接收方；用户点击原页后不会被拉回。
- **源码**　[focus-toggle.js](../../Panelize/content-scripts/focus-toggle.js) · [enter-behavior-utils.js](../../Panelize/content-scripts/enter-behavior-utils.js) · [options.html](../../Panelize/options/options.html)

<a id="p06"></a>

### P06　图片附件

选择、拖入或粘贴多张图，预览移除；按席检查支持情况，失败的附件可针对失败面板重试，部分自定义站支持纯文本降级。

- **参照版复核**　导入两张图，删一张；造一席图片失败，核对再次填写的对象与图片数量。
- **自用版取舍**　后续。
- **验证**　两席分别支持与不支持图片时清楚显示实际交付；重试不重复附上已成功的图片。
- **源码**　[multi-panel.js](../../Panelize/multi-panel/multi-panel.js) · [text-injection-all-providers.js](../../Panelize/content-scripts/text-injection-all-providers.js) · [panel-action-results.js](../../Panelize/modules/panel-action-results.js)

<a id="p07"></a>

### P07　新对话与临时对话

统一开新会话，支持的站点可切临时模式；部分站以页面控件、特定入口或重试完成。

- **参照版复核**　临时模式开启和关闭后分别统一开新对话，逐页确认真实站点状态。
- **自用版取舍**　首版专用新会话；临时模式后续。
- **验证**　站 A 支持临时、B 不支持，逐席标明；开新对话后旧场次引用仍指向旧记录。
- **源码**　[provider-registry.js](../../Panelize/modules/provider-registry.js) · [text-injection-all-providers.js](../../Panelize/content-scripts/text-injection-all-providers.js)

<a id="p08"></a>

### P08　内置与可选站点

注册表收录 14 个提供方。设置启停、排序；部分站需单独授域权限。撤销权限后重算可用状态。

- **参照版复核**　记录默认启用列表、设置中启停/拖动顺序的变化，拒绝再重新授予可选站点权限。
- **自用版取舍**　首版·按能力登记；逐站扩展。
- **验证**　撤销一个站的访问权限，只该站转为待处理；排序不改历史成员 ID。
- **源码**　[provider-registry.js](../../Panelize/modules/provider-registry.js) · [optional-provider-access.js](../../Panelize/modules/optional-provider-access.js) · [options.js](../../Panelize/options/options.js)

<a id="p09"></a>

### P09　Google 两种模式

支持 Google 普通搜索与 AI 模式，设置与面板可切换，同步相应入口。

- **参照版复核**　在设置与面板分别切换 Google 两种模式，核对目标 URL 和其他面板。
- **自用版取舍**　排除普通搜索；AI 模式候选。
- **验证**　普通搜索结果永远不会自动成为某席回答；若引入 AI 模式再验证其对话连续性。
- **源码**　[google-mode.js](../../Panelize/modules/google-mode.js) · [multi-panel.js](../../Panelize/multi-panel/multi-panel.js)

<a id="p10"></a>

### P10　自定义网页

提供线上网站、本地/自建网页两个配置入口及预设；校验 URL、域名重复、来源标记，支持编辑删除与单域授权，通用输入驱动依站点能力工作。

- **参照版复核**　用测试网页分别走线上、自建入口，检查非法 URL、已占用域名、改名和删除。
- **自用版取舍**　后续；自建站可作首轮技术验证环境。
- **验证**　新增自有实例、拒绝/撤销授权、更换域、删除；核对站点归属和旧任务状态，不宣称所有自定义站可自动辩论。
- **源码**　[custom-providers.js](../../Panelize/modules/custom-providers.js) · [url-validator.js](../../Panelize/modules/url-validator.js) · [custom-provider-driver.js](../../Panelize/content-scripts/custom-provider-driver.js) · [options.js](../../Panelize/options/options.js)

<a id="p11"></a>

### P11　自定义 API

兼容端点、模型列表或手填模型、可选密钥；流式输出、图片、Markdown/代码；可与网页席混排。密钥有本地独立存储。

- **参照版复核**　用本地测试端点拉模型、选择模型和发起流式会话；断开连接观察错误及密钥存储范围。
- **自用版取舍**　后续备选·首版网页路径独立。
- **验证**　以后若接入，用本地模拟服务验证模型枚举、中断、取消、认证失败；导出与同步数据不含密钥。
- **源码**　[api-panel.js](../../Panelize/api-panel/api-panel.js) · [openai-chat-client.js](../../Panelize/modules/openai-chat-client.js) · [custom-api-secrets.js](../../Panelize/modules/custom-api-secrets.js)

<a id="p12"></a>

### P12　网页嵌入与会话兼容

真实网页内嵌；维护每站嵌入加载、登录状态、服务工作线程缓存等兼容逻辑；面板与扩展互校来源。

- **参照版复核**　在固定页面样本模拟成功/拒绝嵌入和错误来源的回执；区分 iframe 内与普通标签的表现。
- **自用版取舍**　改造·普通原页标签与通信校验。
- **验证**　受限网站仍可在正常浏览器标签里由用户操作；来自其他标签或域的回执不能改变任务。
- **源码**　[multi-panel.js](../../Panelize/multi-panel/multi-panel.js) · [frame-header-rules.js](../../Panelize/modules/frame-header-rules.js) · [panel-message-contract.js](../../Panelize/modules/panel-message-contract.js) · [custom-sw-recovery.js](../../Panelize/modules/custom-sw-recovery.js)

<a id="p13"></a>

### P13　发送动作回执

部分填写操作匹配 provider、来源窗口、来源域、动作和 requestId；失败原因及等待时限可见。

- **参照版复核**　模拟同一动作的正确、过期和来源不匹配回执，检查成功或超时状态。
- **自用版取舍**　首版·扩展到每个辩论回合。
- **验证**　回放正确、失配、迟到和重复四种回执；只有正确回执推进对应动作，填好不等于回答已完成。
- **源码**　[panel-action-results.js](../../Panelize/modules/panel-action-results.js) · [panel-message-contract.js](../../Panelize/modules/panel-message-contract.js)

<a id="p14"></a>

### P14　自定义站点同意选择与登录兼容

针对嵌入情形有 cookie 同意选择的持久化及个别站会话兼容逻辑。

- **参照版复核**　在授权测试页改变同意选择并重开，核对嵌入页面状态；原站登录另记。
- **自用版取舍**　排除嵌入专用处理。
- **验证**　每次登录、同意条款或验证码都留在原站，由用户操作；新扩展不搬运会话凭据。
- **源码**　[custom-provider-cookie-consent.js](../../Panelize/content-scripts/custom-provider-cookie-consent.js) · [grok-cookie-consent.js](../../Panelize/content-scripts/grok-cookie-consent.js) · [grok-websocket-cookies.js](../../Panelize/modules/grok-websocket-cookies.js)

<a id="p15"></a>

### P15　从其他网页带入材料

右键选区或页面；没有选区时尝试提取正文。可选来源 URL 在首、尾或省略。名为 sendToPanel 的接收路径实际填入草稿。

- **参照版复核**　分别选中文本和不选文本启动右键入口，检查来源 URL 放在首、尾、省略时的统一输入。
- **自用版取舍**　后续选区；整页抓取排除。
- **验证**　选择两段中的一段，仅该段进入草稿，取消时各站无新增提问。
- **源码**　[service-worker.js](../../Panelize/background/service-worker.js) · [page-content-extractor.js](../../Panelize/content-scripts/page-content-extractor.js) · [multi-panel.js](../../Panelize/multi-panel/multi-panel.js)

<a id="p16"></a>

### P16　提示词收藏库

新建、编辑、删除，分类、标签、搜索、收藏、最近使用；变量对话框填值后应用，可导入默认库和自定义文件。

- **参照版复核**　新建带两个变量的模板，搜索、收藏、填值并应用；重启查看最近项与分类。
- **自用版取舍**　后续·个人模板。
- **验证**　用含两个变量的模板，填写和取消各一次；检查最终文本、最近使用、重名导入及删除。
- **源码**　[prompt-manager.js](../../Panelize/modules/prompt-manager.js) · [multi-panel.html](../../Panelize/multi-panel/multi-panel.html) · [options.js](../../Panelize/options/options.js)

<a id="p17"></a>

### P17　对照图

当前视图或全回答滚动拼接，标题可改、预览、进度/取消，复制或下载 PNG；在面板内触发扩展也会走截图入口。

- **参照版复核**　对长对话分别预览当前截图和完整拼接，编辑标题、取消、复制和另存。
- **自用版取舍**　后续·个人无水印导出。
- **验证**　长答覆盖首尾，无重复固定工具栏；取消停止捕获，复原滚动位置；只复制/保存指定结果。
- **源码**　[snapshot-capture.js](../../Panelize/modules/snapshot-capture.js) · [snapshot-stitch.js](../../Panelize/modules/snapshot-stitch.js) · [share-snapshot.js](../../Panelize/modules/share-snapshot.js) · [share-trigger.js](../../Panelize/modules/share-trigger.js)

<a id="p18"></a>

### P18　数据管理

设置和提示词有导入、导出；清提示库、重置偏好是独立操作。普通设置使用浏览器 sync，密钥与提示库另行保存。

- **参照版复核**　分别导出设置和提示词，再导入有效与无效文件；核对清库与恢复设置的影响范围。
- **自用版取舍**　首版本地偏好；备份恢复后续。
- **验证**　导入损坏文件不丢现有数据；清提示库不影响历史讨论；备份不含认证信息。
- **源码**　[settings.js](../../Panelize/modules/settings.js) · [prompt-manager.js](../../Panelize/modules/prompt-manager.js) · [options.js](../../Panelize/options/options.js)

<a id="p19"></a>

### P19　外观与本地化

系统/亮/暗主题、多语言界面、Edge 快捷键设置提示。

- **参照版复核**　切换亮/暗/自动及两种语言，对照设置和多面板工具提示；检查快捷键帮助入口。
- **自用版取舍**　首版中文和系统外观；多语言与 Edge 指引后续。
- **验证**　切系统外观后正文可读；中文站点切英文界面仍按站点能力实测，记录界面语言。
- **源码**　[theme-manager.js](../../Panelize/modules/theme-manager.js) · [i18n.js](../../Panelize/modules/i18n.js) · [options.html](../../Panelize/options/options.html)

<a id="p20"></a>

### P20　评分引导

按成功群发次数计数，首次达到 20 次提示评分；可评分、稍后或永久关闭，稍后间隔为 50 次。

- **参照版复核**　以干净计数模拟第 19、20 次成功发送，再分别点稍后、不再提示，核对后续触发条件。
- **自用版取舍**　排除。
- **验证**　模拟超过两次阈值，界面无评分提示，存储无评分计数或提醒状态。
- **源码**　[rating-prompt.js](../../Panelize/modules/rating-prompt.js) · [multi-panel.html](../../Panelize/multi-panel/multi-panel.html)

<a id="p21"></a>

### P21　品牌水印与导流

分享图默认可附品牌及站点条，设置可关；设置另有外部配置指南。

- **参照版复核**　同一画面打开/关闭水印各导出一次，核对品牌条和设置里的官网指南入口。
- **自用版取舍**　排除水印、推广链接；帮助改成本地说明。
- **验证**　设置、空态、结论和导出均无推广链接，图片没有品牌栏；许可证保留作者署名。
- **源码**　[share-snapshot.js](../../Panelize/modules/share-snapshot.js) · [options.html](../../Panelize/options/options.html)

<a id="p22"></a>

### P22　上游版本检查

提供安装版本信息及检查更新的逻辑，后台另有取得公开提交元数据的路径。

- **参照版复核**　从关于页点检查更新，分别给新版本、相同版本和网络故障，检查呈现及跳转目标。
- **自用版取舍**　排除连接参考项目更新源。
- **验证**　断网打开设置仍可读自己的版本，网络记录无参考项目发布或提交查询。
- **源码**　[version-checker.js](../../Panelize/modules/version-checker.js) · [service-worker.js](../../Panelize/background/service-worker.js)

<a id="p23"></a>

### P23　真实站与本地回放

一套测试使用固定页面和扩展交互，另一套使用真实网站及已登录配置，是否实际发送另有开关。

- **参照版复核**　查看固定站点拦截测试与单站真实测试的启动条件，分别登记样本来源和是否真实发送。
- **自用版取舍**　首版·分别记结果。
- **验证**　同一站标为“样本通过、实站待测”时不会展示已兼容；实站结果带日期、操作和账号界面条件。
- **源码**　[providers.live.test.js](../../Panelize/tests/live/providers.live.test.js) · [chatgpt-send-all.e2e.test.js](../../Panelize/tests/e2e/chatgpt-send-all.e2e.test.js)
