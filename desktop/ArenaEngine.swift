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

import CryptoKit
import Foundation
import ImageIO
import JavaScriptCore

// MARK: - Errors

struct ArenaEngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Build isolation

/// The packaged app keeps the personal profile (`local.ai-arena.desktop`).
///
/// Local regression tests stage a disposable, re-signed copy under the QA
/// identifier. That copy must never read the live history or reach a consumer
/// site: WebKit storage follows the bundle identifier, and the default store
/// directory is the separate "AI Arena QA" folder. Only explicit loopback
/// fixtures may load pages in a QA build.
enum ArenaBuildIsolation {
    /// Kept in sync with `QA_BUNDLE_ID` in `tests/qa_app.py`.
    static let qaBundleIdentifier = "local.ai-arena.desktop.qa"
    static let qaSupportDirectoryName = "AI Arena QA"

    static var isQABuild: Bool {
        Bundle.main.bundleIdentifier == qaBundleIdentifier
    }
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

// MARK: - Opening attachments

struct ArenaDraftAttachment: Identifiable {
    enum Kind: String { case image, text }

    static let maxCount = 8
    static let maxImageBytes = 8 * 1024 * 1024
    static let maxTextBytes = 24 * 1024
    static let maxTotalBytes = 24 * 1024 * 1024

    let id = UUID().uuidString
    let name: String
    let kind: Kind
    let mediaType: String
    let data: Data
    let text: String?
    let sha256: String

    init(fileURL: URL) throws {
        guard fileURL.isFileURL else { throw ArenaEngineError("请选择本地文件") }
        let metadata = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true else { throw ArenaEngineError("请选择普通文件") }
        let limit = try Self.format(fileURL.lastPathComponent).limit
        guard let size = metadata.fileSize, size <= limit else {
            throw ArenaEngineError("文件过大：\(fileURL.lastPathComponent)")
        }
        // Bound the read even if another app replaces/grows the file after stat.
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        try self.init(name: fileURL.lastPathComponent, data: bytes)
    }

    init(name: String, data: Data) throws {
        guard Self.safeName(name) else { throw ArenaEngineError("附件名称无效，请先重命名") }
        let format = try Self.format(name)
        guard !data.isEmpty, data.count <= format.limit else {
            throw ArenaEngineError("文件为空或超过上限：\(name)")
        }
        if format.kind == .text {
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                throw ArenaEngineError("文本附件须使用 UTF-8 编码：\(name)")
            }
            self.text = text
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let sourceType = CGImageSourceGetType(source) as String?,
                  sourceType == (format.mediaType == "image/png" ? "public.png" : "public.jpeg"),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 40_000_000 / height else {
                throw ArenaEngineError("图片格式无效或超过 4000 万像素：\(name)")
            }
            self.text = nil
        }
        self.name = name
        self.kind = format.kind
        self.mediaType = format.mediaType
        self.data = data
        self.sha256 = Self.digest(data)
    }

    static func validate(_ items: [ArenaDraftAttachment]) throws {
        guard items.count <= maxCount else { throw ArenaEngineError("每场最多添加 8 个附件") }
        guard Set(items.map(\.id)).count == items.count else { throw ArenaEngineError("附件记录重复") }
        guard items.reduce(0, { $0 + $1.data.count }) <= maxTotalBytes else {
            throw ArenaEngineError("附件总量超过 24 MiB")
        }
        guard items.filter({ $0.kind == .text }).reduce(0, { $0 + $1.data.count }) <= maxTextBytes else {
            throw ArenaEngineError("文本附件合计超过 24 KiB，请缩小材料范围")
        }
    }

    fileprivate static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." &&
            name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)) == nil
    }

    private static func format(_ name: String) throws -> (kind: Kind, mediaType: String, limit: Int) {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return (.image, "image/png", maxImageBytes)
        case "jpeg", "jpg": return (.image, "image/jpeg", maxImageBytes)
        case "txt": return (.text, "text/plain", maxTextBytes)
        case "md": return (.text, "text/markdown", maxTextBytes)
        case "csv": return (.text, "text/csv", maxTextBytes)
        default: throw ArenaEngineError("当前支持 PNG、JPEG、TXT、MD、CSV：\(name)")
        }
    }

    /// Stable names in manifest, on disk and in the website's sent message.
    /// Distinguish two screenshots with the same Finder name (case-insensitively).
    static func inputRecords(_ items: [ArenaDraftAttachment]) throws -> [[String: Any]] {
        try validate(items)
        var names = Set<String>()
        return items.map { item in
            var name = item.name
            var suffix = 2
            while !names.insert(name.lowercased()).inserted {
                let original = item.name as NSString
                var stem = original.deletingPathExtension
                let tail = "-\(suffix).\(original.pathExtension)"
                while (stem + tail).utf8.count > 255 { stem.removeLast() }
                name = stem + tail
                suffix += 1
            }
            var record: [String: Any] = [
                "id": item.id, "name": name, "kind": item.kind.rawValue, "mediaType": item.mediaType,
                "byteCount": item.data.count, "sha256": item.sha256,
            ]
            if name != item.name { record["originalName"] = item.name }
            if let text = item.text { record["text"] = text }
            return record
        }
    }
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

    /// `true` once this task spent its one bounded read-only reload. Optional
    /// with a default so sessions saved before the field still decode; `nil`
    /// means "not attempted yet". It lives on the intent because a restart must
    /// not hand the same task a second reload it already used.
    var reloadAttempted: Bool? = nil

    /// `true` once this task spent its one bounded automatic return to the
    /// saved conversation after a same-origin drift. Never authorises a send or
    /// a read-only claim by itself; it only stops repeated navigation.
    var driftReturnAttempted: Bool? = nil

    /// The driver verified that it wrote this prompt before the send control
    /// became available. Older records can still prove ownership via a receipt.
    var composerFilled: Bool? = nil

    var attachmentReceipt: String? = nil
    var imagePreparationStarted: Bool? = nil
    /// Positional SHA-256 proofs for anonymous page previews. Absent on older saves.
    var imagePixelDigests: [String]? = nil
}

// MARK: - Persisted session file

/// One saved discussion as shown in the history menu. The stage and outcome
/// are read from the saved session document, never from the current UI state,
/// so a history row stays truthful after the live workbench moved on.
struct ArenaHistorySummary: Identifiable {
    let id: String
    let question: String
    let createdAt: Double
    let updatedAt: Double
    let stage: String
    let round: Int
    let stopReason: String?
    let hasReport: Bool
    let paused: Bool
    /// Seats actually saved in the session document, in participant order.
    /// Derived locally so history search can match a seat without opening a
    /// page or building an index.
    let providers: [String]

    var isFinished: Bool { stage == "done" }
}

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
            let name = ArenaBuildIsolation.isQABuild
                ? ArenaBuildIsolation.qaSupportDirectoryName
                : "AI Arena"
            directory = base.appendingPathComponent(name, isDirectory: true)
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

    /// Commit the whole ordered bundle before exposing the new session to dispatch.
    /// The random staging directory lives beside the destination for an atomic rename.
    func saveAttachments(_ items: [ArenaDraftAttachment], records: [[String: Any]], sessionID: String) throws {
        guard !items.isEmpty else { return }
        guard validID(sessionID), records.count == items.count else { throw ArenaEngineError("场次附件清单无效") }
        let base = root.resolvingSymlinksInPath().appendingPathComponent("attachments", isDirectory: true)
        guard base.resolvingSymlinksInPath().path == base.path else {
            throw ArenaEngineError("附件保存目录异常")
        }
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = base.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: staged) }
        for (item, record) in zip(items, records) {
            guard let name = record["name"] as? String, ArenaDraftAttachment.safeName(name),
                  record["id"] as? String == item.id else { throw ArenaEngineError("附件清单不匹配") }
            let folder = staged.appendingPathComponent(item.id, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            try item.data.write(to: folder.appendingPathComponent(name))
        }
        try fileManager.moveItem(at: staged, to: base.appendingPathComponent(sessionID, isDirectory: true))
    }

    func attachmentData(sessionID: String, attachment: [String: Any]) throws -> Data {
        try verifiedAttachment(sessionID: sessionID, attachment: attachment).bytes
    }

    func attachmentURL(sessionID: String, attachment: [String: Any]) throws -> URL {
        try verifiedAttachment(sessionID: sessionID, attachment: attachment).url
    }

    private func verifiedAttachment(sessionID: String, attachment: [String: Any]) throws -> (url: URL, bytes: Data) {
        guard validID(sessionID), let id = attachment["id"] as? String,
              UUID(uuidString: id) != nil, let name = attachment["name"] as? String,
              ArenaDraftAttachment.safeName(name), let expected = attachment["sha256"] as? String,
              let count = attachment["byteCount"] as? Int, (1...ArenaDraftAttachment.maxImageBytes).contains(count) else {
            throw ArenaEngineError("保存的附件清单无效")
        }
        let url = root.resolvingSymlinksInPath().appendingPathComponent("attachments")
            .appendingPathComponent(sessionID).appendingPathComponent(id).appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().path == url.path,
              let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              info.isRegularFile == true, info.fileSize == count,
              let file = try? FileHandle(forReadingFrom: url) else {
            throw ArenaEngineError("附件丢失或已更改：\(name)")
        }
        defer { try? file.close() }
        let bytes = try file.read(upToCount: count + 1) ?? Data()
        guard bytes.count == count, ArenaDraftAttachment.digest(bytes) == expected else {
            throw ArenaEngineError("附件内容已更改：\(name)")
        }
        return (url, bytes)
    }

    private var currentURL: URL {
        root.appendingPathComponent("current.json", isDirectory: false)
    }

    /// Atomic save; returns a human-readable error instead of throwing so the
    /// model can pause dispatch without losing the in-memory session.
    ///
    /// `updateCurrent` is false for an incremental write to the session that is
    /// already the pinned current one (a user condition added mid-discussion).
    /// Then the scene file is replaced in one atomic write and `current.json`
    /// is left untouched, so a pointer-only failure can never make a committed
    /// note look unsaved (or vice versa). Every other caller keeps the default
    /// and still writes both files.
    @discardableResult
    func save(_ file: ArenaSessionFile, updateCurrent: Bool = true) -> String? {
        guard let url = fileURL(for: file.id) else {
            return "场次编号无效，无法保存"
        }
        do {
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            return "本地保存失败：\(error.localizedDescription)"
        }
        guard updateCurrent else { return nil }
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

    func loadEvaluation(sessionID: String) throws -> ArenaEvaluation? {
        guard let url = evaluationURL(sessionID: sessionID) else { throw EvaluationInputError("场次编号无效") }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ArenaEvaluation.self, from: Data(contentsOf: url))
    }

    func saveEvaluation(_ evaluation: ArenaEvaluation, sessionID: String) throws {
        guard let url = evaluationURL(sessionID: sessionID), load(id: sessionID) != nil else {
            throw EvaluationInputError("找不到已保存的场次")
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(evaluation).write(to: url, options: .atomic)
    }

    private func evaluationURL(sessionID: String) -> URL? {
        guard validID(sessionID) else { return nil }
        return root.appendingPathComponent("evaluations", isDirectory: true)
            .appendingPathComponent("\(sessionID).json", isDirectory: false)
    }

    func setCurrent(_ id: String?) {
        if let id, validID(id) {
            guard let data = try? encoder.encode(CurrentPointer(id: id)) else { return }
            try? data.write(to: currentURL, options: .atomic)
        } else {
            try? fileManager.removeItem(at: currentURL)
        }
    }

    func summaries() -> [ArenaHistorySummary] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var result: [ArenaHistorySummary] = []
        for name in names where name.hasSuffix(".json") && name != "current.json" {
            let url = root.appendingPathComponent(name, isDirectory: false)
            guard let data = try? Data(contentsOf: url),
                  let file = try? decoder.decode(ArenaSessionFile.self, from: data) else {
                continue
            }
            result.append(summary(for: file, session: Self.sessionDocument(file.sessionJSON)))
        }
        return Self.newestFirst(result)
    }

    /// The one summary projection. A full read passes the parsed `sessionJSON`
    /// document; a caller that already holds the just-saved file and its parsed
    /// session passes those instead, so both produce the identical row without
    /// a second file read. `session` is nil only for an unparseable document,
    /// which keeps the historical schema defaults below.
    func summary(for file: ArenaSessionFile, session: [String: Any]?) -> ArenaHistorySummary {
        ArenaHistorySummary(
            id: file.id,
            question: file.question,
            createdAt: file.createdAt,
            updatedAt: file.updatedAt,
            stage: session?.arenaString("stage") ?? "",
            round: session?.arenaInt("round") ?? 1,
            stopReason: session?.arenaString("stopReason"),
            hasReport: session?.arenaString("report")?.isEmpty == false,
            paused: session?.arenaBool("paused") ?? false,
            providers: session?.arenaStringArray("providers") ?? []
        )
    }

    /// Newest-first order shared by the full read and the post-save upsert, so
    /// a freshly saved row lands exactly where a re-read would place it.
    private static func newestFirst(_ items: [ArenaHistorySummary]) -> [ArenaHistorySummary] {
        items.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Replace (or insert) one durable summary in the newest-first list the
    /// caller already holds. Pure: no file access, and the caller keeps the
    /// only cache.
    static func upserting(
        _ summary: ArenaHistorySummary,
        into items: [ArenaHistorySummary]
    ) -> [ArenaHistorySummary] {
        newestFirst(items.filter { $0.id != summary.id } + [summary])
    }

    private static func sessionDocument(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }
}

// MARK: - JavaScript core bridge

/// Hosts `arena-core.js`.
///
/// The shipped resource is already a plain script exposing global
/// `createSession` / `applyAction` (plus the `reportBallot` /
/// `reviewMaterials` helpers): `desktop/build.sh` strips the ES-module
/// `import`/`export` syntax from `shared/providers.js` and `shared/core.js`
/// while writing the bundle resource. This bridge evaluates that script
/// as-is and lets only JSON text cross the boundary.
@MainActor
final class ArenaCore {
    private let context: JSContext

    init(bundle: Bundle) throws {
        guard let url = bundle.url(forResource: "arena-core", withExtension: "js") else {
            throw ArenaEngineError("缺少 arena-core.js（应用包资源）")
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
                globalThis.__arenaCreate = function (question, providersJSON, maxRounds, attachmentsJSON) {
                  return JSON.stringify(
                    createSession(question, JSON.parse(providersJSON), { maxRounds, attachments: JSON.parse(attachmentsJSON) })
                  );
                };
                globalThis.__arenaReportBallot = function (historyJSON) {
                  const { proposal, version, votes } = reportBallot(JSON.parse(historyJSON));
                  return JSON.stringify({
                    candidateID: proposal?.id, version,
                    votes: proposal ? votes.map(({ id, provider, stance }) => ({ id, provider, stance })) : []
                  });
                };
                globalThis.__arenaReviewMaterials = function (sessionJSON) {
                  return JSON.stringify(reviewMaterials(JSON.parse(sessionJSON)));
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

    func createSession(
        question: String,
        providers: [String],
        maxRounds: Int,
        records: [[String: Any]]
    ) throws -> [String: Any] {
        let providersJSON = try Self.jsonString(providers)
        return try callBridge(
            "__arenaCreate",
            arguments: [question, providersJSON, maxRounds, try Self.jsonString(records)],
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

    func reportBallot(history: [[String: Any]]) throws -> [String: Any] {
        try callBridge("__arenaReportBallot", arguments: [Self.jsonString(history)], label: "reportBallot")
    }

    func reviewMaterials(session: [String: Any]) throws -> [String: Any] {
        try callBridge("__arenaReviewMaterials", arguments: [Self.jsonString(session)], label: "reviewMaterials")
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

    func createSession(
        question: String,
        providers: [String],
        maxRounds: Int,
        attachments: [ArenaDraftAttachment] = []
    ) throws -> [String: Any] {
        let records = try ArenaDraftAttachment.inputRecords(attachments)
        let session = try loadedCore().createSession(
            question: question,
            providers: providers,
            maxRounds: maxRounds,
            records: records
        )
        guard let id = session["id"] as? String else { throw ArenaEngineError("场次编号缺失") }
        try store.saveAttachments(attachments, records: records, sessionID: id)
        return session
    }

    func reportBallot(history: [[String: Any]]) throws -> [String: Any] {
        try loadedCore().reportBallot(history: history)
    }

    func reviewMaterials(session: [String: Any]) throws -> [String: Any] {
        try loadedCore().reviewMaterials(session: session)
    }

    func apply(
        session: [String: Any],
        action: String,
        payload: [String: Any]
    ) throws -> [String: Any] {
        try loadedCore().apply(session: session, action: action, payload: payload)
    }

    /// Historical text stays in the local store. The composer is most likely
    /// to restore an independent prompt on the site entry page, so give those
    /// priority when later rounds would otherwise fill all eight slots.
    func knownDraftDigests(provider: String, previousSessionIDs: [String]) -> [String] {
        var firstPrompts: [String] = []
        var laterPrompts: [String] = []
        for id in previousSessionIDs.prefix(8) {
            guard let file = store.load(id: id), file.id == id else { continue }
            for intent in file.intents.sorted(by: { $0.preparedAt > $1.preparedAt }) {
                guard intent.taskId == "\(id):r\(intent.round):\(intent.stage):\(provider)",
                      intent.phase == .submitted || intent.composerFilled == true else { continue }
                if intent.stage == "independent" {
                    firstPrompts.append(intent.prompt)
                } else {
                    laterPrompts.append(intent.prompt)
                }
            }
        }
        var digests: [String] = []
        for prompt in firstPrompts + laterPrompts {
            // Same normalization as collapse() in web-driver.js, including
            // ECMAScript whitespace (which differs from Foundation's set).
            let normalized = prompt
                .replacingOccurrences(of: #"[\u200b-\u200d\ufeff]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+"#,
                                      with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " "))
            guard !normalized.isEmpty else { continue }
            let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
            if !digests.contains(digest) { digests.append(digest) }
            if digests.count == 8 { break }
        }
        return digests
    }

    /// The exact message shape `web-driver.js` documents. `scope.origin`,
    /// `scope.homeHref` and `allowNavigation` are always explicit so a fixture
    /// page can never be accepted on a real-site origin and vice versa.
    func driverMessage(
        kind: String,
        taskID: String,
        prompt: String?,
        verifiedReadPrompt: String? = nil,
        knownDraftDigests: [String] = [],
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
        if kind == "submit", !knownDraftDigests.isEmpty {
            message["knownDraftDigests"] = knownDraftDigests
        }
        if kind == "read", let verifiedReadPrompt {
            message["verifiedReadPrompt"] = verifiedReadPrompt
        }
        return message
    }

    /// The exact original prompt a `read` may carry for a read-only rebuild.
    ///
    /// Only a click that may already have reached the page (`inflight`,
    /// `uncertain`, or `submitted`) can authorise this. A `prepared` intent was
    /// recorded *before* the submit command was issued, so it must never turn a
    /// read into an "already sent" claim; a missing intent has no evidence at
    /// all. The web-driver still requires a stable conversation binding, an
    /// exact full-text match, an answer strictly after that turn, and a live
    /// completion signal before reporting anything as done.
    nonisolated static func readRecoveryPrompt(
        phase: ArenaDeliveryIntent.Phase?,
        prompt: String?
    ) -> String? {
        guard let phase, phase != .prepared else { return nil }
        guard let prompt else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, prompt.count <= 100_000,
              !prompt.unicodeScalars.contains("\u{0}") else { return nil }
        return prompt
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

        // 验收副本只用于回环夹具。普通双击打开时既不加载真实站点，也读不到
        // 本机个人历史（存储目录已在 ArenaSessionStore 中分开）。
        if ArenaBuildIsolation.isQABuild, fixtureBase == nil {
            sitesFailure = "这是 AI Arena QA 验收副本：只连接 http://127.0.0.1 回环夹具，不加载真实站点或本机历史。"
            return
        }

        guard let url = bundle.url(forResource: "sites", withExtension: "json") else {
            sitesFailure = "缺少 sites.json（应用包资源）"
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
        for key in ["input", "send", "user", "answer", "stop", "done", "container", "attachmentComposer"] {
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
