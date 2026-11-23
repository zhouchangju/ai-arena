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

        print(failures == 0 ? "all guidance/history checks passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
