//
//  ArenaFeedback.swift
//  AI Arena · 窗口内短暂反馈与本场完成通知
//
//  反馈：复制、导出等动作在发起窗口显示一条非模态提示。主窗口和详情窗口
//  各自持有一个 presenter；详情窗口的 AppKit 工具栏也复用同一个 presenter。
//  提示不抢焦点、不吃点击、不参与布局，重复动作替换上一条并重新计时。
//
//  完成通知：ArenaModel 只在一次真正成功的持久化把场次从非 done 推进到
//  done 时报告完成；启动/历史恢复既有的已完成场次不会重复通知。通知内容
//  不包含题面或回答，只用场次 ID 做内部路由。QA 和夹具进程完全不接触
//  系统通知授权。
//

import SwiftUI
import AppKit
@preconcurrency import UserNotifications

// MARK: - 复制

enum ArenaClipboard {
    /// Returns the pasteboard's own success value so callers can report a real
    /// failure instead of assuming the write happened.
    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

// MARK: - 短暂反馈

enum ArenaFeedbackTone: Equatable {
    case success
    case failure

    fileprivate var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    fileprivate var symbolColor: Color {
        switch self {
        case .success: return .accentColor
        case .failure: return .orange
        }
    }
}

struct ArenaFeedbackMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let tone: ArenaFeedbackTone
}

@MainActor
final class ArenaFeedbackPresenter: ObservableObject {
    static let duration: TimeInterval = 2.6
    static let copiedText = "已复制到剪贴板"
    static let copyFailedText = "复制失败，请重试"

    @Published private(set) var message: ArenaFeedbackMessage?

    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, tone: ArenaFeedbackTone = .success) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        dismissTask?.cancel()
        let next = ArenaFeedbackMessage(text: trimmed, tone: tone)
        withAnimation(.easeOut(duration: 0.15)) {
            message = next
        }
        ArenaAccessibilityAnnouncer.announce(trimmed)

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.message?.id == next.id else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self.message = nil
            }
        }
    }

    func copyToPasteboard(_ text: String) {
        if ArenaClipboard.copy(text) {
            show(Self.copiedText)
        } else {
            show(Self.copyFailedText, tone: .failure)
        }
    }
}

struct ArenaFeedbackOverlay: View {
    @ObservedObject var presenter: ArenaFeedbackPresenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let message = presenter.message {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: message.tone.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(message.tone.symbolColor)
                        .accessibilityHidden(true)
                    Text(message.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.12))
                )
                .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
                .frame(maxWidth: 460)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(message.text)
                .accessibilityAddTraits(.isStaticText)
                .id(message.id)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: presenter.message?.id)
    }
}

enum ArenaAccessibilityAnnouncer {
    @MainActor
    static func announce(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: trimmed,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

// MARK: - 完成事件

/// A durable transition into `done`, produced only after the session file was
/// written successfully. It carries no question or answer text.
struct ArenaCompletionEvent: Equatable, Sendable {
    let sessionID: String
    let explicitFinish: Bool
}

/// Remembers the last persisted session/stage so a completion is reported once,
/// and only on a real transition from a running stage into `done`.
struct ArenaCompletionTracker {
    private var durableSessionID: String?
    private var durableStage: String?

    mutating func adopt(sessionID: String?, stage: String?) {
        durableSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        durableStage = stage
    }

    mutating func reset() {
        durableSessionID = nil
        durableStage = nil
    }

    mutating func recordPersisted(
        sessionID: String,
        stage: String,
        explicitFinish: Bool = false
    ) -> ArenaCompletionEvent? {
        let previousSessionID = durableSessionID
        let previousStage = durableStage
        durableSessionID = sessionID
        durableStage = stage

        guard previousSessionID == sessionID,
              previousStage != nil,
              previousStage != "done",
              stage == "done" else {
            return nil
        }
        return ArenaCompletionEvent(
            sessionID: sessionID,
            explicitFinish: explicitFinish
        )
    }
}

// MARK: - 完成事件路由

enum ArenaCompletionDelivery: Equatable {
    case presentReport
    case notification
    case silent
}

enum ArenaCompletionPolicy {
    /// Foreground keeps the existing behaviour of opening the report. A
    /// background automatic completion gets one local notification. An
    /// explicit 「结束」 in the background stays silent because the user already
    /// knows the discussion ended.
    static func delivery(isForeground: Bool, explicitFinish: Bool) -> ArenaCompletionDelivery {
        if isForeground { return .presentReport }
        return explicitFinish ? .silent : .notification
    }
}

// MARK: - 本地完成通知

/// UserNotifications wrapper for completed discussions. It never runs for the
/// QA/fixture process, never asks for permission outside a real user action,
/// and stores only the session ID for routing a click back to that report.
@MainActor
final class ArenaCompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ArenaCompletionNotifier()
    nonisolated static let sessionKey = "arena.session.id"

    /// Set by the app delegate. Called on the main actor after a click.
    var onOpenSession: ((String) -> Void)?

    /// QA builds and fixture runs must not touch the notification center at all.
    nonisolated static var isEnabled: Bool {
        !ArenaBuildIsolation.isQABuild
            && ProcessInfo.processInfo.environment["ARENA_FIXTURE_BASE"] == nil
    }

    private override init() {
        super.init()
    }

    func activate() {
        guard Self.isEnabled else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Called from the real 「开始讨论」 and 「继续这一场」 actions. The first
    /// suitable interaction may ask for alert/sound permission; later calls
    /// only observe the current setting.
    func prepareForCompletionAlerts() {
        guard Self.isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func notifyCompletion(_ event: ArenaCompletionEvent) {
        guard Self.isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { settings in
            guard Self.allowsDelivery(settings.authorizationStatus) else { return }

            let content = UNMutableNotificationContent()
            content.title = "讨论已结束"
            content.body = "报告已保存。点按这里查看本场结果。"
            content.sound = .default
            content.threadIdentifier = "arena.completion"
            content.userInfo = [Self.sessionKey: event.sessionID]

            let request = UNNotificationRequest(
                identifier: "arena.completion.\(event.sessionID)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    nonisolated private static func allowsDelivery(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let sessionID = response.notification.request.content.userInfo[Self.sessionKey] as? String,
              !sessionID.isEmpty else {
            return
        }
        Task { @MainActor [weak self] in
            self?.onOpenSession?(sessionID)
        }
    }
}
