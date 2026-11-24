import AVFoundation
import CoreText
import CoreVideo
import Foundation

// MARK: - 分镜

/// A silent, subtitle-only explainer. Every body is taken from the same
/// structured candidate and saved ballot the report shows; the plan never asks
/// a model for a new narration and never replaces a qualifier with a summary.
struct ArenaReportVideoShot: Identifiable, Equatable {
    let id: Int
    let title: String
    let body: String
    let footer: String
    let duration: Double
}

struct ArenaReportVideoOptions {
    var width = 1280
    var height = 720
    var frameRate: Int32 = 30
}

enum ArenaReportVideoPlan {
    static func shots(for input: ArenaReportArtifactInput) -> [ArenaReportVideoShot] {
        var planned: [(title: String, body: String, footer: String)] = []

        let seats = input.participants.map(input.seatLabel).joined(separator: "、")
        planned.append((
            "本场状态",
            [
                input.outcome,
                "候选 v\(input.version) · 起草：\(input.candidateAuthor)",
                "参与席位：\(seats.isEmpty ? "未记录" : seats)",
            ].joined(separator: "\n"),
            "独立场次状态"
        ))

        append(
            &planned,
            title: "直接建议",
            text: input.digest.advicePlain,
            footer: "候选 \(input.candidateSourceID) · 原文"
        )

        let conditions = input.digest.conditions
        if conditions.isEmpty {
            planned.append((
                "成立条件",
                "候选没有列出成立条件。",
                "候选 \(input.candidateSourceID) · 原文"
            ))
        } else {
            for (index, item) in conditions.enumerated() {
                append(
                    &planned,
                    title: "成立条件 \(index + 1)/\(conditions.count)",
                    text: item.plain,
                    footer: "候选 \(input.candidateSourceID) · 原文"
                )
            }
        }

        let disputes = input.digest.disputes
        if !disputes.isEmpty {
            for (index, item) in disputes.enumerated() {
                append(
                    &planned,
                    title: "影响建议的未决分歧 \(index + 1)/\(disputes.count)",
                    text: item.plain,
                    footer: "按原文核对 · 候选没有把分歧当作结论"
                )
            }
        }

        if input.digest.hasOther {
            append(
                &planned,
                title: "其他说明",
                text: input.digest.otherPlain,
                footer: "候选 \(input.candidateSourceID) · 原文"
            )
        }

        for position in input.concernPositions {
            append(
                &planned,
                title: "未计入无条件同意的表态",
                text: "\(position.seatLabel)：\(position.stanceLabel)\n\(ArenaDigestText.plain(position.answer))",
                footer: "\(position.sourceID) · 表态原文"
            )
        }

        let missing = input.participants.filter { provider in
            !input.positions.contains { $0.provider == provider }
        }
        if !missing.isEmpty {
            planned.append((
                "未明确表态",
                missing.map { "\(input.seatLabel($0))：未对 v\(input.version) 明确表态（不计为同意）" }
                    .joined(separator: "\n"),
                "保存的同版表态"
            ))
        }

        planned.append((
            "说明",
            "以上文字摘自候选原文和保存的表态。缺席、跳过、未表态和往轮旧票都不计为同意。",
            "AI Arena · 本地生成"
        ))

        return planned.enumerated().map { index, item in
            ArenaReportVideoShot(
                id: index,
                title: item.title,
                body: item.body.trimmingCharacters(in: .whitespacesAndNewlines),
                footer: item.footer,
                duration: duration(for: item.body)
            )
        }.filter { !$0.body.isEmpty }
    }

    static func duration(for body: String) -> Double {
        let count = Double(body.count)
        return max(2.6, min(12.0, 0.9 + count * 0.085))
    }

    /// Split only at readable boundaries. A single very long sentence is split
    /// at a hard character boundary as a last resort, so no text is dropped.
    static func chunks(_ text: String, limit: Int = 140) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        guard normalized.count > limit else { return [normalized] }

        var result: [String] = []
        var remaining = normalized[...]
        while remaining.count > limit {
            let window = remaining.prefix(limit)
            let sentenceBreak = window.lastIndex(where: { "。！？；\n".contains($0) })
            let phraseBreak = window.lastIndex(where: { "，、：,;".contains($0) })
            let cut = sentenceBreak ?? phraseBreak ?? window.endIndex
            let end = cut == window.endIndex ? cut : remaining.index(after: cut)
            let piece = String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            remaining = remaining[end...]
            while remaining.first == " " || remaining.first == "\n" {
                remaining = remaining.dropFirst()
            }
            if remaining.isEmpty { break }
        }
        let tail = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [normalized] : result
    }

    private static func append(
        _ planned: inout [(title: String, body: String, footer: String)],
        title: String,
        text: String,
        footer: String
    ) {
        let parts = chunks(text)
        guard !parts.isEmpty else { return }
        for (index, part) in parts.enumerated() {
            let suffix = parts.count > 1 ? " \(index + 1)/\(parts.count)" : ""
            planned.append((title + suffix, part, footer))
        }
    }
}

// MARK: - 本地 H.264 MP4

enum ArenaReportVideoError: LocalizedError {
    case noShots
    case invalidSize
    case writer(String)
    case encodeFailed(String)
    case finishTimedOut

    var errorDescription: String? {
        switch self {
        case .noShots: return "没有可生成的分镜"
        case .invalidSize: return "视频尺寸无效"
        case .writer(let detail): return "无法开始写入视频：\(detail)"
        case .encodeFailed(let detail): return "写入视频帧失败：\(detail)"
        case .finishTimedOut: return "视频编码超时"
        }
    }
}

enum ArenaReportVideo {
    static func render(
        _ input: ArenaReportArtifactInput,
        to url: URL,
        options: ArenaReportVideoOptions = ArenaReportVideoOptions()
    ) throws {
        try render(shots: ArenaReportVideoPlan.shots(for: input), to: url, options: options)
    }

    static func render(
        shots: [ArenaReportVideoShot],
        to url: URL,
        options: ArenaReportVideoOptions = ArenaReportVideoOptions()
    ) throws {
        guard !shots.isEmpty else { throw ArenaReportVideoError.noShots }
        guard options.width > 0, options.height > 0, options.frameRate > 0 else {
            throw ArenaReportVideoError.invalidSize
        }

        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Encode beside the destination, then replace only after a complete
        // file exists. A failure never deletes the user's previous video.
        let temporary = directory.appendingPathComponent(".arena-video-\(UUID().uuidString).mp4")
        var committed = false
        defer {
            if !committed { try? fileManager.removeItem(at: temporary) }
        }

        try encode(shots: shots, to: temporary, options: options)

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
        committed = true
    }

    private static func encode(
        shots: [ArenaReportVideoShot],
        to url: URL,
        options: ArenaReportVideoOptions
    ) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: options.width,
            AVVideoHeightKey: options.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(350_000, options.width * options.height * 3),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(options.frameRate) * 2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: options.width,
            kCVPixelBufferHeightKey as String: options.height,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        writer.add(input)

        guard writer.startWriting() else {
            throw ArenaReportVideoError.writer(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        var frameIndex: Int64 = 0
        let totalFrames = shots.reduce(0) { $0 + max(1, Int(($1.duration * Double(options.frameRate)).rounded())) }
        var framesWritten = 0

        for shot in shots {
            let frames = max(1, Int((shot.duration * Double(options.frameRate)).rounded()))
            for frame in 0..<frames {
                let readyDeadline = Date().addingTimeInterval(30)
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed {
                        writer.cancelWriting()
                        throw ArenaReportVideoError.encodeFailed(
                            writer.error?.localizedDescription ?? "writer failed"
                        )
                    }
                    if Date() >= readyDeadline {
                        writer.cancelWriting()
                        throw ArenaReportVideoError.encodeFailed("等待编码器就绪超时")
                    }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                guard writer.status == .writing else {
                    writer.cancelWriting()
                    throw ArenaReportVideoError.encodeFailed(
                        writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)"
                    )
                }
                guard let pool = adaptor.pixelBufferPool else {
                    writer.cancelWriting()
                    throw ArenaReportVideoError.encodeFailed("pixel buffer pool unavailable")
                }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                      let pixelBuffer = buffer else {
                    writer.cancelWriting()
                    throw ArenaReportVideoError.encodeFailed("pixel buffer unavailable")
                }
                draw(
                    shot: shot,
                    frame: frame,
                    framesInShot: frames,
                    overallProgress: totalFrames == 0 ? 0 : Double(framesWritten) / Double(totalFrames),
                    into: pixelBuffer,
                    options: options
                )
                let time = CMTime(value: frameIndex, timescale: options.frameRate)
                guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                    writer.cancelWriting()
                    throw ArenaReportVideoError.encodeFailed(writer.error?.localizedDescription ?? "append failed")
                }
                if writer.status == .failed {
                    throw ArenaReportVideoError.encodeFailed(
                        writer.error?.localizedDescription ?? "writer failed"
                    )
                }
                frameIndex += 1
                framesWritten += 1
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        if semaphore.wait(timeout: .now() + 60) == .timedOut {
            writer.cancelWriting()
            throw ArenaReportVideoError.finishTimedOut
        }
        guard writer.status == .completed else {
            throw ArenaReportVideoError.writer(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
    }

    // MARK: Frame drawing

    private static func draw(
        shot: ArenaReportVideoShot,
        frame: Int,
        framesInShot: Int,
        overallProgress: Double,
        into pixelBuffer: CVPixelBuffer,
        options: ArenaReportVideoOptions
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = options.width
        let height = options.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }

        drawBackground(context, width: width, height: height)
        let fade = fadeAlpha(frame: frame, framesInShot: framesInShot)
        context.setAlpha(fade)

        let margin = CGFloat(width) * 0.075
        let titleSize = max(18, CGFloat(width) / 42)
        let footerSize = max(11, CGFloat(width) / 78)
        let accent = CGColor(red: 0.74, green: 0.92, blue: 0.84, alpha: 0.96)
        let primary = CGColor(red: 0.97, green: 0.98, blue: 0.96, alpha: 1)
        let secondary = CGColor(red: 0.67, green: 0.73, blue: 0.69, alpha: 1)

        drawLine(
            shot.title,
            in: context,
            canvasHeight: CGFloat(height),
            x: margin,
            baselineFromTop: margin + titleSize,
            size: titleSize,
            color: accent,
            weight: .traitBold
        )

        let bodyTop = margin + titleSize + max(20, titleSize * 0.9)
        let bodyBottom = CGFloat(height) - margin - footerSize * 2.6
        let bodyHeight = max(40, bodyBottom - bodyTop)
        let bodyRect = CGRect(
            x: margin,
            y: bodyTop,
            width: CGFloat(width) - margin * 2,
            height: bodyHeight
        )
        drawBody(
            shot.body,
            in: context,
            rect: bodyRect,
            maxSize: max(18, CGFloat(width) / 34),
            color: primary
        )

        drawLine(
            shot.footer,
            in: context,
            canvasHeight: CGFloat(height),
            x: margin,
            baselineFromTop: CGFloat(height) - margin * 0.45,
            size: footerSize,
            color: secondary,
            weight: []
        )

        // A quiet progress line, not a second timeline or a decorative chart.
        let progressY = CGFloat(height) * 0.055
        context.setAlpha(1)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
        context.fill(CGRect(x: margin, y: progressY, width: CGFloat(width) - margin * 2, height: 2))
        context.setFillColor(accent)
        context.fill(CGRect(
            x: margin,
            y: progressY,
            width: (CGFloat(width) - margin * 2) * CGFloat(max(0, min(1, overallProgress))),
            height: 2
        ))
    }

    private static func fadeAlpha(frame: Int, framesInShot: Int) -> CGFloat {
        let fadeFrames = max(1, min(8, framesInShot / 5))
        if frame < fadeFrames { return CGFloat(frame) / CGFloat(fadeFrames) }
        let remaining = framesInShot - frame
        if remaining <= fadeFrames { return CGFloat(max(0, remaining)) / CGFloat(fadeFrames) }
        return 1
    }

    private static func drawBackground(_ context: CGContext, width: Int, height: Int) {
        let colors = [
            CGColor(red: 0.055, green: 0.09, blue: 0.08, alpha: 1),
            CGColor(red: 0.10, green: 0.16, blue: 0.14, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: CGFloat(height)),
                end: CGPoint(x: CGFloat(width), y: 0),
                options: []
            )
        } else {
            context.setFillColor(CGColor(red: 0.08, green: 0.13, blue: 0.11, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        context.setFillColor(CGColor(red: 0.74, green: 0.92, blue: 0.84, alpha: 0.85))
        context.fill(CGRect(x: 0, y: 0, width: max(5, CGFloat(width) * 0.006), height: CGFloat(height)))
    }

    private static func drawLine(
        _ text: String,
        in context: CGContext,
        canvasHeight: CGFloat,
        x: CGFloat,
        baselineFromTop: CGFloat,
        size: CGFloat,
        color: CGColor,
        weight: CTFontSymbolicTraits
    ) {
        guard !text.isEmpty else { return }
        let font = font(size: size, weight: weight)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        let attributed = CFAttributedStringCreate(
            nil,
            text as CFString,
            attributes as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: x, y: canvasHeight - baselineFromTop)
        CTLineDraw(line, context)
    }

    private static func drawBody(
        _ text: String,
        in context: CGContext,
        rect: CGRect,
        maxSize: CGFloat,
        color: CGColor
    ) {
        guard !text.isEmpty else { return }
        var size = maxSize
        while size >= 15 {
            let font = font(size: size, weight: [])
            var lineSpacing = size * 0.42
            let paragraph = withUnsafePointer(to: &lineSpacing) { pointer in
                var setting = CTParagraphStyleSetting(
                    spec: .lineSpacingAdjustment,
                    valueSize: MemoryLayout<CGFloat>.size,
                    value: pointer
                )
                return CTParagraphStyleCreate(&setting, 1)
            }
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color,
                kCTParagraphStyleAttributeName: paragraph,
            ]
            let attributed = CFAttributedStringCreate(
                nil,
                text as CFString,
                attributes as CFDictionary
            )!
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: 0),
                nil,
                CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                nil
            )
            if suggested.height <= rect.height || size <= 15 {
                let path = CGMutablePath()
                path.addRect(rect)
                let frame = CTFramesetterCreateFrame(
                    framesetter,
                    CFRange(location: 0, length: 0),
                    path,
                    nil
                )
                CTFrameDraw(frame, context)
                return
            }
            size -= 1
        }
    }

    private static func font(size: CGFloat, weight: CTFontSymbolicTraits) -> CTFont {
        let base = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
        if weight.isEmpty { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, weight, weight) ?? base
    }
}
