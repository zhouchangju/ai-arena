# AI Arena Extension 功能与验证清单

这是早期扩展阶段的上游源码调研与验收设计。「自用版取舍」记录当时的方案。当前 macOS 工作台的功能与验收见[产品设计](product-design.md)和[试用指引](try-it.md)。上游版本见[参考项目分析](reference-review.md)。

<a id="a01"></a>

### A01　启动入口

工具栏、侧栏、独立群聊窗口，后台将消息同步给已打开的界面。

- **参照版复核**　在原版从工具栏打开群聊，再从侧栏打开群聊；观察哪个窗口被聚焦、状态是否一致。
- **自用版取舍**　首版·单一工作台。
- **验证**　连续点两次扩展图标，回到同一场讨论；关闭工作台再打开能读到刚才的进展。
- **源码**　[background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js) · [popup.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup.js) · [sidepanel.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/sidepanel.js)

<a id="a02"></a>

### A02　安装与首次使用

欢迎页演示、五页教程、四步引导可跳过并重开，首答后给下一步操作，帮助浮标汇集 FAQ 与体检。

- **参照版复核**　新配置逐步完成加席、登录、首答、再加席；分别跳过、重开教程，确认已记住的进度。
- **自用版取舍**　改造·保留就绪指引。
- **验证**　新配置从零加入两位成员并开始首问；缺登录时有具体操作；再次打开无需重走。
- **源码**　[welcome.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/welcome.js) · [popup-onboarding.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-onboarding.js) · [popup-tutorial.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-tutorial.js) · [popup-help-fab.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-help-fab.js)

<a id="a03"></a>

### A03　精简与完整模式

精简页有成员栏、同时提问与条件点亮的辩论/总结按钮。进阶解锁、更多菜单、空状态功能定位提供第二入口。

- **参照版复核**　新配置与已有成员配置分别打开，记录起始模式和辩论按钮点亮条件；从更多菜单找回折叠操作。
- **自用版取舍**　改造·核心动作常驻。
- **验证**　两份完整答复到齐可进入互评；只收到一份时说明缺谁，键盘也能到达。
- **源码**　[popup-simple-mode.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-simple-mode.js) · [popup-progressive.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-progressive.js) · [popup-feature-tour.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-feature-tour.js) · [popup-more-menu.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-more-menu.js)

<a id="a04"></a>

### A04　成员与组合

九个站点入口、增删成员、推荐组合、一键加入；后台最多三席，明确拒绝千问与其他平台混用。按参与者发号，部分收集逻辑按服务标识。

- **参照版复核**　添加三席后尝试第四席；分别先加千问和最后加千问，检查提示。点一键组合核对实际成员。
- **自用版取舍**　首版·两席起步，按实测开放组合。
- **验证**　分别试千问先入/后入；记录旧版限制。新版同一站多个会话须能分别归属，否则禁用该组合。
- **源码**　[popup-members.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-members.js) · [background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js) · [chat-bus.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/chat-bus.js)

<a id="a05"></a>

### A05　登录和标签管理

探测登录、复查、激活原页、重开关闭的页、重新加载；显示每个成员的就绪状态。

- **参照版复核**　关闭一席对应的网页，分别点击唤起、重开、登录复查，记录能否回到原会话。
- **自用版取舍**　首版。
- **验证**　一个成员退出登录，其他成员继续；重新登录后恢复该席，不能误绑同站另一段对话。
- **源码**　[background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js) · [popup-members.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-members.js)

<a id="a06"></a>

### A06　标签、多屏和小窗

同窗口多标签或分窗并列、重排多屏、依次唤起成员；Mini Bar 折叠/恢复大小，缩小后仍能查看成员状态和操作。

- **参照版复核**　在标签、并列、Mini Bar 间切换；在双屏下观察新窗口位置，检查小窗成员状态、展开后尺寸。
- **自用版取舍**　首版用标签；排窗与 Mini Bar 后续。
- **验证**　切换显示器、展开折叠、移除一席，各动作均不新发问题；窗口尺寸与原标签身份可核对。
- **源码**　[popup-window-mode.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-window-mode.js) · [popup-mini-mode.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-mini-mode.js) · [popup-mini-roster.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-mini-roster.js) · [background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js)

<a id="a07"></a>

### A07　同时提问与单独追问

群聊输入、Ctrl+Enter、@ 补全、定向或多选接收者；侧栏也可广播。

- **参照版复核**　广播一句唯一文本，另发 @ 单席文本；逐页核对收件人、发送次数。分别从群聊和侧栏开始。
- **自用版取舍**　首版。
- **验证**　广播一次两页各收一份；仅选 B 时 A 不收到；检查两个入口触发同一发送命令。
- **源码**　[popup.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup.js) · [popup-roster.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-roster.js) · [sidepanel.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/sidepanel.js) · [background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js)

<a id="a08"></a>

### A08　网页选区提问

扩展登记选中文字的右键提问菜单，由后台处理。

- **参照版复核**　在普通网页选一句话并点右键菜单，确认侧栏收到的草稿与选区相同。
- **自用版取舍**　后续·只进入草稿。
- **验证**　选一段正文后进入预览，能修改或取消；取消时各站没有新增消息。
- **源码**　[background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js)

<a id="a09"></a>

### A09　图片和文本附件

侧栏可选文件、粘贴图片、预览移除；文本文件读作正文，图片单独注入。群聊主界面则提示去原网页上传。

- **参照版复核**　从侧栏粘图、选文本、移除附件，查看实际发送内容；在群聊中核对上传引导。
- **自用版取舍**　后续·两条入口分别验。
- **验证**　粘两图删除一张，再加一份文本；逐席核对实际收到的内容。缺附件的一席不能声称已看图。
- **源码**　[sidepanel.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/sidepanel.js) · [popup.html](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup.html) · [inject-images.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/inject-images.js)

<a id="a10"></a>

### A10　网页发送与回执

各站识别编辑器和发送按钮，可能返回已填入、已发、警告或错误。后台侧栏广播把 sent 和 inputted 都计入成功条件。

- **参照版复核**　分别提供可正常发送、按钮禁用和仅可填入的页面样本，记录站点结果及后台广播状态。
- **自用版取舍**　改造·区分填好和已提交。
- **验证**　已填但未提交时留在待发送；回执丢失时先对账；页面只出现一份相同问题。
- **源码**　[background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js) · [content-shared.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-shared.js) · [content-chatgpt.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-chatgpt.js)

<a id="a11"></a>

### A11　流式读回

站点专用提取、共享流式判断、文本稳定性及图文待加载判断，检查登录提示、旧答、提示词回显、千问噪声。

- **参照版复核**　页面预放一条旧答，新答分三段且中途暂停；比对气泡、状态及最终采用文字。
- **自用版取舍**　首版。
- **验证**　回放旧答、思考停顿、两段等长文字、复制按钮噪声及纯图片结果；只将可归属的完成正文投入互评。
- **源码**　[chat-bus.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/chat-bus.js) · [content-shared.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-shared.js) · [qwen-noise-filter.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/qwen-noise-filter.js)

<a id="a12"></a>

### A12　群聊与阅读

流式气泡、轮次徽记、自动跟随滚动、折叠长文、简洁阅读、复制、头像跳原页、查看发送给 AI 的提示词；侧栏有动态预览。

- **参照版复核**　阅读流式长文中途上滚、折叠、展开、查看提示词并复制；在侧栏悬停观察预览。
- **自用版取舍**　首版·按轮次读。
- **验证**　滚动查上一轮时新字不抢位置；点击旧轮提示词能看到当时版本；复制折叠长文得到完整内容。
- **源码**　[popup.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup.js) · [popup-bubble-actions.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-bubble-actions.js) · [popup-compact-mode.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-compact-mode.js) · [popup-arena-badge.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-arena-badge.js) · [sidepanel.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/sidepanel.js)

<a id="a13"></a>

### A13　富文本

支持 Markdown、表格、数学表达降级显示，HTML/SVG 代码块可切换预览。

- **参照版复核**　在一条回答放标题、表格、公式、代码和 SVG 样例，在普通显示、源码、预览间切换。
- **自用版取舍**　首版正文及代码；可执行预览排除。
- **验证**　含表格、公式及 HTML 示例的回答能读、能复制；来自模型的内容始终不会操作扩展页面。
- **源码**　[popup-markdown.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-markdown.js) · [popup-codepreview.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-codepreview.js)

<a id="a14"></a>

### A14　轮次前检查

检查是否已有至少两份回答、是否仍轮询、过短或与上轮相同。可提示重提取或由用户决定继续。

- **参照版复核**　仅一份回答时尝试开辩；两席分别处于生成中、过短或沿用上次内容时检查提示。
- **自用版取舍**　首版。
- **验证**　一份旧答加一份有效答不能开始正式互评；很短的有效回答可人工核实，保留判断依据。
- **源码**　[background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js) · [popup-tasks.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-tasks.js)

<a id="a15"></a>

### A15　自由辩论与群策群力

按风格和轮号生成提示，排除接收者自己的回答；支持用户引导、简洁输出。前几轮有专用模板。

- **参照版复核**　同样两份回答分别启动自由和协作，查看每位收到的提示和本轮引导，核对排除了自己。
- **自用版取舍**　首版自由互评；协作作为可选策略。
- **验证**　给两人不同的限定条件，检查双方下一轮确实看到了对方那条条件，同轮看不到对方正在写的草稿。
- **源码**　[debate-engine.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/debate-engine.js) · [templates-builtin.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/templates-builtin.js)

<a id="a16"></a>

### A16　选人和改写下轮材料

成员开关决定接收方；在 roster 中编辑用作后续输入的答复，失焦保存，避免轮询覆盖用户修改。

- **参照版复核**　取消选中一席，编辑另一席的转发材料后失焦，再触发新一帧更新，检查保存和接收方。
- **自用版取舍**　改造·派生副本。
- **验证**　把一句引述改成假设，预览显示“用户编辑”；原回答与引用仍可单独查看。
- **源码**　[popup-roster.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-roster.js) · [background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js)

<a id="a17"></a>

### A17　压缩与单席补发

可截取队友长回答首尾，按总预算收紧；记录单席 prompt 和失败名单，支持常规或压缩后补发。

- **参照版复核**　准备过长队友答复和一席失败场景，比较压缩前后发送内容并检查仅失败席被补发。
- **自用版取舍**　首版·保全未解反例。
- **验证**　把唯一反例放在长文中间。转发预算到顶后仍可定位该反例；补发 B 不改 A 的答复。
- **源码**　[debate-engine.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/debate-engine.js) · [popup-tasks.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-tasks.js) · [background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js)

<a id="a18"></a>

### A18　顺序接力

用户排序，后来成员看到前面成员本轮的观点，逐个等待答复。

- **参照版复核**　拖动排序后依次发言，对照后发者的实际 prompt；空问题和重复顺序应得到对应提示。
- **自用版取舍**　后续·单独协议。
- **验证**　交换 A、B 顺序，验证首次发言者看不到后来者观点；中途断线能指出停在哪一席。
- **源码**　[popup-tasks.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-tasks.js) · [background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js)

<a id="a19"></a>

### A19　队长和角色帽

首位成员可承担整合职责，界面可只看队长；澄清、核查、挑战、综合、行动五种角色可分工。

- **参照版复核**　开启队长模式，比较首位和另一位的真实 prompt；设置角色后在只看队长视图来回切换。
- **自用版取舍**　后续·独立首轮保持同题。
- **验证**　检查角色提示仅发给被指定者；切换只看队长后，其余原文和异议仍保留。
- **源码**　[captain-mode.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/captain-mode.js) · [popup-role-hats.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-role-hats.js) · [popup-bubble-actions.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-bubble-actions.js)

<a id="a20"></a>

### A20　裁判与报告

选裁判，可附要求，生成文本或结构化报告，展示共识、分歧、论证等；解析失败回显原文，可打开报告或定位下载文件。

- **参照版复核**　选裁判分别生成文本/结构化报告，输入合法、回显模板及截断输出，观察解析、回退和下载行为。
- **自用版取舍**　首版·引用到具体轮次。
- **验证**　首轮独有反例进入报告；截断 JSON、错误引用、漏掉一名成员时报告保持草稿或部分结果。
- **源码**　[debate-engine.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/debate-engine.js) · [debate-summary-template.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/debate-summary-template.js) · [background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js)

<a id="a21"></a>

### A21　接棒简报

选浓缩官、长度与立场，生成面向新对话的简报，边生成边回填输入，用户可编辑。

- **参照版复核**　指定浓缩官、长度、立场，检查简报流入主输入框，允许改写再使用。
- **自用版取舍**　后续。
- **验证**　分别选中立和鼓励反方，生成后核对关键事实和分歧；草稿需可编辑，不能直接发给新成员。
- **源码**　[baton-prompts.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/baton-prompts.js) · [popup-tasks.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-tasks.js)

<a id="a22"></a>

### A22　回答对照与导出

本轮回答并排、字数对照、复制 Markdown、导出离线 HTML；另有会话轮次记录导出。

- **参照版复核**　用一轮长短不同的答复打开对比，复制 Markdown 和导出 HTML；用会话导出检查覆盖的轮次。
- **自用版取舍**　首版并排与 Markdown；HTML 后续。
- **验证**　比较首轮和末轮，导出能区别二者；字数不参与质量评定；断网可读已导出的结果。
- **源码**　[popup-compare.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-compare.js) · [export-engine.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/export-engine.js) · [background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js)

<a id="a23"></a>

### A23　历史目录和重置

按日期分组，从用户提问展开回答，搜索高亮、跳转；清群聊、重置上下文、彻底重置的作用域不同。

- **参照版复核**　从日期目录检索问答并跳转，分别检查清屏、重置会话和彻底重置清掉哪些数据。
- **自用版取舍**　首版·按场次存储。
- **验证**　建两场同题讨论，搜索可定位各自回答；取消删除无变化，只删除一场时另一场仍可完整恢复。
- **源码**　[popup-history.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-history.js) · [state-machine.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/state-machine.js) · [popup-tasks.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-tasks.js)

<a id="a24"></a>

### A24　模板库

内置自由/协作各轮、总结、场景、角色、PPT 模板；可改字段、逐项或全部重置，可创建、改写、删除个人模板。

- **参照版复核**　修改一项内置字段，创建自定义模板；逐项复位和全部复位后核对自建记录。
- **自用版取舍**　首版固定版本；个人模板后续。
- **验证**　改第 2 轮模板，历史场次保留原版本；重置内置项保留自建项；空字段有回退。
- **源码**　[templates-builtin.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/templates-builtin.js) · [template-store.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/template-store.js) · [popup-templates.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-templates.js)

<a id="a25"></a>

### A25　划线备忘

群聊或 AI 原页选词摘录，记录来源；可开关原页浮钮，列表引用、复制、批量复制、删除和清空。

- **参照版复核**　分别从气泡和原站摘录，复核来源与顺序，依次引用、复制、删除、清空。
- **自用版取舍**　后续。
- **验证**　从两个不同轮次摘录相同文字，核对来源。删除摘录不改写回答。
- **源码**　[memo-store.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/memo-store.js) · [popup-memos.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-memos.js) · [content-shared.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/content-shared.js)

<a id="a26"></a>

### A26　发送前敏感内容检查

本地规则识别文本；可遮盖发送、取消或确认原文并加入个人白名单。内置含原作者组织专用规则。

- **参照版复核**　用合成的手机号和私网地址触发提示，分别取消、遮盖和原文放行，再查相同值的白名单行为。
- **自用版取舍**　改造·按实际转发内容及接收方预览。
- **验证**　用虚构号码分别走首问和跨站转发，选择遮盖后核对每份实际输入。一次放行不应意外影响下一场。
- **源码**　[gatekeeper-engine.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/gatekeeper-engine.js) · [gatekeeper-rules.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/gatekeeper-rules.js) · [gatekeeper-store.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/gatekeeper-store.js) · [popup-gatekeeper-bridge.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-gatekeeper-bridge.js)

<a id="a27"></a>

### A27　故障处理

体检分别查标签、脚本及登录；无进展提醒、状态日志；气泡支持重提取、单席重发、跳过。

- **参照版复核**　模拟标签缺失、脚本未就绪和登出，对照三项体检、对应操作、日志及全场无进展提示。
- **自用版取舍**　首版。
- **验证**　关闭 B 后出现可处理的原因；重提取仅重读；跳过标记缺席；诊断去掉问题正文。
- **源码**　[popup-doctor.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-doctor.js) · [popup-log.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-log.js) · [popup-stuck-sentinel.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-stuck-sentinel.js) · [arena-errors.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/arena-errors.js)

<a id="a28"></a>

### A28　后台恢复

保存成员与轮次、上次发送、待裁判状态；恢复待处理轮询；旧轮长文本写盘时可截断。

- **参照版复核**　在有正在生成及待总结的任务时重启后台；检查轮询恢复、旧轮截断标记和报告关联。
- **自用版取舍**　改造·独立原文存储。
- **验证**　生成中结束后台进程并重新打开工作台，原文可读，任务状态明确，裁判只产出一份报告。
- **源码**　[state-machine.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/state-machine.js) · [chat-bus.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/chat-bus.js)

<a id="a29"></a>

### A29　站点兼容与构建差异

内置/可覆盖选择器；源码和不同发布变体的远程选择器、后台页面辅助与权限配置有差异。

- **参照版复核**　比较不同构建配方的清单与配置来源；用无效选择器配置样本检查本地回退。
- **自用版取舍**　改造·站点适配随自用版本更新。
- **验证**　离线加载时无需上游地址；单站样本变更应只使该站的对应能力降级。
- **源码**　[selectors-config.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/selectors-config.js) · [selectors-remote.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/selectors-remote.js) · [manifest.json](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/manifest.json) · [build.mjs](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/build.mjs)

<a id="a30"></a>

### A30　PPT 工坊和 PPT-SUPER

普通工坊写文案、生成配图和成片提示；SUPER 选版式、分槽生成/读取 AI 结果、编辑预览并填充可编辑演示稿。

- **参照版复核**　普通工坊分别选择文案、图片、PPTX；SUPER 走选版、填稿、编辑、导出，核对两条入口不同。
- **自用版取舍**　排除·独立制片工作流。
- **验证**　检查任务菜单、导出格式、构建包，均无演示稿流程和模板资产。
- **源码**　[ppt-prompts.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/ppt-prompts.js) · [popup-tasks.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-tasks.js) · [ppt-super.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/ppt-super/ppt-super.js) · [ppt-fill.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/ppt-super/ppt-fill.js)

<a id="a31"></a>

### A31　统计、成就、实力榜

统计本次/累计/各模型使用、估算用量、热力图与任务图表；解锁成就。成员栏另有带日期的第三方模型榜单。

- **参照版复核**　累计提问并切换本次/累计/模型页，核对成就条件、估算值和固定日期的外部榜单。
- **自用版取舍**　排除·仅留本场用时和状态。
- **验证**　多次跑完整场，不生成成就、累计排名或外部榜单链接；单场仍可查耗时与失败。
- **源码**　[popup-stats.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-stats.js) · [popup-achievements.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-achievements.js) · [popup-members.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-members.js)

<a id="a32"></a>

### A32　推广及装饰

上游 README/推广页含宣传演示和交流群材料；设置能打开上游仓库、检查上游发布；主题、头像皮肤与教程推广入口相互独立。

- **参照版复核**　分别检查安装材料、推广页、设置和更新入口，标注哪些出现于运行时、哪些只在仓库宣传材料。
- **自用版取舍**　排除推广、上游更新、皮肤包。
- **验证**　首次打开、设置、结束报告、导出均无引流、二维码或更新弹窗；法律声明中的来源仍可查。
- **源码**　[popup-update-check.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-update-check.js) · [popup-settings.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-settings.js) · [popup-logo-style.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/popup-logo-style.js) · [README.md](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/README.md)

<a id="a33"></a>

### A33　诊断和观看辅助

侧栏按成员显示进度、响应预览；单独唤起指定或全部 AI，旧提取路径与不同发布变体对后台标签有专门辅助。

- **参照版复核**　后台放置一个慢页面，观察侧栏预览、单席唤起和全体唤起；比较不同发布构建的可用能力。
- **自用版取舍**　改造·按席打开原页。
- **验证**　一席进入后台后停住，前台已有答案仍可读。切去处理慢席再返回时进度不倒退。
- **源码**　[sidepanel.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/sidepanel.js) · [background.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/background.js) · [bootstrap-main-world.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/bootstrap-main-world.js) · [cdp-extractor.js](https://github.com/TianLin0509/ai-arena-extension/blob/00953ebff7ab2b73525c949f56302f06b4db121b/src/cdp-extractor.js)
