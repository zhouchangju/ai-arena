import Foundation

// MARK: - 席位表态

enum ArenaCandidateStance {
    static let declared: Set<String> = ["agree", "conditional", "oppose"]

    static func label(_ raw: String?) -> String {
        switch raw {
        case "agree": return "同意"
        case "conditional": return "有条件同意"
        case "oppose": return "反对"
        default: return "未核实表态"
        }
    }

    static func isConcern(_ raw: String?) -> Bool {
        raw == "oppose" || raw == "conditional"
    }
}

struct ArenaCandidateVote: Identifiable, Equatable {
    let taskID: String
    let provider: String
    let sourceID: String
    let stance: String
    let answer: String
    let version: Int

    var id: String { taskID }
}

enum ArenaCandidateGapReason: Equatable {
    case notRecorded
    case unanswered
    case skipped
    case emptyAnswer
    case notVerified

    var label: String {
        switch self {
        case .notRecorded: return "未记录表态"
        case .unanswered: return "表态任务未回答"
        case .skipped: return "已跳过，计为缺席"
        case .emptyAnswer: return "表态原文为空"
        case .notVerified: return "未被同版核验计入"
        }
    }
}

/// A seat without an accepted vote. `taskID` and `sourceID` point at the real
/// saved row when one exists; the reason is derived from that row only.
struct ArenaCandidateVoteGap: Identifiable, Equatable {
    let provider: String
    let reason: ArenaCandidateGapReason
    let taskID: String?
    let sourceID: String?

    var id: String { provider }
}

enum ArenaCandidateVoteCoverage: Equatable {
    case noneRecorded
    case partial
    case complete

    func label(verified: Int, expected: Int) -> String {
        switch self {
        case .noneRecorded: return "无同版表态记录"
        case .partial: return "部分表态 · \(verified)/\(expected) 席可核对"
        case .complete: return "全部 \(expected) 席可核对"
        }
    }
}

// MARK: - 候选版本与同版表态

/// One canonical candidate: the task named by the shared engine's
/// `candidateID`, with text read from the real saved row. The reader never
/// selects a candidate by scanning proposals itself.
struct ArenaCandidateVersion: Identifiable, Equatable {
    let version: Int
    let taskID: String
    let text: String
    let sourceID: String

    var id: Int { version }
    var title: String { "v\(version)" }
}

struct ArenaCandidateSnapshot: Equatable {
    let version: Int
    let candidate: ArenaCandidateVersion?
    let votes: [ArenaCandidateVote]
    let gaps: [ArenaCandidateVoteGap]
    let participants: [String]
    let recordedCount: Int

    var coverage: ArenaCandidateVoteCoverage {
        if recordedCount == 0 { return .noneRecorded }
        let expected = participants.isEmpty
            ? Array(Set(votes.map(\.provider))).sorted()
            : participants
        if expected.isEmpty { return .partial }
        let verified = Set(votes.map(\.provider))
        return expected.allSatisfy(verified.contains) ? .complete : .partial
    }

    var coverageLabel: String {
        let expected = participants.isEmpty
            ? Array(Set(votes.map(\.provider))).sorted()
            : participants
        let verified = Set(votes.map(\.provider))
        return coverage.label(
            verified: expected.filter(verified.contains).count,
            expected: expected.count
        )
    }

    var concerns: [ArenaCandidateVote] {
        votes.filter { ArenaCandidateStance.isConcern($0.stance) }
    }

    static func empty(version: Int, participants: [String] = []) -> ArenaCandidateSnapshot {
        ArenaCandidateSnapshot(
            version: version,
            candidate: nil,
            votes: [],
            gaps: [],
            participants: participants,
            recordedCount: 0
        )
    }
}

/// Reads only what the reader may derive locally: which saved version numbers
/// exist, the saved rows behind an accepted vote, and why a seat has no
/// accepted vote. Accepted votes and their candidate come from the bridge.
struct ArenaCandidateHistory {
    let versions: [Int]
    let participants: [String]

    private let tasks: [ArenaCandidateTask]

    init(session: [String: Any]?) {
        self.tasks = ArenaCandidateTask.parse(session: session)
        self.participants = (session?["providers"] as? [String]) ?? []

        var versions: [Int] = []
        for task in tasks
        where task.stage == "proposal" && task.isUsableAnswer {
            guard let version = task.version, version > 0 else { continue }
            if !versions.contains(version) { versions.append(version) }
        }
        self.versions = versions.sorted()
    }

    var hasMultipleVersions: Bool { versions.count >= 2 }

    func defaultComparison() -> (older: Int, newer: Int)? {
        guard versions.count >= 2, let newer = versions.last else { return nil }
        return (versions[versions.count - 2], newer)
    }

    /// `ballot` is the exact bridge result for this version. If it names no
    /// candidate, or that candidate is not a real saved proposal row, the
    /// snapshot carries no candidate and no votes at all.
    func snapshot(version: Int, ballot: [String: Any]?) -> ArenaCandidateSnapshot {
        guard let ballot,
              ArenaCandidateValue.int(ballot["version"]) == version,
              let candidateID = ArenaCandidateValue.string(ballot["candidateID"]),
              let proposal = tasks.first(where: {
                  $0.id == candidateID && $0.stage == "proposal" && $0.isUsableAnswer
              }),
              proposal.version == version else {
            return .empty(version: version, participants: participants)
        }

        let candidate = ArenaCandidateVersion(
            version: version,
            taskID: proposal.id,
            text: proposal.answer,
            sourceID: proposal.sourceID
        )

        // Bridge votes carry only id/provider/stance. Text, seat source and
        // round come from the matching saved vote row; an id with no saved row
        // is not displayed.
        var order: [String] = []
        var byProvider: [String: ArenaCandidateVote] = [:]
        for raw in (ballot["votes"] as? [[String: Any]] ?? []) {
            guard let taskID = ArenaCandidateValue.string(raw["id"]),
                  let stance = ArenaCandidateValue.string(raw["stance"]),
                  ArenaCandidateStance.declared.contains(stance),
                  let saved = tasks.first(where: {
                      $0.id == taskID && $0.stage == "vote" && $0.isUsableAnswer
                  }) else { continue }
            if byProvider[saved.provider] == nil { order.append(saved.provider) }
            byProvider[saved.provider] = ArenaCandidateVote(
                taskID: taskID,
                provider: saved.provider,
                sourceID: saved.sourceID,
                stance: stance,
                answer: saved.answer,
                version: version
            )
        }
        let votes = order.compactMap { byProvider[$0] }

        let records = tasks.filter { $0.stage == "vote" && $0.version == version }
        let verified = Set(votes.map(\.provider))
        var seats = participants
        for record in records where !seats.contains(record.provider) {
            seats.append(record.provider)
        }
        let gaps = seats.filter { !verified.contains($0) }.map { provider -> ArenaCandidateVoteGap in
            guard let last = records.last(where: { $0.provider == provider }) else {
                return ArenaCandidateVoteGap(
                    provider: provider,
                    reason: .notRecorded,
                    taskID: nil,
                    sourceID: nil
                )
            }
            return ArenaCandidateVoteGap(
                provider: provider,
                reason: Self.gapReason(for: last),
                taskID: last.id,
                sourceID: last.sourceID
            )
        }

        return ArenaCandidateSnapshot(
            version: version,
            candidate: candidate,
            votes: votes,
            gaps: gaps,
            participants: participants,
            recordedCount: records.count
        )
    }

    /// Saved-row status only. Digest and stance acceptance already happened in
    /// the shared engine, so a readable row that the bridge did not accept is
    /// reported as not verified rather than re-judged here.
    private static func gapReason(for task: ArenaCandidateTask) -> ArenaCandidateGapReason {
        if task.status == "skipped" { return .skipped }
        guard task.status == "answered" else { return .unanswered }
        if task.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyAnswer
        }
        return .notVerified
    }
}

private struct ArenaCandidateTask {
    let id: String
    let provider: String
    let stage: String
    let version: Int?
    let status: String
    let sourceID: String
    let answer: String

    var isUsableAnswer: Bool {
        status == "answered" && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func parse(session: [String: Any]?) -> [ArenaCandidateTask] {
        (session?["history"] as? [[String: Any]] ?? []).compactMap { row in
            guard let provider = ArenaCandidateValue.string(row["provider"]),
                  !provider.isEmpty else { return nil }
            return ArenaCandidateTask(
                id: ArenaCandidateValue.string(row["id"]) ?? "",
                provider: provider,
                stage: ArenaCandidateValue.string(row["stage"]) ?? "",
                version: ArenaCandidateValue.int(row["version"]),
                status: ArenaCandidateValue.string(row["status"]) ?? "",
                sourceID: ArenaCandidateValue.string(row["sourceId"]) ?? "",
                answer: ArenaCandidateValue.string(row["answer"]) ?? ""
            )
        }
    }
}

// MARK: - 段落变化

enum ArenaParagraphChangeKind: Equatable {
    case unchanged
    case changed
    case added
    case removed
    case gap
}

struct ArenaParagraphChange: Identifiable, Equatable {
    let id: Int
    let kind: ArenaParagraphChangeKind
    let oldText: String?
    let newText: String?
    let gapCount: Int

    var newCitations: [String] { ArenaParagraphCitations.inText(newText ?? "") }
    var oldCitations: [String] { ArenaParagraphCitations.inText(oldText ?? "") }
}

enum ArenaParagraphCitations {
    private static let group = try! NSRegularExpression(pattern: #"\[([^\]]+)\]"#)
    private static let identifier = try! NSRegularExpression(pattern: #"S\d+"#)

    static func inText(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for bracket in group.matches(in: text, range: range) {
            guard let content = Range(bracket.range(at: 1), in: text) else { continue }
            let inner = String(text[content])
            let innerRange = NSRange(inner.startIndex..., in: inner)
            for match in identifier.matches(in: inner, range: innerRange) {
                guard let matchRange = Range(match.range, in: inner) else { continue }
                let value = String(inner[matchRange])
                if !result.contains(value) { result.append(value) }
            }
        }
        return result
    }
}

enum ArenaParagraphDiff {
    struct Result {
        let rows: [ArenaParagraphChange]
        let truncated: Bool
    }

    private static let maxParagraphs = 400
    private static let maxCharacters = 160_000
    private static let maxCells = 40_000
    private static let maxRows = 240

    private struct Step {
        let kind: ArenaParagraphChangeKind
        let old: Int?
        let new: Int?
    }

    static func compare(old: String, new: String) -> Result {
        let oldSplit = split(old)
        let newSplit = split(new)
        let oldItems = oldSplit.items
        let newItems = newSplit.items

        var steps: [Step] = []
        var start = 0
        while start < oldItems.count, start < newItems.count,
              oldItems[start] == newItems[start] {
            steps.append(Step(kind: .unchanged, old: start, new: start))
            start += 1
        }
        var oldEnd = oldItems.count
        var newEnd = newItems.count
        while oldEnd > start, newEnd > start,
              oldItems[oldEnd - 1] == newItems[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        steps += middle(
            Array(oldItems[start..<oldEnd]),
            Array(newItems[start..<newEnd]),
            offset: start
        )
        while oldEnd < oldItems.count, newEnd < newItems.count {
            steps.append(Step(kind: .unchanged, old: oldEnd, new: newEnd))
            oldEnd += 1
            newEnd += 1
        }

        var rows: [ArenaParagraphChange] = []
        var cursor = 0
        while cursor < steps.count {
            if steps[cursor].kind == .unchanged {
                var run: [Step] = []
                while cursor < steps.count, steps[cursor].kind == .unchanged {
                    run.append(steps[cursor])
                    cursor += 1
                }
                appendUnchanged(run, oldItems: oldItems, newItems: newItems, rows: &rows)
            } else {
                var removed: [Int] = []
                var added: [Int] = []
                while cursor < steps.count, steps[cursor].kind != .unchanged {
                    if let oldIndex = steps[cursor].old { removed.append(oldIndex) }
                    if let newIndex = steps[cursor].new { added.append(newIndex) }
                    cursor += 1
                }
                appendChanged(
                    removed,
                    added,
                    oldItems: oldItems,
                    newItems: newItems,
                    rows: &rows
                )
            }
        }

        let truncated = oldSplit.truncated || newSplit.truncated || rows.count > maxRows
        return Result(rows: rows.count > maxRows ? Array(rows.prefix(maxRows)) : rows, truncated: truncated)
    }

    // MARK: Private

    private static func middle(_ old: [String], _ new: [String], offset: Int) -> [Step] {
        guard !old.isEmpty else {
            return new.indices.map { Step(kind: .added, old: nil, new: $0 + offset) }
        }
        guard !new.isEmpty else {
            return old.indices.map { Step(kind: .removed, old: $0 + offset, new: nil) }
        }
        guard old.count * new.count <= maxCells else {
            var steps: [Step] = []
            let paired = min(old.count, new.count)
            for index in 0..<paired {
                steps.append(Step(kind: .changed, old: index + offset, new: index + offset))
            }
            for index in paired..<old.count {
                steps.append(Step(kind: .removed, old: index + offset, new: nil))
            }
            for index in paired..<new.count {
                steps.append(Step(kind: .added, old: nil, new: index + offset))
            }
            return steps
        }

        // Bounded LCS: at most maxCells states, so a selector change cannot
        // stall on a long candidate.
        let rows = old.count
        let columns = new.count
        var table = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: columns - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var steps: [Step] = []
        var i = 0
        var j = 0
        while i < rows, j < columns {
            if old[i] == new[j] {
                steps.append(Step(kind: .unchanged, old: i + offset, new: j + offset))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                steps.append(Step(kind: .removed, old: i + offset, new: nil))
                i += 1
            } else {
                steps.append(Step(kind: .added, old: nil, new: j + offset))
                j += 1
            }
        }
        while i < rows {
            steps.append(Step(kind: .removed, old: i + offset, new: nil))
            i += 1
        }
        while j < columns {
            steps.append(Step(kind: .added, old: nil, new: j + offset))
            j += 1
        }
        return steps
    }

    private static func appendUnchanged(
        _ run: [Step],
        oldItems: [String],
        newItems: [String],
        rows: inout [ArenaParagraphChange]
    ) {
        func append(_ step: Step) {
            let text = step.new.map { newItems[$0] } ?? step.old.map { oldItems[$0] }
            rows.append(
                ArenaParagraphChange(
                    id: rows.count, kind: .unchanged, oldText: nil, newText: text, gapCount: 0
                )
            )
        }
        if run.count > 2 {
            append(run[0])
            rows.append(
                ArenaParagraphChange(
                    id: rows.count, kind: .gap, oldText: nil, newText: nil, gapCount: run.count - 2
                )
            )
            append(run[run.count - 1])
        } else {
            run.forEach(append)
        }
    }

    private static func appendChanged(
        _ removed: [Int],
        _ added: [Int],
        oldItems: [String],
        newItems: [String],
        rows: inout [ArenaParagraphChange]
    ) {
        let paired = min(removed.count, added.count)
        for index in 0..<paired {
            rows.append(
                ArenaParagraphChange(
                    id: rows.count,
                    kind: .changed,
                    oldText: oldItems[removed[index]],
                    newText: newItems[added[index]],
                    gapCount: 0
                )
            )
        }
        for index in removed.dropFirst(paired) {
            rows.append(
                ArenaParagraphChange(
                    id: rows.count, kind: .removed, oldText: oldItems[index], newText: nil, gapCount: 0
                )
            )
        }
        for index in added.dropFirst(paired) {
            rows.append(
                ArenaParagraphChange(
                    id: rows.count, kind: .added, oldText: nil, newText: newItems[index], gapCount: 0
                )
            )
        }
    }

    private static func split(_ text: String) -> (items: [String], truncated: Bool) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var items: [String] = []
        var current: [String] = []
        var characters = 0
        var truncated = false

        func flush() {
            guard !current.isEmpty else { return }
            let paragraph = current.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty { items.append(paragraph) }
            current.removeAll(keepingCapacity: true)
        }

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                if items.count >= maxParagraphs { truncated = true; break }
                continue
            }
            if trimmed.hasPrefix("#") {
                flush()
                items.append(trimmed)
                if items.count >= maxParagraphs { truncated = true; break }
                continue
            }
            current.append(value)
            characters += value.count + 1
            if characters >= maxCharacters {
                flush()
                truncated = true
                break
            }
        }
        if !truncated { flush() }
        if items.count > maxParagraphs {
            items = Array(items.prefix(maxParagraphs))
            truncated = true
        }
        return (items, truncated)
    }
}

// MARK: - 值读取

enum ArenaCandidateValue {
    static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
