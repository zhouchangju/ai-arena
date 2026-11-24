//
//  qa_ui_driver.swift
//  AI Arena · 隔离 UI 性能与交互验收驱动（仅 QA 构建）
//
//  目标：G1/G2/G3/G4。本文件只在 tests/qa_ui_acceptance.py 的临时源码副本里
//  编译（生产 ArenaApp.swift 的 @main 在副本中被移除），不进入正式应用。
//  驱动在同一进程内建立真实 NSWindow + ArenaRootView，通过
//  AXUIElementCreateApplication(getpid()) 读取本进程的 NSAccessibility 树，
//  用 AXPress 驱动原生控件，用真实 NSTextView 输入，用 cacheDisplay 截图。
//  不调用外部 AX、不请求屏幕录制、不激活到前台、不读取正式账号或偏好。
//
//  步骤由 ARENA_QA_UI_STEPS 指向的 JSON 数组给出；结果写到
//  ARENA_QA_UI_RESULT，截图写到 ARENA_QA_UI_OUT。
//
//  性能口径：CVDisplayLink 的主线程回调间隔（含主线程延迟），以及主
//  runloop 每轮忙碌时长。没有屏幕录制时拿不到真实显示帧，因此不声称帧率；
//  报告样本数、p50/p95/max、超过 1 帧/2 帧预算的次数。
//

import AppKit
import SwiftUI
import ApplicationServices
import CoreVideo
import QuartzCore
import ObjectiveC
import Security

// MARK: - 环境与错误

struct QAFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func qaTrimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else { return nil }
    return value
}

func qaNow() -> Double { CACurrentMediaTime() }

func qaPercentile(_ values: [Double], _ percentile: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = Int((Double(sorted.count) * percentile).rounded(.up)) - 1
    return sorted[min(max(rank, 0), sorted.count - 1)]
}

func qaStat(_ values: [Double]) -> [String: Any] {
    guard !values.isEmpty else {
        return ["count": 0, "p50": 0.0, "p95": 0.0, "max": 0.0, "mean": 0.0]
    }
    let mean = values.reduce(0, +) / Double(values.count)
    return [
        "count": values.count,
        "p50": qaPercentile(values, 0.50),
        "p95": qaPercentile(values, 0.95),
        "max": values.max() ?? 0,
        "mean": mean,
    ]
}

// MARK: - 主窗口 reduce motion 注入

/// 报告窗口由生产代码自行创建，无法从外部注入环境。为覆盖报告里的
/// Reduce Motion 分支，仅在本进程内替换 NSWorkspace 的只读 getter。
/// 不改文件、不写偏好、不影响其他进程；安装失败会在结果中明确标注。
enum QAWorkspaceMotion {
    static var override: Bool?
    private(set) static var installed = false
    /// 安装替换前读到的系统真实值，避免结果里只剩被覆盖后的 false。
    static let systemValueAtLaunch = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    static func install() {
        guard !installed else { return }
        let selector = NSSelectorFromString("accessibilityDisplayShouldReduceMotion")
        guard let method = class_getInstanceMethod(NSWorkspace.self, selector) else { return }
        let block: @convention(block) (AnyObject) -> Bool = { _ in override ?? false }
        method_setImplementation(method, imp_implementationWithBlock(block))
        installed = true
    }
}

// MARK: - 主 runloop 与 display link 采样

/// 只由主线程调用；观察器回调本身也运行在主 runloop。
final class QARunLoopProbe {
    private var busy: [Double] = []
    private var busyStart: Double?
    private var observers: [CFRunLoopObserver] = []

    func start() {
        busy.removeAll()
        busyStart = nil
        let runLoop = CFRunLoopGetMain()
        func add(_ activity: CFOptionFlags) {
            let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, activity, true, 0
            ) { [weak self] _, _ in
                guard let self else { return }
                let now = qaNow()
                if activity == CFRunLoopActivity.afterWaiting.rawValue {
                    if self.busyStart == nil { self.busyStart = now }
                } else if activity == CFRunLoopActivity.beforeWaiting.rawValue {
                    if let start = self.busyStart {
                        self.busy.append((now - start) * 1000)
                        self.busyStart = nil
                    }
                } else if activity == CFRunLoopActivity.beforeSources.rawValue,
                          self.busyStart == nil {
                    self.busyStart = now
                }
            }
            if let observer {
                CFRunLoopAddObserver(runLoop, observer, .commonModes)
                observers.append(observer)
            }
        }
        add(CFRunLoopActivity.afterWaiting.rawValue)
        add(CFRunLoopActivity.beforeWaiting.rawValue)
        add(CFRunLoopActivity.beforeSources.rawValue)
    }

    func stop() -> [Double] {
        for observer in observers {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observers.removeAll()
        return busy
    }
}

/// CVDisplayLink 提供本机真实刷新节拍；回调里把一次采样送到主线程，主线程
/// 到达时间与回调时间的差即主线程停滞的代理指标。回调本身不读屏幕。
/// 采样在 CV 线程产生、只在主线程消费；运行标志只做粗粒度开关。
final class QADisplayLinkProbe {
    private var link: CVDisplayLink?
    private(set) var ticks: [Double] = []
    private(set) var latencies: [Double] = []
    private var running = false

    func start() -> Bool {
        ticks.removeAll()
        latencies.removeAll()
        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess,
              let created else { return false }
        link = created
        CVDisplayLinkSetOutputHandler(created) { [weak self] _, _, _, _, _ in
            let callback = qaNow()
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                let arrival = qaNow()
                self.latencies.append((arrival - callback) * 1000)
                self.ticks.append(arrival)
            }
            return kCVReturnSuccess
        }
        running = true
        return CVDisplayLinkStart(created) == kCVReturnSuccess
    }

    func stop() {
        running = false
        if let link { CVDisplayLinkStop(link) }
        link = nil
        // 让已排到主队列的采样收口。
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    var intervals: [Double] {
        guard ticks.count > 1 else { return [] }
        return zip(ticks.dropFirst(), ticks).map { ($0 - $1) * 1000 }
    }
}

// MARK: - 启动前 fail-closed 检查

/// 新的 @main 不会经过生产 ArenaApp 的 SmokeRunner.preflight，因此必须在
/// 创建 NSApplication、ArenaModel 或任何 WKWebView 之前完成同样的边界检查：
/// 只允许 QA 包身份、独立数据目录、回环夹具，并关闭钥匙串交互。
/// 任一项不满足立即退出，绝不打开个人包、个人历史或真实站点。
enum QAUIStartup {
    static func preflight() {
        let environment = ProcessInfo.processInfo.environment
        func fail(_ reason: String) -> Never {
            FileHandle.standardError.write(Data("[qa-ui] preflight: \(reason)\n".utf8))
            exit(2)
        }
        guard Bundle.main.bundleIdentifier == ArenaBuildIsolation.qaBundleIdentifier else {
            fail("bundle 必须是 \(ArenaBuildIsolation.qaBundleIdentifier)，实际 \(Bundle.main.bundleIdentifier ?? "nil")")
        }
        guard let dataDir = qaTrimmed(environment["ARENA_DATA_DIR"]) else {
            fail("ARENA_DATA_DIR is required")
        }
        guard FileManager.default.fileExists(atPath: dataDir) else {
            fail("ARENA_DATA_DIR 不存在：\(dataDir)")
        }
        guard let rawBase = qaTrimmed(environment["ARENA_FIXTURE_BASE"]),
              let url = URL(string: rawBase),
              url.scheme?.lowercased() == "http",
              url.host == "127.0.0.1" else {
            fail("ARENA_FIXTURE_BASE 必须是 http://127.0.0.1[:端口] 回环地址")
        }
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            fail("无法关闭钥匙串交互")
        }
    }
}

// MARK: - 驱动

@MainActor
final class QAUIDriver {
    private let outDir: URL
    private let resultPath: URL
    private let steps: [[String: Any]]
    private let model: ArenaModel
    private var window: NSWindow!
    private var records: [[String: Any]] = []
    private var captures: [[String: Any]] = []
    private var metrics: [[String: Any]] = []
    private var notes: [String] = []
    private let startedAt = ISO8601DateFormatter().string(from: Date())
    private let clock = qaNow()
    private var didFinish = false

    init(outDir: URL, resultPath: URL, steps: [[String: Any]]) {
        self.outDir = outDir
        self.resultPath = resultPath
        self.steps = steps
        self.model = ArenaModel(continueSessionID: nil)
    }

    // MARK: 启动

    static func launch() {
        let environment = ProcessInfo.processInfo.environment
        guard let out = qaTrimmed(environment["ARENA_QA_UI_OUT"]),
              let result = qaTrimmed(environment["ARENA_QA_UI_RESULT"]),
              let stepsPath = qaTrimmed(environment["ARENA_QA_UI_STEPS"]) else {
            FileHandle.standardError.write(Data("[qa-ui] ARENA_QA_UI_OUT/RESULT/STEPS are required\n".utf8))
            exit(2)
        }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: stepsPath)) }
        catch {
            FileHandle.standardError.write(Data("[qa-ui] cannot read steps: \(error)\n".utf8))
            exit(2)
        }
        guard let steps = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            FileHandle.standardError.write(Data("[qa-ui] steps must be a JSON array of objects\n".utf8))
            exit(2)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let driver = QAUIDriver(
            outDir: URL(fileURLWithPath: out),
            resultPath: URL(fileURLWithPath: result),
            steps: steps
        )
        driver.installWindow()

        Task { @MainActor in
            await driver.run()
        }
    }

    private func installWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Arena"
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.contentView = NSHostingView(rootView: ArenaRootView(model: model))
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        self.window = window
        // 现有 QA 入口同样只把窗口排到后面：不激活、不抢焦点。
        window.orderBack(nil)
    }

    // MARK: 结果

    private func writeResult(ok: Bool, fatal: String? = nil) {
        var payload: [String: Any] = [
            "ok": ok,
            "startedAt": startedAt,
            "finishedAt": ISO8601DateFormatter().string(from: Date()),
            "durationMs": (qaNow() - clock) * 1000,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "executable": Bundle.main.executablePath ?? "",
            "fixtureBase": ProcessInfo.processInfo.environment["ARENA_FIXTURE_BASE"] ?? "",
            "steps": records,
            "captures": captures,
            "metrics": metrics,
            "notes": notes,
            "session": [
                "id": model.session?.arenaString("id") ?? "",
                "stage": model.stageKey,
                "readOnly": model.isReadOnly,
                "question": model.question,
            ],
            "workspaceReduceMotionOverride": [
                "installed": QAWorkspaceMotion.installed,
                "value": QAWorkspaceMotion.override.map { String($0) } ?? "nil",
                "systemAtLaunch": QAWorkspaceMotion.systemValueAtLaunch,
                "systemRead": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            ],
        ]
        if let fatal { payload["fatal"] = fatal }
        do {
            try FileManager.default.createDirectory(
                at: resultPath.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: resultPath, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[qa-ui] failed to write result: \(error)\n".utf8))
        }
    }

    private func finish(ok: Bool, fatal: String? = nil) {
        guard !didFinish else { return }
        didFinish = true
        writeResult(ok: ok, fatal: fatal)
        if let fatal {
            FileHandle.standardError.write(Data("[qa-ui] FAIL: \(fatal)\n".utf8))
        } else {
            FileHandle.standardError.write(Data("[qa-ui] PASS\n".utf8))
        }
        exit(ok ? 0 : 1)
    }

    // MARK: 运行

    private func run() async {
        await settle(0.8)
        for (index, step) in steps.enumerated() {
            let op = (step["op"] as? String) ?? "unknown"
            let name = (step["name"] as? String) ?? op
            let start = qaNow()
            var record: [String: Any] = [
                "index": index,
                "op": op,
                "name": name,
            ]
            do {
                let detail = try await perform(step: step, index: index)
                record["ok"] = true
                if !detail.isEmpty { record["detail"] = detail }
            } catch {
                record["ok"] = false
                record["error"] = String(describing: error)
                record["durationMs"] = (qaNow() - start) * 1000
                records.append(record)
                writeResult(ok: false, fatal: "step \(index) \(op) \(name): \(error)")
                finish(ok: false, fatal: "step \(index) \(op) \(name): \(error)")
                return
            }
            record["durationMs"] = (qaNow() - start) * 1000
            records.append(record)
            writeResult(ok: true)
        }
        finish(ok: true)
    }

    private func perform(step: [String: Any], index: Int) async throws -> [String: Any] {
        switch (step["op"] as? String) ?? "" {
        case "sleep":
            try await settle(step["seconds"] as? Double ?? 1)
            return [:]

        case "waitSeats":
            return try await waitSeats(timeout: step["timeout"] as? Double ?? 45)

        case "waitStage":
            guard let stage = step["stage"] as? String else { throw QAFailure("waitStage 缺 stage") }
            return try await waitStage(stage, timeout: step["timeout"] as? Double ?? 120)

        case "waitWindow":
            guard let title = step["title"] as? String else { throw QAFailure("waitWindow 缺 title") }
            let detail = try await waitWindow(title, timeout: step["timeout"] as? Double ?? 15)
            try await settle(0.5)
            return detail

        case "waitText":
            guard let text = step["text"] as? String else { throw QAFailure("waitText 缺 text") }
            return try await waitText(text, window: step["window"] as? String ?? "main",
                                      timeout: step["timeout"] as? Double ?? 20)

        case "type":
            guard let text = step["text"] as? String else { throw QAFailure("type 缺 text") }
            return try await type(text, expect: step["expect"] as? String)

        case "click":
            return try await click(step: step, index: index)

        case "inspect":
            return try inspect(step: step, index: index)

        case "capture":
            return try capture(step: step, index: index)

        case "resize":
            return try resize(step: step)

        case "appearance":
            return try appearance(step: step)

        case "reduceMotion":
            return try reduceMotion(step: step)

        case "perf":
            return try await perf(step: step, index: index)

        case "openHistory":
            return try await openHistory(step: step)

        case "assertModel":
            return try assertModel(step: step)

        case "note":
            guard let text = step["text"] as? String else { throw QAFailure("note 缺 text") }
            notes.append(text)
            return ["note": text]

        default:
            throw QAFailure("未知步骤 \(step["op"] ?? "")")
        }
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    // MARK: 等待

    private func waitSeats(timeout: Double) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        let providers = ["chatgpt", "gemini", "deepseek"]
        while Date() < deadline {
            if providers.allSatisfy({ model.panes[$0]?.documentReady == true }) {
                return ["ready": providers]
            }
            try await settle(0.2)
        }
        let pending = providers.filter { model.panes[$0]?.documentReady != true }
        throw QAFailure("三席未就绪：\(pending.joined(separator: ", "))")
    }

    private func waitStage(_ stage: String, timeout: Double) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.stageKey == stage { return ["stage": model.stageKey] }
            try await settle(0.15)
        }
        throw QAFailure("等待 stage=\(stage) 超时，当前 \(model.stageKey)，错误：\(model.errorMessage)")
    }

    private func waitWindow(_ title: String, timeout: Double) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) {
                return ["window": title, "frame": NSStringFromRect(window.frame)]
            }
            try await settle(0.15)
        }
        throw QAFailure("窗口「\(title)」未出现，现有：\(NSApp.windows.map(\.title))")
    }

    private func waitText(_ text: String, window key: String, timeout: Double) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let root = try? axWindow(key), axFind(root, { axText($0).contains(text) }) != nil {
                return ["found": text]
            }
            try await settle(0.2)
        }
        throw QAFailure("AX 树中未找到文本「\(text)」")
    }

    // MARK: 类型化输入

    private func type(_ text: String, expect: String?) async throws -> [String: Any] {
        guard let content = window.contentView,
              let editor = findComposerTextView(content) else {
            throw QAFailure("未找到提问区 NSTextView")
        }
        let full = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.setSelectedRange(full)
        editor.insertText(text, replacementRange: full)
        try await settle(0.4)
        let expected = expect ?? text
        guard model.question == expected else {
            throw QAFailure("NSTextView 输入未同步到 model.question（得到 \(model.question.prefix(40))）")
        }
        return ["textView": String(describing: Swift.type(of: editor)),
                "questionLength": model.question.count]
    }

    private func findComposerTextView(_ view: NSView) -> NSTextView? {
        if let scroll = view as? NSScrollView, let text = scroll.documentView as? NSTextView,
           text.accessibilityLabel() == "讨论问题" {
            return text
        }
        for child in view.subviews {
            if let found = findComposerTextView(child) { return found }
        }
        return nil
    }

    // MARK: AX 快照与点击

    /// 先定位真实 NSWindow，再把本进程 AXWindow 与它对齐。
    /// 详情窗口的 AXTitle 会合并动态 subtitle，因此不能用精确标题硬匹配；
    /// 顺序为 exact → 唯一前缀 → 唯一 frame（含前缀）→ 唯一窗口。
    /// 找不到就抛出带两侧窗口诊断的错误，绝不回退到主窗。
    /// 把步骤里的窗口 key 解析成真实 NSWindow。sheet 只按 attachedSheet 引用取，
    /// 不当成同名窗口、也不回退主窗；对不上就抛错。
    private func nsWindow(for key: String) throws -> NSWindow {
        switch key {
        case "main":
            return window
        case "details":
            guard let found = NSApp.windows.first(where: { $0.title == "本场详情" }), found.isVisible else {
                throw QAFailure("详情 NSWindow 不存在或不可见。\(axWindowDiagnostics())")
            }
            return found
        case "sheet":
            guard let sheet = window.attachedSheet, sheet.isVisible else {
                throw QAFailure("主窗没有可见 attachedSheet。\(axWindowDiagnostics())")
            }
            return sheet
        default:
            guard let found = NSApp.windows.first(where: { $0.title == key }), found.isVisible else {
                throw QAFailure("NSWindow「\(key)」不存在或不可见。\(axWindowDiagnostics())")
            }
            return found
        }
    }

    private func axWindow(_ key: String) throws -> AXUIElement {
        // sheet 是主窗 attachedSheet，按引用解析，绝不当成「同名窗口」再回退主窗。
        if key == "sheet" { return try axSheet() }
        let ns = try nsWindow(for: key)

        let candidates = axWindowCandidates()
        let title = ns.title.trimmingCharacters(in: .whitespacesAndNewlines)

        let exact = candidates.filter { !title.isEmpty && $0.title == title }
        if exact.count == 1 { return exact[0].element }

        let expectedFrame = expectedAXFrame(for: ns)
        if let expectedFrame {
            let byFrame = candidates.filter { candidate in
                guard let frame = candidate.frame else { return false }
                return axSameFrame(frame, expectedFrame)
            }
            if byFrame.count == 1 { return byFrame[0].element }
            let framedPrefix = byFrame.filter { !title.isEmpty && $0.title.hasPrefix(title) }
            if framedPrefix.count == 1 { return framedPrefix[0].element }
        }

        let prefix = candidates.filter { !title.isEmpty && $0.title.hasPrefix(title) }
        if prefix.count == 1 { return prefix[0].element }

        if candidates.count == 1 { return candidates[0].element }

        throw QAFailure(
            "无法把 NSWindow「\(title)」对齐到 AXWindow（候选 \(candidates.count) 个）。"
            + axWindowDiagnostics()
        )
    }

    /// 主窗 attachedSheet 的 AX 对端与来源。sheet 在 AX 里通常挂在主窗子树下，
    /// 角色为 AXSheet；少数情况会作为独立轴窗口出现。只接受同树唯一 AXSheet
    /// 或按标题/位置唯一匹配的窗口；对不上时 element 为 nil，并说明是哪一步空的。
    private func axSheetMatch() -> (element: AXUIElement?, source: String, detail: String) {
        guard let sheet = window.attachedSheet, sheet.isVisible else {
            return (nil, "no-attached-sheet", axWindowDiagnostics())
        }
        let title = sheet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedFrame = expectedAXFrame(for: sheet)

        guard let mainRoot = try? axWindow("main") else {
            return (nil, "no-main-ax-window", axSheetDiagnostics([], sheet: sheet))
        }
        // 先在同一棵主窗 AX 树里确认，这是「同树可确认」的唯一来源。
        let inTree = axFindAll(mainRoot, { axString($0, kAXRoleAttribute) == "AXSheet" },
                               maxNodes: 2000, limitMs: 2000)
        if inTree.count == 1 { return (inTree[0], "ax-tree", "") }
        if inTree.count > 1 {
            let detail = axSheetDiagnostics(inTree, sheet: sheet)
            if let unique = axNarrowToUnique(inTree, title: title, frame: expectedFrame) {
                return (unique, "ax-tree-narrowed", detail)
            }
            return (nil, "ambiguous-ax-tree", detail)
        }

        // 树里没有时只认按标题或位置唯一正确的轴窗口。
        let candidates = axWindowCandidates()
        let detail = axSheetDiagnostics(inTree, sheet: sheet)
        let byTitle = candidates.filter { !title.isEmpty && $0.title == title }
        if byTitle.count == 1 { return (byTitle[0].element, "ax-window-title", detail) }
        if let expectedFrame {
            let byFrame = candidates.filter { candidate in
                guard let frame = candidate.frame else { return false }
                return axSameFrame(frame, expectedFrame)
            }
            if byFrame.count == 1 { return (byFrame[0].element, "ax-window-frame", detail) }
        }
        return (nil, "missing", detail)
    }

    /// 主窗 attachedSheet 的 AX 对端。AX 对不上时先把能取到的真实画面存成截图，
    /// 再带着来源报错；不改模型、不伪造点击、不回退主窗。
    private func axSheet() throws -> AXUIElement {
        let match = axSheetMatch()
        if let element = match.element { return element }
        let shot = bestEffortCapture(key: "sheet", name: "sheet-ax-missing")
        throw QAFailure(
            "attachedSheet 无法 AX 对齐（\(match.source)）"
            + (shot.map { "，已先截图 \($0)" } ?? "，截图也失败")
            + "。不改模型伪造点击。" + match.detail
        )
    }

    /// 只截图、不抛错：用于 AX 无法操作但仍能取到真实画面的分支。
    private func bestEffortCapture(key: String, name: String) -> String? {
        guard let entry = try? capture(step: ["op": "capture", "name": name, "window": key],
                                       index: 990 + captures.count) else { return nil }
        return entry["file"] as? String
    }

    /// 多个候选时只按标题/位置缩到唯一一个；缩不到唯一就返回 nil，由调用方报错。
    private func axNarrowToUnique(_ elements: [AXUIElement], title: String, frame: CGRect?) -> AXUIElement? {
        if !title.isEmpty {
            let byTitle = elements.filter {
                axString($0, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines) == title
            }
            if byTitle.count == 1 { return byTitle[0] }
        }
        if let frame {
            let byFrame = elements.filter { candidate in
                guard let candidateFrame = axFrame(candidate) else { return false }
                return axSameFrame(candidateFrame, frame)
            }
            if byFrame.count == 1 { return byFrame[0] }
        }
        return nil
    }

    private func axSameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 2
            && abs(lhs.origin.y - rhs.origin.y) < 2
            && abs(lhs.width - rhs.width) < 2
            && abs(lhs.height - rhs.height) < 2
    }

    private func axSheetDiagnostics(_ elements: [AXUIElement], sheet: NSWindow) -> String {
        var parts: [String] = []
        for (offset, element) in elements.enumerated() {
            let title = axString(element, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
            let frame = axFrame(element).map { NSStringFromRect($0) } ?? "no-frame"
            parts.append("sheet#\(offset)「\(title)」\(frame)")
        }
        let expected = expectedAXFrame(for: sheet).map { NSStringFromRect($0) } ?? "no-screen"
        return "\nAX sheets: \(parts.isEmpty ? "none" : parts.joined(separator: " | "))"
            + "\nNS attachedSheet「\(sheet.title)」frame=\(NSStringFromRect(sheet.frame)) expectedAX=\(expected)"
    }

    private struct AXWindowCandidate {
        let element: AXUIElement
        let title: String
        let frame: CGRect?
    }

    private func axWindowCandidates() -> [AXWindowCandidate] {
        let app = AXUIElementCreateApplication(getpid())
        let windows = (axValue(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return windows.compactMap { element in
            let title = axString(element, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = axString(element, kAXDescriptionAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = title.isEmpty ? fallback : title
            guard !resolved.isEmpty else { return nil }
            return AXWindowCandidate(element: element, title: resolved, frame: axFrame(element))
        }
    }

    /// NSWindow.frame 以主屏左下为原点；AXPosition 以主屏左上为原点。
    private func expectedAXFrame(for ns: NSWindow) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let frame = ns.frame
        return CGRect(
            x: frame.origin.x,
            y: primary.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func axWindowDiagnostics() -> String {
        let ax = axWindowCandidates().map { candidate in
            "「\(candidate.title)」"
                + (candidate.frame.map { NSStringFromRect($0) } ?? "no-frame")
        }.joined(separator: " | ")
        let ns = NSApp.windows.map { win in
            "「\(win.title)」sub=「\(win.subtitle)」visible=\(win.isVisible)"
                + "frame=\(NSStringFromRect(win.frame))"
        }.joined(separator: " | ")
        return "\nAX windows: \(ax.isEmpty ? "none" : ax)\nNS windows: \(ns.isEmpty ? "none" : ns)"
    }

    private func click(step: [String: Any], index: Int) async throws -> [String: Any] {
        let key = step["window"] as? String ?? "main"
        let root = try axWindow(key)
        let label = (step["label"] as? String) ?? (step["labelContains"] as? String) ?? ""
        guard !label.isEmpty else { throw QAFailure("click 缺 label") }
        let exact = (step["exact"] as? Bool) ?? ((step["labelContains"] as? String) == nil)
        let verifyChange = (step["requireChange"] as? Bool) == true
            || (step["observeChange"] as? Bool) == true

        let before = verifyChange ? axFingerprint(root, maxParts: 120, limitMs: 400) : nil
        let findStart = qaNow()
        // 第一个同时满足文本匹配与 AXPress 的控件即返回：不继续扫描
        // WebKit 席位内容，避免把一次点击拖到秒级。
        let target = axFind(root, maxNodes: 1200, limitMs: 1200) { element in
            guard axEnabled(element) else { return false }
            let text = axText(element)
            let matched: Bool
            if exact {
                // SwiftUI 常把 .help 并进 description/title，形成
                // 「开始讨论 向所选席位发送…」；按字段或首段匹配，避免漏点。
                matched = axFields(element).contains(label)
                    || text == label
                    || text.hasPrefix(label + " ")
            } else {
                matched = text.contains(label)
            }
            guard matched else { return false }
            return axActions(element).contains(kAXPressAction as String)
        }
        let findMs = (qaNow() - findStart) * 1000
        guard let target else {
            throw QAFailure("AX 中未找到可点击「\(label)」（窗口 \(key)，扫描 \(Int(findMs))ms）")
        }
        let role = axString(target, kAXRoleAttribute)
        let actions = axActions(target)
        let frame = axFrame(target).map(NSStringFromRect) ?? ""
        var result: [String: Any] = [
            "label": label,
            "role": role,
            "actions": actions,
            "frame": frame,
            "timingsMs": ["find": findMs],
        ]
        guard actions.contains(kAXPressAction as String) else {
            throw QAFailure("「\(label)」不支持 AXPress，动作：\(actions)")
        }
        let pressStart = qaNow()
        let error = AXUIElementPerformAction(target, kAXPressAction as CFString)
        let pressMs = (qaNow() - pressStart) * 1000
        result["axResult"] = Int(error.rawValue)
        result["timingsMs"] = ["find": findMs, "press": pressMs]
        try await settle(step["settle"] as? Double ?? 0.55)
        if let expected = step["expectValue"] as? String {
            guard let refreshed = axFind(root, { element in
                axFields(element).contains(label) || axText(element).hasPrefix(label)
            }), axString(refreshed, kAXValueAttribute) == expected else {
                throw QAFailure("「\(label)」点击后 AX 值不是「\(expected)」")
            }
            result["value"] = expected
        }
        if let expected = step["expectText"] as? String {
            guard axFind(root, { axText($0).contains(expected) }) != nil else {
                throw QAFailure("点击「\(label)」后未出现文本「\(expected)」")
            }
            result["text"] = expected
        }
        if verifyChange, let before {
            let after = axFingerprint(root, maxParts: 120, limitMs: 400)
            result["fingerprintTruncated"] = before.truncated || after.truncated
            result["observedChange"] = before.signature != after.signature
            if !before.truncated, !after.truncated, before.signature == after.signature {
                throw QAFailure("点击「\(label)」没有观察到界面变化")
            }
        }
        return result
    }

    private func inspect(step: [String: Any], index: Int) throws -> [String: Any] {
        let key = step["window"] as? String ?? "main"
        let root = try axWindow(key)
        let name = (step["name"] as? String) ?? "inspect"
        var nodes: [[String: Any]] = []
        var visits = 0
        let deadline = qaNow() + 2.0
        func walk(_ element: AXUIElement, depth: Int, path: String) {
            guard depth <= 14, visits < 700, qaNow() < deadline else { return }
            visits += 1
            let role = axString(element, kAXRoleAttribute)
            if role.isEmpty { return }
            var node: [String: Any] = [
                "role": role,
                "text": axText(element),
                "value": axString(element, kAXValueAttribute),
                "enabled": axEnabled(element),
                "frame": axFrame(element).map { [ $0.origin.x, $0.origin.y, $0.size.width, $0.size.height ] } ?? [],
                "depth": depth,
                "path": path,
            ]
            let actions = axActions(element)
            if !actions.isEmpty { node["actions"] = actions }
            if role == "AXWebArea" {
                node["childrenOmitted"] = true
                nodes.append(node)
                return
            }
            nodes.append(node)
            let children = axChildren(element)
            for (offset, child) in children.enumerated() {
                walk(child, depth: depth + 1, path: "\(path).\(offset)")
            }
        }
        walk(root, depth: 0, path: "w")
        let file = outDir.appendingPathComponent(String(format: "%02d-%@.ax.json", index, sanitize(name)))
        let payload: [String: Any] = [
            "window": key,
            "nodes": nodes,
            "nodeCount": nodes.count,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return ["file": file.lastPathComponent, "nodes": nodes.count]
    }

    // MARK: 截图

    private func capture(step: [String: Any], index: Int) throws -> [String: Any] {
        let title = step["window"] as? String ?? "main"
        let name = (step["name"] as? String) ?? "capture"
        // sheet 只按主窗 attachedSheet 引用取真实窗口，不回退主窗、不按标题猜。
        let target = try nsWindow(for: title)
        guard let content = target.contentView else { throw QAFailure("窗口没有 contentView") }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw QAFailure("无法创建 cacheDisplay 位图")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw QAFailure("无法生成 PNG")
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let file = outDir.appendingPathComponent(String(format: "%02d-%@.png", index, sanitize(name)))
        try png.write(to: file, options: .atomic)
        var entry: [String: Any] = [
            "name": name,
            "file": file.lastPathComponent,
            "window": target.title.isEmpty ? title : target.title,
            "pixels": [bitmap.pixelsWide, bitmap.pixelsHigh],
            "contentPoints": [content.bounds.width, content.bounds.height],
            "bytes": png.count,
        ]
        if title == "sheet" {
            // 截图只依赖真实 NSWindow；AX 是否对得上单独记录，不影响这张图的可信度。
            let match = axSheetMatch()
            entry["attachedSheet"] = true
            entry["axSheet"] = match.element == nil ? "unmatched:\(match.source)" : "matched:\(match.source)"
            if match.element == nil { entry["axSheetDetail"] = match.detail }
        }
        captures.append(entry)
        return entry
    }

    // MARK: 外观、尺寸、reduce motion

    private func resize(step: [String: Any]) throws -> [String: Any] {
        guard let width = step["width"] as? Double, let height = step["height"] as? Double else {
            throw QAFailure("resize 缺 width/height")
        }
        let title = step["window"] as? String ?? "main"
        let target = title == "details"
            ? NSApp.windows.first(where: { $0.title == "本场详情" })
            : window
        guard let target else { throw QAFailure("找不到窗口 \(title)") }
        target.setContentSize(NSSize(width: width, height: height))
        target.contentView?.layoutSubtreeIfNeeded()
        return ["size": NSStringFromSize(target.contentView?.bounds.size ?? .zero),
                "frame": NSStringFromRect(target.frame)]
    }

    private func appearance(step: [String: Any]) throws -> [String: Any] {
        guard let value = step["value"] as? String else { throw QAFailure("appearance 缺 value") }
        let name: NSAppearance.Name
        switch value {
        case "dark": name = .darkAqua
        case "light": name = .aqua
        default: throw QAFailure("appearance 只支持 light/dark")
        }
        // 只改本进程窗口外观；不写系统偏好。
        NSApp.appearance = NSAppearance(named: name)
        for window in NSApp.windows { window.appearance = NSApp.appearance }
        window.contentView?.layoutSubtreeIfNeeded()
        return ["appearance": value,
                "effective": window.effectiveAppearance.name.rawValue]
    }

    private func reduceMotion(step: [String: Any]) throws -> [String: Any] {
        guard let value = step["value"] as? Bool else { throw QAFailure("reduceMotion 缺 value") }
        QAWorkspaceMotion.override = value
        QAWorkspaceMotion.install()
        // SwiftUI 的 accessibilityReduceMotion 只读，来源是 NSWorkspace。
        // 通知让现有窗口重新读取该值；不改系统偏好。
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        window.appearance = NSApp.appearance
        window.contentView?.layoutSubtreeIfNeeded()
        return [
            "requested": value,
            "workspaceGetter": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "intercepted": QAWorkspaceMotion.installed,
            "notification": NSWorkspace.accessibilityDisplayOptionsDidChangeNotification.rawValue,
        ]
    }

    // MARK: 历史回看

    private func openHistory(step: [String: Any]) async throws -> [String: Any] {
        let target: String?
        if let id = step["id"] as? String {
            target = id
        } else {
            target = model.historyList.first(where: { $0.isFinished })?.id
                ?? model.session?.arenaString("id")
                ?? model.historyList.first?.id
        }
        guard let id = target else { throw QAFailure("没有可打开的历史场次") }
        // 菜单里的「只读回看」最终调用同一个模型入口；原生菜单项属于
        // 独立的菜单窗口，进程内 AX 无法稳定枚举，因此这里直接走模型入口，
        // 并在结果中标注为 model-level，而不是假装按到了菜单项。
        model.openHistory(id)
        try await settle(0.8)
        guard model.isReadOnly else { throw QAFailure("历史回看未进入只读状态") }
        return ["id": id, "path": "model-level openHistory（与菜单「只读回看」同一入口）",
                "readOnly": model.isReadOnly]
    }

    private func assertModel(step: [String: Any]) throws -> [String: Any] {
        var observed: [String: Any] = [:]
        if let stage = step["stage"] as? String {
            guard model.stageKey == stage else {
                throw QAFailure("期望 stage=\(stage)，实际 \(model.stageKey)")
            }
            observed["stage"] = model.stageKey
        }
        if let readOnly = step["readOnly"] as? Bool {
            guard model.isReadOnly == readOnly else {
                throw QAFailure("期望 readOnly=\(readOnly)，实际 \(model.isReadOnly)")
            }
            observed["readOnly"] = readOnly
        }
        if let paused = step["paused"] as? Bool {
            guard model.isPaused == paused else {
                throw QAFailure("期望 paused=\(paused)，实际 \(model.isPaused)")
            }
            observed["paused"] = paused
        }
        return observed
    }

    // MARK: 性能

    private func perf(step: [String: Any], index: Int) async throws -> [String: Any] {
        let mode = step["mode"] as? String ?? "scroll"
        let name = (step["name"] as? String) ?? "perf"
        switch mode {
        case "scroll":
            return try await scrollPerf(step: step, name: name)
        case "toggle":
            return try await togglePerf(step: step, name: name)
        default:
            throw QAFailure("perf.mode 只支持 scroll/toggle")
        }
    }

    private func scrollPerf(step: [String: Any], name: String) async throws -> [String: Any] {
        let key = step["window"] as? String ?? "details"
        let target = try nsWindow(for: key)
        guard let content = target.contentView else { throw QAFailure("找不到窗口 \(key)") }
        let duration = (step["durationMs"] as? Double ?? 1800) / 1000
        guard let scroll = largestScrollView(content) else { throw QAFailure("窗口里没有可滚动区域") }
        let clip = scroll.contentView
        let document = scroll.documentView
        let clipHeight = clip.bounds.height
        let documentHeight = document?.frame.height ?? 0
        let maxOffset = max(0, documentHeight - clipHeight)
        guard maxOffset > 8 else {
            throw QAFailure("可滚动高度只有 \(maxOffset)pt，无法做滚动性能采样")
        }
        let distance = min(maxOffset, step["distance"] as? Double ?? maxOffset)
        let startOffset = clip.bounds.origin.y
        let endOffset = min(maxOffset, startOffset + distance)
        guard abs(endOffset - startOffset) > 8 else {
            throw QAFailure("滚动距离过小（\(endOffset - startOffset)pt），不能计入样本")
        }

        let busyProbe = QARunLoopProbe()
        let display = QADisplayLinkProbe()
        var tickWork: [Double] = []
        let displayAvailable = display.start()
        busyProbe.start()

        let scrollStart = qaNow()
        var lastProgress = -1.0
        while true {
            let elapsed = qaNow() - scrollStart
            let progress = min(1, elapsed / duration)
            if progress != lastProgress {
                lastProgress = progress
                let eased = 0.5 - 0.5 * cos(progress * Double.pi)
                let offset = startOffset + (endOffset - startOffset) * eased
                let workStart = qaNow()
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: offset))
                scroll.reflectScrolledClipView(clip)
                content.layoutSubtreeIfNeeded()
                CATransaction.flush()
                tickWork.append((qaNow() - workStart) * 1000)
            }
            try await settle(1.0 / 120.0)
            if progress >= 1 { break }
        }
        try await settle(0.25)
        let finalOffset = clip.bounds.origin.y
        let moved = abs(finalOffset - startOffset)
        guard moved > max(8, abs(endOffset - startOffset) * 0.5) else {
            throw QAFailure("滚动前后 offset 未变化（\(startOffset) → \(finalOffset)），不能计入样本")
        }
        let busy = busyProbe.stop()
        display.stop()

        let refresh = target.screen?.maximumFramesPerSecond ?? 60
        let budget = 1000.0 / Double(refresh)
        let intervals = display.intervals
        let latencies = display.latencies
        let overBudget = intervals.filter { $0 > budget }.count
        let overDouble = intervals.filter { $0 > budget * 2 }.count

        var entry: [String: Any] = [
            "name": name,
            "mode": "scroll",
            "window": target.title,
            "refreshHz": refresh,
            "budgetMs": budget,
            "samples": intervals.count,
            "intervalMs": qaStat(intervals),
            "mainLatencyMs": qaStat(latencies),
            "mainWorkMs": qaStat(busy),
            "scriptedTickWorkMs": qaStat(tickWork),
            "overBudget": overBudget,
            "overDoubleBudget": overDouble,
            "displayLink": displayAvailable ? "CVDisplayLink(active displays)" : "unavailable",
            "scroll": [
                "documentHeight": documentHeight,
                "clipHeight": clipHeight,
                "startOffset": startOffset,
                "endOffset": endOffset,
                "finalOffset": finalOffset,
                "moved": moved,
                "ticks": tickWork.count,
            ],
            "note": "本机 display-link 节拍与主线程工作；未使用屏幕录制，不声称真实显示帧率",
        ]
        if let captureName = step["captureMid"] as? String {
            _ = try? capture(step: ["op": "capture", "name": captureName, "window": key],
                             index: 900 + metrics.count)
        }
        if step["resetScroll"] as? Bool == true {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: startOffset))
            scroll.reflectScrolledClipView(clip)
        }
        metrics.append(entry)
        return entry
    }

    /// 每次展开/收起都必须同时满足：动作真的生效（AXPress 返回成功，或本窗口
    /// 本进程指针 down/up 后状态确实改变）、AX 状态在已展开/已收起之间交替、
    /// 以及该状态下的真实内容与上次同状态完全一致。任一条不满足就中止整场验收，
    /// 绝不把空值或不存在的点击计入样本，也不把失败的动作包装成成功。
    private func togglePerf(step: [String: Any], name: String) async throws -> [String: Any] {
        let key = step["window"] as? String ?? "details"
        let root = try axWindow(key)
        let targetWindow = try nsWindow(for: key)
        let input = ((step["input"] as? String) ?? "axpress").lowercased()
        guard input == "axpress" || input == "pointer" else {
            throw QAFailure("togglePerf.input 只支持 axpress/pointer（得到「\(input)」）")
        }
        guard let label = step["label"] as? String else { throw QAFailure("togglePerf 缺 label") }
        let cycles = step["cycles"] as? Int ?? 3
        let settleMs = step["settleMs"] as? Double ?? 260
        guard cycles > 0 else { throw QAFailure("togglePerf.cycles 必须大于 0") }

        // pointer 模式不要求控件声明 AXPress，否则定位会把可点行漏掉；
        // axpress 模式仍只认支持 AXPress 的控件，和原来的口径一致。
        let requiresPressAction = (input == "axpress")
        func disclosure(_ root: AXUIElement) -> AXUIElement? {
            axFind(root, maxNodes: 1200, limitMs: 1200) { element in
                guard axEnabled(element) else { return false }
                guard axFields(element).contains(label) || axText(element).hasPrefix(label) else {
                    return false
                }
                return requiresPressAction ? axActions(element).contains(kAXPressAction as String) : true
            }
        }
        let allowedStates: Set<String> = ["已展开", "已收起"]

        guard let first = disclosure(root) else { throw QAFailure("找不到折叠标题「\(label)」") }
        let initialValue = axString(first, kAXValueAttribute)
        guard allowedStates.contains(initialValue) else {
            throw QAFailure("折叠标题「\(label)」初始 AX 状态不是已展开/已收起（得到「\(initialValue)」）")
        }
        let initialSignature = axTextSignature(root)
        guard !initialSignature.truncated else {
            throw QAFailure("无法完整读取「\(label)」初始内容（AX 遍历被截断），不能计入性能样本")
        }
        guard !initialSignature.text.isEmpty else {
            throw QAFailure("「\(label)」初始状态没有可核对的内容")
        }
        var signaturesByState: [String: String] = [initialValue: initialSignature.text]
        var currentValue = initialValue

        let busyProbe = QARunLoopProbe()
        busyProbe.start()
        var layoutMs: [Double] = []
        var wallMs: [Double] = []
        var states: [String] = []
        var contentDelta: [Int] = []
        var pressResults: [Int] = []
        var pressMs: [Double] = []
        var pointerSendMs: [Double] = []
        var pointerLatencyMs: [Double] = []
        var pointerPoints: [String] = []
        var pointerFrames: [String] = []
        var pointerHitViews: [String] = []
        var pointerHitChains: [[String]] = []
        var pointerKeyStates: [Bool] = []
        for cycle in 0..<cycles {
            guard let element = disclosure(root) else {
                throw QAFailure("第 \(cycle + 1) 次切换前找不到「\(label)」")
            }
            let beforeValue = axString(element, kAXValueAttribute)
            guard beforeValue == currentValue, allowedStates.contains(beforeValue) else {
                throw QAFailure("第 \(cycle + 1) 次切换前状态漂移：「\(beforeValue)」，期望「\(currentValue)」")
            }
            let beforeSignature = signaturesByState[beforeValue] ?? ""
            guard !beforeSignature.isEmpty else {
                throw QAFailure("第 \(cycle + 1) 次切换前缺少「\(beforeValue)」的内容快照")
            }

            let start = qaNow()
            if input == "pointer" {
                let dispatch = try pointerClick(on: element, in: targetWindow)
                if let before = dispatch.offsetBefore, let after = dispatch.offsetAfter {
                    guard abs(before.x - after.x) <= 0.5, abs(before.y - after.y) <= 0.5 else {
                        throw QAFailure(
                            "第 \(cycle + 1) 次指针 down/up 改变了滚动偏移："
                            + "\(NSStringFromPoint(before)) → \(NSStringFromPoint(after))"
                        )
                    }
                }
                pointerSendMs.append(dispatch.sendMs)
                pointerPoints.append(NSStringFromPoint(dispatch.point))
                pointerFrames.append(NSStringFromRect(dispatch.axFrame))
                pointerHitViews.append(dispatch.hitView)
                pointerHitChains.append(dispatch.hitChain)
                pointerKeyStates.append(dispatch.windowIsKey)
            } else {
                let pressStart = qaNow()
                let press = AXUIElementPerformAction(element, kAXPressAction as CFString)
                pressMs.append((qaNow() - pressStart) * 1000)
                guard press == .success else {
                    // 不吞掉 AX 错误：先把点击后能取到的现场记下来，再按断言中止。
                    let stateAfter = axFind(root, maxNodes: 1200, limitMs: 800) { candidate in
                        axFields(candidate).contains(label) || axText(candidate).hasPrefix(label)
                    }.map { axString($0, kAXValueAttribute) } ?? "nil"
                    let contentAfter = axTextSignature(root, limitMs: 800)
                    throw QAFailure(
                        "第 \(cycle + 1) 次 AXPress「\(label)」失败：\(press.rawValue)"
                        + "（未吞错误，按 AX 断言中止。点击后 AX 状态「\(stateAfter)」，"
                        + "内容 \(contentAfter.text.count) 字符，截断 \(contentAfter.truncated)）"
                    )
                }
                pressResults.append(Int(press.rawValue))
            }
            targetWindow.contentView?.layoutSubtreeIfNeeded()
            CATransaction.flush()
            layoutMs.append((qaNow() - start) * 1000)

            if input == "pointer" {
                // 指针分派是异步生效的：单独量到状态真正翻转为止的耗时。
                let flipStart = qaNow()
                let timeout = max(settleMs * 4, 1200) / 1000
                var flipped = false
                while qaNow() - flipStart < timeout {
                    if let probe = disclosure(root), axString(probe, kAXValueAttribute) != beforeValue {
                        flipped = true
                        break
                    }
                    await settle(0.005)
                }
                pointerLatencyMs.append((qaNow() - flipStart) * 1000)
                guard flipped else {
                    throw QAFailure(
                        "第 \(cycle + 1) 次指针点击后 \(Int(timeout * 1000))ms 内状态仍是「\(beforeValue)」"
                        + "（落点 \(pointerPoints.last ?? "")，命中 \(pointerHitViews.last ?? "")，"
                        + "分派 \(String(format: "%.2f", pointerSendMs.last ?? 0))ms）"
                    )
                }
            }
            try await settle(settleMs / 1000)

            guard let refreshed = disclosure(root) else {
                throw QAFailure("第 \(cycle + 1) 次切换后找不到「\(label)」")
            }
            let afterValue = axString(refreshed, kAXValueAttribute)
            guard allowedStates.contains(afterValue), !afterValue.isEmpty else {
                throw QAFailure("第 \(cycle + 1) 次切换后 AX 状态无效（得到「\(afterValue)」）")
            }
            guard afterValue != beforeValue else {
                throw QAFailure("第 \(cycle + 1) 次切换后状态仍是「\(afterValue)」，点击未生效")
            }
            let signature = axTextSignature(root)
            guard !signature.truncated else {
                throw QAFailure("第 \(cycle + 1) 次切换后 AX 内容被截断，无法核对展开/收起")
            }
            guard !signature.text.isEmpty else {
                throw QAFailure("第 \(cycle + 1) 次切换后没有可核对的真实内容")
            }
            let delta = signature.text.count - beforeSignature.count
            if afterValue == "已展开" {
                guard delta > 0 else {
                    throw QAFailure("第 \(cycle + 1) 次展开后子内容没有增加（\(delta) 字符）")
                }
            } else {
                guard delta < 0 else {
                    throw QAFailure("第 \(cycle + 1) 次收起后子内容没有减少（\(delta) 字符）")
                }
            }
            if let known = signaturesByState[afterValue] {
                guard known == signature.text else {
                    throw QAFailure("第 \(cycle + 1) 次切换后「\(afterValue)」的真实内容与上次同状态不一致")
                }
            } else {
                signaturesByState[afterValue] = signature.text
            }
            guard signaturesByState.count >= 2 else {
                throw QAFailure("切换没有产生第二种可核对的内容状态")
            }

            currentValue = afterValue
            states.append(afterValue)
            wallMs.append((qaNow() - start) * 1000)
            contentDelta.append(delta)
        }
        let busy = busyProbe.stop()
        guard states.count == cycles,
              states.allSatisfy({ allowedStates.contains($0) }),
              Set(states).count >= 2,
              !contentDelta.contains(0) else {
            throw QAFailure("展开/收起样本不完整：states=\(states) delta=\(contentDelta)")
        }
        let refresh = targetWindow.screen?.maximumFramesPerSecond ?? 60
        let budget = 1000.0 / Double(refresh)
        var entry: [String: Any] = [
            "name": name,
            "mode": "toggle",
            "window": key,
            "label": label,
            "input": input,
            "cycles": cycles,
            "refreshHz": refresh,
            "budgetMs": budget,
            "samples": layoutMs.count,
            "layoutMs": qaStat(layoutMs),
            "wallMs": qaStat(wallMs),
            "mainWorkMs": qaStat(busy),
            "overBudget": layoutMs.filter { $0 > budget }.count,
            "overDoubleBudget": layoutMs.filter { $0 > budget * 2 }.count,
            "states": states,
            "contentDeltaChars": contentDelta,
            "pressResults": pressResults,
            "axPressMs": qaStat(pressMs),
        ]
        if input == "pointer" {
            entry["axPressUsed"] = false
            entry["axPressAdvertised"] = axActions(first).contains(kAXPressAction as String)
            entry["pointerSendMs"] = qaStat(pointerSendMs)
            entry["pointerLatencyMs"] = qaStat(pointerLatencyMs)
            entry["pointerPoints"] = pointerPoints
            entry["pointerFrames"] = pointerFrames
            entry["pointerHitViews"] = pointerHitViews
            entry["pointerHitChains"] = pointerHitChains
            entry["pointerWindowWasKey"] = pointerKeyStates
            entry["note"] = "pointer：只在本窗口本进程用 NSEvent down/up 走命中测试；"
                + "逐轮核对真实状态交替、真实内容增删与 down/up 前后滚动偏移；"
                + "不调用 AXPress，也不把 AXPress 记成成功"
        } else {
            entry["axPressUsed"] = true
            entry["note"] = "每次切换都核对 AXPress 成功、已展开/已收起交替、以及真实内容增删；不合格即中止"
        }
        if let captureName = step["capture"] as? String {
            _ = try? capture(step: ["op": "capture", "name": captureName, "window": key],
                             index: 950 + metrics.count)
        }
        metrics.append(entry)
        return entry
    }

    /// 一次真实指针点击的现场：落点、AX 行位置、命中的视图链、同期滚动偏移
    /// 与同步分派耗时。
    private struct PointerDispatch {
        /// NSEvent 使用的窗口基准坐标落点。
        let point: CGPoint
        /// 命中测试使用的 contentView 坐标落点。
        let contentPoint: CGPoint
        let axFrame: CGRect
        let hitView: String
        let hitChain: [String]
        let windowIsKey: Bool
        let offsetBefore: CGPoint?
        let offsetAfter: CGPoint?
        let sendMs: Double
    }

    /// 本窗口本进程的鼠标 down/up：只用 NSEvent + NSWindow.sendEvent，由 AppKit
    /// 自己做命中测试。不投全局 HID、不激活应用、不改模型；落点取自经 AX 定位的
    /// 真实报告行中心，并先确认该行在窗口内容区内、命中测试确实落到了视图。
    private func pointerClick(on element: AXUIElement, in target: NSWindow) throws -> PointerDispatch {
        guard let content = target.contentView else {
            throw QAFailure("窗口没有 contentView，无法做指针命中")
        }
        guard let axRect = axFrame(element), axRect.width > 0, axRect.height > 0 else {
            throw QAFailure("AX 定位的报告行没有可用的位置/尺寸，无法做指针命中")
        }
        guard let primary = NSScreen.screens.first else {
            throw QAFailure("没有屏幕信息，无法把 AX 坐标换算到窗口")
        }
        // AX 用主屏左上原点，NSWindow.convertPoint(fromScreen:) 用左下原点。
        let screenPoint = CGPoint(x: axRect.midX, y: primary.frame.maxY - axRect.midY)
        // NSEvent.location 要窗口基准坐标；hitTest 要 contentView 坐标，两者分开算。
        let windowPoint = target.convertPoint(fromScreen: screenPoint)
        let point = content.convert(windowPoint, from: nil)
        guard content.bounds.contains(point) else {
            throw QAFailure(
                "指针落点 \(NSStringFromPoint(windowPoint)) 不在窗口内容区 \(NSStringFromRect(content.bounds))"
                + "，AX 行 \(NSStringFromRect(axRect)) 可能已滚出可见范围"
            )
        }
        guard let hit = content.hitTest(point) else {
            throw QAFailure("命中测试在 \(NSStringFromPoint(point)) 没有返回视图，拒绝在空背景上点击")
        }
        var chain: [String] = []
        var enclosingScroll: NSScrollView?
        var node: NSView? = hit
        while let current = node, chain.count < 16 {
            chain.append(String(describing: Swift.type(of: current)))
            if enclosingScroll == nil, let scroll = current as? NSScrollView { enclosingScroll = scroll }
            node = current.superview
        }
        func makeEvent(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: target.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else {
                throw QAFailure("无法构造鼠标事件 \(type.rawValue)")
            }
            return event
        }
        let down = try makeEvent(.leftMouseDown)
        let up = try makeEvent(.leftMouseUp)
        // 只量 down/up 同步分派本身：同一点上的一次点击不应改变滚动偏移。
        let offsetBefore = enclosingScroll?.contentView.bounds.origin
        let sendStart = qaNow()
        target.sendEvent(down)
        target.sendEvent(up)
        let sendMs = (qaNow() - sendStart) * 1000
        let offsetAfter = enclosingScroll?.contentView.bounds.origin
        return PointerDispatch(
            point: windowPoint,
            contentPoint: point,
            axFrame: axRect,
            hitView: String(describing: Swift.type(of: hit)),
            hitChain: chain,
            windowIsKey: target.isKeyWindow,
            offsetBefore: offsetBefore,
            offsetAfter: offsetAfter,
            sendMs: sendMs
        )
    }

    private func largestScrollView(_ view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var bestHeight: CGFloat = 0
        func walk(_ node: NSView) {
            if node.isHiddenOrHasHiddenAncestor { return }
            if let scroll = node as? NSScrollView,
               let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 8 {
                let height = document.frame.height
                if height > bestHeight {
                    bestHeight = height
                    best = scroll
                }
            }
            node.subviews.forEach(walk)
        }
        walk(view)
        return best
    }

    // MARK: 文本工具

    private func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).prefix(80).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - AX 基础

func axValue(_ element: AXUIElement, _ attribute: String) -> Any? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

func axString(_ element: AXUIElement, _ attribute: String) -> String {
    (axValue(element, attribute) as? String) ?? ""
}

/// SwiftUI 往往只填 title/description 之一；匹配时先看每个字段，再看拼接文本。
func axFields(_ element: AXUIElement) -> [String] {
    var parts: [String] = []
    for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
        let text = axString(element, attribute).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !parts.contains(text) { parts.append(text) }
    }
    return parts
}

func axText(_ element: AXUIElement) -> String {
    axFields(element).joined(separator: " ")
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    (axValue(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func axEnabled(_ element: AXUIElement) -> Bool {
    (axValue(element, kAXEnabledAttribute) as? Bool) ?? true
}

func axActions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let positionValue = axValue(element, kAXPositionAttribute),
          let sizeValue = axValue(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

/// 遍历都带节点数与时间预算。WebKit 页面加载后 AX 子树可能非常重，
/// 无限递归会把一次点击拖到几十秒；预算用尽时返回已找到的结果并标记截断。
func axFind(
    _ root: AXUIElement,
    maxNodes: Int = 1200,
    limitMs: Double = 1200,
    _ predicate: (AXUIElement) -> Bool
) -> AXUIElement? {
    // limitMs 是毫秒；预算用尽时退回已访问结果，绝不无限递归 WebKit 内容。
    let deadline = qaNow() + limitMs / 1000
    var visited = 0
    func walk(_ element: AXUIElement) -> AXUIElement? {
        if visited >= maxNodes || qaNow() > deadline { return nil }
        visited += 1
        let role = axString(element, kAXRoleAttribute)
        // 空 role 是 WebKit/代理容器；继续递归会在真实页面上阻塞十几秒。
        if role.isEmpty || role == "AXWebArea" { return nil }
        if predicate(element) { return element }
        for child in axChildren(element) {
            if let found = walk(child) { return found }
        }
        return nil
    }
    return walk(root)
}

func axFindAll(
    _ root: AXUIElement,
    _ predicate: (AXUIElement) -> Bool,
    maxNodes: Int = 1200,
    limitMs: Double = 1200
) -> [AXUIElement] {
    let deadline = qaNow() + limitMs / 1000
    var result: [AXUIElement] = []
    var visited = 0
    func walk(_ element: AXUIElement) {
        if visited >= maxNodes || qaNow() > deadline { return }
        visited += 1
        let role = axString(element, kAXRoleAttribute)
        if role.isEmpty || role == "AXWebArea" { return }
        if predicate(element) { result.append(element) }
        for child in axChildren(element) { walk(child) }
    }
    walk(root)
    return result
}

/// 粗粒度界面指纹：只看有名字/值的控件，避免把 web 内容算进来。
func axFingerprint(
    _ root: AXUIElement,
    maxParts: Int = 160,
    limitMs: Double = 800
) -> (signature: String, truncated: Bool) {
    let deadline = qaNow() + limitMs / 1000
    var parts: [String] = []
    var visited = 0
    var truncated = false
    func walk(_ element: AXUIElement, _ depth: Int) {
        if truncated { return }
        if depth >= 12 || parts.count >= maxParts || visited >= 400 || qaNow() > deadline {
            truncated = true
            return
        }
        visited += 1
        let role = axString(element, kAXRoleAttribute)
        if role.isEmpty || role == "AXWebArea" { return }
        let text = axText(element)
        let value = axString(element, kAXValueAttribute)
        if !text.isEmpty || !value.isEmpty {
            parts.append("\(role)|\(text)|\(value)")
        }
        for child in axChildren(element) { walk(child, depth + 1) }
    }
    walk(root, 0)
    return (parts.joined(separator: "\n"), truncated)
}

/// 报告窗口里的真实内容签名：静态文本，加上只读 NSTextView 暴露的
/// AXTextArea value。编辑中的输入控件也有 value，因此可编辑、value 可写、
/// 或当前已聚焦的文本框一律不计入；WKWebArea 仍整棵跳过。
/// 只有内容完整读取时才能用来核对展开/收起，因此把截断单独暴露给调用方。
func axTextSignature(
    _ root: AXUIElement,
    maxNodes: Int = 2500,
    limitMs: Double = 3000
) -> (text: String, truncated: Bool, nodes: Int) {
    let deadline = qaNow() + limitMs / 1000
    var values: [String] = []
    var visited = 0
    var truncated = false
    func walk(_ element: AXUIElement) {
        if truncated { return }
        if visited >= maxNodes || qaNow() > deadline {
            truncated = true
            return
        }
        visited += 1
        let role = axString(element, kAXRoleAttribute)
        if role.isEmpty || role == "AXWebArea" { return }
        if role == kAXStaticTextRole {
            let text = axText(element).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { values.append(text) }
        } else if role == "AXTextArea" {
            if let text = axReadOnlyTextAreaValue(element) { values.append(text) }
        }
        for child in axChildren(element) { walk(child) }
    }
    walk(root)
    return (values.joined(separator: "\n"), truncated, visited)
}

/// 只读 NSTextView 的正文只在 AXTextArea 的 value 上。这里只接受能确认是
/// 展示用途的文本框：显式声明可编辑的一律跳过；未声明可编辑时，value 可写
/// 或当前已聚焦也按输入控件跳过。显式只读的控件即使被选中聚焦也照常计入。
func axReadOnlyTextAreaValue(_ element: AXUIElement) -> String? {
    let editable = axValue(element, "AXEditable") as? Bool
    if editable == true { return nil }
    if editable != false {
        if axValueIsSettable(element) { return nil }
        if (axValue(element, kAXFocusedAttribute) as? Bool) == true { return nil }
    }
    let raw = axValue(element, kAXValueAttribute)
    let value = ((raw as? String) ?? ((raw as? NSAttributedString)?.string ?? ""))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

func axValueIsSettable(_ element: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success else {
        return false
    }
    return settable.boolValue
}

// MARK: - 入口

@main
struct QAUIEntry {
    static func main() {
        // 必须先于 NSApplication.shared、ArenaModel 和任何 WebKit 对象。
        QAUIStartup.preflight()
        QAUIDriver.launch()
        NSApplication.shared.run()
    }
}
