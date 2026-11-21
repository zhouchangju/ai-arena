# Provider marks — 来源与许可

本目录的 9 个 SVG 只用于工作台「选择两席」里 `.provider-avatar` 的小标记，
由 `extension/provider-marks.css` 以本地 `background-image` 引用；不联网、不含脚本、
不含外链（唯一 URI 是 `xmlns="http://www.w3.org/2000/svg"` 命名空间，不会发起请求）。
站点名仍由相邻的 `.provider-name` 文本显示，头像本身 `aria-hidden="true"`。

| 文件 | 对应席位 | 显示名 |
| --- | --- | --- |
| `chatgpt.svg` | `chatgpt` | ChatGPT（OpenAI 标记） |
| `claude.svg` | `claude` | Claude |
| `gemini.svg` | `gemini` | Gemini |
| `deepseek.svg` | `deepseek` | DeepSeek |
| `doubao.svg` | `doubao` | 豆包 |
| `kimi.svg` | `kimi` | Kimi |
| `qwen.svg` | `qwen` | 通义千问 |
| `yuanbao.svg` | `yuanbao` | 腾讯元宝 |
| `grok.svg` | `grok` | Grok |

本机 A / B 没有厂商标记，不在此目录内；它们由 CSS 用 A / B 字母与两套底色区分。

## 溯源

1. 这 9 个文件复制自同机仓库 `../ai-arena-extension/src/icons/brands/`
   （提交 `6e07394`，`feat: add AI brand logos to add buttons, participant cards, and model stats`，
   2026-05-01）。该仓库为 MIT，版权人 `TianLin0509`，见其 `LICENSE`。
   文件内容按字节复制，未改路径、未改配色；只把文件名映射到本项目的 provider id
   （`openai.svg` → `chatgpt.svg`），并在本说明中登记。
2. 该套图形的几何来自 LobeHub Lobe Icons 静态 SVG 集
   （`lobehub/lobe-icons`，`packages/static-svg/icons/`，MIT，Copyright (c) 2023 LobeHub）。
   逐条比对 `path d`：7 个标记与上游当前版本一致；`qwen.svg`、`yuanbao.svg`
   与同一套件的较早版本一致（上游后来重绘过这两个标记）。
   上游把 `fill` 从 `currentColor` 改成固定品牌色，其余结构未变。
3. 两份 MIT 许可都要求保留版权与许可声明，全文附在本文件末尾。

## 商标

ChatGPT / OpenAI、Claude / Anthropic、Gemini / Google、DeepSeek、豆包 / 字节跳动、
Kimi / 月之暗面、通义千问 / 阿里巴巴、腾讯元宝 / 腾讯、Grok / xAI 及相关图形
均为其各自权利人的商标。此处仅用于标明用户所选的席位，不表示任何隶属、赞助或认可。

---

## MIT License — ai-arena-extension

Copyright (c) 2026 TianLin0509

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## MIT License — LobeHub Lobe Icons

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
