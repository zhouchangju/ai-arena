# AI Arena for macOS

这是一个使用系统 WebKit 的原生 macOS 应用。一个窗口里有 ChatGPT、Gemini 和 DeepSeek 各自的真实网页。流式正文、图片、表格、引用和交互控件由各站渲染。工具栏负责组织轮次，讨论记录保存在本机。

本机已打好的 0.3.0（构建 3）位于 `desktop/build/releases/0.3.0/AI Arena.app`，压缩包在同一目录。这个目录属于本机构建产物；新检出的仓库可按下方命令构建。 [开场界面](../docs/evidence/native-0.3/composer.png) · [讨论界面](../docs/evidence/native-0.3/discussion.png)

## 第一次使用

1. 双击 `AI Arena.app`，在各席原页里按站点提示登录。应用使用自己的持久 WebKit 数据存储，需要在这个应用里建立登录会话。
2. 选择两席或三席，在多行框输入问题，点「开始讨论」或按 ⌘↩。开始后题面收起，让出空间给三席原页。每个参与席在自己的原页接收提示。独立作答后，工作台向各席转交其他席位的回答，起草候选并请各席对同一版本表态。新场次默认最多三轮互评，可在开场选择 1–5 轮。仍有反对或附加条件时，在剩余轮次内定向互评并修订；全体明确同意可提前结束，到上限则列出未决分歧。
3. 每席顶部显示状态。「查看当前提示」可核对材料。「暂停」用于暂停后续派发；已经发送给原站的请求仍可能生成。某席遇到登录、限流或页面变化，可以在该席菜单中接管、补录或跳过。核对原页后可选择「恢复本站自动」。发送结果不确定时，工作台回到同一会话核对本轮提问和随后出现的原始回答。Gemini 正文停止变化却缺少完成标记时，工作台会在确认没有生成控件和未发送草稿后尝试重新读取原页。
4. 讨论结束会打开报告。也可从「详情」查看发言、出处和报告，用「导出」保存 Markdown。「历史」打开已有记录。应用重启会恢复上次讨论；未完成席先进入人工核对，避免重复发送。记录默认存放在 `~/Library/Application Support/AI Arena/`。

首次登录需要站点本人验证。Google 可能限制嵌入式 WebView 登录。已在本机登录态核对三站的原页收发；具体轮次与验收覆盖见迭代记录。Chrome 扩展的历史、权限和账号属于它自己的浏览器环境。 [Google 授权说明](https://developers.google.com/identity/protocols/oauth2/native-app#disallowed_useragent)

## 一席停住时怎么看

| 席位提示 | 原页上发生了什么 | 如何处理 |
|---|---|---|
| 已填入，等待发送按钮 | 提示已写入编辑框，工作台正在等发送控件就绪。 | 先等自动重试。若提示“长时间未就绪”，在该席菜单接管，核对原页上的草稿或已发消息。 |
| 发送结果待确认 | 点击可能已到达站点，工作台正在查找本轮原始提问及随后出现的答复。 | 保持当前会话，让工作台读回，避免手动再发一遍。 |
| 已收到回答，但缺少明确立场 | 本轮表态未能解析出同意、有条件同意或反对。 | 查看原文，只在立场明确时接管并选择相应表态；无法判断时可跳过，该席计为缺席。 |

## 构建和验收

在仓库根目录执行：

```sh
./desktop/build.sh
open "desktop/build/AI Arena.app"
```

构建使用 Apple Swift 工具链、系统框架和 Node.js，生成本机架构的本地签名应用。构建脚本把已有讨论引擎、网页驱动和站点配置装入应用资源目录。运行时只需要 macOS；目前实测机器为 Apple Silicon。

用已安装仓库测试依赖的 Python 运行隔离验收。输出目录请使用新路径。

```sh
python3 tests/native_desktop_acceptance.py --app "desktop/build/AI Arena.app" --out /tmp/arena-native-full
python3 tests/native_desktop_acceptance.py --app "desktop/build/AI Arena.app" --out /tmp/arena-native-takeover --takeover
```

两条命令都会从指定的应用包复制出 AI Arena QA，使用独立的应用标识、WebKit 资料和临时讨论目录访问回环测试页。测试会核对同版投票、重启后的 Cookie 和 Markdown 导出，第二条还覆盖人工接管。如需专门核对中途重启，运行 `python3 tests/native_resume_acceptance.py --app "desktop/build/AI Arena.app" --out /tmp/arena-native-resume`。该用例从两席已答、第三席待发的记录继续，核对已有回答没有重复发送。真实账号验收使用定稿的同一份正式构建。

## 运行时和钥匙串

桌面调度器监控原页是否真正送达和答完，JavaScriptCore 中的本地状态机组织互评、候选、确认与报告。参与讨论的网页 AI 负责观点、质询、修订及表态。应用启动后可以关闭 Codex 和 OpenCode。

macOS 的“AI Arena WebCrypto Master Key”用于 WebKit 持久化网页加密密钥。“始终允许”受 macOS 对应用签名身份的检查约束。使用同一份已授权应用通常不需要重复输入。默认临时签名与构建内容绑定，更新后可能再次询问。如果已有有效的代码签名证书，可将 `ARENA_SIGN_IDENTITY` 设为该证书身份，后续版本使用同一身份和应用标识构建。指定身份无效时构建会失败。 [Apple 的签名身份说明](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/)
