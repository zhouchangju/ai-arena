//
//  ArenaModel.swift
//  AI Arena desktop (G1–G4)
//
//  The observable workbench state machine. One instance owns:
//    - the current discussion (`session`, produced by `arena-core.js`),
//    - one `SitePane` per participating site,
//    - independent per-seat dispatch/read loops,
//    - takeover, manual answers, pause/finish and skip,
//    - atomic persistence, history and restart recovery.
//
//  Safety rules enforced here:
//    * a delivery intent is persisted before a submit command runs, and a seat
//      never resends a task whose submit may already have happened;
//    * a task whose submit may already have happened is checked with the
//      read-only `read` command only; if the page cannot confirm it, the task
//      stays blocked for a human;
//    * every command result is re-validated against the run token, the current
//      task and that one seat's takeover state before it may change anything;
//    * `resumeSeat` runs only from an explicit user action, one seat at a time;
//    * a restored session and a history record never auto-send; restore is
//      handled as manual verification;
//    * takeover only changes one provider's loop; other seats keep running;
//    * callbacks from an older discussion are ignored through `runToken`.
//

import Foundation
import AppKit
import SwiftUI

/// The exact round a manual answer form was opened for. Saving is refused when
/// the discussion, task, stage, round or candidate version moved on, so a
/// pasted answer can never land in the next round.
struct ArenaManualTarget: Equatable {
    let provider: String
    let sessionID: String
    let taskID: String
    let stage: String
    let round: Int
    let version: Int?
}

/// What a seat is doing right now. The UI derives colour and a short badge from
/// this value only; the free-text `detail` is the sentence shown in the tooltip
/// and status line. No view ever guesses a state from detail wording.
enum ArenaSeatStateKind: String, Codable, CaseIterable {
    case idle
    case sending
    case generating
    case answered
    case needsAction
    case takenOver
    case skipped
    case paused
    case done
}

struct ArenaSeatState: Equatable {
    var kind: ArenaSeatStateKind
    var detail: String

    /// Flat, JSON-safe form for the smoke diagnostics. Extra keys are additive;
    /// the existing `statuses` text map stays for compatibility.
    var jsonObject: [String: String] {
        ["kind": kind.rawValue, "detail": detail]
    }
}

/// A one-shot, live-only UI signal for one seat and one task. It is deliberately
/// in-memory: restoring a session, opening history or reconciling a task that
/// may already have been sent never creates one. The UUID only gives SwiftUI a
/// stable change token, so the same task cannot replay a microinteraction twice.
struct ArenaSeatLiveSignal: Equatable {
    enum Kind: String {
        case receiptVerified
        case answerSaved
    }

    let id: UUID
    let taskID: String
    let kind: Kind

    init(taskID: String, kind: Kind) {
        self.id = UUID()
        self.taskID = taskID
        self.kind = kind
    }
}

/// Which per-seat actions the current state really allows.
struct ArenaSeatControls: Equatable {
    var canTakeOver = false
    var canResume = false
    var canBackfill = false
    var canSkip = false
    var canOpenHome = false

    static let none = ArenaSeatControls()
}

/// One seat-local recovery step for a blocked seat. The kind is chosen from
/// structured model facts only; the Chinese `detail` sentence is never parsed.
/// `target` pins the round the button was rendered for, and the click handler
/// refuses to act when the pending task has moved on.
struct ArenaSeatLocalAction: Equatable {
    enum Kind: String, Equatable {
        /// The persisted delivery intent proves the resume path can only read:
        /// `.submitted` continues the read, `.inflight` / `.uncertain` re-check
        /// with the read-only `read` command. It never labels a task that the
        /// resume path might submit.
        case readOnlyCheck
        /// A complete answer was already refused (e.g. a vote without an
        /// explicit stance), so re-reading would return the same refusal. Opens
        /// the existing non-modal backfill panel, which never sends to the site.
        case verifyAndBackfill
    }

    var kind: Kind
    var target: ArenaManualTarget
}

/// Preview text for a seat. A streamed fragment and a complete answer that was
/// not accepted are different things and must be labelled differently.
struct ArenaPreview: Equatable {
    var text: String
    /// `true` when this is a complete answer the discussion engine refused
    /// (e.g. a vote without an explicit stance), not a mid-stream fragment.
    var isComplete: Bool
}

/// Opening text for the non-modal backfill panel.
struct ArenaBackfillPrefill: Equatable {
    var text: String
    /// `true` only for a mid-stream preview fragment.
    var isPartial: Bool
    /// `true` for a complete answer the engine refused; also needs a note.
    var isComplete: Bool
}

/// Unified stage wording (UI, export, statuses). Internal keys never change.
enum ArenaStageNames {
    static let labels: [String: String] = [
        "independent": "独立作答",
        "critique": "互评",
        "proposal": "候选结论",
        "vote": "表态",
        "done": "结束",
    ]

    static func label(_ stage: String) -> String {
        if stage.isEmpty { return "未开始" }
        return labels[stage] ?? stage
    }

    static func reviewRound(_ session: [String: Any]?) -> String? {
        guard let session else { return nil }
        let stage = session.arenaString("stage") ?? ""
        if stage == "done" {
            let history = session["history"] as? [[String: Any]] ?? []
            let rounds = Set(history.filter { $0.arenaString("stage") == "critique" }
                .compactMap { $0.arenaInt("round") })
            return rounds.isEmpty ? nil : roundLabel(rounds.count, session: session)
        }
        guard ["critique", "proposal", "vote"].contains(stage),
              let round = session.arenaInt("round") else { return nil }
        return roundLabel(round, session: session)
    }

    static func discussionLabel(_ session: [String: Any]) -> String {
        let stage = label(session.arenaString("stage") ?? "")
        return [stage, reviewRound(session)].compactMap { $0 }.joined(separator: " · ")
    }

    static func taskLabel(_ stage: String, round: Int, session: [String: Any]?) -> String {
        guard stage != "independent" else { return label(stage) }
        return "\(label(stage)) · \(roundLabel(round, session: session))"
    }

    private static func roundLabel(_ round: Int, session: [String: Any]?) -> String {
        let limit = session?.arenaInt("maxRounds") ?? 2
        return "互评第 \(round) 轮 / 上限 \((1...5).contains(limit) ? limit : 2)"
    }
}

/// A durable, session-derived seat outcome. Only saved rows are read, so this
/// never reflects a transient "只读回看" UI label or an in-flight page command.
enum ArenaSeatOutcome {
    static func derive(session: [String: Any]?, provider: String, ballot: [String: Any]? = nil) -> ArenaSeatState {
        guard let session else {
            return ArenaSeatState(kind: .idle, detail: "待开始")
        }
        let participants = session.arenaStringArray("providers")
        guard participants.contains(provider) else {
            return ArenaSeatState(kind: .idle, detail: "未参与本场")
        }
        let stage = session.arenaString("stage") ?? ""
        let round = session.arenaInt("round") ?? 1
        let history = rows(session, key: "history")
        let tasks = rows(session, key: "tasks")
        let all = history + tasks
        let proposal = latestProposal(history)
        let version = proposal?.arenaInt("version")
        let paused = session.arenaBool("paused") ?? false

        if stage == "done" {
            if let version {
                let votes = ballot?["votes"] as? [[String: Any]] ?? []
                if let vote = votes.last(where: { $0.arenaString("provider") == provider }),
                   let stance = vote.arenaString("stance") {
                    return ArenaSeatState(
                        kind: .done,
                        detail: "最终表态：\(stanceLabel(stance))（v\(version)）"
                    )
                }
                let skip = all.last {
                    $0.arenaString("stage") == "vote"
                        && $0.arenaString("provider") == provider
                        && $0.arenaInt("version") == version
                        && $0.arenaString("status") == "skipped"
                }
                if skip != nil {
                    return ArenaSeatState(kind: .skipped, detail: "已跳过 v\(version) 表态（计为缺席）")
                }
                return ArenaSeatState(
                    kind: .needsAction,
                    detail: "未对候选 v\(version) 明确表态（不计为同意）"
                )
            }
            if let row = all.last(where: { $0.arenaString("provider") == provider }) {
                switch row.arenaString("status") {
                case "skipped": return ArenaSeatState(kind: .skipped, detail: "已跳过（计为缺席）")
                case "pending": return ArenaSeatState(kind: .done, detail: "结束时仍待回答")
                default: break
                }
            }
            return ArenaSeatState(kind: .done, detail: "讨论已结束（未形成候选）")
        }

        let pending = tasks.first {
            $0.arenaString("provider") == provider && $0.arenaString("status") == "pending"
        }
        if paused {
            if pending != nil || tasks.isEmpty {
                return ArenaSeatState(kind: .paused, detail: "已暂停 · \(ArenaStageNames.taskLabel(stage, round: round, session: session))")
            }
            // A seat that already answered this stage keeps its real outcome;
            // pause only withholds the next dispatch.
        }
        if let pending {
            let pendingVersion = pending.arenaInt("version")
            if stage == "vote", let version, pendingVersion == version {
                return ArenaSeatState(kind: .generating, detail: "等待表态（v\(version) · \(ArenaStageNames.reviewRound(session) ?? ArenaStageNames.label(stage))）")
            }
            return ArenaSeatState(
                kind: .generating,
                detail: "等待回答（\(ArenaStageNames.taskLabel(stage, round: round, session: session))）"
            )
        }

        if let row = all.last(where: {
            $0.arenaString("provider") == provider
                && $0.arenaString("stage") == stage
                && $0.arenaInt("round") == round
        }) {
            switch row.arenaString("status") {
            case "answered":
                if stage == "vote", let stance = row.arenaString("stance") {
                    let rowVersion = row.arenaInt("version")
                    return ArenaSeatState(
                        kind: .answered,
                        detail: "已表态：\(stanceLabel(stance))\(rowVersion.map { "（v\($0)）" } ?? "")"
                    )
                }
                return ArenaSeatState(kind: .answered, detail: "已收到本阶段回答")
            case "skipped":
                return ArenaSeatState(kind: .skipped, detail: "已跳过本阶段任务（计为缺席）")
            default:
                return ArenaSeatState(kind: .generating, detail: "等待回答（\(ArenaStageNames.taskLabel(stage, round: round, session: session))）")
            }
        }

        if stage.isEmpty {
            return ArenaSeatState(kind: .idle, detail: "待开始")
        }
        return ArenaSeatState(kind: .idle, detail: "本阶段无任务（等待其他席位）")
    }

    private static func rows(_ session: [String: Any], key: String) -> [[String: Any]] {
        (session[key] as? [[String: Any]]) ?? []
    }

    private static func latestProposal(_ history: [[String: Any]]) -> [String: Any]? {
        history.last {
            $0.arenaString("stage") == "proposal"
                && $0.arenaString("status") == "answered"
                && $0.arenaInt("version") != nil
        }
    }


    private static func stanceLabel(_ stance: String) -> String {
        switch stance {
        case "agree": return "同意"
        case "conditional": return "有条件同意"
        case "oppose": return "反对"
        default: return stance
        }
    }
}

/// One bounded read-only recovery is allowed per delivered task after this many
/// seconds without any visible new content. It sits inside the agreed 30–45 s
/// window and is never a completion signal by itself.
let arenaStalledReadRecoverySeconds: TimeInterval = 35

/// A Gemini seat whose send control stays missing/hidden before any click is
/// repaired once per task by reloading this seat's own bound conversation. The
/// repair waits for either this long or this many consecutive driver-confirmed
/// pre-click refusals, stays inside the agreed 15–25 s window, and never clicks.
let arenaPreClickReloadAfterSeconds: TimeInterval = 20
let arenaPreClickReloadAfterRefusals = 3
/// How long the reloaded page may take to mount a usable composer again.
let arenaPreClickReloadReadySeconds: TimeInterval = 20

@MainActor
final class ArenaModel: ObservableObject {

    // MARK: Public state

    /// The question shown on the start screen.
    @Published var question: String = ""

    @Published var draftAttachments: [ArenaDraftAttachment] = []

    func addDraftAttachments(_ attachments: [ArenaDraftAttachment]) {
        guard session == nil, !attachments.isEmpty else { return }
        do {
            let items = draftAttachments + attachments
            try ArenaDraftAttachment.validate(items)
            draftAttachments = items
            errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Only material explicitly attached to this discussion is available here.
    var sessionAttachments: [[String: Any]] {
        session?["attachments"] as? [[String: Any]] ?? []
    }

    func attachmentURL(_ attachment: [String: Any]) throws -> URL {
        guard let currentID,
              let stored = sessionAttachments.first(where: {
                  $0.arenaString("id") == attachment.arenaString("id")
              }) else { throw ArenaEngineError("找不到本场附件") }
        return try engine.store.attachmentURL(sessionID: currentID, attachment: stored)
    }

    func requiresManualAttachmentConfirmation(for provider: String) -> Bool {
        stageKey == "independent" && !sessionAttachments.isEmpty && pendingTask(for: provider) != nil
    }

    func attachmentDeliverySummary(for provider: String) -> String? {
        guard !sessionAttachments.isEmpty else { return nil }
        let archived = session?["history"] as? [[String: Any]] ?? []
        let task = archived.first {
            $0.arenaString("stage") == "independent" && $0.arenaString("provider") == provider
        } ?? (stageKey == "independent" ? currentTasks.first { $0.arenaString("provider") == provider } : nil)
        switch task?.arenaString("attachmentReceipt") {
        case "verified": return "原页已核对全部附件"
        case "manual": return "已人工核对全部附件"
        default: return task?.arenaString("status") == "skipped" ? "已跳过，附件送达未核实" : "附件送达待核对"
        }
    }

    /// Latest session document produced by `arena-core.js`.
    @Published private(set) var session: [String: Any]?

    /// Structured, per-seat state. The UI and diagnostics derive everything
    /// from `kind` + `detail`; nothing is inferred from the wording.
    @Published private(set) var seatStates: [String: ArenaSeatState] = [:]

    /// Live-only, one-shot signals for the seat header microinteractions.
    /// Receipt only exists after WebKit verified this send's matching user turn;
    /// answer only exists after the accepted answer was written to disk.
    @Published private(set) var seatReceiptSignals: [String: ArenaSeatLiveSignal] = [:]
    @Published private(set) var seatAnswerSignals: [String: ArenaSeatLiveSignal] = [:]
    /// Monotonic counter for the top stage answer count. It advances only on a
    /// live accepted-and-saved answer, so restoration never animates the count.
    @Published private(set) var liveAnswerRevision = 0

    /// Compatibility text view of `seatStates` for the smoke diagnostics and
    /// existing fixtures. Always the exact `detail`, never a guessed label.
    var statuses: [String: String] {
        seatStates.mapValues { $0.detail }
    }

    /// Last blocking or informational error. Seat-level problems stay in
    /// `seatStates` so one failing site does not hide the other two.
    @Published var errorMessage: String = ""

    /// Web panes owned by the discussion, keyed by provider id.
    @Published private(set) var panes: [String: SitePane] = [:]

    /// Latest preview for a seat, with an explicit partial/complete marker.
    /// Never saved as the accepted answer.
    @Published private(set) var previews: [String: ArenaPreview] = [:]

    /// Saved discussions, newest first, with date and saved outcome.
    @Published private(set) var historyList: [ArenaHistorySummary] = []

    /// Unfinished history session that can reopen for manual verification.
    @Published private(set) var historyResumeID: String?

    @Published private(set) var stageKey: String = ""
    @Published private(set) var stageLabel: String = "尚未开始"
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var isReadOnly: Bool = false
    @Published private(set) var isRecovering: Bool = false
    @Published private(set) var recoveryNotice: String = ""
    @Published private(set) var evaluatingSessionID: String?
    @Published private(set) var evaluationPage: EvaluationPage?

    struct EvaluationPage: Identifiable {
        let id = UUID()
        let sessionID: String
        let pane: SitePane
    }

    /// True only when this launch used `--continue-saved-discussion <id>` and
    /// the saved discussion passed every safety check, so the dispatcher was
    /// restarted for the existing session. A normal launch stays manual.
    @Published private(set) var didContinueSavedDiscussion: Bool = false

    /// App-level reaction to a durable completion. Kept separate from view
    /// state so the window chooses between opening the report and notifying.
    var onDiscussionCompleted: ((ArenaCompletionEvent) -> Void)?

    /// A discussion exists and has not reached the final stage. Used by the app
    /// delegate to confirm quitting/closing and by the destructive UI actions.
    var hasRunningDiscussion: Bool {
        !isReadOnly && session != nil && stageKey != "done"
    }

    // MARK: Private state

    private let engine: ArenaEngine
    private let explicitContinueID: String?
    private var runToken = UUID()
    private var dispatcher: Task<Void, Never>?
    private var workers: [String: Task<Void, Never>] = [:]

    private var manualProviders: Set<String> = []
    private var verificationProviders: Set<String> = []
    private var blockedTasks: Set<String> = []
    private var intents: [String: ArenaDeliveryIntent] = [:]

    /// Per delivered task: the last visible progress fingerprint and when that
    /// exact fingerprint was first seen. Cleared when content moves, when the
    /// task is delivered, and when a new discussion starts. Deliberately
    /// in-memory only: a restart must observe a fresh stall before reloading;
    /// whether the one reload was already spent travels on the intent.
    private var readRecoveryStalls: [String: ReadRecoveryStall] = [:]

    private struct ReadRecoveryStall {
        var fingerprint: String
        var since: Date
    }

    /// Per task: the first driver-confirmed `missing`/`hidden` pre-click send
    /// refusal in the current streak and how many have followed it. Cleared
    /// when the streak breaks, when the task is delivered, and when a new run
    /// starts. Deliberately in-memory only: a restart must observe a fresh
    /// streak before it may reload anything.
    private var preClickStalls: [String: PreClickStall] = [:]
    /// Tasks whose single automatic pre-click reload was already spent this run.
    private var preClickReloadedTasks: Set<String> = []

    private struct PreClickStall {
        var since: Date
        var refusals: Int
    }

    private var currentID: String?
    private var createdAt: Double = 0
    private var storageFailed = false
    private var completionTracker = ArenaCompletionTracker()

    /// How long a normal start keeps probing a real site whose composer has not
    /// mounted yet. The bound is deliberately inside the agreed 30–38 s window,
    /// and `probe` neither fills nor clicks, so retrying here cannot deliver.
    private static let realProbeWindowSeconds: TimeInterval = 34
    /// Fixture pages mount immediately; a long window would only delay failures.
    private static let fixtureProbeWindowSeconds: TimeInterval = 6
    /// Bounded read-only window used to re-check a task whose submit may have
    /// already run. Only `read` is used inside it.
    private static let verifyWindowSeconds: TimeInterval = 90
    /// A probe blocked on `document-not-ready` may navigate back to its own
    /// page at most once after this long. It is deliberately just above the
    /// 10 s document-readiness wait, so a normally slow site is never raced.
    private static let probeRecoveryDelaySeconds: TimeInterval = 10

    // MARK: Init / restore

    init(continueSessionID: String? = nil) {
        let requested = continueSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.explicitContinueID = (requested?.isEmpty == false) ? requested : nil
        self.engine = ArenaEngine()
        if let issue = engine.configurationIssue {
            self.errorMessage = issue
        }
        refreshHistoryList()
        restoreInitialSession()
        prepareInitialPanes()
        // Only the explicit, verified continuation restarts dispatch. A normal
        // launch of a saved discussion deliberately stays manual.
        if didContinueSavedDiscussion {
            startDispatcher(token: runToken)
        }
    }

    // MARK: Discussion lifecycle

    /// Start a new discussion with two or three distinct provider ids.
    ///
    /// `maxRounds` is the total round budget (1-5, default 3 for a new desktop
    /// session): the first independent/critique/proposal/vote round plus up to
    /// four targeted follow-ups. A legacy session keeps the original
    /// two-round budget because it never passes this option.
    ///
    /// The core session is created first, then every seat's original site is
    /// opened at its new-conversation entry page. Independent answers, peer
    /// critique, proposal and same-version votes are then driven in parallel.
    func start(_ providers: [String], maxRounds: Int = 3) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "请先输入要讨论的问题"
            return
        }
        guard trimmed.count <= 20_000 else {
            errorMessage = "问题过长，请压缩到 20000 字以内"
            return
        }
        let unique = Array(Set(providers))
        guard providers.count == unique.count else {
            errorMessage = "同一席位不能重复添加"
            return
        }
        guard (2...3).contains(providers.count) else {
            errorMessage = "请选择两席或三席参与讨论"
            return
        }
        guard (1...5).contains(maxRounds) else {
            errorMessage = "互评上限请选择 1 到 5 轮"
            return
        }

        var configs: [String: ArenaSiteConfig] = [:]
        for provider in providers {
            do {
                configs[provider] = try engine.config(for: provider)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        stopRunningWork()

        let created: [String: Any]
        do {
            created = try engine.createSession(
                question: trimmed,
                providers: providers,
                maxRounds: maxRounds,
                attachments: draftAttachments
            )
        } catch {
            errorMessage = "无法建立场次：\(error.localizedDescription)"
            return
        }

        session = created
        draftAttachments.removeAll()
        isReadOnly = false
        isRecovering = false
        didContinueSavedDiscussion = false
        recoveryNotice = ""
        isPaused = false
        storageFailed = false
        intents.removeAll()
        manualProviders.removeAll()
        verificationProviders.removeAll()
        blockedTasks.removeAll()
        previews.removeAll()
        seatStates.removeAll()
        readRecoveryStalls.removeAll()
        historyResumeID = nil
        currentID = created.arenaString("id")
        createdAt = Self.nowMillis()
        errorMessage = ""
        completionTracker.reset()

        refreshStage()
        persist()

        panes = panes.filter { providers.contains($0.key) }
        let token = runToken
        for provider in providers {
            guard let config = configs[provider] else { continue }
            let pane = ensurePane(for: provider)
            // 新场次才解除上一场固定的对话；本场后续轮次与人工接管都不重置。
            pane.resetConversationBinding()
            pane.open(config.url)
            setState(provider, .idle, "打开原页…")
        }
        startDispatcher(token: token)
    }

    /// Pause or resume dispatch. Sending is paused, not cancelled: a command
    /// already handed to a page finishes, and nothing is re-sent on resume.
    func pauseOrResume() {
        guard let session else {
            errorMessage = "还没有正在进行的讨论"
            return
        }
        guard session.arenaString("stage") != "done" else {
            errorMessage = "讨论已经结束"
            return
        }
        guard !isReadOnly else {
            errorMessage = "历史回看为只读；新建讨论后才能继续"
            return
        }
        _ = setPaused(!isPaused)
    }

    /// The one pause/resume path. Both the toolbar button and the guidance
    /// affordance go through it, so pausing for a condition has exactly the
    /// same effect as pausing manually and never resumes by itself.
    @discardableResult
    private func setPaused(_ paused: Bool) -> Bool {
        guard let session else { return false }
        guard session.arenaString("stage") != "done" else { return false }
        guard !isReadOnly else { return false }
        do {
            self.session = try engine.apply(
                session: session,
                action: paused ? "pause" : "resume",
                payload: [:]
            )
        } catch {
            errorMessage = "无法\(paused ? "暂停" : "继续")：\(error.localizedDescription)"
            return false
        }
        isPaused = self.session?.arenaBool("paused") ?? paused
        if isPaused {
            // A paused discussion must never start a receipt animation. Clearing
            // only the transient receipt token is enough; the seat state itself
            // still carries the truthful waiting/answered wording.
            seatReceiptSignals.removeAll()
        }
        refreshStage()
        persist()

        for provider in currentProviders {
            guard let pending = pendingTask(for: provider) else { continue }
            if isPaused {
                setState(provider, .paused, "已暂停")
            } else if manualProviders.contains(provider) {
                setManualWaitingState(provider, task: pending)
            } else if blockedTasks.contains(pending.arenaString("id") ?? "") {
                setState(provider, .needsAction, "需要你核对原页")
            } else if intents[pending.arenaString("id") ?? ""]?.phase == .submitted {
                setState(provider, .generating, "继续读取回答…")
            } else if let phase = intents[pending.arenaString("id") ?? ""]?.phase,
                      phase == .inflight || phase == .uncertain {
                setState(provider, .needsAction, "可能已发送，需你核对原页（不会重发）")
            } else {
                setState(provider, .sending, "继续…")
            }
        }
        return true
    }

    // MARK: - User conditions during a discussion

    /// Only a live, eligible independent/critique phase exposes the affordance.
    var guidanceAvailability: ArenaGuidanceAvailability {
        ArenaGuidanceRules.availability(
            stage: stageKey,
            sessionID: session?.arenaString("id"),
            readOnly: isReadOnly,
            paused: isPaused
        )
    }

    /// Conditions already recorded in the current (possibly historical)
    /// session. Read-only history shows them without offering an editor.
    var savedGuidance: [ArenaGuidanceNote] {
        ArenaGuidanceRules.notes(from: session)
    }

    var guidanceCount: Int { savedGuidance.count }

    /// The live phase a condition may attach to, pinned at the moment the
    /// composer opens. `nil` when no live eligible discussion exists.
    func guidanceTarget() -> ArenaGuidanceTarget? {
        if case .hidden = guidanceAvailability { return nil }
        guard let id = session?.arenaString("id"), !id.isEmpty else { return nil }
        return ArenaGuidanceTarget(sessionID: id, stage: stageKey, round: currentRound)
    }

    /// The guidance entry point: pause first (through the normal pause path),
    /// then hand back the pinned phase. Saving a condition never resumes the
    /// discussion and never dispatches an already-issued task.
    func beginGuidance() -> ArenaGuidanceTarget? {
        guard let target = guidanceTarget() else {
            errorMessage = readOnlyGuidanceMessage
            return nil
        }
        guard !isPaused else { return target }
        guard setPaused(true) else { return nil }
        // The pause action cannot move the stage, but re-pin from the live
        // session so the composer can never save into a stale phase.
        guard let pinned = guidanceTarget(), pinned == target else {
            errorMessage = "讨论阶段已变化，请重新打开补充条件"
            return nil
        }
        return pinned
    }

    /// `true` when the pinned phase is still the live, paused, same session /
    /// stage / round. The composer disables saving the moment this goes false.
    func guidancePhaseMatches(_ target: ArenaGuidanceTarget) -> Bool {
        ArenaGuidanceRules.accepts(
            target: target,
            sessionID: session?.arenaString("id"),
            stage: stageKey,
            round: currentRound,
            paused: isPaused,
            readOnly: isReadOnly
        )
    }

    /// Record one condition. Refuses unless the discussion is still the pinned
    /// live session, the same stage/round and paused. The session is written
    /// atomically; a durable-save failure rolls the in-memory session back so
    /// the composer can keep the draft and retry.
    func saveGuidance(_ text: String, target: ArenaGuidanceTarget) -> ArenaGuidanceSaveOutcome {
        guard let previous = session else {
            return .rejected("没有正在进行的讨论")
        }
        guard ArenaGuidanceRules.accepts(
            target: target,
            sessionID: previous.arenaString("id"),
            stage: stageKey,
            round: currentRound,
            paused: isPaused,
            readOnly: isReadOnly
        ) else {
            return .rejected("讨论阶段或暂停状态已变化，条件未保存；草稿已保留。")
        }
        // Guidance writes only the pinned live scene file; require the pointer
        // to already be this exact session so no partial-write risk remains.
        guard previous.arenaString("id") == currentID else {
            return .rejected("本地当前场次尚未同步，条件未保存；请稍后重试，草稿已保留。")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected("请先写一条条件")
        }
        guard trimmed.utf16.count <= ArenaGuidanceRules.maxTextLength else {
            return .rejected("条件最多 \(ArenaGuidanceRules.maxTextLength) 个字符（与网页计数一致）；草稿已保留。")
        }
        let previousNotes = ArenaGuidanceRules.notes(from: previous)
        let lastSeq = previousNotes.map(\.seq).max() ?? 0
        let next: [String: Any]
        do {
            next = try engine.apply(
                session: previous,
                action: "guide",
                payload: ["text": trimmed]
            )
        } catch {
            return .rejected("条件未保存：\(error.localizedDescription)")
        }
        // Validate the recorded note before touching the live session or the
        // disk, so a committed write can never be reported as a rejection.
        let notes = ArenaGuidanceRules.notes(from: next)
        guard notes.count == previousNotes.count + 1,
              let note = notes.last,
              note.seq > lastSeq,
              note.text == trimmed else {
            return .rejected("条件没有写入本次讨论，未保存；草稿已保留。")
        }
        self.session = next
        isPaused = next.arenaBool("paused") ?? true
        refreshStage()
        // The composer only saves into the pinned live session, so the scene
        // file alone is written and the existing current pointer is untouched.
        guard persist(updateCurrent: false) else {
            // Durable save failed: restore the previous session so the UI and
            // the next dispatch decision both see the last really-saved state.
            self.session = previous
            isPaused = previous.arenaBool("paused") ?? true
            refreshStage()
            return .rejected("条件未写入本地记录，已撤销；草稿已保留。")
        }
        return .saved(note)
    }

    private var readOnlyGuidanceMessage: String {
        if isReadOnly {
            return "历史回看为只读；新建讨论后才能补充条件"
        }
        if stageKey == "done" {
            return "讨论已经结束，不能再补充条件"
        }
        return "只有独立作答或互评阶段可以补充条件"
    }

    /// Stop the discussion, keep every saved answer and produce the report.
    func finish() {
        guard let session else {
            errorMessage = "还没有正在进行的讨论"
            return
        }
        guard !isReadOnly else {
            errorMessage = "历史回看为只读；新建讨论后才能操作"
            return
        }
        guard session.arenaString("stage") != "done" else {
            return
        }
        stopRunningWork()
        do {
            self.session = try engine.apply(
                session: session,
                action: "finish",
                payload: [:]
            )
        } catch {
            errorMessage = "无法结束讨论：\(error.localizedDescription)"
            return
        }
        isPaused = false
        refreshStage()
        persist()
        for provider in currentProviders {
            let state = finalState(for: provider)
            setState(provider, state.kind, state.detail)
        }
    }

    /// Turn one seat manual. Other seats keep their own loops untouched.
    func takeOver(_ provider: String) {
        guard !isReadOnly else {
            errorMessage = "历史回看为只读；新建讨论后才能接管"
            return
        }
        guard session != nil else {
            errorMessage = "还没有正在进行的讨论"
            return
        }
        guard currentProviders.contains(provider) else {
            errorMessage = "该席位不在本场讨论中"
            return
        }
        manualProviders.insert(provider)
        verificationProviders.remove(provider)
        if let pending = pendingTask(for: provider) {
            blockedTasks.remove(pending.arenaString("id") ?? "")
            setState(provider, .takenOver, "已接管；核对原页后可从本席菜单「文本补录…」提交")
        } else {
            setState(provider, .takenOver, "已接管")
        }
        persist()
    }

    /// Resume one seat after the user explicitly asks for it (the seat card's
    /// 「恢复本站自动」). Only the current task of that one seat is validated and
    /// advanced:
    ///
    /// * no intent, or a `.prepared` intent: the submit never ran, so the task
    ///   returns to automatic dispatch;
    /// * `.submitted`: keep reading the answer only;
    /// * `.inflight` / `.uncertain`: the click may have happened, so only the
    ///   read-only `read` re-check is allowed — this never submits again.
    ///
    /// Every other seat, including the ones the user took over by hand, is left
    /// exactly as it was.
    func resumeSeat(_ provider: String) {
        guard !isReadOnly else {
            errorMessage = "历史回看为只读；新建讨论后才能恢复"
            return
        }
        guard session != nil else {
            errorMessage = "还没有正在进行的讨论"
            return
        }
        guard currentProviders.contains(provider) else {
            errorMessage = "该席位不在本场讨论中"
            return
        }
        guard engine.hasConfig(for: provider) else {
            errorMessage = "「\(displayName(provider))」的站点配置不可用"
            return
        }
        guard stageKey != "done" else {
            errorMessage = "讨论已经结束；没有可恢复的任务"
            return
        }
        // A manual first answer has no driver receipt. Only the explicit resume
        // action authorizes the currently shown conversation for future rounds.
        if sessionAttachments.isEmpty, manualProviders.contains(provider), let pane = panes[provider],
           pane.boundConversationURL == nil, let url = pane.webView.url {
            _ = pane.restoreConversationBinding(url)
        }
        guard let task = pendingTask(for: provider), let taskID = task.arenaString("id") else {
            errorMessage = "「\(displayName(provider))」当前没有待处理任务"
            return
        }

        manualProviders.remove(provider)
        blockedTasks.remove(taskID)
        _ = ensurePane(for: provider)
        // The decision itself has to be durable before any automatic work runs.
        guard persist() else {
            manualProviders.insert(provider)
            blockedTasks.insert(taskID)
            setState(provider, .needsAction, "本地保存失败，暂未恢复")
            return
        }
        verificationProviders.remove(provider)

        let name = displayName(provider)
        switch intents[taskID]?.phase {
        case .submitted:
            setState(provider, .generating, "恢复只读：继续读取本轮回答…")
            if isRecovering {
                recoveryNotice = "已恢复上次讨论。「\(name)」只读继续本轮回答，不会重发；其他席位仍为人工核对。"
            }
        case .inflight, .uncertain:
            setState(provider, .needsAction, "恢复只读：可能已发送，只核对不重发…")
            if isRecovering {
                recoveryNotice = "已恢复上次讨论。「\(name)」本轮可能已发送，只做只读核对，不会重发；其他席位仍为人工核对。"
            }
        case .prepared, .none:
            setState(provider, .sending, "恢复自动：准备本轮提示…")
            if isRecovering {
                recoveryNotice = "已恢复上次讨论。「\(name)」尚未发送的任务恢复自动派发；其他席位仍为人工核对。"
            }
        }

        if workers[taskID] == nil {
            if isPaused {
                // Keep the decision; the dispatcher starts the task after the
                // user resumes the discussion.
                setState(provider, .paused, "已暂停；继续讨论后生效")
            } else {
                launchWorker(provider: provider, task: task, token: runToken)
            }
        }
        ensureDispatcher(token: runToken)
    }

    /// Explicit user action from a drifted seat: reopen the saved conversation
    /// and resume this one seat. It never sends anything by itself; the normal
    /// `resumeSeat` phase rules decide whether this is a guarded pre-click
    /// retry, a read-only check, or an immediate stop.
    func returnToBoundConversationAndResume(_ provider: String) {
        guard !isReadOnly else {
            errorMessage = "历史回看为只读；新建讨论后才能操作原页"
            return
        }
        guard let pane = panes[provider] else {
            errorMessage = "「\(displayName(provider))」原页不可用"
            return
        }
        guard pane.boundConversationURL != nil else {
            errorMessage = "「\(displayName(provider))」尚未固定本场对话"
            return
        }
        guard pane.openBoundConversation() else {
            errorMessage = "「\(displayName(provider))」的本场对话地址未通过核对"
            return
        }
        resumeSeat(provider)
    }

    /// Accept a manually relayed answer for one seat.
    ///
    /// During the vote stage an explicit stance is mandatory. A `STANCE: …`
    /// marker is accepted as a fallback only when it is the strict marker on
    /// the answer's last non-empty line; it is never invented here.
    ///
    /// `expected` is the snapshot a manual form pinned when it opened. When it
    /// is supplied and no longer matches the current round, nothing is applied:
    /// the caller keeps the draft and shows the error.
    @discardableResult
    func manualAnswer(
        _ provider: String,
        text: String,
        stance: String?,
        expected: ArenaManualTarget? = nil,
        attachmentsConfirmed: Bool = false
    ) -> Bool {
        guard !isReadOnly else {
            errorMessage = "历史回看为只读；新建讨论后才能录入回答"
            return false
        }
        guard let session else {
            errorMessage = "还没有正在进行的讨论"
            return false
        }
        guard currentProviders.contains(provider) else {
            errorMessage = "该席位不在本场讨论中"
            return false
        }
        guard let task = pendingTask(for: provider), let taskID = task.arenaString("id") else {
            errorMessage = "「\(displayName(provider))」当前没有待处理任务"
            return false
        }
        if let expected {
            guard expected.provider == provider,
                  let sessionID = session.arenaString("id"),
                  expected.sessionID == sessionID,
                  expected.taskID == taskID else {
                errorMessage = "这一轮已经变化（场次或待处理任务不同），草稿未提交；请关闭后按当前轮重新录入"
                return false
            }
            guard expected.stage == stageKey, expected.round == currentRound else {
                errorMessage = "讨论已进入新阶段或新一轮，草稿未提交；请关闭后按当前轮重新录入"
                return false
            }
            if expected.stage == "vote", task.arenaInt("version") != expected.version {
                errorMessage = "候选版本已经变化，草稿未提交；请核对当前候选后再表态"
                return false
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "回答不能为空；未完成的片段不会被保存"
            return false
        }

        var payload: [String: Any] = [
            "taskId": taskID,
            "text": trimmed,
            "stage": stageKey,
            "round": currentRound,
        ]
        if requiresManualAttachmentConfirmation(for: provider) {
            guard attachmentsConfirmed else {
                errorMessage = "请先在本席原页核对本轮提问与全部附件"
                return false
            }
            payload["attachmentReceipt"] = task.arenaString("attachmentReceipt") ?? "manual"
        }
        var stanceLabelText: String?
        if stageKey == "vote" {
            let resolved = stance.flatMap(Self.normalizeStance)
                ?? Self.parseStance(trimmed)
            guard let resolved else {
                errorMessage = "表态需要明确立场：同意、有条件同意或反对"
                return false
            }
            payload["stance"] = resolved
            if let version = task.arenaInt("version") {
                payload["version"] = version
            }
            stanceLabelText = Self.stanceDisplay(resolved)
        }

        do {
            self.session = try engine.apply(session: session, action: "answer", payload: payload)
        } catch {
            errorMessage = "回答未采用：\(error.localizedDescription)"
            return false
        }

        // The user explicitly checked the opening materials in this pane.
        // Later automatic rounds must stay in this same conversation.
        if attachmentsConfirmed, payload["attachmentReceipt"] != nil, let pane = panes[provider],
           pane.boundConversationURL == nil, let url = pane.currentURL {
            _ = pane.restoreConversationBinding(url)
        }
        blockedTasks.remove(taskID)
        previews[provider] = nil
        errorMessage = ""
        refreshStage()
        let saved = persist()
        markIdleSeats()
        if let label = stanceLabelText {
            setState(provider, .answered, "已表态：\(label)")
        } else {
            setState(provider, .answered, "已提交回答")
        }
        emitSavedAnswerSignal(provider: provider, taskID: taskID, saved: saved)
        return true
    }

    /// The snapshot a manual form must pin while it is open. `nil` means the
    /// seat has no pending task right now, so the form must not pretend it can
    /// save into a later round.
    func manualTarget(for provider: String) -> ArenaManualTarget? {
        guard !isReadOnly,
              let session,
              let sessionID = session.arenaString("id"),
              currentProviders.contains(provider),
              let task = pendingTask(for: provider),
              let taskID = task.arenaString("id") else {
            return nil
        }
        return ArenaManualTarget(
            provider: provider,
            sessionID: sessionID,
            taskID: taskID,
            stage: stageKey,
            round: currentRound,
            version: task.arenaInt("version")
        )
    }

    /// Which seat actions the current state really allows. Every menu item is
    /// bound to one of these flags instead of "enabled whenever running".
    func controls(for provider: String) -> ArenaSeatControls {
        guard session != nil, !isReadOnly, stageKey != "done",
              currentProviders.contains(provider) else {
            return .none
        }
        let pending = pendingTask(for: provider)
        let pendingID = pending?.arenaString("id")
        let isManual = manualProviders.contains(provider)
        let isBlocked = pendingID.map { blockedTasks.contains($0) } ?? false
        return ArenaSeatControls(
            canTakeOver: !isManual || verificationProviders.contains(provider),
            canResume: (isManual || isBlocked) && pending != nil,
            canBackfill: pending != nil,
            canSkip: pending != nil,
            canOpenHome: isManual || isBlocked
        )
    }

    /// Starting text for the non-modal backfill panel. Only this round's saved
    /// answer or the latest preview is offered; a previous round's answer is
    /// never pasted into a new pending round.
    func backfillPrefill(for provider: String) -> ArenaBackfillPrefill {
        let answer = currentTasks
            .last(where: { $0.arenaString("provider") == provider })?
            .arenaString("answer")
        return Self.backfillPrefill(currentAnswer: answer, preview: previews[provider])
    }

    /// The one local action a blocked seat card may offer, or `nil`.
    ///
    /// This is deliberately narrower than the seat menu: it appears only for a
    /// blocked, non-manual, non-paused seat in a running discussion, and only
    /// when the persisted intent proves the action is safe. Manual takeover,
    /// paused, done, read-only history and every other seat keep their existing
    /// menus and behaviour.
    ///
    /// A visible conversation-mismatch banner already owns the next step (return
    /// to the saved conversation); the seat card must not add a competing CTA.
    func localAction(for provider: String) -> ArenaSeatLocalAction? {
        guard !isReadOnly, !isPaused, stageKey != "done",
              currentProviders.contains(provider),
              !manualProviders.contains(provider),
              let target = manualTarget(for: provider),
              blockedTasks.contains(target.taskID) else {
            return nil
        }
        if let pane = panes[provider], pane.boundConversationURL != nil,
           pane.conversationMismatch() != nil {
            return nil
        }
        let controls = controls(for: provider)
        guard controls.canResume else { return nil }
        guard let kind = Self.seatLocalActionKind(
            intentPhase: intents[target.taskID]?.phase,
            hasCompletePreview: previews[provider]?.isComplete == true,
            canBackfill: controls.canBackfill
        ) else {
            return nil
        }
        return ArenaSeatLocalAction(kind: kind, target: target)
    }

    /// Pure safety rule for `localAction(for:)`. `.readOnlyCheck` is returned
    /// only for intent phases whose resume path cannot submit. A complete answer
    /// the engine refused gets the confirmed backfill action because reading
    /// again returns the same refusal. A `.prepared` or missing intent has no
    /// truthful local action: the existing seat menu keeps takeover, backfill
    /// and skip, and a read-only label would be false.
    nonisolated static func seatLocalActionKind(
        intentPhase: ArenaDeliveryIntent.Phase?,
        hasCompletePreview: Bool,
        canBackfill: Bool
    ) -> ArenaSeatLocalAction.Kind? {
        if hasCompletePreview {
            return canBackfill ? .verifyAndBackfill : nil
        }
        switch intentPhase {
        case .submitted, .inflight, .uncertain:
            return .readOnlyCheck
        case .prepared, .none:
            return nil
        }
    }

    /// Skip this seat's current task. A late answer is not accepted into the
    /// skipped round; the report keeps the skip as an absence.
    func skip(_ provider: String) {
        guard !isReadOnly else {
            errorMessage = "历史回看为只读；新建讨论后才能跳过"
            return
        }
        guard let session else {
            errorMessage = "还没有正在进行的讨论"
            return
        }
        guard let task = pendingTask(for: provider), let taskID = task.arenaString("id") else {
            errorMessage = "「\(displayName(provider))」当前没有待处理任务"
            return
        }
        do {
            self.session = try engine.apply(
                session: session,
                action: "skip",
                payload: ["taskId": taskID]
            )
        } catch {
            errorMessage = "无法跳过：\(error.localizedDescription)"
            return
        }
        blockedTasks.remove(taskID)
        workers[taskID]?.cancel()
        workers[taskID] = nil
        previews[provider] = nil
        setState(provider, .skipped, "已跳过")
        refreshStage()
        persist()
        markIdleSeats()
    }

    // MARK: History

    /// Open a saved discussion for read-only review. This never re-creates a
    /// delivery loop and never opens or sends to a site.
    /// Open a saved discussion for read-only review. This never opens a page,
    /// re-creates a delivery loop or sends anything. The shared restore path is
    /// used in conservative mode: every pending seat, including one whose task
    /// was never sent, waits for manual verification.
    func openHistory(_ id: String) {
        guard let saved = loadSavedSession(id: id) else {
            errorMessage = "找不到该历史场次，或记录已损坏"
            return
        }
        stopRunningWork()
        installRestored(saved, mode: .manualVerification, readOnly: true)
        for provider in saved.participants {
            _ = ensurePane(for: provider)
        }
        historyResumeID = saved.stage == "done" ? nil : id
        errorMessage = ""
        recoveryNotice = "历史回看为只读：不会打开原页、不会重发，也不能修改回答。"
        refreshStage()
    }

    /// Clear the workbench for a fresh question.
    func newDiscussion() {
        stopRunningWork()
        session = nil
        currentID = nil
        question = ""
        draftAttachments.removeAll()
        createdAt = 0
        intents.removeAll()
        manualProviders.removeAll()
        verificationProviders.removeAll()
        blockedTasks.removeAll()
        previews.removeAll()
        seatStates.removeAll()
        readRecoveryStalls.removeAll()
        isReadOnly = false
        isRecovering = false
        isPaused = false
        storageFailed = false
        recoveryNotice = ""
        errorMessage = ""
        historyResumeID = nil
        stageKey = ""
        stageLabel = "尚未开始"
        completionTracker.reset()
        engine.store.setCurrent(nil)
        refreshHistoryList()
    }

    // MARK: - Dispatch

    private func startDispatcher(token: UUID) {
        dispatcher?.cancel()
        dispatcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if token != self.runToken || self.session == nil || self.isReadOnly {
                    return
                }
                if self.stageKey == "done" {
                    return
                }
                if !self.isPaused && !self.storageFailed {
                    self.dispatchPending(token: token)
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    private func dispatchPending(token: UUID) {
        for task in currentTasks {
            guard task.arenaString("status") == "pending" else { continue }
            guard let taskID = task.arenaString("id"),
                  let provider = task.arenaString("provider") else { continue }

            if manualProviders.contains(provider) {
                setManualWaitingState(provider, task: task)
                continue
            }
            if blockedTasks.contains(taskID) {
                continue
            }
            if workers[taskID] != nil {
                continue
            }
            // A task whose submit may already have happened is dispatched too:
            // `runSeat` only re-checks it with `read` and never clicks again.
            launchWorker(provider: provider, task: task, token: token)
        }
    }

    private func launchWorker(provider: String, task: [String: Any], token: UUID) {
        guard let taskID = task.arenaString("id") else { return }
        workers[taskID] = Task { [weak self] in
            guard let self else { return }
            await self.runSeat(provider: provider, task: task, token: token)
            // A worker of a replaced discussion must not erase the slot of the
            // current discussion's worker for the same (re-used) task id.
            if token == self.runToken {
                self.workers[taskID] = nil
            }
        }
    }

    private func setManualWaitingState(_ provider: String, task: [String: Any]) {
        if verificationProviders.contains(provider) {
            let state = Self.restoredManualState(phase: intents[task.arenaString("id") ?? ""]?.phase)
            setState(provider, state.kind, state.detail)
        } else {
            setState(provider, .takenOver, "已接管；核对原页后可从本席菜单提交补录")
        }
    }

    private func runSeat(provider: String, task: [String: Any], token: UUID) async {
        guard token == runToken, !isReadOnly, !isPaused else { return }
        guard let taskID = task.arenaString("id"),
              let prompt = task.arenaString("prompt"),
              !prompt.isEmpty else { return }

        let config: ArenaSiteConfig
        do {
            config = try engine.config(for: provider)
        } catch {
            setState(provider, .needsAction, "需要你处理：\(error.localizedDescription)")
            return
        }
        guard let pane = panes[provider] else {
            setState(provider, .needsAction, "需要你处理：原页不可用")
            return
        }
        if manualProviders.contains(provider) {
            setState(provider, .takenOver, "已接管，等待你核对原页")
            return
        }

        if stageKey != "independent", !sessionAttachments.isEmpty, pane.boundConversationURL == nil {
            blockedTasks.insert(taskID)
            setState(provider, .needsAction, "无法确认仍在接收首轮附件的对话，请核对原页并手动接管")
            return
        }
        if stageKey == "independent" {
            let materials = sessionAttachments
            let ids = materials.compactMap { $0.arenaString("id") }
            guard materials.count == ids.count, ids == task.arenaStringArray("attachmentIDs"),
                  materials.allSatisfy({ ["image", "text"].contains($0.arenaString("kind") ?? "") }) else {
                blockedTasks.insert(taskID)
                setState(provider, .needsAction, "首轮附件清单不完整，请核对本场记录")
                return
            }
        }
        let canRead = await ensureSubmitted(
            provider: provider,
            task: task,
            taskID: taskID,
            prompt: prompt,
            config: config,
            pane: pane,
            token: token
        )
        guard canRead else { return }
        await pollAnswer(
            provider: provider,
            task: task,
            taskID: taskID,
            config: config,
            pane: pane,
            token: token
        )
    }

    private var openingImages: [[String: Any]] {
        guard stageKey == "independent" else { return [] }
        return sessionAttachments.filter { $0.arenaString("kind") == "image" }
    }

    private var openingImageNames: [String] { openingImages.compactMap { $0.arenaString("name") } }

    /// Reads retain the ordered manifest and verified pixel fingerprints. Only
    /// the preparation command receives the source file bytes.
    private func withImageEvidence(_ message: [String: Any]) -> [String: Any] {
        let names = openingImageNames
        guard !names.isEmpty else { return message }
        var scoped = message
        scoped["imageNames"] = names
        if let taskID = message.arenaString("taskId"), let pixels = intents[taskID]?.imagePixelDigests {
            scoped["imagePixels"] = pixels
        }
        return scoped
    }

    nonisolated static func preparedImagePixels(_ raw: Any?, count: Int) throws -> [String]? {
        guard let raw else { return nil }
        guard let pixels = raw as? [String], pixels.count == count,
              pixels.allSatisfy({ hash in
                  hash.isEmpty || (hash.utf8.count == 64 &&
                      hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
              }) else { throw ArenaEngineError("原页返回的图片像素摘要与附件清单不符") }
        return pixels
    }

    private func newIntent(taskID: String, prompt: String) -> ArenaDeliveryIntent {
        ArenaDeliveryIntent(taskId: taskID, prompt: prompt, stage: stageKey, round: currentRound,
                            phase: .prepared, preparedAt: Self.nowMillis(), submittedAt: nil, pageURL: nil)
    }

    /// Persist the upload attempt *before* passing any bytes to the page.
    /// After a restart the final submit can only use a previously prepared,
    /// site/task-owned composer. A missing proof requires manual takeover.
    private func prepareOpeningImages(
        provider: String, taskID: String, prompt: String, config: ArenaSiteConfig,
        pane: SitePane, token: UUID, knownDraftDigests: [String]
    ) async -> Bool {
        let images = openingImages
        guard !images.isEmpty else { return true }
        guard await waitWhilePaused(token), callbackIsCurrent(token: token, taskID: taskID, provider: provider),
              let currentID else { return false }
        var intent = intents[taskID] ?? newIntent(taskID: taskID, prompt: prompt)
        if intent.imagePreparationStarted == true { return true }

        do {
            var message = engine.driverMessage(kind: "submit", taskID: taskID, prompt: prompt,
                                              knownDraftDigests: knownDraftDigests, config: config)
            message["images"] = try images.map { image -> [String: String] in
                guard let name = image.arenaString("name"), let mediaType = image.arenaString("mediaType") else {
                    throw ArenaEngineError("本场图片信息不完整")
                }
                let data = try engine.store.attachmentData(sessionID: currentID, attachment: image)
                return ["name": name, "mediaType": mediaType, "base64": data.base64EncodedString()]
            }
            let names = openingImageNames
            message["prepareImagesOnly"] = true
            intent.imagePreparationStarted = true
            intents[taskID] = intent
            guard persist() else {
                intents[taskID]?.imagePreparationStarted = nil
                throw ArenaEngineError("未能保存附件投递记录，未开始上传")
            }
            setState(provider, .sending, "正在原页添加并核对图片…")
            let result = try await pane.command(message)
            guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else { return false }
            let detail = result["detail"] as? [String: Any]
            guard result.arenaString("status") == "attachments-ready",
                  detail?["readyImageNames"] as? [String] == names else {
                if detail?.arenaBool("uploadAttempted") == false {
                    // A driver refusal before handing any file to the website
                    // permits an explicit retry after the user resolves it.
                    intents[taskID]?.imagePreparationStarted = nil
                    persist()
                }
                throw ArenaEngineError(attachmentProblem(result, fallback: "attachment-not-ready"))
            }
            if let pixels = try Self.preparedImagePixels(detail?["readyImagePixels"], count: names.count) {
                intents[taskID]?.imagePixelDigests = pixels
                guard persist() else { throw ArenaEngineError("无法保存图片像素核对记录") }
            }
            return true
        } catch {
            guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else { return false }
            blockedTasks.insert(taskID)
            setState(provider, .needsAction, "图片待核对：\(Self.short(error.localizedDescription))")
            return false
        }
    }

    private func attachmentProblem(_ response: [String: Any], fallback: String) -> String {
        let message = Self.friendly(errorCode: response.arenaString("error") ?? fallback)
        let detail = response["detail"] as? [String: Any]
        let reported = detail?.arenaStringArray("missingImageNames") ?? []
        let missing = openingImageNames.filter { reported.contains($0) }
        return missing.isEmpty ? message : message + "（待核对：" + missing.joined(separator: "、") + "）"
    }

    /// Called only for a verified user turn. A sent message containing the
    /// prompt alone cannot establish receipt of separately uploaded images.
    private func confirmOpeningMaterials(taskID: String, response: [String: Any]) throws {
        guard stageKey == "independent", !sessionAttachments.isEmpty else { return }
        let names = openingImageNames
        let detail = response["detail"] as? [String: Any]
        guard detail?.arenaBool("userTurnVerified") == true else {
            throw ArenaEngineError("原页尚未确认含附件的本轮提问")
        }
        guard names.isEmpty || detail?["verifiedImageNames"] as? [String] == names else {
            throw ArenaEngineError(Self.friendly(errorCode: "attachment-receipt-mismatch"))
        }
        guard let session, currentTask(taskID)?.arenaString("attachmentReceipt") != "verified" else { return }
        self.session = try engine.apply(session: session, action: "attachmentReceipt",
                                       payload: ["taskId": taskID, "attachmentReceipt": "verified"])
        intents[taskID]?.attachmentReceipt = "verified"
        guard persist() else { throw ArenaEngineError("附件回执未能保存") }
    }

    // MARK: Submit

    private func ensureSubmitted(
        provider: String,
        task: [String: Any],
        taskID: String,
        prompt: String,
        config: ArenaSiteConfig,
        pane: SitePane,
        token: UUID
    ) async -> Bool {
        if let intent = intents[taskID] {
            switch intent.phase {
            case .submitted:
                setState(provider, .generating, "继续读取本轮回答…")
                return true
            case .inflight, .uncertain:
                // A previous click may have reached the page. Re-check it with
                // the read-only `read` command; never submit again.
                return await adoptPossiblySent(
                    provider: provider,
                    task: task,
                    taskID: taskID,
                    config: config,
                    pane: pane,
                    token: token
                )
            case .prepared:
                // A relaunched WKWebView may still be navigating. Probe before
                // claiming a new submit attempt, just as for a fresh task.
                guard await probeSeat(provider: provider, taskID: taskID, config: config,
                                      pane: pane, token: token) != nil else { return false }
                if intents[taskID]?.phase == .submitted { return true }
            }
        } else {
            guard await probeSeat(
                provider: provider,
                taskID: taskID,
                config: config,
                pane: pane,
                token: token
            ) != nil else {
                return false
            }
            guard token == runToken, !isReadOnly, !manualProviders.contains(provider) else {
                return false
            }
            if let known = intents[taskID], known.phase == .submitted {
                return true
            }
        }

        let knownDraftDigests = stageKey == "independent" && pane.boundConversationURL == nil
            ? engine.knownDraftDigests(
                provider: provider,
                previousSessionIDs: historyList.map(\.id).filter { $0 != currentID }
            )
            : []
        guard await prepareOpeningImages(provider: provider, taskID: taskID, prompt: prompt, config: config,
                                         pane: pane, token: token, knownDraftDigests: knownDraftDigests) else {
            return false
        }
        var attempt = 0
        while attempt < 8 {
            guard await waitWhilePaused(token) else { return false }
            if manualProviders.contains(provider) {
                setState(provider, .takenOver, "已接管，等待你核对原页")
                return false
            }
            guard isCurrentPending(taskID) else { return false }

            var intent = intents[taskID] ?? newIntent(taskID: taskID, prompt: prompt)
            intent.phase = .inflight
            intent.pageURL = pane.boundConversationURL?.absoluteString
            intents[taskID] = intent
            // The intent must be durable before the click. If it is not, the
            // submit command must not run at all: after a crash nobody could
            // tell whether this task was already sent.
            guard persist() else {
                var safe = intent
                safe.phase = .prepared
                safe.pageURL = nil
                intents[taskID] = safe
                blockedTasks.insert(taskID)
                setState(provider, .needsAction, "本地保存失败，未发送；请先处理存储")
                return false
            }
            setState(provider, .sending, "填入本轮提示并发送…")

            let response: [String: Any]
            do {
                response = try await pane.command(
                    withImageEvidence(engine.driverMessage(
                        kind: "submit",
                        taskID: taskID,
                        prompt: intent.prompt,
                        knownDraftDigests: knownDraftDigests,
                        config: config
                    ))
                )
            } catch {
                // The click may have happened. Only record the outcome for the
                // discussion and seat that are still current.
                guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
                    return false
                }
                // 原页被换到同站别的对话：Swift 在发命令前就拒绝了，什么都没发出。
                // 这里是明确的点击前状态：先把意图退回 prepared（持久化），再
                // 有界地自动回到已保存、已核验的对话；回不去就转人工。
                if let paneError = error as? SitePaneError, paneError.isConversationChanged {
                    var safe = intent
                    safe.phase = .prepared
                    safe.pageURL = nil
                    intents[taskID] = safe
                    persist()
                    switch await recoverConversationDrift(
                        provider: provider,
                        taskID: taskID,
                        pane: pane,
                        token: token,
                        phase: .beforeSend
                    ) {
                    case .recovered:
                        continue
                    case .stopped, .blocked:
                        return false
                    }
                }
                // Outcome unknown: never retry.
                intent.phase = .uncertain
                intents[taskID] = intent
                persist()
                blockedTasks.insert(taskID)
                setState(provider, .needsAction, "发送结果待确认：\(Self.short(error.localizedDescription))")
                return await adoptPossiblySent(
                    provider: provider,
                    task: task,
                    taskID: taskID,
                    config: config,
                    pane: pane,
                    token: token
                )
            }

            // A late answer must not leak into another discussion, another
            // task, or a seat the user took over while the command was out.
            guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
                return false
            }

            // 已核验本轮用户消息后，把本席真实会话的 origin+path 固定下来，
            // 供下一轮发送前的地址核对与持久化恢复。
            let status = response.arenaString("status") ?? ""
            let turnVerified = (response["detail"] as? [String: Any])?["userTurnVerified"] as? Bool == true
            if status == "submitted" || (status == "pending" && turnVerified) || status == "done" {
                do {
                    try confirmOpeningMaterials(taskID: taskID, response: response)
                } catch {
                    intents[taskID]?.phase = .uncertain
                    persist()
                    blockedTasks.insert(taskID)
                    setState(provider, .needsAction, "本轮已尝试发送，\(error.localizedDescription)")
                    return false
                }
                persistVerifiedBinding(pane, from: response, taskID: taskID)
                intent.attachmentReceipt = intents[taskID]?.attachmentReceipt
                intent.phase = .submitted
                intent.submittedAt = Self.nowMillis()
                intent.pageURL = pane.boundConversationURL?.absoluteString ?? intent.pageURL
                intents[taskID] = intent
                let receiptSaved = persist()
                blockedTasks.remove(taskID)
                if receiptSaved {
                    emitReceiptSignal(provider: provider, taskID: taskID, turnVerified: turnVerified)
                }
                if status == "done",
                   let text = response.arenaString("text"),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    deliver(provider: provider, task: task, text: text)
                    return false
                }
                setState(provider, .generating,
                         turnVerified ? "原页已核验本轮提问，等待回答…" : "已发送，等待回答…")
                return true
            }

            let code = response.arenaString("error") ?? "unknown"
            let detail = response["detail"] as? [String: Any]
            // Only the driver's explicit pre-click statement may put this task
            // back into `.prepared` for another click. Both fields are required:
            // `history-changed` / `user-turn-mismatch` and any other unknown
            // reply may already have clicked.
            let explicitlyPreClick = (detail?["clickAttempted"] as? Bool) == false
                && (detail?["phase"] as? String) == "pre-click"
            // The driver's address check can answer at `authorize`, `pre-fill`
            // or `pre-click`. All three carry clickAttempted == false; only
            // those may authorise an automatic return. A post-click
            // conversation-changed (if one ever appears) stays uncertain.
            let conversationDeniedBeforeSend = (detail?["clickAttempted"] as? Bool) == false
                && ["authorize", "pre-fill", "pre-click"].contains(detail?["phase"] as? String ?? "")

            // The driver's own conversation guard can answer at authorize,
            // pre-fill or pre-click, always with clickAttempted == false. The
            // page is on another conversation and nothing was filled or
            // clicked: return to the saved conversation if it is safe.
            if code == "conversation-changed", conversationDeniedBeforeSend {
                var safe = intent
                safe.phase = .prepared
                safe.pageURL = nil
                intents[taskID] = safe
                persist()
                switch await recoverConversationDrift(
                    provider: provider,
                    taskID: taskID,
                    pane: pane,
                    token: token,
                    phase: .beforeSend
                ) {
                case .recovered:
                    continue
                case .stopped, .blocked:
                    return false
                }
            }

            // A partial upload, a changed image draft or a missing receipt
            // cannot authorize another upload, reload or blind click.
            if code.hasPrefix("attachment-") || (!openingImages.isEmpty && explicitlyPreClick) {
                intent.phase = explicitlyPreClick ? .prepared : .uncertain
                intents[taskID] = intent
                persist()
                blockedTasks.insert(taskID)
                setState(provider, .needsAction, attachmentProblem(response, fallback: code))
                return false
            }

            switch code {
            case "send-pending" where explicitlyPreClick:
                if detail?["composerFilled"] as? Bool == true { intent.composerFilled = true }
                intent.phase = .prepared
                intents[taskID] = intent
                persist()
                setState(provider, .sending, Self.preClickStatus(detail))
                if case .blocked = await repairPreClickSendIfNeeded(
                    provider: provider,
                    taskID: taskID,
                    config: config,
                    pane: pane,
                    token: token,
                    prompt: intent.prompt,
                    detail: detail
                ) { return false }
                attempt += 1
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            case "prompt-already-sent":
                // This round's prompt is already on the page; read only.
                intent.phase = .submitted
                intent.submittedAt = Self.nowMillis()
                intents[taskID] = intent
                persist()
                setState(provider, .generating, "本轮提问已在原页，只读核对…")
                return true
            default:
                if explicitlyPreClick {
                    // The page says no click happened; the button may mount.
                    intent.phase = .prepared
                    intents[taskID] = intent
                    persist()
                    setState(provider, .sending, Self.preClickStatus(detail))
                    if case .blocked = await repairPreClickSendIfNeeded(
                        provider: provider,
                        taskID: taskID,
                        config: config,
                        pane: pane,
                        token: token,
                        prompt: intent.prompt,
                        detail: detail
                    ) { return false }
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                } else if code == "draft-conflict" {
                    // An explicit input conflict that the driver rejected before
                    // any click. Never retried automatically; a human decides.
                    intent.phase = .prepared
                    intents[taskID] = intent
                    persist()
                    blockedTasks.insert(taskID)
                    setState(provider, .needsAction, "需要你处理：\(Self.friendly(errorCode: code))")
                    return false
                } else {
                    // Unknown or post-click failure: the submit may already have
                    // happened. Only `read` may confirm it from here.
                    intent.phase = .uncertain
                    intents[taskID] = intent
                    persist()
                    blockedTasks.insert(taskID)
                    setState(provider, .needsAction, "发送结果待确认，只读核对原页（不会重发）…")
                    return await adoptPossiblySent(
                        provider: provider,
                        task: task,
                        taskID: taskID,
                        config: config,
                        pane: pane,
                        token: token
                    )
                }
            }
        }

        blockedTasks.insert(taskID)
        setState(provider, .needsAction, "发送控件长时间未就绪；原页可能已填入本轮提示，请核对")
        return false
    }

    /// Probe the page before the first submit. `probe` never fills or clicks, so
    /// a slow-starting real site may be retried inside a bounded window; a task
    /// the page already remembers is adopted for read-only reading instead of
    /// being sent again.
    private func probeSeat(
        provider: String,
        taskID: String,
        config: ArenaSiteConfig,
        pane: SitePane,
        token: UUID
    ) async -> [String: Any]? {
        let window = engine.fixtureBase == nil
            ? Self.realProbeWindowSeconds
            : Self.fixtureProbeWindowSeconds
        let deadline = Date().addingTimeInterval(window)
        let startedAt = Date()
        var attempt = 0
        var attemptedProbeRecovery = false

        while true {
            guard !Task.isCancelled else { return nil }
            guard await waitWhilePaused(token) else { return nil }
            if manualProviders.contains(provider) {
                setState(provider, .takenOver, "已接管，等待你核对原页")
                return nil
            }
            guard isCurrentPending(taskID) else { return nil }
            setState(provider, .sending, attempt == 0 ? "检查原页…" : "等待原页就绪…")
            do {
                let response = try await pane.command(
                    withImageEvidence(engine.driverMessage(
                        kind: "probe",
                        taskID: taskID,
                        prompt: nil,
                        config: config
                    ))
                )
                guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
                    return nil
                }
                let status = response.arenaString("status") ?? ""
                if status == "ready" {
                    if let detail = response["detail"] as? [String: Any],
                       let known = detail["knownTask"] as? [String: Any],
                       ((known.arenaString("status") == "submitted" && known.arenaBool("verified") == true)
                        || known.arenaString("status") == "done") {
                        // The page still remembers this task id: adopt it and
                        // read only. Never submit a second time.
                        var intent = intents[taskID] ?? newIntent(
                            taskID: taskID, prompt: currentTask(taskID)?.arenaString("prompt") ?? ""
                        )
                        intent.phase = .submitted
                        intent.submittedAt = intent.submittedAt ?? Self.nowMillis()
                        intent.pageURL = pane.boundConversationURL?.absoluteString ?? intent.pageURL
                        intents[taskID] = intent
                        persist()
                        setState(provider, .generating, "已发送，只读核对中…")
                    }
                    return response
                }
                let code = response.arenaString("error") ?? status
                // The composer of a real site can mount well after the page
                // reports ready. These codes are all pre-click states.
                if Date() < deadline, Self.isTransientProbeFailure(code) {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                }
                blockedTasks.insert(taskID)
                setState(provider, .needsAction, "需要你处理：\(Self.friendly(errorCode: code))")
                return nil
            } catch {
                guard token == runToken, !isReadOnly else { return nil }
                // 本轮会话被换走：先尝试一次有界回到已保存对话，不发送。
                if let paneError = error as? SitePaneError, paneError.isConversationChanged {
                    switch await recoverConversationDrift(
                        provider: provider,
                        taskID: taskID,
                        pane: pane,
                        token: token,
                        phase: .beforeSend
                    ) {
                    case .recovered:
                        attempt += 1
                        continue
                    case .stopped, .blocked:
                        return nil
                    }
                }
                // 冷启动恢复后，WK 内容进程终止或一次瞬时网络导航失败会让
                // 文档永远等不到 didFinish。此时允许一次回到本席原页的导航；
                // 助手只在确认没有可用文档时才导航，且从不填写或点击。
                // 暂停、接管、离线、证书/认证页和地址不符都在这里或助手里排除。
                if !attemptedProbeRecovery,
                   Date() < deadline,
                   Date().timeIntervalSince(startedAt) >= Self.probeRecoveryDelaySeconds,
                   let paneError = error as? SitePaneError,
                   case .documentNotReady = paneError,
                   !isPaused,
                   !manualProviders.contains(provider),
                   isCurrentPending(taskID) {
                    attemptedProbeRecovery = true
                    let recovery = await pane.recoverStalledProbeDocument {
                        !Task.isCancelled && !self.isPaused && self.callbackIsCurrent(
                            token: token, taskID: taskID, provider: provider
                        )
                    }
                    switch recovery {
                    case .flagsCorrected:
                        // 文档其实已经 settled，只是 WebKit 标志过期：稍等后
                        // 重新 probe，不导航、不点击。
                        setState(provider, .sending, "原页已就绪，继续核对…")
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        continue
                    case .navigated:
                        setState(provider, .sending, "原页未就绪，已自动回到本席原页一次；继续核对，不会点击…")
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        continue
                    case .declined:
                        break
                    }
                }
                if Date() < deadline, !Task.isCancelled {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                }
                blockedTasks.insert(taskID)
                setState(provider, .needsAction, "需要你处理：原页命令失败（\(Self.short(error.localizedDescription))）")
                return nil
            }
        }
    }

    // MARK: Read

    private func pollAnswer(
        provider: String,
        task: [String: Any],
        taskID: String,
        config: ArenaSiteConfig,
        pane: SitePane,
        token: UUID
    ) async {
        let optionMs = config.options.arenaDouble("pendingTimeoutMs") ?? 600_000
        let timeout = min(max(optionMs / 1000, 30), 900)
        let deadline = Date().addingTimeInterval(timeout)
        var showedSubmitted = false
        var consecutiveErrors = 0

        poll: while true {
            if token != runToken || isReadOnly { return }
            if manualProviders.contains(provider) {
                setState(provider, .takenOver, "已接管，等待你核对原页")
                return
            }
            guard await waitWhilePaused(token) else { return }
            guard isCurrentPending(taskID) else { return }

            do {
                // A read may carry the exact persisted prompt so a driver that
                // lost its in-memory record (page reload, new process, seat
                // reopened) can rebuild a read-only record instead of stopping
                // for a human. The prompt is only present when this app really
                // persisted a delivery intent; `prepared` never counts.
                let recoveryPrompt = ArenaEngine.readRecoveryPrompt(
                    phase: intents[taskID]?.phase,
                    prompt: intents[taskID]?.prompt
                )
                let response = try await pane.command(
                    withImageEvidence(engine.driverMessage(
                        kind: "read",
                        taskID: taskID,
                        prompt: nil,
                        verifiedReadPrompt: recoveryPrompt,
                        config: config
                    ))
                )
                // Ignore a late read that belongs to a replaced discussion, a
                // finished task, or a seat the user took over meanwhile.
                guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
                    return
                }
                let detail = response["detail"] as? [String: Any]
                if response.arenaString("status") == "done" || detail?.arenaBool("userTurnVerified") == true {
                    do {
                        try confirmOpeningMaterials(taskID: taskID, response: response)
                    } catch {
                        blockedTasks.insert(taskID)
                        setState(provider, .needsAction, error.localizedDescription)
                        return
                    }
                }
                persistVerifiedBinding(pane, from: response, taskID: taskID)
                consecutiveErrors = 0
                let status = response.arenaString("status") ?? ""
                let code = response.arenaString("error") ?? ""

                if code == "conversation-changed" {
                    switch await recoverConversationDrift(
                        provider: provider,
                        taskID: taskID,
                        pane: pane,
                        token: token,
                        phase: .reading
                    ) {
                    case .recovered:
                        consecutiveErrors = 0
                        continue poll
                    case .stopped, .blocked:
                        return
                    }
                }

                if code.hasPrefix("attachment-") {
                    blockedTasks.insert(taskID)
                    setState(provider, .needsAction, attachmentProblem(response, fallback: code))
                    return
                }
                switch status {
                case "done":
                    let text = (response.arenaString("text") ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        blockedTasks.insert(taskID)
                        setState(provider, .needsAction, "回答为空，请核对原页")
                        return
                    }
                    previews[provider] = nil
                    deliver(provider: provider, task: task, text: text)
                    return
                case "pending":
                    let detail = response["detail"] as? [String: Any]
                    if let preview = detail?["preview"] as? [String: Any],
                       let text = preview.arenaString("text") {
                        previews[provider] = ArenaPreview(text: text, isComplete: false)
                    }
                    let reason = detail?.arenaString("reason")
                    let stalledFor = noteReadProgress(taskID: taskID, detail: detail)
                    let outcome = await recoverStalledReadIfNeeded(
                        provider: provider,
                        taskID: taskID,
                        config: config,
                        pane: pane,
                        token: token,
                        detail: detail,
                        stalledFor: stalledFor
                    )
                    switch outcome {
                    case .reloaded:
                        // The helper already set the precise status.
                        break
                    case .held(let text):
                        setState(provider, .generating, text)
                    case .none:
                        let state = Self.pendingReadState(
                            reason: reason,
                            recoveryUsed: intents[taskID]?.reloadAttempted == true
                        )
                        setState(provider, state.kind, state.detail)
                    }
                case "submitted", "ready":
                    if !showedSubmitted {
                        setState(provider, .generating, "已发送，等待回答…")
                        showedSubmitted = true
                    }
                case "unknown":
                    blockedTasks.insert(taskID)
                    if intents[taskID]?.driftReturnAttempted == true,
                       Self.isPostReturnPromptMismatch(code.isEmpty ? "unknown" : code) {
                        setState(provider, .needsAction,
                                 Self.conversationDriftReadFailureMessage(.reading))
                    } else {
                        setState(provider, .needsAction, "需要你核对原页（\(Self.friendly(errorCode: code.isEmpty ? "unknown" : code))）")
                    }
                    return
                default:
                    if code == "document-not-ready" || code == "not-authorized-page" {
                        if !showedSubmitted {
                            setState(provider, .generating, "等待原页就绪…")
                            showedSubmitted = true
                        }
                    } else {
                        blockedTasks.insert(taskID)
                        if intents[taskID]?.driftReturnAttempted == true,
                           Self.isPostReturnPromptMismatch(code) {
                            setState(provider, .needsAction,
                                     Self.conversationDriftReadFailureMessage(.reading))
                        } else {
                            setState(provider, .needsAction, "需要你核对原页：\(Self.friendly(errorCode: code))")
                        }
                        return
                    }
                }
            } catch {
                if let paneError = error as? SitePaneError, paneError.isConversationChanged {
                    switch await recoverConversationDrift(
                        provider: provider,
                        taskID: taskID,
                        pane: pane,
                        token: token,
                        phase: .reading
                    ) {
                    case .recovered:
                        consecutiveErrors = 0
                        continue poll
                    case .stopped, .blocked:
                        return
                    }
                }
                consecutiveErrors += 1
                if Date() >= deadline || consecutiveErrors >= 20 {
                    blockedTasks.insert(taskID)
                    setState(provider, .needsAction, "读取中断，请核对原页（\(Self.short(error.localizedDescription))）")
                    return
                }
                setState(provider, .generating, "读取中断，重试…")
            }

            if Date() >= deadline {
                blockedTasks.insert(taskID)
                setState(provider, .needsAction, "生成超时，请核对原页")
                return
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
    }

    // MARK: Bounded conversation drift return

    /// Why this worker may be away from its saved conversation.
    enum ConversationDriftPhase: Equatable {
        /// Before a submit: nothing has been sent for this task.
        case beforeSend
        /// Reading an already delivered answer.
        case reading
        /// Confirming a submit whose outcome is unknown.
        case verifying
    }

    enum ConversationDriftDecision: Equatable {
        case proceed
        /// Pause, takeover, a replaced discussion or a finished task.
        case stop
        /// The page must not move; a human decides.
        case blocked(String)
    }

    /// The single bounded automatic return policy. It only decides whether the
    /// page may move back to the saved conversation; it never authorises a
    /// click, submit or read-only delivery claim.
    nonisolated static func conversationDriftReturnDecision(
        bound: Bool,
        drifted: Bool,
        alreadyUsed: Bool,
        phase: ArenaDeliveryIntent.Phase?,
        openingImagesPrepared: Bool,
        taskIsCurrent: Bool,
        paused: Bool,
        takenOver: Bool
    ) -> ConversationDriftDecision {
        guard taskIsCurrent, !paused, !takenOver else { return .stop }
        guard bound else {
            return .blocked("本席尚未固定本场对话，不能自动返回。请核对原页或「人工接管」后「文本补录…」。")
        }
        guard drifted else {
            // This helper is only called after the page or the driver reported a
            // conversation change. A nil WebKit mismatch at this point means
            // WebKit and the page driver disagree; never let a worker loop.
            return .blocked(
                "原页地址与网页内容不一致，无法自动恢复。请核对原页，再点「回到本场对话并恢复」。"
            )
        }
        if alreadyUsed {
            return .blocked(
                "已尝试自动恢复，本任务不再自动跳转。请核对原页，再点「回到本场对话并恢复」。"
            )
        }
        if openingImagesPrepared, phase == .prepared || phase == nil {
            return .blocked(
                "首轮图片已放入原页，自动返回会丢失材料。请先核对附件，再点「回到本场对话并恢复」。"
            )
        }
        return .proceed
    }

    nonisolated static func conversationDriftPrefix(_ phase: ConversationDriftPhase) -> String {
        switch phase {
        case .beforeSend: return "原页切到了另一段对话，本轮尚未发送。"
        case .reading: return "本轮提问已发出，网页切到了另一段对话。"
        case .verifying: return "本轮提问可能已发出，网页切到了另一段对话。只核对、不重发。"
        }
    }

    nonisolated static func conversationDriftRecoveredMessage(_ phase: ConversationDriftPhase) -> String {
        switch phase {
        case .beforeSend:
            return conversationDriftPrefix(phase)
                + "已自动回到本场对话，继续发送前核对。"
        case .reading:
            return conversationDriftPrefix(phase)
                + "已自动回到本场对话，继续只读读取。"
        case .verifying:
            return conversationDriftPrefix(phase)
                + "已自动回到本场对话，继续只读核对。"
        }
    }

    nonisolated static func conversationDriftBlockedMessage(
        _ phase: ConversationDriftPhase,
        reason: String
    ) -> String {
        conversationDriftPrefix(phase) + "未自动跳转。" + reason
    }

    nonisolated static func conversationDriftUnreachableMessage(
        _ phase: ConversationDriftPhase,
        reason: String
    ) -> String {
        conversationDriftPrefix(phase)
            + "自动返回未成功（\(reason)）。请点「回到本场对话并恢复」。"
    }

    /// 自动返回后仍未核对到本轮完整提问。这里必须说清下一步，但不暗示重发。
    nonisolated static func conversationDriftReadFailureMessage(
        _ phase: ConversationDriftPhase
    ) -> String {
        switch phase {
        case .beforeSend:
            return "已回到本场对话，但未核对到本轮完整提示。请核对原页；仍不符时用 ⋯「人工接管」和「文本补录…」，不会自动发送。"
        case .reading:
            return "已回到本场对话，但未核对到本轮完整提问。请核对原页；仍不符时用 ⋯「人工接管」和「文本补录…」，不会自动重发。"
        case .verifying:
            return "已回到本场对话，但未核对到本轮完整提问。本轮可能已发出，只核对、不重发；仍不符时用 ⋯「人工接管」和「文本补录…」。"
        }
    }

    nonisolated static func isPostReturnPromptMismatch(_ code: String) -> Bool {
        switch code {
        case "user-turn-mismatch", "history-changed", "task-prompt-mismatch",
             "task-unknown", "page-changed", "recovery-timeout":
            return true
        default:
            return false
        }
    }

    /// Concise, actionable reasons for a protected drift page. No URL is ever
    /// put into the seat header, so a narrow window cannot ellipsize it.
    nonisolated static func conversationDriftSafetyReason(
        _ safety: SitePaneConversationDriftSafety
    ) -> String {
        switch safety {
        case .draft:
            return "当前页有未发送的草稿或附件。请先保存，再点「回到本场对话并恢复」。"
        case .generating:
            return "当前页仍在生成。请等结束后，再点「回到本场对话并恢复」。"
        case .loginBarrier:
            return "当前页停在登录页。请先登录，再点「回到本场对话并恢复」。"
        case .unavailable(let code):
            return "无法核对当前页（\(conversationDriftUnavailableReason(code))）。请核对原页，再点「回到本场对话并恢复」。"
        case .safe:
            return ""
        }
    }

    nonisolated static func conversationDriftUnavailableReason(_ code: String) -> String {
        switch code {
        case "selector-missing": return "原页缺少可核对控件"
        case "document-not-ready": return "原页尚未就绪"
        case "not-authorized-page", "out-of-scope": return "原页地址不可核对"
        case "loginbarrier": return "需要登录"
        default: return "原页状态无法确认"
        }
    }

    private enum ConversationDriftRecovery {
        case recovered
        case stopped
        case blocked
    }

    /// One bounded, read-only return to the saved conversation. Every await is
    /// surrounded by the run token, task, pause and takeover checks; a human
    /// draft, live generation, login barrier or unreadable page stops it.
    private func recoverConversationDrift(
        provider: String,
        taskID: String,
        pane: SitePane,
        token: UUID,
        phase: ConversationDriftPhase
    ) async -> ConversationDriftRecovery {
        guard token == runToken, !isReadOnly else { return .stopped }
        // 同文档换页可能已由本席主动返回 A；这时页面又是本场对话，不要把它
        // 当成无法恢复的漂移，也不要再导航一次。
        if pane.conversationMismatch() == nil, pane.didJustProactivelyReturn() {
            setState(
                provider,
                phase == .beforeSend ? .sending : .generating,
                Self.conversationDriftRecoveredMessage(phase)
            )
            return .recovered
        }
        let decision = Self.conversationDriftReturnDecision(
            bound: pane.boundConversationURL != nil,
            drifted: pane.conversationMismatch() != nil,
            alreadyUsed: intents[taskID]?.driftReturnAttempted == true,
            phase: intents[taskID]?.phase,
            openingImagesPrepared: stageKey == "independent"
                && !openingImages.isEmpty
                && intents[taskID]?.imagePreparationStarted == true,
            taskIsCurrent: isCurrentPending(taskID),
            paused: isPaused,
            takenOver: manualProviders.contains(provider)
        )
        switch decision {
        case .stop:
            return .stopped
        case .blocked(let reason):
            blockedTasks.insert(taskID)
            setState(
                provider,
                .needsAction,
                Self.conversationDriftBlockedMessage(phase, reason: reason)
            )
            return .blocked
        case .proceed:
            break
        }

        // Reserve the one automatic return durably *before* the page moves.
        // Only the flag is added: an existing intent keeps every other field.
        // A task with no intent yet (a drift caught before its first probe) gets
        // a prepared intent, because no click can have happened.
        let priorIntent = intents[taskID]
        guard let prompt = priorIntent?.prompt ?? currentTask(taskID)?.arenaString("prompt"),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            blockedTasks.insert(taskID)
            setState(provider, .needsAction,
                     "无法取得本轮原文，未自动回到本场对话；请核对原页或「人工接管」后「文本补录…」。")
            return .blocked
        }
        var reservation = priorIntent ?? newIntent(taskID: taskID, prompt: prompt)
        reservation.driftReturnAttempted = true
        intents[taskID] = reservation
        guard persist() else {
            if let priorIntent {
                intents[taskID] = priorIntent
            } else {
                intents.removeValue(forKey: taskID)
            }
            blockedTasks.insert(taskID)
            setState(provider, .needsAction,
                     "本地保存失败，未自动回到本场对话；请先处理存储再重试。")
            return .blocked
        }

        let outcome = await pane.returnToBoundConversationIfSafe(taskID: taskID) {
            token == self.runToken
                && !self.isReadOnly
                && !self.isPaused
                && !self.manualProviders.contains(provider)
                && self.isCurrentPending(taskID)
        }
        guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
            return .stopped
        }

        switch outcome {
        case .returned:
            // The page and WebKit must agree after the await. If they do not,
            // keep the task blocked instead of silently looping on reads.
            guard pane.conversationMismatch() == nil else {
                blockedTasks.insert(taskID)
                setState(provider, .needsAction,
                         "已尝试回到本场对话，但原页地址仍不一致。请核对原页，再点「回到本场对话并恢复」。")
                return .blocked
            }
            setState(
                provider,
                phase == .beforeSend ? .sending : .generating,
                Self.conversationDriftRecoveredMessage(phase)
            )
            return .recovered
        case .blocked(let safety):
            blockedTasks.insert(taskID)
            setState(
                provider,
                .needsAction,
                Self.conversationDriftBlockedMessage(
                    phase,
                    reason: Self.conversationDriftSafetyReason(safety)
                )
            )
            return .blocked
        case .unreachable(let reason):
            blockedTasks.insert(taskID)
            setState(
                provider,
                .needsAction,
                Self.conversationDriftUnreachableMessage(phase, reason: reason)
            )
            return .blocked
        case .cancelled, .notDrifted:
            return .stopped
        }
    }

    // MARK: Bounded read-only recovery

    private enum StalledReadOutcome {
        /// Not a candidate (wrong seat, unconfirmed, already used, progress moved,
        /// or the user paused / took over).
        case none
        /// A candidate whose page state (or a reservation that could not be
        /// saved) forbids a reload; keep reading only.
        case held(String)
        /// The one allowed reload was started in this seat's own WKWebView.
        case reloaded
    }

    /// Visible progress only: the preview text/length and the reported partial
    /// length. Elapsed time, `stableMs` and `timedOut` keep growing while the
    /// page is stuck, so they must never count as progress.
    nonisolated static func readProgressFingerprint(_ detail: [String: Any]?) -> String {
        guard let detail else { return "" }
        let preview = detail["preview"] as? [String: Any]
        let text = preview?.arenaString("text") ?? ""
        let chars = preview?.arenaInt("chars") ?? text.count
        let partial = detail.arenaInt("partialChars") ?? 0
        let reason = detail.arenaString("reason") ?? ""
        return "\(reason)|\(chars)|\(partial)|\(text)"
    }

    /// One reload per delivered Gemini task, and only while the page itself has
    /// verified this round's turn, has no active stop control and is still on
    /// the bound conversation. A pending preview is never a completion signal.
    nonisolated static func isStalledReadRecoveryCandidate(
        provider: String,
        phase: ArenaDeliveryIntent.Phase?,
        alreadyUsed: Bool,
        userTurnVerified: Bool,
        stopActive: Bool,
        boundMatchesCurrent: Bool,
        stalledFor: TimeInterval
    ) -> Bool {
        provider == "gemini"
            && phase == .submitted
            && !alreadyUsed
            && userTurnVerified
            && !stopActive
            && boundMatchesCurrent
            && stalledFor >= arenaStalledReadRecoverySeconds
    }

    /// One automatic pre-click send repair per Gemini task. Only the driver's
    /// explicit `pre-click` + `clickAttempted == false` answer with a
    /// `missing`/`hidden` send control counts: a disabled control, a
    /// composer-changed refusal, or any post-click state is not evidence that
    /// reloading this seat's own bound conversation would help.
    nonisolated static func isPreClickReloadCandidate(
        provider: String,
        phase: ArenaDeliveryIntent.Phase?,
        reportedPhase: String?,
        clickAttempted: Bool?,
        reason: String?,
        alreadyReloaded: Bool,
        elapsed: TimeInterval,
        refusals: Int
    ) -> Bool {
        provider == "gemini"
            && phase == .prepared
            && reportedPhase == "pre-click"
            && clickAttempted == false
            && (reason == "missing" || reason == "hidden")
            && !alreadyReloaded
            && (elapsed >= arenaPreClickReloadAfterSeconds
                || refusals >= arenaPreClickReloadAfterRefusals)
    }

    /// A reload may only move a composer that is empty or already holds exactly
    /// this round's complete prompt (as judged by the driver's own `sameText`),
    /// and only while the page shows no live Stop control.
    nonisolated static func isPreClickComposerSafe(
        draftEmpty: Bool,
        matchesExpectedPrompt: Bool,
        stopActive: Bool
    ) -> Bool {
        (draftEmpty || matchesExpectedPrompt) && !stopActive
    }

    nonisolated static func pendingReadStatus(reason: String?, recoveryUsed: Bool) -> String {
        let suffix = recoveryUsed ? "（已试只读重载）" : ""
        switch reason {
        case "completion-signal-missing":
            return "原页文本已停止更新，等待原生完成标记\(suffix)…"
        case "answer-updating":
            return "回答仍在更新\(suffix)…"
        case "awaiting-answer":
            return "等待回答出现\(suffix)…"
        case "generating":
            return "正在生成…"
        default:
            return "继续只读等待原生完成标记\(suffix)…"
        }
    }

    /// A pending read is still generation, even when the text stopped moving or
    /// this seat already used its one read-only reload. It must never look like
    /// a completed answer.
    nonisolated static func pendingReadState(
        reason: String?,
        recoveryUsed: Bool
    ) -> ArenaSeatState {
        ArenaSeatState(
            kind: .generating,
            detail: pendingReadStatus(reason: reason, recoveryUsed: recoveryUsed)
        )
    }

    /// Pure starting-text rule for the backfill panel, testable without a live
    /// web view. Only the current round's answer or preview may be offered.
    nonisolated static func backfillPrefill(
        currentAnswer: String?,
        preview: ArenaPreview?
    ) -> ArenaBackfillPrefill {
        if let answer = currentAnswer?.trimmingCharacters(in: .whitespacesAndNewlines),
           !answer.isEmpty {
            return ArenaBackfillPrefill(text: answer, isPartial: false, isComplete: false)
        }
        if let preview, !preview.text.isEmpty {
            return ArenaBackfillPrefill(
                text: preview.text,
                isPartial: !preview.isComplete,
                isComplete: preview.isComplete
            )
        }
        return ArenaBackfillPrefill(text: "", isPartial: false, isComplete: false)
    }

    /// Track one task's visible progress and return how long the current
    /// fingerprint has been unchanged. A changed fingerprint resets the clock.
    private func noteReadProgress(taskID: String, detail: [String: Any]?) -> TimeInterval {
        let fingerprint = Self.readProgressFingerprint(detail)
        let now = Date()
        if let existing = readRecoveryStalls[taskID], existing.fingerprint == fingerprint {
            return now.timeIntervalSince(existing.since)
        }
        readRecoveryStalls[taskID] = ReadRecoveryStall(fingerprint: fingerprint, since: now)
        return 0
    }

    /// One bounded, read-only recovery for a delivered task whose page stopped
    /// updating. It runs inside this seat's own worker only, so another seat's
    /// dispatch never waits on it. It never fills, clicks or calls `submit`.
    private func recoverStalledReadIfNeeded(
        provider: String,
        taskID: String,
        config: ArenaSiteConfig,
        pane: SitePane,
        token: UUID,
        detail: [String: Any]?,
        stalledFor: TimeInterval
    ) async -> StalledReadOutcome {
        let userTurnVerified = detail?.arenaBool("userTurnVerified") == true
        let reason = detail?.arenaString("reason")
        let boundMatches = pane.boundConversationURL != nil
            && pane.currentURL != nil
            && pane.conversationMismatch() == nil
        guard Self.isStalledReadRecoveryCandidate(
            provider: provider,
            phase: intents[taskID]?.phase,
            alreadyUsed: intents[taskID]?.reloadAttempted == true,
            userTurnVerified: userTurnVerified,
            stopActive: reason == "generating",
            boundMatchesCurrent: boundMatches,
            stalledFor: stalledFor
        ) else { return .none }

        // Re-check the user's control right before touching the page.
        guard token == runToken, !isReadOnly, !isPaused,
              !manualProviders.contains(provider), isCurrentPending(taskID) else {
            return .none
        }

        // The read receipt does not carry the composer, so confirm with the
        // read-only probe: empty composer, no live stop, still the same page.
        let probe: [String: Any]
        do {
            probe = try await pane.command(
                withImageEvidence(engine.driverMessage(kind: "probe", taskID: taskID, prompt: nil, config: config))
            )
        } catch {
            // `read` will surface the real error on its own path; this helper
            // must not block the loop with its own retries.
            return .none
        }
        guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
            return .none
        }

        let probeDetail = probe["detail"] as? [String: Any]
        let composerEmpty = (probeDetail?["composer"] as? [String: Any])?
            .arenaBool("draftEmpty") == true
        let stopActive = (probeDetail?["stop"] as? [String: Any])?
            .arenaBool("active") == true

        guard probe.arenaString("status") == "ready" else {
            // Page is still loading or rejected the probe. Restart the stall
            // clock so this check is not repeated every poll tick.
            readRecoveryStalls[taskID] = ReadRecoveryStall(
                fingerprint: Self.readProgressFingerprint(detail),
                since: Date()
            )
            return .none
        }
        guard composerEmpty, !stopActive else {
            readRecoveryStalls[taskID] = ReadRecoveryStall(
                fingerprint: Self.readProgressFingerprint(detail),
                since: Date()
            )
            return .held(
                composerEmpty
                    ? "原页仍有生成控件，未自动重载…"
                    : "原页有未发送草稿，未自动重载…"
            )
        }

        // The probe awaited the page, so the user may have paused the
        // discussion since the pre-probe check. Re-check the control right
        // before navigating: a pause must win over the reload.
        guard token == runToken, !isReadOnly, !isPaused,
              !manualProviders.contains(provider), isCurrentPending(taskID) else {
            return .none
        }

        // Reserve the one reload durably *before* the page moves. A reload that
        // is not recorded could be borrowed again after a restart, so a failed
        // save leaves the page untouched.
        let priorReloadFlag = intents[taskID]?.reloadAttempted
        guard var reservation = intents[taskID] else { return .none }
        reservation.reloadAttempted = true
        intents[taskID] = reservation
        guard persist() else {
            reservation.reloadAttempted = priorReloadFlag
            intents[taskID] = reservation
            // Do not probe again on every tick while storage is failing.
            readRecoveryStalls[taskID] = ReadRecoveryStall(
                fingerprint: Self.readProgressFingerprint(detail),
                since: Date()
            )
            return .held("本地保存失败，未自动重载；请先处理存储")
        }

        guard pane.reloadBoundConversationForReadRecovery() else {
            readRecoveryStalls[taskID] = ReadRecoveryStall(
                fingerprint: Self.readProgressFingerprint(detail),
                since: Date()
            )
            return .held("地址或页面状态已变化，未自动重载；请核对原页")
        }

        setState(provider, .generating, "长时间无新内容，已只读重载同一会话一次；继续等待原生完成标记…")
        return .reloaded
    }

    // MARK: Bounded pre-click send repair

    private enum PreClickRepair {
        /// Not a candidate, or the page/task changed: do nothing.
        case none
        /// The one reload happened; the caller may continue its normal loop.
        case reloaded
        /// The page showed something we must not disturb; a human decides.
        case blocked
    }

    private enum ReloadWaitOutcome {
        case ready
        /// Pause, takeover, run change or a moved page: stop without blocking.
        case stopped
        /// The page never mounted a usable composer after the reload.
        case timedOut
    }

    private struct PreClickComposerState {
        var draftEmpty: Bool
        var matchesExpectedPrompt: Bool
        var stopActive: Bool

        var safe: Bool {
            ArenaModel.isPreClickComposerSafe(
                draftEmpty: draftEmpty,
                matchesExpectedPrompt: matchesExpectedPrompt,
                stopActive: stopActive
            )
        }
    }

    /// A real-site Gemini composer can stay missing/hidden long enough to burn
    /// a whole submit loop even though the same bound conversation sends at
    /// once after a reopen (observed 2026-11-22, vote round, ~90 s). This
    /// records one driver-confirmed pre-click refusal and, once per task, may
    /// reload this seat's own pane. It never fills, clicks or submits.
    private func repairPreClickSendIfNeeded(
        provider: String,
        taskID: String,
        config: ArenaSiteConfig,
        pane: SitePane,
        token: UUID,
        prompt: String,
        detail: [String: Any]?
    ) async -> PreClickRepair {
        guard provider == "gemini" else { return .none }

        let reason = detail?["reason"] as? String
        // Only a consecutive run of missing/hidden refusals counts; any other
        // pre-click answer (composer-changed, not-clickable, disabled) resets
        // the streak instead of borrowing this repair.
        guard (detail?["clickAttempted"] as? Bool) == false,
              (detail?["phase"] as? String) == "pre-click",
              reason == "missing" || reason == "hidden" else {
            preClickStalls[taskID] = nil
            return .none
        }

        let now = Date()
        var stall = preClickStalls[taskID] ?? PreClickStall(since: now, refusals: 0)
        stall.refusals += 1
        preClickStalls[taskID] = stall
        let elapsed = now.timeIntervalSince(stall.since)
        guard Self.isPreClickReloadCandidate(
            provider: provider,
            phase: intents[taskID]?.phase,
            reportedPhase: detail?["phase"] as? String,
            clickAttempted: detail?["clickAttempted"] as? Bool,
            reason: reason,
            alreadyReloaded: preClickReloadedTasks.contains(taskID),
            elapsed: elapsed,
            refusals: stall.refusals
        ) else { return .none }

        // The user's control and this task's place must still hold.
        guard token == runToken, !isReadOnly, !isPaused,
              !manualProviders.contains(provider), isCurrentPending(taskID),
              intents[taskID]?.phase == .prepared else { return .none }
        // Only this seat's already bound, same canonical conversation may be
        // reloaded. `conversationMismatch()` is nil while bound and in place.
        guard pane.boundConversationURL != nil, pane.currentURL != nil,
              pane.conversationMismatch() == nil else {
            preClickStalls[taskID] = nil
            return .none
        }

        // Read-only confirmation of the live composer. The probe carries the
        // exact round prompt only as a comparison value and writes nothing.
        guard let composer = await probePreClickComposer(
            provider: provider,
            taskID: taskID,
            config: config,
            pane: pane,
            token: token,
            prompt: prompt
        ) else { return .none }
        guard composer.safe else {
            // A human draft or a live Stop: never reload over it.
            blockedTasks.insert(taskID)
            setState(provider, .needsAction, "原页有未发送草稿或生成控件；未重载、未发送，请核对原页")
            return .blocked
        }

        // The probe awaited the page, so re-check the user's control right
        // before navigating. A pause or takeover must win over the reload.
        guard token == runToken, !isReadOnly, !isPaused,
              !manualProviders.contains(provider), isCurrentPending(taskID) else {
            return .none
        }

        // Mark this repair as used for this run before the page moves.
        preClickReloadedTasks.insert(taskID)
        guard pane.reloadBoundConversationForReadRecovery() else {
            preClickReloadedTasks.remove(taskID)
            preClickStalls[taskID] = nil
            return .none
        }
        preClickStalls[taskID] = nil
        setState(provider, .sending, "发送前检查长时间未通过，已只重载本席同一会话一次；未点击发送")

        switch await waitForReloadedComposer(
            provider: provider,
            taskID: taskID,
            config: config,
            pane: pane,
            token: token,
            prompt: prompt
        ) {
        case .ready:
            return .reloaded
        case .stopped:
            return .none
        case .timedOut:
            blockedTasks.insert(taskID)
            setState(provider, .needsAction, "重载后原页仍未就绪；已停止自动发送，请核对原页")
            return .blocked
        }
    }

    /// The same bound pane must mount a usable composer again before the normal
    /// submit loop may continue. Read-only: probes only, no fill and no click.
    private func waitForReloadedComposer(
        provider: String,
        taskID: String,
        config: ArenaSiteConfig,
        pane: SitePane,
        token: UUID,
        prompt: String
    ) async -> ReloadWaitOutcome {
        let deadline = Date().addingTimeInterval(arenaPreClickReloadReadySeconds)
        while Date() < deadline {
            if Task.isCancelled { return .stopped }
            guard token == runToken, !isReadOnly, !isPaused,
                  !manualProviders.contains(provider), isCurrentPending(taskID) else {
                return .stopped
            }
            if pane.conversationMismatch() != nil { return .stopped }
            if let composer = await probePreClickComposer(
                provider: provider,
                taskID: taskID,
                config: config,
                pane: pane,
                token: token,
                prompt: prompt
            ), composer.safe {
                return .ready
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return .timedOut
    }

    /// Read-only `probe` with the optional composer comparison. Returns nil for
    /// any non-ready answer or transport error; the caller then leaves the page
    /// untouched instead of guessing.
    private func probePreClickComposer(
        provider: String,
        taskID: String,
        config: ArenaSiteConfig,
        pane: SitePane,
        token: UUID,
        prompt: String
    ) async -> PreClickComposerState? {
        var message = engine.driverMessage(
            kind: "probe",
            taskID: taskID,
            prompt: nil,
            config: config
        )
        message["expectedPrompt"] = prompt
        do {
            let response = try await pane.command(withImageEvidence(message))
            guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
                return nil
            }
            guard response.arenaString("status") == "ready" else { return nil }
            let detail = response["detail"] as? [String: Any]
            let composer = detail?["composer"] as? [String: Any]
            let stop = detail?["stop"] as? [String: Any]
            return PreClickComposerState(
                draftEmpty: composer?.arenaBool("draftEmpty") == true,
                matchesExpectedPrompt: composer?.arenaBool("matchesExpectedPrompt") == true,
                stopActive: stop?.arenaBool("active") == true
            )
        } catch {
            return nil
        }
    }

    // MARK: Deliver

    private func deliver(provider: String, task: [String: Any], text: String) {
        guard !manualProviders.contains(provider) else {
            setState(provider, .takenOver, "已接管，未自动回填")
            return
        }
        guard let session, !isReadOnly else { return }
        guard let taskID = task.arenaString("id"), isCurrentPending(taskID) else { return }
        readRecoveryStalls[taskID] = nil
        preClickStalls[taskID] = nil
        preClickReloadedTasks.remove(taskID)

        var payload: [String: Any] = [
            "taskId": taskID,
            "text": text,
            "stage": stageKey,
            "round": currentRound,
        ]
        if stageKey == "independent", !sessionAttachments.isEmpty {
            guard currentTask(taskID)?.arenaString("attachmentReceipt") == "verified" else {
                blockedTasks.insert(taskID)
                setState(provider, .needsAction, "附件送达待核对，回答尚未采用")
                return
            }
            payload["attachmentReceipt"] = "verified"
        }
        var stanceText: String?
        if stageKey == "vote" {
            guard let stance = Self.parseStance(text) else {
                // The model has to state its stance explicitly. Keep the text
                // visible so the user can take over without losing it.
                previews[provider] = ArenaPreview(text: text, isComplete: true)
                blockedTasks.insert(taskID)
                setState(provider, .needsAction, "已收到回答，但缺少明确立场；请接管后选择")
                return
            }
            payload["stance"] = stance
            if let version = task.arenaInt("version") {
                payload["version"] = version
            }
            stanceText = Self.stanceDisplay(stance)
        }

        do {
            self.session = try engine.apply(session: session, action: "answer", payload: payload)
        } catch {
            previews[provider] = ArenaPreview(text: text, isComplete: true)
            blockedTasks.insert(taskID)
            setState(provider, .needsAction, "回答未采用：\(Self.short(error.localizedDescription))")
            return
        }

        previews[provider] = nil
        if let stanceText {
            setState(provider, .answered, "已表态：\(stanceText)")
        } else {
            setState(provider, .answered, "已收到回答")
        }
        refreshStage()
        let saved = persist()
        emitSavedAnswerSignal(provider: provider, taskID: taskID, saved: saved)
        markIdleSeats()
    }

    // MARK: - Helpers

    func stopRunningWork() {
        runToken = UUID()
        dispatcher?.cancel()
        dispatcher = nil
        for (_, task) in workers { task.cancel() }
        workers.removeAll()
        preClickStalls.removeAll()
        preClickReloadedTasks.removeAll()
        clearLiveSignals()
    }

    private func waitWhilePaused(_ token: UUID) async -> Bool {
        while true {
            if token != runToken || isReadOnly { return false }
            if !isPaused { return true }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    /// The restart-only safety net for an explicit per-seat resume: the normal
    /// start already owns a dispatcher, a restored session does not.
    private func ensureDispatcher(token: UUID) {
        guard !isReadOnly, session != nil else { return }
        if dispatcher == nil {
            startDispatcher(token: token)
        }
    }

    /// A command result may arrive after the discussion changed, after its task
    /// was answered or skipped, or after the user took this seat over. Only a
    /// result that still belongs to all three may touch state or the page.
    private func callbackIsCurrent(token: UUID, taskID: String, provider: String) -> Bool {
        guard token == runToken, !isReadOnly else { return false }
        guard isCurrentPending(taskID) else { return false }
        guard !manualProviders.contains(provider) else { return false }
        return true
    }

    /// Say precisely where a pre-click attempt stopped. The driver fills the
    /// composer before it waits for the send control, so `which == "send"`
    /// means the round's prompt is already in the page: call that what it is
    /// instead of leaving a generic "sending" status on screen.
    private static func preClickStatus(_ detail: [String: Any]?) -> String {
        let which = detail?["which"] as? String
        let reason = detail?["reason"] as? String
        if which == "send" {
            switch reason {
            case "disabled": return "已填入，发送按钮暂不可用…"
            case "hidden", "missing": return "已填入，等待发送按钮…"
            default: return "已填入，等待发送按钮…"
            }
        }
        if which == "composer" || reason == "composer-changed" {
            return "原页改动了输入内容，等待重新填入…"
        }
        return "已填入，等待发送控件…"
    }

    /// The pre-click states a normal start may retry while a real site's
    /// composer is still mounting. None of them implies a delivery.
    private static func isTransientProbeFailure(_ code: String) -> Bool {
        switch code {
        case "document-not-ready", "not-authorized-page", "selector-missing",
             "input-uneditable", "input-disabled", "input-readonly":
            return true
        default:
            return false
        }
    }

    /// Explicit input conflicts the page rejected before any click. They are
    /// safe to keep at `.prepared`, but must go to a human instead of being
    /// retried automatically. Anything not listed here is treated as possibly
    /// delivered and may only be confirmed with `read`.


    // MARK: Read-only confirmation

    private enum VerifyResult {
        case answered(String)
        case generating
        /// The page cannot confirm this task; a human has to look at the site.
        case unconfirmed(String)
        /// The discussion, task or seat changed while the command was out.
        case stopped
    }

    /// Confirm a task whose submit may already have happened, using the
    /// web-driver `read` command only. It never fills, never clicks and never
    /// falls back to `submit`, so an unconfirmed task stays for a human.
    private func verifyPossiblySent(
        provider: String,
        taskID: String,
        config: ArenaSiteConfig,
        pane: SitePane,
        token: UUID
    ) async -> VerifyResult {
        let window = engine.fixtureBase == nil
            ? Self.verifyWindowSeconds
            : Self.fixtureProbeWindowSeconds
        let deadline = Date().addingTimeInterval(window)

        verify: while true {
            guard !Task.isCancelled else { return .stopped }
            guard await waitWhilePaused(token) else { return .stopped }
            guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
                return .stopped
            }
            do {
                // Only a persisted intent that may already have clicked may
                // supply the exact original prompt. The driver still needs a
                // stable conversation binding and a verbatim latest turn.
                let recoveryPrompt = ArenaEngine.readRecoveryPrompt(
                    phase: intents[taskID]?.phase,
                    prompt: intents[taskID]?.prompt
                )
                let response = try await pane.command(
                    withImageEvidence(engine.driverMessage(
                        kind: "read",
                        taskID: taskID,
                        prompt: nil,
                        verifiedReadPrompt: recoveryPrompt,
                        config: config
                    ))
                )
                guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
                    return .stopped
                }
                let detail = response["detail"] as? [String: Any]
                if response.arenaString("status") == "done" || detail?.arenaBool("userTurnVerified") == true {
                    do {
                        try confirmOpeningMaterials(taskID: taskID, response: response)
                    } catch {
                        return .unconfirmed(error.localizedDescription)
                    }
                }
                persistVerifiedBinding(pane, from: response, taskID: taskID)
                let status = response.arenaString("status") ?? ""
                let code = response.arenaString("error") ?? ""
                if code == "conversation-changed" {
                    switch await recoverConversationDrift(
                        provider: provider,
                        taskID: taskID,
                        pane: pane,
                        token: token,
                        phase: .verifying
                    ) {
                    case .recovered:
                        continue verify
                    case .stopped, .blocked:
                        return .stopped
                    }
                }
                if code.hasPrefix("attachment-") {
                    return .unconfirmed(attachmentProblem(response, fallback: code))
                }
                switch status {
                case "done":
                    let text = (response.arenaString("text") ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? .unconfirmed("原页回答为空") : .answered(text)
                case "pending":
                    if (response["detail"] as? [String: Any])?.arenaBool("userTurnVerified") == true {
                        return .generating
                    }
                    if Date() >= deadline { return .unconfirmed("原页尚未出现本轮完整提问") }
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                case "unknown":
                    if intents[taskID]?.driftReturnAttempted == true,
                       Self.isPostReturnPromptMismatch(code.isEmpty ? "unknown" : code) {
                        blockedTasks.insert(taskID)
                        setState(provider, .needsAction,
                                 Self.conversationDriftReadFailureMessage(.verifying))
                        return .stopped
                    }
                    return .unconfirmed(Self.friendly(errorCode: code.isEmpty ? "unknown" : code))
                default:
                    if code == "document-not-ready" || code == "not-authorized-page",
                       Date() < deadline {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        continue
                    }
                    if intents[taskID]?.driftReturnAttempted == true,
                       Self.isPostReturnPromptMismatch(code) {
                        blockedTasks.insert(taskID)
                        setState(provider, .needsAction,
                                 Self.conversationDriftReadFailureMessage(.verifying))
                        return .stopped
                    }
                    return .unconfirmed(Self.friendly(errorCode: code.isEmpty ? status : code))
                }
            } catch {
                guard token == runToken, !isReadOnly, !Task.isCancelled else { return .stopped }
                if let paneError = error as? SitePaneError, paneError.isConversationChanged {
                    switch await recoverConversationDrift(
                        provider: provider,
                        taskID: taskID,
                        pane: pane,
                        token: token,
                        phase: .verifying
                    ) {
                    case .recovered:
                        continue verify
                    case .stopped, .blocked:
                        return .stopped
                    }
                }
                if Date() < deadline {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                }
                return .unconfirmed(Self.short(error.localizedDescription))
            }
        }
    }

    /// Apply the result of that read-only confirmation. Confirmed tasks move to
    /// `.submitted` and are read normally; anything else blocks the task and
    /// asks the user to check the page. Nothing here can send.
    private func adoptPossiblySent(
        provider: String,
        task: [String: Any],
        taskID: String,
        config: ArenaSiteConfig,
        pane: SitePane,
        token: UUID
    ) async -> Bool {
        switch await verifyPossiblySent(
            provider: provider,
            taskID: taskID,
            config: config,
            pane: pane,
            token: token
        ) {
        case .stopped:
            return false
        case .generating:
            promoteToSubmitted(taskID: taskID, task: task, pane: pane)
            blockedTasks.remove(taskID)
            setState(provider, .generating, "原页已确认本轮提问，只读读取回答…")
            return true
        case .answered(let text):
            promoteToSubmitted(taskID: taskID, task: task, pane: pane)
            blockedTasks.remove(taskID)
            previews[provider] = nil
            deliver(provider: provider, task: task, text: text)
            return false
        case .unconfirmed(let why):
            blockedTasks.insert(taskID)
            setState(provider, .needsAction, "需处理：只读核对未确认（\(why)）；不会重发")
            return false
        }
    }

    private func promoteToSubmitted(taskID: String, task: [String: Any], pane: SitePane) {
        var intent = intents[taskID] ?? ArenaDeliveryIntent(
            taskId: taskID,
            prompt: task.arenaString("prompt") ?? "",
            stage: stageKey,
            round: currentRound,
            phase: .submitted,
            preparedAt: Self.nowMillis(),
            submittedAt: Self.nowMillis(),
            pageURL: pane.boundConversationURL?.absoluteString
        )
        intent.phase = .submitted
        intent.submittedAt = intent.submittedAt ?? Self.nowMillis()
        intent.pageURL = pane.boundConversationURL?.absoluteString ?? intent.pageURL
        intents[taskID] = intent
        persist()
    }

    func prepareHome(_ selected: Set<String> = ["chatgpt", "gemini", "deepseek"]) {
        guard session == nil, engine.configurationIssue == nil else { return }
        panes = panes.filter { selected.contains($0.key) }
        for provider in engine.providerIDs where selected.contains(provider) && panes[provider] == nil {
            ensurePane(for: provider).openHome()
        }
    }

    private func ensurePane(for provider: String) -> SitePane {
        if let existing = panes[provider] { return existing }
        let pane = makePane(for: provider)
        panes[provider] = pane
        return pane
    }

    /// Creates a pane without navigating. `SitePane` documents that
    /// `init(provider:)` performs no navigation.
    ///
    /// In controlled fixture mode the pane is built through `testPane` with
    /// the loopback URL, so neither navigation nor driver authorisation can
    /// reach a real consumer site.
    private func makePane(for provider: String) -> SitePane {
        let pane: SitePane
        if engine.fixtureBase != nil,
           let config = try? engine.config(for: provider) {
            pane = SitePane.testPane(
                provider: provider,
                loopbackURL: config.url,
                selectors: Self.stringSelectors(config.selectors),
                options: config.options,
                allowNavigation: config.allowNavigation
            )
        } else {
            pane = SitePane(provider: provider)
        }
        // 自动回合中把本席钉在已核验的本场对话上。判断随场次状态实时计算：
        // 人工接管、暂停、结束、历史回看或新场次都会立即解除，不再加锁。
        pane.isAutomaticWorkActive = { [weak self] in
            self?.isAutomaticSeatWork(provider) ?? false
        }
        return pane
    }

    /// 这一席此刻是否仍由自动派发负责。只有这种席位才允许加导航锁和主动
    /// 返回；人工接管、已交回用户处理的任务与只读回看都必须保持原页自由。
    private func isAutomaticSeatWork(_ provider: String) -> Bool {
        guard session != nil, !isReadOnly, !isPaused, stageKey != "done" else { return false }
        guard currentProviders.contains(provider), !manualProviders.contains(provider) else {
            return false
        }
        if let pending = pendingTask(for: provider),
           let taskID = pending.arenaString("id"),
           blockedTasks.contains(taskID) {
            return false
        }
        return true
    }

    /// Mount the three seat pages with their entry pages so the workbench is
    /// usable before the first question. `start` re-opens each home page to
    /// guarantee a fresh conversation for the new discussion.
    private func prepareInitialPanes() {
        guard engine.configurationIssue == nil else { return }
        let restored = currentID.flatMap { engine.store.load(id: $0) }
        let providers = session == nil ? engine.providerIDs : currentProviders
        for provider in providers {
            guard let config = try? engine.config(for: provider) else { continue }
            let savedURL = restored?.pageURLs[provider].flatMap(URL.init(string:))
            let target = savedURL.flatMap { SitePane.originString($0) == config.origin ? $0 : nil }
            let pane = ensurePane(for: provider)
            pane.resetConversationBinding()
            pane.open(target ?? config.url)
            // 恢复上次场次时同时恢复本席固定的会话地址（仅同源且通过白名单）。
            if let target { pane.restoreConversationBinding(target) }
        }
    }

    private static func stringSelectors(_ raw: [String: Any]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (key, value) in raw {
            if let list = value as? [String] {
                result[key] = list
            } else if let single = value as? String, !single.isEmpty {
                result[key] = [single]
            }
        }
        return result
    }

    private var currentProviders: [String] {
        session?.arenaStringArray("providers") ?? []
    }

    private var currentTasks: [[String: Any]] {
        (session?["tasks"] as? [[String: Any]]) ?? []
    }

    private var currentRound: Int {
        session?.arenaInt("round") ?? 1
    }

    private func currentTask(_ taskID: String) -> [String: Any]? {
        currentTasks.first { $0.arenaString("id") == taskID }
    }

    private func isCurrentPending(_ taskID: String) -> Bool {
        currentTask(taskID)?.arenaString("status") == "pending"
    }

    private func pendingTask(for provider: String) -> [String: Any]? {
        currentTasks.first {
            $0.arenaString("provider") == provider &&
            $0.arenaString("status") == "pending"
        }
    }

    private func displayName(_ provider: String) -> String {
        (try? engine.config(for: provider))?.label ?? provider
    }

    private func persistVerifiedBinding(_ pane: SitePane, from response: [String: Any], taskID: String) {
        let prior = pane.boundConversationURL
        guard pane.bindVerifiedConversation(from: response),
              let current = pane.boundConversationURL, current != prior else { return }
        intents[taskID]?.pageURL = current.absoluteString
        persist()
    }

    private func emitReceiptSignal(provider: String, taskID: String, turnVerified: Bool) {
        guard ArenaSeatMotionPolicy.shouldAnimateVerifiedReceipt(
            turnVerified: turnVerified,
            paused: isPaused,
            readOnly: isReadOnly,
            takenOver: manualProviders.contains(provider)
        ) else { return }
        seatReceiptSignals[provider] = ArenaSeatLiveSignal(taskID: taskID, kind: .receiptVerified)
    }

    private func emitSavedAnswerSignal(provider: String, taskID: String, saved: Bool) {
        guard ArenaSeatMotionPolicy.shouldAnimateSavedAnswer(saved: saved, readOnly: isReadOnly) else {
            return
        }
        seatAnswerSignals[provider] = ArenaSeatLiveSignal(taskID: taskID, kind: .answerSaved)
        liveAnswerRevision &+= 1
    }

    private func clearLiveSignals() {
        seatReceiptSignals.removeAll()
        seatAnswerSignals.removeAll()
    }

    private func setState(
        _ provider: String,
        _ kind: ArenaSeatStateKind,
        _ detail: String
    ) {
        let next = ArenaSeatState(kind: kind, detail: detail)
        if seatStates[provider] != next {
            seatStates[provider] = next
            if ProcessInfo.processInfo.environment["ARENA_TRACE_STATUS"] == "1" {
                FileHandle.standardError.write(
                    Data("[Arena] \(stageKey) \(provider) \(kind.rawValue) \(detail)\n".utf8)
                )
            }
        }
    }

    private func refreshStage() {
        guard let session else {
            stageKey = ""
            stageLabel = "尚未开始"
            return
        }
        stageKey = session.arenaString("stage") ?? ""
        var label = ArenaStageNames.discussionLabel(session)
        if isReadOnly {
            label += "（历史回看）"
        }
        stageLabel = label
    }

    /// Give seats without work a truthful resting status. A state that needs
    /// the user (blocked, taken over, skipped, paused) is never overwritten.
    private func markIdleSeats() {
        guard stageKey != "done" else {
            for provider in currentProviders {
                let state = finalState(for: provider)
                setState(provider, state.kind, state.detail)
            }
            return
        }
        for provider in currentProviders {
            guard pendingTask(for: provider) == nil else { continue }
            let current = seatStates[provider]?.kind
            if manualProviders.contains(provider) {
                setState(provider, .takenOver, "本轮已完成（等待其他席位）")
            } else if current == .needsAction || current == .takenOver
                        || current == .skipped || current == .paused {
                continue
            } else {
                setState(provider, .answered, "本轮已完成")
            }
        }
    }

    private func finalState(for provider: String) -> ArenaSeatState {
        ArenaSeatOutcome.derive(session: session, provider: provider, ballot: reportBallot())
    }

    // MARK: Persistence

    /// Writes the current session and delivery intents atomically.
    ///
    /// Returns `false` when nothing was written (read-only, no session, or a
    /// storage failure). Callers that are about to send must treat `false` as
    /// "stop": an intent that is not durable cannot guard a later restart.
    @discardableResult
    /// `updateCurrent` defaults to true; an incremental write to the already
    /// pinned live session (a user condition) passes false so the scene file is
    /// the only write and a pointer-only failure cannot produce a false failure.
    private func persist(updateCurrent: Bool = true) -> Bool {
        guard !isReadOnly, let session else { return false }
        guard let id = session.arenaString("id"), !id.isEmpty else { return false }
        let sessionJSON: String
        do {
            let data = try JSONSerialization.data(withJSONObject: session, options: [.sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else {
                throw ArenaEngineError("场次无法编码")
            }
            sessionJSON = text
        } catch {
            storageFailed = true
            errorMessage = "本地保存失败：\(error.localizedDescription)；已暂停后续发送"
            return false
        }

        var pageURLs: [String: String] = [:]
        for (provider, pane) in panes {
            // 只保存“已核验对话”的规范化地址（origin+path）；没有绑定时退回
            // 旧的同源、无查询串/片段地址。账号、query、fragment 一律不落盘。
            if let config = try? engine.config(for: provider),
               let bound = pane.boundConversationURL,
               SitePane.originString(bound) == config.origin {
                pageURLs[provider] = bound.absoluteString

            }
        }

        let file = ArenaSessionFile(
            version: 1,
            id: id,
            question: question,
            createdAt: createdAt > 0 ? createdAt : Self.nowMillis(),
            updatedAt: Self.nowMillis(),
            sessionJSON: sessionJSON,
            intents: intents.values.sorted { $0.taskId < $1.taskId },
            manualProviders: manualProviders.subtracting(verificationProviders).sorted(),
            pageURLs: pageURLs,
            stopReason: session.arenaString("stopReason")
        )

        if let failure = engine.store.save(file, updateCurrent: updateCurrent) {
            if !storageFailed {
                storageFailed = true
                errorMessage = failure + "；已暂停后续发送"
            }
            return false
        }
        if storageFailed {
            storageFailed = false
            if errorMessage.contains("本地保存失败") || errorMessage.contains("本地当前场次") {
                errorMessage = ""
            }
        }
        currentID = id
        // The write above is durable and `session` is already parsed, so the
        // history row is projected from this save instead of re-reading every
        // saved record. A failed save returned before this point.
        historyList = ArenaSessionStore.upserting(
            engine.store.summary(for: file, session: session),
            into: historyList
        )
        if let event = completionTracker.recordPersisted(
            sessionID: id,
            stage: session.arenaString("stage") ?? "",
            explicitFinish: session.arenaString("stopReason") == "user-finished"
        ) {
            onDiscussionCompleted?(event)
        }
        return true
    }

    func evaluation(sessionID: String) throws -> ArenaEvaluation? {
        try engine.store.loadEvaluation(sessionID: sessionID)
    }

    func saveEvaluation(_ evaluation: ArenaEvaluation, sessionID: String) throws {
        guard session?.arenaString("id") == sessionID, stageKey == "done" else {
            throw EvaluationInputError("场次已切换，请重新打开本场报告")
        }
        try engine.store.saveEvaluation(evaluation, sessionID: sessionID)
    }

    private func evaluationAttachments(sessionID: String) throws -> (images: [[String: String]], texts: [String: String]) {
        guard session?.arenaString("id") == sessionID else { throw EvaluationInputError("场次已切换") }
        var images: [[String: String]] = []
        var texts: [String: String] = [:]
        for (index, attachment) in sessionAttachments.enumerated() {
            guard let name = attachment.arenaString("name") else { throw EvaluationInputError("附件缺少名称") }
            let data = try engine.store.attachmentData(sessionID: sessionID, attachment: attachment)
            if attachment.arenaString("kind") == "image" {
                guard let mediaType = attachment.arenaString("mediaType") else {
                    throw EvaluationInputError("图片缺少格式")
                }
                images.append(["name": name, "mediaType": mediaType, "base64": data.base64EncodedString()])
            } else {
                guard let text = String(data: data, encoding: .utf8) else {
                    throw EvaluationInputError("无法读取附件原文")
                }
                texts["附件 \(index + 1) · \(name)"] = text
            }
        }
        return (images, texts)
    }

    func runEvaluation(sessionID: String, reversing pairID: String? = nil) async throws -> ArenaEvaluation {
        guard evaluatingSessionID == nil else { throw EvaluationInputError("已有评估正在进行") }
        guard let session, session.arenaString("id") == sessionID, stageKey == "done",
              let question = session.arenaString("question") else { throw EvaluationInputError("请打开已结束的场次") }
        let candidates = ArenaSessionDigest.evaluationCandidates(session)
        guard candidates.count >= 2, Set(candidates.map(\.source)).count == candidates.count else {
            throw EvaluationInputError("本场需要至少两份可核对出处的独立作答")
        }
        var saved = try evaluation(sessionID: sessionID)
        let attachments = try evaluationAttachments(sessionID: sessionID)
        let names = attachments.images.compactMap { $0["name"] }
        let draft: ArenaEvaluationDraft
        if let pairID {
            guard let saved, saved.checks[pairID] == nil,
                  let pair = saved.comparisons.first(where: { $0.id == pairID }) else {
                throw EvaluationInputError("找不到待复判的对阵")
            }
            draft = ArenaEvaluationDraft(question: question, evaluation: saved, reversing: pair,
                                         images: names, texts: attachments.texts, candidates: candidates)
        } else {
            guard saved == nil else { throw EvaluationInputError("本场已有评估结果") }
            draft = ArenaEvaluationDraft(question: question, candidates: candidates, images: names, texts: attachments.texts)
        }
        let prompt = draft.prompt
        guard prompt.utf16.count <= 100_000 else { throw EvaluationInputError("本场评估材料超过网页单次发送上限") }
        evaluatingSessionID = sessionID
        defer { evaluatingSessionID = nil }

        let config = try engine.config(for: "chatgpt")
        let pane = makePane(for: "chatgpt")
        pane.webView.frame = CGRect(x: 0, y: 0, width: 1040, height: 740)
        pane.isAutomaticWorkActive = { true }
        evaluationPage = EvaluationPage(sessionID: sessionID, pane: pane)
        defer { pane.isAutomaticWorkActive = nil }
        pane.openHome()

        let taskID = "evaluation-\(draft.id.uuidString):r1:independent:chatgpt"
        var probe = engine.driverMessage(kind: "probe", taskID: taskID, prompt: nil, config: config)
        if !names.isEmpty { probe["imageNames"] = names }
        try await waitForEvaluationComposer(pane, probe: probe, sessionID: sessionID)

        var send = engine.driverMessage(kind: "submit", taskID: taskID, prompt: prompt, config: config)
        send["freshConversationOnly"] = true
        var read = engine.driverMessage(kind: "read", taskID: taskID, prompt: nil,
                                        verifiedReadPrompt: prompt, config: config)
        if !names.isEmpty {
            var prepare = send
            prepare["images"] = attachments.images
            prepare["prepareImagesOnly"] = true
            let ready = try await pane.command(prepare)
            let detail = ready["detail"] as? [String: Any]
            guard ready.arenaString("status") == "attachments-ready",
                  detail?["readyImageNames"] as? [String] == names else {
                throw EvaluationInputError("ChatGPT 未能在裁判页备齐图片")
            }
            let pixels = try Self.preparedImagePixels(detail?["readyImagePixels"], count: names.count)
            send["imageNames"] = names
            read["imageNames"] = names
            send["imagePixels"] = pixels
            read["imagePixels"] = pixels
        }
        try Task.checkCancellation()
        guard self.session?.arenaString("id") == sessionID else { throw EvaluationInputError("场次已切换") }
        // Exactly one send command per click. A lost receipt never leads to a second click.
        let submitted: [String: Any]
        do {
            submitted = try await pane.command(send)
        } catch let error as SitePaneError {
            if error.isConversationChanged {
                throw EvaluationInputError("裁判页未停在 ChatGPT 新会话，评估未发送")
            }
            throw EvaluationInputError("无法确认裁判请求：\(error.localizedDescription)")
        }
        let code = submitted.arenaString("error")
        guard submitted.arenaString("status") == "submitted" || code == "submit-unconfirmed" else {
            throw EvaluationInputError(code == "fresh-conversation-required"
                ? "裁判页已有对话，评估未发送"
                : "裁判请求受阻：\(Self.friendly(errorCode: code ?? "unknown"))")
        }
        _ = pane.bindVerifiedConversation(from: submitted)

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation()
            guard self.session?.arenaString("id") == sessionID else { throw EvaluationInputError("场次已切换") }
            let response = try await pane.command(read)
            _ = pane.bindVerifiedConversation(from: response)
            if response.arenaString("status") == "done", let text = response.arenaString("text") {
                let detail = response["detail"] as? [String: Any]
                guard names.isEmpty || detail?["verifiedImageNames"] as? [String] == names else {
                    throw EvaluationInputError("裁判页未确认收齐图片")
                }
                let comparisons = try draft.parse(text)
                if let pairID, var prior = saved, let comparison = comparisons.first {
                    prior.checks[pairID] = comparison
                    saved = prior
                } else {
                    saved = ArenaEvaluation(id: draft.id, entries: draft.entries, judge: "ChatGPT 网页", comparisons: comparisons)
                }
                guard let saved else { throw EvaluationInputError("裁判没有返回可保存的对阵") }
                try saveEvaluation(saved, sessionID: sessionID)
                evaluationPage = nil
                return saved
            }
            if response.arenaString("status") == "error", let error = response.arenaString("error") {
                throw EvaluationInputError("裁判回复无法核对：\(Self.friendly(errorCode: error))")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw EvaluationInputError("等待裁判回复超时。本次未重发，你可以在 ChatGPT 网页核对原会话。")
    }

    /// A navigation can finish before ChatGPT mounts its editor and upload picker.
    /// Only the read-only probe is repeated. Dispatch still has one submit attempt.
    private func waitForEvaluationComposer(_ pane: SitePane, probe: [String: Any], sessionID: String) async throws {
        let timeout = engine.fixtureBase == nil ? Self.realProbeWindowSeconds : Self.fixtureProbeWindowSeconds
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            guard session?.arenaString("id") == sessionID else { throw EvaluationInputError("场次已切换") }
            let code: String
            let control: String?
            do {
                let result = try await pane.command(probe)
                if result.arenaString("status") == "ready" { return }
                code = result.arenaString("error") ?? "unknown"
                control = (result["detail"] as? [String: Any])?.arenaString("which")
            } catch let error as SitePaneError {
                code = error.code
                control = nil
            }
            if let url = pane.currentURL, SitePane.isAuthenticationPath(url) {
                throw EvaluationInputError("ChatGPT 裁判页需要登录。请打开裁判原页完成登录后重试。")
            }
            let transient = Self.isTransientProbeFailure(code) || code == "selector-hidden"
            if transient, Date() < deadline {
                try await Task.sleep(nanoseconds: 600_000_000)
                continue
            }
            if control == "input" || control == "attachment-picker" {
                let name = control == "input" ? "输入框" : "图片上传控件"
                throw EvaluationInputError("ChatGPT 裁判页没有就绪的\(name)。评估未发送，请查看裁判原页。")
            }
            throw EvaluationInputError("评估未发送：\(Self.friendly(errorCode: code))。请查看裁判原页。")
        }
    }

    func reviewMaterials() -> [String: [[String: String]]] {
        guard let session else { return [:] }
        return (try? engine.reviewMaterials(session: session)) as? [String: [[String: String]]] ?? [:]
    }

    func reportBallot() -> [String: Any]? {
        guard let history = session?["history"] as? [[String: Any]] else { return nil }
        // The per-turn prompts can contain the entire debate. Only ballot
        // metadata and candidate text are needed by the shared core filter.
        return try? engine.reportBallot(
            history: ArenaBallotProjection.materials(history: history)
        )
    }

    /// Same projection and return shape as `reportBallot()`, scoped to one
    /// candidate version. `version`, the candidate text, its digest and only
    /// the strictly verified votes for that exact text come from the shared
    /// engine; prompts and other rounds never cross into JavaScript.
    func reportBallot(forVersion version: Int) -> [String: Any]? {
        guard let history = session?["history"] as? [[String: Any]] else { return nil }
        guard ArenaBallotProjection.containsProposal(version: version, in: history) else {
            return nil
        }
        return try? engine.reportBallot(
            history: ArenaBallotProjection.materials(history: history, version: version)
        )
    }

    // MARK: - Restore

    /// One shared loader for the ordinary relaunch, the CLI continuation and
    /// the history view. The mode is the only difference: a history view and a
    /// plain relaunch treat every pending seat (including a never-sent one) as
    /// manual verification, while an explicitly authorised continuation lets the
    /// existing dispatcher advance a verified unsent task.
    private enum ArenaRestoreMode {
        case manualVerification
        case explicitContinue
    }

    private struct ArenaSavedSession {
        let file: ArenaSessionFile
        let session: [String: Any]

        var participants: [String] { session.arenaStringArray("providers") }
        var stage: String { session.arenaString("stage") ?? "" }
        var isPaused: Bool { session.arenaBool("paused") ?? false }
    }

    private func loadSavedSession(id: String) -> ArenaSavedSession? {
        guard let file = engine.store.load(id: id),
              let session = Self.decodeSession(file.sessionJSON),
              Self.hasUniqueIntentIDs(file.intents) else {
            return nil
        }
        return ArenaSavedSession(file: file, session: session)
    }

    /// Reject a saved record whose delivery intents reuse a task id. No single
    /// phase can be chosen for such a task: a guessed `prepared` could resend
    /// something already sent, so the record is refused and left on disk.
    private nonisolated static func hasUniqueIntentIDs(_ intents: [ArenaDeliveryIntent]) -> Bool {
        var seen: Set<String> = []
        for intent in intents where !seen.insert(intent.taskId).inserted {
            return false
        }
        return true
    }

    /// Preconditions for the CLI path that can dispatch verified unsent tasks.
    private func explicitContinueBlockedReason(_ saved: ArenaSavedSession) -> String? {
        if saved.stage == "done" {
            return "这场讨论已经结束，没有可继续的轮次。"
        }
        if saved.isPaused {
            return "这场讨论处于暂停状态；为避免重复发送不会自动继续，请只读回看。"
        }
        if !saved.file.manualProviders.isEmpty {
            return "这场讨论有席位处于人工接管；请只读回看后按席位逐项核对。"
        }
        return nil
    }

    private func restoreInitialSession() {
        guard let id = engine.store.currentID() else {
            return
        }
        guard let saved = loadSavedSession(id: id) else {
            // The pointer is valid but the record is not: keep the file as it
            // is, install nothing and say so instead of starting silently.
            // `recoveryNotice` only renders after a restore installs a running
            // session, so this failure belongs in the dismissible error banner.
            errorMessage = "上次场次未能恢复：本地记录没有通过校验。历史里可能仍看得到这一场，但打开它会被拒绝。为避免重复发送，本场不会自动继续；可新建讨论。"
            return
        }
        let requested = explicitContinueID
        let explicit = requested != nil
            && requested == id
            && explicitContinueBlockedReason(saved) == nil

        installRestored(saved, mode: explicit ? .explicitContinue : .manualVerification)

        if let requested, requested != id {
            recoveryNotice = "指定的场次 \(requested) 与当前场次 \(id) 不一致，未自动恢复；已按人工核对方式打开当前场次。"
        } else if requested != nil && !explicit {
            if saved.isPaused {
                recoveryNotice = "当前场次处于暂停状态，未自动恢复；请先核对原页，再手动继续。"
            } else if !saved.file.manualProviders.isEmpty {
                recoveryNotice = "当前场次有席位处于手工接管，未自动恢复；请核对接管席位后手动继续。"
            } else if saved.stage == "done" {
                recoveryNotice = "当前场次已经结束，没有需要继续的轮次。"
            } else {
                recoveryNotice = "当前场次未通过自动恢复检查；已按人工核对方式打开。"
            }
        } else if !explicit {
            recoveryNotice = "已恢复上次讨论。为避免重复发送，本场改为人工核对：可打开原页核对后粘贴回答，或跳过；新建讨论才会恢复自动派发。"
        }
    }

    private func installRestored(
        _ saved: ArenaSavedSession,
        mode: ArenaRestoreMode,
        readOnly: Bool = false
    ) {
        session = saved.session
        currentID = saved.file.id
        question = saved.file.question
        draftAttachments.removeAll()
        createdAt = saved.file.createdAt
        completionTracker.adopt(sessionID: saved.file.id, stage: saved.stage)
        intents = Dictionary(uniqueKeysWithValues: saved.file.intents.map { ($0.taskId, $0) })
        blockedTasks.removeAll()
        previews.removeAll()
        seatStates.removeAll()
        clearLiveSignals()
        isReadOnly = readOnly
        isRecovering = true
        isPaused = saved.isPaused
        historyResumeID = nil
        didContinueSavedDiscussion = (mode == .explicitContinue)
        verificationProviders.removeAll()
        refreshStage()

        switch mode {
        case .explicitContinue:
            // Only the seats the user really took over block this mode; the
            // checks above already required that set to be empty. The saved
            // intents and task ownership stay exactly as they were, and the
            // normal dispatcher decides per phase what may happen next.
            manualProviders = []
            for provider in saved.participants {
                let state = continueState(for: provider)
                setState(provider, state.kind, state.detail)
            }
            recoveryNotice = "已按指定场次继续讨论。已收齐的席位不重发；尚未发送的席位自动派发；可能已发送的席位只做只读核对。"
        case .manualVerification:
            // Conservative: every pending seat waits for a human, including a
            // task whose persisted phase is still `prepared` (never sent).
            manualProviders = Set(saved.participants)
            verificationProviders = manualProviders.subtracting(saved.file.manualProviders)
            for provider in saved.participants {
                if let pending = pendingTask(for: provider) {
                    setManualWaitingState(provider, task: pending)
                } else if saved.stage == "done" {
                    let state = finalState(for: provider)
                    setState(provider, state.kind, state.detail)
                } else {
                    setState(provider, .answered, "本轮已完成")
                }
            }
        }
        refreshStage()
    }

    /// Reopen a history session via the same restore pipeline as the CLI.
    /// All seats wait for explicit user action, including tasks with no intent.
    @discardableResult
    func continueSavedDiscussion(_ id: String) -> Bool {
        guard let saved = loadSavedSession(id: id) else {
            errorMessage = "找不到该历史场次"
            return false
        }
        guard saved.stage != "done" else {
            errorMessage = "这场讨论已经结束，没有可继续的轮次。"
            return false
        }
        stopRunningWork()
        errorMessage = ""
        installRestored(saved, mode: .manualVerification)
        recoveryNotice = "已继续这一场。请逐席核对原页，再补录、跳过或恢复本站自动。"
        panes = panes.filter { currentProviders.contains($0.key) }
        engine.store.setCurrent(id)
        prepareInitialPanes()
        refreshHistoryList()
        startDispatcher(token: runToken)
        return true
    }

    /// The resting state of one seat in a verified explicit continuation. A
    /// seat that never sent is described as ready to dispatch, not as sending.
    private func continueState(for provider: String) -> ArenaSeatState {
        guard let pending = pendingTask(for: provider),
              let taskID = pending.arenaString("id") else {
            return stageKey == "done"
                ? finalState(for: provider)
                : ArenaSeatState(kind: .answered, detail: "本轮已完成")
        }
        switch intents[taskID]?.phase {
        case .submitted:
            return ArenaSeatState(kind: .generating, detail: "已恢复：此前已发送，只读继续读取回答…")
        case .inflight, .uncertain:
            return ArenaSeatState(kind: .needsAction, detail: "已恢复：可能已发送，只读核对原页（不会重发）…")
        case .prepared, .none:
            return ArenaSeatState(kind: .sending, detail: "已恢复：本轮尚未发送，准备自动派发…")
        }
    }

    /// Conservative pending-seat state for a history/relaunch restore. A
    /// prepared task has evidence that nothing was clicked, but it still waits
    /// for the same human verification as any other restored seat.
    nonisolated static func restoredManualState(
        phase: ArenaDeliveryIntent.Phase?
    ) -> ArenaSeatState {
        switch phase {
        case .submitted:
            return ArenaSeatState(kind: .needsAction, detail: "已恢复：此前已发送，请核对原页（不会重发）")
        case .inflight, .uncertain:
            return ArenaSeatState(kind: .needsAction, detail: "已恢复：可能已发送，需你核对原页（不会重发）")
        case .prepared, .none:
            return ArenaSeatState(kind: .needsAction, detail: "已恢复：本轮尚未发送，请核对原页后再手动继续（不会自动发送）")
        }
    }

    /// Read-only diagnostic used by the isolated acceptance runner: the
    /// persisted delivery phase of that seat's current pending task, if any.
    func deliveryPhase(for provider: String) -> String? {
        guard let pending = pendingTask(for: provider),
              let taskID = pending.arenaString("id") else {
            return nil
        }
        return intents[taskID]?.phase.rawValue
    }

    private func refreshHistoryList() {
        historyList = engine.store.summaries()
    }

    /// Re-read the saved summaries for the search sheet. Read-only: nothing is
    /// opened, resumed or sent.
    func reloadHistorySummaries() {
        refreshHistoryList()
    }

    // MARK: Static helpers

    private static func nowMillis() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    private static func decodeSession(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func short(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 90 else { return trimmed }
        return String(trimmed.prefix(90)) + "…"
    }

    private static func friendly(errorCode: String) -> String {
        switch errorCode {
        case "document-not-ready": return "原页尚未加载完成"
        case "not-authorized-page": return "原页尚未就绪"
        case "out-of-scope": return "原页地址与登记的站点不一致"
        case "conversation-changed": return "原页已切到别的对话，未发送"
        case "selector-missing": return "原页缺少输入或发送控件（站点可能改版）"
        case "selector-ambiguous": return "原页控件不唯一"
        case "selector-overlap": return "消息选择器重叠"
        case "selector-invalid": return "站点选择器无效"
        case "input-uneditable": return "输入框无法编辑"
        case "input-disabled": return "输入框被禁用"
        case "input-readonly": return "输入框只读"
        case "attachment-unsupported": return "原页没有可核对的图片上传入口，请在该席原页添加"
        case "attachment-draft-conflict": return "原页附件草稿与本轮不一致，请在原页核对"
        case "attachment-upload-failed": return "原页未接收全部图片，请核对并手动补齐"
        case "attachment-not-ready": return "图片尚未全部就绪，请核对原页后恢复本席或手动补录"
        case "attachment-receipt-mismatch": return "原页本轮消息的图片与清单不一致，请核对；不会重发"
        case "draft-conflict": return "原页已有未发送草稿，未覆盖"
        case "busy": return "原页正有另一任务"
        case "prompt-already-sent": return "原页已有本轮提问，不再重发"
        case "submit-unconfirmed": return "可能已发送，只能人工核对"
        case "user-turn-mismatch": return "未核对到本轮提问"
        case "task-prompt-mismatch": return "原页记录与持久化原文不一致"
        case "recovery-timeout": return "只读核对超时，原页仍未挂载本轮消息"
        case "send-pending": return "发送控件暂未就绪"
        case "send-unavailable": return "发送控件不可用"
        case "fill-failed", "fill-mismatch": return "填写未通过核对"
        case "task-unknown", "page-changed", "history-changed": return "页面状态已变化，不会重发"
        case "task-id-conflict": return "页面任务号冲突"
        case "internal": return "网页驱动内部错误"
        default: return errorCode.isEmpty ? "未知错误" : errorCode
        }
    }

    /// Strict reading of the vote marker: only the last non-empty line may
    /// decide the stance, and that line must be exactly
    /// `STANCE: agree|conditional|oppose`.
    ///
    /// A marker quoted in the body (an earlier round, another seat's answer,
    /// an example) or a bare `同意`/`反对` in the reasoning is never a stance.
    /// A stance the user picked by hand is passed separately and never goes
    /// through this parser.
    static func parseStance(_ text: String) -> String? {
        let lastLine = text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        guard let lastLine else { return nil }

        switch lastLine {
        case "STANCE: agree": return "agree"
        case "STANCE: conditional": return "conditional"
        case "STANCE: oppose": return "oppose"
        default: return nil
        }
    }

    static func normalizeStance(_ raw: String) -> String? {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。.!！,，;；\"'"))
            .lowercased()
        switch value {
        case "agree", "yes", "同意", "赞成", "支持":
            return "agree"
        case "conditional", "conditional-agreement", "有条件同意", "有条件", "附条件同意":
            return "conditional"
        case "oppose", "no", "反对", "不同意":
            return "oppose"
        default:
            return nil
        }
    }

    static func stanceDisplay(_ stance: String) -> String {
        switch stance {
        case "agree": return "同意"
        case "conditional": return "有条件同意"
        case "oppose": return "反对"
        default: return stance
        }
    }
}
