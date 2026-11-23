import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Read a whole paste or drop before changing the draft. A Finder item can
/// advertise both its URL and its icon. Only the file belongs in the question.
enum ArenaComposerPaste {
    case ordinaryText
    case materials([ArenaDraftAttachment], text: String)

    static func read(_ board: NSPasteboard) throws -> ArenaComposerPaste {
        let items = board.pasteboardItems ?? []
        var attachments: [ArenaDraftAttachment] = []
        var text: [String] = []
        for item in items {
            if let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL {
                attachments.append(try ArenaDraftAttachment(fileURL: url))
            } else if let bytes = item.data(forType: .png) {
                attachments.append(try ArenaDraftAttachment(name: "粘贴图片.png", data: bytes))
            } else if let bytes = item.data(forType: .init(UTType.jpeg.identifier)) {
                attachments.append(try ArenaDraftAttachment(name: "粘贴图片.jpg", data: bytes))
            } else if let bytes = item.data(forType: .tiff) {
                attachments.append(try ArenaDraftAttachment(name: "截图.png", data: pngFromTIFF(bytes)))
            } else if let value = item.string(forType: .string) ?? item.string(forType: .URL) {
                text.append(value)
            } else if item.availableType(from: [.html, .rtf]) != nil && items.count == 1 {
                return .ordinaryText
            } else {
                throw failure("无法加入这项内容。支持 PNG、JPEG、TXT、Markdown 和 CSV。")
            }
            try ArenaDraftAttachment.validate(attachments)
        }
        return attachments.isEmpty ? .ordinaryText : .materials(attachments, text: text.joined(separator: "\n"))
    }

    private static func pngFromTIFF(_ bytes: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height else {
            throw failure("截图无法读取或像素过多，请缩小后重新粘贴。")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw failure("无法转换剪贴板里的截图。")
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure("无法转换剪贴板里的截图。") }
        return output as Data
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "AI Arena 输入", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

final class ArenaQuestionTextView: NSTextView {
    var acceptMaterials: (([ArenaDraftAttachment]) -> Bool)?
    var reportError: ((String) -> Void)?
    var start: (() -> Void)?
    var focusOnMount = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusOnMount, let window {
            focusOnMount = false
            DispatchQueue.main.async { [weak self, weak window] in
                if let self { window?.makeFirstResponder(self) }
            }
        }
    }

    // AppKit uses this list to enable Edit > Paste (including its shortcut)
    // and to choose a type for the system paste/Services path.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        Self.materialTypes + super.readablePasteboardTypes.filter { !Self.materialTypes.contains($0) }
    }

    override func readSelection(from board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if Self.materialTypes.contains(type) { return importContent(board) }
        return super.readSelection(from: board, type: type)
    }

    override func paste(_ sender: Any?) {
        if !importContent(.general) { super.paste(sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "\r", !hasMarkedText() {
            start?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static let materialTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .png, .tiff, .init(UTType.jpeg.identifier)
    ]

    func enableMaterialDrops() {
        registerForDraggedTypes(Array(Set(registeredDraggedTypes + Self.materialTypes)))
    }

    private func isMaterialDrag(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(from: Self.materialTypes) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isMaterialDrag(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isMaterialDrag(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isMaterialDrag(sender) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isMaterialDrag(sender) { return importContent(sender.draggingPasteboard) }
        return super.performDragOperation(sender)
    }

    func importContent(_ board: NSPasteboard) -> Bool {
        do {
            switch try ArenaComposerPaste.read(board) {
            case .ordinaryText: return false
            case .materials(let files, let text):
                if acceptMaterials?(files) == true, !text.isEmpty {
                    insertText(text, replacementRange: selectedRange())
                }
            }
        } catch {
            reportError?(error.localizedDescription)
        }
        return true
    }
}

struct ArenaQuestionEditor: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let onFocus: (Bool) -> Void
    let onMaterials: ([ArenaDraftAttachment]) -> Bool
    let onError: (String) -> Void
    let onStart: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ArenaQuestionEditor
        var lastFocusRequest: Int

        init(_ parent: ArenaQuestionEditor) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
        }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
        func textDidBeginEditing(_ notification: Notification) { parent.onFocus(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocus(false) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = ArenaQuestionTextView(frame: .zero)
        editor.isRichText = false
        editor.usesFindPanel = true
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = .init(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.setAccessibilityLabel("讨论问题")
        editor.setAccessibilityHelp("可输入文字、粘贴或拖入附件。按 Command 加回车开始讨论。")
        editor.focusOnMount = true
        editor.delegate = context.coordinator
        scroll.documentView = editor
        editor.enableMaterialDrops()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ArenaQuestionTextView else { return }
        context.coordinator.parent = self
        if !editor.hasMarkedText(), editor.string != text { editor.string = text }
        editor.acceptMaterials = onMaterials
        editor.reportError = onError
        editor.start = onStart
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak editor] in
                if let editor { editor.window?.makeFirstResponder(editor) }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let paragraph = (text.isEmpty ? " " : text + " ") as NSString
        let height = paragraph.boundingRect(
            with: NSSize(width: max(1, width - 15), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        ).height
        return CGSize(width: width, height: min(132, max(57, ceil(height) + 4)))
    }
}

private func arenaImagePreview(_ data: Data, pixels: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: pixels,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
}

struct ArenaDraftAttachmentChip: View {
    let item: ArenaDraftAttachment
    let label: String
    let onPreview: () -> Void
    let onRemove: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onPreview) {
                HStack(spacing: 6) {
                    Group {
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().scaledToFill()
                        } else {
                            Image(systemName: item.kind == .image ? "photo" : "doc.plaintext")
                                .foregroundStyle(.secondary)
                        }
                    }.frame(width: 34, height: 32).clipped().cornerRadius(4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).lineLimit(1).font(.caption.weight(.semibold))
                        Text(item.kind == .image ? item.name : "以文本发送")
                            .lineLimit(1).truncationMode(.middle).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: 110, alignment: .leading)
                }
            }.buttonStyle(.plain).accessibilityLabel("预览" + label)
            Button(action: onRemove) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.borderless).help("移除" + label).accessibilityLabel("移除" + label)
        }
        .padding(6).background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
        .task(id: item.id) {
            if item.kind == .image { thumbnail = arenaImagePreview(item.data, pixels: 80) }
        }
    }
}

struct ArenaMaterialPreview: View {
    let item: ArenaDraftAttachment
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: item.name).font(.headline)
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
            }
            if let text = item.text {
                ScrollView {
                    Text(verbatim: text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let image = arenaImagePreview(item.data, pixels: 1500) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Text("无法读取图片预览。") }
        }.padding(18).frame(width: 520, height: 360)
    }
}
