# AI Arena for macOS

这是一个使用系统 WebKit 的原生 macOS 应用。一个窗口里有 ChatGPT、Gemini 和 DeepSeek 各自的真实网页。流式正文、图片、表格、引用和交互控件由各站渲染。工具栏负责组织轮次，讨论记录保存在本机。

## 第一次使用

1. 双击 `AI Arena.app`，在各席原页里按站点提示登录。应用使用自己的持久 WebKit 数据存储，需要在这个应用里建立登录会话。
2. 选择两席或三席，输入问题，点「开始」。每个参与席在自己的原页接收提示。独立作答后，工作台向各席转交其他席位的回答，起草候选并请各席对同一版本表态。新场次默认最多三轮互评，可在开场选择 1–5 轮。仍有反对或附加条件时，在剩余轮次内定向互评并修订；全体明确同意可提前结束，到上限则列出未决分歧。
3. 每席顶部显示状态。「查看当前提示」可核对材料。「暂停」用于暂停后续派发；已经发送给原站的请求仍可能生成。某席遇到登录、限流或页面变化，可以在该席菜单中接管、补录或跳过。核对原页后可选择「恢复本站自动」。发送结果不确定时，工作台回到同一会话核对本轮提问和随后出现的原始回答。Gemini 正文停止变化却缺少完成标记时，工作台会在确认没有生成控件和未发送草稿后尝试重新读取原页。
4. 讨论结束会打开报告。也可从「详情」查看发言、出处和报告，用「导出」保存 Markdown。「历史」打开已有记录。应用重启会恢复上次讨论；未完成席先进入人工核对，避免重复发送。记录默认存放在 `~/Library/Application Support/AI Arena/`。

首次登录需要站点本人验证。Google 可能限制嵌入式 WebView 登录。已在本机登录态核对三站的原页收发；具体轮次与验收覆盖见迭代记录。Chrome 扩展的历史、权限和账号属于它自己的浏览器环境。 [Google 授权说明](https://developers.google.com/identity/protocols/oauth2/native-app#disallowed_useragent)

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

两条命令都运行实际应用，打开三个本地 WebKit 页面，逐席比对发送和回填，复核同一候选版本、重启恢复、测试站点 Cookie 和 Markdown。第二条还覆盖在一席接管后由其余两席继续作答，再恢复自动讨论。
