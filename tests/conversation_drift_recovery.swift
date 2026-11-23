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

        /// A same-document route change (history.pushState) never reaches the
        /// navigation delegate. This is the path the earlier bounded fallback
        /// still has to cover for already-drifted pages.
        @MainActor
        func driftSameDocument(_ pane: SitePane, to path: String,
                               timeout: TimeInterval = 5) async -> Bool {
            _ = try? await pane.webView.evaluateJavaScript("history.pushState({}, '', '\(path)')")
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if pane.currentURL?.path == path { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return pane.currentURL?.path == path
        }

        // 1. A blank same-origin conversation changed by same-document routing
        //    can be left and the saved one is reopened. No send control is ever
        //    clicked.
        do {
            let home = page("ok")
            let pane = newPane(home)
            check("the saved conversation loads", await load(pane, home))
            check("the saved conversation binds", pane.restoreConversationBinding(home))
            check("a same-document second conversation appears",
                  await driftSameDocument(pane, to: "/ok-b"))
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

        // 2. A human draft typed in the same document is preserved.
        do {
            let home = page("draft")
            let pane = newPane(home)
            check("a draft scenario binds", await load(pane, home) && pane.restoreConversationBinding(home))
            _ = try? await pane.webView.evaluateJavaScript(
                "document.querySelector('#editor').value = '留给用户的手写草稿'"
            )
            check("a draft drift appears", await driftSameDocument(pane, to: "/draft-b"))
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

        // 6. Pure lock/policy rules: another recognized conversation and the
        //    generic home are blocked; A, auth, subframes and authorized opens
        //    are not.
        let geminiOrigin = "https://gemini.google.com"
        let geminiA = URL(string: "https://gemini.google.com/app/abc123")!
        func blocked(_ target: String, bound: URL? = geminiA, main: Bool = true,
                     authorized: Bool = false, provider: String = "gemini",
                     homePath: String = "/app", origin: String = geminiOrigin) -> Bool {
            SitePane.shouldCancelAutomaticNavigation(
                target: URL(string: target)!, bound: bound, current: bound,
                isMainFrame: main, isAuthorized: authorized, provider: provider,
                siteOrigin: origin, homePath: homePath, isTest: false
            )
        }
        check("another Gemini conversation is blocked", blocked("https://gemini.google.com/app/zzz999"))
        check("Gemini's new-chat home is blocked", blocked("https://gemini.google.com/app"))
        check("a ChatGPT conversation is blocked",
              blocked("https://chatgpt.com/c/00000000-0000-4000-8000-000000000002",
                      bound: URL(string: "https://chatgpt.com/c/00000000-0000-4000-8000-000000000001")!,
                      provider: "chatgpt", homePath: "/", origin: "https://chatgpt.com"))
        check("ChatGPT home is blocked",
              blocked("https://chatgpt.com/",
                      bound: URL(string: "https://chatgpt.com/c/00000000-0000-4000-8000-000000000001")!,
                      provider: "chatgpt", homePath: "/", origin: "https://chatgpt.com"))
        check("a DeepSeek conversation is blocked",
              blocked("https://chat.deepseek.com/a/chat/s/zzz999",
                      bound: URL(string: "https://chat.deepseek.com/a/chat/s/abc123")!,
                      provider: "deepseek", homePath: "/", origin: "https://chat.deepseek.com"))
        check("the same conversation with a query is allowed",
              !blocked("https://gemini.google.com/app/abc123?model=fast"))
        check("the first A assignment is allowed", !blocked("https://gemini.google.com/app", bound: nil))
        check("an auth host is allowed", !blocked("https://accounts.google.com/o/oauth2/auth"))
        check("a same-site login path is allowed", !blocked("https://gemini.google.com/login"))
        check("a subframe is allowed", !blocked("https://gemini.google.com/app/zzz999", main: false))
        check("an authorized open is allowed",
              !blocked("https://gemini.google.com/app", authorized: true))
        check("a fixture sibling conversation is blocked",
              SitePane.shouldCancelAutomaticNavigation(
                target: URL(string: "http://127.0.0.1:9/gemini-b")!,
                bound: URL(string: "http://127.0.0.1:9/gemini")!,
                current: URL(string: "http://127.0.0.1:9/gemini")!,
                isMainFrame: true, isAuthorized: false, provider: "gemini",
                siteOrigin: "http://127.0.0.1:9", homePath: "/gemini", isTest: true
              ))
        check("the same fixture conversation is allowed",
              !SitePane.shouldCancelAutomaticNavigation(
                target: URL(string: "http://127.0.0.1:9/gemini")!,
                bound: URL(string: "http://127.0.0.1:9/gemini")!,
                current: URL(string: "http://127.0.0.1:9/gemini")!,
                isMainFrame: true, isAuthorized: false, provider: "gemini",
                siteOrigin: "http://127.0.0.1:9", homePath: "/gemini", isTest: true
              ))

        // 7. Receipt provenance: a post-click receipt from another conversation,
        //    or a success receipt with no verifiable href, is never adopted.
        func receipt(_ status: String, href: String?, verified: Bool = false,
                     ok: Bool = true) -> [String: Any] {
            var detail: [String: Any] = ["userTurnVerified": verified]
            if let href { detail["href"] = href }
            return ["ok": ok, "status": status, "detail": detail]
        }
        check("a stable receipt matches",
              SitePane.receiptConversationMismatch(
                receipt("submitted", href: geminiA.absoluteString, verified: true),
                bound: geminiA, origin: geminiOrigin) == nil)
        check("a submitted receipt from B is rejected",
              SitePane.receiptConversationMismatch(
                receipt("submitted", href: "https://gemini.google.com/app/zzz999", verified: true),
                bound: geminiA, origin: geminiOrigin) != nil)
        check("a done receipt from B is rejected",
              SitePane.receiptConversationMismatch(
                receipt("done", href: "https://gemini.google.com/app/zzz999"),
                bound: geminiA, origin: geminiOrigin) != nil)
        check("a submitted receipt without provenance is rejected",
              SitePane.receiptConversationMismatch(
                receipt("submitted", href: nil, verified: true),
                bound: geminiA, origin: geminiOrigin) != nil)
        check("an unparseable verified href is rejected",
              SitePane.receiptConversationMismatch(
                receipt("submitted", href: "javascript:alert(1)", verified: true),
                bound: geminiA, origin: geminiOrigin) != nil)
        check("a cross-origin done href is rejected",
              SitePane.receiptConversationMismatch(
                receipt("done", href: "https://example.test/app/abc123"),
                bound: geminiA, origin: geminiOrigin) != nil)
        check("a failed receipt is not a provenance mismatch",
              SitePane.receiptConversationMismatch(
                receipt("unknown", href: "https://gemini.google.com/app/zzz999", ok: false),
                bound: geminiA, origin: geminiOrigin) == nil)
        check("a pending receipt without href is tolerated",
              SitePane.receiptConversationMismatch(
                receipt("pending", href: nil), bound: geminiA, origin: geminiOrigin) == nil)
        check("an unconfirmed submit never looks like a pre-click change",
              !SitePaneError.submitUnconfirmed(expected: "a", actual: "b").isConversationChanged)
        check("an unconfirmed submit records that a click may have happened",
              SitePaneError.submitUnconfirmed(expected: "a", actual: "b").possiblySubmitted
              && SitePaneError.submitUnconfirmed(expected: "a", actual: "b").clickAttempted)

        // 8. The preventive lock in a real WKWebView: a verified A bound through
        //    the same receipt path polls use stays put on an unsolicited full
        //    navigation, keeps its ready state, and records no error.
        do {
            let home = page("ok")
            let pane = newPane(home)
            check("a lock scenario loads", await load(pane, home))
            let verified: [String: Any] = [
                "ok": true, "status": "submitted",
                "detail": ["userTurnVerified": true, "href": home.absoluteString],
            ]
            check("a receipt binds verified A", pane.bindVerifiedConversation(from: verified))
            pane.isAutomaticWorkActive = { true }
            check("a repeated receipt keeps the same binding",
                  pane.bindVerifiedConversation(from: verified))
            _ = try? await pane.webView.evaluateJavaScript("location.assign('/ok-b')")
            try? await Task.sleep(nanoseconds: 900_000_000)
            check("an unsolicited navigation to B is cancelled",
                  pane.currentURL?.path == home.path)
            check("A stays ready after the cancelled navigation",
                  pane.documentReady && !pane.isLoading)
            check("the cancelled navigation leaves no error",
                  pane.lastNavigationErrorCode == nil && pane.lastErrorCode == nil)
            check("A still has no conversation mismatch", pane.conversationMismatch() == nil)
        }

        // 9. A same-document A→B change is returned immediately (twice), and
        //    repeated receipts for the same A do not refill the throttle.
        do {
            let home = page("ok")
            let pane = newPane(home)
            check("a proactive scenario loads", await load(pane, home))
            let verified: [String: Any] = [
                "ok": true, "status": "submitted",
                "detail": ["userTurnVerified": true, "href": home.absoluteString],
            ]
            check("a proactive scenario binds", pane.bindVerifiedConversation(from: verified))
            pane.isAutomaticWorkActive = { true }

            @MainActor
            func driftAndWait() async -> Bool {
                _ = try? await pane.webView.evaluateJavaScript("history.pushState({}, '', '/ok-b')")
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    if !pane.isLoading, pane.documentReady,
                       pane.currentURL?.path == home.path,
                       pane.conversationMismatch() == nil { return true }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                return false
            }
            check("a same-document drift returns to A", await driftAndWait())
            check("a second independent drift is returned too", await driftAndWait())
            check("a repeated receipt after recovery is still the same binding",
                  pane.bindVerifiedConversation(from: verified))
            _ = try? await pane.webView.evaluateJavaScript("history.pushState({}, '', '/ok-b')")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            check("a third rapid drift is left to the task fallback",
                  pane.currentURL?.path == page("ok-b").path)
        }

        // 10. Without automatic work (manual takeover) the page is free again.
        do {
            let home = page("ok")
            let pane = newPane(home)
            check("a manual scenario loads", await load(pane, home))
            _ = pane.restoreConversationBinding(home)
            pane.isAutomaticWorkActive = { false }
            _ = try? await pane.webView.evaluateJavaScript("location.assign('/pause-b')")
            let deadline = Date().addingTimeInterval(8)
            var moved = false
            while Date() < deadline {
                if pane.currentURL?.path == page("pause-b").path { moved = true; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            check("a manually taken-over seat may change page", moved)
        }

        // 11. An active remote reply alone does not trap a same-document drift,
        //     but a locally typed draft still does.
        do {
            let home = page("busy")
            let pane = newPane(home)
            check("a generating scenario loads", await load(pane, home))
            _ = pane.restoreConversationBinding(home)
            pane.isAutomaticWorkActive = { true }
            _ = try? await pane.webView.evaluateJavaScript(
                "document.body.insertAdjacentHTML('beforeend', '<button id=\"stop\" style=\"display:block\">stop</button>')"
            )
            _ = try? await pane.webView.evaluateJavaScript("history.pushState({}, '', '/busy-b')")
            let deadline = Date().addingTimeInterval(8)
            var returned = false
            while Date() < deadline {
                if !pane.isLoading, pane.currentURL?.path == home.path { returned = true; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            check("remote generation does not block the proactive return", returned)
        }
        do {
            let home = page("draft")
            let pane = newPane(home)
            check("a draft scenario loads for the lock", await load(pane, home))
            _ = pane.restoreConversationBinding(home)
            pane.isAutomaticWorkActive = { true }
            _ = try? await pane.webView.evaluateJavaScript(
                "document.querySelector('#editor').value = '本地手写草稿'; history.pushState({}, '', '/draft-b')"
            )
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            check("a locally typed draft still prevents the proactive return",
                  pane.currentURL?.path == page("draft-b").path)
            let kept = (try? await pane.webView.evaluateJavaScript(
                "document.querySelector('#editor').value"
            )) as? String
            check("the local draft is left untouched", kept == "本地手写草稿")
        }

        if failures == 0 {
            print("conversation drift recovery: all checks passed")
            exit(0)
        }
        print("conversation drift recovery: \(failures) check(s) failed")
        exit(1)
    }
}
