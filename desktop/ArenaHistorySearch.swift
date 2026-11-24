//
//  ArenaHistorySearch.swift
//  AI Arena · 本机历史检索与指定版本表态投影（G2/G3/G4，R05/R07）
//
//  历史只来自 `ArenaSessionStore.summaries()` 已保存的场次文件：题面、
//  时间、阶段、停止原因、席位和暂停标记。检索在当前进程内对这批摘要做
//  过滤，不扫描网络、不建立索引、也不修改任何场次。打开一条结果仍走
//  `ArenaModel.openHistory` 的只读路径（运行中先确认），与历史菜单一致。
//
//  同一文件还提供按候选版本裁剪的“材料-only”投影，供报告阅读器向共享
//  引擎查询指定版本的候选与严格核对过的表态；投影与 `ArenaModel.reportBallot()`
//  原有的键集合完全一致。
//

import Foundation

// MARK: - Outcome

/// One saved session's outcome, derived only from the persisted summary.
enum ArenaHistoryOutcome {
    static func key(for item: ArenaHistorySummary) -> String {
        guard item.isFinished else {
            return item.paused ? "unfinished-paused" : "unfinished"
        }
        // A batch refresh/save stamped the strict ballot result once. Search and
        // menu filters read that stamp instead of recomputing per keystroke.
        if let key = item.conservativeOutcomeKey { return key }
        switch item.stopReason {
        case "consensus": return "consensus"
        case "conditional-agreement": return "conditional-agreement"
        case "unresolved-opposition": return "unresolved-opposition"
        case "partial-votes": return "partial-votes"
        case "partial-participation": return "partial-participation"
        case "no-cross-review": return "no-cross-review"
        case "no-critique": return "no-critique"
        case "proposal-skipped": return "proposal-skipped"
        case "draft": return "draft"
        case "user-finished": return "user-finished"
        case "no-answers": return "no-answers"
        default: return "finished"
        }
    }

    /// The one Chinese short-term table for a saved outcome. The history menu,
    /// search sheet, report reader and Markdown export all read these strings,
    /// so the same session is never described with two different words.
    static let labels: [String: String] = [
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

    /// Older wording that described the same saved outcome before the terms
    /// were unified. Search keeps these as aliases, so a familiar phrase such
    /// as 「仍有反对」 or a former report phrase still finds the session.
    static let alternateLabels: [String: [String]] = [
        "conditional-agreement": ["有条件同意"],
        "unresolved-opposition": ["存在分歧"],
        "partial-votes": ["表态记录不完整"],
        "partial-participation": ["部分席位参与"],
        "no-cross-review": ["互评未完成"],
        "no-critique": ["尚无最终候选"],
        "proposal-skipped": ["尚无最终候选"],
        "no-answers": ["尚无回答"],
        "finished": ["讨论已结束"],
        "incomplete-votes": ["部分表态"],
    ]

    /// Conservative presentation derived once from a saved ballot. It only
    /// labels the saved code honestly; the raw stopReason and JSON stay intact.
    struct Stamp: Equatable {
        let key: String
        let label: String
    }

    /// The wording used by the existing History menu, search sheet, report
    /// reader and export. An unknown saved code is never rewritten: it keeps
    /// its raw value in the session JSON and only falls back here.
    static func label(for item: ArenaHistorySummary) -> String {
        guard item.isFinished else {
            return item.paused ? "未完成 · 已暂停" : "未完成 · 可继续"
        }
        if let label = item.conservativeOutcomeLabel { return label }
        return label(stopReason: item.stopReason)
    }

    /// Chinese label for a persisted stop reason. Unknown codes stay in the
    /// original data and read as a generic finished state here.
    static func label(stopReason: String?) -> String {
        guard let stopReason else { return "已结束" }
        return labels[stopReason] ?? "已结束"
    }

    /// The report reader's label. `verifiedConsensus` is decided by the reader
    /// from the saved candidate plus every participant's same-version `agree`
    /// vote; a missing vote or candidate degrades instead of claiming 全体一致.
    /// A conditional stop without any recorded conditional stance also degrades.
    static func reportLabel(
        stopReason: String?,
        verifiedConsensus: Bool,
        hasConditionalVote: Bool
    ) -> String {
        let raw = stopReason ?? ""
        if verifiedConsensus { return label(stopReason: "consensus") }
        if raw == "consensus" { return "表态记录不完整" }
        if raw == "conditional-agreement", !hasConditionalVote {
            return "表态记录不完整"
        }
        return label(stopReason: stopReason)
    }

    /// Alternate search wording for this session's saved outcome.
    static func searchTerms(for item: ArenaHistorySummary) -> [String] {
        alternateLabels[key(for: item)] ?? []
    }

    /// Strict consensus from the existing report ballot. A `consensus` code
    /// alone never proves agreement: the ballot must name an answered candidate
    /// version and every participant must have a saved same-version `agree`
    /// vote for it. Missing, older or mismatched votes degrade instead.
    static func verifiedConsensus(
        stopReason: String?,
        ballot: [String: Any]?,
        participants: [String]
    ) -> Bool {
        guard stopReason == "consensus", let ballot else { return false }
        let version = ballot.arenaInt("version") ?? 0
        guard version > 0,
              let candidateID = ballot["candidateID"] as? String,
              !candidateID.isEmpty,
              !participants.isEmpty else {
            return false
        }
        let votes = ballot["votes"] as? [[String: Any]] ?? []
        return participants.allSatisfy { provider in
            votes.contains { vote in
                (vote["provider"] as? String) == provider
                    && (vote["stance"] as? String) == "agree"
                    && sameVersion(vote, version)
            }
        }
    }

    /// A recorded conditional stance for the ballot's candidate version.
    static func hasConditionalVote(ballot: [String: Any]?) -> Bool {
        guard let ballot else { return false }
        let version = ballot.arenaInt("version") ?? 0
        let votes = ballot["votes"] as? [[String: Any]] ?? []
        return votes.contains { vote in
            (vote["stance"] as? String) == "conditional" && sameVersion(vote, version)
        }
    }

    /// The engine bridge already scopes votes to the candidate version and may
    /// omit a vote's version field. When it is present, it must match.
    private static func sameVersion(_ vote: [String: Any], _ version: Int) -> Bool {
        guard let voteVersion = vote.arenaInt("version") else { return true }
        return version > 0 && voteVersion == version
    }

    /// One conservative label for the report, completion banner and Markdown
    /// export. The raw stop code stays untouched in the saved JSON; only this
    /// presentation degrades when the ballot cannot prove the claim.
    static func conservativeLabel(
        stopReason: String?,
        ballot: [String: Any]?,
        participants: [String]
    ) -> String {
        reportLabel(
            stopReason: stopReason,
            verifiedConsensus: verifiedConsensus(
                stopReason: stopReason, ballot: ballot, participants: participants
            ),
            hasConditionalVote: hasConditionalVote(ballot: ballot)
        )
    }

    /// Stamp a finished summary once from its saved ballot. Only the two claims
    /// that need proof are stamped: 全体一致 and 有条件一致. Everything else
    /// keeps the raw-code label. A shell or ballot-less record degrades instead
    /// of claiming agreement, and the raw code is never replaced.
    static func stamp(
        stopReason: String?,
        ballot: [String: Any]?,
        participants: [String]
    ) -> Stamp? {
        switch stopReason {
        case "consensus":
            return verifiedConsensus(
                stopReason: stopReason, ballot: ballot, participants: participants
            )
                ? Stamp(key: "consensus", label: label(stopReason: "consensus"))
                : Stamp(key: "incomplete-votes", label: "表态记录不完整")
        case "conditional-agreement":
            return hasConditionalVote(ballot: ballot)
                ? Stamp(key: "conditional-agreement", label: label(stopReason: "conditional-agreement"))
                : Stamp(key: "incomplete-votes", label: "表态记录不完整")
        default:
            return nil
        }
    }

    /// Compact filter label; unfinished rows carry their own two states.
    static func filterLabel(for item: ArenaHistorySummary) -> String {
        if !item.isFinished {
            return item.paused ? "未完成 · 已暂停" : "未完成"
        }
        return label(for: item)
    }
}

/// Where an opened saved session should land. A read-only session with a saved
/// report renders that report inside the workbench, so no second window is
/// opened. Everything else uses the independent details window: the saved
/// answers, or the report when one exists.
enum ArenaHistoryOpenTarget: Equatable {
    case inlineReport
    case savedAnswers
    case report

    static func decide(readOnly: Bool, hasReport: Bool) -> ArenaHistoryOpenTarget {
        if readOnly, hasReport { return .inlineReport }
        return hasReport ? .report : .savedAnswers
    }
}

// MARK: - Criteria

enum ArenaHistoryStateFilter: String, CaseIterable, Identifiable {
    case all
    case finished
    case unfinished
    case paused

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部状态"
        case .finished: return "已结束"
        case .unfinished: return "未完成"
        case .paused: return "未完成 · 已暂停"
        }
    }
}

/// A selectable filter value read from the saved summaries themselves.
struct ArenaHistoryFacet: Identifiable, Equatable {
    let key: String
    let label: String

    var id: String { key }
}

struct ArenaHistorySearchCriteria: Equatable {
    var query: String = ""
    var state: ArenaHistoryStateFilter = .all
    var outcome: String?
    var seat: String?

    var isDefault: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state == .all && outcome == nil && seat == nil
    }
}

// MARK: - Keyboard selection

enum ArenaHistoryMove {
    case up
    case down
}

/// The one selected row in the search sheet. Kept pure so the rules the user
/// relies on stay checkable without a window:
///
/// * the selection is always one of the currently visible results;
/// * changing the query or a filter starts at the first visible row, never at
///   a row that just disappeared; an empty result set selects none;
/// * a saved-history refresh keeps the selection when it is still visible and
///   otherwise falls back to the first row;
/// * without a selection, Down picks the first row and Up the last;
/// * moving stops at either end instead of wrapping.
struct ArenaHistorySelection: Equatable {
    private(set) var id: String?

    init(id: String? = nil) {
        self.id = id
    }

    /// Keep the selection visible after the saved history itself changed.
    /// Returns `true` when the selection had to move.
    @discardableResult
    mutating func reconcile(with visibleIDs: [String]) -> Bool {
        if let id, visibleIDs.contains(id) { return false }
        let next = visibleIDs.first
        guard next != id else { return false }
        id = next
        return true
    }

    /// A query or filter change starts again at the first visible row, even if
    /// the previous selection happens to survive the new result set.
    @discardableResult
    mutating func selectFirst(in visibleIDs: [String]) -> Bool {
        let next = visibleIDs.first
        guard next != id else { return false }
        id = next
        return true
    }

    /// Move one row. The result is always a visible row, or `nil` when there
    /// is nothing to select.
    @discardableResult
    mutating func move(_ direction: ArenaHistoryMove, in visibleIDs: [String]) -> Bool {
        guard !visibleIDs.isEmpty else {
            guard id != nil else { return false }
            id = nil
            return true
        }
        let next: String
        if let current = id, let index = visibleIDs.firstIndex(of: current) {
            switch direction {
            case .up: next = visibleIDs[max(index - 1, 0)]
            case .down: next = visibleIDs[min(index + 1, visibleIDs.count - 1)]
            }
        } else {
            next = direction == .down ? visibleIDs[0] : visibleIDs[visibleIDs.count - 1]
        }
        guard next != id else { return false }
        id = next
        return true
    }
}

extension Notification.Name {
    /// Posted by the View menu command so the already-mounted workbench opens
    /// the same history panel as the header button. One window, one sheet.
    static let arenaOpenHistorySearch = Notification.Name("ArenaOpenHistorySearch")
}

enum ArenaHistorySearch {
    /// Filter local summaries. `seatName` lets the caller resolve a provider id
    /// to its display name without this file depending on UI metadata.
    static func filter(
        _ items: [ArenaHistorySummary],
        criteria: ArenaHistorySearchCriteria,
        seatName: (String) -> String = { $0 }
    ) -> [ArenaHistorySummary] {
        let query = normalize(criteria.query)
        return items.filter { item in
            switch criteria.state {
            case .all:
                break
            case .finished:
                guard item.isFinished else { return false }
            case .unfinished:
                guard !item.isFinished else { return false }
            case .paused:
                guard !item.isFinished, item.paused else { return false }
            }
            if let outcome = criteria.outcome,
               ArenaHistoryOutcome.key(for: item) != outcome {
                return false
            }
            if let seat = criteria.seat, !item.providers.contains(seat) {
                return false
            }
            guard !query.isEmpty else { return true }
            // Question, seat and outcome are all searchable; everything is
            // local summary text, never a re-read of prompts or answers.
            if normalize(item.question).contains(query) { return true }
            if normalize(ArenaHistoryOutcome.label(for: item)).contains(query) { return true }
            if ArenaHistoryOutcome.searchTerms(for: item).contains(where: {
                normalize($0).contains(query)
            }) {
                return true
            }
            if item.providers.contains(where: {
                normalize($0).contains(query) || normalize(seatName($0)).contains(query)
            }) {
                return true
            }
            return false
        }
    }

    /// Outcome choices actually present in this machine's history.
    static func outcomeFacets(_ items: [ArenaHistorySummary]) -> [ArenaHistoryFacet] {
        var seen = Set<String>()
        var facets: [ArenaHistoryFacet] = []
        for item in items {
            let key = ArenaHistoryOutcome.key(for: item)
            guard seen.insert(key).inserted else { continue }
            facets.append(
                ArenaHistoryFacet(key: key, label: ArenaHistoryOutcome.filterLabel(for: item))
            )
        }
        return facets
    }

    /// Seat choices actually present in this machine's history.
    static func seatFacets(
        _ items: [ArenaHistorySummary],
        seatName: (String) -> String = { $0 }
    ) -> [ArenaHistoryFacet] {
        var seen = Set<String>()
        var facets: [ArenaHistoryFacet] = []
        for item in items {
            for provider in item.providers where seen.insert(provider).inserted {
                facets.append(ArenaHistoryFacet(key: provider, label: seatName(provider)))
            }
        }
        return facets
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN"))
    }
}

// MARK: - Versioned ballot projection

/// Material-only projection of saved rounds. The report reader and the export
/// ask the shared engine for exactly one candidate version; prompts and other
/// bulky fields never cross into JavaScript.
enum ArenaBallotProjection {
    /// Kept in sync with `ArenaModel.reportBallot()`.
    static let materialKeys: Set<String> = [
        "id", "provider", "stage", "status", "version", "round", "proposalDigest", "stance"
    ]

    /// `version == nil` keeps every proposal/vote row (the existing
    /// `reportBallot()` path). A version keeps only that candidate and the
    /// votes issued for it, so the engine's digest check still decides which
    /// votes are strictly verified for that exact text.
    static func materials(history: [[String: Any]], version: Int? = nil) -> [[String: Any]] {
        history.compactMap { row -> [String: Any]? in
            let stage = row["stage"] as? String
            guard stage == "proposal" || stage == "vote" else { return nil }
            if let version, row.arenaInt("version") != version { return nil }
            return row.filter {
                materialKeys.contains($0.key) || (stage == "proposal" && $0.key == "answer")
            }
        }
    }

    /// `true` when the saved history actually contains that candidate version
    /// (an answered proposal with text), mirroring `latestAnsweredProposal`.
    /// A skipped proposal never becomes a ballot target.
    static func containsProposal(version: Int, in history: [[String: Any]]) -> Bool {
        guard version > 0 else { return false }
        return history.contains { row in
            guard row["stage"] as? String == "proposal",
                  row.arenaInt("version") == version,
                  row["status"] as? String == "answered",
                  let answer = row["answer"] as? String,
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            return true
        }
    }
}
