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
    @StateObject private var model: ArenaModel

    init() {
        // 冒烟配置不合法时必须在 ArenaModel 创建（会打开原页）之前退出。
        SmokeRunner.preflight()
        _model = StateObject(
            wrappedValue: ArenaModel(
                continueSessionID: ArenaLaunchOptions.continueSessionID()
            )
        )
    }

    var body: some Scene {
        Window("AI Arena", id: "arena-main") {
            ArenaRootView(model: model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 860)
    }
}

final class ArenaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - 主界面

struct ArenaRootView: View {
    @ObservedObject var model: ArenaModel

    @State private var selectedProviders: Set<String> = Set(ArenaSeatCatalog.ordered)
    @State private var roundLimit = 3
    private var hasStarted: Bool { model.session != nil }
    @State private var takenOver: Set<String> = []
    @State private var detailsRequest: ArenaDetailRequest?
    @State private var backfillRequest: ArenaSeatTarget?
    @State private var backfillTarget: ArenaManualTarget?
    @State private var backfillError = ""
    @State private var backfillText = ""
    @State private var backfillStance = ""

    @FocusState private var questionFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .task {
            model.prepareHome()
            if model.isRecovering && model.stageKey == "done" && !SmokeRunner.isEnabled {
                presentDetails(provider: nil, tab: .report)
            }
            if !hasStarted {
                questionFocused = true
            }
            SmokeRunner.shared.begin(model: model)
        }
        .onChange(of: model.stageKey) { stage in
            if stage == "done", !model.isReadOnly, backfillRequest == nil {
                presentDetails(provider: nil, tab: .report)
            }
        }
        .sheet(item: $detailsRequest) { request in
            ArenaDetailsSheet(model: model, request: request)
        }
        .sheet(item: $backfillRequest, onDismiss: {
            backfillTarget = nil
            backfillError = ""
        }) { target in
            backfillSheet(provider: target.id)
        }
    }

    // MARK: 顶部工作台（系统玻璃质感；开始前大输入框，开始后只读题面）

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
            ArenaGlassSurface(material: .headerView, cornerRadius: 0)
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
            if compact {
                iconToolButton("查看当前提示、历史原文、报告与原始记录", icon: "sidebar.right") {
                    presentDetails(provider: nil, tab: .prompts)
                }
                .disabled(model.session == nil)
                iconToolButton("以 Markdown 保存本场记录", icon: "square.and.arrow.up") {
                    ArenaExporter.export(model: model)
                }
                .disabled(model.session == nil)
            } else {
                toolButton("详情", icon: "sidebar.right") {
                    presentDetails(provider: nil, tab: .prompts)
                }
                .disabled(model.session == nil)
                .help("查看当前提示、历史原文、报告与原始记录")
                toolButton("导出", icon: "square.and.arrow.up") {
                    ArenaExporter.export(model: model)
                }
                .disabled(model.session == nil)
                .help("以 Markdown 保存本场记录")
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
            if model.historyList.isEmpty {
                Button("暂无历史") {}.disabled(true)
            } else {
                ForEach(Array(model.historyList.enumerated()), id: \.offset) { _, item in
                    Button(arenaShorten(item.question, limit: 42)) {
                        openHistory(item.id)
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

    // MARK: 开始前：大号多行问题输入

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                    .accessibilityHidden(true)

                TextField(
                    "你想让它们讨论什么？",
                    text: $model.question,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(3...7)
                .focused($questionFocused)
                .accessibilityLabel("讨论问题")
                .help("⌘↩ 开始讨论")

                if model.question.trimmedNonEmpty != nil {
                    Button {
                        model.question = ""
                        questionFocused = true
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

            Divider().opacity(0.45)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    seatChips
                    roundPicker
                    Spacer(minLength: 8)
                    startButton
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 12) {
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
    }

    private var seatChips: some View {
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
                .help(selected ? "本场参与：\(ArenaSeatCatalog.name(provider))" : "点击加入本场")
                .accessibilityLabel("\(ArenaSeatCatalog.name(provider))，\(selected ? "已选择" : "未选择")")
            }
        }
        .fixedSize()
    }

    private var roundPicker: some View {
        HStack(spacing: 5) {
            Text("轮数")
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
            .help("新场次最多讨论轮数（含首轮独立作答、互评、候选与表态，默认 3）")
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

            Button {
                arenaCopyToPasteboard(lockedQuestion)
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
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        )
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            stagePill
            Spacer(minLength: 8)
            toolButton(
                isPaused ? "继续" : "暂停",
                icon: isPaused ? "play.fill" : "pause.fill",
                large: true,
                action: pauseOrResume
            )
            .disabled(!isRunning)
            .help(isPaused ? "继续派发后续轮次" : "暂停后续派发，保留当前进度")
            toolButton("结束", icon: "stop.fill", large: true, action: finishDiscussion)
                .disabled(!isRunning)
                .help("结束本轮讨论并保留已保存内容")
            toolButton("新建", icon: "square.and.pencil", large: true, action: newDiscussion)
                .help("清空当前场次，开始新的问题")
        }
    }

    private var stagePill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 8, height: 8)
                .shadow(color: isRunning ? Color.green.opacity(0.6) : .clear, radius: 3)
            Text(stageText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 26)
        .background(Capsule().fill(Color.primary.opacity(0.055)))
        .fixedSize()
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
                ScrollView {
                    Text((saved["report"] as? String) ?? "该场次尚未生成报告，可在详情中查阅已保存的发言。")
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                let columns = columnCount(for: providers.count, width: geometry.size.width)
                let rows = rowsOf(providers, columns: columns)
                VStack(spacing: 8) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        HStack(spacing: 8) {
                            ForEach(rows[rowIndex], id: \.self) { provider in
                                seatCard(provider)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            ForEach(Array(0..<max(0, columns - rows[rowIndex].count)), id: \.self) { _ in
                                Color.clear
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func seatCard(_ provider: String) -> some View {
        if let pane = model.panes[provider] {
            let badge = seatBadge(provider)
            ArenaSeatCard(
                pane: pane,
                provider: provider,
                statusText: badge.text,
                statusColor: badge.color,
                isParticipant: isParticipant(provider),
                hasStarted: hasStarted,
                canOpenHome: canOpenHome(provider),
                onPrompt: { presentDetails(provider: provider, tab: .prompts) },
                onTakeOver: { takeOver(provider) },
                onResume: { takenOver.remove(provider); model.resumeSeat(provider) },
                canManage: isRunning && isParticipant(provider),
                onBackfill: { presentBackfill(provider) },
                onSkip: { model.skip(provider) }
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

    // MARK: 补录

    private func backfillSheet(provider: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("文本补录 · \(ArenaSeatCatalog.name(provider))")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("取消") { backfillRequest = nil }
                    .keyboardShortcut(.cancelAction)
            }
            Text("仅保存本席这一轮的原文；其他席继续运行。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if let target = backfillTarget {
                Text("已固定为 \(ArenaStageNames.label(target.stage)) · 第 \(target.round) 轮\(target.version.map { " · 候选 v\($0)" } ?? "")。保存时若本轮已变化，草稿会保留并报错。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("本席当前没有待处理任务；草稿不会贴入下一轮。请关闭后等本轮出现待答再录入。")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            if let message = backfillError.trimmedNonEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $backfillText)
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
                .frame(minHeight: 220)

            HStack(spacing: 8) {
                Text("表态")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Picker("", selection: $backfillStance) {
                    Text("未指定").tag("")
                    Text("同意").tag("agree")
                    Text("有条件同意").tag("conditional")
                    Text("反对").tag("oppose")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                Spacer()
                Button("提交补录") {
                    submitBackfill(provider)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(backfillText.trimmedNonEmpty == nil || backfillTarget == nil)
            }
        }
        .padding(14)
        .frame(minWidth: 560, minHeight: 380)
    }

    // MARK: 动作

    private func startDiscussion() {
        guard canStart else { return }
        let providers = ArenaSeatCatalog.ordered.filter { selectedProviders.contains($0) }
        guard providers.count >= 2 else {
            model.errorMessage = "至少保留两席"
            return
        }
        takenOver = []
        model.start(providers, maxRounds: roundLimit)
    }

    private func pauseOrResume() {
        model.pauseOrResume()
    }

    private func finishDiscussion() {
        model.finish()
    }

    private func newDiscussion() {
        takenOver = []
        selectedProviders = Set(ArenaSeatCatalog.ordered)
        roundLimit = 3
        detailsRequest = nil
        backfillRequest = nil
        backfillTarget = nil
        backfillError = ""
        backfillText = ""
        backfillStance = ""
        model.newDiscussion()
        model.prepareHome()
        DispatchQueue.main.async { questionFocused = true }
    }

    private func takeOver(_ provider: String) {
        model.takeOver(provider)
        takenOver.insert(provider)
        presentBackfill(provider)
    }

    private func presentBackfill(_ provider: String) {
        backfillText = ArenaSessionDigest.answerText(model.session, provider: provider) ?? ""
        backfillStance = ""
        backfillError = ""
        // Pin the exact round now. A save checks this snapshot again, so the
        // draft cannot be pasted into whatever task the next round creates.
        backfillTarget = model.manualTarget(for: provider)
        backfillRequest = ArenaSeatTarget(id: provider)
    }

    private func submitBackfill(_ provider: String) {
        guard let text = backfillText.trimmedNonEmpty else { return }
        guard let target = backfillTarget, target.provider == provider else {
            backfillError = "本席当前没有待处理任务；草稿已保留，请关闭后按当前轮重新录入"
            return
        }
        let accepted = model.manualAnswer(
            provider,
            text: text,
            stance: backfillStance.trimmedNonEmpty,
            expected: target
        )
        guard accepted else {
            // Keep the sheet, the text and the pinned snapshot: the round may
            // have moved on, and this draft must not land in the next one.
            backfillError = model.errorMessage.trimmedNonEmpty ?? "回答未采用，草稿已保留"
            return
        }
        backfillRequest = nil
        backfillText = ""
        backfillStance = ""
    }

    private func openHistory(_ id: String) {
        takenOver = []
        model.openHistory(id)
        presentDetails(provider: nil, tab: .report)
    }

    private func presentDetails(provider: String?, tab: ArenaInspectorTab) {
        detailsRequest = ArenaDetailRequest(provider: provider, tab: tab)
    }

    private func toggleSeat(_ provider: String) {
        if selectedProviders.contains(provider) {
            if selectedProviders.count > 2 {
                selectedProviders.remove(provider)
            }
        } else {
            selectedProviders.insert(provider)
        }
        model.prepareHome(selectedProviders)
    }

    // MARK: 派生状态

    private var isRunning: Bool {
        guard !model.isReadOnly, let stage = model.session?["stage"] as? String else { return false }
        return stage != "done"
    }

    private var isPaused: Bool {
        (model.session?["paused"] as? Bool) ?? false
    }

    private var canStart: Bool {
        model.question.trimmedNonEmpty != nil
            && selectedProviders.count >= 2
            && selectedProviders.count <= 3
            && !isRunning
    }

    private var stageText: String {
        guard let session = model.session else {
            return hasStarted ? "准备中" : "未开始"
        }
        let stage = (session["stage"] as? String) ?? ""
        let round = ArenaValue.int(session["round"]) ?? 1
        let paused = (session["paused"] as? Bool) ?? false
        var text = ArenaStageNames.label(stage)
        if stage != "done" && !stage.isEmpty {
            text += " · 第 \(round) 轮"
        }
        if let tasks = session["tasks"] as? [[String: Any]], !tasks.isEmpty, stage != "done" {
            let answered = tasks.filter { ($0["status"] as? String) == "answered" }.count
            text += " · 已收到 " + String(answered) + "/" + String(tasks.count)
            let pending = tasks.filter { ($0["status"] as? String) == "pending" }
            if pending.count == 1, let seat = pending[0]["provider"] as? String {
                text += " · 等待 " + ArenaSeatCatalog.name(seat)
            }
        }
        if paused { text += " · 已暂停" }
        return text
    }

    private var gridProviders: [String] {
        let panes = model.panes
        let known = ArenaSeatCatalog.ordered.filter { panes[$0] != nil }
        let extra = panes.keys.filter { !ArenaSeatCatalog.ordered.contains($0) }.sorted()
        return known + extra
    }

    private func columnCount(for count: Int, width: CGFloat) -> Int {
        if count <= 2 { return max(count, 1) }
        return width >= 1040 ? 3 : 2
    }

    private func rowsOf(_ providers: [String], columns: Int) -> [[String]] {
        guard columns > 0 else { return [providers] }
        return stride(from: 0, to: providers.count, by: columns).map {
            Array(providers[$0..<min($0 + columns, providers.count)])
        }
    }

    private func isParticipant(_ provider: String) -> Bool {
        guard let providers = model.session?["providers"] as? [String] else { return true }
        return providers.contains(provider)
    }

    private func canOpenHome(_ provider: String) -> Bool {
        if !hasStarted { return true }
        if takenOver.contains(provider) { return true }
        if let raw = model.statuses[provider]?.lowercased(),
           raw.contains("manual") || raw.contains("takeover") || raw.contains("接管") {
            return true
        }
        return false
    }

    private func seatBadge(_ provider: String) -> (text: String, color: Color) {
        if let raw = model.statuses[provider]?.trimmedNonEmpty {
            return ArenaSeatStatus.describe(raw)
        }
        guard let session = model.session else { return ("待开始", Color.secondary) }
        let stage = (session["stage"] as? String) ?? ""
        let rows = ArenaSessionDigest.rows(session)
        if let row = rows.last(where: { $0.provider == provider && $0.stage == stage }) {
            switch row.status.lowercased() {
            case "answered": return ("已收到", Color.green)
            case "skipped": return ("已跳过", Color.secondary)
            default: return ("等待回复", Color.orange)
            }
        }
        if rows.contains(where: { $0.provider == provider && $0.answer?.trimmedNonEmpty != nil }) {
            return ("已完成", Color.green)
        }
        return ("未参与", Color.secondary)
    }
}

// MARK: - 单席卡片

/// 每席单独观察自己的 SitePane，页面加载完成或失败时只重绘本卡，
/// 不重建 webView，也不触发网页重载。
struct ArenaSeatCard: View {
    @ObservedObject var pane: SitePane

    let provider: String
    let statusText: String
    let statusColor: Color
    let isParticipant: Bool
    let hasStarted: Bool
    let canOpenHome: Bool

    let onPrompt: () -> Void
    let onTakeOver: () -> Void
    let onResume: () -> Void
    let canManage: Bool
    let onBackfill: () -> Void
    let onSkip: () -> Void

    private var openError: String? {
        pane.lastError ?? pane.lastNavigationError
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.45), radius: 3)
                Text(ArenaSeatCatalog.name(provider))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusColor.opacity(0.12)))
                    .frame(maxWidth: 190, alignment: .leading)
                    .help(statusText)
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
            .padding(.horizontal, 9)
            .frame(height: 36)
            .background(Color.primary.opacity(0.035))

            Divider()

            ZStack {
                SitePaneView(pane: pane)
                if pane.webView.url == nil || pane.isWebContentTerminated {
                    placeholder
                }
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
    }

    private var menu: some View {
        Menu {
            Button("查看当前提示…", action: onPrompt)
            Button("回原站首页") { pane.openHome() }
                .disabled(!canOpenHome)
            Divider()
            Group {
                Button("恢复本站自动", action: onResume)
                Button("人工接管", action: onTakeOver)
                Button("文本补录…", action: onBackfill)
                Button("跳过本席", action: onSkip)
            }
            .disabled(!canManage)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
        .help("本席操作：回首页（未开始或已接管时）、接管、补录、跳过")
        .accessibilityLabel("本席操作")
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

// MARK: - 席位状态词典

enum ArenaSeatStatus {
    static func describe(_ raw: String) -> (String, Color) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if text.isEmpty { return ("待开始", Color.secondary) }
        if lower.contains("skip") || text.contains("跳过") { return ("已跳过", Color.secondary) }
        if lower.contains("error") || lower.contains("fail") || lower.contains("timeout")
            || text.contains("失败") || text.contains("需处理") {
            return ("需处理", Color.red)
        }
        if lower.contains("manual") || lower.contains("takeover") || text.contains("接管") {
            return ("人工接管", Color.orange)
        }
        if lower.contains("answer") || lower.contains("done") || lower.contains("complete")
            || lower.contains("ok") || text.contains("已收到") || text.contains("完成") {
            return ("已收到", Color.green)
        }
        if lower.contains("stream") || lower.contains("generat") || lower.contains("working")
            || lower.contains("sent") || lower.contains("progress") || lower.contains("wait")
            || lower.contains("pending") || text.contains("生成") || text.contains("等待") {
            return ("进行中", Color.blue)
        }
        return (text, Color.secondary)
    }
}

enum ArenaStageNames {
    static let labels: [String: String] = [
        "independent": "独立作答",
        "critique": "质询",
        "proposal": "候选结论",
        "vote": "表决",
        "done": "结束",
    ]

    static func label(_ stage: String) -> String {
        if stage.isEmpty { return "未开始" }
        return labels[stage] ?? stage
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

    static func answerText(_ session: [String: Any]?, provider: String) -> String? {
        if let task = currentTask(session, provider: provider), let answer = task.answer?.trimmedNonEmpty {
            return answer
        }
        return lastTask(session, provider: provider)?.answer?.trimmedNonEmpty
    }

    static func answerRows(_ session: [String: Any]?) -> [ArenaTaskRow] {
        rows(session).filter { $0.answer?.trimmedNonEmpty != nil }
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

    var label: String {
        switch self {
        case .prompts: return "当前提示"
        case .answers: return "历史原文"
        case .report: return "报告"
        case .json: return "原始记录"
        }
    }
}

struct ArenaSeatTarget: Identifiable {
    let id: String
}

struct ArenaDetailRequest: Identifiable {
    let id = UUID()
    let provider: String?
    let tab: ArenaInspectorTab
}

struct ArenaDetailsSheet: View {
    @ObservedObject var model: ArenaModel
    let request: ArenaDetailRequest

    @Environment(\.dismiss) private var dismiss
    @State private var tab: ArenaInspectorTab
    @State private var promptProvider: String

    init(model: ArenaModel, request: ArenaDetailRequest) {
        self.model = model
        self.request = request
        let participants = ArenaSessionDigest.participants(model.session)
        let fallback = request.provider
            ?? participants.first
            ?? ArenaSeatCatalog.ordered.first
            ?? "chatgpt"
        _tab = State(initialValue: request.tab)
        _promptProvider = State(initialValue: fallback)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("本场详情")
                    .font(.system(size: 15, weight: .semibold))
                Picker("", selection: $tab) {
                    ForEach(ArenaInspectorTab.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 360)
                .onChange(of: tab) { newValue in
                    if newValue == .prompts { normalizePromptProvider() }
                }
                Spacer()
                Button("导出 Markdown") { ArenaExporter.export(model: model) }
                    .controlSize(.regular)
                    .disabled(model.session == nil)
                Button("关闭") { dismiss() }
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            Group {
                switch tab {
                case .prompts: promptsView
                case .answers: answersView
                case .report: reportView
                case .json: jsonView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    // MARK: 当前提示

    private var providerChoices: [String] {
        let participants = ArenaSessionDigest.participants(model.session)
        if !participants.isEmpty { return participants }
        return ArenaSeatCatalog.ordered.filter { model.panes[$0] != nil }
    }

    private var promptsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if providerChoices.count > 1 {
                    Picker("", selection: $promptProvider) {
                        ForEach(providerChoices, id: \.self) { provider in
                            Text(ArenaSeatCatalog.name(provider)).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
                Spacer()
                Button("复制提示") {
                    if let text = currentPromptText {
                        arenaCopyToPasteboard(text)
                    }
                }
                .controlSize(.regular)
                .disabled(currentPromptText == nil)
            }

            if let task = ArenaSessionDigest.currentTask(model.session, provider: promptProvider) {
                Text("本席这一轮 · \(ArenaStageNames.label(task.stage)) · 第 \(task.round) 轮"
                    + (task.sourceId.isEmpty ? "" : " · \(task.sourceId)"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("本席当前没有进行中的提示；下面显示最近一次记录。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(currentPromptText ?? "暂无提示记录")
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.045))
                    )
            }
        }
        .padding(12)
        .onAppear(perform: normalizePromptProvider)
    }

    private var currentPromptText: String? {
        ArenaSessionDigest.promptText(model.session, provider: promptProvider)
    }

    private func normalizePromptProvider() {
        guard !providerChoices.contains(promptProvider) else { return }
        if let first = providerChoices.first { promptProvider = first }
    }

    // MARK: 历史原文

    @ViewBuilder
    private var answersView: some View {
        let rows = ArenaSessionDigest.answerRows(model.session)
        if rows.isEmpty {
            emptyState("还没有已保存的原文。")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        ArenaAnswerDisclosure(row: row)
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: 报告

    private var reportView: some View {
        let report = ArenaSessionDigest.report(model.session)
        return Group {
            if let report {
                VStack(spacing: 0) {
                    HStack {
                        if let reason = ArenaSessionDigest.stopReason(model.session) {
                            Text("停止原因：\(reason)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("复制报告") { arenaCopyToPasteboard(report) }
                            .controlSize(.regular)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    ScrollView {
                        Text(report)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            } else {
                emptyState(
                    ArenaSessionDigest.stopReason(model.session)
                        .map { "尚未生成报告。停止原因：\($0)" }
                        ?? "尚未生成报告。"
                )
            }
        }
    }

    // MARK: 原始记录

    private var jsonView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会话原始数据（只读）")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制 JSON") {
                    arenaCopyToPasteboard(ArenaJSON.string(model.session))
                }
                .controlSize(.regular)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ScrollView([.horizontal, .vertical]) {
                Text(ArenaJSON.string(model.session))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private func labeled(_ title: String, text: String, dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "（空）" : text)
                .font(.system(size: 13))
                .foregroundStyle(dim ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ArenaAnswerDisclosure: View {
    let row: ArenaTaskRow

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                labeled("提示", text: row.prompt, dim: true)
                labeled("原文", text: row.answer ?? "", dim: false)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("第 \(row.round) 轮 · \(ArenaStageNames.label(row.stage))")
                    .font(.system(size: 12.5, weight: .medium))
                Text(ArenaSeatCatalog.name(row.provider))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !row.sourceId.isEmpty {
                    Text(row.sourceId)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("复制原文") {
                    if let text = row.answer { arenaCopyToPasteboard(text) }
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
        }
    }

    private func labeled(_ title: String, text: String, dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "（空）" : text)
                .font(.system(size: 13))
                .foregroundStyle(dim ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Markdown 导出

enum ArenaExporter {

    @MainActor
    static func export(model: ArenaModel) {
        guard model.session != nil else {
            model.errorMessage = "还没有可导出的场次"
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
            model.errorMessage = "导出失败：\(error.localizedDescription)"
        }
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
        lines.append("- 导出时间：\(ISO8601DateFormatter().string(from: Date()))")
        lines.append("- 阶段：\(ArenaStageNames.label((session?["stage"] as? String) ?? ""))")
        if let round = ArenaValue.int(session?["round"]) {
            lines.append("- 轮次：第 \(round) 轮")
        }
        if let paused = session?["paused"] as? Bool, paused {
            lines.append("- 暂停：是")
        }
        if let id = ArenaSessionDigest.id(session), !id.isEmpty {
            lines.append("- 记录编号：\(id)")
        }
        lines.append("")
        lines.append("## 题面")
        lines.append("")
        lines.append((session?["question"] as? String) ?? model.question)
        lines.append("")
        lines.append("## 参与者与状态")
        lines.append("")
        lines.append("| 席位 | 站点 | 状态 |")
        lines.append("| --- | --- | --- |")
        for provider in providers {
            let status = model.statuses[provider]?.trimmedNonEmpty ?? "—"
            lines.append("| `\(provider)` | \(ArenaSeatCatalog.name(provider)) | \(status) |")
        }
        lines.append("")

        lines.append("## 当前提示")
        lines.append("")
        for provider in providers {
            let task = ArenaSessionDigest.currentTask(session, provider: provider)
            lines.append("### \(ArenaSeatCatalog.name(provider))")
            lines.append("")
            if let task {
                lines.append("阶段：\(ArenaStageNames.label(task.stage)) · 第 \(task.round) 轮"
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
                lines.append("### 第 \(row.round) 轮 · \(ArenaStageNames.label(row.stage)) · \(ArenaSeatCatalog.name(row.provider))\(source)")
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

fileprivate func arenaCopyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
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
            // Prove the ordinary relaunch path stays conservative: wait long
            // enough for a stray dispatch to show, then report without sending.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let payload: [String: Any] = [
                "ok": true,
                "reason": "restart-conservative",
                "didContinue": model.didContinueSavedDiscussion,
                "statuses": model.statuses,
                "stage": model.session?.arenaString("stage") ?? "",
                "session": model.session ?? [:],
            ]
            Self.write(payload, to: resultPath)
            Self.writeStderr("[smoke] ordinary restart checked; no dispatch expected")
            exit(0)
        }
        if CommandLine.arguments.contains("--smoke-prepare-recovery") {
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

        let question = "【冒烟测试】如果只有两个周末，个人笔记工具应先做移动端采集，还是先补桌面检索？请给出判断和一个可验证的理由。"
        model.question = question
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

    /// First half of the isolated continuation check: start a normal
    /// discussion on the fixture pages and stop as soon as two first-round
    /// answers are recorded and the third seat is stuck before send with a
    /// durable `.prepared` intent. Nothing is forced into the session.
    @MainActor
    private func runPrepareRecovery(model: ArenaModel, resultPath: String, timeout: Double) async {
        let question = "【恢复验收】如果只有两个周末，个人笔记工具应先做移动端采集，还是先补桌面检索？请给出判断和一个可验证的理由。"
        model.question = question
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
