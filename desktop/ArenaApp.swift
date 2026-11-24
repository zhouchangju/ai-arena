//
//  ArenaApp.swift
//  AI Arena 独立 macOS 工作台（SwiftUI + WKWebView）
//
//  本文件负责：应用入口、主窗口界面、会话阅读/原生 Markdown 导出，
//  以及 --smoke-test 终端验收。讨论状态与轮次推进由 ArenaModel 负责，
//  单席真实网页由 SitePane 负责。三者一起由 desktop/build.sh 编译，
//  并把 web-driver.js / sites.json / arena-core.js 放入 App 资源。
//
//  首次启动由 ArenaModel 打开三席原页（chatgpt / gemini / deepseek）
//  以便登录；设置 ARENA_FIXTURE_BASE=http://127.0.0.1[:端口] 时由模型
//  改用 SitePane.testPane 打开回环 /<provider> 页面。
//
//  回环验收由 tests/native_desktop_acceptance.py 创建独立的 QA 应用。
//  仅 QA 身份接受 --smoke-test；正式应用在创建 WebView 前拒绝该入口。
//  三窗真正加载完成后，用同一 model.start 发送合成问题；stage 变为
//  done 时写出 session JSON 并退出（0）。超时或未就绪时写出诊断并退出
//  （1 超时 / 2 缺结果路径 / 3 非回环夹具 / 4 三窗未就绪）。
//  未设置回环夹具时默认拒绝运行，不向真实站点启用。
//

import SwiftUI
import WebKit
import AppKit
import Security
import UniformTypeIdentifiers

// MARK: - 席位目录

enum ArenaSeatCatalog {
    /// 与扩展版一致的站点顺序；也是默认三席顺序。
    static let ordered = ["chatgpt", "gemini", "deepseek"]

    static let homes: [String: String] = [
        "chatgpt": "https://chatgpt.com/",
        "gemini": "https://gemini.google.com/app",
        "deepseek": "https://chat.deepseek.com/",
    ]

    static func name(_ provider: String) -> String {
        switch provider.lowercased() {
        case "chatgpt": return "ChatGPT"
        case "gemini": return "Gemini"
        case "deepseek": return "DeepSeek"
        default:
            guard let first = provider.first else { return provider }
            return String(first).uppercased() + provider.dropFirst()
        }
    }
}

// MARK: - SwiftUI 包装

/// 只挂载一次真实 webView；update 不触发任何页面重载。
struct SitePaneView: NSViewRepresentable {
    @ObservedObject var pane: SitePane

    func makeNSView(context: Context) -> WKWebView {
        return pane.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 保持原页滚动、图片与交互状态，不做重绘或重载。
    }
}

// MARK: - 系统玻璃背景

/// 原生 vibrancy 玻璃。用户开启“降低透明度”或系统不提供该材质时退回
/// 不透明窗口底色，避免在辅助功能模式下出现低对比度文字。
struct ArenaGlassSurface: View {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var cornerRadius: CGFloat = 12

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            fallback
        } else if #available(macOS 13.0, *) {
            ArenaVibrancyView(material: material)
                .clipShape(shape)
                .overlay(shape.fill(Color.primary.opacity(0.015)))
        } else {
            fallback
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var fallback: some View {
        shape.fill(Color(nsColor: .windowBackgroundColor))
    }
}

/// 只负责一块视觉材质；不参与布局、不触达网页内容。
fileprivate struct ArenaVibrancyView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - 应用入口

/// Launch arguments that change the workbench's startup behaviour.
enum ArenaLaunchOptions {
    /// `--continue-saved-discussion <id>` (or `=<id>`) asks for one explicit,
    /// verified continuation of exactly that saved discussion. Without it a
    /// relaunch stays in the conservative manual-verification mode.
    static func continueSessionID() -> String? {
        let arguments = CommandLine.arguments
        var raw: String?
        if let index = arguments.firstIndex(of: "--continue-saved-discussion"),
           index + 1 < arguments.count {
            raw = arguments[index + 1]
        } else if let inline = arguments.first(where: {
            $0.hasPrefix("--continue-saved-discussion=")
        }) {
            raw = String(inline.dropFirst("--continue-saved-discussion=".count))
        }
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.hasPrefix("--") else {
            return nil
        }
        return value
    }
}

@main
struct ArenaDesktopApp: App {
    @NSApplicationDelegateAdaptor(ArenaAppDelegate.self) private var appDelegate

    init() {
        // 冒烟配置不合法时必须在 ArenaModel 创建（会打开原页）之前退出。
        SmokeRunner.preflight()
        // Apply the saved appearance before ArenaModel creates any WebView or
        // window. WKWebView identity and site-owned themes are left untouched.
        ArenaAppearancePreferences.shared.applyApplicationAppearance()
        appDelegate.model = ArenaModel(
            continueSessionID: ArenaLaunchOptions.continueSessionID()
        )
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    ArenaSettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class ArenaAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    @MainActor var model: ArenaModel?
    private var mainWindow: NSWindow?
    private var terminationConfirmed = false

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Arena"
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.contentView = NSHostingView(rootView: ArenaRootView(model: model))
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        window.setFrameAutosaveName("arena-main")
        mainWindow = window
        NSApp.setActivationPolicy(ArenaBuildIsolation.isQABuild ? .accessory : .regular)
        ArenaCompletionNotifier.shared.activate()
        ArenaCompletionNotifier.shared.onOpenSession = { [weak self] id in
            self?.openCompletedSession(id)
        }
        model.onDiscussionCompleted = { [weak self] event in
            self?.handleCompletion(event)
        }
        arenaPresentWindow(window)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow, !terminationConfirmed,
              model?.hasRunningDiscussion == true else { return true }
        // Ask through the same path as ⌘Q while the workbench is still visible.
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return false
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationConfirmed, let model, model.hasRunningDiscussion else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "仍有讨论在进行"
        alert.informativeText = "退出会停止后续派发。已发送的请求可能仍会在原页生成；之后可以从「历史」继续核对已保存的进度。"
        alert.addButton(withTitle: "退出")
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\r"
        alert.buttons[0].keyEquivalent = ""
        if alert.runModal() == .alertFirstButtonReturn {
            terminationConfirmed = true
            model.stopRunningWork()
            return .terminateNow
        }
        // The last window may already have closed. Bring the workbench back
        // instead of leaving an app with no window.
        if let main = mainWindow {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        }
        return .terminateCancel
    }

    /// Dock 点击或重新激活时，优先把主工作台带回前台。详情窗口是独立
    /// 辅助窗口，不能代替主窗口成为“重新打开”的落点。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if let main = mainWindow {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        } else if !ArenaDetailsWindowController.shared.focusIfVisible() {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // MARK: 完成后的落点

    /// A completion may arrive while the workbench is in the background. The
    /// policy keeps the old foreground behaviour (open the report), sends one
    /// local notification when backgrounded, and stays silent for an explicit
    /// 「结束」 that the user just triggered.
    @MainActor
    private func handleCompletion(_ event: ArenaCompletionEvent) {
        guard let model else { return }
        switch ArenaCompletionPolicy.delivery(
            isForeground: isCompletionForeground,
            explicitFinish: event.explicitFinish
        ) {
        case .presentReport:
            ArenaDetailsWindowController.shared.present(
                model: model,
                request: ArenaDetailRequest(provider: nil, tab: .report)
            )
        case .notification:
            ArenaCompletionNotifier.shared.notifyCompletion(event)
        case .silent:
            break
        }
    }

    /// A click on the completion notification returns to that session's report.
    /// A different running discussion is never stopped, switched or resent; the
    /// user can reach the finished session through the existing history menu.
    @MainActor
    private func openCompletedSession(_ id: String) {
        guard let model else { return }
        let currentID = ArenaSessionDigest.id(model.session)
        if currentID == id {
            ArenaDetailsWindowController.shared.present(
                model: model,
                request: ArenaDetailRequest(provider: nil, tab: .report)
            )
            return
        }
        guard !model.hasRunningDiscussion else {
            bringMainWindowForward()
            return
        }
        model.openHistory(id)
        guard ArenaSessionDigest.id(model.session) == id else {
            bringMainWindowForward()
            return
        }
        ArenaDetailsWindowController.shared.present(
            model: model,
            request: ArenaDetailRequest(provider: nil, tab: .report)
        )
    }

    /// Foreground means the app is active and at least one of its real windows
    /// is visible, so opening the report cannot pull focus from another app or
    /// from a minimised workbench.
    @MainActor
    private var isCompletionForeground: Bool {
        guard NSApp.isActive else { return false }
        if let mainWindow, mainWindow.isVisible, !mainWindow.isMiniaturized { return true }
        if let details = ArenaDetailsWindowController.shared.window,
           details.isVisible, !details.isMiniaturized { return true }
        return false
    }

    @MainActor
    private func bringMainWindowForward() {
        if let mainWindow {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            _ = ArenaDetailsWindowController.shared.focusIfVisible()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

}

// MARK: - 主界面

private func arenaPresentWindow(_ window: NSWindow) {
    if ArenaBuildIsolation.isQABuild {
        window.orderBack(nil)
    } else {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ArenaRootView: View {
    @ObservedObject var model: ArenaModel

    @State private var selectedProviders: Set<String> = Set(ArenaSeatCatalog.ordered)
    @State private var roundLimit = 3
    private var hasStarted: Bool { model.session != nil }
    @State private var confirmation: ArenaConfirmation?
    @State private var seatHint: String?
    @State private var hintTask: Task<Void, Never>?
    @StateObject private var feedback = ArenaFeedbackPresenter()
    @ObservedObject private var appearance = ArenaAppearancePreferences.shared

    private var usesPhotoBackdrop: Bool {
        appearance.backdropKind == .image && appearance.customImage != nil
    }

    @State private var questionFocused = false
    @State private var questionFocusRequest = 0
    @State private var previewAttachment: ArenaDraftAttachment?
    @State private var guidanceTarget: ArenaGuidanceTarget?
    @State private var showsHistorySearch = false
    @State private var pendingHistoryAction: HistoryAction?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum HistoryAction {
        case view(String)
        case resume(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = model.errorMessage.trimmedNonEmpty {
                errorBanner(message)
            }
            if model.isRecovering && isRunning && !model.recoveryNotice.isEmpty {
                Text(model.recoveryNotice)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            Divider()
            seatArea
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            ArenaFeedbackOverlay(presenter: feedback)
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
        }
        .task {
            model.prepareHome()
            if model.isRecovering && model.stageKey == "done" && !SmokeRunner.isEnabled {
                presentDetails(provider: nil, tab: .report)
            }
            SmokeRunner.shared.begin(model: model)
        }
        .alert(item: $confirmation) { item in
            switch item {
            case .newDiscussion:
                return Alert(
                    title: Text("新建讨论？"),
                    message: Text("当前讨论会停止并保留在历史中。已发送的请求可能仍会在原页生成；之后可从「历史」继续核对。"),
                    primaryButton: .destructive(Text("新建")) { performNewDiscussion() },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .finish:
                return Alert(
                    title: Text("结束整场讨论？"),
                    message: Text("将停止后续派发并生成当前报告，保留已保存的回答。已发送的请求可能仍会在原页生成。"),
                    primaryButton: .destructive(Text("结束整场")) { model.finish() },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .continueHistory(let id):
                return Alert(
                    title: Text("继续这一场？"),
                    message: Text(
                        (model.hasRunningDiscussion
                            ? "当前讨论会停止并保留在历史中。已发送的请求可能仍会在原页生成。"
                            : "")
                        + "各待处理席位会先等待你核对原页。你可以补录、跳过，或逐席恢复自动。可能已发送的任务只做只读核对。"
                    ),
                    primaryButton: .default(Text("继续")) { continueSaved(id) },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .openHistory(let id):
                return Alert(
                    title: Text("打开历史场次？"),
                    message: Text("当前讨论会停在已保存的进度。已发送的请求可能仍会在原页生成，之后可以从「历史」继续。"),
                    primaryButton: .default(Text("打开历史")) { openHistory(id) },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
        .sheet(isPresented: $showsHistorySearch, onDismiss: runPendingHistoryAction) {
            ArenaHistorySearchView(
                model: model,
                isRunning: isRunning,
                onView: { id in
                    pendingHistoryAction = .view(id)
                    showsHistorySearch = false
                },
                onResume: { id in
                    pendingHistoryAction = .resume(id)
                    showsHistorySearch = false
                },
                onClose: { showsHistorySearch = false }
            )
        }
        .sheet(item: $guidanceTarget) { target in
            ArenaGuidanceComposer(model: model, target: target) {
                guidanceTarget = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: hasStarted ? 9 : 11) {
            titleRow
            if hasStarted {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        lockedQuestionBar.frame(minWidth: 285)
                        actionBar.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(spacing: 8) { lockedQuestionBar; actionBar }
                }
            } else {
                composerCard
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ArenaQuestionBackdropView(preferences: appearance)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: hasStarted)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            Text("AI Arena")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .layoutPriority(1)

            Spacer(minLength: 10)

            ViewThatFits(in: .horizontal) {
                headerActions(compact: false)
                headerActions(compact: true)
            }
        }
    }

    @ViewBuilder
    private func headerActions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            historyMenu(compact: compact)
            if hasStarted {
                if compact {
                    iconToolButton("查看当前提示、历史原文、报告与原始记录", icon: "sidebar.right") {
                        presentDetails(provider: nil, tab: .prompts)
                    }
                    iconToolButton("以 Markdown 保存本场记录", icon: "square.and.arrow.up") {
                        ArenaExporter.export(model: model, feedback: feedback)
                    }
                } else {
                    toolButton("详情", icon: "sidebar.right") {
                        presentDetails(provider: nil, tab: .prompts)
                    }
                    .help("查看当前提示、历史原文、报告与原始记录")
                    toolButton("导出", icon: "square.and.arrow.up") {
                        ArenaExporter.export(model: model, feedback: feedback)
                    }
                    .help("以 Markdown 保存本场记录")
                }
            }

            iconToolButton("外观与设置（⌘,）", icon: "gearshape") {
                ArenaSettingsWindowController.shared.show()
            }
        }
    }

    private func toolButton(
        _ title: String,
        icon: String? = nil,
        large: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: large ? 12.5 : 11.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: large ? 14 : 13, weight: .medium))
            }
            .padding(.horizontal, 2)
            .frame(minHeight: large ? 32 : 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(large ? .large : .regular)
    }

    private func iconToolButton(
        _ help: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help(help)
        .accessibilityLabel(help)
    }

    private func historyMenu(compact: Bool) -> some View {
        Menu {
            Button {
                showsHistorySearch = true
            } label: {
                Label("搜索历史…", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("按题面、席位或结果搜索本机保存的场次")
            Divider()
            if model.historyList.isEmpty {
                Button("暂无历史") {}.disabled(true)
            } else {
                ForEach(model.historyList) { item in
                    Menu {
                        Button("只读回看") {
                            if isRunning { confirmation = .openHistory(item.id) }
                            else { openHistory(item.id) }
                        }
                        if !item.isFinished {
                            Button("继续这一场…") {
                                confirmation = .continueHistory(item.id)
                            }
                            .help("先逐席核对原页，可能已发送的任务只做只读核对")
                        }
                    } label: {
                        Text(historyLabel(item))
                    }
                }
            }
        } label: {
            Group {
                if compact {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 30, height: 26)
                } else {
                    Label("历史", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(minHeight: 26)
                }
            }
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("打开已保存的场次")
        .accessibilityLabel("历史场次")
    }

    /// One history row: local date/time, saved outcome and enough of the
    /// question to tell sessions apart. An unfinished session says so.
    private func historyLabel(_ item: ArenaHistorySummary) -> String {
        let stamp = Self.historyDateFormatter.string(
            from: Date(timeIntervalSince1970: item.updatedAt / 1000)
        )
        let outcome = historyOutcome(item)
        return "\(stamp) · \(outcome) · \(arenaShorten(item.question, limit: 34))"
    }

    private func historyOutcome(_ item: ArenaHistorySummary) -> String {
        ArenaHistoryOutcome.label(for: item)
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    // MARK: 开始前：大号多行问题输入

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                    .accessibilityHidden(true)

                ZStack(alignment: .topLeading) {
                    if model.question.isEmpty {
                        Text(model.draftAttachments.isEmpty ? "你想让它们讨论什么？" : "希望各席结合这些附件讨论什么？")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                    ArenaQuestionEditor(
                        text: $model.question,
                        focusRequest: questionFocusRequest,
                        onFocus: { questionFocused = $0 },
                        onMaterials: acceptMaterials,
                        onError: { model.errorMessage = $0 },
                        onStart: startDiscussion
                    )
                }

                if model.question.trimmedNonEmpty != nil {
                    Button {
                        model.question = ""
                        questionFocusRequest += 1
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("清空问题")
                    .accessibilityLabel("清空问题")
                }
            }
            .padding(.bottom, 2)

            if !model.draftAttachments.isEmpty { draftMaterials }

            Divider().opacity(0.45)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    addMaterialsButton
                    seatChips
                    roundPicker
                    Spacer(minLength: 8)
                    startButton
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 12) {
                        addMaterialsButton
                        seatChips
                        roundPicker
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        startButton
                    }
                }
            }
        }
        .padding(14)
        .background(ArenaGlassSurface(material: .underWindowBackground, cornerRadius: 16))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(usesPhotoBackdrop ? 0.72 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    questionFocused
                        ? Color.accentColor.opacity(0.55)
                        : Color.primary.opacity(0.09),
                    lineWidth: questionFocused ? 1.4 : 1
                )
        )
        .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.05), radius: 8, y: 2)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: questionFocused)
        .sheet(item: $previewAttachment) { item in
            ArenaMaterialPreview(item: item) { previewAttachment = nil }
        }
    }

    private var addMaterialsButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.title = "添加附件"
            panel.prompt = "添加"
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = ["png", "jpg", "jpeg", "txt", "md", "csv"].compactMap {
                UTType(filenameExtension: $0)
            }
            guard panel.runModal() == .OK else { return }
            do {
                // Validate each addition before reading more selected files.
                var files: [ArenaDraftAttachment] = []
                for url in panel.urls {
                    files.append(try ArenaDraftAttachment(fileURL: url))
                    try ArenaDraftAttachment.validate(model.draftAttachments + files)
                }
                _ = acceptMaterials(files)
            } catch { model.errorMessage = error.localizedDescription }
        } label: {
            Label("添加附件", systemImage: "paperclip")
        }
        .help("可将图片或文件拖入提问框，也可按 ⌘V 粘贴。支持 PNG、JPEG、TXT、MD、CSV。")
    }

    private func acceptMaterials(_ files: [ArenaDraftAttachment]) -> Bool {
        let oldCount = model.draftAttachments.count
        model.addDraftAttachments(files)
        return model.draftAttachments.count == oldCount + files.count
    }

    private var draftMaterials: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.draftAttachments) { item in
                        let preceding = model.draftAttachments.prefix { $0.id != item.id }
                        let imageNumber = preceding.filter { $0.kind == .image }.count + 1
                        ArenaDraftAttachmentChip(
                            item: item,
                            label: item.kind == .image ? "图 \(imageNumber)" : item.name,
                            onPreview: { previewAttachment = item },
                            onRemove: { model.draftAttachments.removeAll { $0.id == item.id } }
                        )
                    }
                }
            }
            Text("题面和附件将发送给 " + ArenaSeatCatalog.ordered.filter(selectedProviders.contains)
                .map(ArenaSeatCatalog.name).joined(separator: "、"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var seatChips: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ForEach(ArenaSeatCatalog.ordered, id: \.self) { provider in
                    let selected = selectedProviders.contains(provider)
                    Button {
                        toggleSeat(provider)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11, weight: .semibold))
                            Text(ArenaSeatCatalog.name(provider))
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                        .contentShape(Capsule())
                        .background(
                            Capsule().fill(
                                selected
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.primary.opacity(0.06)
                            )
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                selected
                                    ? Color.accentColor.opacity(0.28)
                                    : Color.primary.opacity(0.08)
                            )
                        )
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                    .help(seatChipHelp(provider, selected: selected))
                    .accessibilityLabel("\(ArenaSeatCatalog.name(provider))，\(selected ? "已选择" : "未选择")")
                }
            }
            .fixedSize()

            if let seatHint {
                Text(seatHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.orange)
                    .transition(.opacity)
            }
        }
    }

    private func seatChipHelp(_ provider: String, selected: Bool) -> String {
        if isRunning { return "本场参与：\(ArenaSeatCatalog.name(provider))" }
        if selected && selectedProviders.count == 2 {
            return "至少保留两席；先加入另一席再取消本席"
        }
        return selected ? "本场参与：\(ArenaSeatCatalog.name(provider))" : "点击加入本场"
    }

    private var roundPicker: some View {
        HStack(spacing: 5) {
            Text("互评上限")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("", selection: $roundLimit) {
                ForEach(1...5, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .fixedSize()
            .disabled(model.session != nil)
            .help("互评上限（1–5，默认 3）。独立作答结束后开始第 1 轮互评；每轮包括互评、起草或修订候选及表态")
        }
        .fixedSize()
    }

    private var startButton: some View {
        Button(action: startDiscussion) {
            Label("开始讨论", systemImage: "paperplane.fill")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canStart)
        .help("向所选席位发送同一个问题（⌘↩）")
    }

    // MARK: 开始后：紧凑只读题面与操作条

    private var lockedQuestion: String {
        (model.session?["question"] as? String)?.trimmedNonEmpty
            ?? model.question.trimmedNonEmpty
            ?? "（未记录题面）"
    }

    private var lockedQuestionBar: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("本场问题")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(lockedQuestion)
                    .font(.system(size: 13.5))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(lockedQuestion)
                    .accessibilityLabel("本场问题：\(lockedQuestion)")
            }

            Spacer(minLength: 8)
            if let files = model.session?["attachments"] as? [[String: Any]], !files.isEmpty {
                Button {
                    presentDetails(provider: nil, tab: .prompts)
                } label: { Label("\(files.count)", systemImage: "paperclip") }
                .help("查看本场附件和逐席送达记录")
                .accessibilityLabel("查看 \(files.count) 个附件")
            }

            Button {
                feedback.copyToPasteboard(lockedQuestion)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("复制本场问题")
            .accessibilityLabel("复制本场问题")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ArenaGlassSurface(material: .underWindowBackground, cornerRadius: 12))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(usesPhotoBackdrop ? 0.72 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        )
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            stagePill
            Spacer(minLength: 8)
            if isRunning {
                toolButton(
                    isPaused ? "继续" : "暂停",
                    icon: isPaused ? "play.fill" : "pause.fill",
                    large: true,
                    action: pauseOrResume
                )
                .help(isPaused ? "继续派发后续轮次" : "暂停后续派发，保留当前进度")
                if guidanceAvailable {
                    toolButton("补充条件", icon: "text.badge.plus", large: true) {
                        openGuidanceComposer()
                    }
                    .help("先暂停讨论，再把条件写入之后新建的提示；不会改写或重发已发出的任务")
                }
                toolButton("结束", icon: "stop.fill", large: true) {
                    confirmation = .finish
                }
                .help("结束整场讨论并生成当前报告（已发送的请求可能仍会生成）")
            }
            if hasSavedReport {
                Button {
                    presentDetails(provider: nil, tab: .report)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("查看报告")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 2)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("打开本场报告")
            }
            toolButton("新建", icon: "square.and.pencil", large: true) {
                if model.hasRunningDiscussion {
                    confirmation = .newDiscussion
                } else {
                    performNewDiscussion()
                }
            }
            .help(
                model.hasRunningDiscussion
                    ? "停止当前讨论并开始新的问题（会确认，可从历史继续）"
                    : "清空当前场次，开始新的问题"
            )
        }
    }

    private var stagePill: some View {
        HStack(spacing: 7) {
            if isPaused && isRunning {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.orange)
            } else {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary.opacity(0.55))
                    .frame(width: 8, height: 8)
                    .shadow(color: isRunning ? Color.green.opacity(0.6) : .clear, radius: 3)
            }
            HStack(spacing: 0) {
                Text(stageHeadline)
                if let progress = stageAnswerProgress {
                    Text(" · ")
                    ArenaStageAnswerCount(
                        answered: progress.answered,
                        total: progress.total,
                        liveRevision: model.liveAnswerRevision,
                        reduceMotion: reduceMotion
                    )
                    .id(stageProgressIdentity)
                }
                if let seat = stageWaitingSeat {
                    Text(" · 等待 \(seat)")
                }
                if stagePausedSuffix {
                    Text(" · 已暂停")
                }
                if model.guidanceCount > 0 {
                    Text(" · 条件 \(model.guidanceCount)")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isPaused && isRunning ? Color.orange : Color.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 26)
        .background(Capsule().fill(Color.primary.opacity(0.055)))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 6)
            Button {
                model.errorMessage = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭提示")
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: 席位区

    private var seatArea: some View {
        GeometryReader { geometry in
            let providers = gridProviders
            if model.isReadOnly, let saved = model.session {
                VStack(spacing: 0) {
                    readOnlyBanner
                    if ArenaSessionDigest.report(saved) != nil {
                        ArenaReportReader(session: saved, ballot: model.reportBallot(), model: model)
                            .id(ArenaSessionDigest.id(saved))
                    } else {
                        Text("该场次尚未生成报告，可在详情中查阅已保存的发言。")
                            .padding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if providers.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在准备三席原页…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                seatColumns(providers, size: geometry.size)
            }
        }
        .padding(10)
    }

    /// Three seats always stay full-height columns. At the 860 pt minimum the
    /// available width is narrower than three usable site columns, so the row
    /// scrolls horizontally instead of wrapping into a 2+1 grid with half-height
    /// pages. Two seats still share the width evenly.
    @ViewBuilder
    private func seatColumns(_ providers: [String], size: CGSize) -> some View {
        let gap: CGFloat = 8
        let minimumColumn: CGFloat = 320
        if providers.count <= 2 {
            HStack(spacing: gap) {
                ForEach(providers, id: \.self) { provider in
                    seatCard(provider)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            let available = max(size.width - gap * CGFloat(providers.count - 1), 0)
            let ideal = available / CGFloat(providers.count)
            if ideal >= minimumColumn {
                HStack(spacing: gap) {
                    ForEach(providers, id: \.self) { provider in
                        seatCard(provider)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: gap) {
                        ForEach(providers, id: \.self) { provider in
                            seatCard(provider)
                                .frame(width: minimumColumn, height: max(size.height, 0))
                        }
                    }
                }
            }
        }
    }

    private var readOnlyBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "book.closed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("历史回看 · 只读")
                    .font(.system(size: 12, weight: .semibold))
                Text("不会打开原页、不会重发")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let id = model.historyResumeID {
                Button {
                    confirmation = .continueHistory(id)
                } label: {
                    Label("继续这一场", systemImage: "play.circle.fill")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("恢复上次讨论；已发送的席位只读核对，不会重发")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035))
    }

    @ViewBuilder
    private func seatCard(_ provider: String) -> some View {
        if let pane = model.panes[provider] {
            let state = seatBadge(provider)
            ArenaSeatCard(
                pane: pane,
                provider: provider,
                status: state,
                isParticipant: isParticipant(provider),
                hasStarted: hasStarted,
                controls: model.controls(for: provider),
                receiptSignal: model.seatReceiptSignals[provider],
                savedAnswerSignal: liveSavedAnswerSignal(for: provider),
                onPrompt: { presentDetails(provider: provider, tab: .prompts) },
                onTakeOver: { model.takeOver(provider) },
                onResume: { model.resumeSeat(provider) },
                onReturnToBound: { model.returnToBoundConversationAndResume(provider) },
                onBackfill: { presentBackfill(provider) },
                localAction: model.localAction(for: provider),
                onLocalAction: { action in
                    // Re-derive the whole action at click time: kind, pending
                    // target and eligibility. A task can return to `.prepared`
                    // after rendering (e.g. a pre-click drift), so a stale
                    // read-only label must never reach the send-capable resume
                    // path. A visible mismatch banner also suppresses it.
                    guard model.localAction(for: provider) == action else {
                        model.errorMessage = "本席任务已变化，请核对后再操作"
                        return
                    }
                    switch action.kind {
                    case .readOnlyCheck:
                        model.resumeSeat(provider)
                    case .verifyAndBackfill:
                        presentBackfill(provider)
                    }
                },
                skipTarget: model.manualTarget(for: provider),
                onSkip: { target in
                    guard target == model.manualTarget(for: provider) else {
                        model.errorMessage = "本席任务已变化，请核对后再跳过"
                        return
                    }
                    model.skip(provider)
                }
            )
            .id(ObjectIdentifier(pane))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                Text("尚未挂载 \(ArenaSeatCatalog.name(provider))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: 补录（非模态面板，便于同时核对原页）

    private func presentBackfill(_ provider: String) {
        ArenaBackfillWindowController.shared.present(model: model, provider: provider)
    }

    // MARK: 动作

    private func startDiscussion() {
        guard canStart else { return }
        let providers = ArenaSeatCatalog.ordered.filter { selectedProviders.contains($0) }
        guard providers.count >= 2 else {
            showSeatHint("至少保留两席")
            return
        }
        // 新场次会替换阅读内容；旧详情与补录面板不再代表当前讨论。
        ArenaDetailsWindowController.shared.close()
        ArenaBackfillWindowController.shared.close()
        model.start(providers, maxRounds: roundLimit)
        if model.session != nil {
            ArenaCompletionNotifier.shared.prepareForCompletionAlerts()
        }
    }

    private func pauseOrResume() {
        model.pauseOrResume()
    }

    /// The confirmed path behind 「新建」. Stops the current discussion (which
    /// is already saved), clears the workbench and focuses the composer.
    private func performNewDiscussion() {
        selectedProviders = Set(ArenaSeatCatalog.ordered)
        roundLimit = 3
        ArenaDetailsWindowController.shared.close()
        ArenaBackfillWindowController.shared.close()
        model.newDiscussion()
        model.prepareHome()
        questionFocusRequest += 1
    }

    private func continueSaved(_ id: String) {
        ArenaDetailsWindowController.shared.close()
        ArenaBackfillWindowController.shared.close()
        guard model.continueSavedDiscussion(id) else { return }
        ArenaCompletionNotifier.shared.prepareForCompletionAlerts()
    }

    private func openHistory(_ id: String) {
        ArenaBackfillWindowController.shared.close()
        model.openHistory(id)
        presentDetails(provider: nil, tab: .report)
    }

    private func presentDetails(provider: String?, tab: ArenaInspectorTab) {
        ArenaDetailsWindowController.shared.present(
            model: model,
            request: ArenaDetailRequest(provider: provider, tab: tab)
        )
    }

    private func toggleSeat(_ provider: String) {
        if selectedProviders.contains(provider) {
            if selectedProviders.count > 2 {
                selectedProviders.remove(provider)
            } else {
                showSeatHint("至少保留两席；先加入另一席再取消本席")
                return
            }
        } else {
            selectedProviders.insert(provider)
        }
        model.prepareHome(selectedProviders)
    }

    private func showSeatHint(_ text: String) {
        hintTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            seatHint = text
        }
        hintTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                seatHint = nil
            }
        }
    }

    // MARK: 派生状态

    private var isRunning: Bool {
        guard !model.isReadOnly, let stage = model.session?["stage"] as? String else { return false }
        return stage != "done"
    }

    private var isPaused: Bool {
        (model.session?["paused"] as? Bool) ?? false
    }

    /// A report saved for the current session (completed or read-only history).
    private var hasSavedReport: Bool {
        ArenaSessionDigest.report(model.session) != nil
    }

    private var guidanceAvailable: Bool {
        if case .available = model.guidanceAvailability { return true }
        return false
    }

    /// Pause first through the model's single pause path, then open the editor
    /// for the pinned live phase. Nothing is resumed automatically, here or on
    /// save; the user must press 「继续」.
    private func openGuidanceComposer() {
        guard let target = model.beginGuidance() else { return }
        guidanceTarget = target
    }

    /// Run the history action only after the search sheet finished dismissing,
    /// so a confirmation alert is never presented on top of a live sheet.
    private func runPendingHistoryAction() {
        guard let action = pendingHistoryAction else { return }
        pendingHistoryAction = nil
        switch action {
        case .view(let id):
            if isRunning { confirmation = .openHistory(id) }
            else { openHistory(id) }
        case .resume(let id):
            confirmation = .continueHistory(id)
        }
    }

    private var canStart: Bool {
        model.question.trimmedNonEmpty != nil
            && selectedProviders.count >= 2
            && selectedProviders.count <= 3
            && !isRunning
    }

    private var stageHeadline: String {
        guard let session = model.session else {
            return hasStarted ? "准备中" : "未开始"
        }
        return ArenaStageNames.discussionLabel(session)
    }

    /// The real per-stage count from the saved/current task list. It is shown
    /// as its own text so only this number changes, in place, when a live answer
    /// is saved.
    private var stageAnswerProgress: (answered: Int, total: Int)? {
        guard let session = model.session,
              let tasks = session["tasks"] as? [[String: Any]], !tasks.isEmpty,
              (session["stage"] as? String) != "done" else { return nil }
        let answered = tasks.filter { ($0["status"] as? String) == "answered" }.count
        return (answered, tasks.count)
    }

    private var stageWaitingSeat: String? {
        guard let session = model.session,
              (session["stage"] as? String) != "done",
              let tasks = session["tasks"] as? [[String: Any]] else { return nil }
        let pending = tasks.filter { ($0["status"] as? String) == "pending" }
        guard pending.count == 1, let seat = pending[0]["provider"] as? String else { return nil }
        return ArenaSeatCatalog.name(seat)
    }

    private var stagePausedSuffix: Bool {
        (model.session?["paused"] as? Bool) ?? false
    }

    /// A new session, stage or round is a new count surface. Giving the number
    /// view that identity prevents the last answer of one stage from rolling
    /// the next stage's restored 0.
    private var stageProgressIdentity: String {
        let sessionID = ArenaSessionDigest.id(model.session) ?? ""
        let stage = (model.session?["stage"] as? String) ?? ""
        let round = ArenaValue.int(model.session?["round"]) ?? 0
        return "\(sessionID)|\(stage)|\(round)"
    }

    private var gridProviders: [String] {
        let panes = model.panes
        let known = ArenaSeatCatalog.ordered.filter { panes[$0] != nil }
        let extra = panes.keys.filter { !ArenaSeatCatalog.ordered.contains($0) }.sorted()
        return known + extra
    }

    private func isParticipant(_ provider: String) -> Bool {
        guard let providers = model.session?["providers"] as? [String] else { return true }
        return providers.contains(provider)
    }

    /// A live saved-answer token only describes the current answered task. When
    /// the stage or round moves on, the token is no longer shown, while history
    /// (whose tokens are cleared) keeps its static appearance.
    private func liveSavedAnswerSignal(for provider: String) -> ArenaSeatLiveSignal? {
        guard let signal = model.seatAnswerSignals[provider],
              signal.kind == .answerSaved,
              let tasks = model.session?["tasks"] as? [[String: Any]] else { return nil }
        let matchesCurrentTask = tasks.contains { task in
            task.arenaString("id") == signal.taskID
                && task.arenaString("provider") == provider
                && task.arenaString("status") == "answered"
                && task.arenaString("answer")?.trimmedNonEmpty != nil
        }
        return matchesCurrentTask ? signal : nil
    }

    /// The badge always comes from a structured seat state: the live model
    /// state when the discussion is running, otherwise a durable outcome read
    /// from the saved session. Free-text status wording is never parsed.
    private func seatBadge(_ provider: String) -> ArenaSeatState {
        if let state = model.seatStates[provider] {
            return state
        }
        return ArenaSeatOutcome.derive(session: model.session, provider: provider)
    }
}

// MARK: - 单席卡片

/// 每席单独观察自己的 SitePane，页面加载完成或失败时只重绘本卡，
/// 不重建 webView，也不触发网页重载。
struct ArenaSeatCard: View {
    @ObservedObject var pane: SitePane

    let provider: String
    let status: ArenaSeatState
    let isParticipant: Bool
    let hasStarted: Bool
    let controls: ArenaSeatControls
    let receiptSignal: ArenaSeatLiveSignal?
    let savedAnswerSignal: ArenaSeatLiveSignal?

    let onPrompt: () -> Void
    let onTakeOver: () -> Void
    let onResume: () -> Void
    let onReturnToBound: () -> Void
    let onBackfill: () -> Void
    let localAction: ArenaSeatLocalAction?
    let onLocalAction: (ArenaSeatLocalAction) -> Void
    let skipTarget: ArenaManualTarget?
    let onSkip: (ArenaManualTarget) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingSkip = false
    @State private var confirmedSkipTarget: ArenaManualTarget?
    @State private var confirmingReturn = false
    @State private var resumeAfterReturn = false
    @State private var receiptPlaneVisible = false
    @State private var receiptPlaneLaunched = false
    @State private var receiptTask: Task<Void, Never>?
    @State private var savedCheckScale: CGFloat = 1
    @State private var savedCheckSettleTask: Task<Void, Never>?

    private var openError: String? {
        pane.lastError ?? pane.lastNavigationError
    }

    private var statusColor: Color { ArenaSeatStatus.color(status.kind) }

    /// The idle and generic generating details repeat the badge word verbatim.
    /// Specific delivery, recovery and failure reasons stay visible.
    private var showsStatusDetail: Bool {
        switch status.kind {
        case .idle:
            return status.detail != "待开始"
        case .generating:
            return status.detail != "正在生成…"
        default:
            return true
        }
    }

    /// Persistent static saved mark for the current answered task. The parent
    /// only forwards a token while its task is still the current answered one;
    /// history clears tokens, so its static appearance is unchanged.
    private var showsSavedCheck: Bool {
        status.kind == .answered && savedAnswerSignal != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusColor.opacity(0.45), radius: 3)
                    Text(ArenaSeatCatalog.name(provider))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(ArenaSeatStatus.label(status.kind))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(statusColor.opacity(0.12)))
                        .help(status.detail)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .offset(x: receiptPlaneLaunched ? 0 : -4)
                        .opacity(receiptPlaneVisible && status.kind == .generating && receiptPlaneLaunched ? 1 : 0)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(!(receiptPlaneVisible && status.kind == .generating && receiptPlaneLaunched))
                        .accessibilityLabel("原页已核验本轮提问，等待回答")
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.green)
                        .opacity(showsSavedCheck ? 1 : 0)
                        .scaleEffect(savedCheckScale)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(!showsSavedCheck)
                        .accessibilityLabel("回答已保存")
                    if !isParticipant && hasStarted {
                        Text("未参与")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button(action: onPrompt) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 12.5, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("查看本席当前真正提示")
                    .accessibilityLabel("查看本席当前提示")
                    menu
                }
                if showsStatusDetail {
                    Text(status.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(status.kind == .needsAction ? nil : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(status.detail)
                        .padding(.leading, 16)
                        .padding(.trailing, 4)
                        .accessibilityLabel("\(ArenaSeatCatalog.name(provider)) 状态：\(status.detail)")
                }
                if let localAction {
                    HStack(spacing: 6) {
                        Button {
                            onLocalAction(localAction)
                        } label: {
                            Label(
                                ArenaSeatStatus.localActionLabel(localAction.kind),
                                systemImage: ArenaSeatStatus.localActionSymbol(localAction.kind)
                            )
                            .font(.system(size: 11.5, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help(ArenaSeatStatus.localActionHelp(localAction.kind))
                        .accessibilityLabel(
                            "\(ArenaSeatCatalog.name(provider))：\(ArenaSeatStatus.localActionLabel(localAction.kind))"
                        )
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 4)
                    .padding(.top, 2)
                    .padding(.bottom, 3)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(minHeight: 50)
            .background(
                LinearGradient(
                    colors: [Color.primary.opacity(0.055), Color.primary.opacity(0.022)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            if pane.boundConversationURL != nil, pane.conversationMismatch() != nil {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                    Text("原页已切到其他对话")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(controls.canResume ? "回到本场对话并恢复" : "回到本场对话") {
                        resumeAfterReturn = controls.canResume
                        confirmingReturn = true
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .help("重新打开本席已核验的本场对话；当前页未发送的内容不会保留")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.10))
            }

            Divider()

            ZStack {
                SitePaneView(pane: pane)
                if pane.webView.url == nil || pane.isWebContentTerminated {
                    placeholder
                }
            }
            .alert(resumeAfterReturn ? "回到本场对话并恢复自动？" : "回到本场对话？",
                   isPresented: $confirmingReturn) {
                Button(resumeAfterReturn ? "回到并恢复" : "回到本场对话") {
                    if resumeAfterReturn {
                        onReturnToBound()
                    } else {
                        _ = pane.openBoundConversation()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前页未发送的内容（含草稿和附件）不会保留。若需要，请先复制或保存草稿。")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10))
        )
        .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(ArenaSeatCatalog.name(provider)) 席位")
        .alert("跳过 \(ArenaSeatCatalog.name(provider))？", isPresented: $confirmingSkip) {
            Button("跳过本席", role: .destructive) {
                if let target = confirmedSkipTarget { onSkip(target) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("跳过本席后，本轮该席计为缺席；晚到的回答也不会进入本轮。")
        }
        .onChange(of: receiptSignal?.id) { _ in
            if receiptSignal == nil {
                receiptTask?.cancel()
                receiptTask = nil
                receiptPlaneVisible = false
                receiptPlaneLaunched = false
            } else {
                playReceiptPlane()
            }
        }
        .onChange(of: savedAnswerSignal?.id) { _ in
            if savedAnswerSignal != nil && status.kind == .answered {
                settleSavedCheck()
            } else {
                savedCheckSettleTask?.cancel()
                savedCheckSettleTask = nil
                savedCheckScale = 1
            }
        }
        .onChange(of: status.kind) { kind in
            if kind != .generating {
                receiptTask?.cancel()
                receiptTask = nil
                receiptPlaneVisible = false
                receiptPlaneLaunched = false
            }
            if kind != .answered {
                savedCheckSettleTask?.cancel()
                savedCheckSettleTask = nil
                savedCheckScale = 1
            }
        }
        .onDisappear {
            receiptTask?.cancel()
            savedCheckSettleTask?.cancel()
        }
    }

    /// One-shot paper-plane motion for this seat header only. It is triggered
    /// exclusively by a live verified receipt signal, never by a click or a
    /// restored task. Reduce Motion keeps the same readable icon without motion.
    private func playReceiptPlane() {
        receiptTask?.cancel()
        receiptPlaneLaunched = false
        receiptPlaneVisible = true
        if !reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) { receiptPlaneLaunched = true }
        } else {
            receiptPlaneLaunched = true
        }
        receiptTask = Task { @MainActor in
            let dwell: UInt64 = reduceMotion ? 900_000_000 : 700_000_000
            try? await Task.sleep(nanoseconds: dwell)
            guard !Task.isCancelled else { return }
            if reduceMotion {
                receiptPlaneVisible = false
                receiptPlaneLaunched = false
            } else {
                withAnimation(.easeOut(duration: 0.18)) { receiptPlaneLaunched = false }
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                receiptPlaneVisible = false
            }
        }
    }

    /// One brief settle for the persistent saved mark. The mark itself stays
    /// statically visible while the answered badge refers to the same live task;
    /// there is no disappear timer.
    private func settleSavedCheck() {
        savedCheckSettleTask?.cancel()
        guard !reduceMotion else {
            savedCheckScale = 1
            return
        }
        savedCheckScale = 0.68
        savedCheckSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                savedCheckScale = 1
            }
        }
    }

    private var menu: some View {
        Menu {
            Button("查看当前提示…", action: onPrompt)
            if pane.boundConversationURL != nil {
                Button("回到本场对话") {
                    resumeAfterReturn = false
                    confirmingReturn = true
                }
                .help("重新打开已核验的本场对话；当前页未发送的内容不会保留")
                Button("回到本场对话并恢复自动") {
                    resumeAfterReturn = true
                    confirmingReturn = true
                }
                .disabled(!controls.canResume)
                .help(controls.canResume
                      ? "重新打开本场对话，并按已保存阶段恢复本席；可能已发送的只读核对，不会重发"
                      : "本席当前没有可恢复的任务")
            }
            Button("回原站首页") { pane.openHome() }
                .disabled(!homeAllowed)
                .help("会离开本场对话；当前页未发送的内容不会保留")
            Divider()
            Button("恢复本站自动", action: onResume)
                .disabled(!controls.canResume)
                .help(resumeHelp)
            Button("人工接管", action: onTakeOver)
                .disabled(!controls.canTakeOver)
                .help(controls.canTakeOver ? "停止本席自动派发，其他席继续" : "本席已是人工接管或不在本轮")
            Button("文本补录…", action: onBackfill)
                .disabled(!controls.canBackfill)
                .help(controls.canBackfill ? "打开非模态补录面板，可同时核对原页" : "本席当前没有待处理任务")
            Button("跳过本席…") {
                confirmedSkipTarget = skipTarget
                confirmingSkip = skipTarget != nil
            }
                .disabled(!controls.canSkip)
                .help(controls.canSkip ? "本轮该席计为缺席（会确认）" : "本席当前没有待处理任务")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
        .help("本席操作：回首页、恢复自动、接管、补录、跳过")
        .accessibilityLabel("本席操作")
    }

    private var homeAllowed: Bool {
        !hasStarted || controls.canOpenHome
    }

    private var resumeHelp: String {
        if controls.canResume {
            return "按已保存的发送阶段继续：可能已发送的只读核对，不会重发"
        }
        return "仅在本席已接管或需要核对时可用"
    }

    private var placeholder: some View {
        VStack(spacing: 9) {
            if let openError {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.orange)
                Text(openError)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 18)
                Button("重试") { pane.openHome() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            } else {
                ProgressView().controlSize(.small)
                Text("正在打开 \(ArenaSeatCatalog.name(provider)) 原页…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if hasStarted {
                    // 页面加载期间不遮断模型自动派发，仅提示可交互状态。
                    Text("页面打开后可直接在原站查看与操作")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - 席位状态表现

/// Colour and short badge text for one structured seat state. This is the only
/// place UI wording is chosen; no status sentence is ever inspected.
enum ArenaSeatStatus {
    static func label(_ kind: ArenaSeatStateKind) -> String {
        switch kind {
        case .idle: return "待开始"
        case .sending: return "发送中"
        case .generating: return "生成中"
        case .answered: return "已收到"
        case .needsAction: return "需处理"
        case .takenOver: return "人工接管"
        case .skipped: return "已跳过"
        case .paused: return "已暂停"
        case .done: return "已结束"
        }
    }

    static func localActionLabel(_ kind: ArenaSeatLocalAction.Kind) -> String {
        switch kind {
        case .readOnlyCheck: return "只读核对"
        case .verifyAndBackfill: return "核对并补录"
        }
    }

    static func localActionSymbol(_ kind: ArenaSeatLocalAction.Kind) -> String {
        switch kind {
        case .readOnlyCheck: return "checkmark.shield"
        case .verifyAndBackfill: return "square.and.pencil"
        }
    }

    static func localActionHelp(_ kind: ArenaSeatLocalAction.Kind) -> String {
        switch kind {
        case .readOnlyCheck:
            return "只读取本轮原页的提问与回答，不会重发"
        case .verifyAndBackfill:
            return "打开非模态补录面板；请先核对原页，表态需明确立场，带附件时需确认已核对"
        }
    }

    static func color(_ kind: ArenaSeatStateKind) -> Color {
        switch kind {
        case .idle: return Color.secondary
        case .sending: return Color.blue
        case .generating: return Color.blue
        case .answered: return Color.green
        case .needsAction: return Color.red
        case .takenOver: return Color.orange
        case .skipped: return Color.secondary
        case .paused: return Color.orange
        case .done: return Color.secondary
        }
    }
}

// MARK: - 值工具

enum ArenaValue {
    static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

extension String {
    fileprivate var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

fileprivate func arenaShorten(_ text: String, limit: Int) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    if flat.count <= limit { return flat }
    return String(flat.prefix(max(limit - 1, 1))) + "…"
}

// MARK: - 顶部阶段计数

/// Shows the actual saved task count and rolls the digits only for a live saved
/// answer. Stage restoration, history and pause update it without animation,
/// and the monospaced digits keep the pill from shifting its neighbours.
struct ArenaStageAnswerCount: View {
    let answered: Int
    let total: Int
    let liveRevision: Int
    let reduceMotion: Bool

    @State private var displayedAnswered: Int
    @State private var displayedTotal: Int
    @State private var seenRevision: Int

    init(answered: Int, total: Int, liveRevision: Int, reduceMotion: Bool) {
        self.answered = answered
        self.total = total
        self.liveRevision = liveRevision
        self.reduceMotion = reduceMotion
        _displayedAnswered = State(initialValue: answered)
        _displayedTotal = State(initialValue: total)
        _seenRevision = State(initialValue: liveRevision)
    }

    private struct Snapshot: Equatable {
        let answered: Int
        let total: Int
        let revision: Int
    }

    private var snapshot: Snapshot {
        Snapshot(answered: answered, total: total, revision: liveRevision)
    }

    var body: some View {
        Text("已收到 \(displayedAnswered)/\(displayedTotal)")
            .monospacedDigit()
            .contentTransition(.numericText())
            .onChange(of: snapshot) { next in
                let live = next.revision != seenRevision
                seenRevision = next.revision

                // A new round or stage changes the denominator. That is a
                // restoration of the next stage's real count, not a live answer
                // for the number already on screen, so it never rolls.
                if next.total != displayedTotal {
                    displayedTotal = next.total
                    displayedAnswered = next.answered
                    return
                }
                guard next.answered != displayedAnswered else { return }
                if live && !reduceMotion {
                    withAnimation(.easeOut(duration: 0.2)) {
                        displayedAnswered = next.answered
                    }
                } else {
                    displayedAnswered = next.answered
                }
            }
            .accessibilityLabel("本阶段已收到 \(displayedAnswered) / \(displayedTotal) 席回答")
    }
}

// MARK: - 会话读取

struct ArenaTaskRow: Identifiable {
    let id: String
    let provider: String
    let stage: String
    let round: Int
    let status: String
    let sourceId: String
    let prompt: String
    let answer: String?
}

enum ArenaSessionDigest {

    static func rows(_ session: [String: Any]?) -> [ArenaTaskRow] {
        guard let session else { return [] }
        var result: [ArenaTaskRow] = []
        var seen = Set<String>()

        func append(_ raw: [String: Any], fallbackIndex: Int) {
            guard let provider = ArenaValue.string(raw["provider"])?.trimmedNonEmpty else { return }
            let stage = ArenaValue.string(raw["stage"]) ?? ""
            let round = ArenaValue.int(raw["round"]) ?? 1
            let sourceId = ArenaValue.string(raw["sourceId"]) ?? ""
            let status = ArenaValue.string(raw["status"]) ?? ""
            let prompt = ArenaValue.string(raw["prompt"]) ?? ""
            let answer = ArenaValue.string(raw["answer"])
            var id = ArenaValue.string(raw["id"])?.trimmedNonEmpty
                ?? "\(stage)-\(round)-\(provider)-\(sourceId)-\(fallbackIndex)"
            if seen.contains(id) {
                id += "-\(fallbackIndex)"
            }
            seen.insert(id)
            result.append(
                ArenaTaskRow(
                    id: id,
                    provider: provider,
                    stage: stage,
                    round: round,
                    status: status,
                    sourceId: sourceId,
                    prompt: prompt,
                    answer: answer
                )
            )
        }

        if let history = session["history"] as? [[String: Any]] {
            for (index, raw) in history.enumerated() { append(raw, fallbackIndex: index) }
        }
        if let tasks = session["tasks"] as? [[String: Any]] {
            for (index, raw) in tasks.enumerated() { append(raw, fallbackIndex: 10_000 + index) }
        }
        return result
    }

    static func participants(_ session: [String: Any]?) -> [String] {
        (session?["providers"] as? [String]) ?? []
    }

    /// 详情窗口的席位列：参与席优先，再补上已有记录的席位；没有场次时
    /// 退回本机已挂载的默认顺序，保证窄窗口里也总有一个可选目标。
    static func providerChoices(_ session: [String: Any]?) -> [String] {
        var choices = participants(session)
        for row in rows(session) where !choices.contains(row.provider) {
            choices.append(row.provider)
        }
        return choices.isEmpty ? ArenaSeatCatalog.ordered : choices
    }

    static func currentTask(_ session: [String: Any]?, provider: String) -> ArenaTaskRow? {
        guard let session else { return nil }
        let stage = (session["stage"] as? String) ?? ""
        let round = ArenaValue.int(session["round"]) ?? 1
        return rows(session).last {
            $0.provider == provider && $0.stage == stage && $0.round == round
        }
    }

    static func lastTask(_ session: [String: Any]?, provider: String) -> ArenaTaskRow? {
        rows(session).last { $0.provider == provider }
    }

    static func promptText(_ session: [String: Any]?, provider: String) -> String? {
        if let task = currentTask(session, provider: provider), let prompt = task.prompt.trimmedNonEmpty {
            return prompt
        }
        return lastTask(session, provider: provider)?.prompt.trimmedNonEmpty
    }

    static func answerRows(_ session: [String: Any]?) -> [ArenaTaskRow] {
        rows(session).filter { $0.answer?.trimmedNonEmpty != nil }
    }

    static func evaluationCandidates(_ session: [String: Any]?) -> [ArenaEvaluationDraft.Candidate] {
        let answers = answerRows(session)
        return participants(session).compactMap { provider in
            guard let row = answers.first(where: {
                $0.stage == "independent" && $0.status == "answered" && $0.provider == provider
            }), let answer = row.answer, !row.sourceId.isEmpty else { return nil }
            return ArenaEvaluationDraft.Candidate(provider: provider, source: row.sourceId, answer: answer)
        }
    }

    static func report(_ session: [String: Any]?) -> String? {
        (session?["report"] as? String)?.trimmedNonEmpty
    }

    static func stopReason(_ session: [String: Any]?) -> String? {
        (session?["stopReason"] as? String)?.trimmedNonEmpty
    }

    static func id(_ session: [String: Any]?) -> String? {
        (session?["id"] as? String).flatMap { $0.trimmedNonEmpty }
    }
}

enum ArenaJSON {
    static func string(_ value: Any?) -> String {
        guard let value else { return "{}" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
               withJSONObject: value,
               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
           ),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }
}

// MARK: - 详情面板

enum ArenaInspectorTab: String, CaseIterable, Identifiable {
    case prompts
    case answers
    case report
    case json

    var id: String { rawValue }

    /// Tabs shown as the primary segmented control. The raw JSON record is
    /// deliberately kept behind a secondary menu.
    static var primaryCases: [ArenaInspectorTab] { [.prompts, .answers, .report] }

    var label: String {
        switch self {
        case .prompts: return "当前提示"
        case .answers: return "历史原文"
        case .report: return "报告"
        case .json: return "原始记录"
        }
    }

    var symbol: String {
        switch self {
        case .prompts: return "text.bubble"
        case .answers: return "clock.arrow.circlepath"
        case .report: return "doc.text"
        case .json: return "curlybraces"
        }
    }
}

/// One pending confirmation. Destructive actions and the verified history
/// continuation all route through a single native alert.
enum ArenaConfirmation: Identifiable {
    case newDiscussion
    case finish
    case continueHistory(String)
    case openHistory(String)

    var id: String {
        switch self {
        case .newDiscussion: return "new"
        case .finish: return "finish"
        case .continueHistory(let id): return "continue-\(id)"
        case .openHistory(let id): return "history-\(id)"
        }
    }
}

struct ArenaDetailRequest: Identifiable {
    let id = UUID()
    let provider: String?
    let tab: ArenaInspectorTab
}

// MARK: - 详情窗口（独立、非模态）

/// 详情窗口只保存阅读状态；会话仍由 ArenaModel 持有。窗口被关闭后保留，
/// 下一次「详情」「查看当前提示」或历史回看只更新所选标签、席位和内容。
@MainActor
final class ArenaDetailsWindowState: ObservableObject {
    @Published var tab: ArenaInspectorTab = .report
    @Published var provider: String = ArenaSeatCatalog.ordered.first ?? "chatgpt"
    @Published var showsRawRecord = false

    func apply(request: ArenaDetailRequest, session: [String: Any]?) {
        if request.tab == .json {
            showsRawRecord = true
        } else {
            tab = request.tab
            showsRawRecord = false
        }
        let choices = ArenaSessionDigest.providerChoices(session)
        if let requested = request.provider, choices.contains(requested) {
            provider = requested
        } else if !choices.contains(provider) {
            provider = choices.first ?? provider
        }
    }

    func normalize(session: [String: Any]?) {
        let choices = ArenaSessionDigest.providerChoices(session)
        guard !choices.contains(provider), let first = choices.first else { return }
        provider = first
    }
}

/// 独立的标准 NSWindow：有标题栏、可缩放、可最小化、可关闭，绿色按钮和
/// ⌃⌘F 使用系统全屏，标题栏双击遵循“系统设置 → 桌面与程序坞”的用户偏好。
/// 不再重复提供「最大化」按钮；系统绿色按钮即缩放入口。
@MainActor
final class ArenaDetailsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {

    static let shared = ArenaDetailsWindowController()

    private(set) var window: NSWindow?
    private var hostingController: NSHostingController<ArenaDetailsWindowView>?
    private var hostedModel: ArenaModel?
    private let state = ArenaDetailsWindowState()
    private let feedback = ArenaFeedbackPresenter()
    private var copyReportItem: NSToolbarItem?

    private enum Item {
        static let copyReport = NSToolbarItem.Identifier("arena.details.copy-report")
        static let export = NSToolbarItem.Identifier("arena.details.export")
    }

    private override init() {
        super.init()
    }

    // MARK: 打开与复用

    func present(model: ArenaModel, request: ArenaDetailRequest) {
        state.apply(request: request, session: model.session)
        let window = ensureWindow(model: model)
        window.title = "本场详情"
        window.subtitle = Self.subtitle(for: model.session)
        if window.isMiniaturized { window.deminiaturize(nil) }
        arenaPresentWindow(window)
        refreshToolbar()
    }

    /// 显式关闭（红点、⌘W、标题栏菜单或界面按钮）后窗口仍被保留，
    /// 下次打开继续使用同一个窗口和阅读状态。
    func close() {
        window?.close()
    }

    @discardableResult
    func focusIfVisible() -> Bool {
        guard let window, window.isVisible else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func ensureWindow(model: ArenaModel) -> NSWindow {
        if let window, hostedModel === model {
            return window
        }
        if let existing = window {
            existing.delegate = nil
            existing.close()
        }

        let root = ArenaDetailsWindowView(model: model, state: state, feedback: feedback)
        let hosting = NSHostingController(rootView: root)
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1100, height: 800)
        let initial = NSRect(x: 0, y: 0, width: min(1060, visible.width - 32),
                             height: min(720, visible.height - 100))
        hosting.view.frame = initial

        let window = NSWindow(
            contentRect: initial,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "本场详情"
        window.minSize = NSSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.animationBehavior = .documentWindow
        window.delegate = self

        let toolbar = NSToolbar(identifier: "ArenaDetailsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        if !window.setFrameUsingName("ArenaDetailsWindow") {
            window.center()
        }
        window.setFrameAutosaveName("ArenaDetailsWindow")

        hostingController = hosting
        hostedModel = model
        self.window = window
        return window
    }

    private static func subtitle(for session: [String: Any]?) -> String {
        guard let session else { return "尚未建立场次" }
        return ArenaStageNames.discussionLabel(session)
    }

    // MARK: 工具栏

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.copyReport, Item.export]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.copyReport, Item.export]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Item.copyReport:
            let item = makeItem(
                itemIdentifier,
                label: "复制报告",
                toolTip: "复制本场报告全文",
                symbol: "doc.on.doc",
                action: #selector(copyReport(_:))
            )
            item.isEnabled = ArenaSessionDigest.report(hostedModel?.session) != nil
            copyReportItem = item
            return item
        case Item.export:
            return makeItem(
                itemIdentifier,
                label: "导出 Markdown",
                toolTip: "以 Markdown 保存本场完整记录",
                symbol: "square.and.arrow.up",
                action: #selector(exportMarkdown(_:))
            )
        default:
            return nil
        }
    }

    private func makeItem(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        toolTip: String,
        symbol: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Item.copyReport:
            return ArenaSessionDigest.report(hostedModel?.session) != nil
        case Item.export:
            return hostedModel?.session != nil
        default:
            return true
        }
    }

    private func refreshToolbar() {
        copyReportItem?.isEnabled = ArenaSessionDigest.report(hostedModel?.session) != nil
        window?.toolbar?.validateVisibleItems()
    }

    @objc private func copyReport(_ sender: Any?) {
        guard let report = ArenaSessionDigest.report(hostedModel?.session) else { return }
        feedback.copyToPasteboard(report)
    }

    @objc private func exportMarkdown(_ sender: Any?) {
        guard let model = hostedModel else { return }
        ArenaExporter.export(model: model, feedback: feedback)
    }

    // The system green button, ⌃⌘F and the title-bar double-click own zoom and
    // full screen. The window deliberately adds no duplicate 「最大化」 item.

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        refreshToolbar()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        refreshToolbar()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        refreshToolbar()
    }
}

// MARK: 详情窗口内容

struct ArenaDetailsWindowView: View {
    @ObservedObject var model: ArenaModel
    @ObservedObject var state: ArenaDetailsWindowState
    @ObservedObject var feedback: ArenaFeedbackPresenter
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var selectedAnswerSource: ArenaTaskRow?

    private var session: [String: Any]? { model.session }
    private var report: String? { ArenaSessionDigest.report(session) }
    private var sessionIdentity: String { ArenaSessionDigest.id(session) ?? "" }

    private var questionText: String {
        (session?["question"] as? String)?.trimmedNonEmpty
            ?? model.question.trimmedNonEmpty
            ?? ""
    }

    private var providerChoices: [String] {
        ArenaSessionDigest.providerChoices(session)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .overlay(Color.primary.opacity(0.08))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(ArenaGlassSurface(material: .underWindowBackground, cornerRadius: 0))
        .overlay(alignment: .bottom) {
            ArenaFeedbackOverlay(presenter: feedback)
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
        }
        .onAppear { state.normalize(session: session) }
        .onChange(of: sessionIdentity) { _ in
            selectedAnswerSource = nil
            state.normalize(session: session)
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: tabSelection) {
                ForEach(ArenaInspectorTab.primaryCases) { item in
                    Label(item.label, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: 560)

            Menu {
                Button("原始记录（JSON）") { state.showsRawRecord = true }
                Button("复制 JSON") {
                    feedback.copyToPasteboard(ArenaJSON.string(session))
                }
                .disabled(session == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多：原始记录")
            .accessibilityLabel("更多")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(ArenaGlassSurface(material: .headerView, cornerRadius: 0))
    }

    private var tabSelection: Binding<ArenaInspectorTab> {
        Binding(
            get: { state.tab },
            set: { value in
                state.tab = value
                state.showsRawRecord = false
                selectedAnswerSource = nil
            }
        )
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if state.showsRawRecord {
            jsonView
        } else {
            switch state.tab {
            case .prompts: promptsView
            case .answers: answersContent
            case .report: reportView
            case .json: jsonView
            }
        }
    }

    /// The answers list stays mounted behind the source reader so returning
    /// keeps its scroll position and each disclosure's expansion state. The
    /// hidden list is removed from hit testing and accessibility.
    private var answersContent: some View {
        ZStack {
            answersView
                .opacity(selectedAnswerSource == nil ? 1 : 0)
                .allowsHitTesting(selectedAnswerSource == nil)
                .accessibilityHidden(selectedAnswerSource != nil)
            if let source = selectedAnswerSource {
                ArenaSourceReader(
                    row: source,
                    session: session,
                    returnLabel: "返回历史原文"
                ) {
                    selectedAnswerSource = nil
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    // MARK: 当前提示

    private var promptsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                readingCard(
                    title: "本场问题",
                    subtitle: participantSummary,
                    text: questionText,
                    copyLabel: "复制问题"
                )
                ArenaSavedMaterials(model: model)
                if !model.savedGuidance.isEmpty {
                    ArenaSavedConditionsCard(notes: model.savedGuidance)
                }

                VStack(alignment: .leading, spacing: 10) {
                    providerPickerRow
                    taskCaption
                    readingCard(
                        title: "本席当前提示",
                        subtitle: nil,
                        text: currentPromptText,
                        copyLabel: "复制提示"
                    )
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var participantSummary: String {
        let participants = ArenaSessionDigest.participants(session)
        guard !participants.isEmpty else { return "发送给参与本场的席位" }
        return "发送给 " + participants.map(ArenaSeatCatalog.name).joined(separator: "、")
    }

    @ViewBuilder
    private var providerPickerRow: some View {
        if providerChoices.count > 1 {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    pickerLabel
                    providerPicker
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    pickerLabel
                    providerPicker
                }
            }
        }
    }

    private var pickerLabel: some View {
        Text("查看席位")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var providerPicker: some View {
        Picker("", selection: $state.provider) {
            ForEach(providerChoices, id: \.self) { provider in
                Text(ArenaSeatCatalog.name(provider)).tag(provider)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.large)
        .frame(maxWidth: 430)
    }

    @ViewBuilder
    private var taskCaption: some View {
        if let task = ArenaSessionDigest.currentTask(session, provider: state.provider) {
            Text("本席这一轮 · \(ArenaStageNames.taskLabel(task.stage, round: task.round, session: model.session))"
                + (task.sourceId.isEmpty ? "" : " · \(task.sourceId)"))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        } else {
            Text("本席当前没有进行中的提示；下面显示最近一次记录。")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }

    private var currentPromptText: String? {
        ArenaSessionDigest.promptText(session, provider: state.provider)
    }

    private func readingCard(
        title: String,
        subtitle: String?,
        text: String?,
        copyLabel: String
    ) -> some View {
        let value = text?.trimmedNonEmpty
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(copyLabel) {
                    if let value { feedback.copyToPasteboard(value) }
                }
                .controlSize(.large)
                .disabled(value == nil)
            }

            Text(value ?? "（暂无记录）")
                .font(.system(size: 14))
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        )
        .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.04), radius: 6, y: 2)
    }

    // MARK: 历史原文

    @ViewBuilder
    private var answersView: some View {
        let rows = ArenaSessionDigest.answerRows(session)
        if rows.isEmpty {
            emptyState("还没有已保存的原文。")
        } else {
            let hasReviews = rows.contains { $0.stage == "critique" }
            let reviewMaterials = hasReviews ? model.reviewMaterials() : [:]
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("已保存 \(rows.count) 条原文")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("提示与原文均按轮次保留")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 2)

                    if hasReviews {
                        Text("本场互评没有逐项胜负判定")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(rows) { row in
                        ArenaAnswerDisclosure(
                            row: row,
                            session: model.session,
                            reviewMaterials: reviewMaterials[row.id],
                            feedback: feedback,
                            onOpenSource: { selectedAnswerSource = $0 }
                        )
                    }
                }
                .padding(18)
            }
        }
    }

    // MARK: 报告

    @ViewBuilder
    private var reportView: some View {
        if report != nil {
            ArenaReportReader(session: model.session, ballot: model.reportBallot(), model: model)
                .id(sessionIdentity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let reason = ArenaSessionDigest.stopReason(session) {
            emptyState("尚未生成报告。停止原因：\(reason)")
        } else {
            emptyState("讨论结束后可在这里查看报告。")
        }
    }

    // MARK: 原始记录

    private var jsonView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("会话原始数据（只读）")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("复制 JSON") {
                    feedback.copyToPasteboard(ArenaJSON.string(session))
                }
                .controlSize(.large)
                .disabled(session == nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(ArenaJSON.string(session))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ArenaAnswerDisclosure: View {
    let row: ArenaTaskRow
    let session: [String: Any]?
    let reviewMaterials: [[String: String]]?
    let feedback: ArenaFeedbackPresenter
    let onOpenSource: (ArenaTaskRow) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var highlightedMaterials: Set<Int> = []
    @State private var highlightTask: Task<Void, Never>?

    private var reviewSummary: String {
        guard let reviewMaterials else { return "评审材料无法核对" }
        if reviewMaterials.isEmpty { return "无其他席位作答 · 自我反驳" }
        return reviewMaterials.compactMap { material -> String? in
            guard let source = material["sourceId"] else { return nil }
            return "\(materialTitle(material))（\(source)）"
        }.joined(separator: "、")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let materials = reviewMaterials, !materials.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("本席收到的材料 · 点一处打开原文")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(materials.indices, id: \.self) { index in
                            materialRow(index: index, material: materials[index])
                        }
                    }
                }
                labeled("提示", text: row.prompt, dim: true)
                labeled("原文", text: row.answer ?? "", dim: false)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(ArenaStageNames.taskLabel(row.stage, round: row.round, session: session))
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(ArenaSeatCatalog.name(row.provider))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        if !row.sourceId.isEmpty {
                            Text(row.sourceId)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if row.stage == "critique" {
                        Text(reviewSummary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button("复制原文") {
                    if let text = row.answer { feedback.copyToPasteboard(text) }
                }
                .controlSize(.large)
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        )
        .onChange(of: isExpanded) { expanded in
            if expanded {
                startMaterialHighlight()
            } else {
                highlightTask?.cancel()
                highlightTask = nil
                highlightedMaterials.removeAll()
            }
        }
        .onDisappear {
            highlightTask?.cancel()
            highlightTask = nil
            highlightedMaterials.removeAll()
        }
    }

    private func materialTitle(_ material: [String: String]) -> String {
        let name = material["provider"].map(ArenaSeatCatalog.name) ?? "其他席位"
        switch material["stage"] {
        case "independent": return "\(name) 的首轮作答"
        case "proposal": return "\(name) 起草的候选"
        case "vote": return "\(name) 的异议或条件"
        default: return "\(name) 的材料"
        }
    }

    private func materialSource(_ material: [String: String]) -> ArenaTaskRow? {
        guard let sourceID = material["sourceId"], !sourceID.isEmpty,
              let provider = material["provider"], !provider.isEmpty,
              let stage = material["stage"], !stage.isEmpty else { return nil }
        return ArenaSessionDigest.rows(session).first { candidate in
            candidate.sourceId == sourceID
                && candidate.provider == provider
                && candidate.stage == stage
                && candidate.status == "answered"
                && candidate.answer?.trimmedNonEmpty != nil
        }
    }

    private func materialRow(index: Int, material: [String: String]) -> some View {
        let source = materialSource(material)
        let highlighted = highlightedMaterials.contains(index)
        let sourceID = material["sourceId"] ?? "出处未知"
        return Button {
            if let source { onOpenSource(source) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: source == nil ? "doc.questionmark" : "arrow.up.forward.square")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(source == nil ? Color.secondary : Color.accentColor)
                Text(materialTitle(material))
                    .font(.system(size: 12))
                Text(sourceID)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if source == nil {
                    Text("原文不可用")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(highlighted ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.03))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(source == nil)
        .help(source == nil ? "这条材料的原文不在本场已保存记录中" : "打开这条材料的已保存原文")
        .accessibilityLabel(
            "\(materialTitle(material)) \(sourceID)"
                + (source == nil ? "，原文不可用" : "，打开原文")
        )
    }

    /// A one-shot domino highlight over the exact recipient's real input rows.
    /// Reduce Motion lists the same rows immediately and skips the highlight
    /// task and its delays entirely.
    private func startMaterialHighlight() {
        highlightTask?.cancel()
        highlightTask = nil
        highlightedMaterials.removeAll()
        guard !reduceMotion else { return }
        guard let count = reviewMaterials?.count, count > 0 else { return }
        highlightTask = Task { @MainActor in
            for index in 0..<count {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    _ = highlightedMaterials.insert(index)
                }
                try? await Task.sleep(nanoseconds: 55_000_000)
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                highlightedMaterials.removeAll()
            }
        }
    }

    private func labeled(_ title: String, text: String, dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "（空）" : text)
                .font(.system(size: 13.5))
                .foregroundStyle(dim ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 非模态文本补录面板

/// Draft state for one backfill panel. The pinned target is captured when the
/// panel opens; a later round change makes the save fail without clearing the
/// text, so a draft can never land in the next round.
@MainActor
final class ArenaBackfillDraft: ObservableObject {
    @Published var provider = ""
    @Published var text = ""
    @Published var stance = ""
    @Published var error = ""
    @Published var note: String?
    @Published var noteIsWarning = false
    @Published var attachmentsConfirmed = false

    private(set) var target: ArenaManualTarget?

    func configure(model: ArenaModel, provider: String) {
        self.provider = provider
        let prefill = model.backfillPrefill(for: provider)
        text = prefill.text
        stance = ""
        error = ""
        target = model.manualTarget(for: provider)
        attachmentsConfirmed = false
        if prefill.isPartial {
            note = "以下为流式预览片段，尚未确认完成；请先核对原页，再修改后提交。"
            noteIsWarning = true
        } else if prefill.isComplete {
            note = "以下为本席已收到但未被采用的完整回答；请核对立场与正文后提交。"
            noteIsWarning = true
        } else if !prefill.text.isEmpty {
            note = "已填入本席当前轮已保存的原文；如与原页不符请直接修改。"
            noteIsWarning = false
        } else {
            note = nil
            noteIsWarning = false
        }
    }
}

struct ArenaBackfillView: View {
    @ObservedObject var model: ArenaModel
    @ObservedObject var draft: ArenaBackfillDraft
    let onClose: () -> Void

    private var providerName: String {
        ArenaSeatCatalog.name(draft.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("文本补录 · \(providerName)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            Text("面板不遮挡原页，便于同时核对。只保存本席这一轮的原文；其他席继续运行。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let target = draft.target {
                Text("已固定为 \(ArenaStageNames.taskLabel(target.stage, round: target.round, session: model.session))\(target.version.map { " · 候选 v\($0)" } ?? "")。保存时若本轮已变化，草稿会保留并报错。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("本席当前没有待处理任务；草稿不会贴入下一轮。请关闭后等本轮出现待答再录入。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.requiresManualAttachmentConfirmation(for: draft.provider) {
                Toggle("已在本席原页核对本轮问题和全部附件", isOn: $draft.attachmentsConfirmed)
            }

            if let note = draft.note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(draft.noteIsWarning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !draft.error.isEmpty {
                Text(draft.error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $draft.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
                .frame(minHeight: 190)

            HStack(spacing: 8) {
                if draft.target?.stage == "vote" {
                    Text("表态")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $draft.stance) {
                        Text("未指定").tag("")
                        Text("同意").tag("agree")
                        Text("有条件同意").tag("conditional")
                        Text("反对").tag("oppose")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }
                Spacer()
                Button("提交补录") { submit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(draft.text.trimmedNonEmpty == nil || draft.target == nil
                        || (model.requiresManualAttachmentConfirmation(for: draft.provider) && !draft.attachmentsConfirmed))
            }
        }
        .padding(14)
        .frame(minWidth: 520, minHeight: 360)
    }

    private func submit() {
        guard let target = draft.target else {
            draft.error = "本席当前没有待处理任务；草稿已保留，请按当前轮重新打开补录"
            return
        }
        guard let text = draft.text.trimmedNonEmpty else { return }
        let accepted = model.manualAnswer(
            draft.provider,
            text: text,
            stance: draft.stance.trimmedNonEmpty,
            expected: target,
            attachmentsConfirmed: draft.attachmentsConfirmed
        )
        guard accepted else {
            draft.error = model.errorMessage.trimmedNonEmpty ?? "回答未采用，草稿已保留"
            return
        }
        onClose()
    }
}

@MainActor
final class ArenaBackfillWindowController: NSObject, NSWindowDelegate {
    static let shared = ArenaBackfillWindowController()

    private var panel: NSPanel?
    private weak var model: ArenaModel?
    private var provider: String?

    private override init() {
        super.init()
    }

    /// Open (or reuse) the panel for one seat. Re-opening the same seat keeps
    /// the current draft; switching seats pins the new round afresh.
    func present(model: ArenaModel, provider: String) {
        if let panel, panel.isVisible, self.model === model, self.provider == provider {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let draft = ArenaBackfillDraft()
        draft.configure(model: model, provider: provider)
        let root = ArenaBackfillView(model: model, draft: draft, onClose: { [weak self] in
            self?.panel?.close()
        })
        let hosting = NSHostingController(rootView: root)

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
            panel.contentViewController = hosting
        } else {
            let rect = NSRect(x: 0, y: 0, width: 580, height: 460)
            hosting.view.frame = rect
            panel = NSPanel(
                contentRect: rect,
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = hosting
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 480, height: 320)
            panel.tabbingMode = .disallowed
            panel.collectionBehavior = [.fullScreenAuxiliary, .managed]
            panel.animationBehavior = .utilityWindow
            panel.delegate = self
            panel.center()
        }
        panel.title = "文本补录 · \(ArenaSeatCatalog.name(provider))"
        self.panel = panel
        self.model = model
        self.provider = provider
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSPanel) === panel else { return }
        provider = nil
    }
}

/// The manifest belongs to the saved opening question. Loading a preview
/// verifies the archived file first, so a missing/replaced original is visible.
struct ArenaSavedMaterials: View {
    @ObservedObject var model: ArenaModel
    @State private var preview: ArenaDraftAttachment?
    @State private var previewError: String?

    private var records: [[String: Any]] { model.sessionAttachments }

    var body: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("开场附件（\(records.count)）").font(.subheadline.weight(.semibold))
                ForEach(Array(records.indices), id: \.self) { index in
                    let record = records[index]
                    let name = record["name"] as? String ?? "附件"
                    let isText = record["kind"] as? String == "text"
                    HStack(spacing: 12) {
                        Button {
                            do {
                                let url = try model.attachmentURL(record)
                                preview = try ArenaDraftAttachment(fileURL: url)
                                previewError = nil
                            } catch { previewError = error.localizedDescription }
                        } label: {
                            Label("\(index + 1). \(name)" + (isText ? "（以文本发送）" : ""),
                                  systemImage: isText ? "doc.plaintext" : "photo")
                        }.buttonStyle(.link)
                        Button {
                            do {
                                let url = try model.attachmentURL(record)
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                previewError = nil
                            } catch { previewError = error.localizedDescription }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("在 Finder 中显示")
                        .accessibilityLabel("在 Finder 中显示" + name)
                    }
                }
                if let previewError { Text(verbatim: previewError).foregroundStyle(.orange) }
                ForEach(ArenaSessionDigest.participants(model.session), id: \.self) { provider in
                    if let summary = model.attachmentDeliverySummary(for: provider) {
                        Text("\(ArenaSeatCatalog.name(provider)) · \(summary)").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            .sheet(item: $preview) { item in ArenaMaterialPreview(item: item) { preview = nil } }
        }
    }
}

// MARK: - Markdown 导出


enum ArenaExporter {

    @MainActor
    static func export(model: ArenaModel, feedback: ArenaFeedbackPresenter) {
        guard model.session != nil else {
            feedback.show("还没有可导出的场次", tone: .failure)
            return
        }
        let markdown = makeMarkdown(model: model)
        let panel = NSSavePanel()
        panel.title = "导出讨论记录"
        panel.prompt = "导出"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename(session: model.session)
        if let type = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = markdown.data(using: .utf8) else {
                throw NSError(domain: "ArenaExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法编码 Markdown"])
            }
            try data.write(to: url, options: .atomic)
        } catch {
            feedback.show("导出失败：\(error.localizedDescription)", tone: .failure)
            return
        }
        feedback.show("已导出 Markdown")
    }

    @MainActor
    static func makeMarkdown(model: ArenaModel) -> String {
        let session = model.session
        var lines: [String] = []
        let participants = ArenaSessionDigest.participants(session)
        let providers = participants.isEmpty
            ? ArenaSeatCatalog.ordered.filter { model.panes[$0] != nil }
            : participants

        lines.append("# AI Arena 讨论记录")
        lines.append("")
        lines.append("- 场次：\(ArenaSessionDigest.id(session) ?? "（未编号）")")
        lines.append("- 导出时间：\(localTimestamp())（本地时间）")
        lines.append("- 阶段：\(ArenaStageNames.label((session?["stage"] as? String) ?? ""))")
        if let reviewRound = ArenaStageNames.reviewRound(session) {
            lines.append("- \(reviewRound)")
        }
        if let paused = session?["paused"] as? Bool, paused {
            lines.append("- 暂停：是")
        }
        lines.append("")
        lines.append("## 题面")
        lines.append("")
        lines.append((session?["question"] as? String) ?? model.question)
        lines.append("")
        if let attachments = session?["attachments"] as? [[String: Any]], !attachments.isEmpty {
            lines.append("### 开场附件")
            lines.append("")
            for (index, record) in attachments.enumerated() {
                let name = record["name"] as? String ?? "附件"
                let kind = record["kind"] as? String == "text" ? "以文本发送" : "图片"
                let longestRun = name.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let ticks = String(repeating: "`", count: longestRun + 1)
                lines.append("\(index + 1). \(ticks) \(name) \(ticks)（\(kind)）")
            }
            lines.append("")
            for provider in providers {
                if let summary = model.attachmentDeliverySummary(for: provider) {
                    lines.append("- \(ArenaSeatCatalog.name(provider)) · \(summary)")
                }
            }
            lines.append("")
        }
        lines.append("## 参与者与状态")
        lines.append("")
        lines.append("| 席位 | 站点 | 状态 |")
        lines.append("| --- | --- | --- |")
        let ballot = model.reportBallot()
        for provider in providers {
            // Durable, session-derived status: the final same-version stance,
            // a skip, a pending seat or "not in this stage". Never the transient
            // UI badge (which would say e.g. 「只读回看」 in history).
            let state = ArenaSeatOutcome.derive(session: session, provider: provider, ballot: ballot)
            lines.append("| `\(provider)` | \(ArenaSeatCatalog.name(provider)) | \(state.detail) |")
        }
        lines.append("")

        lines.append("## 当前提示")
        lines.append("")
        for provider in providers {
            let task = ArenaSessionDigest.currentTask(session, provider: provider)
            lines.append("### \(ArenaSeatCatalog.name(provider))")
            lines.append("")
            if let task {
                lines.append("阶段：\(ArenaStageNames.taskLabel(task.stage, round: task.round, session: session))"
                    + (task.sourceId.isEmpty ? "" : " · \(task.sourceId)"))
                lines.append("")
                lines.append(fenced(task.prompt))
            } else {
                lines.append("（无进行中的提示）")
            }
            lines.append("")
        }

        let answerRows = ArenaSessionDigest.answerRows(session)
        lines.append("## 历史原文")
        lines.append("")
        if answerRows.isEmpty {
            lines.append("（还没有保存的原文）")
            lines.append("")
        } else {
            for row in answerRows {
                let source = row.sourceId.isEmpty ? "" : " · \(row.sourceId)"
                lines.append("### \(ArenaStageNames.taskLabel(row.stage, round: row.round, session: session)) · \(ArenaSeatCatalog.name(row.provider))\(source)")
                lines.append("")
                lines.append("**提示**")
                lines.append("")
                lines.append(fenced(row.prompt))
                lines.append("")
                lines.append("**原文**")
                lines.append("")
                lines.append(fenced(row.answer ?? ""))
                lines.append("")
            }
        }

        lines.append("## 报告")
        lines.append("")
        if let report = ArenaSessionDigest.report(session) {
            lines.append(report)
        } else {
            lines.append("（尚未生成报告）")
        }
        lines.append("")
        if let reason = ArenaSessionDigest.stopReason(session) {
            lines.append("## 停止原因")
            lines.append("")
            lines.append(reason)
            lines.append("")
        }

        lines.append("## 附：会话原始数据")
        lines.append("")
        lines.append(fenced(ArenaJSON.string(session), language: "json"))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func fenced(_ text: String, language: String = "text") -> String {
        // 用四个反引号，正文里出现三反引号时也不会截断。
        return "````\(language)\n\(text)\n````"
    }

    /// ISO 8601 in the machine's local time zone, including its offset.
    private static func localTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func defaultFilename(session: [String: Any]?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        if let id = ArenaSessionDigest.id(session)?.trimmedNonEmpty {
            return "AI-Arena-\(stamp)-\(id).md"
        }
        return "AI-Arena-\(stamp).md"
    }
}

// MARK: - 终端冒烟验收

/// 只在夹具/回环环境运行。启动已挂载的三席真实网页后，用同一
/// model.start 发送合成问题；stage 变为 done 时把 session JSON 写入
/// ARENA_SMOKE_RESULT，超时写诊断并退出。
final class SmokeRunner {

    static let shared = SmokeRunner()
    static let isEnabled = CommandLine.arguments.contains("--smoke-test")

    private static let providers = ["chatgpt", "gemini", "deepseek"]
    private var started = false

    private init() {}

    // MARK: 预检（在创建窗口和网页之前）

    static func preflight() {
        let environment = ProcessInfo.processInfo.environment
        if ArenaBuildIsolation.isQABuild {
            // WebKit can ask Security.framework for its WebCrypto key. A QA
            // process must fail an interactive lookup before creating any pane.
            guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                Self.writeStderr("[qa] Could not disable keychain interaction.")
                exit(2)
            }
            guard isEnabled, environment["ARENA_DATA_DIR"]?.trimmedNonEmpty != nil else {
                Self.writeStderr("[qa] Start this copy through the native acceptance harness.")
                exit(2)
            }
        } else if isEnabled || environment["ARENA_FIXTURE_BASE"]?.trimmedNonEmpty != nil {
            Self.writeStderr("[qa] Use tests/native_desktop_acceptance.py to run a separate fixture app.")
            exit(2)
        }
        guard isEnabled else { return }
        guard let resultPath = environment["ARENA_SMOKE_RESULT"]?.trimmedNonEmpty else {
            Self.writeStderr("[smoke] ARENA_SMOKE_RESULT is required")
            exit(2)
        }
        do {
            let rawBase = environment["ARENA_FIXTURE_BASE"]?.trimmedNonEmpty
            let validFixture: Bool = {
                guard let rawBase,
                      let url = URL(string: rawBase),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { return false }
                return url.host == "127.0.0.1" && scheme == "http"
            }()
            if !validFixture {
                let diagnostic: [String: Any] = [
                    "ok": false,
                    "reason": "fixture-required",
                    "detail": "ARENA_FIXTURE_BASE 必须是 http://127.0.0.1[:端口] 的回环地址；冒烟模式默认不触达真实站点",
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                ]
                Self.write(diagnostic, to: resultPath)
                Self.writeStderr("[smoke] refusing to run against real sites: set ARENA_FIXTURE_BASE to a loopback base")
                exit(3)
            }
        }
    }

    // MARK: 运行

    @MainActor
    func begin(model: ArenaModel) {
        guard SmokeRunner.isEnabled, !started else { return }
        started = true
        Task { @MainActor in
            await run(model: model)
        }
    }

    @MainActor
    private func run(model: ArenaModel) async {
        let environment = ProcessInfo.processInfo.environment
        guard let resultPath = environment["ARENA_SMOKE_RESULT"]?.trimmedNonEmpty else {
            Self.writeStderr("[smoke] ARENA_SMOKE_RESULT is required")
            exit(2)
        }
        let timeout = Double(environment["ARENA_SMOKE_TIMEOUT"] ?? "") ?? 120
        let mountDeadline = Date().addingTimeInterval(min(45, timeout))

        Self.writeStderr("[smoke] waiting for three mounted panes…")
        while Date() < mountDeadline {
            let panes = model.panes
            if SmokeRunner.providers.allSatisfy({ panes[$0]?.documentReady == true }) {
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let panes = model.panes
        let notReady = SmokeRunner.providers.filter { panes[$0]?.documentReady != true }
        guard notReady.isEmpty else {
            var details: [String: Any] = [:]
            for provider in SmokeRunner.providers {
                details[provider] = [
                    "mounted": panes[provider] != nil,
                    "ready": panes[provider]?.documentReady ?? false,
                    "url": panes[provider]?.currentURL?.absoluteString ?? "",
                    "error": panes[provider]?.lastError ?? "",
                ]
            }
            writeDiagnostics(
                path: resultPath,
                reason: "panes-not-ready",
                detail: "未加载完成的席位：\(notReady.joined(separator: ", "))",
                model: model,
                extra: ["panes": details]
            )
            exit(4)
        }

        if CommandLine.arguments.contains("--smoke-check-restart") {
            if CommandLine.arguments.contains("--smoke-check-history") {
                guard let id = model.session?.arenaString("id") else { exit(10) }
                model.openHistory(id)
                guard model.isReadOnly, model.historyResumeID == id,
                      model.continueSavedDiscussion(id), !model.isReadOnly else {
                    Self.writeStderr("[smoke] could not continue the unfinished history session")
                    exit(10)
                }
            }
            // Prove the ordinary relaunch path stays conservative: wait long
            // enough for a stray dispatch to show, then report without sending.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let payload: [String: Any] = [
                "ok": true,
                "reason": "restart-conservative",
                "didContinue": model.didContinueSavedDiscussion,
                "statuses": model.statuses,
                "seatStates": SmokeRunner.seatStatePayload(model),
                "stage": model.session?.arenaString("stage") ?? "",
                "session": model.session ?? [:],
            ]
            Self.write(payload, to: resultPath)
            Self.writeStderr("[smoke] ordinary restart checked; no dispatch expected")
            exit(0)
        }
        if CommandLine.arguments.contains("--smoke-prepare-recovery") {
            loadFixtureAttachments(model: model, path: resultPath)
            await runPrepareRecovery(model: model, resultPath: resultPath, timeout: timeout)
            return
        }
        if CommandLine.arguments.contains("--smoke-continue-recovery") {
            await runContinueRecovery(model: model, resultPath: resultPath, timeout: timeout)
            return
        }

        if CommandLine.arguments.contains("--smoke-restore") {
            guard let session = model.session, session["stage"] as? String == "done" else {
                Self.write(["error": "没有恢复已完成的场次"], to: resultPath)
                exit(5)
            }
            // Exercise the same serializer as the native Save panel.
            do {
                if CommandLine.arguments.contains("--smoke-evaluation") {
                    guard let id = session.arenaString("id"),
                          let evaluation = try model.evaluation(sessionID: id),
                          evaluation.comparisons.count == 3, evaluation.checks.count == 1,
                          evaluation.ranks == nil else { throw ArenaEngineError("未恢复评估及复判") }
                }
                try ArenaExporter.makeMarkdown(model: model).write(
                    to: URL(fileURLWithPath: resultPath).deletingLastPathComponent().appendingPathComponent("export.md"),
                    atomically: true, encoding: .utf8)
            } catch {
                Self.writeStderr(error.localizedDescription)
                exit(6)
            }
            Self.write(session, to: resultPath)
            exit(0)
        }
        loadFixtureAttachments(model: model, path: resultPath)
        let question = "【冒烟测试】如果只有两个周末，个人笔记工具应先做移动端采集，还是先补桌面检索？请给出判断和一个可验证的理由。"
        model.question = question
        await captureComposerIfRequested()
        Self.writeStderr("[smoke] panes ready; starting discussion")
        model.start(SmokeRunner.providers)

        let verifyTakeover = CommandLine.arguments.contains("--smoke-takeover")
        var didBackfill = false
        if verifyTakeover { model.takeOver("deepseek") }
        let stageDeadline = Date().addingTimeInterval(timeout)
        while Date() < stageDeadline {
            if verifyTakeover && !didBackfill,
               let tasks = model.session?["tasks"] as? [[String: Any]],
               tasks.count == 3,
               tasks.filter({ ($0["provider"] as? String) != "deepseek" }).allSatisfy({ ($0["status"] as? String) == "answered" }),
               tasks.first(where: { ($0["provider"] as? String) == "deepseek" })?["status"] as? String == "pending" {
                guard let target = model.manualTarget(for: "deepseek"),
                      model.manualAnswer("deepseek", text: "夹具人工接管原文", stance: nil, expected: target),
                      !model.manualAnswer("deepseek", text: "上一轮的旧草稿", stance: nil, expected: target) else {
                    Self.writeStderr("[smoke] manual answer task binding failed")
                    exit(7)
                }
                model.resumeSeat("deepseek")
                didBackfill = true
            }
            if (model.session?["stage"] as? String) == "done" {
                guard let session = model.session else { break }
                if CommandLine.arguments.contains("--smoke-evaluation"), let id = session.arenaString("id") {
                    do {
                        guard try model.evaluation(sessionID: id) == nil else {
                            throw ArenaEngineError("未触发前已有评估")
                        }
                        let evaluation = try await model.runEvaluation(sessionID: id)
                        guard let pair = evaluation.comparisons.first, evaluation.ranks?.count == 3 else {
                            throw ArenaEngineError("初判缺少三席排名")
                        }
                        let checked = try await model.runEvaluation(sessionID: id, reversing: pair.id)
                        guard checked.comparisons.count == 3, checked.checks.count == 1, checked.ranks == nil else {
                            throw ArenaEngineError("复判冲突没有被保留")
                        }
                    } catch {
                        Self.writeStderr("[smoke] evaluation: \(error.localizedDescription)")
                        exit(11)
                    }
                }
                Self.write(session, to: resultPath)
                Self.writeStderr("[smoke] stage done; session written to \(resultPath)")
                exit(0)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        writeDiagnostics(
            path: resultPath,
            reason: "timeout",
            detail: "等待 stage=done 超时（\(Int(timeout))s）",
            model: model,
            extra: ["providers": SmokeRunner.providers]
        )
        exit(1)
    }

    /// Snapshot only the isolated QA app window, after the actual composer
    /// has rendered the imported draft and before its dispatch starts.
    @MainActor
    private func captureComposerIfRequested() async {
        guard let path = ProcessInfo.processInfo.environment["ARENA_SMOKE_COMPOSER_CAPTURE"]?.trimmedNonEmpty else { return }
        try? await Task.sleep(nanoseconds: 800_000_000)
        do {
            guard let content = NSApp.windows.first(where: { $0.title == "AI Arena" })?.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw ArenaEngineError("无法取得验收应用的工作台")
            }
            content.layoutSubtreeIfNeeded()
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw ArenaEngineError("无法生成提问区验收截图")
            }
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            Self.writeStderr("[smoke] " + error.localizedDescription)
            exit(2)
        }
    }

    @MainActor
    private func loadFixtureAttachments(model: ArenaModel, path: String) {
        guard let dir = ProcessInfo.processInfo.environment["ARENA_SMOKE_ATTACHMENT_DIR"]?.trimmedNonEmpty else { return }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir),
                                                                  includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let files = try urls.map { try ArenaDraftAttachment(fileURL: $0) }
            model.addDraftAttachments(files)
            guard !files.isEmpty, model.draftAttachments.count == files.count else {
                throw ArenaEngineError(model.errorMessage.trimmedNonEmpty ?? "验收附件为空")
            }
        } catch {
            writeDiagnostics(path: path, reason: "fixture-attachment-import", detail: error.localizedDescription,
                             model: model, extra: [:])
            exit(2)
        }
    }

    /// First half of the isolated continuation check: start a normal
    /// discussion on the fixture pages and stop as soon as two first-round
    /// answers are recorded and the third seat is stuck before send with a
    /// durable `.prepared` intent. Nothing is forced into the session.
    @MainActor
    private func runPrepareRecovery(model: ArenaModel, resultPath: String, timeout: Double) async {
        let question = "【恢复验收】如果只有两个周末，个人笔记工具应先做移动端采集，还是先补桌面检索？请给出判断和一个可验证的理由。"
        model.question = question
        await captureComposerIfRequested()
        Self.writeStderr("[smoke] preparing a two-answered, one-prepared first round")
        model.start(SmokeRunner.providers)

        let deadline = Date().addingTimeInterval(min(max(timeout, 30), 120))
        while Date() < deadline {
            if (model.session?["stage"] as? String) == "independent",
               let tasks = model.session?["tasks"] as? [[String: Any]],
               tasks.count == SmokeRunner.providers.count {
                let answered = tasks.filter { ($0["status"] as? String) == "answered" }
                let pending = tasks.filter { ($0["status"] as? String) == "pending" }
                if answered.count == 2, pending.count == 1,
                   let provider = pending.first?["provider"] as? String,
                   model.deliveryPhase(for: provider) == "prepared" {
                    let payload: [String: Any] = [
                        "ok": true,
                        "reason": "recovery-armed",
                        "sessionID": model.session?.arenaString("id") ?? "",
                        "stage": model.session?.arenaString("stage") ?? "",
                        "statuses": model.statuses,
                        "seatStates": SmokeRunner.seatStatePayload(model),
                        "pendingProvider": provider,
                        "pendingPhase": "prepared",
                        "session": model.session ?? [:],
                    ]
                    Self.write(payload, to: resultPath)
                    Self.writeStderr("[smoke] recovery armed: two answers saved, \(provider) is prepared")
                    exit(0)
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        writeDiagnostics(
            path: resultPath,
            reason: "prepare-recovery-timeout",
            detail: "等待“两席已答、一席 prepared”超时（\(Int(timeout))s）",
            model: model,
            extra: ["providers": SmokeRunner.providers]
        )
        exit(8)
    }

    /// Second half: the app was launched with `--continue-saved-discussion`
    /// already; wait for the normal multi-round flow to reach the report.
    @MainActor
    private func runContinueRecovery(model: ArenaModel, resultPath: String, timeout: Double) async {
        guard model.didContinueSavedDiscussion else {
            writeDiagnostics(
                path: resultPath,
                reason: "continue-not-authorized",
                detail: "指定的场次未通过显式恢复检查",
                model: model
            )
            exit(9)
        }
        guard let sessionID = model.session?.arenaString("id") else {
            writeDiagnostics(
                path: resultPath,
                reason: "no-saved-session",
                detail: "没有可继续的已保存场次",
                model: model
            )
            exit(9)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (model.session?["stage"] as? String) == "done" {
                do {
                    try ArenaExporter.makeMarkdown(model: model).write(
                        to: URL(fileURLWithPath: resultPath)
                            .deletingLastPathComponent()
                            .appendingPathComponent("export.md"),
                        atomically: true,
                        encoding: .utf8
                    )
                } catch {
                    Self.writeStderr("[smoke] export failed: \(error.localizedDescription)")
                    exit(6)
                }
                let payload: [String: Any] = [
                    "ok": true,
                    "reason": "recovered",
                    "sessionID": sessionID,
                    "statuses": model.statuses,
                    "seatStates": SmokeRunner.seatStatePayload(model),
                    "session": model.session ?? [:],
                ]
                Self.write(payload, to: resultPath)
                Self.writeStderr("[smoke] recovered discussion finished; result written")
                exit(0)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        writeDiagnostics(
            path: resultPath,
            reason: "continue-timeout",
            detail: "显式恢复后等待 stage=done 超时（\(Int(timeout))s）",
            model: model,
            extra: ["sessionID": sessionID]
        )
        exit(1)
    }

    // MARK: 写出

    /// A JSON-safe, explicit `{kind, detail}` map for the smoke diagnostics.
    @MainActor
    static func seatStatePayload(_ model: ArenaModel) -> [String: [String: String]] {
        model.seatStates.mapValues { $0.jsonObject }
    }

    @MainActor
    private func writeDiagnostics(
        path: String,
        reason: String,
        detail: String,
        model: ArenaModel,
        extra: [String: Any] = [:]
    ) {
        var payload: [String: Any] = [
            "ok": false,
            "reason": reason,
            "detail": detail,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "statuses": model.statuses,
            "seatStates": Self.seatStatePayload(model),
            "errorMessage": model.errorMessage,
            "question": model.question,
        ]
        for (key, value) in extra { payload[key] = value }
        if let session = model.session { payload["session"] = session }
        Self.write(payload, to: path)
        Self.writeStderr("[smoke] diagnostic written to \(path): \(reason) — \(detail)")
    }

    static func write(_ object: Any, to path: String) {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var payload = object
        if !JSONSerialization.isValidJSONObject(object) {
            payload = [
                "ok": false,
                "reason": "not-serializable",
                "description": String(describing: object),
            ] as [String: Any]
        }

        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: .atomic)
        } catch {
            Self.writeStderr("[smoke] failed to write \(path): \(error.localizedDescription)")
        }
    }

    static func writeStderr(_ message: String) {
        if let data = (message + "\n").data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
