//
//  feedback_completion.swift
//  AI Arena · 窗口反馈与完成通知的定向检查
//
//  只验证纯逻辑和独立剪贴板，不启动应用、不创建窗口、不访问系统通知中心，
//  也不改动用户当前的通用剪贴板。
//
//  在仓库根目录编译并运行：
//    xcrun --sdk macosx swiftc -swift-version 5 \
//      -framework AppKit -framework SwiftUI -framework JavaScriptCore \
//      -framework UserNotifications \
//      desktop/ArenaMotion.swift desktop/ArenaFeedback.swift \
//      desktop/ArenaEngine.swift desktop/ArenaEvaluation.swift \
//      tests/feedback_completion.swift -o <bin>
//

import AppKit

@main
struct FeedbackCompletionCheck {
    @MainActor
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

        // --- 1. One completion per durable session transition -----------------
        var tracker = ArenaCompletionTracker()
        _ = tracker.recordPersisted(sessionID: "s1", stage: "independent")
        check("a running stage publishes nothing", tracker.recordPersisted(
            sessionID: "s1", stage: "critique") == nil)
        let completed = tracker.recordPersisted(sessionID: "s1", stage: "done")
        check("the first running→done transition publishes once", completed?.sessionID == "s1")
        check("an automatic completion is not marked explicit", completed?.explicitFinish == false)
        check("persisting done again publishes nothing", tracker.recordPersisted(
            sessionID: "s1", stage: "done") == nil)

        // --- 2. Explicit finish keeps its marker ------------------------------
        var explicitTracker = ArenaCompletionTracker()
        _ = explicitTracker.recordPersisted(sessionID: "s2", stage: "vote")
        let explicit = explicitTracker.recordPersisted(
            sessionID: "s2", stage: "done", explicitFinish: true)
        check("explicit finish is carried on the event", explicit?.explicitFinish == true)

        // --- 3. Restored completed sessions never notify again ----------------
        var restoredDone = ArenaCompletionTracker()
        restoredDone.adopt(sessionID: "old", stage: "done")
        check("an adopted completed session stays quiet", restoredDone.recordPersisted(
            sessionID: "old", stage: "done") == nil)

        var restoredRunning = ArenaCompletionTracker()
        restoredRunning.adopt(sessionID: "resumed", stage: "vote")
        check("a resumed session can still complete once", restoredRunning.recordPersisted(
            sessionID: "resumed", stage: "done")?.sessionID == "resumed")

        // --- 4. A new session cannot inherit the previous done state ----------
        var changed = ArenaCompletionTracker()
        _ = changed.recordPersisted(sessionID: "first", stage: "done")
        check("a different session id never maps onto done", changed.recordPersisted(
            sessionID: "second", stage: "done") == nil)

        // --- 5. Delivery never steals the foreground ---------------------------
        check("a foreground automatic completion stays in the workbench",
              ArenaCompletionPolicy.delivery(isForeground: true, explicitFinish: false) == .revealInPlace)
        check("a foreground explicit finish also stays in the workbench",
              ArenaCompletionPolicy.delivery(isForeground: true, explicitFinish: true) == .revealInPlace)
        check("background automatic completion notifies", ArenaCompletionPolicy.delivery(
            isForeground: false, explicitFinish: false) == .notification)
        check("background explicit finish stays silent", ArenaCompletionPolicy.delivery(
            isForeground: false, explicitFinish: true) == .silent)
        check("no delivery turns a completion into a notification in the foreground",
              ArenaCompletionPolicy.delivery(isForeground: true, explicitFinish: false) != .notification)
        check("the in-place notice has its own channel",
              Notification.Name.arenaCompletionAnnouncedInPlace
                  != Notification.Name("arena.completion"))

        // --- 6. Copy reports the pasteboard's own result ----------------------
        let board = NSPasteboard(name: NSPasteboard.Name("ArenaFeedbackCheck.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        check("copy writes through a named pasteboard", ArenaClipboard.copy("检查文本", to: board))
        check("copy leaves the expected string", board.string(forType: .string) == "检查文本")

        // --- 7. Visible feedback uses the required Chinese text ---------------
        let presenter = ArenaFeedbackPresenter()
        presenter.show(ArenaFeedbackPresenter.copiedText)
        check("copy success text is exact",
              presenter.message?.text == "已复制到剪贴板"
              && presenter.message?.tone == .success)
        presenter.show("导出失败：磁盘已满", tone: .failure)
        check("failure replaces and keeps the tone",
              presenter.message?.text == "导出失败：磁盘已满"
              && presenter.message?.tone == .failure)

        if failures == 0 {
            print("PASS: feedback and completion checks")
            exit(0)
        }
        print("FAILURES: \(failures)")
        exit(1)
    }
}
