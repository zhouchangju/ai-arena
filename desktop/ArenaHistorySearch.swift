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

    /// The wording used by the existing History menu. Kept identical so the
    /// menu and the search sheet never describe the same session differently.
    static func label(for item: ArenaHistorySummary) -> String {
        guard item.isFinished else {
            return item.paused ? "未完成 · 已暂停" : "未完成 · 可继续"
        }
        switch item.stopReason {
        case "consensus": return "全体一致"
        case "conditional-agreement": return "有条件一致"
        case "unresolved-opposition": return "仍有反对"
        case "partial-votes": return "部分表态"
        case "partial-participation": return "参与不足"
        case "no-cross-review": return "互评缺失"
        case "no-critique": return "缺少互评材料"
        case "proposal-skipped": return "未形成候选"
        case "draft": return "候选草稿"
        case "user-finished": return "提前结束"
        case "no-answers": return "无有效回答"
        default: return "已结束"
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
