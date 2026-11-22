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

@MainActor
final class ArenaModel: ObservableObject {

    // MARK: Public state

    /// The question shown on the start screen.
    @Published var question: String = ""

    /// Latest session document produced by `arena-core.js`.
    @Published private(set) var session: [String: Any]?

    /// One short, user-facing status per provider.
    @Published private(set) var statuses: [String: String] = [:]

    /// Last blocking or informational error. Seat-level problems stay in
    /// `statuses` so one failing site does not hide the other two.
    @Published var errorMessage: String = ""

    /// Web panes owned by the discussion, keyed by provider id.
    @Published private(set) var panes: [String: SitePane] = [:]

    /// Live answer preview (tail of the generating response), never saved as
    /// the accepted answer.
    @Published private(set) var previews: [String: String] = [:]

    @Published private(set) var stageKey: String = ""
    @Published private(set) var stageLabel: String = "尚未开始"
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var isReadOnly: Bool = false
    @Published private(set) var isRecovering: Bool = false
    @Published private(set) var recoveryNotice: String = ""

    // MARK: Private state

    private let engine: ArenaEngine
    private var runToken = UUID()
    private var dispatcher: Task<Void, Never>?
    private var workers: [String: Task<Void, Never>] = [:]

    private var manualProviders: Set<String> = []
    private var blockedTasks: Set<String> = []
    private var intents: [String: ArenaDeliveryIntent] = [:]

    private var currentID: String?
    private var createdAt: Double = 0
    private var storageFailed = false
    private var historyCache: [(id: String, question: String)] = []

    /// How long a normal start keeps probing a real site whose composer has not
    /// mounted yet. The bound is deliberately inside the agreed 30–38 s window,
    /// and `probe` neither fills nor clicks, so retrying here cannot deliver.
    private static let realProbeWindowSeconds: TimeInterval = 34
    /// Fixture pages mount immediately; a long window would only delay failures.
    private static let fixtureProbeWindowSeconds: TimeInterval = 6
    /// Bounded read-only window used to re-check a task whose submit may have
    /// already run. Only `read` is used inside it.
    private static let verifyWindowSeconds: TimeInterval = 20

    // MARK: Init / restore

    init() {
        self.engine = ArenaEngine()
        if let issue = engine.configurationIssue {
            self.errorMessage = issue
        }
        refreshHistoryCache()
        restoreLastSession()
        prepareInitialPanes()
    }

    /// Saved discussions, newest first. Reading this never sends anything.
    var historyList: [(id: String, question: String)] {
        historyCache
    }

    // MARK: Discussion lifecycle

    /// Start a new discussion with two or three distinct provider ids.
    ///
    /// The core session is created first, then every seat's original site is
    /// opened at its new-conversation entry page. Independent answers, peer
    /// critique, proposal and same-version votes are then driven in parallel.
    func start(_ providers: [String]) {
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
            created = try engine.createSession(question: trimmed, providers: providers)
        } catch {
            errorMessage = "无法建立场次：\(error.localizedDescription)"
            return
        }

        session = created
        isReadOnly = false
        isRecovering = false
        recoveryNotice = ""
        isPaused = false
        storageFailed = false
        intents.removeAll()
        manualProviders.removeAll()
        blockedTasks.removeAll()
        previews.removeAll()
        statuses.removeAll()
        currentID = created.arenaString("id")
        createdAt = Self.nowMillis()
        errorMessage = ""

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
            setStatus(provider, "打开原页…")
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
        let nextPaused = !isPaused
        do {
            self.session = try engine.apply(
                session: session,
                action: nextPaused ? "pause" : "resume",
                payload: [:]
            )
        } catch {
            errorMessage = "无法\(nextPaused ? "暂停" : "继续")：\(error.localizedDescription)"
            return
        }
        isPaused = self.session?.arenaBool("paused") ?? nextPaused
        refreshStage()
        persist()

        for provider in currentProviders {
            guard let pending = pendingTask(for: provider) else { continue }
            if isPaused {
                setStatus(provider, "已暂停")
            } else if manualProviders.contains(provider) {
                setStatus(provider, "等待你处理")
            } else if blockedTasks.contains(pending.arenaString("id") ?? "") {
                setStatus(provider, "需要你核对原页")
            } else if intents[pending.arenaString("id") ?? ""]?.phase == .submitted {
                setStatus(provider, "继续读取回答…")
            } else if let phase = intents[pending.arenaString("id") ?? ""]?.phase,
                      phase == .inflight || phase == .uncertain {
                setStatus(provider, "可能已发送，需你核对原页（不会重发）")
            } else {
                setStatus(provider, "继续…")
            }
        }
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
            setStatus(provider, finalStatus(for: provider))
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
        if let pending = pendingTask(for: provider) {
            blockedTasks.remove(pending.arenaString("id") ?? "")
            setStatus(provider, "已接管，等待你核对原页")
        } else {
            setStatus(provider, "已接管")
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
        if manualProviders.contains(provider), let pane = panes[provider],
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
            setStatus(provider, "本地保存失败，暂未恢复")
            return
        }

        let name = displayName(provider)
        switch intents[taskID]?.phase {
        case .submitted:
            setStatus(provider, "恢复只读：继续读取本轮回答…")
            if isRecovering {
                recoveryNotice = "已恢复上次讨论。「\(name)」只读继续本轮回答，不会重发；其他席位仍为人工核对。"
            }
        case .inflight, .uncertain:
            setStatus(provider, "恢复只读：可能已发送，只核对不重发…")
            if isRecovering {
                recoveryNotice = "已恢复上次讨论。「\(name)」本轮可能已发送，只做只读核对，不会重发；其他席位仍为人工核对。"
            }
        case .prepared, .none:
            setStatus(provider, "恢复自动：准备本轮提示…")
            if isRecovering {
                recoveryNotice = "已恢复上次讨论。「\(name)」尚未发送的任务恢复自动派发；其他席位仍为人工核对。"
            }
        }

        if workers[taskID] == nil {
            if isPaused {
                // Keep the decision; the dispatcher starts the task after the
                // user resumes the discussion.
                setStatus(provider, "已暂停；继续讨论后生效")
            } else {
                launchWorker(provider: provider, task: task, token: runToken)
            }
        }
        ensureDispatcher(token: runToken)
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
        expected: ArenaManualTarget? = nil
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
        var stanceLabelText: String?
        if stageKey == "vote" {
            let resolved = stance.flatMap(Self.normalizeStance)
                ?? Self.parseStance(trimmed)
            guard let resolved else {
                errorMessage = "表决需要明确立场：同意、有条件同意或反对"
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

        blockedTasks.remove(taskID)
        previews[provider] = nil
        errorMessage = ""
        refreshStage()
        persist()
        markIdleSeats()
        if let label = stanceLabelText {
            setStatus(provider, "已表态：\(label)")
        } else {
            setStatus(provider, "已提交回答")
        }
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
        setStatus(provider, "已跳过")
        refreshStage()
        persist()
        markIdleSeats()
    }

    // MARK: History

    /// Open a saved discussion for read-only review. This never re-creates a
    /// delivery loop and never opens or sends to a site.
    func openHistory(_ id: String) {
        guard let file = engine.store.load(id: id) else {
            errorMessage = "找不到该历史场次"
            return
        }
        guard let saved = Self.decodeSession(file.sessionJSON) else {
            errorMessage = "该历史场次的记录已损坏"
            return
        }
        stopRunningWork()
        session = saved
        isReadOnly = true
        isRecovering = true
        isPaused = saved.arenaBool("paused") ?? false
        currentID = file.id
        question = file.question
        createdAt = file.createdAt
        intents = Dictionary(uniqueKeysWithValues: file.intents.map { ($0.taskId, $0) })
        manualProviders = Set(saved.arenaStringArray("providers"))
        blockedTasks.removeAll()
        previews.removeAll()
        statuses.removeAll()
        for provider in saved.arenaStringArray("providers") {
            _ = ensurePane(for: provider)
            setStatus(provider, "只读回看")
        }
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
        createdAt = 0
        intents.removeAll()
        manualProviders.removeAll()
        blockedTasks.removeAll()
        previews.removeAll()
        statuses.removeAll()
        isReadOnly = false
        isRecovering = false
        isPaused = false
        storageFailed = false
        recoveryNotice = ""
        errorMessage = ""
        stageKey = ""
        stageLabel = "尚未开始"
        engine.store.setCurrent(nil)
        refreshHistoryCache()
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
                setStatus(provider, "等待你处理")
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

    private func runSeat(provider: String, task: [String: Any], token: UUID) async {
        guard token == runToken, !isReadOnly, !isPaused else { return }
        guard let taskID = task.arenaString("id"),
              let prompt = task.arenaString("prompt"),
              !prompt.isEmpty else { return }

        let config: ArenaSiteConfig
        do {
            config = try engine.config(for: provider)
        } catch {
            setStatus(provider, "需要你处理：\(error.localizedDescription)")
            return
        }
        guard let pane = panes[provider] else {
            setStatus(provider, "需要你处理：原页不可用")
            return
        }
        if manualProviders.contains(provider) {
            setStatus(provider, "已接管，等待你核对原页")
            return
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
                setStatus(provider, "继续读取本轮回答…")
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
                break // The submit command was never issued for this intent.
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

        var attempt = 0
        while attempt < 8 {
            guard await waitWhilePaused(token) else { return false }
            if manualProviders.contains(provider) {
                setStatus(provider, "已接管，等待你核对原页")
                return false
            }
            guard isCurrentPending(taskID) else { return false }

            var intent = intents[taskID] ?? ArenaDeliveryIntent(
                taskId: taskID,
                prompt: prompt,
                stage: stageKey,
                round: currentRound,
                phase: .prepared,
                preparedAt: Self.nowMillis(),
                submittedAt: nil,
                pageURL: nil
            )
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
                setStatus(provider, "本地保存失败，未发送；请先处理存储")
                return false
            }
            setStatus(provider, "发送中…")

            let response: [String: Any]
            do {
                response = try await pane.command(
                    engine.driverMessage(
                        kind: "submit",
                        taskID: taskID,
                        prompt: intent.prompt,
                        config: config
                    )
                )
            } catch {
                // The click may have happened. Only record the outcome for the
                // discussion and seat that are still current.
                guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
                    return false
                }
                // 原页被换到同站别的对话：Swift 在发命令前就拒绝了，什么都没发出。
                // 停在本轮转人工，不记“可能已发送”，也不做只读核对。
                if stopOnConversationChange(error, provider: provider, taskID: taskID) {
                    intent.phase = .prepared
                    intent.pageURL = nil
                    intents[taskID] = intent
                    persist()
                    return false
                }
                // Outcome unknown: never retry.
                intent.phase = .uncertain
                intents[taskID] = intent
                persist()
                blockedTasks.insert(taskID)
                setStatus(provider, "发送结果待确认：\(Self.short(error.localizedDescription))")
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
            pane.bindVerifiedConversation(from: response)

            let status = response.arenaString("status") ?? ""
            if status == "submitted" || status == "pending" || status == "done" {
                intent.phase = .submitted
                intent.submittedAt = Self.nowMillis()
                intent.pageURL = pane.boundConversationURL?.absoluteString ?? intent.pageURL
                intents[taskID] = intent
                persist()
                blockedTasks.remove(taskID)
                if status == "done",
                   let text = response.arenaString("text"),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    deliver(provider: provider, task: task, text: text)
                    return false
                }
                setStatus(provider, "已发送，等待回答…")
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

            switch code {
            case "send-pending" where explicitlyPreClick:
                intent.phase = .prepared
                intents[taskID] = intent
                persist()
                setStatus(provider, "等待发送控件…")
                attempt += 1
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            case "prompt-already-sent":
                // This round's prompt is already on the page; read only.
                intent.phase = .submitted
                intent.submittedAt = Self.nowMillis()
                intents[taskID] = intent
                persist()
                setStatus(provider, "本轮提问已在原页，只读核对…")
                return true
            default:
                if explicitlyPreClick {
                    // The page says no click happened; the button may mount.
                    intent.phase = .prepared
                    intents[taskID] = intent
                    persist()
                    setStatus(provider, "等待发送控件…")
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                } else if code == "draft-conflict" {
                    // An explicit input conflict that the driver rejected before
                    // any click. Never retried automatically; a human decides.
                    intent.phase = .prepared
                    intents[taskID] = intent
                    persist()
                    blockedTasks.insert(taskID)
                    setStatus(provider, "需要你处理：\(Self.friendly(errorCode: code))")
                    return false
                } else {
                    // Unknown or post-click failure: the submit may already have
                    // happened. Only `read` may confirm it from here.
                    intent.phase = .uncertain
                    intents[taskID] = intent
                    persist()
                    blockedTasks.insert(taskID)
                    setStatus(provider, "发送结果待确认，只读核对原页（不会重发）…")
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
        setStatus(provider, "发送控件长时间未就绪，请核对原页")
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
        var attempt = 0

        while true {
            guard !Task.isCancelled else { return nil }
            guard await waitWhilePaused(token) else { return nil }
            if manualProviders.contains(provider) {
                setStatus(provider, "已接管，等待你核对原页")
                return nil
            }
            guard isCurrentPending(taskID) else { return nil }
            setStatus(provider, attempt == 0 ? "检查原页…" : "等待原页就绪…")
            do {
                let response = try await pane.command(
                    engine.driverMessage(
                        kind: "probe",
                        taskID: taskID,
                        prompt: nil,
                        config: config
                    )
                )
                guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
                    return nil
                }
                let status = response.arenaString("status") ?? ""
                if status == "ready" {
                    if let detail = response["detail"] as? [String: Any],
                       let known = detail["knownTask"] as? [String: Any],
                       (known.arenaString("status") == "submitted"
                        || known.arenaString("status") == "done") {
                        // The page still remembers this task id: adopt it and
                        // read only. Never submit a second time.
                        intents[taskID] = ArenaDeliveryIntent(
                            taskId: taskID,
                            prompt: intents[taskID]?.prompt ?? currentTask(taskID)?.arenaString("prompt") ?? "",
                            stage: stageKey,
                            round: currentRound,
                            phase: .submitted,
                            preparedAt: intents[taskID]?.preparedAt ?? Self.nowMillis(),
                            submittedAt: Self.nowMillis(),
                            pageURL: pane.boundConversationURL?.absoluteString
                        )
                        persist()
                        setStatus(provider, "已发送，只读核对中…")
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
                setStatus(provider, "需要你处理：\(Self.friendly(errorCode: code))")
                return nil
            } catch {
                guard token == runToken, !isReadOnly else { return nil }
                // 本轮会话被换走：立即转人工，不做 34 秒的瞬态重试。
                if stopOnConversationChange(error, provider: provider, taskID: taskID) {
                    return nil
                }
                if Date() < deadline, !Task.isCancelled {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                }
                blockedTasks.insert(taskID)
                setStatus(provider, "需要你处理：原页命令失败（\(Self.short(error.localizedDescription))）")
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

        while true {
            if token != runToken || isReadOnly { return }
            if manualProviders.contains(provider) {
                setStatus(provider, "已接管，等待你核对原页")
                return
            }
            guard await waitWhilePaused(token) else { return }
            guard isCurrentPending(taskID) else { return }

            do {
                let response = try await pane.command(
                    engine.driverMessage(
                        kind: "read",
                        taskID: taskID,
                        prompt: nil,
                        config: config
                    )
                )
                // Ignore a late read that belongs to a replaced discussion, a
                // finished task, or a seat the user took over meanwhile.
                guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
                    return
                }
                pane.bindVerifiedConversation(from: response)
                consecutiveErrors = 0
                let status = response.arenaString("status") ?? ""
                let code = response.arenaString("error") ?? ""

                switch status {
                case "done":
                    let text = (response.arenaString("text") ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        blockedTasks.insert(taskID)
                        setStatus(provider, "回答为空，请核对原页")
                        return
                    }
                    previews[provider] = nil
                    deliver(provider: provider, task: task, text: text)
                    return
                case "pending":
                    if let detail = response["detail"] as? [String: Any],
                       let preview = detail["preview"] as? [String: Any],
                       let text = preview.arenaString("text") {
                        previews[provider] = text
                    }
                    setStatus(provider, "正在生成…")
                case "submitted", "ready":
                    if !showedSubmitted {
                        setStatus(provider, "已发送，等待回答…")
                        showedSubmitted = true
                    }
                case "unknown":
                    blockedTasks.insert(taskID)
                    setStatus(provider, "需要你核对原页（\(Self.friendly(errorCode: code.isEmpty ? "unknown" : code))）")
                    return
                default:
                    if code == "document-not-ready" || code == "not-authorized-page" {
                        if !showedSubmitted {
                            setStatus(provider, "等待原页就绪…")
                            showedSubmitted = true
                        }
                    } else {
                        blockedTasks.insert(taskID)
                        setStatus(provider, "需要你核对原页：\(Self.friendly(errorCode: code))")
                        return
                    }
                }
            } catch {
                if stopOnConversationChange(error, provider: provider, taskID: taskID) {
                    return
                }
                consecutiveErrors += 1
                if Date() >= deadline || consecutiveErrors >= 20 {
                    blockedTasks.insert(taskID)
                    setStatus(provider, "读取中断，请核对原页（\(Self.short(error.localizedDescription))）")
                    return
                }
                setStatus(provider, "读取中断，重试…")
            }

            if Date() >= deadline {
                blockedTasks.insert(taskID)
                setStatus(provider, "生成超时，请核对原页")
                return
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
    }

    // MARK: Deliver

    private func deliver(provider: String, task: [String: Any], text: String) {
        guard !manualProviders.contains(provider) else {
            setStatus(provider, "已接管，未自动回填")
            return
        }
        guard let session, !isReadOnly else { return }
        guard let taskID = task.arenaString("id"), isCurrentPending(taskID) else { return }

        var payload: [String: Any] = [
            "taskId": taskID,
            "text": text,
            "stage": stageKey,
            "round": currentRound,
        ]
        var stanceText: String?
        if stageKey == "vote" {
            guard let stance = Self.parseStance(text) else {
                // The model has to state its stance explicitly. Keep the text
                // visible so the user can take over without losing it.
                previews[provider] = text
                blockedTasks.insert(taskID)
                setStatus(provider, "已收到回答，但缺少明确立场；请接管后选择")
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
            previews[provider] = text
            blockedTasks.insert(taskID)
            setStatus(provider, "回答未采用：\(Self.short(error.localizedDescription))")
            return
        }

        previews[provider] = nil
        if let stanceText {
            setStatus(provider, "已表态：\(stanceText)")
        } else {
            setStatus(provider, "已收到回答")
        }
        refreshStage()
        persist()
        markIdleSeats()
    }

    // MARK: - Helpers

    private func stopRunningWork() {
        runToken = UUID()
        dispatcher?.cancel()
        dispatcher = nil
        for (_, task) in workers { task.cancel() }
        workers.removeAll()
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

    /// 原页被换到同站别的对话时，Swift 在发命令前就拒绝（web-driver 也会在
    /// 最后一次填入/点击前再拒绝一次）。两种拒绝都停在本轮转人工核对：
    /// 不发、不重试，也不把“没发出”记成可能已发送。
    @discardableResult
    private func stopOnConversationChange(_ error: Error, provider: String, taskID: String) -> Bool {
        guard let paneError = error as? SitePaneError, paneError.isConversationChanged else {
            return false
        }
        blockedTasks.insert(taskID)
        setStatus(provider, "已转人工：\(paneError.localizedDescription)")
        return true
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

        while true {
            guard !Task.isCancelled else { return .stopped }
            guard await waitWhilePaused(token) else { return .stopped }
            guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
                return .stopped
            }
            do {
                let response = try await pane.command(
                    engine.driverMessage(
                        kind: "read",
                        taskID: taskID,
                        prompt: nil,
                        config: config
                    )
                )
                guard callbackIsCurrent(token: token, taskID: taskID, provider: provider) else {
                    return .stopped
                }
                pane.bindVerifiedConversation(from: response)
                let status = response.arenaString("status") ?? ""
                let code = response.arenaString("error") ?? ""
                switch status {
                case "done":
                    let text = (response.arenaString("text") ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? .unconfirmed("原页回答为空") : .answered(text)
                case "pending":
                    // The driver only knows a task after a submit started.
                    return .generating
                case "unknown":
                    return .unconfirmed(Self.friendly(errorCode: code.isEmpty ? "unknown" : code))
                default:
                    if code == "document-not-ready" || code == "not-authorized-page",
                       Date() < deadline {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        continue
                    }
                    return .unconfirmed(Self.friendly(errorCode: code.isEmpty ? status : code))
                }
            } catch {
                guard token == runToken, !isReadOnly, !Task.isCancelled else { return .stopped }
                if let paneError = error as? SitePaneError, paneError.isConversationChanged {
                    blockedTasks.insert(taskID)
                    setStatus(provider, "已转人工：\(paneError.localizedDescription)")
                    return .unconfirmed("原页对话已更换")
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
            setStatus(provider, "原页已确认本轮提问，只读读取回答…")
            return true
        case .answered(let text):
            promoteToSubmitted(taskID: taskID, task: task, pane: pane)
            blockedTasks.remove(taskID)
            previews[provider] = nil
            deliver(provider: provider, task: task, text: text)
            return false
        case .unconfirmed(let why):
            blockedTasks.insert(taskID)
            setStatus(provider, "需处理：只读核对未确认（\(why)）；不会重发")
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
        if engine.fixtureBase != nil,
           let config = try? engine.config(for: provider) {
            return SitePane.testPane(
                provider: provider,
                loopbackURL: config.url,
                selectors: Self.stringSelectors(config.selectors),
                options: config.options,
                allowNavigation: config.allowNavigation
            )
        }
        return SitePane(provider: provider)
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

    private func setStatus(_ provider: String, _ text: String) {
        if statuses[provider] != text {
            statuses[provider] = text
        }
    }

    private func refreshStage() {
        guard let session else {
            stageKey = ""
            stageLabel = "尚未开始"
            return
        }
        stageKey = session.arenaString("stage") ?? ""
        let round = currentRound
        var label: String
        switch stageKey {
        case "independent":
            label = "独立作答 · 第\(round)轮"
        case "critique":
            label = "交叉质询 · 第\(round)轮"
        case "proposal":
            label = "起草候选 · 第\(round)轮"
        case "vote":
            label = "逐席表态 · 第\(round)轮"
        case "done":
            label = "讨论已结束"
        default:
            label = "准备中"
        }
        if isReadOnly {
            label += "（历史回看）"
        }
        stageLabel = label
    }

    /// Give seats without work a truthful resting status. Never touches a
    /// seat that is blocked or manually waiting.
    private func markIdleSeats() {
        guard stageKey != "done" else {
            for provider in currentProviders {
                setStatus(provider, finalStatus(for: provider))
            }
            return
        }
        for provider in currentProviders {
            guard pendingTask(for: provider) == nil else { continue }
            if manualProviders.contains(provider) {
                setStatus(provider, "本轮已完成（等待其他席位）")
            } else if !statuses[provider, default: ""].contains("需要") {
                setStatus(provider, "本轮已完成")
            }
        }
    }

    private func finalStatus(for provider: String) -> String {
        let history = (session?["history"] as? [[String: Any]]) ?? []
        let votes = history.filter {
            $0.arenaString("provider") == provider &&
            $0.arenaString("stage") == "vote" &&
            $0.arenaString("status") == "answered"
        }
        if let vote = votes.last, let stance = vote.arenaString("stance") {
            return "最终表态：\(Self.stanceDisplay(stance))"
        }
        let skips = history.filter {
            $0.arenaString("provider") == provider &&
            $0.arenaString("status") == "skipped"
        }
        if !skips.isEmpty {
            return "已结束（有跳过）"
        }
        return "讨论已结束"
    }

    // MARK: Persistence

    /// Writes the current session and delivery intents atomically.
    ///
    /// Returns `false` when nothing was written (read-only, no session, or a
    /// storage failure). Callers that are about to send must treat `false` as
    /// "stop": an intent that is not durable cannot guard a later restart.
    @discardableResult
    private func persist() -> Bool {
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
            manualProviders: manualProviders.sorted(),
            pageURLs: pageURLs,
            stopReason: session.arenaString("stopReason")
        )

        if let failure = engine.store.save(file) {
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
        refreshHistoryCache()
        return true
    }

    private func restoreLastSession() {
        guard let id = engine.store.currentID(),
              let file = engine.store.load(id: id),
              let saved = Self.decodeSession(file.sessionJSON) else {
            return
        }
        session = saved
        currentID = file.id
        question = file.question
        createdAt = file.createdAt
        intents = Dictionary(uniqueKeysWithValues: file.intents.map { ($0.taskId, $0) })
        manualProviders = Set(saved.arenaStringArray("providers"))
        blockedTasks.removeAll()
        previews.removeAll()
        isReadOnly = false
        isRecovering = true
        isPaused = saved.arenaBool("paused") ?? false
        statuses.removeAll()

        for provider in saved.arenaStringArray("providers") {
            if let pending = pendingTask(for: provider) {
                if let phase = intents[pending.arenaString("id") ?? ""]?.phase,
                   phase == .submitted {
                    setStatus(provider, "已恢复：此前已发送，请核对原页（不会重发）")
                } else {
                    setStatus(provider, "已恢复：请核对原页（不会重发）")
                }
            } else if saved.arenaString("stage") == "done" {
                setStatus(provider, finalStatus(for: provider))
            } else {
                setStatus(provider, "本轮已完成")
            }
        }
        recoveryNotice = "已恢复上次讨论。为避免重复发送，本场改为人工核对：可打开原页核对后粘贴回答，或跳过；新建讨论才会恢复自动派发。"
        refreshStage()
    }

    private func refreshHistoryCache() {
        historyCache = engine.store.summaries().map { (id: $0.id, question: $0.question) }
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
        case "conversation-changed": return "原页已切换到别的对话，未发送；请切回本场对话或接管"
        case "selector-missing": return "原页缺少输入或发送控件（站点可能改版）"
        case "selector-ambiguous": return "原页控件不唯一"
        case "selector-overlap": return "消息选择器重叠"
        case "selector-invalid": return "站点选择器无效"
        case "input-uneditable": return "输入框无法编辑"
        case "input-disabled": return "输入框被禁用"
        case "input-readonly": return "输入框只读"
        case "draft-conflict": return "原页已有未发送草稿，未覆盖"
        case "busy": return "原页正有另一任务"
        case "prompt-already-sent": return "原页已有本轮提问，不再重发"
        case "submit-unconfirmed": return "可能已发送，只能人工核对"
        case "user-turn-mismatch": return "未核对到本轮提问"
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
