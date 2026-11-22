//
//  SitePane.swift
//  AI Arena · 独立 macOS 工作台的一个网页席位
//
//  目标：G1 / G3 / G4，R02 / R06 / R07 / R09。
//
//  这一层只负责“一个网页 = 一个席位”的浏览器边界：
//    - 使用持久化 WKWebsiteDataStore.default()，保留用户自己的登录态；
//    - 页面仍是普通 WKWebView，远程网页可原生点击、滚动、输入；
//    - 只在 chatgpt / gemini / deepseek 三家的精确 HTTPS origin 上执行自动化；
//    - 自动化脚本原封加载 Bundle.main 中的 web-driver.js，注入独立的
//      WKContentWorld，绝不改写站点脚本、UA、Cookie 或安全策略；
//    - 命令通过 callAsyncJavaScript 的参数通道传递，绝不把提示拼进 JS 源码；
//    - 主 frame、当前 URL、document 与任务形状都在执行前核对；
//    - 每次失败、恢复与最近命令结果都可在 inspectState() 中查看。
//
//  端到端测试入口（仅显式测试模式）：
//    let pane = SitePane(
//        provider: "chatgpt",
//        testConfiguration: .init(
//            loopbackURL: URL(string: "http://127.0.0.1:8877/web-driver-fixture.html?seat=A")!,
//            selectors: ["input": ["#composer"], "send": ["#send"],
//                        "user": [".turn.user .msg"], "answer": [".turn.answer .msg"]],
//            options: ["sampleMs": 50, "stableSamples": 2]
//        )
//    )
//  测试模式只接受 http(s) + 回环主机，并且只在该回环 origin 内导航；生产构造
//  SitePane(provider:) 永远不会把回环地址当成可自动化页面。
//
//  命令形状与 extension/web-driver.js 的消息一致：
//    ["type": "arena.web.probe" | "arena.web.submit" | "arena.web.read",
//     "taskId": "round1.seatA",
//     "prompt": "仅 submit",                 // 可选，submit 必填
//     "selectors": [...],                    // 可选，覆盖内置站点选择器
//     "options": [...],                      // 可选，覆盖内置采样参数
//     "knownDraftDigests": ["<sha256>"],     // 可选，最多 8 个
//     "verifiedReadPrompt": "原文",          // 可选，仅 read；只读重建
//     "scope": ...]                          // 忽略；作用域由本类固定
//  也接受把同样内容放在 command["message"] 里。
//

import AppKit
import Foundation
import SwiftUI
import WebKit

// MARK: - Errors

enum SitePaneError: Error, LocalizedError {
    case unsupportedProvider(String)
    case invalidTestOrigin(String)
    case driverScriptMissing
    case driverScriptUnreadable(String)
    case driverScriptInvalid
    case driverInjectionFailed(String)
    case noPageLoaded
    case notAuthorizedPage(expected: String, actual: String?)
    case mainFrameRequired
    case documentNotReady(String)
    case driverUnavailable
    case invalidCommand(String)
    case invalidTaskID(String)
    case invalidSelectors(String)
    case invalidPrompt(String)
    case invalidDraftDigest(String)
    case navigationBlocked(String)
    case conversationChanged(expected: String, actual: String)
    case javaScriptFailed(String)
    case invalidDriverResponse(String)

    /// 稳定错误码，便于 UI 和测试记录；与 web-driver 自己的错误码分开。
    var code: String {
        switch self {
        case .unsupportedProvider: return "unsupported-provider"
        case .invalidTestOrigin: return "invalid-test-origin"
        case .driverScriptMissing: return "driver-script-missing"
        case .driverScriptUnreadable: return "driver-script-unreadable"
        case .driverScriptInvalid: return "driver-script-invalid"
        case .driverInjectionFailed: return "driver-injection-failed"
        case .noPageLoaded: return "no-page-loaded"
        case .notAuthorizedPage: return "not-authorized-page"
        case .mainFrameRequired: return "not-main-frame"
        case .documentNotReady: return "document-not-ready"
        case .driverUnavailable: return "driver-unavailable"
        case .invalidCommand: return "invalid-command"
        case .invalidTaskID: return "invalid-task-id"
        case .invalidSelectors: return "invalid-selectors"
        case .invalidPrompt: return "invalid-prompt"
        case .invalidDraftDigest: return "invalid-draft-digest"
        case .navigationBlocked: return "navigation-blocked"
        case .conversationChanged: return "conversation-changed"
        case .javaScriptFailed: return "javascript-failed"
        case .invalidDriverResponse: return "invalid-driver-response"
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            return "不支持的席位站点：\(provider)。可用：chatgpt、gemini、deepseek。"
        case .invalidTestOrigin(let value):
            return "测试地址必须是 http(s) 回环地址，收到：\(value)。"
        case .driverScriptMissing:
            return "应用包中找不到 web-driver.js。请把 extension/web-driver.js 作为资源放进 App Bundle。"
        case .driverScriptUnreadable(let detail):
            return "web-driver.js 无法读取：\(detail)"
        case .driverScriptInvalid:
            return "web-driver.js 不是预期的 AI Arena 网页驱动。"
        case .driverInjectionFailed(let detail):
            return "web-driver.js 注入失败：\(detail)"
        case .noPageLoaded:
            return "当前没有已加载的网页。请先打开站点首页。"
        case .notAuthorizedPage(let expected, let actual):
            return "当前页面不在本站白名单内。期望 \(expected)，实际 \(actual ?? "无地址")。"
        case .mainFrameRequired:
            return "自动化只能在主 frame 执行。"
        case .documentNotReady(let state):
            return "页面文档尚未就绪（readyState=\(state)）。"
        case .driverUnavailable:
            return "页面里没有可用的 web-driver。请确认脚本已注入后重试。"
        case .invalidCommand(let reason):
            return "网页命令无效：\(reason)"
        case .invalidTaskID(let value):
            return "任务号不合法：\(value)"
        case .invalidSelectors(let reason):
            return "页面选择器不合法：\(reason)"
        case .invalidPrompt(let reason):
            return "提示文本不合法：\(reason)"
        case .invalidDraftDigest(let value):
            return "旧提示摘要不合法：\(value)"
        case .navigationBlocked(let value):
            return "测试模式拒绝离开回环 origin：\(value)"
        case .conversationChanged(let expected, let actual):
            return "本席已固定到核验过的对话 \(expected)，当前原页是 \(actual)。为免把本轮提示发到别的窗口，已转人工核对。"
        case .javaScriptFailed(let detail):
            return "页面脚本执行失败：\(detail)"
        case .invalidDriverResponse(let detail):
            return "web-driver 返回了无法识别的结果：\(detail)"
        }
    }

    /// 本席原页被换到别的对话。调用方应停在本轮、转人工，绝不重试或重发。
    var isConversationChanged: Bool {
        if case .conversationChanged = self { return true }
        return false
    }
}

// MARK: - SitePane

@MainActor
final class SitePane: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {

    // MARK: Explicit loopback test configuration

    /// 只有调用方显式传入这个结构时，才允许把回环 origin 当作可自动化页面。
    /// 生产初始化 `SitePane(provider:)` 不会推断、读取环境变量或自动启用测试模式。
    struct TestConfiguration {
        var loopbackURL: URL
        var selectors: [String: [String]]
        var options: [String: Any]
        var allowNavigation: Bool
        var label: String?

        init(
            loopbackURL: URL,
            selectors: [String: [String]],
            options: [String: Any] = [:],
            allowNavigation: Bool = true,
            label: String? = nil
        ) {
            self.loopbackURL = loopbackURL
            self.selectors = selectors
            self.options = options
            self.allowNavigation = allowNavigation
            self.label = label
        }
    }

    // MARK: Required public shape

    let provider: String
    let webView: WKWebView

    // MARK: Observable status

    @Published private(set) var label: String
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress: Double = 0
    @Published private(set) var documentReady = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isWebContentTerminated = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastErrorCode: String?
    @Published private(set) var lastNavigationError: String?
    @Published private(set) var lastNavigationErrorCode: String?
    @Published private(set) var lastCommandStatus: String?
    @Published private(set) var lastTaskID: String?
    @Published private(set) var lastCommandAt: Date?
    @Published private(set) var driverResourcePath: String?

    /// 本席已核验本轮用户消息后固定下来的真实会话地址（同源 origin+path，
    /// 已规范化：不含账号、查询串或片段）。只要本场还在进行，后续 probe /
    /// submit / read 都要求原页仍停在这个地址；用户换到同站另一个对话时立即
    /// 转人工，绝不把提示发进别的窗口。新建场次时由调用方显式重置。
    @Published private(set) var boundConversationURL: URL?

    // MARK: Private state

    private let site: SiteDescriptor?
    private let configurationError: SitePaneError?
    private let contentWorld: WKContentWorld
    private let commandGate = CommandGate()

    private var cachedDriverSource: String?
    private var didInstallDriverUserScript = false
    private var keyValueObservations: [NSKeyValueObservation] = []

    // MARK: Initialisers

    /// 生产入口。init 不发起任何导航；由 UI / 模型显式调用 openHome() 或 open(_:)。
    convenience init(provider: String) {
        self.init(provider: provider, testConfiguration: nil)
    }

    /// 指定站点的构造入口；testConfiguration 为 nil 时行为与 init(provider:) 完全相同。
    init(provider: String, testConfiguration: TestConfiguration?) {
        self.provider = provider

        let resolution = Self.resolveSite(provider: provider, testConfiguration: testConfiguration)
        self.site = resolution.site
        self.configurationError = resolution.error
        self.label = resolution.site?.label ?? provider

        let configuration = Self.makeWebConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.contentWorld = WKContentWorld.world(
            name: "ai-arena-web-driver-" + SitePane.worldNameComponent(provider)
        )

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.allowsLinkPreview = true
        observeWebView()

        prepareDriverUserScript()
        if let configurationError {
            record(configurationError)
        }
    }

    /// 显式测试入口：同一 provider，但浏览器地址只允许给定的回环 origin。
    /// 这个工厂只用于端到端测试/R02–R06 回放，不会进入普通 UI 的构造路径。
    static func testPane(
        provider: String,
        loopbackURL: URL,
        selectors: [String: [String]],
        options: [String: Any] = [:],
        allowNavigation: Bool = true
    ) -> SitePane {
        SitePane(
            provider: provider,
            testConfiguration: TestConfiguration(
                loopbackURL: loopbackURL,
                selectors: selectors,
                options: options,
                allowNavigation: allowNavigation
            )
        )
    }

    // MARK: Navigation

    /// 打开本席位的站点首页。只有调用方显式调用时才导航。
    func openHome() {
        guard let site else {
            record(configurationError ?? .unsupportedProvider(provider))
            return
        }
        open(site.homeURL)
    }

    /// 在同一个 WKWebView 中打开 URL（普通登录、同窗导航都走这里）。
    /// 不在白名单里的 http(s) 页面可以加载（例如登录跳转），但 command()
    /// 会再次核对当前 origin，绝不会在登录页上执行网页驱动。
    func open(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            record(.navigationBlocked(url.absoluteString))
            return
        }

        if let site, site.isTest {
            guard let targetOrigin = Self.originString(url), targetOrigin == site.origin else {
                record(.navigationBlocked(url.absoluteString))
                return
            }
        } else {
            // 生产席位只由调用方打开 HTTPS 页面；普通登录跳转由 WebKit
            // 在同一个 webView 内完成，不经过这个入口。
            guard scheme == "https" else {
                record(.navigationBlocked(url.absoluteString))
                return
            }
        }

        clearLastError()
        prepareDriverUserScript()
        documentReady = false
        webView.load(URLRequest(url: url))
    }

    // MARK: Conversation binding

    /// 只有“驱动已核验本轮用户消息”的回应才能固定会话地址。
    /// 地址取驱动回执里的规范化 `href`（没有就退回 `url`），再按白名单规范化；
    /// 任一环节不合格就不绑定，宁可让下一轮转人工，也不猜对话。
    @discardableResult
    func bindVerifiedConversation(from response: [String: Any]) -> Bool {
        guard let site else { return false }
        guard let detail = response["detail"] as? [String: Any] else { return false }
        // 只有驱动明确核对过“本轮精确用户消息”的回执才能固定会话。
        // status 本身不够：临时路由上也可能返回 submitted。
        guard (detail["userTurnVerified"] as? Bool) == true else { return false }

        let raw = (detail["href"] as? String) ?? (detail["url"] as? String)
        guard let raw, let url = URL(string: raw),
              let canonical = Self.canonicalConversationURL(url, origin: site.origin)
        else { return false }
        guard isConversation(canonical, site: site),
              boundConversationURL == nil || boundConversationURL == canonical else { return false }
        boundConversationURL = canonical
        return true
    }

    /// 恢复上次场次时固定当时保存的会话地址。传入的地址必须仍与登记站点同源，
    /// 且能通过白名单规范化；否则不绑定。
    @discardableResult
    func restoreConversationBinding(_ url: URL) -> Bool {
        guard let site,
              let canonical = Self.canonicalConversationURL(url, origin: site.origin)
        else { return false }
        guard isConversation(canonical, site: site),
              boundConversationURL == nil || boundConversationURL == canonical else { return false }
        boundConversationURL = canonical
        return true
    }

    private func isConversation(_ url: URL, site: SiteDescriptor) -> Bool {
        Self.isConversationURL(
            url,
            provider: provider,
            homePath: site.homeURL.path,
            isTest: site.isTest
        )
    }

    /// 纯函数版本：绑定、恢复和定向测试共用同一套白名单。
    ///
    /// ChatGPT 在真正落稳之前会先把地址换成 `/c/local-chatgpt:<uuid>`，路径里的
    /// 冒号也可能是百分号编码（`local-chatgpt%3A...`）。这是前端临时路由，不是
    /// 会话地址：不持久化、不作为恢复目的地，也不允许固定成本席的上下文。
    /// 只认稳定的 `/c/<id>`；其它站点的既有规则保持不变。
    nonisolated static func isConversationURL(
        _ url: URL,
        provider: String,
        homePath: String,
        isTest: Bool
    ) -> Bool {
        if isTest { return url.path == homePath }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch provider {
        case "chatgpt":
            guard parts.count == 2, parts[0] == "c" else { return false }
            return isStableChatGPTConversationID(parts[1])
        case "gemini": return parts.count == 2 && parts[0] == "app"
        case "deepseek": return parts.count == 4 && Array(parts.prefix(3)) == ["a", "chat", "s"]
        default: return false
        }
    }

    /// 稳定的 ChatGPT 会话 ID。除了解码后的路径不能含 `local-chatgpt`，
    /// 还要求形如 `/c/<id>` 的单段 ID；临时路由里的冒号、编码片段都不合格。
    nonisolated static func isStableChatGPTConversationID(_ raw: String) -> Bool {
        var segment = raw
        for _ in 0..<2 {
            guard let decoded = segment.removingPercentEncoding, decoded != segment else { break }
            segment = decoded
        }
        if segment.lowercased().contains("local-chatgpt") { return false }
        return segment.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9-]{5,}$"#,
            options: .regularExpression
        ) != nil
    }

    /// 新建场次（或换一场讨论）时才允许解除固定。手工接管与恢复不重置。
    func resetConversationBinding() {
        boundConversationURL = nil
    }

    /// 一次受控只读恢复的地址条件：本席已固定会话、当前地址正是该会话、页面
    /// 也没有正在进行的导航。满足时返回规范化的重载目标，否则 nil。纯函数，
    /// 模型和定向检查共用；它不判断草稿或 stop，那些要由页面的 probe 回执确认。
    nonisolated static func readRecoveryReloadTarget(
        current: URL?,
        bound: URL?,
        origin: String,
        isLoading: Bool
    ) -> URL? {
        guard !isLoading,
              let current,
              let bound,
              let canonicalCurrent = canonicalConversationURL(current, origin: origin),
              let canonicalBound = canonicalConversationURL(bound, origin: origin),
              canonicalCurrent.absoluteString == canonicalBound.absoluteString
        else { return nil }
        return canonicalBound
    }

    /// 已确认发送、仍在等待原生完成标记的席位在长时间没有新内容时，由本席
    /// 做一次受控的“只读恢复”：在同一个 WKWebView 内重新加载已经固定的会话
    /// 地址。它不填写、不点击、不打开别的标签，也不改变会话绑定。
    ///
    /// 调用方必须先用只读 `probe` 确认输入框为空、没有活跃的 stop，并核对该
    /// 任务仍属于当前场次；任一条件不满足就应放弃本次重载。返回是否真的发起
    /// 了导航。
    @discardableResult
    func reloadBoundConversationForReadRecovery() -> Bool {
        guard let site else { return false }
        guard let target = Self.readRecoveryReloadTarget(
            current: webView.url,
            bound: boundConversationURL,
            origin: site.origin,
            isLoading: isLoading
        ) else { return false }
        isWebContentTerminated = false
        open(target)
        return true
    }

    // MARK: Probe-time document recovery

    /// probe 阶段“最多一次”的恢复结果。助手只核对文档并（必要时）导航，
    /// 不填写、不点击。
    enum ProbeRecoveryOutcome: Equatable {
        /// 文档其实已经 settled，只是 WebKit 的 documentReady/isLoading 没有
        /// 更新。调用方应稍等后重新 probe，不要导航、不要点击。
        case flagsCorrected
        /// 已发起一次回到本席原页（已核验会话或从未开始时的入口）的导航。
        case navigated(URL)
        /// 不满足自动恢复条件；调用方保持原样，继续原有的有界等待。
        case declined(String)
    }

    /// 冷启动恢复后，WK 内容进程被终止或一次瞬时网络导航失败可能让
    /// `documentReady` 永远不成立。这里只读核对当前文档：
    /// - 只要有可用文档（可能含未发送草稿），就只修正过期的 WebKit 标志；
    /// - 只有确认没有可用文档、且失败可归因于内容进程终止或瞬态网络错误时，
    ///   才允许一次导航回已核验会话 / 从未开始时的允许入口。
    /// 离线、证书、认证、取消、地址不符和进行中的导航一律不自动导航。
    func recoverStalledProbeDocument(canRecover: () -> Bool) async -> ProbeRecoveryOutcome {
        guard let site else { return .declined("unsupported-site") }
        if webView.isLoading { return .declined("navigation-in-progress") }

        let current = webView.url
        if let current, Self.originString(current) != site.origin {
            // 登录、验证或认证页：地址已离开本席 origin，绝不自动回退。
            return .declined("origin-mismatch")
        }

        let snapshot = await probeDocumentSnapshot()
        guard canRecover(), webView.url == current, !webView.isLoading else {
            return .declined("page-or-task-changed")
        }
        if let snapshot {
            guard snapshot.settled else { return .declined("live-document-loading") }
            guard let current, snapshot.locationMatches(current) else {
                return .declined("document-location-mismatch")
            }
            // 有可用文档就是活页面：绝不导航离开它。
            if documentReady && !isLoading {
                return .declined("document-already-ready")
            }
            documentReady = true
            if snapshot.readyState == "complete" {
                isLoading = false
                estimatedProgress = 1
            }
            if isWebContentTerminated {
                isWebContentTerminated = false
                if lastErrorCode == "web-content-terminated" {
                    lastErrorCode = nil
                    lastError = nil
                }
            }
            return .flagsCorrected
        }

        // 没有可用文档：只有“内容进程终止”或“已确认的瞬态网络导航失败”
        // 才允许一次自动导航；离线、证书、认证和其它失败留给人和原有的
        // 有界等待。
        let terminated = isWebContentTerminated
        if Self.isHumanRequiredNavigationFailure(lastNavigationErrorCode) {
            return .declined("needs-human")
        }
        guard terminated || Self.isRecoverableTransientNavigationFailure(lastNavigationErrorCode) else {
            return .declined("no-confirmed-failure")
        }

        guard let target = Self.probeRecoveryNavigationTarget(
            current: current,
            bound: boundConversationURL,
            siteOrigin: site.origin,
            homePath: site.homeURL.path,
            provider: provider,
            isTest: site.isTest
        ) else { return .declined("no-verified-target") }

        isWebContentTerminated = false
        open(target)
        return .navigated(target)
    }

    private struct ProbeDocumentSnapshot {
        let readyState: String
        let href: URL?

        var settled: Bool { readyState == "interactive" || readyState == "complete" }

        func locationMatches(_ webViewURL: URL) -> Bool {
            guard let href else { return false }
            return SitePane.documentLocationsMatch(href, webViewURL)
        }
    }

    /// 只读读取当前文档的 readyState 和 location；读不到（例如内容进程已终止）
    /// 返回 nil，表示没有可用文档。
    private func probeDocumentSnapshot() async -> ProbeDocumentSnapshot? {
        let body = """
        const state = document.readyState ? String(document.readyState) : "";
        const href = (window.location && window.location.href) ? String(window.location.href) : "";
        return { readyState: state, href: href };
        """
        let raw: Any
        do {
            raw = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: contentWorld) { result in
                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            return nil
        }
        guard let dictionary = raw as? [String: Any],
              let state = dictionary["readyState"] as? String,
              !state.isEmpty
        else { return nil }
        let href = (dictionary["href"] as? String).flatMap(URL.init(string:))
        return ProbeDocumentSnapshot(readyState: state, href: href)
    }

    /// 当前原页是否已经离开本席固定的会话。返回 nil 表示仍在原位（或尚未固定）。
    func conversationMismatch() -> (expected: String, actual: String)? {
        guard let site, let bound = boundConversationURL, let current = webView.url else {
            return nil
        }
        let canonical = Self.canonicalConversationURL(current, origin: site.origin)
        guard canonical?.absoluteString != bound.absoluteString else { return nil }
        return (bound.absoluteString, canonical?.absoluteString ?? current.absoluteString)
    }

    /// 重新打开当前页或站点首页。用于内容进程被系统终止、页面崩溃后的显式恢复；
    /// 不会自动重发任何网页提示。
    @discardableResult
    func recover() -> Bool {
        if let current = webView.url ?? currentURL, isNavigationAllowed(current) {
            isWebContentTerminated = false
            open(current)
            return true
        }
        if let home = site?.homeURL {
            isWebContentTerminated = false
            open(home)
            return true
        }
        record(.noPageLoaded)
        return false
    }

    /// 只读诊断快照：UI、日志和端到端测试使用同一份事实。
    func inspectState() -> [String: Any] {
        let actualOrigin = webView.url.flatMap(Self.originString)
        let authorized = site.map { actualOrigin == $0.origin } ?? false
        return [
            "provider": provider,
            "label": label,
            "testMode": site?.isTest ?? false,
            "homeURL": site?.homeURL.absoluteString ?? NSNull(),
            "currentURL": webView.url?.absoluteString ?? NSNull(),
            "currentOrigin": actualOrigin ?? NSNull(),
            "authorizedOrigin": site?.origin ?? NSNull(),
            "isOnAuthorizedPage": authorized,
            "isLoading": isLoading,
            "documentReady": documentReady,
            "estimatedProgress": estimatedProgress,
            "canGoBack": canGoBack,
            "canGoForward": canGoForward,
            "webContentTerminated": isWebContentTerminated,
            "lastError": lastError ?? NSNull(),
            "lastErrorCode": lastErrorCode ?? NSNull(),
            "lastNavigationError": lastNavigationError ?? NSNull(),
            "lastNavigationErrorCode": lastNavigationErrorCode ?? NSNull(),
            "lastCommandStatus": lastCommandStatus ?? NSNull(),
            "lastTaskID": lastTaskID ?? NSNull(),
            "lastCommandAt": lastCommandAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "driverResourcePath": driverResourcePath ?? NSNull(),
            "driverUserScriptInstalled": didInstallDriverUserScript,
            "boundConversationURL": boundConversationURL?.absoluteString ?? NSNull(),
        ]
    }

    // MARK: Commands

    /// 执行一条 web-driver 命令。命令串行化，避免同一页面上 probe/read/submit 交错。
    /// 返回 web-driver 原始回应；`ok == false` 时仍返回字典，由调用方按 status/error 处理。
    func command(_ command: [String: Any]) async throws -> [String: Any] {
        await commandGate.acquire()
        do {
            let result = try await runCommand(command)
            await commandGate.release()
            return result
        } catch {
            await commandGate.release()
            lastCommandStatus = "error"
            lastCommandAt = Date()
            if let paneError = error as? SitePaneError {
                record(paneError)
            } else {
                record(.javaScriptFailed(error.localizedDescription))
            }
            throw error
        }
    }

    /// 等当前导航真正结束。只等待，不触发导航，也不重发任何提示。
    private func waitForDocumentReady(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !documentReady {
            if Date() >= deadline {
                if let site,
                   let actual = webView.url.flatMap(Self.originString),
                   actual != site.origin {
                    throw SitePaneError.notAuthorizedPage(expected: site.origin, actual: actual)
                }
                throw SitePaneError.documentNotReady("timeout")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func runCommand(_ rawCommand: [String: Any]) async throws -> [String: Any] {
        guard configurationError == nil, let site else {
            throw configurationError ?? .unsupportedProvider(provider)
        }

        prepareDriverUserScript()
        try ensureDriverSourceAvailable()

        guard webView.url != nil else {
            throw SitePaneError.noPageLoaded
        }
        // UI/模型常常在 open() 之后立刻派发命令；等本次文档真正 didFinish，
        // 避免把命令打进正在被替换的旧文档，造成“可能已发送”的假象。
        try await waitForDocumentReady()
        if webView.isLoading {
            throw SitePaneError.documentNotReady("navigation-in-progress")
        }

        guard let pageURL = webView.url else {
            throw SitePaneError.noPageLoaded
        }
        let actualOrigin = Self.originString(pageURL)
        guard actualOrigin == site.origin else {
            throw SitePaneError.notAuthorizedPage(expected: site.origin, actual: actualOrigin)
        }

        // 本席已固定到核验过的对话：命令发出前先核对原页仍是同一个会话地址。
        // 用户手动切到同站别的对话时，这里立刻失败并转人工，绝不把提示发错窗口。
        if let mismatch = conversationMismatch() {
            throw SitePaneError.conversationChanged(
                expected: mismatch.expected,
                actual: mismatch.actual
            )
        }

        let message = try buildDriverMessage(rawCommand, site: site)
        let taskID = message["taskId"] as? String
        lastTaskID = taskID
        lastCommandStatus = "running"
        lastCommandAt = Date()
        clearLastError()

        var result: [String: Any]
        do {
            result = try await invokeDriver(message, expectedOrigin: site.origin)
            if (result["error"] as? String) == "driver-unavailable" {
                // 当前文档在 user script 安装之前就已加载时，补注入一次再重试。
                // 注入的是原始 bundle 脚本，不包含任何命令或提示内容。
                try await injectDriverIntoCurrentPage()
                result = try await invokeDriver(message, expectedOrigin: site.origin)
            }
        } catch let paneError as SitePaneError {
            throw paneError
        } catch {
            throw SitePaneError.javaScriptFailed(error.localizedDescription)
        }

        try Self.requireDriverPreconditions(result)

        let status = (result["status"] as? String) ?? "unknown"
        lastCommandStatus = status
        if (result["ok"] as? Bool) == true {
            clearLastError()
        } else {
            let code = (result["error"] as? String) ?? "driver-error"
            lastErrorCode = code
            lastError = "web-driver: \(code)"
        }
        return result
    }

    // MARK: Driver loading / injection

    /// 原封读取应用包里的 web-driver.js。不在 Swift 里复制一份驱动逻辑。
    private func driverSource() throws -> String {
        if let cachedDriverSource { return cachedDriverSource }

        guard let url = Bundle.main.url(forResource: "web-driver", withExtension: "js") else {
            throw SitePaneError.driverScriptMissing
        }
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SitePaneError.driverScriptUnreadable(error.localizedDescription)
        }
        guard source.contains("__arenaWebDriver"), source.contains("function handle") || source.contains("handle:") else {
            throw SitePaneError.driverScriptInvalid
        }
        cachedDriverSource = source
        driverResourcePath = url.path
        return source
    }

    private func ensureDriverSourceAvailable() throws {
        _ = try driverSource()
    }

    /// 在文档结束时把脚本注入命名隔离世界。只在主 frame 运行，不触碰页面自身世界。
    private func prepareDriverUserScript() {
        guard !didInstallDriverUserScript else { return }
        guard let source = try? driverSource() else { return }

        let script = WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: contentWorld
        )
        webView.configuration.userContentController.addUserScript(script)
        didInstallDriverUserScript = true
    }

    /// 如果脚本是在当前文档加载后才装进配置，它不会追溯执行；这里显式补一次。
    private func injectDriverIntoCurrentPage() async throws {
        let source = try driverSource()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(source, in: nil, in: contentWorld) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(
                        throwing: SitePaneError.driverInjectionFailed(error.localizedDescription)
                    )
                }
            }
        }
    }

    private func invokeDriver(_ message: [String: Any], expectedOrigin: String) async throws -> [String: Any] {
        let arguments: [String: Any] = [
            "message": message,
            "expectedOrigin": expectedOrigin,
        ]

        let raw: Any = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            webView.callAsyncJavaScript(
                Self.driverInvocationBody,
                arguments: arguments,
                in: nil,
                in: contentWorld
            ) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(
                        throwing: SitePaneError.javaScriptFailed(error.localizedDescription)
                    )
                }
            }
        }

        guard let dictionary = raw as? [String: Any] else {
            throw SitePaneError.invalidDriverResponse(String(describing: type(of: raw)))
        }
        return dictionary
    }

    /// `callAsyncJavaScript` 的函数体：所有动态内容都从 arguments 进入。
    /// 这里不含任务号、提示、选择器或任何用户文本。
    private static let driverInvocationBody: String = """
    "use strict";
    if (window.top !== window.self) {
      return { ok: false, status: "error", error: "not-main-frame" };
    }
    const actualOrigin = window.location.origin;
    if (actualOrigin !== expectedOrigin) {
      return {
        ok: false,
        status: "error",
        error: "out-of-scope",
        detail: { expectedOrigin: expectedOrigin, actualOrigin: actualOrigin }
      };
    }
    if (!document.documentElement || !document.body) {
      return {
        ok: false,
        status: "error",
        error: "document-not-ready",
        detail: { readyState: document.readyState || "missing" }
      };
    }
    if (document.readyState === "loading") {
      return {
        ok: false,
        status: "error",
        error: "document-not-ready",
        detail: { readyState: document.readyState }
      };
    }
    const driver = globalThis.__arenaWebDriver;
    if (!driver || typeof driver.handle !== "function") {
      return { ok: false, status: "error", error: "driver-unavailable" };
    }
    try {
      return await driver.handle(message);
    } catch (error) {
      return {
        ok: false,
        status: "error",
        error: "internal",
        detail: { message: String((error && error.message) || error) }
      };
    }
    """

    // MARK: Command construction

    private func buildDriverMessage(_ raw: [String: Any], site: SiteDescriptor) throws -> [String: Any] {
        let source = (raw["message"] as? [String: Any]) ?? raw

        guard let type = source["type"] as? String else {
            throw SitePaneError.invalidCommand("缺少 type")
        }
        let normalizedType: String
        switch type {
        case "arena.web.probe", "probe": normalizedType = "arena.web.probe"
        case "arena.web.submit", "submit": normalizedType = "arena.web.submit"
        case "arena.web.read", "read": normalizedType = "arena.web.read"
        default: throw SitePaneError.invalidCommand("未知 type：\(type)")
        }

        guard let taskID = source["taskId"] as? String, Self.isValidTaskID(taskID) else {
            throw SitePaneError.invalidTaskID(String(describing: source["taskId"] ?? "nil"))
        }

        let selectors = try Self.mergeSelectors(
            base: site.selectors,
            override: source["selectors"]
        )
        let options = Self.mergeOptions(
            base: site.options,
            override: source["options"],
            provided: source["options"] != nil
        )

        var scope: [String: Any] = [
            "origin": site.origin,
            "hrefPrefix": site.origin + "/",
            "homeHref": site.homeURL.absoluteString,
            "allowNavigation": site.allowNavigation,
        ]
        // 可选、向后兼容的会话约束：driver 不认识时忽略，认识时在最后一次
        // 填入/点击前再核对一次地址。
        if let bound = boundConversationURL {
            scope["href"] = bound.absoluteString
        } else if normalizedType == "arena.web.submit" {
            guard taskID.contains(":independent:"),
                  let here = webView.url,
                  let canonical = Self.canonicalConversationURL(here, origin: site.origin),
                  canonical.path == site.homeURL.path || (provider == "deepseek" && canonical.path == "/a/chat")
            else { throw SitePaneError.conversationChanged(expected: site.homeURL.absoluteString, actual: "原页未绑定") }
            scope["href"] = canonical.absoluteString
        }

        var message: [String: Any] = [
            "type": normalizedType,
            "taskId": taskID,
            "selectors": selectors,
            "options": options,
            "scope": scope,
        ]

        if normalizedType == "arena.web.submit" {
            guard let prompt = source["prompt"] as? String else {
                throw SitePaneError.invalidPrompt("submit 必须带 prompt")
            }
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw SitePaneError.invalidPrompt("prompt 为空")
            }
            guard prompt.count <= 100_000 else {
                throw SitePaneError.invalidPrompt("prompt 超过 100000 字符")
            }
            guard !prompt.unicodeScalars.contains("\u{0}") else {
                throw SitePaneError.invalidPrompt("prompt 含 NUL")
            }
            message["prompt"] = prompt
        }

        if let rawDigests = source["knownDraftDigests"] {
            message["knownDraftDigests"] = try Self.normalizedDraftDigests(rawDigests)
        }

        // 可选、向后兼容：只读 `probe` 可以点名核对输入框是否正好是本轮完整
        // 提示。该值只用于比较，永远不会写入输入框，也不授权点击。
        if normalizedType == "arena.web.probe", let rawExpected = source["expectedPrompt"] {
            if let prompt = try Self.validatedProbeExpectedPrompt(rawExpected) {
                message["expectedPrompt"] = prompt
            }
        }

        // 只读重建用的原文：只允许出现在 read 上，形状与 submit 的 prompt
        // 同样严格（非空、有界、无 NUL）。是否携带由模型按持久化发送意图决定；
        // 驱动还会要求 scope.href 是稳定的同站会话地址后才真正重建。
        if normalizedType == "arena.web.read", let rawReadPrompt = source["verifiedReadPrompt"] {
            if let prompt = try Self.validatedReadRecoveryPrompt(rawReadPrompt) {
                message["verifiedReadPrompt"] = prompt
            }
        }

        return message
    }

    /// Shape check for the read-only rebuild prompt. It is never written to the
    /// composer and never authorises a click by itself.
    nonisolated static func validatedReadRecoveryPrompt(_ raw: Any?) throws -> String? {
        guard let raw else { return nil }
        guard let prompt = raw as? String else {
            throw SitePaneError.invalidPrompt("verifiedReadPrompt 必须是字符串")
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              prompt.count <= 100_000,
              !prompt.unicodeScalars.contains("\u{0}")
        else {
            throw SitePaneError.invalidPrompt("verifiedReadPrompt 为空或超长")
        }
        return prompt
    }

    /// Shape check for the optional read-only `probe` composer comparison. Like
    /// the read prompt it is only a comparison string: it is never written to
    /// the composer and never authorises a click.
    nonisolated static func validatedProbeExpectedPrompt(_ raw: Any?) throws -> String? {
        guard let raw else { return nil }
        guard let prompt = raw as? String else {
            throw SitePaneError.invalidPrompt("expectedPrompt 必须是字符串")
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              prompt.count <= 100_000,
              !prompt.unicodeScalars.contains("\u{0}")
        else {
            throw SitePaneError.invalidPrompt("expectedPrompt 为空或超长")
        }
        return prompt
    }

    private static func normalizedDraftDigests(_ raw: Any) throws -> [String] {
        guard let values = raw as? [Any] else {
            throw SitePaneError.invalidDraftDigest(String(describing: raw))
        }
        guard values.count <= 8 else {
            throw SitePaneError.invalidDraftDigest("最多 8 个摘要")
        }
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let digest = value as? String,
                  digest.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil
            else {
                throw SitePaneError.invalidDraftDigest(String(describing: value))
            }
            let lower = digest.lowercased()
            if seen.insert(lower).inserted {
                result.append(lower)
            }
        }
        return result
    }

    private static func mergeSelectors(base: [String: [String]], override: Any?) throws -> [String: [String]] {
        var merged = base
        if let override {
            guard let raw = override as? [String: Any] else {
                throw SitePaneError.invalidSelectors("selectors 必须是对象")
            }
            for (key, value) in raw {
                guard Self.selectorKeys.contains(key) else {
                    throw SitePaneError.invalidSelectors("未知键 \(key)")
                }
                let candidates: [String]
                if let single = value as? String {
                    candidates = [single]
                } else if let list = value as? [String] {
                    candidates = list
                } else {
                    throw SitePaneError.invalidSelectors("\(key) 必须是字符串或字符串数组")
                }
                merged[key] = candidates
            }
        }

        var normalized: [String: [String]] = [:]
        for key in Self.selectorKeys {
            guard let candidates = merged[key] else {
                if Self.requiredSelectorKeys.contains(key) {
                    throw SitePaneError.invalidSelectors("缺少 \(key)")
                }
                continue
            }
            var clean: [String] = []
            for candidate in candidates {
                let css = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !css.isEmpty, css.count <= 400, !css.contains("\n"), !css.contains("\r") else {
                    throw SitePaneError.invalidSelectors("\(key) 含空或超长候选")
                }
                if !clean.contains(css) { clean.append(css) }
            }
            guard !clean.isEmpty else {
                if Self.requiredSelectorKeys.contains(key) {
                    throw SitePaneError.invalidSelectors("\(key) 为空")
                }
                continue
            }
            normalized[key] = clean
        }

        for key in Self.requiredSelectorKeys where normalized[key] == nil {
            throw SitePaneError.invalidSelectors("缺少 \(key)")
        }

        let userText = normalized["user"]?.joined(separator: " || ") ?? ""
        let answerText = normalized["answer"]?.joined(separator: " || ") ?? ""
        guard !userText.isEmpty, userText != answerText else {
            throw SitePaneError.invalidSelectors("user 与 answer 不能相同")
        }
        return normalized
    }

    private static func mergeOptions(base: [String: Any], override: Any?, provided: Bool) -> [String: Any] {
        var merged = base
        guard provided, let raw = override as? [String: Any] else { return merged }

        for (key, value) in raw {
            if optionNumberKeys.contains(key), let number = value as? NSNumber, !isBooleanNumber(number) {
                merged[key] = number.doubleValue
            } else if key == "requireDoneMarker", let flag = value as? Bool {
                merged[key] = flag
            }
            // 其它类型或未知键留给 web-driver 的默认值，不把任意对象送进页面。
        }
        return merged
    }

    private static func isBooleanNumber(_ number: NSNumber) -> Bool {
        String(cString: number.objCType) == "c" && (number == true || number == false)
    }

    // MARK: Preconditions from driver wrapper

    private static func requireDriverPreconditions(_ result: [String: Any]) throws {
        let error = (result["error"] as? String) ?? ""
        switch error {
        case "not-main-frame":
            throw SitePaneError.mainFrameRequired
        case "document-not-ready":
            let detail = result["detail"] as? [String: Any]
            let state = (detail?["readyState"] as? String) ?? "unknown"
            throw SitePaneError.documentNotReady(state)
        case "out-of-scope":
            let detail = result["detail"] as? [String: Any]
            let actual = detail?["actualOrigin"] as? String
            let expected = (detail?["expectedOrigin"] as? String) ?? ""
            throw SitePaneError.notAuthorizedPage(expected: expected, actual: actual)
        case "driver-unavailable":
            throw SitePaneError.driverUnavailable
        default:
            return
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        if scheme == "about" {
            decisionHandler(.allow)
            return
        }

        guard scheme == "http" || scheme == "https" else {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated {
                openExternally(url)
            }
            return
        }

        if let site, site.isTest {
            guard let targetOrigin = Self.originString(url), targetOrigin == site.origin else {
                decisionHandler(.cancel)
                record(.navigationBlocked(url.absoluteString))
                return
            }
            decisionHandler(.allow)
            return
        }

        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame != false,
           let destinationOrigin = Self.originString(url),
           destinationOrigin != site?.origin,
           !Self.isAuthenticationURL(url) {
            decisionHandler(.cancel)
            openExternally(url)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        documentReady = false
        isWebContentTerminated = false
        currentURL = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        lastNavigationError = nil
        lastNavigationErrorCode = nil
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        currentURL = webView.url
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        currentURL = webView.url
        pageTitle = webView.title
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        documentReady = true
        currentURL = webView.url
        pageTitle = webView.title
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        estimatedProgress = 1
        isWebContentTerminated = false
        lastNavigationError = nil
        lastNavigationErrorCode = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didSameDocumentNavigation navigation: WKNavigation!) {
        currentURL = webView.url
        pageTitle = webView.title
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        documentReady = false
        isWebContentTerminated = true
        lastErrorCode = "web-content-terminated"
        lastError = "网页内容进程已终止。当前页面仍保留地址，可调用 recover() 显式重开；不会自动重发提示。"
    }

    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // 明确交回 WebKit/系统处理：不绕过站点身份验证、证书校验或登录流程。
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""

        guard scheme == "http" || scheme == "https" else {
            if navigationAction.navigationType == .linkActivated {
                openExternally(url)
            } else {
                record(.navigationBlocked("非用户点击的外部协议：\(scheme)"))
            }
            return nil
        }

        if let site {
            let sameSite = Self.originString(url) == site.origin
            let loginPopup = !site.isTest && Self.isAuthenticationURL(url)
            guard sameSite || loginPopup else {
                if site.isTest || navigationAction.navigationType != .linkActivated {
                    record(.navigationBlocked(url.absoluteString))
                } else {
                    openExternally(url)
                }
                return nil
            }
            // 同站弹窗和登录弹窗（很多登录/附件流程使用 target=_blank）
            // 留在这个席位里，保持用户当前登录态和同窗导航。
            webView.load(URLRequest(url: url))
            return nil
        }

        openExternally(url)
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = pageTitle ?? label
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = pageTitle ?? label
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = pageTitle ?? label
        alert.informativeText = prompt
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field

        let response = alert.runModal()
        completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // MARK: Helpers

    private func handleNavigationFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
            // 被策略改道（例如同站弹窗转到本席位）不是导航故障。
            return
        }
        isLoading = false
        documentReady = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        lastNavigationErrorCode = "\(nsError.domain)#\(nsError.code)"
        lastNavigationError = nsError.localizedDescription
        lastErrorCode = lastNavigationErrorCode
        lastError = nsError.localizedDescription
    }

    private func openExternally(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        // 只把用户明确点击的常规链接和系统通信链接交给系统；不打开 file:、
        // javascript: 或未知自定义协议。
        let safeSchemes: Set<String> = ["http", "https", "mailto", "tel", "sms"]
        guard safeSchemes.contains(scheme) else {
            record(.navigationBlocked("不支持的链接协议：\(scheme)"))
            return
        }
        if !NSWorkspace.shared.open(url) {
            record(.navigationBlocked("无法交给系统打开：\(url.absoluteString)"))
        }
    }

    private func isNavigationAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        if let site, site.isTest {
            return Self.originString(url) == site.origin
        }
        return true
    }

    private func record(_ error: SitePaneError) {
        lastErrorCode = error.code
        lastError = error.errorDescription ?? error.code
    }

    private func clearLastError() {
        lastError = nil
        lastErrorCode = nil
    }

    private func observeWebView() {
        keyValueObservations.append(
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                let value = webView.estimatedProgress
                Task { @MainActor [weak self] in
                    self?.estimatedProgress = value
                }
            }
        )
        keyValueObservations.append(
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                let value = webView.canGoBack
                Task { @MainActor [weak self] in
                    self?.canGoBack = value
                }
            }
        )
        keyValueObservations.append(
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                let value = webView.canGoForward
                Task { @MainActor [weak self] in
                    self?.canGoForward = value
                }
            }
        )
        keyValueObservations.append(
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                let value = webView.title
                Task { @MainActor [weak self] in
                    self?.pageTitle = value
                }
            }
        )
        keyValueObservations.append(
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                let value = webView.url
                Task { @MainActor [weak self] in
                    self?.currentURL = value
                }
            }
        )
    }

    // MARK: Static support

    private static func makeWebConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // 持久化是硬要求：用户在原站完成的登录由系统数据仓库保留。
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = false
        return configuration
    }

    private static func worldNameComponent(_ provider: String) -> String {
        let allowed = provider.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "_"
        }
        return String(String(allowed).prefix(64))
    }

    private static let selectorKeys: Set<String> = [
        "input", "send", "user", "answer", "stop", "done", "container",
    ]
    private static let requiredSelectorKeys: Set<String> = [
        "input", "send", "user", "answer",
    ]
    private static let optionNumberKeys: Set<String> = [
        "sampleMs", "stableSamples", "stableMs", "submitTimeoutMs", "sendEnableMs",
        "pollMs", "turnGraceMs", "pendingTimeoutMs", "previewChars",
    ]

    private static func isValidTaskID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$"#, options: .regularExpression) != nil
    }

    /// 精确 origin 比较：scheme + host + 有效端口；缺省端口规范化。
    nonisolated static func originString(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let rawHost = url.host?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        var host = rawHost
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }

        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port ?? defaultPort
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return port == defaultPort ? "\(scheme)://\(hostPart)" : "\(scheme)://\(hostPart):\(port)"
    }

    /// 允许被固定/持久化的会话地址（G3 白名单）：
    /// - 必须与登记站点同源（scheme + host + 有效端口）；
    /// - 丢弃账号、查询串和片段，只保留 origin + 规范化 path（因此持久化时
    ///   永远不会写入 token、会话 id 之外的查询参数或锚点）；
    /// - 路径像登录/授权/回调页的一律不保存；
    /// - 规范化后超长的一律不保存。
    /// 任何不满足的地址返回 nil，调用方据此“不绑定、不保存”，而不是存半截。
    nonisolated static func canonicalConversationURL(_ url: URL, origin: String) -> URL? {
        guard let actualOrigin = originString(url), actualOrigin == origin else { return nil }
        guard url.user == nil, url.password == nil else { return nil }

        var path = url.path
        if path.isEmpty { path = "/" }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard path.count <= 1000, !path.contains("//") else { return nil }

        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map {
            $0.lowercased()
        }
        let authenticationSegments: Set<String> = [
            "auth", "authorize", "callback", "login", "logout", "oauth",
            "signin", "sign-in", "signout", "sign-out", "sso",
        ]
        guard !segments.contains(where: authenticationSegments.contains) else { return nil }

        return URL(string: origin + path)
    }

    /// JS `location` 与 WebKit 记录的地址是否指向同一个文档：同源且规范化
    /// 路径一致。query/片段常被站点自身改写，不作为“换页”依据。
    nonisolated static func documentLocationsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let leftOrigin = originString(lhs),
              let rightOrigin = originString(rhs),
              leftOrigin == rightOrigin
        else { return false }
        return normalizedPath(lhs.path) == normalizedPath(rhs.path)
    }

    nonisolated static func normalizedPath(_ path: String) -> String {
        var value = path.isEmpty ? "/" : path
        if !value.hasPrefix("/") { value = "/" + value }
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// query 阶段最多一次自动导航的目标：
    /// - 本席已固定会话：只允许精确回到该会话，且当前地址仍与它一致；
    /// - 从未固定会话（还没开始）：只允许回到本站允许的新对话入口；
    /// - 其它情况返回 nil，宁可转人工也不猜目的地。
    nonisolated static func probeRecoveryNavigationTarget(
        current: URL?,
        bound: URL?,
        siteOrigin: String,
        homePath: String,
        provider: String,
        isTest: Bool
    ) -> URL? {
        if let bound {
            guard let canonicalBound = canonicalConversationURL(bound, origin: siteOrigin),
                  isConversationURL(
                    canonicalBound,
                    provider: provider,
                    homePath: homePath,
                    isTest: isTest
                  )
            else { return nil }
            if let current {
                guard let canonicalCurrent = canonicalConversationURL(current, origin: siteOrigin),
                      canonicalCurrent.absoluteString == canonicalBound.absoluteString
                else { return nil }
            }
            return canonicalBound
        }

        guard let current,
              let canonicalCurrent = canonicalConversationURL(current, origin: siteOrigin)
        else { return nil }
        let root = normalizedPath(homePath)
        let isPermittedRoot = canonicalCurrent.path == root
            || (provider == "deepseek" && canonicalCurrent.path == "/a/chat")
        return isPermittedRoot ? canonicalCurrent : nil
    }

    /// 已确认的瞬态网络导航失败。离线（-1009）、证书（-1200…-1207）、
    /// 认证与取消都不在其中：这些需要人来处理，自动导航解决不了问题，
    /// 还会反复打断站点。
    nonisolated static func isRecoverableTransientNavigationFailure(_ raw: String?) -> Bool {
        let prefix = "NSURLErrorDomain#"
        guard let raw, raw.hasPrefix(prefix),
              let code = Int(raw.dropFirst(prefix.count))
        else { return false }
        switch code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed:
            return true
        default:
            return false
        }
    }

    /// 需要人工处理的导航失败：离线与证书/认证。即使内容进程随后被终止，
    /// 也不自动导航，避免反复打断站点或掩盖需要用户登录/信任证书的问题。
    nonisolated static func isHumanRequiredNavigationFailure(_ raw: String?) -> Bool {
        let prefix = "NSURLErrorDomain#"
        guard let raw, raw.hasPrefix(prefix),
              let code = Int(raw.dropFirst(prefix.count))
        else { return false }
        switch code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired,
             NSURLErrorUserAuthenticationRequired,
             NSURLErrorUserCancelledAuthentication:
            return true
        default:
            return false
        }
    }

    private static func isLoopbackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost"
            || host == "::1"
            || host == "0:0:0:0:0:0:0:1"
            || host.hasPrefix("127.")
    }

    private static func isAuthenticationURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let exact = [
            "accounts.google.com",
            "auth.openai.com",
            "auth0.openai.com",
            "login.microsoftonline.com",
            "login.live.com",
            "appleid.apple.com",
        ]
        if exact.contains(host) { return true }
        return host.hasSuffix(".google.com")
            || host.hasSuffix(".openai.com")
            || host.hasSuffix(".microsoftonline.com")
            || host.hasSuffix(".apple.com")
    }

    // MARK: Site registry (mirrors extension/provider-web-configs.js)

    private struct SiteDescriptor {
        let provider: String
        let label: String
        let homeURL: URL
        let origin: String
        let selectors: [String: [String]]
        let options: [String: Any]
        let allowNavigation: Bool
        let isTest: Bool
    }

    private struct Resolution {
        let site: SiteDescriptor?
        let error: SitePaneError?
    }

    private static func resolveSite(provider: String, testConfiguration: TestConfiguration?) -> Resolution {
        if let test = testConfiguration {
            guard let scheme = test.loopbackURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  isLoopbackURL(test.loopbackURL),
                  let origin = originString(test.loopbackURL)
            else {
                return Resolution(
                    site: nil,
                    error: .invalidTestOrigin(test.loopbackURL.absoluteString)
                )
            }

            // 测试页自带精确选择器：显式给了就完全替换，避免内置的 stop/done
            // 候选误命中测试页元素；没给才退回该站点的内置配置。
            let baseSelectors = test.selectors.isEmpty ? (builtInSelectors(provider) ?? [:]) : [:]
            let mergedSelectors: [String: [String]]
            do {
                mergedSelectors = try mergeSelectors(base: baseSelectors, override: test.selectors)
            } catch let error as SitePaneError {
                return Resolution(site: nil, error: error)
            } catch {
                return Resolution(site: nil, error: .invalidSelectors(error.localizedDescription))
            }

            let options = mergeOptions(
                base: builtInOptions(provider) ?? [:],
                override: test.options,
                provided: true
            )

            return Resolution(
                site: SiteDescriptor(
                    provider: provider,
                    label: test.label ?? "\(displayLabel(provider)) · 测试",
                    homeURL: test.loopbackURL,
                    origin: origin,
                    selectors: mergedSelectors,
                    options: options,
                    allowNavigation: test.allowNavigation,
                    isTest: true
                ),
                error: nil
            )
        }

        guard let home = builtInHome(provider),
              let origin = originString(home),
              origin.hasPrefix("https://"),
              let selectors = builtInSelectors(provider),
              let options = builtInOptions(provider)
        else {
            return Resolution(site: nil, error: .unsupportedProvider(provider))
        }

        return Resolution(
            site: SiteDescriptor(
                provider: provider,
                label: displayLabel(provider),
                homeURL: home,
                origin: origin,
                selectors: selectors,
                options: options,
                allowNavigation: true,
                isTest: false
            ),
            error: nil
        )
    }

    private static func displayLabel(_ provider: String) -> String {
        switch provider {
        case "chatgpt": return "ChatGPT"
        case "gemini": return "Gemini"
        case "deepseek": return "DeepSeek"
        default: return provider
        }
    }

    private static func builtInHome(_ provider: String) -> URL? {
        switch provider {
        case "chatgpt": return URL(string: "https://chatgpt.com/")
        case "gemini": return URL(string: "https://gemini.google.com/app")
        case "deepseek": return URL(string: "https://chat.deepseek.com/")
        default: return nil
        }
    }

    // build.sh packages the registry used by the browser extension.
    private static let bundledAdapters: [String: [String: Any]] = {
        guard let url = Bundle.main.url(forResource: "sites", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let sites = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [:] }
        return sites
    }()

    private static func builtInSelectors(_ provider: String) -> [String: [String]]? {
        bundledAdapters[provider]?["selectors"] as? [String: [String]]
    }

    private static func builtInOptions(_ provider: String) -> [String: Any]? {
        bundledAdapters[provider]?["options"] as? [String: Any]
    }

}

// MARK: - Serial command gate

/// 同一席位的 probe/read/submit 串行执行，防止同一页面上两个命令互相看见
/// 对方尚未完成的填写或采样。跨席位互不影响。
private actor CommandGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
