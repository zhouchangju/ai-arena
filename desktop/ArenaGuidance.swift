//
//  ArenaGuidance.swift
//  AI Arena · 讨论中追加的用户条件（G1/G2/G3，R03/R06）
//
//  用户在独立作答或互评阶段可以追加一条条件。条件只在暂停时记录，并且
//  只被**之后新建**的任务提示采用；已经发出、待处理、已归档的表态任务
//  不会被改写或重发。这里只做纯数据与规则，不访问网络、不碰界面状态。
//
//  `shared/core.js` 的 `applyAction(session, 'guide', { text })` 是唯一写入
//  入口：它要求 stage ∈ {independent, critique} 且 session.paused === true，
//  并把 note 记在 session.guidance。桌面模型只负责先暂停、再调用、再落盘。
//

import Foundation

/// One saved user condition, read back from the persisted session document.
///
/// `deliveredTaskIDs` is the shared engine's bookkeeping: the ids of the tasks
/// whose prompts were constructed *after* the note was written. A prompt that
/// was already issued before the note is never listed here.
struct ArenaGuidanceNote: Identifiable, Equatable {
    let seq: Int
    let text: String
    let stage: String
    let round: Int
    let createdAt: Double
    let deliveredTaskIDs: [String]

    var id: Int { seq }

    var stageLabel: String {
        switch stage {
        case "independent": return "独立作答"
        case "critique": return "互评"
        case "proposal": return "候选结论"
        default: return stage
        }
    }

    /// Where this condition already went. Empty means it is saved but no later
    /// prompt has been constructed yet. The wording stays neutral: a finished
    /// discussion will not continue, so it never promises that it will.
    var deliveryLabel: String {
        if deliveredTaskIDs.isEmpty {
            return "尚未计入任何后续提示"
        }
        return "已计入 \(deliveredTaskIDs.count) 个之后新建的提示"
    }

    /// Independent answers are a prerequisite stage, not review round 1; do not
    /// print "第 1 轮" for them.
    var originLabel: String {
        switch stage {
        case "independent": return "独立作答时提出"
        case "critique": return "互评第 \(round) 轮提出"
        case "proposal": return "候选第 \(round) 轮提出"
        default: return stage.isEmpty ? "讨论中提出" : "\(stageLabel)提出"
        }
    }
}

/// The exact live discussion + phase a condition may be saved into. Pinned when
/// the composer opens so a stage change or a different discussion is refused
/// instead of silently attaching the text to the wrong round.
struct ArenaGuidanceTarget: Identifiable, Equatable {
    let sessionID: String
    let stage: String
    let round: Int

    var id: String { "\(sessionID)-\(stage)-\(round)" }
}

enum ArenaGuidanceAvailability: Equatable {
    /// No affordance: read-only history, a finished discussion or a stage whose
    /// prompts already carry a candidate/vote.
    case hidden
    /// Eligible. `requiresPause == true` means the affordance must pause first
    /// and keep the discussion paused after the note is saved.
    case available(requiresPause: Bool)
}

/// Result of a save attempt. A rejection always leaves the draft untouched.
enum ArenaGuidanceSaveOutcome: Equatable {
    case saved(ArenaGuidanceNote)
    case rejected(String)
}

/// Unsaved condition drafts lived only by this running workbench.
///
/// Each draft is keyed by the exact session / stage / round pinned when the
/// editor opened, so closing and reopening the same round restores the text,
/// while another discussion, stage or round can never inherit it. Nothing here
/// is written to the session file or to the shared engine, and parking a draft
/// never resumes dispatch: the condition still reaches the discussion only
/// through `saveGuidance`.
struct ArenaGuidanceDraftParking: Equatable {
    private(set) var drafts: [String: String] = [:]

    func text(for target: ArenaGuidanceTarget) -> String {
        drafts[target.id] ?? ""
    }

    /// A blank (or whitespace-only) draft is not worth restoring, and only a
    /// blank draft lets a cancelled editor undo the pause it applied.
    func hasDraft(for target: ArenaGuidanceTarget) -> Bool {
        !text(for: target).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func set(_ text: String, for target: ArenaGuidanceTarget) {
        if text.isEmpty {
            drafts.removeValue(forKey: target.id)
        } else {
            drafts[target.id] = text
        }
    }

    /// Only a successful save clears the text. A rejected save keeps it.
    mutating func clear(_ target: ArenaGuidanceTarget) {
        drafts.removeValue(forKey: target.id)
    }

    /// Keep only the live phase's draft. Called when an editor opens (and when
    /// a fresh discussion starts) so text typed into a different round or
    /// session cannot surface under the current one.
    mutating func keepOnly(_ target: ArenaGuidanceTarget) {
        drafts = drafts.filter { $0.key == target.id }
    }

    mutating func removeAll() {
        drafts.removeAll()
    }

    var isEmpty: Bool { drafts.isEmpty }
}

/// What closing the editor without saving does to the pause this workbench
/// applied when it opened. Kept out of the view so the rule is checkable:
///
/// * a saved condition always keeps the pause (0.7 behaviour);
/// * a draft typed into this same round also keeps the pause, so reopening
///   restores it and the next dispatch is not silently re-armed;
/// * only an editor cancelled with an empty draft undoes the pause it applied
///   itself. A pause the user made before opening is never undone.
enum ArenaGuidanceClosePolicy {
    static func undoesOwnedPause(ownedPause: Bool, saved: Bool, hasDraft: Bool) -> Bool {
        ownedPause && !saved && !hasDraft
    }
}

enum ArenaGuidanceRules {
    /// Mirrors `GUIDANCE_INPUT_STAGES` in `shared/core.js`.
    static let eligibleStages: Set<String> = ["independent", "critique"]
    /// Mirrors `MAX_GUIDANCE` in `shared/core.js`. JavaScript counts UTF-16
    /// code units, so the UI and the model use `utf16.count` too.
    static let maxTextLength = 2000

    /// Who may see the affordance. Only a live discussion in an eligible stage
    /// exposes it; legacy and read-only sessions keep their existing behaviour.
    static func availability(
        stage: String,
        sessionID: String?,
        readOnly: Bool,
        paused: Bool
    ) -> ArenaGuidanceAvailability {
        guard !readOnly,
              let id = sessionID,
              !id.isEmpty,
              eligibleStages.contains(stage) else {
            return .hidden
        }
        return .available(requiresPause: !paused)
    }

    /// Re-check the whole pinned phase immediately before writing. The shared
    /// engine enforces the same rules; this keeps a stale composer from even
    /// attempting the write.
    static func accepts(
        target: ArenaGuidanceTarget,
        sessionID: String?,
        stage: String,
        round: Int,
        paused: Bool,
        readOnly: Bool
    ) -> Bool {
        guard !readOnly, paused,
              eligibleStages.contains(stage),
              let sessionID, sessionID == target.sessionID,
              stage == target.stage,
              round == target.round else {
            return false
        }
        return true
    }

    /// Read the conditions already saved in the session. Legacy sessions have
    /// no field and simply produce an empty list.
    static func notes(from session: [String: Any]?) -> [ArenaGuidanceNote] {
        guard let session,
              let raw = session["guidance"] as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { row in
            guard let text = row.arenaString("text")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return nil
            }
            return ArenaGuidanceNote(
                seq: row.arenaInt("seq") ?? 0,
                text: text,
                stage: row.arenaString("stage") ?? "",
                round: row.arenaInt("round") ?? 0,
                createdAt: row.arenaDouble("createdAt") ?? 0,
                deliveredTaskIDs: row.arenaStringArray("deliveredTo")
            )
        }
    }
}
