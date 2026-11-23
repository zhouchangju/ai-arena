//
//  native_candidate_comparison.swift
//  AI Arena · 候选版本对比与同版表态核对
//
//  目标：G2/G3/G4，R04/R05/R07。只验证读取与对比规则：版本目录、
//  来自共享引擎的候选与表态映射、缺失候选、段落级变化和长文边界。
//  不启动应用、不创建窗口、不加载网页、不访问真实账号。
//
//  由 tests/native_candidate_comparison.py 编译运行。错误摘要的拒绝由
//  shared/core.js 的 tests/core.test.mjs 覆盖，这里不复制该规则。
//

import Foundation

@main
struct NativeCandidateComparisonCheck {
    static let v1 = """
    候选结论

    压缩即智能，因为恢复所需程序越短，理解越充分。

    适用条件：仅讨论无损压缩。

    仍需事实：长文本实验。
    """

    static let v2 = """
    候选结论

    压缩即智能，因为恢复所需程序越短，理解越充分。该判断依赖可计算压缩器 [S7]。

    适用条件：仅讨论无损压缩；超出范围时结论不成立。

    仍需事实：长文本实验。
    """

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

        // MARK: 版本目录与默认对比

        let session = makeSession()
        let history = ArenaCandidateHistory(session: session)
        check("saved usable versions are listed in order", history.versions == [1, 2])
        check("two versions offer a comparison", history.hasMultipleVersions)
        check("default comparison is previous vs latest",
              history.defaultComparison()?.older == 1 && history.defaultComparison()?.newer == 2)

        // MARK: 共享引擎决定候选与可计入表态

        let v1Ballot = ballot(
            candidate: "p1", version: 1,
            votes: [
                ("r1-vote-gemini", "gemini", "oppose"),
                ("r1-vote-chatgpt", "chatgpt", "conditional"),
                ("r1-vote-deepseek", "deepseek", "agree"),
            ]
        )
        let v1Snapshot = history.snapshot(version: 1, ballot: v1Ballot)
        check("the canonical candidate comes from candidateID",
              v1Snapshot.candidate?.taskID == "p1" && v1Snapshot.candidate?.sourceID == "S5")
        check("accepted votes map to the real saved rows",
              v1Snapshot.votes.allSatisfy { $0.sourceID.hasPrefix("S") && !$0.answer.isEmpty })
        check("v1 keeps an explicit opposition",
              v1Snapshot.votes.contains { $0.provider == "gemini" && $0.stance == "oppose" })
        check("v1 keeps the qualified acceptance as a concern",
              v1Snapshot.concerns.contains { $0.provider == "chatgpt" && $0.stance == "conditional" })
        check("v1 coverage is complete", v1Snapshot.coverage == .complete)

        let v2Ballot = ballot(
            candidate: "p2", version: 2,
            votes: [
                ("r2-vote-chatgpt", "chatgpt", "conditional"),
                ("r2-vote-gemini", "gemini", "agree"),
            ]
        )
        let v2Snapshot = history.snapshot(version: 2, ballot: v2Ballot)
        check("a later same-version proposal is not selected by scanning history",
              v2Snapshot.candidate?.text == v2
                  && v2Snapshot.candidate?.text != "被摘要排除的同一版本改写")
        check("the candidate row is the saved one named by the bridge",
              v2Snapshot.candidate?.sourceID == "S9")
        check("votes carry the saved source text",
              v2Snapshot.votes.contains { $0.sourceID == "S10" && $0.answer.contains("[S7]") })
        check("v2 keeps the qualified acceptance",
              v2Snapshot.votes.contains { $0.provider == "chatgpt" && $0.stance == "conditional" })
        check("a skipped seat is missing, not agreement",
              v2Snapshot.gaps.contains { $0.provider == "deepseek" && $0.reason == .skipped }
                  && !v2Snapshot.votes.contains { $0.provider == "deepseek" })
        check("v2 coverage stays partial with a missing seat",
              v2Snapshot.coverage == .partial)
        check("the changed passage cites the prior statement explicitly",
              ArenaParagraphCitations.inText(v2Snapshot.candidate?.text ?? "").contains("S7"))
        check("that citation names a saved prior concern",
              v1Snapshot.concerns.contains { $0.sourceID == "S7" })

        // The shared engine omits a vote bound to another text. That reject is
        // proven in tests/core.test.mjs; this reader only reports the seat as
        // missing and never re-checks the digest.
        let wrongDigestBallot = ballot(
            candidate: "p2", version: 2,
            votes: [("r2-vote-chatgpt", "chatgpt", "conditional")]
        )
        let wrongDigest = history.snapshot(version: 2, ballot: wrongDigestBallot)
        check("a vote omitted by the shared engine stays missing",
              wrongDigest.gaps.contains { $0.provider == "gemini" && $0.reason == .notVerified })
        check("the omitted vote never counts as agreement",
              !wrongDigest.votes.contains { $0.provider == "gemini" })
        check("the version with an omitted vote is partial",
              wrongDigest.coverage == .partial)

        let ghost = ballot(
            candidate: "p2", version: 2,
            votes: [
                ("r2-vote-chatgpt", "chatgpt", "conditional"),
                ("r2-vote-ghost", "deepseek", "agree"),
            ]
        )
        let ghostSnapshot = history.snapshot(version: 2, ballot: ghost)
        check("an accepted id without a saved row is not displayed",
              !ghostSnapshot.votes.contains { $0.taskID == "r2-vote-ghost" })
        check("the seat without a saved row stays missing",
              ghostSnapshot.gaps.contains { $0.provider == "deepseek" })

        // MARK: 缺失候选时不显示表态

        let missingCandidate = history.snapshot(
            version: 2,
            ballot: ballot(candidate: "p99", version: 2, votes: [("r2-vote-chatgpt", "chatgpt", "conditional")])
        )
        check("a missing bridge candidate never displays votes",
              missingCandidate.candidate == nil && missingCandidate.votes.isEmpty)
        check("a missing bridge candidate reports no coverage",
              missingCandidate.coverage == .noneRecorded)
        let noBallot = history.snapshot(version: 2, ballot: nil)
        check("a missing bridge result never displays votes",
              noBallot.candidate == nil && noBallot.votes.isEmpty)
        let bumpedVersion = history.snapshot(
            version: 2,
            ballot: ballot(candidate: "p2", version: 3, votes: [("r2-vote-chatgpt", "chatgpt", "conditional")])
        )
        check("a ballot for another version is not applied",
              bumpedVersion.candidate == nil && bumpedVersion.votes.isEmpty)

        // MARK: 单版、旧记录与空场次

        let single = ArenaCandidateHistory(session: makeSession(includeV2: false))
        check("a single saved candidate has no comparison",
              single.versions == [1] && !single.hasMultipleVersions && single.defaultComparison() == nil)
        check("a single candidate still reports its own ballot",
              single.snapshot(version: 1, ballot: v1Ballot).coverage == .complete)

        let old = ArenaCandidateHistory(session: [
            "providers": ["chatgpt"],
            "history": [
                row(id: "p1", stage: "proposal", provider: "chatgpt", source: "S1",
                    answer: "旧候选", version: nil),
                row(id: "v1", stage: "vote", provider: "chatgpt", source: "S2",
                    answer: "同意", version: 1),
            ],
        ])
        check("an old proposal without a version is not a usable version",
              old.versions.isEmpty && !old.hasMultipleVersions)
        check("no version means no comparison default", old.defaultComparison() == nil)

        let empty = ArenaCandidateHistory(session: nil)
        check("an empty session has no versions", empty.versions.isEmpty)
        check("an empty session has no recorded votes",
              empty.snapshot(version: 1, ballot: nil).coverage == .noneRecorded)
        let emptyDiff = ArenaParagraphDiff.compare(old: "", new: "")
        check("an empty comparison produces no rows", emptyDiff.rows.isEmpty)

        // MARK: 段落级变化

        let diff = ArenaParagraphDiff.compare(old: v1, new: v2)
        let changed = diff.rows.filter { $0.kind == .changed }
        check("changed paragraphs are identified locally", changed.count == 2)
        check("unchanged context is retained",
              diff.rows.contains { $0.kind == .unchanged && $0.newText == "候选结论" })
        check("a changed paragraph exposes its candidate citation",
              changed.contains { ($0.newText ?? "").contains("可计算压缩器")
                  && $0.newCitations == ["S7"] })
        check("a changed paragraph without a citation claims none",
              changed.contains { ($0.newText ?? "").contains("超出范围") && $0.newCitations.isEmpty })
        check("the added citation is not attributed to the old text",
              diff.rows.allSatisfy { !$0.oldCitations.contains("S7") })
        check("citation extraction is ordered and deduplicated",
              ArenaParagraphCitations.inText("[S7, S7] 与 [S8]") == ["S7", "S8"])

        // MARK: 长文边界

        let paragraphs = (1...1200).map { "第 \($0) 段：压缩即智能。" }
        let longOld = paragraphs.joined(separator: "\n\n")
        var modified = paragraphs
        modified[700] = "第 701 段：这一段被修改，并引用 [S7]。"
        let longNew = modified.joined(separator: "\n\n")
        let started = Date()
        let longDiff = ArenaParagraphDiff.compare(old: longOld, new: longNew)
        let elapsed = Date().timeIntervalSince(started)
        check("a long candidate is compared with bounded rows", longDiff.rows.count <= 240)
        check("a long candidate reports its truncation", longDiff.truncated)
        check("a long candidate does not stall the reader", elapsed < 2)

        let hugeText = String(repeating: "长", count: 300_000)
        let huge = ArenaParagraphDiff.compare(old: hugeText, new: hugeText + "改动")
        check("a single huge paragraph is bounded and marked truncated",
              huge.truncated && huge.rows.count <= 240)

        if failures == 0 {
            print("native candidate comparison: all checks passed")
            exit(0)
        }
        print("native candidate comparison: \(failures) check(s) failed")
        exit(1)
    }

    // MARK: Fixture

    /// Bridge-shaped ballot: canonical candidateID, version and accepted vote
    /// ids. This is exactly what `__arenaReportBallot` returns.
    static func ballot(
        candidate: String,
        version: Int,
        votes: [(String, String, String)]
    ) -> [String: Any] {
        [
            "candidateID": candidate,
            "version": version,
            "votes": votes.map { ["id": $0.0, "provider": $0.1, "stance": $0.2] },
        ]
    }

    static func makeSession(includeV2: Bool = true) -> [String: Any] {
        var history: [[String: Any]] = [
            row(id: "p1", stage: "proposal", provider: "chatgpt", source: "S5", answer: v1,
                version: 1),
            row(id: "r1-vote-gemini", stage: "vote", provider: "gemini", source: "S6",
                answer: "反对：缺少真实压缩实验。", version: 1, stance: "oppose"),
            row(id: "r1-vote-chatgpt", stage: "vote", provider: "chatgpt", source: "S7",
                answer: "有条件同意：仅在无损压缩范围。", version: 1, stance: "conditional"),
            row(id: "r1-vote-deepseek", stage: "vote", provider: "deepseek", source: "S8",
                answer: "同意。", version: 1, stance: "agree"),
        ]
        if includeV2 {
            history += [
                row(id: "p2", stage: "proposal", provider: "gemini", source: "S9", answer: v2,
                    version: 2),
                row(id: "p2-edit", stage: "proposal", provider: "gemini", source: "S13",
                    answer: "被摘要排除的同一版本改写", version: 2, round: 3),
                row(id: "r2-vote-chatgpt", stage: "vote", provider: "chatgpt", source: "S10",
                    answer: "有条件同意：请保留 [S7] 的条件。", version: 2, stance: "conditional"),
                row(id: "r2-vote-gemini", stage: "vote", provider: "gemini", source: "S11",
                    answer: "同意。", version: 2, stance: "agree"),
                row(id: "r2-vote-deepseek", stage: "vote", provider: "deepseek", source: "S12",
                    answer: "", version: 2, status: "skipped"),
            ]
        }
        return ["providers": ["chatgpt", "gemini", "deepseek"], "history": history]
    }

    static func row(
        id: String,
        stage: String,
        provider: String,
        source: String,
        answer: String,
        version: Int?,
        round: Int = 1,
        stance: String? = nil,
        status: String = "answered"
    ) -> [String: Any] {
        var row: [String: Any] = [
            "id": id,
            "stage": stage,
            "provider": provider,
            "sourceId": source,
            "answer": answer,
            "round": round,
            "status": status,
        ]
        if let version { row["version"] = version }
        if let stance { row["stance"] = stance }
        return row
    }
}
