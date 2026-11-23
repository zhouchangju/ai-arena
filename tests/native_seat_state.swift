//
//  native_seat_state.swift
//  AI Arena · 结构化席位状态与补录起点的定向检查
//
//  目标：G2/G3。席位徽标不再从中文状态句里猜关键字；状态由模型给出
//  `kind + detail`，导出和历史回看使用同一套由已保存场次推导的结构化结果。
//  本检查只验证纯函数，不启动应用、不创建窗口、不访问网络或真实账号。
//
//  由 tests/native_seat_state.py 编译运行：
//    xcrun --sdk macosx swiftc -swift-version 5 \
//      -framework AppKit -framework WebKit -framework SwiftUI \
//      -framework JavaScriptCore \
//      desktop/ArenaEngine.swift desktop/SitePane.swift \
//      desktop/ArenaModel.swift tests/native_seat_state.swift -o <bin>
//

import Foundation

@main
struct NativeSeatStateCheck {
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

        func task(
            _ provider: String,
            _ stage: String,
            round: Int,
            status: String,
            version: Int? = nil,
            stance: String? = nil,
            answer: String? = nil
        ) -> [String: Any] {
            var row: [String: Any] = [
                "id": "\(stage)-\(round)-\(provider)-\(status)",
                "provider": provider,
                "stage": stage,
                "round": round,
                "status": status,
                "prompt": "prompt",
            ]
            if let version { row["version"] = version }
            if let stance { row["stance"] = stance }
            if let answer { row["answer"] = answer }
            return row
        }

        // --- 1. Final same-version stance, stale version and skip -------------
        let finished: [String: Any] = [
            "id": "s1",
            "providers": ["chatgpt", "gemini", "deepseek"],
            "stage": "done",
            "round": 2,
            "paused": false,
            "tasks": [],
            "history": [
                task("chatgpt", "proposal", round: 1, status: "answered", version: 1, answer: "v1"),
                task("chatgpt", "vote", round: 1, status: "answered", version: 1, stance: "oppose"),
                task("chatgpt", "proposal", round: 2, status: "answered", version: 2, answer: "v2"),
                task("chatgpt", "vote", round: 2, status: "answered", version: 2, stance: "agree"),
                task("gemini", "vote", round: 2, status: "answered", version: 2, stance: "conditional"),
                task("deepseek", "vote", round: 2, status: "skipped", version: 2),
            ],
        ]
        let ballot = ["votes": [
            task("chatgpt", "vote", round: 2, status: "answered", version: 2, stance: "agree"),
            task("gemini", "vote", round: 2, status: "answered", version: 2, stance: "conditional"),
        ]]
        let chatgpt = ArenaSeatOutcome.derive(session: finished, provider: "chatgpt", ballot: ballot)
        check("final stance uses the latest proposal version", chatgpt.detail.contains("同意") && chatgpt.detail.contains("v2"))
        check("a stale v1 oppose is not the final stance", !chatgpt.detail.contains("反对"))
        check("final stance kind is done", chatgpt.kind == .done)

        let gemini = ArenaSeatOutcome.derive(session: finished, provider: "gemini", ballot: ballot)
        check("conditional vote is preserved", gemini.detail.contains("有条件同意") && gemini.detail.contains("v2"))
        let unverified = ArenaSeatOutcome.derive(session: finished, provider: "gemini", ballot: ["votes": []])
        check("a saved stance outside the verified ballot cannot be exported as final", unverified.kind == .needsAction)

        let deepseek = ArenaSeatOutcome.derive(session: finished, provider: "deepseek")
        check("skip is exported as a skip", deepseek.kind == .skipped && deepseek.detail.contains("跳过"))

        let outsider = ArenaSeatOutcome.derive(session: finished, provider: "other")
        check("a non-participant is not reported as a stance", outsider.kind == .idle && outsider.detail.contains("未参与"))

        // --- 2. A live pending seat is generating, not "needs action" --------
        let running: [String: Any] = [
            "id": "s2",
            "providers": ["chatgpt", "gemini"],
            "stage": "vote",
            "round": 1,
            "paused": false,
            "history": [
                task("chatgpt", "proposal", round: 1, status: "answered", version: 1, answer: "v1"),
            ],
            "tasks": [
                task("chatgpt", "vote", round: 1, status: "answered", version: 1, stance: "agree"),
                task("gemini", "vote", round: 1, status: "pending", version: 1),
            ],
        ]
        let pending = ArenaSeatOutcome.derive(session: running, provider: "gemini")
        check("pending same-version vote is generating", pending.kind == .generating)
        check("pending vote names its version", pending.detail.contains("v1"))

        let voted = ArenaSeatOutcome.derive(session: running, provider: "chatgpt")
        check("answered vote is answered", voted.kind == .answered && voted.detail.contains("同意"))

        var paused = running
        paused["paused"] = true
        let pausedState = ArenaSeatOutcome.derive(session: paused, provider: "gemini")
        check("paused wins over a pending task", pausedState.kind == .paused)
        check("paused detail names the stage", pausedState.detail.contains("已暂停") && pausedState.detail.contains("表态"))

        // --- 3. Restored pending seats are conservative -----------------------
        for (name, phase) in [
            ("submitted", ArenaDeliveryIntent.Phase.submitted),
            ("inflight", .inflight),
            ("uncertain", .uncertain),
            ("prepared", .prepared),
        ] {
            let state = ArenaModel.restoredManualState(phase: phase)
            check("restored \(name) needs a human", state.kind == .needsAction)
            check("restored \(name) asks to check the original page", state.detail.contains("核对原页"))
            check("restored \(name) promises no resend", state.detail.contains("不会重发") || state.detail.contains("不会自动发送"))
        }
        let restoredMissing = ArenaModel.restoredManualState(phase: nil)
        check("a restored task with no intent is still conservative", restoredMissing.kind == .needsAction)

        // --- 4. Slow generation never reads as a completed answer -------------
        for reason in ["completion-signal-missing", "answer-updating", "awaiting-answer", "generating", "other"] {
            let state = ArenaModel.pendingReadState(reason: reason, recoveryUsed: false)
            check("pending read \(reason) is generating", state.kind == .generating)
        }
        let reloaded = ArenaModel.pendingReadState(reason: "completion-signal-missing", recoveryUsed: true)
        check("the one read-only reload keeps generating", reloaded.kind == .generating)
        check("the reload is named in the detail", reloaded.detail.contains("已试只读重载"))

        // --- 5. Backfill starting text ---------------------------------------
        let saved = ArenaModel.backfillPrefill(currentAnswer: " 本轮原文 ", preview: ArenaPreview(text: "preview", isComplete: false))
        check("a current-round saved answer wins over a preview", saved.text == "本轮原文" && !saved.isPartial && !saved.isComplete)

        let partial = ArenaModel.backfillPrefill(currentAnswer: nil, preview: ArenaPreview(text: "半句", isComplete: false))
        check("a streamed fragment is marked partial", partial.text == "半句" && partial.isPartial && !partial.isComplete)

        let unaccepted = ArenaModel.backfillPrefill(currentAnswer: nil, preview: ArenaPreview(text: "完整但未采用", isComplete: true))
        check("an unaccepted complete answer is not called partial", unaccepted.text == "完整但未采用" && !unaccepted.isPartial && unaccepted.isComplete)

        let empty = ArenaModel.backfillPrefill(currentAnswer: "   ", preview: nil)
        check("an empty current round starts blank", empty.text.isEmpty && !empty.isPartial)

        // --- 6. Unified stage wording -----------------------------------------
        check("critique is 互评", ArenaStageNames.label("critique") == "互评")
        check("vote is 表态", ArenaStageNames.label("vote") == "表态")
        check("internal keys are unchanged", ArenaStageNames.label("independent") == "独立作答")

        let independent: [String: Any] = ["stage": "independent", "round": 1, "maxRounds": 3]
        check("independent stage has no round label", ArenaStageNames.discussionLabel(independent) == "独立作答")
        let critique: [String: Any] = ["stage": "critique", "round": 1, "maxRounds": 3]
        check("first critique uses the same round and cap as the report",
              ArenaStageNames.reviewRound(critique) == "互评第 1 轮 / 上限 3")
        let earlyFinish: [String: Any] = ["stage": "done", "round": 1, "history": [independent]]
        check("ending before review omits the round", ArenaStageNames.reviewRound(earlyFinish) == nil)
        let legacyFinish: [String: Any] = ["stage": "done", "round": 1, "history": [independent, critique, critique]]
        check("legacy finish counts distinct review rounds and defaults to two",
              ArenaStageNames.reviewRound(legacyFinish) == "互评第 1 轮 / 上限 2")

        if failures == 0 {
            print("native seat state: all checks passed")
            exit(0)
        }
        print("native seat state: \(failures) check(s) failed")
        exit(1)
    }
}
