//
//  ArenaEngine.swift
//  AI Arena desktop (G1/G3)
//
//  Infrastructure used by `ArenaModel`:
//    - `ArenaCore`: runs the bundle's `arena-core.js` state machine through
//      JavaScriptCore. All data crosses the boundary as JSON text, never as a
//      Swift <-> JS object graph and never as interpolated code.
//    - `ArenaSiteRegistry`: reads the bundle's `sites.json` and applies the
//      controlled `ARENA_FIXTURE_BASE` override (http://127.0.0.1 only).
//    - `ArenaSessionStore`: atomic, local-only persistence of the session plus
//      delivery intents, manual takeovers and the task's original page URL.
//
//  This file owns no UI. Round scheduling and failure handling live in
//  `ArenaModel.swift`.
//

import Foundation
import JavaScriptCore

// MARK: - Errors

struct ArenaEngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Site configuration

/// One seat's web adapter, normalised from `sites.json`.
///
/// `selectors` / `options` are passed verbatim to the page driver. They are
/// kept as `[String: Any]` because the driver owns their validation and
/// defaults; the desktop side only checks that the four required selector keys
/// exist and that the entry URL is an ordinary HTTP(S) page.
struct ArenaSiteConfig {
    let provider: String
    let label: String
    let url: URL
    let origin: String
    let selectors: [String: Any]
    let options: [String: Any]
    let allowNavigation: Bool

    var homeHref: String { url.absoluteString }
}

// MARK: - Delivery intents

/// A persisted statement of what the app intended to send, written *before*
/// the page command runs.
///
/// Phase changes are the only thing that may authorise a retry:
///   prepared  – intent recorded, submit command not yet issued (safe)
///   inflight  – submit command issued; outcome still unknown
///   submitted – the page confirmed this round's user message (read-only)
///   uncertain – the driver reported `submit-unconfirmed`; never resend
struct ArenaDeliveryIntent: Codable, Equatable {
    enum Phase: String, Codable {
        case prepared
        case inflight
        case submitted
        case uncertain
    }

    var taskId: String
    var prompt: String
    var stage: String
    var round: Int
    var phase: Phase
    var preparedAt: Double
    var submittedAt: Double?
    var pageURL: String?
}

// MARK: - Persisted session file

struct ArenaSessionFile: Codable {
    var version: Int
    var id: String
    var question: String
    var createdAt: Double
    var updatedAt: Double
    var sessionJSON: String
    var intents: [ArenaDeliveryIntent]
    var manualProviders: [String]
    var pageURLs: [String: String]
    var stopReason: String?
}

// MARK: - Local store

/// Application Support (or `ARENA_DATA_DIR`) storage. Every write is a single
/// atomic file replacement, so an interrupted save leaves the previous
/// complete record instead of a half-written one.
final class ArenaSessionStore {
    let root: URL
    private(set) var setupError: String?

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private struct CurrentPointer: Codable {
        var id: String
    }

    init() {
        let environment = ProcessInfo.processInfo.environment
        var directory: URL
        if let raw = environment["ARENA_DATA_DIR"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            directory = URL(
                fileURLWithPath: (raw as NSString).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            directory = base.appendingPathComponent("AI Arena", isDirectory: true)
        }
        self.root = directory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            setupError = "无法创建本地数据目录：\(error.localizedDescription)"
        }
    }

    private func validID(_ id: String) -> Bool {
        id.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$",
            options: .regularExpression
        ) != nil
    }

    private func fileURL(for id: String) -> URL? {
        guard validID(id) else { return nil }
        return root.appendingPathComponent("\(id).json", isDirectory: false)
    }

    private var currentURL: URL {
        root.appendingPathComponent("current.json", isDirectory: false)
    }

    /// Atomic save; returns a human-readable error instead of throwing so the
    /// model can pause dispatch without losing the in-memory session.
    @discardableResult
    func save(_ file: ArenaSessionFile) -> String? {
        guard let url = fileURL(for: file.id) else {
            return "场次编号无效，无法保存"
        }
        do {
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            return "本地保存失败：\(error.localizedDescription)"
        }
        do {
            let data = try encoder.encode(CurrentPointer(id: file.id))
            try data.write(to: currentURL, options: .atomic)
        } catch {
            return "本地当前场次标记保存失败：\(error.localizedDescription)"
        }
        return nil
    }

    func load(id: String) -> ArenaSessionFile? {
        guard let url = fileURL(for: id),
              let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(ArenaSessionFile.self, from: data) else {
            return nil
        }
        return file
    }

    func currentID() -> String? {
        guard let data = try? Data(contentsOf: currentURL),
              let pointer = try? decoder.decode(CurrentPointer.self, from: data),
              validID(pointer.id) else {
            return nil
        }
        return pointer.id
    }

    func setCurrent(_ id: String?) {
        if let id, validID(id) {
            guard let data = try? encoder.encode(CurrentPointer(id: id)) else { return }
            try? data.write(to: currentURL, options: .atomic)
        } else {
            try? fileManager.removeItem(at: currentURL)
        }
    }

    func summaries() -> [(id: String, question: String, updatedAt: Double)] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var result: [(id: String, question: String, updatedAt: Double)] = []
        for name in names where name.hasSuffix(".json") && name != "current.json" {
            let url = root.appendingPathComponent(name, isDirectory: false)
            guard let data = try? Data(contentsOf: url),
                  let file = try? decoder.decode(ArenaSessionFile.self, from: data) else {
                continue
            }
            result.append((id: file.id, question: file.question, updatedAt: file.updatedAt))
        }
        result.sort { $0.updatedAt > $1.updatedAt }
        return result
    }
}

// MARK: - Resource lookup

enum ArenaResource {
    static func url(name: String, extension ext: String, bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: ext)
    }
}

// MARK: - JavaScript core bridge

/// Hosts `arena-core.js`.
///
/// `arena-core.js` may be shipped either as a plain script exposing global
/// `createSession` / `applyAction`, or as a copy of the ES module with
/// `import`/`export` syntax. The latter is normalised here (module keywords
/// removed, provider-id constants supplied) so the two shapes share one
/// bridge. Only JSON text crosses the boundary.
@MainActor
final class ArenaCore {
    private let context: JSContext

    init(bundle: Bundle) throws {
        guard let url = ArenaResource.url(
            name: "arena-core",
            extension: "js",
            bundle: bundle
        ) else {
            throw ArenaEngineError("缺少 arena-core.js（应用包或 desktop/ 目录）")
        }
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ArenaEngineError("无法读取 arena-core.js：\(error.localizedDescription)")
        }
        guard let context = JSContext() else {
            throw ArenaEngineError("无法创建 JavaScriptCore 上下文")
        }
        self.context = context
        context.exception = nil

        do {
            try evaluate(source)
        } catch {
            throw ArenaEngineError("arena-core.js 载入失败：\(error.localizedDescription)")
        }
        for name in ["createSession", "applyAction"] {
            let value = context.objectForKeyedSubscript(name)
            guard let value, !value.isUndefined, !value.isNull else {
                throw ArenaEngineError("arena-core.js 未提供全局 \(name)")
            }
        }
        do {
            try evaluate(
                """
                globalThis.__arenaCreate = function (question, providersJSON) {
                  return JSON.stringify(createSession(question, JSON.parse(providersJSON)));
                };
                globalThis.__arenaApply = function (sessionJSON, action, payloadJSON) {
                  return JSON.stringify(
                    applyAction(JSON.parse(sessionJSON), action, JSON.parse(payloadJSON))
                  );
                };
                """
            )
        } catch {
            throw ArenaEngineError("arena-core.js 桥接失败：\(error.localizedDescription)")
        }
    }

    func createSession(question: String, providers: [String]) throws -> [String: Any] {
        let providersJSON = try Self.jsonString(providers)
        return try callBridge(
            "__arenaCreate",
            arguments: [question, providersJSON],
            label: "createSession"
        )
    }

    func apply(
        session: [String: Any],
        action: String,
        payload: [String: Any]
    ) throws -> [String: Any] {
        let sessionJSON = try Self.jsonString(session)
        let payloadJSON = try Self.jsonString(payload)
        return try callBridge(
            "__arenaApply",
            arguments: [sessionJSON, action, payloadJSON],
            label: "applyAction"
        )
    }

    // MARK: Private

    @discardableResult
    private func evaluate(_ script: String) throws -> JSValue {
        context.exception = nil
        let value = context.evaluateScript(script)
        if let exception = context.exception {
            context.exception = nil
            throw ArenaEngineError(exception.toString() ?? "未知脚本错误")
        }
        guard let value else {
            throw ArenaEngineError("脚本没有返回值")
        }
        return value
    }

    private func callBridge(
        _ name: String,
        arguments: [Any],
        label: String
    ) throws -> [String: Any] {
        context.exception = nil
        guard let function = context.objectForKeyedSubscript(name),
              !function.isUndefined else {
            throw ArenaEngineError("缺少桥接函数 \(name)")
        }
        let result = function.call(withArguments: arguments)
        if let exception = context.exception {
            context.exception = nil
            throw ArenaEngineError(Self.cleanMessage(exception.toString() ?? "\(label) 失败"))
        }
        guard let result, let text = result.toString(), !text.isEmpty else {
            throw ArenaEngineError("\(label) 未返回结果")
        }
        guard let data = text.data(using: .utf8) else {
            throw ArenaEngineError("\(label) 返回内容不是 UTF-8")
        }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data, options: [])
            guard let object = parsed as? [String: Any] else {
                throw ArenaEngineError("\(label) 返回的 JSON 不是对象")
            }
            return object
        } catch let error as ArenaEngineError {
            throw error
        } catch {
            throw ArenaEngineError("\(label) 返回的 JSON 无法解析：\(error.localizedDescription)")
        }
    }

    private static func jsonString(_ value: Any) throws -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [])
            guard let text = String(data: data, encoding: .utf8) else {
                throw ArenaEngineError("无法编码 JSON")
            }
            return text
        } catch let error as ArenaEngineError {
            throw error
        } catch {
            throw ArenaEngineError("无法编码桥接数据：\(error.localizedDescription)")
        }
    }

    private static func cleanMessage(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "脚本执行失败" : text
    }


}

// MARK: - Engine

/// Owns the bridge, the site registry and the store. It never talks to a
/// `SitePane`; `ArenaModel` builds driver messages from `ArenaSiteConfig` and
/// decides when a command may run.
@MainActor
final class ArenaEngine {
    let store: ArenaSessionStore
    private let bundle: Bundle

    private var core: ArenaCore?
    private var coreFailure: String?
    private var sites: [String: ArenaSiteConfig] = [:]
    private var siteProblems: [String: String] = [:]
    private(set) var sitesFailure: String?

    private(set) var fixtureBase: URL?
    private(set) var fixtureFailure: String?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        self.store = ArenaSessionStore()
        loadSites()
    }

    var configurationIssue: String? {
        fixtureFailure ?? sitesFailure ?? store.setupError
    }

    func config(for provider: String) throws -> ArenaSiteConfig {
        if let failure = fixtureFailure {
            throw ArenaEngineError(failure)
        }
        if let failure = sitesFailure {
            throw ArenaEngineError(failure)
        }
        if let config = sites[provider] {
            return config
        }
        if let problem = siteProblems[provider] {
            throw ArenaEngineError(problem)
        }
        throw ArenaEngineError("未登记的站点：\(provider)")
    }

    func hasConfig(for provider: String) -> Bool {
        fixtureFailure == nil && sitesFailure == nil && sites[provider] != nil
    }

    /// Providers with a usable page adapter, in the same order as the
    /// reference catalog (then any extras).
    var providerIDs: [String] {
        let preferred = ["chatgpt", "gemini", "deepseek"]
        let known = preferred.filter { sites[$0] != nil }
        let extras = sites.keys.filter { !preferred.contains($0) }.sorted()
        return known + extras
    }

    func createSession(question: String, providers: [String]) throws -> [String: Any] {
        try loadedCore().createSession(question: question, providers: providers)
    }

    func apply(
        session: [String: Any],
        action: String,
        payload: [String: Any]
    ) throws -> [String: Any] {
        try loadedCore().apply(session: session, action: action, payload: payload)
    }

    /// The exact message shape `web-driver.js` documents. `scope.origin`,
    /// `scope.homeHref` and `allowNavigation` are always explicit so a fixture
    /// page can never be accepted on a real-site origin and vice versa.
    func driverMessage(
        kind: String,
        taskID: String,
        prompt: String?,
        config: ArenaSiteConfig
    ) -> [String: Any] {
        var message: [String: Any] = [
            "type": "arena.web.\(kind)",
            "taskId": taskID,
            "selectors": config.selectors,
            "options": config.options,
            "scope": [
                "origin": config.origin,
                "homeHref": config.homeHref,
                "allowNavigation": config.allowNavigation,
            ],
        ]
        if let prompt {
            message["prompt"] = prompt
        }
        return message
    }

    // MARK: Site loading

    private func loadedCore() throws -> ArenaCore {
        if let core { return core }
        if let coreFailure { throw ArenaEngineError(coreFailure) }
        do {
            let created = try ArenaCore(bundle: bundle)
            core = created
            return created
        } catch {
            coreFailure = error.localizedDescription
            throw error
        }
    }

    private func loadSites() {
        let environment = ProcessInfo.processInfo.environment
        let fixtureRaw = environment["ARENA_FIXTURE_BASE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let fixtureRaw, !fixtureRaw.isEmpty {
            switch Self.parseFixtureBase(fixtureRaw) {
            case .success(let url):
                fixtureBase = url
            case .failure(let message):
                fixtureFailure = message.message
                sitesFailure = message.message
                return
            }
        }

        guard let url = ArenaResource.url(
            name: "sites",
            extension: "json",
            bundle: bundle
        ) else {
            sitesFailure = "缺少 sites.json（应用包或 desktop/ 目录）"
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            sitesFailure = "无法读取 sites.json：\(error.localizedDescription)"
            return
        }
        let rootObject: Any
        do {
            rootObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            sitesFailure = "sites.json 不是合法 JSON：\(error.localizedDescription)"
            return
        }
        guard let root = rootObject as? [String: Any] else {
            sitesFailure = "sites.json 顶层必须是对象"
            return
        }
        let entries = (root["sites"] as? [String: Any]) ?? root

        for (provider, rawValue) in entries {
            guard provider.range(
                of: "^[a-z0-9]+(?:[-_][a-z0-9]+)*$",
                options: .regularExpression
            ) != nil else {
                continue
            }
            guard let raw = rawValue as? [String: Any] else {
                siteProblems[provider] = "sites.json 中 \(provider) 的配置不是对象"
                continue
            }
            let label = (raw["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = (label?.isEmpty == false) ? label! : provider

            guard let selectors = Self.normalizeSelectors(raw["selectors"]) else {
                siteProblems[provider] = "\(display) 缺少输入/发送/用户/回答选择器"
                continue
            }
            let options = (raw["options"] as? [String: Any]) ?? [:]

            let pageURL: URL
            let allowNavigation: Bool
            if let fixtureBase {
                pageURL = Self.fixtureURL(base: fixtureBase, provider: provider)
                allowNavigation = (raw["allowNavigation"] as? Bool) ?? false
            } else {
                guard let rawURL = raw["url"] as? String,
                      let parsed = URL(string: rawURL),
                      parsed.scheme?.lowercased() == "https",
                      parsed.host?.isEmpty == false else {
                    siteProblems[provider] = "\(display) 的入口不是固定的 HTTPS 地址"
                    continue
                }
                pageURL = parsed
                allowNavigation = (raw["allowNavigation"] as? Bool) ?? false
            }

            guard let origin = Self.originString(pageURL) else {
                siteProblems[provider] = "\(display) 的入口地址无法得到来源"
                continue
            }
            sites[provider] = ArenaSiteConfig(
                provider: provider,
                label: display,
                url: pageURL,
                origin: origin,
                selectors: selectors,
                options: options,
                allowNavigation: allowNavigation
            )
        }

        if sites.isEmpty {
            sitesFailure = "sites.json 中没有可用的网页席位配置"
        }
    }

    private static func normalizeSelectors(_ raw: Any?) -> [String: Any]? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        var result: [String: Any] = [:]
        for key in ["input", "send", "user", "answer", "stop", "done", "container"] {
            guard let value = dictionary[key] else { continue }
            var list: [String] = []
            if let single = value as? String {
                let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { list = [trimmed] }
            } else if let array = value as? [Any] {
                list = array.compactMap { item in
                    guard let text = item as? String else { return nil }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            }
            if !list.isEmpty {
                result[key] = list
            }
        }
        for required in ["input", "send", "user", "answer"] where result[required] == nil {
            return nil
        }
        return result
    }

    private static func originString(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty,
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var origin = "\(scheme)://\(formattedHost)"
        if let port = url.port {
            origin += ":\(port)"
        }
        return origin
    }

    private static func fixtureURL(base: URL, provider: String) -> URL {
        var text = base.absoluteString
        if text.hasSuffix("/") {
            text += provider
        } else {
            text += "/" + provider
        }
        return URL(string: text) ?? base.appendingPathComponent(provider)
    }

    /// `ARENA_FIXTURE_BASE` is deliberately narrow: plain HTTP on 127.0.0.1.
    /// Anything else fails closed so a mis-set variable cannot send a fixture
    /// prompt to a real consumer site.
    private static func parseFixtureBase(_ raw: String) -> Result<URL, ArenaEngineError> {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http",
              components.host == "127.0.0.1",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else {
            return .failure(ArenaEngineError("ARENA_FIXTURE_BASE 只接受 http://127.0.0.1[:端口] 形式"))
        }
        return .success(url)
    }
}

// MARK: - Small JSON helpers

extension Dictionary where Key == String, Value == Any {
    func arenaString(_ key: String) -> String? {
        self[key] as? String
    }

    func arenaInt(_ key: String) -> Int? {
        if let number = self[key] as? NSNumber { return number.intValue }
        if let value = self[key] as? Int { return value }
        if let text = self[key] as? String { return Int(text) }
        return nil
    }

    func arenaBool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        if let number = self[key] as? NSNumber { return number.boolValue }
        return nil
    }

    func arenaDouble(_ key: String) -> Double? {
        if let number = self[key] as? NSNumber { return number.doubleValue }
        if let value = self[key] as? Double { return value }
        if let text = self[key] as? String { return Double(text) }
        return nil
    }

    func arenaStringArray(_ key: String) -> [String] {
        (self[key] as? [String]) ?? []
    }
}
