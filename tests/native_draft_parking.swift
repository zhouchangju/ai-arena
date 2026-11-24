//
//  native_draft_parking.swift
//  AI Arena · 未发送草稿与历史查看的定向检查
//
//  目标：G1/G3/G4。打开或继续历史会覆盖题面并清空草稿；本检查只验证草稿
//  停放规则本身：题面与同一组有序附件一起保存和取回，空内容不占位，历史
//  内容永远不被当成新草稿，只有真正开始才消费草稿。另验证运行中与草稿并存
//  时的退出确认，以及返回草稿在只读直达、运行中先确认的规则。
//  不启动应用、不创建窗口、不访问网络或真实账号。
//
//  从仓库根目录运行 `python3 tests/native_draft_parking.py`。
//

import Foundation

@main
struct NativeDraftParkingCheck {
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

        // A valid 1×1 PNG so the image attachment passes the same validation as
        // a file the user really picked.
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        func attachments() throws -> [ArenaDraftAttachment] {
            [
                try ArenaDraftAttachment(name: "图 1.png", data: png),
                try ArenaDraftAttachment(name: "笔记.md", data: Data("# 结论\n先做采集".utf8)),
            ]
        }

        guard let pair = try? attachments(), pair.count == 2 else {
            print("FAIL could not build the two test attachments")
            exit(1)
        }
        let question = "如果只有两个周末，个人笔记工具应先做移动端采集，还是先补桌面检索？"

        // --- 1. 题面与两个附件按原顺序一起停放和取回 -----------------------
        var box = ArenaDraftParking()
        box.park(question: question, attachments: pair, leavingComposer: true)
        check("parked draft is available", box.hasDraft)
        let restored = box.take()
        check("restored question is exactly the unsent text", restored?.question == question)
        check("restored attachments keep their order", restored?.attachments.map(\.name) == ["图 1.png", "笔记.md"])
        check("restored attachments keep their ids", restored?.attachments.map(\.id) == pair.map(\.id))
        check("restored image bytes are unchanged", restored?.attachments.first?.data == png)
        check("a taken draft leaves the slot empty", !box.hasDraft)
        check("the same draft cannot be restored twice", box.take() == nil)

        // --- 2. 空内容不占位，也不弹「返回草稿」 -----------------------------
        var empty = ArenaDraftParking()
        empty.park(question: "", attachments: [], leavingComposer: true)
        check("an empty composer parks nothing", !empty.hasDraft && empty.take() == nil)
        empty.park(question: "  \n\t", attachments: [], leavingComposer: true)
        check("a whitespace-only body parks nothing", !empty.hasDraft)

        // 只贴了附件、还没写题面，同样是未发送草稿。
        var attachmentOnly = ArenaDraftParking()
        attachmentOnly.park(question: "", attachments: [pair[1]], leavingComposer: true)
        check("an attachment-only draft is still a draft", attachmentOnly.hasDraft)
        check("an attachment-only draft returns its file", attachmentOnly.take()?.attachments.map(\.name) == ["笔记.md"])

        // --- 3. 历史内容永远不被当成新草稿 ----------------------------------
        var history = ArenaDraftParking()
        history.park(
            question: "上一场的题面",
            attachments: [],
            leavingComposer: false
        )
        check("a restored session question never becomes a draft", !history.hasDraft)
        check("nothing is handed back from a session context", history.take() == nil)

        // --- 4. 切换多个历史场次不会覆盖已停放的草稿 ------------------------
        var switching = ArenaDraftParking()
        switching.park(question: question, attachments: pair, leavingComposer: true)
        switching.park(question: "另一场历史题面", attachments: [], leavingComposer: true)
        let kept = switching.take()
        check("history switching keeps the first parked draft", kept?.question == question)
        check("history switching keeps both attachments", kept?.attachments.map(\.name) == ["图 1.png", "笔记.md"])

        // --- 5. 多次往返：返回草稿、再进历史，仍能取回编辑后的内容 ----------
        var roundTrip = ArenaDraftParking()
        roundTrip.park(question: question, attachments: pair, leavingComposer: true)
        _ = roundTrip.take()
        let edited = question + "\n补充：先验证一个可复现的检索场景。"
        roundTrip.park(question: edited, attachments: pair, leavingComposer: true)
        let second = roundTrip.take()
        check("a second history visit parks the edited body", second?.question == edited)
        check("the second visit keeps the same ordered attachments", second?.attachments.map(\.id) == pair.map(\.id))

        // --- 6. 只有真正开始才消费草稿 --------------------------------------
        var failedStart = ArenaDraftParking()
        failedStart.park(question: question, attachments: pair, leavingComposer: true)
        failedStart.consumeOnStart(succeeded: false)
        check("a refused start keeps the draft", failedStart.hasDraft)
        check("a refused start returns the same attachments", failedStart.take()?.attachments.map(\.name) == ["图 1.png", "笔记.md"])

        var started = ArenaDraftParking()
        started.park(question: question, attachments: pair, leavingComposer: true)
        started.consumeOnStart(succeeded: true)
        check("a started discussion consumes the draft", !started.hasDraft && started.take() == nil)

        // --- 7. 退出确认：运行中与草稿并存时，一个弹框说明两件事 ------------
        let quitBoth = ArenaQuitPrompt(hasRunningDiscussion: true, hasUnsentDraft: true)
        check("quit needs confirmation while both exist", quitBoth.isNeeded)
        check("one quit dialog warns about resumable progress",
              quitBoth.message.contains("继续核对已保存的进度"))
        check("the same quit dialog warns the draft is destroyed",
              quitBoth.message.contains("永久丢弃尚未发送的问题和附件"))
        check("the confirm button names the discarded draft", quitBoth.confirmTitle == "退出并丢弃草稿")
        check("cancel keeps the default key", quitBoth.cancelIsDefault)
        check("title mentions running work and the draft",
              quitBoth.title.contains("讨论在进行") && quitBoth.title.contains("草稿"))

        let quitRunning = ArenaQuitPrompt(hasRunningDiscussion: true, hasUnsentDraft: false)
        check("a running discussion alone keeps the old warning",
              quitRunning.message.contains("停止后续派发") && !quitRunning.message.contains("草稿"))
        check("a running discussion's confirm is plain 退出", quitRunning.confirmTitle == "退出")

        let quitDraft = ArenaQuitPrompt(hasRunningDiscussion: false, hasUnsentDraft: true)
        check("an unsent draft alone still confirms", quitDraft.isNeeded && quitDraft.confirmTitle == "退出并丢弃草稿")

        let quitClean = ArenaQuitPrompt(hasRunningDiscussion: false, hasUnsentDraft: false)
        check("a clean quit asks nothing", !quitClean.isNeeded)
        check("a clean quit has no dialog text", quitClean.title.isEmpty && quitClean.message.isEmpty)

        // --- 8. 返回草稿：只读直达，运行中先确认，无草稿不出现 --------------
        check("read-only review returns without a confirmation",
              ArenaDraftReturnPolicy.decide(isReadOnly: true, isRunning: false, hasParkedDraft: true) == .direct)
        check("a running discussion confirms before returning to the draft",
              ArenaDraftReturnPolicy.decide(isReadOnly: false, isRunning: true, hasParkedDraft: true) == .confirmStop)
        check("the idle composer returns directly",
              ArenaDraftReturnPolicy.decide(isReadOnly: false, isRunning: false, hasParkedDraft: true) == .direct)
        check("no parked draft means no return action",
              ArenaDraftReturnPolicy.decide(isReadOnly: true, isRunning: false, hasParkedDraft: false) == .unavailable)
        check("a read-only session is never treated as running",
              ArenaDraftReturnPolicy.decide(isReadOnly: true, isRunning: true, hasParkedDraft: true) == .direct)

        if failures == 0 {
            print("all draft parking checks passed")
        } else {
            print("\(failures) draft parking check(s) failed")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
