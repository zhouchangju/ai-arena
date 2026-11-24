//
//  guidance_history.swift
//  AI Arena · 讨论中补充条件与本机历史检索的定向检查
//
//  目标：G1/G2/G3/G4，R03/R06/R07。只验证纯逻辑：
//    * 补充条件只在独立作答/互评、暂停、同场次同阶段同轮次时可保存；
//    * 已保存条件的阶段、轮次与送达记账从持久化场次读回；
//    * 历史检索只过滤本机摘要（题面、席位、结果、状态），且不改动摘要；
//    * 指定候选版本的表态投影只保留该版本的候选与表态材料。
//
//  不启动应用、不创建窗口、不访问网络、不打开真实账号。
//
//  由 tests/guidance_history.py 编译运行：
//    xcrun --sdk macosx swiftc -swift-version 5 \
//      -framework AppKit -framework JavaScriptCore \
//      desktop/ArenaEngine.swift desktop/ArenaEvaluation.swift \
//      desktop/ArenaGuidance.swift desktop/ArenaHistorySearch.swift \
//      tests/guidance_history.swift -o <bin>
//

import Foundation

@main
struct GuidanceHistoryCheck {
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

        // --- 1. Guidance availability ---------------------------------------
        check(
            "live independent needs a pause first",
            ArenaGuidanceRules.availability(
                stage: "independent", sessionID: "s1", readOnly: false, paused: false
            ) == .available(requiresPause: true)
        )
        check(
            "already paused critique can save directly",
            ArenaGuidanceRules.availability(
                stage: "critique", sessionID: "s1", readOnly: false, paused: true
            ) == .available(requiresPause: false)
        )
        for stage in ["proposal", "vote", "done", ""] {
            check(
                "\(stage.isEmpty ? "no-stage" : stage) hides the affordance",
                ArenaGuidanceRules.availability(
                    stage: stage, sessionID: "s1", readOnly: false, paused: true
                ) == .hidden
            )
        }
        check(
            "read-only history hides the affordance",
            ArenaGuidanceRules.availability(
                stage: "critique", sessionID: "s1", readOnly: true, paused: true
            ) == .hidden
        )
        check(
            "a session without an id hides the affordance",
            ArenaGuidanceRules.availability(
                stage: "independent", sessionID: nil, readOnly: false, paused: false
            ) == .hidden
        )

        // --- 2. Pinned target acceptance ------------------------------------
        let target = ArenaGuidanceTarget(sessionID: "s1", stage: "critique", round: 2)
        check(
            "the same paused phase accepts",
            ArenaGuidanceRules.accepts(
                target: target, sessionID: "s1", stage: "critique", round: 2,
                paused: true, readOnly: false
            )
        )
        check(
            "an unpaused phase refuses",
            !ArenaGuidanceRules.accepts(
                target: target, sessionID: "s1", stage: "critique", round: 2,
                paused: false, readOnly: false
            )
        )
        check(
            "a different round refuses",
            !ArenaGuidanceRules.accepts(
                target: target, sessionID: "s1", stage: "critique", round: 3,
                paused: true, readOnly: false
            )
        )
        check(
            "a different stage refuses",
            !ArenaGuidanceRules.accepts(
                target: target, sessionID: "s1", stage: "independent", round: 2,
                paused: true, readOnly: false
            )
        )
        check(
            "a different session refuses",
            !ArenaGuidanceRules.accepts(
                target: target, sessionID: "s2", stage: "critique", round: 2,
                paused: true, readOnly: false
            )
        )
        check(
            "a read-only history refuses",
            !ArenaGuidanceRules.accepts(
                target: target, sessionID: "s1", stage: "critique", round: 2,
                paused: true, readOnly: true
            )
        )
        check(
            "a mechanism that no longer accepts guidance refuses",
            !ArenaGuidanceRules.accepts(
                target: target, sessionID: "s1", stage: "vote", round: 2,
                paused: true, readOnly: false
            )
        )

        // --- 3. Reading saved notes -----------------------------------------
        check("a legacy session has no conditions", ArenaGuidanceRules.notes(from: nil).isEmpty)
        check(
            "a session saved without the field has no conditions",
            ArenaGuidanceRules.notes(from: ["id": "s1"]).isEmpty
        )

        let session: [String: Any] = [
            "id": "s1",
            "guidance": [
                [
                    "seq": 1,
                    "text": "  预算最多两周  ",
                    "stage": "critique",
                    "round": 2,
                    "createdAt": 1_700_000_000_000.0,
                    "deliveredTo": ["critique-2-chatgpt", "proposal-2-gemini"],
                ],
                [
                    "seq": 2,
                    "text": "   ",
                    "stage": "independent",
                    "round": 1,
                    "createdAt": 1_700_000_000_001.0,
                    "deliveredTo": [],
                ],
            ],
        ]
        let notes = ArenaGuidanceRules.notes(from: session)
        check("only non-empty conditions are read back", notes.count == 1)
        check("condition text is trimmed", notes.first?.text == "预算最多两周")
        check("condition keeps its stage", notes.first?.stage == "critique")
        check("condition keeps its round", notes.first?.round == 2)
        check("condition keeps its marker", notes.first?.createdAt == 1_700_000_000_000.0)
        check(
            "delivery names the exact newly constructed prompts",
            notes.first?.deliveryLabel == "已计入 2 个之后新建的提示"
        )
        check(
            "an undelivered condition stays neutral about a finished discussion",
            ArenaGuidanceNote(
                seq: 2, text: "x", stage: "independent", round: 1,
                createdAt: 0, deliveredTaskIDs: []
            ).deliveryLabel == "尚未计入任何后续提示"
        )
        check(
            "independent is not labelled as review round 1",
            ArenaGuidanceNote(
                seq: 1, text: "x", stage: "independent", round: 1,
                createdAt: 0, deliveredTaskIDs: []
            ).originLabel == "独立作答时提出"
        )
        check(
            "a critique condition names its real review round",
            ArenaGuidanceNote(
                seq: 1, text: "x", stage: "critique", round: 2,
                createdAt: 0, deliveredTaskIDs: []
            ).originLabel == "互评第 2 轮提出"
        )
        check(
            "the guidance limit matches the shared engine's 2000 UTF-16 units",
            ArenaGuidanceRules.maxTextLength == 2000
                && String(repeating: "x", count: 2000).utf16.count == 2000
                && "😀".utf16.count == 2
        )

        // --- 4. History search ----------------------------------------------
        func summary(
            _ id: String,
            _ question: String,
            updatedAt: Double,
            stage: String = "done",
            stopReason: String? = "consensus",
            paused: Bool = false,
            providers: [String]
        ) -> ArenaHistorySummary {
            ArenaHistorySummary(
                id: id,
                question: question,
                createdAt: updatedAt - 1_000,
                updatedAt: updatedAt,
                stage: stage,
                round: 1,
                stopReason: stopReason,
                hasReport: stage == "done",
                paused: paused,
                providers: providers
            )
        }

        let fixtures = [
            summary("a", "值不值得先做移动端？", updatedAt: 400, providers: ["chatgpt", "gemini"]),
            summary("b", "笔记检索速度怎么改", updatedAt: 300, stage: "critique",
                    stopReason: nil, providers: ["chatgpt", "deepseek"]),
            summary("c", "先做检索还是先做导出", updatedAt: 200,
                    stopReason: "unresolved-opposition", providers: ["gemini", "deepseek"]),
            summary("d", "暂停中的讨论", updatedAt: 100, stage: "independent",
                    stopReason: nil, paused: true, providers: ["chatgpt"]),
        ]
        let seatName: (String) -> String = {
            ["chatgpt": "ChatGPT", "gemini": "Gemini", "deepseek": "DeepSeek"][$0] ?? $0
        }

        var criteria = ArenaHistorySearchCriteria()
        check(
            "no criteria keeps every summary in update order",
            ArenaHistorySearch.filter(fixtures, criteria: criteria).map(\.id) == ["a", "b", "c", "d"]
        )
        criteria.query = "移动端"
        check(
            "the question is searchable",
            ArenaHistorySearch.filter(fixtures, criteria: criteria).map(\.id) == ["a"]
        )
        criteria = ArenaHistorySearchCriteria()
        criteria.query = "GEMINI"
        check(
            "a seat display name is searchable case-insensitively",
            ArenaHistorySearch.filter(fixtures, criteria: criteria, seatName: seatName).map(\.id) == ["a", "c"]
        )
        criteria.query = "仍有反对"
        check(
            "an outcome label is searchable",
            ArenaHistorySearch.filter(fixtures, criteria: criteria).map(\.id) == ["c"]
        )
        criteria = ArenaHistorySearchCriteria(state: .finished)
        check(
            "the finished filter excludes running and paused sessions",
            ArenaHistorySearch.filter(fixtures, criteria: criteria).map(\.id) == ["a", "c"]
        )
        criteria = ArenaHistorySearchCriteria(state: .unfinished)
        check(
            "the unfinished filter keeps every running session",
            ArenaHistorySearch.filter(fixtures, criteria: criteria).map(\.id) == ["b", "d"]
        )
        criteria = ArenaHistorySearchCriteria(state: .paused)
        check(
            "the paused filter keeps only paused running sessions",
            ArenaHistorySearch.filter(fixtures, criteria: criteria).map(\.id) == ["d"]
        )
        criteria = ArenaHistorySearchCriteria(outcome: "unfinished-paused")
        check(
            "an exact outcome filter is applied",
            ArenaHistorySearch.filter(fixtures, criteria: criteria).map(\.id) == ["d"]
        )
        // Core ends the discussion with `no-critique` when independent answers
        // exist but no critique did; it must not collapse into generic ended.
        let noCritique = summary("e", "本轮没有可用互评", updatedAt: 50,
                                 stopReason: "no-critique", providers: ["chatgpt", "gemini"])
        check(
            "a core no-critique stop reason keeps its own outcome and label",
            ArenaHistoryOutcome.key(for: noCritique) == "no-critique"
                && ArenaHistoryOutcome.label(for: noCritique) == "缺少互评材料"
                && ArenaHistorySearch.filter(
                    fixtures + [noCritique],
                    criteria: ArenaHistorySearchCriteria(outcome: "no-critique")
                ).map(\.id) == ["e"]
        )
        criteria = ArenaHistorySearchCriteria(seat: "deepseek")
        check(
            "a seat filter uses the persisted seats",
            ArenaHistorySearch.filter(fixtures, criteria: criteria).map(\.id) == ["b", "c"]
        )
        criteria = ArenaHistorySearchCriteria(query: "导出")
        check(
            "a term from one saved session never matches another",
            ArenaHistorySearch.filter(fixtures, criteria: criteria).map(\.id) == ["c"]
        )
        criteria = ArenaHistorySearchCriteria(query: "笔记", state: .finished)
        check(
            "search and state filters combine",
            ArenaHistorySearch.filter(fixtures, criteria: criteria).isEmpty
        )
        check(
            "searching never mutates the summaries",
            fixtures.map(\.id) == ["a", "b", "c", "d"] && fixtures[1].isFinished == false
        )
        let outcomeFacets = ArenaHistorySearch.outcomeFacets(fixtures)
        check(
            "outcome facets are unique",
            outcomeFacets.map(\.key).sorted() == ["consensus", "unfinished", "unfinished-paused", "unresolved-opposition"]
        )
        check(
            "seat facets list each persisted seat once",
            ArenaHistorySearch.seatFacets(fixtures, seatName: seatName).map(\.label).sorted()
                == ["ChatGPT", "DeepSeek", "Gemini"]
        )
        check(
            "default criteria are recognised",
            ArenaHistorySearchCriteria().isDefault
                && !ArenaHistorySearchCriteria(query: "x").isDefault
        )

        // --- 4b. Keyboard selection over the visible results ----------------
        var selection = ArenaHistorySelection()
        check("nothing is selected before the sheet loads", selection.id == nil)
        check(
            "reconciling an empty result set selects nothing",
            !selection.reconcile(with: []) && selection.id == nil
        )
        check(
            "reconciling selects the first visible row",
            selection.reconcile(with: ["a", "b", "c"]) && selection.id == "a"
        )
        check(
            "an already visible selection stays put",
            !selection.reconcile(with: ["a", "b", "c"]) && selection.id == "a"
        )
        selection = ArenaHistorySelection(id: "c")
        check(
            "a query or filter change starts at the first visible row",
            selection.selectFirst(in: ["a", "b", "c"]) && selection.id == "a"
        )
        check(
            "selecting the first row again is a no-op",
            !selection.selectFirst(in: ["a", "b", "c"]) && selection.id == "a"
        )
        selection = ArenaHistorySelection(id: "c")
        check(
            "clearing the query starts again at the newest row",
            selection.selectFirst(in: ["n", "b", "c"]) && selection.id == "n"
        )
        check(
            "a query with no results selects nothing",
            selection.selectFirst(in: []) && selection.id == nil
        )
        selection = ArenaHistorySelection(id: "a")
        check(
            "a filter that hides the selection falls back to the first visible row",
            selection.reconcile(with: ["b", "c"]) && selection.id == "b"
        )
        check(
            "down moves one row",
            selection.move(.down, in: ["b", "c"]) && selection.id == "c"
        )
        check(
            "down stops at the last row",
            !selection.move(.down, in: ["b", "c"]) && selection.id == "c"
        )
        check(
            "up moves one row",
            selection.move(.up, in: ["b", "c"]) && selection.id == "b"
        )
        check(
            "up stops at the first row",
            !selection.move(.up, in: ["b", "c"]) && selection.id == "b"
        )
        check(
            "a filter that empties the results clears the selection",
            selection.reconcile(with: []) && selection.id == nil
        )
        check(
            "return has nothing to open on an empty result set",
            !selection.move(.down, in: []) && !selection.move(.up, in: []) && selection.id == nil
        )
        check(
            "down without a selection starts at the first row",
            selection.move(.down, in: ["a", "b"]) && selection.id == "a"
        )
        selection = ArenaHistorySelection()
        check(
            "up without a selection starts at the last row",
            selection.move(.up, in: ["a", "b"]) && selection.id == "b"
        )
        selection = ArenaHistorySelection(id: "gone")
        check(
            "a selection from a previous filter is replaced on the next move",
            selection.move(.down, in: ["x", "y"]) && selection.id == "x"
        )

        // --- 4b. One unified Chinese term per saved outcome -----------------
        let expectedLabels: [String: String] = [
            "consensus": "全体一致",
            "conditional-agreement": "有条件一致",
            "unresolved-opposition": "仍有反对",
            "partial-votes": "部分表态",
            "partial-participation": "参与不足",
            "no-cross-review": "互评缺失",
            "no-critique": "缺少互评材料",
            "proposal-skipped": "未形成候选",
            "draft": "候选草稿",
            "user-finished": "提前结束",
            "no-answers": "无有效回答",
        ]
        check(
            "every known stop reason has one unified label",
            expectedLabels.allSatisfy { ArenaHistoryOutcome.label(stopReason: $0.key) == $0.value }
        )
        let unknown = summary("f", "未来版本的停止原因", updatedAt: 25,
                              stopReason: "future-stop", providers: ["chatgpt", "gemini"])
        check(
            "an unknown stop code keeps its raw value in the summary",
            unknown.stopReason == "future-stop"
        )
        check(
            "an unknown stop code reads as a generic finished state",
            ArenaHistoryOutcome.label(for: unknown) == "已结束"
        )
        check(
            "an unknown stop code keeps a generic filter key",
            ArenaHistoryOutcome.key(for: unknown) == "finished"
        )
        criteria = ArenaHistorySearchCriteria(query: "讨论已结束")
        check(
            "the former report wording still finds the session",
            ArenaHistorySearch.filter([unknown], criteria: criteria).map(\.id) == ["f"]
        )
        criteria = ArenaHistorySearchCriteria(query: "存在分歧")
        check(
            "the former opposition wording still finds the session",
            ArenaHistorySearch.filter(fixtures, criteria: criteria).map(\.id) == ["c"]
        )
        criteria = ArenaHistorySearchCriteria(query: "仍有反对")
        check(
            "the current opposition wording keeps working",
            ArenaHistorySearch.filter(fixtures, criteria: criteria).map(\.id) == ["c"]
        )

        // The report reader must never upgrade a missing vote to consensus.
        check(
            "a verified consensus uses the shared term",
            ArenaHistoryOutcome.reportLabel(
                stopReason: "consensus", verifiedConsensus: true, hasConditionalVote: false
            ) == "全体一致"
        )
        check(
            "a consensus without every vote degrades",
            ArenaHistoryOutcome.reportLabel(
                stopReason: "consensus", verifiedConsensus: false, hasConditionalVote: false
            ) == "表态记录不完整"
        )
        check(
            "a conditional stop without a conditional vote degrades",
            ArenaHistoryOutcome.reportLabel(
                stopReason: "conditional-agreement", verifiedConsensus: false, hasConditionalVote: false
            ) == "表态记录不完整"
        )
        check(
            "a conditional stop with a saved vote uses the shared term",
            ArenaHistoryOutcome.reportLabel(
                stopReason: "conditional-agreement", verifiedConsensus: false, hasConditionalVote: true
            ) == "有条件一致"
        )
        check(
            "an opposition report uses the same term as history",
            ArenaHistoryOutcome.reportLabel(
                stopReason: "unresolved-opposition", verifiedConsensus: false, hasConditionalVote: false
            ) == ArenaHistoryOutcome.label(for: fixtures[2])
        )
        check(
            "partial votes keeps its degraded shared term",
            ArenaHistoryOutcome.reportLabel(
                stopReason: "partial-votes", verifiedConsensus: false, hasConditionalVote: false
            ) == "部分表态"
        )
        check(
            "an unknown report stop uses the generic finished term",
            ArenaHistoryOutcome.reportLabel(
                stopReason: "future-stop", verifiedConsensus: false, hasConditionalVote: false
            ) == "已结束"
        )

        // --- 4c. Opening a saved session never duplicates an inline report ---
        check(
            "a read-only session with a report stays in the workbench",
            ArenaHistoryOpenTarget.decide(readOnly: true, hasReport: true) == .inlineReport
        )
        check(
            "a read-only session without a report lands on saved answers",
            ArenaHistoryOpenTarget.decide(readOnly: true, hasReport: false) == .savedAnswers
        )
        check(
            "a live finished session opens the independent report",
            ArenaHistoryOpenTarget.decide(readOnly: false, hasReport: true) == .report
        )
        check(
            "a live session without a report lands on saved answers",
            ArenaHistoryOpenTarget.decide(readOnly: false, hasReport: false) == .savedAnswers
        )

        // --- 4d. The export/banner label is strict about missing votes ------
        func ballot(
            candidate: String? = "p2",
            version: Int = 2,
            votes: [(String, String)]
        ) -> [String: Any] {
            var value: [String: Any] = [
                "version": version,
                "votes": votes.map {
                    ["id": "vote-\($0.0)", "provider": $0.0, "stance": $0.1]
                },
            ]
            if let candidate { value["candidateID"] = candidate }
            return value
        }
        let seats = ["chatgpt", "gemini", "deepseek"]
        let complete = ballot(votes: [("chatgpt", "agree"), ("gemini", "agree"), ("deepseek", "agree")])
        check(
            "every same-version agree vote keeps the shared consensus label",
            ArenaHistoryOutcome.conservativeLabel(
                stopReason: "consensus", ballot: complete, participants: seats
            ) == "全体一致"
        )
        check(
            "a consensus with one missing vote degrades in the export label",
            ArenaHistoryOutcome.conservativeLabel(
                stopReason: "consensus",
                ballot: ballot(votes: [("chatgpt", "agree"), ("gemini", "agree")]),
                participants: seats
            ) == "表态记录不完整"
        )
        check(
            "a consensus with one conditional vote degrades",
            ArenaHistoryOutcome.conservativeLabel(
                stopReason: "consensus",
                ballot: ballot(votes: [("chatgpt", "agree"), ("gemini", "agree"), ("deepseek", "conditional")]),
                participants: seats
            ) == "表态记录不完整"
        )
        check(
            "a consensus code without any ballot degrades",
            ArenaHistoryOutcome.conservativeLabel(
                stopReason: "consensus", ballot: nil, participants: seats
            ) == "表态记录不完整"
        )
        check(
            "a ballot without an answered candidate version degrades",
            ArenaHistoryOutcome.conservativeLabel(
                stopReason: "consensus",
                ballot: ballot(candidate: nil, version: 0, votes: [
                    ("chatgpt", "agree"), ("gemini", "agree"), ("deepseek", "agree"),
                ]),
                participants: seats
            ) == "表态记录不完整"
        )
        check(
            "a consensus without recorded participants degrades",
            ArenaHistoryOutcome.conservativeLabel(
                stopReason: "consensus", ballot: complete, participants: []
            ) == "表态记录不完整"
        )
        check(
            "a vote for a non-participant cannot complete the ballot",
            ArenaHistoryOutcome.conservativeLabel(
                stopReason: "consensus",
                ballot: ballot(votes: [("chatgpt", "agree"), ("gemini", "agree"), ("other", "agree")]),
                participants: seats
            ) == "表态记录不完整"
        )
        check(
            "a conditional stop with a saved conditional vote keeps its term",
            ArenaHistoryOutcome.conservativeLabel(
                stopReason: "conditional-agreement",
                ballot: ballot(votes: [("chatgpt", "agree"), ("gemini", "conditional")]),
                participants: seats
            ) == "有条件一致"
        )
        check(
            "a conditional stop without a conditional vote degrades",
            ArenaHistoryOutcome.conservativeLabel(
                stopReason: "conditional-agreement",
                ballot: ballot(votes: [("chatgpt", "agree")]),
                participants: seats
            ) == "表态记录不完整"
        )
        let savedConsensus: [String: Any] = [
            "stopReason": "consensus",
            "providers": ["chatgpt", "gemini"],
        ]
        _ = ArenaHistoryOutcome.conservativeLabel(
            stopReason: savedConsensus["stopReason"] as? String,
            ballot: nil,
            participants: savedConsensus["providers"] as? [String] ?? []
        )
        check(
            "the conservative label never rewrites the saved stop code",
            savedConsensus["stopReason"] as? String == "consensus"
        )

        // --- 4e. History rows use the same strict stamp, computed once ------
        func versionedBallot(
            candidate: String = "p2",
            version: Int = 2,
            voteVersion: Int? = nil,
            votes: [(String, String)]
        ) -> [String: Any] {
            var value = ballot(candidate: candidate, version: version, votes: votes)
            if let voteVersion {
                let rows = (value["votes"] as? [[String: Any]] ?? []).map { row -> [String: Any] in
                    var copy = row
                    copy["version"] = voteVersion
                    return copy
                }
                value["votes"] = rows
            }
            return value
        }
        let fullBallot = versionedBallot(voteVersion: 2, votes: [
            ("chatgpt", "agree"), ("gemini", "agree"), ("deepseek", "agree"),
        ])
        check(
            "a true full same-version ballot stamps consensus",
            ArenaHistoryOutcome.stamp(
                stopReason: "consensus", ballot: fullBallot, participants: seats
            ) == ArenaHistoryOutcome.Stamp(key: "consensus", label: "全体一致")
        )
        check(
            "a missing vote stamps the conservative incomplete label",
            ArenaHistoryOutcome.stamp(
                stopReason: "consensus",
                ballot: versionedBallot(voteVersion: 2, votes: [
                    ("chatgpt", "agree"), ("gemini", "agree"),
                ]),
                participants: seats
            ) == ArenaHistoryOutcome.Stamp(key: "incomplete-votes", label: "表态记录不完整")
        )
        check(
            "votes from the wrong version stamp the incomplete label",
            ArenaHistoryOutcome.stamp(
                stopReason: "consensus",
                ballot: versionedBallot(voteVersion: 1, votes: [
                    ("chatgpt", "agree"), ("gemini", "agree"), ("deepseek", "agree"),
                ]),
                participants: seats
            ) == ArenaHistoryOutcome.Stamp(key: "incomplete-votes", label: "表态记录不完整")
        )
        check(
            "a shell or ballot-less record degrades instead of claiming consensus",
            ArenaHistoryOutcome.stamp(
                stopReason: "consensus", ballot: nil, participants: seats
            ) == ArenaHistoryOutcome.Stamp(key: "incomplete-votes", label: "表态记录不完整")
        )
        check(
            "a genuinely verified conditional stamp keeps its own label",
            ArenaHistoryOutcome.stamp(
                stopReason: "conditional-agreement",
                ballot: versionedBallot(voteVersion: 2, votes: [
                    ("chatgpt", "agree"), ("gemini", "conditional"),
                ]),
                participants: seats
            ) == ArenaHistoryOutcome.Stamp(key: "conditional-agreement", label: "有条件一致")
        )
        check(
            "a conditional without a same-version conditional vote degrades",
            ArenaHistoryOutcome.stamp(
                stopReason: "conditional-agreement",
                ballot: versionedBallot(voteVersion: 1, votes: [
                    ("chatgpt", "agree"), ("gemini", "conditional"),
                ]),
                participants: seats
            ) == ArenaHistoryOutcome.Stamp(key: "incomplete-votes", label: "表态记录不完整")
        )
        check(
            "other stop codes keep the raw-code label",
            ArenaHistoryOutcome.stamp(
                stopReason: "unresolved-opposition", ballot: fullBallot, participants: seats
            ) == nil
        )

        var degraded = summary("g", "旧记录停止码", updatedAt: 20,
                               stopReason: "consensus", providers: seats)
        degraded.conservativeOutcomeKey = "incomplete-votes"
        degraded.conservativeOutcomeLabel = "表态记录不完整"
        check(
            "a stamped history row shows the conservative label",
            ArenaHistoryOutcome.label(for: degraded) == "表态记录不完整"
                && ArenaHistoryOutcome.key(for: degraded) == "incomplete-votes"
        )
        check(
            "the raw code stays in the summary for provenance",
            degraded.stopReason == "consensus"
        )
        check(
            "the stamped row is not found as consensus",
            ArenaHistorySearch.filter(
                [degraded],
                criteria: ArenaHistorySearchCriteria(query: "全体一致")
            ).isEmpty
        )
        check(
            "the stamped row is found by its conservative label",
            ArenaHistorySearch.filter(
                [degraded],
                criteria: ArenaHistorySearchCriteria(query: "表态记录不完整")
            ).map(\.id) == ["g"]
        )
        check(
            "the outcome filter follows the stamped key",
            ArenaHistorySearch.filter(
                [degraded],
                criteria: ArenaHistorySearchCriteria(outcome: "consensus")
            ).isEmpty
                && ArenaHistorySearch.filter(
                    [degraded],
                    criteria: ArenaHistorySearchCriteria(outcome: "incomplete-votes")
                ).map(\.id) == ["g"]
        )
        let degradedFacets = ArenaHistorySearch.outcomeFacets([degraded])
        check(
            "the outcome facet uses the conservative key and label",
            degradedFacets.map(\.key) == ["incomplete-votes"]
                && degradedFacets.map(\.label) == ["表态记录不完整"]
        )
        check(
            "an unstamped summary still falls back to the raw label",
            ArenaHistoryOutcome.label(for: summary("h", "壳场", updatedAt: 10,
                                                  stopReason: "consensus", providers: []))
                == "全体一致"
        )
        let tied = summary("a", "同一时间的旧场", updatedAt: 500, providers: seats)
        let tiedOther = summary("b", "同一时间的另一场", updatedAt: 500, providers: seats)
        check(
            "equal update times keep a stable id order",
            ArenaSessionStore.upserting(tied, into: [tiedOther]).map(\.id) == ["a", "b"]
        )

        // --- 5. Version-scoped ballot projection ----------------------------
        let history: [[String: Any]] = [
            [
                "id": "p1", "provider": "chatgpt", "stage": "proposal", "status": "answered",
                "version": 1, "round": 1, "answer": "旧候选 [S1]", "prompt": "很长的提示一",
            ],
            [
                "id": "v1", "provider": "gemini", "stage": "vote", "status": "answered",
                "version": 1, "round": 1, "stance": "agree", "proposalDigest": "6:00000001",
                "prompt": "很长的提示二",
            ],
            [
                "id": "p2", "provider": "gemini", "stage": "proposal", "status": "answered",
                "version": 2, "round": 2, "answer": "新候选 [S2]", "prompt": "很长的提示三",
            ],
            [
                "id": "v2", "provider": "chatgpt", "stage": "vote", "status": "answered",
                "version": 2, "round": 2, "stance": "conditional", "proposalDigest": "8:00000002",
                "prompt": "很长的提示四",
            ],
            [
                "id": "c1", "provider": "deepseek", "stage": "critique", "status": "answered",
                "version": 2, "round": 2, "answer": "互评正文", "prompt": "很长的提示五",
            ],
        ]
        let v2 = ArenaBallotProjection.materials(history: history, version: 2)
        check(
            "a version keeps exactly its proposal and votes",
            v2.map { $0["id"] as? String } == ["p2", "v2"]
        )
        check(
            "the candidate text survives the projection",
            v2.first?["answer"] as? String == "新候选 [S2]"
        )
        check(
            "the vote keeps its digest for strict verification",
            v2.last?["proposalDigest"] as? String == "8:00000002"
        )
        check(
            "prompts never cross into the projection",
            v2.allSatisfy { $0["prompt"] == nil }
        )
        check(
            "a different version keeps its own rows",
            ArenaBallotProjection.materials(history: history, version: 1).map { $0["id"] as? String }
                == ["p1", "v1"]
        )
        check(
            "an unknown version projects nothing",
            ArenaBallotProjection.materials(history: history, version: 9).isEmpty
        )
        check(
            "the unfiltered projection keeps every proposal and vote",
            ArenaBallotProjection.materials(history: history).map { $0["id"] as? String }
                == ["p1", "v1", "p2", "v2"]
        )
        check(
            "known versions are detected from answered proposals",
            ArenaBallotProjection.containsProposal(version: 2, in: history)
                && !ArenaBallotProjection.containsProposal(version: 3, in: history)
        )
        let skippedProposal: [String: Any] = [
            "id": "p3", "provider": "chatgpt", "stage": "proposal", "status": "skipped",
            "version": 3, "round": 3, "answer": "",
        ]
        check(
            "a skipped proposal is not a ballot target",
            !ArenaBallotProjection.containsProposal(version: 3, in: history + [skippedProposal])
        )
        check(
            "version zero is never a ballot target",
            !ArenaBallotProjection.containsProposal(version: 0, in: history)
        )

        // --- 6. Unsaved condition drafts stay in process by pinned phase ---
        let t1 = ArenaGuidanceTarget(sessionID: "s1", stage: "independent", round: 1)
        let t2 = ArenaGuidanceTarget(sessionID: "s1", stage: "critique", round: 1)
        let t3 = ArenaGuidanceTarget(sessionID: "s2", stage: "independent", round: 1)
        var parking = ArenaGuidanceDraftParking()
        check("a fresh workbench parks nothing", parking.isEmpty && parking.text(for: t1).isEmpty)
        parking.set("预算最多两周", for: t1)
        check("closing and reopening the same round restores the text",
              parking.text(for: t1) == "预算最多两周")
        check("a non-blank draft counts as kept", parking.hasDraft(for: t1))
        parking.set("另一个阶段的草稿", for: t2)
        check("a different stage keeps its own text",
              parking.text(for: t1) == "预算最多两周" && parking.text(for: t2) == "另一个阶段的草稿")
        parking.set("别的场次", for: t3)
        check("a different session keeps its own text",
              parking.text(for: t1) == "预算最多两周" && parking.text(for: t3) == "别的场次")
        check("blank text never resurrects an empty slot",
              parking.text(for: ArenaGuidanceTarget(sessionID: "s9", stage: "critique", round: 2)).isEmpty)
        parking.keepOnly(t2)
        check("opening one round drops drafts from every other target",
              parking.text(for: t2) == "另一个阶段的草稿"
                && parking.text(for: t1).isEmpty
                && parking.text(for: t3).isEmpty)
        parking.set("   \n ", for: t2)
        check("a whitespace-only draft is not worth restoring", !parking.hasDraft(for: t2))
        parking.set("保存后要清空", for: t2)
        parking.clear(t2)
        check("a committed save clears the draft", parking.text(for: t2).isEmpty && parking.isEmpty)
        parking.set("拒绝保存要保留", for: t2)
        check("a rejected save keeps the draft", parking.text(for: t2) == "拒绝保存要保留")
        parking.removeAll()
        check("a fresh discussion clears every parked draft", parking.isEmpty)

        // --- 6b. What closing the editor does to the pause it applied ------
        check("cancelled with an empty draft undoes the pause it applied",
              ArenaGuidanceClosePolicy.undoesOwnedPause(ownedPause: true, saved: false, hasDraft: false))
        check("an unsaved draft keeps the pause so it can be reopened",
              !ArenaGuidanceClosePolicy.undoesOwnedPause(ownedPause: true, saved: false, hasDraft: true))
        check("a saved condition keeps the pause",
              !ArenaGuidanceClosePolicy.undoesOwnedPause(ownedPause: true, saved: true, hasDraft: false))
        check("a pause the user made is never undone",
              !ArenaGuidanceClosePolicy.undoesOwnedPause(ownedPause: false, saved: false, hasDraft: false))

        print(failures == 0 ? "all guidance/history checks passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)    }
}
