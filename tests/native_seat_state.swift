//
//  native_seat_state.swift
//  AI Arena · 结构化席位状态与补录起点的定向检查
//
//  目标：G2/G3。席位徽标不再从中文状态句里猜关键字；状态由模型给出
//  `kind + detail`，导出和历史回看使用同一套由已保存场次推导的结构化结果。
//  本检查只验证纯函数，不启动应用、不创建窗口、不访问网络或真实账号。
//
//  从仓库根目录运行 `python3 tests/native_seat_state.py`。
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

        // Anonymous image previews need the same positional hashes on a read
        // after relaunch; missing evidence on an older intent stays absent.
        let hash = String(repeating: "ab", count: 32)
        do {
            var intent = ArenaDeliveryIntent(taskId: "sample:independent:gemini", prompt: "q",
                                            stage: "independent", round: 1, phase: .prepared,
                                            preparedAt: 1, submittedAt: nil, pageURL: nil)
            let encoder = JSONEncoder(), decoder = JSONDecoder()
            let legacy = try decoder.decode(ArenaDeliveryIntent.self, from: encoder.encode(intent))
            check("legacy intent has no pixel proof", legacy.imagePixelDigests == nil)
            intent.imagePixelDigests = try ArenaModel.preparedImagePixels([hash, ""], count: 2)
            let restored = try decoder.decode(ArenaDeliveryIntent.self, from: encoder.encode(intent))
            check("pixel proofs retain image order and empty slots on restore", restored.imagePixelDigests == [hash, ""])
            check("malformed pixel proof rejected", (try? ArenaModel.preparedImagePixels(["invalid"], count: 1)) == nil)
            check("wrong proof count rejected", (try? ArenaModel.preparedImagePixels([hash], count: 2)) == nil)
        } catch {
            check("pixel proof persistence", false)
        }

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

        // --- 5b. A seat-local label only promises what the intent proves ------
        check("a submitted intent may offer only a read-only check",
              ArenaModel.seatLocalActionKind(
                  intentPhase: .submitted, hasCompletePreview: false, canBackfill: true
              ) == .readOnlyCheck)
        check("an inflight intent may offer only a read-only check",
              ArenaModel.seatLocalActionKind(
                  intentPhase: .inflight, hasCompletePreview: false, canBackfill: true
              ) == .readOnlyCheck)
        check("an uncertain intent may offer only a read-only check",
              ArenaModel.seatLocalActionKind(
                  intentPhase: .uncertain, hasCompletePreview: false, canBackfill: true
              ) == .readOnlyCheck)
        check("a prepared intent is never labelled read-only",
              ArenaModel.seatLocalActionKind(
                  intentPhase: .prepared, hasCompletePreview: false, canBackfill: true
              ) == nil)
        check("a task without an intent offers no local shortcut",
              ArenaModel.seatLocalActionKind(
                  intentPhase: nil, hasCompletePreview: false, canBackfill: true
              ) == nil)
        check("a complete refused answer prefers a confirmed backfill",
              ArenaModel.seatLocalActionKind(
                  intentPhase: .submitted, hasCompletePreview: true, canBackfill: true
              ) == .verifyAndBackfill)
        check("a prepared task never opens an empty backfill instead",
              ArenaModel.seatLocalActionKind(
                  intentPhase: .prepared, hasCompletePreview: false, canBackfill: true
              ) == nil)
        check("no read-only action is faked without a safe fallback",
              ArenaModel.seatLocalActionKind(
                  intentPhase: .prepared, hasCompletePreview: false, canBackfill: false
              ) == nil)
        check("a refused answer without backfill offers nothing",
              ArenaModel.seatLocalActionKind(
                  intentPhase: .submitted, hasCompletePreview: true, canBackfill: false
              ) == nil)

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

        // --- 7. Bounded conversation-drift return -----------------------------
        let allowedDrift = ArenaModel.conversationDriftReturnDecision(
            bound: true, drifted: true, alreadyUsed: false, phase: .submitted,
            openingImagesPrepared: false, taskIsCurrent: true, paused: false, takenOver: false
        )
        check("a submitted task may return to its saved conversation", allowedDrift == .proceed)

        let preparedDrift = ArenaModel.conversationDriftReturnDecision(
            bound: true, drifted: true, alreadyUsed: false, phase: .prepared,
            openingImagesPrepared: false, taskIsCurrent: true, paused: false, takenOver: false
        )
        check("a prepared task may return before its guarded pre-click path", preparedDrift == .proceed)

        func driftReason(_ decision: ArenaModel.ConversationDriftDecision) -> String? {
            if case .blocked(let reason) = decision { return reason }
            return nil
        }
        let usedReason = driftReason(ArenaModel.conversationDriftReturnDecision(
            bound: true, drifted: true, alreadyUsed: true, phase: .submitted,
            openingImagesPrepared: false, taskIsCurrent: true, paused: false, takenOver: false
        ))
        check("a second drift is not returned automatically",
              usedReason?.contains("已尝试自动恢复") == true)
        check("the repeat message never claims a successful return",
              usedReason?.contains("已自动返回") == false)
        check("the repeat message offers the real recovery button",
              usedReason?.contains("回到本场对话并恢复") == true)

        let mismatchReason = driftReason(ArenaModel.conversationDriftReturnDecision(
            bound: true, drifted: false, alreadyUsed: false, phase: .submitted,
            openingImagesPrepared: false, taskIsCurrent: true, paused: false, takenOver: false
        ))
        check("a WebKit/driver disagreement blocks instead of looping",
              mismatchReason?.contains("原页地址与网页内容不一致") == true)
        check("a WebKit/driver disagreement asks for page verification",
              mismatchReason?.contains("核对原页") == true
                  && mismatchReason?.contains("回到本场对话并恢复") == true)

        let imageReason = driftReason(ArenaModel.conversationDriftReturnDecision(
            bound: true, drifted: true, alreadyUsed: false, phase: .prepared,
            openingImagesPrepared: true, taskIsCurrent: true, paused: false, takenOver: false
        ))
        check("prepared opening images block an automatic return", imageReason?.contains("首轮图片") == true)

        let noBoundReason = driftReason(ArenaModel.conversationDriftReturnDecision(
            bound: false, drifted: true, alreadyUsed: false, phase: .submitted,
            openingImagesPrepared: false, taskIsCurrent: true, paused: false, takenOver: false
        ))
        check("an unbound seat is never returned", noBoundReason?.contains("尚未固定") == true)
        check("an unbound seat is not offered a return action",
              noBoundReason?.contains("回到本场对话") == false)

        check("a paused or taken-over seat never returns", ArenaModel.conversationDriftReturnDecision(
            bound: true, drifted: true, alreadyUsed: false, phase: .submitted,
            openingImagesPrepared: false, taskIsCurrent: true, paused: true, takenOver: false
        ) == .stop)
        check("a replaced task never returns", ArenaModel.conversationDriftReturnDecision(
            bound: true, drifted: true, alreadyUsed: false, phase: .submitted,
            openingImagesPrepared: false, taskIsCurrent: false, paused: false, takenOver: false
        ) == .stop)
        check("a taken-over seat never returns", ArenaModel.conversationDriftReturnDecision(
            bound: true, drifted: true, alreadyUsed: false, phase: .submitted,
            openingImagesPrepared: false, taskIsCurrent: true, paused: false, takenOver: true
        ) == .stop)

        let recoveredReading = ArenaModel.conversationDriftRecoveredMessage(.reading)
        check("a recovered read says the turn was sent and stays read-only",
              recoveredReading.contains("本轮提问已发出")
                  && recoveredReading.contains("已自动回到本场对话")
                  && recoveredReading.contains("只读"))
        let blockedDraft = ArenaModel.conversationDriftBlockedMessage(
            .reading,
            reason: ArenaModel.conversationDriftSafetyReason(.draft)
        )
        check("a draft blocks the return with concrete steps",
              blockedDraft.contains("未发送的草稿或附件")
                  && blockedDraft.contains("回到本场对话并恢复"))
        check("a draft message does not repeat menu alternatives",
              !blockedDraft.contains("文本补录") && !blockedDraft.contains("恢复本站自动"))
        let unreachable = ArenaModel.conversationDriftUnreachableMessage(.verifying, reason: "离线")
        check("an unreachable original keeps the send uncertain and read-only",
              unreachable.contains("可能已发出")
                  && unreachable.contains("只核对、不重发")
                  && unreachable.contains("自动返回未成功"))
        let postReturnMismatch = ArenaModel.conversationDriftReadFailureMessage(.reading)
        check("a post-return prompt mismatch says what to do next",
              postReturnMismatch.contains("未核对到本轮完整提问")
                  && postReturnMismatch.contains("人工接管")
                  && postReturnMismatch.contains("文本补录…")
                  && postReturnMismatch.contains("不会自动重发"))
        let postReturnUncertain = ArenaModel.conversationDriftReadFailureMessage(.verifying)
        check("a post-return uncertain mismatch says it will not resend",
              postReturnUncertain.contains("可能已发出")
                  && postReturnUncertain.contains("只核对、不重发"))
        check("post-return prompt mismatches are recognized",
              ["user-turn-mismatch", "history-changed", "task-prompt-mismatch",
               "task-unknown", "page-changed", "recovery-timeout"].allSatisfy(
                  ArenaModel.isPostReturnPromptMismatch
              ))
        check("an unrelated error is not labelled a post-return prompt mismatch",
              !ArenaModel.isPostReturnPromptMismatch("selector-missing"))
        let unknownPage = ArenaModel.conversationDriftBlockedMessage(
            .beforeSend,
            reason: ArenaModel.conversationDriftSafetyReason(.unavailable("selector-missing"))
        )
        check("an uninspectable page fails closed", unknownPage.contains("无法核对"))
        check("drift status text never embeds a URL",
              ![recoveredReading, blockedDraft, unreachable, unknownPage].contains { $0.contains("http") })

        if failures == 0 {
            print("native seat state: all checks passed")
            exit(0)
        }
        print("native seat state: \(failures) check(s) failed")
        exit(1)
    }
}
