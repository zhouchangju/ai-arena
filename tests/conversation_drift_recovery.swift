//
//  conversation_drift_recovery.swift
//  AI Arena · 同源对话漂移的有界返回检查
//
//  目标：G1/G3，R06。原页被换到同源、稳定的另一个对话时，只读核对当前页；
//  没有未发送草稿、附件或生成控件才回到已保存、已核验的原对话。看不到页面
//  内容、页面受保护或调用方已暂停/接管时必须留在原页，绝不发送。
//
//  这是真实 WKWebView + 本地回环页面的检查，不启动应用、不访问真实站点、
//  不读取个人账号或数据。
//
//  由 tests/conversation_drift_recovery.py 编译与运行。
//

import AppKit
import Foundation

@main
struct ConversationDriftRecoveryCheck {
    static func main() async {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)

        guard CommandLine.arguments.count == 2,
              let base = URL(string: CommandLine.arguments[1]) else {
            print("usage: conversation-drift-recovery <loopback-base>")
            exit(2)
        }

        let selectors: [String: [String]] = [
            "input": ["#editor"],
            "send": ["#send"],
            "user": [".turn.user .msg"],
            "answer": [".turn.answer .msg"],
            "stop": ["#stop"],
        ]
        let options: [String: Any] = ["sampleMs": 20, "stableSamples": 2]

        var failures = 0
        func check(_ name: String, _ value: Bool) {
            if value {
                print("ok   \(name)")
            } else {
                failures += 1
                print("FAIL \(name)")
            }
        }

        func page(_ name: String) -> URL {
            base.appendingPathComponent(name)
        }

        // Exact-origin login detection: a real Gemini conversation must never
        // be mistaken for a login page, while a genuine auth path/host is.
        check(
            "a real Gemini conversation is not a login barrier",
            SitePane.conversationDriftLocationSafety(
                current: URL(string: "https://gemini.google.com/app/abc123"),
                siteOrigin: "https://gemini.google.com"
            ) == nil
        )
        check(
            "an auth host is a login barrier",
            SitePane.conversationDriftLocationSafety(
                current: URL(string: "https://accounts.google.com/o/oauth2/auth"),
                siteOrigin: "https://gemini.google.com"
            ) == .loginBarrier
        )
        check(
            "a login path on the site is a login barrier",
            SitePane.conversationDriftLocationSafety(
                current: URL(string: "https://gemini.google.com/login"),
                siteOrigin: "https://gemini.google.com"
            ) == .loginBarrier
        )
        check(
            "a missing page fails closed",
            SitePane.conversationDriftLocationSafety(current: nil, siteOrigin: "https://gemini.google.com")
                == .unavailable("原页没有地址")
        )
        check(
            "missing stop evidence fails closed",
            SitePane.conversationDriftSafety(
                draftEmpty: true, hasAttachments: false,
                stopConfigured: false, stopActive: false
            ) == .unavailable("无法确认是否仍在生成")
        )

        @MainActor
        func newPane(_ home: URL) -> SitePane {
            SitePane.testPane(
                provider: "gemini",
                loopbackURL: home,
                selectors: selectors,
                options: options
            )
        }

        @MainActor
        func load(_ pane: SitePane, _ url: URL) async -> Bool {
            pane.open(url)
            return await waitReady(pane)
        }

        @MainActor
        func waitReady(_ pane: SitePane, timeout: TimeInterval = 10) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if pane.documentReady, !pane.isLoading { return true }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            return pane.documentReady
        }

        // 1. A blank same-origin conversation can be left and the saved one is
        //    reopened. No send control is ever clicked.
        do {
            let home = page("ok")
            let pane = newPane(home)
            check("the saved conversation loads", await load(pane, home))
            check("the saved conversation binds", pane.restoreConversationBinding(home))
            check("a same-origin second conversation loads", await load(pane, page("ok-b")))
            check("the drift is visible before recovery", pane.conversationMismatch() != nil)
            let outcome = await pane.returnToBoundConversationIfSafe(
                taskID: "drift-check:reading:gemini",
                canContinue: { true }
            )
            check("a safe drift returns to the saved conversation", outcome == .returned)
            check("the saved conversation is current after recovery", pane.conversationMismatch() == nil)
            check("the returned address is the saved conversation",
                  pane.currentURL?.path == home.path)
        }

        // 2. A human draft on the page being left is preserved.
        do {
            let home = page("draft")
            let pane = newPane(home)
            check("a draft scenario binds", await load(pane, home) && pane.restoreConversationBinding(home))
            check("a draft drift page loads", await load(pane, page("draft-b")))
            let outcome = await pane.returnToBoundConversationIfSafe(
                taskID: "drift-check:prepared:gemini",
                canContinue: { true }
            )
            check("a draft blocks the automatic return", outcome == .blocked(.draft))
            check("a draft page is left untouched", pane.currentURL?.path == page("draft-b").path)
        }

        // 3. A live generation on the page being left is never interrupted.
        do {
            let home = page("busy")
            let pane = newPane(home)
            check("a busy scenario binds", await load(pane, home) && pane.restoreConversationBinding(home))
            check("a generating drift page loads", await load(pane, page("busy-b")))
            let outcome = await pane.returnToBoundConversationIfSafe(
                taskID: "drift-check:reading:gemini",
                canContinue: { true }
            )
            check("a live generation blocks the automatic return", outcome == .blocked(.generating))
            check("a generating page is not navigated away", pane.currentURL?.path == page("busy-b").path)
        }

        // 4. An unreadable page fails closed instead of guessing.
        do {
            let home = page("unknown")
            let pane = newPane(home)
            check("an unknown scenario binds", await load(pane, home) && pane.restoreConversationBinding(home))
            check("an unreadable drift page loads", await load(pane, page("unknown-b")))
            let outcome = await pane.returnToBoundConversationIfSafe(
                taskID: "drift-check:verifying:gemini",
                canContinue: { true }
            )
            var failedClosed = false
            if case .blocked(.unavailable) = outcome { failedClosed = true }
            check("an unreadable page blocks the automatic return", failedClosed)
            check("an unreadable page is left untouched", pane.currentURL?.path == page("unknown-b").path)
        }

        // 5. Pause/takeover/replaced-task checks win over navigation.
        do {
            let home = page("pause")
            let pane = newPane(home)
            check("a pause scenario binds", await load(pane, home) && pane.restoreConversationBinding(home))
            check("a pause drift page loads", await load(pane, page("pause-b")))
            let outcome = await pane.returnToBoundConversationIfSafe(
                taskID: "drift-check:reading:gemini",
                canContinue: { false }
            )
            check("a stale task or pause cancels the return", outcome == .cancelled)
            check("a cancelled return leaves the page alone", pane.currentURL?.path == page("pause-b").path)
        }

        if failures == 0 {
            print("conversation drift recovery: all checks passed")
            exit(0)
        }
        print("conversation drift recovery: \(failures) check(s) failed")
        exit(1)
    }
}
