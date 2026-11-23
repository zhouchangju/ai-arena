// G1/G3. Run the compiled check with an isolated, empty ARENA_DATA_DIR.
import Foundation

@main
struct AttachmentStoreCheck {
    static func main() throws {
        guard ProcessInfo.processInfo.environment["ARENA_DATA_DIR"] != nil else {
            throw ArenaEngineError("test requires isolated ARENA_DATA_DIR")
        }
        let store = ArenaSessionStore()
        let source = store.root.appendingPathComponent("材料[1].txt")
        let original = Data("首行\n第二行".utf8)
        try original.write(to: source)
        let text = try ArenaDraftAttachment(fileURL: source)
        try FileManager.default.moveItem(at: source, to: store.root.appendingPathComponent("renamed.md"))
        try Data("new".utf8).write(to: source)
        precondition(text.data == original && text.text == String(data: original, encoding: .utf8))
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jTXkAAAAASUVORK5CYII=")!
        let first = try ArenaDraftAttachment(name: "shot.png", data: image)
        let second = try ArenaDraftAttachment(name: "SHOT.png", data: image)
        let drafts = [first, text, second]
        let records = try ArenaDraftAttachment.inputRecords(drafts)
        precondition(records.compactMap { $0["name"] as? String } == ["shot.png", "材料[1].txt", "SHOT-2.png"])
        try store.saveAttachments(drafts, records: records, sessionID: "test-session")
        let reopened = ArenaSessionStore()
        let bytes = try reopened.attachmentData(sessionID: "test-session", attachment: records[1])
        precondition(bytes == original)
        let saved = try reopened.attachmentURL(sessionID: "test-session", attachment: records[1])
        try Data(repeating: 0, count: original.count).write(to: saved)
        precondition((try? reopened.attachmentData(sessionID: "test-session", attachment: records[1])) == nil)
        precondition((try? reopened.attachmentURL(sessionID: "../escape", attachment: records[0])) == nil)
        let firstURL = try reopened.attachmentURL(sessionID: "test-session", attachment: records[0])
        let otherFile = store.root.appendingPathComponent("other.png")
        try image.write(to: otherFile)
        try FileManager.default.removeItem(at: firstURL)
        try FileManager.default.createSymbolicLink(at: firstURL, withDestinationURL: otherFile)
        precondition((try? reopened.attachmentData(sessionID: "test-session", attachment: records[0])) == nil)
        var badName = records[0]
        badName["name"] = "../source.txt"
        precondition((try? reopened.attachmentURL(sessionID: "test-session", attachment: badName)) == nil)
        precondition((try? ArenaDraftAttachment(name: "report.pdf", data: original)) == nil)
        precondition((try? ArenaDraftAttachment(name: "wrong.png", data: original)) == nil)
        precondition((try? ArenaDraftAttachment(name: "bad.md", data: Data([0xff]))) == nil)
        let overLimit = Data(repeating: 0x78, count: ArenaDraftAttachment.maxTextBytes + 1)
        precondition((try? ArenaDraftAttachment(name: "large.txt", data: overLimit)) == nil)
        let half = Data(repeating: 0x78, count: ArenaDraftAttachment.maxTextBytes / 2 + 1)
        let a = try ArenaDraftAttachment(name: "a.txt", data: half)
        let b = try ArenaDraftAttachment(name: "b.txt", data: half)
        precondition((try? ArenaDraftAttachment.validate([a, b])) == nil)

        let legacy = Data(#"{"version":1,"id":"legacy","question":"旧题","createdAt":1,"updatedAt":2,"sessionJSON":"{}","intents":[{"taskId":"t","prompt":"p","stage":"independent","round":1,"phase":"prepared","preparedAt":1}],"manualProviders":[],"pageURLs":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(ArenaSessionFile.self, from: legacy)
        precondition(decoded.intents.first?.attachmentReceipt == nil)
        precondition(decoded.intents.first?.imagePixelDigests == nil)
        var withPixels = decoded
        let digests = [String(repeating: "a", count: 64), ""]
        withPixels.intents[0].imagePixelDigests = digests
        let reencoded = try JSONEncoder().encode(withPixels)
        let reopenedPixels = try JSONDecoder().decode(ArenaSessionFile.self, from: reencoded)
        precondition(reopenedPixels.intents[0].imagePixelDigests == digests)
        print("attachment store: snapshot, order, duplicate names, PNG validation, bounds, tamper, path checks, legacy decode OK")
    }
}
