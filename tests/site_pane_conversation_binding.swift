//
//  site_pane_conversation_binding.swift
//  AI Arena · ChatGPT 临时前端路由与稳定会话绑定的定向检查
//
//  目标：G1/G3。ChatGPT 在首问成功后可能先落在
//  `https://chatgpt.com/c/local-chatgpt:<uuid>`（路径里的冒号也可能被百分号
//  编码），随后才换成稳定的 `/c/<id>`。本检查只验证 desktop/SitePane.swift
//  的纯白名单函数：临时路由不能被固定、不能作为恢复目的地，稳定地址和
//  其它既有站点不受影响。
//
//  由 tests/site_pane_conversation_binding.py 编译并运行：
//    xcrun --sdk macosx swiftc -swift-version 5 \
//      -framework AppKit -framework WebKit -framework SwiftUI \
//      desktop/SitePane.swift tests/site_pane_conversation_binding.swift -o <bin>
//

import Foundation

@main
struct SitePaneConversationBindingCheck {
    static func main() {
        var failures = 0

        func check(_ name: String, _ value: Bool) {
            if value {
                print("ok   \(name)")
            } else {
                failures += 1
                print("FAIL \(name)")
            }
        }

        func accepted(_ raw: String, provider: String = "chatgpt", homePath: String = "/") -> Bool {
            guard let url = URL(string: raw) else { return false }
            return SitePane.isConversationURL(
                url,
                provider: provider,
                homePath: homePath,
                isTest: false
            )
        }

        check(
            "stable ChatGPT /c/<id> is accepted",
            accepted("https://chatgpt.com/c/00000000-0000-4000-8000-000000000137")
        )
        check(
            "temporary /c/local-chatgpt:<uuid> is rejected",
            !accepted("https://chatgpt.com/c/local-chatgpt:6f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8")
        )
        check(
            "percent-encoded temporary route is rejected",
            !accepted("https://chatgpt.com/c/local-chatgpt%3A6f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8")
        )
        check(
            "double-encoded temporary route is rejected",
            !accepted("https://chatgpt.com/c/local-chatgpt%253A6f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8")
        )
        check(
            "hyphenated temporary marker is rejected",
            !accepted("https://chatgpt.com/c/local-chatgpt-6f1a2b3c")
        )
        check(
            "ChatGPT home is not a conversation",
            !accepted("https://chatgpt.com/")
        )
        check(
            "Gemini /app/<id> rule is unchanged",
            accepted("https://gemini.google.com/app/abc123", provider: "gemini", homePath: "/app")
        )
        check(
            "DeepSeek /a/chat/s/<id> rule is unchanged",
            accepted("https://chat.deepseek.com/a/chat/s/abc123", provider: "deepseek")
        )

        let fixture = URL(string: "http://127.0.0.1:8877/web-driver-fixture.html")!
        check(
            "loopback test page keeps its exact home path",
            SitePane.isConversationURL(
                fixture,
                provider: "chatgpt",
                homePath: "/web-driver-fixture.html",
                isTest: true
            )
        )

        if failures > 0 {
            exit(1)
        }
    }
}
