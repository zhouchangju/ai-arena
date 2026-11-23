import AppKit

/// Drive the actual composer import handler using a private pasteboard.
/// The general clipboard and the user's Finder selection stay untouched.
@main
struct AttachmentPasteboardCheck {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let png = try Data(contentsOf: folder.appendingPathComponent("01-红.png"))
        let tiff = NSImage(data: png)!.tiffRepresentation!
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let editor = ArenaQuestionTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        editor.isRichText = false
        var received: [ArenaDraftAttachment] = []
        var errors: [String] = []
        editor.acceptMaterials = { items in received.append(contentsOf: items); return true }
        editor.reportError = { errors.append($0) }

        func write(_ items: [NSPasteboardItem]) {
            board.clearContents()
            precondition(board.writeObjects(items))
        }
        func file(_ name: String) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setString(folder.appendingPathComponent(name).absoluteString, forType: .fileURL)
            // Finder may supply an icon alongside the file: it is one item.
            item.setData(tiff, forType: .tiff)
            return item
        }

        write([file("02-蓝.png"), file("01-红.png"), file("03-说明.txt")])
        precondition(editor.importContent(board))
        precondition(received.map(\.name) == ["02-蓝.png", "01-红.png", "03-说明.txt"])
        precondition(received[1].data == png && received[2].text?.contains("风铃") == true)
        precondition(editor.string.isEmpty)

        let screenshot = NSPasteboardItem()
        screenshot.setData(tiff, forType: .tiff)
        write([screenshot])
        precondition(editor.importContent(board))
        precondition(received.last?.mediaType == "image/png" && received.count == 4)

        let screenshotAndText = NSPasteboardItem()
        screenshotAndText.setData(png, forType: .png)
        screenshotAndText.setData(tiff, forType: .tiff)
        let text = NSPasteboardItem()
        text.setString("插入\n文字", forType: .string)
        editor.string = "左右"
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        write([screenshotAndText, text])
        precondition(editor.readablePasteboardTypes.contains(.png))
        precondition(editor.readSelection(from: board, type: .png))
        precondition(received.count == 5 && received.last?.data == png)
        precondition(editor.string == "左插入\n文字右")
        precondition(errors.isEmpty)

        write([file("01-红.png"), file("unsupported.pdf")])
        precondition(editor.importContent(board))
        precondition(received.count == 5 && errors.count == 1)
        precondition(editor.string == "左插入\n文字右")

        let plain = NSPasteboardItem()
        plain.setString("https://example.org/\n引用", forType: .string)
        write([plain])
        precondition(!editor.importContent(board))
        editor.setSelectedRange(NSRange(location: 0, length: 1))
        precondition(editor.readSelection(from: board, type: .string))
        precondition(editor.string.hasPrefix("https://example.org/\n引用插入"))
        print("PASS: AppKit Finder multi-item order, repeated PNG/TIFF paste, mixed text at caret, unsupported batch, ordinary text selection")
    }
}
