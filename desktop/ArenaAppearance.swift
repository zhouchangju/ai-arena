//
//  ArenaAppearance.swift
//  AI Arena · 外观与提问区背景
//
//  Only NSApplication.appearance changes; WebViews and site-owned themes are
//  untouched. The question background is a visual layer in the main header.
//  Preferences and the bounded JPEG copy live in one atomic binary plist under
//  the existing ArenaSessionStore root.
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 外观模式

enum ArenaAppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - 提问区背景

enum ArenaQuestionBackdropKind: String, Codable, CaseIterable, Identifiable {
    case gradient
    case solid
    case image

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gradient: return "默认渐变"
        case .solid: return "纯色"
        case .image: return "自定义图片"
        }
    }
}

enum ArenaQuestionImageError: LocalizedError {
    case notLocal
    case notRegularFile
    case sourceTooLarge
    case unsupported
    case dimensionsTooLarge
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .notLocal:
            return "请选择本机图片文件。"
        case .notRegularFile:
            return "请选择一个 PNG 或 JPEG 文件。"
        case .sourceTooLarge:
            return "图片文件过大（超过 64 MB）。请换一张较小的图片。"
        case .unsupported:
            return "无法读取这张图片。请选择 PNG 或 JPEG 文件。"
        case .dimensionsTooLarge:
            return "图片尺寸过大，无法用作背景。请换一张较小的图片。"
        case .processingFailed:
            return "无法处理这张图片。请换一张 PNG 或 JPEG 文件后重试。"
        }
    }
}

enum ArenaAppearanceError: LocalizedError {
    case writeFailed

    var errorDescription: String? {
        "无法保存外观设置。请检查磁盘空间和应用支持目录的写入权限后重试。"
    }
}

// MARK: - 图片归一化

/// Validates a picked PNG/JPEG, applies orientation and returns bounded JPEG
/// bytes. It never touches the previous stored copy.
struct ArenaQuestionImageProcessor {
    static let maxPixelSize = 2_048
    static let maxSourceBytes = 64 * 1024 * 1024
    static let maxOutputBytes = 4 * 1024 * 1024
    static let maxSourceDimension = 30_000
    static let maxSourcePixels = 120_000_000

    func processedData(from sourceURL: URL) throws -> Data {
        guard sourceURL.isFileURL else { throw ArenaQuestionImageError.notLocal }
        let metadata = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true else { throw ArenaQuestionImageError.notRegularFile }
        if let size = metadata.fileSize, size > Self.maxSourceBytes {
            throw ArenaQuestionImageError.sourceTooLarge
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let sourceType = CGImageSourceGetType(source) as String?,
              sourceType == UTType.png.identifier || sourceType == UTType.jpeg.identifier else {
            throw ArenaQuestionImageError.unsupported
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw ArenaQuestionImageError.unsupported
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= Self.maxSourcePixels,
              width <= Self.maxSourceDimension, height <= Self.maxSourceDimension else {
            throw ArenaQuestionImageError.dimensionsTooLarge
        }

        let attempts: [(pixels: Int, quality: CGFloat)] = [
            (2_048, 0.84),
            (1_600, 0.78),
            (1_200, 0.72),
        ]
        for attempt in attempts {
            guard let thumbnail = Self.thumbnail(source, maxPixel: attempt.pixels) else { continue }
            let flattened = Self.flatten(thumbnail)
            guard let data = Self.encodeJPEG(flattened, quality: attempt.quality) else { continue }
            if data.count <= Self.maxOutputBytes { return data }
        }
        throw ArenaQuestionImageError.processingFailed
    }

    private static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func flatten(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            let width = image.width
            let height = image.height
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  ) else { return image }
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage() ?? image
        }
    }

    private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - 原子存储

/// One bounded binary plist in the session store's existing root. The JPEG is
/// part of the same atomic write, so a failed save cannot point at a missing or
/// half-replaced copy.
struct ArenaAppearanceStore {
    struct Snapshot: Codable, Equatable {
        var mode: ArenaAppearanceMode
        var backdrop: ArenaQuestionBackdropKind
        var image: Data?
    }

    static let maxFileBytes = ArenaQuestionImageProcessor.maxOutputBytes + 64 * 1024

    let directory: URL

    init(root: URL = ArenaSessionStore().root) {
        directory = root.appendingPathComponent("Appearance", isDirectory: true)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("appearance.plist", isDirectory: false)
    }

    func load() -> Snapshot? {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= Self.maxFileBytes,
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: Snapshot) throws {
        if let image = snapshot.image,
           image.isEmpty || image.count > ArenaQuestionImageProcessor.maxOutputBytes {
            throw ArenaAppearanceError.writeFailed
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw ArenaAppearanceError.writeFailed
        }
        guard data.count <= Self.maxFileBytes else { throw ArenaAppearanceError.writeFailed }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw ArenaAppearanceError.writeFailed
        }
    }
}

// MARK: - 偏好

final class ArenaAppearancePreferences: ObservableObject {
    static let shared = ArenaAppearancePreferences()

    @Published private(set) var mode: ArenaAppearanceMode
    @Published private(set) var backdropKind: ArenaQuestionBackdropKind
    @Published private(set) var customImage: NSImage?

    private var customImageData: Data?
    private let store: ArenaAppearanceStore

    init(store: ArenaAppearanceStore = ArenaAppearanceStore()) {
        self.store = store
        let snapshot = store.load()
        let storedKind = snapshot?.backdrop ?? .gradient
        var image: NSImage?
        var imageData: Data?
        if let data = snapshot?.image,
           !data.isEmpty,
           data.count <= ArenaQuestionImageProcessor.maxOutputBytes,
           let decoded = NSImage(data: data) {
            image = decoded
            imageData = data
        }
        self.mode = snapshot?.mode ?? .system
        self.backdropKind = storedKind == .image && image == nil ? .gradient : storedKind
        self.customImage = image
        self.customImageData = imageData
    }

    var hasCustomImage: Bool { customImage != nil }

    func setMode(_ next: ArenaAppearanceMode) throws {
        guard next != mode else { return }
        try store.save(.init(mode: next, backdrop: backdropKind, image: customImageData))
        mode = next
        applyApplicationAppearance()
    }

    func applyApplicationAppearance() {
        NSApplication.shared.appearance = mode.appearance
    }

    func selectBackdrop(_ next: ArenaQuestionBackdropKind) throws {
        if next == .image, !hasCustomImage { return }
        guard next != backdropKind else { return }
        try store.save(.init(mode: mode, backdrop: next, image: customImageData))
        backdropKind = next
    }

    func setCustomImage(from url: URL) throws {
        let data = try ArenaQuestionImageProcessor().processedData(from: url)
        guard let image = NSImage(data: data) else {
            throw ArenaQuestionImageError.processingFailed
        }
        try store.save(.init(mode: mode, backdrop: .image, image: data))
        customImage = image
        customImageData = data
        backdropKind = .image
    }

    func restoreDefaultBackdrop() throws {
        try store.save(.init(mode: mode, backdrop: .gradient, image: nil))
        customImage = nil
        customImageData = nil
        backdropKind = .gradient
    }
}

// MARK: - 顶部背景

/// Paints behind the header only, so changing background never affects layout
/// or the solid report, raw record and WebView surfaces below.
struct ArenaQuestionBackdropView: View {
    @ObservedObject var preferences: ArenaAppearancePreferences

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                base
                if preferences.backdropKind == .image, let image = preferences.customImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                    photoScrim
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isDark: Bool { colorScheme == .dark }

    @ViewBuilder
    private var base: some View {
        switch preferences.backdropKind {
        case .gradient, .image:
            gradient
        case .solid:
            solid
        }
    }

    private var gradient: some View {
        LinearGradient(
            colors: isDark
                ? [
                    Color(red: 0.17, green: 0.21, blue: 0.27),
                    Color(red: 0.12, green: 0.16, blue: 0.21),
                    Color(red: 0.10, green: 0.14, blue: 0.19),
                ]
                : [
                    Color(red: 0.93, green: 0.95, blue: 0.97),
                    Color(red: 0.86, green: 0.90, blue: 0.94),
                    Color(red: 0.82, green: 0.87, blue: 0.92),
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var solid: some View {
        isDark
            ? Color(red: 0.13, green: 0.17, blue: 0.22)
            : Color(red: 0.86, green: 0.90, blue: 0.94)
    }

    private var photoScrim: some View {
        let boost = reduceTransparency ? 0.07 : 0
        let top = min(1, (isDark ? 0.84 : 0.92) + boost)
        let bottom = min(1, (isDark ? 0.72 : 0.80) + boost)
        return LinearGradient(
            colors: isDark
                ? [
                    Color.black.opacity(top),
                    Color(red: 0.07, green: 0.11, blue: 0.16).opacity(bottom),
                ]
                : [
                    Color.white.opacity(top),
                    Color(red: 0.90, green: 0.93, blue: 0.96).opacity(bottom),
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 设置窗口

struct ArenaAppearanceSettingsView: View {
    @ObservedObject var preferences: ArenaAppearancePreferences
    @State private var errorMessage: String?

    var body: some View {
        TabView {
            Form {
                Section {
                    Picker("窗口外观", selection: modeBinding) {
                        ForEach(ArenaAppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("外观")
                }

                Section {
                    Picker("背景样式", selection: backgroundBinding) {
                        ForEach(ArenaQuestionBackdropKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        Button(preferences.hasCustomImage ? "更换图片…" : "选择图片…") {
                            chooseImage()
                        }
                        Button("恢复默认") {
                            do {
                                try preferences.restoreDefaultBackdrop()
                                errorMessage = nil
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                        .disabled(preferences.backdropKind == .gradient && !preferences.hasCustomImage)
                    }

                    ArenaQuestionBackdropView(preferences: preferences)
                        .frame(height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10))
                        )

                    Text("自定义图片只保存在本机，不会上传，也不会写入场次导出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("提问区背景")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("外观", systemImage: "paintbrush") }
        }
        .frame(width: 480, height: 430)
    }

    private var modeBinding: Binding<ArenaAppearanceMode> {
        Binding(
            get: { preferences.mode },
            set: { next in
                do {
                    try preferences.setMode(next)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private var backgroundBinding: Binding<ArenaQuestionBackdropKind> {
        Binding(
            get: { preferences.backdropKind },
            set: { next in
                if next == .image, !preferences.hasCustomImage {
                    chooseImage()
                    return
                }
                do {
                    try preferences.selectBackdrop(next)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "选择提问区背景图片"
        panel.prompt = "使用"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try preferences.setCustomImage(from: url)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// AppKit-owned settings window. QA orders it back instead of activating the
/// helper process.
final class ArenaSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = ArenaSettingsWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<ArenaAppearanceSettingsView>?

    func show(preferences: ArenaAppearancePreferences = .shared) {
        if window == nil {
            let root = ArenaAppearanceSettingsView(preferences: preferences)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 430),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "设置"
            window.contentViewController = hosting
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.collectionBehavior = [.managed]
            window.delegate = self
            window.center()
            hostingController = hosting
            self.window = window
        }
        guard let window else { return }
        if ArenaBuildIsolation.isQABuild {
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
