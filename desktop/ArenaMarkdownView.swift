//  ArenaMarkdownView.swift
//  AI Arena · 本地报告阅读视图
//
//  目标：G2/G4。把本场报告（以及从网页抄录的普通文本）按块渲染成可读的
//  本地 Markdown 视图：标题、段落间距、项目符号与编号列表、引用、行内强调、
//  围栏代码和简单表格。[S#] 出处保持原样可见，长报告可整体选择和复制。
//
//  安全边界：只用 Foundation 的行内 Markdown 解析和本地文本排版；不请求网络、
//  不加载远程图片、不执行 HTML。网页链接仅在用户点击时打开，
//  因此 javascript: 等协议没有落点。无法解析的标记按原文显示，不会吞掉内容。
//
//  用法：报告页用 ArenaMarkdownView(text: report) 替换原来的
//  ScrollView { Text(report) }。纵向滚动由外层阅读页统一管理。

import AppKit
import Foundation
import SwiftUI

// MARK: - 块模型

/// 报告中可独立排版的最小单元。解析器不抛错：无法识别的行退回段落。
enum ArenaMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case list(items: [ArenaMarkdownListItem], ordered: Bool)
    case quote(lines: [String])
    case code(text: String, language: String?)
    case table(header: [String], rows: [[String]])
    case divider
}

struct ArenaMarkdownListItem: Equatable {
    let depth: Int
    let marker: String
    var text: String
}

// MARK: - 解析

/// 以行扫描为基础的块解析。行内强调交给 Foundation 的
/// `AttributedString(markdown:)`（inlineOnlyPreservingWhitespace），块级结构
/// 在本地处理，以便支持表格、中文编号小标题和残缺标记。
enum ArenaMarkdownParser {

    static func blocks(in raw: String) -> [ArenaMarkdownBlock] {
        let lines = normalize(raw).components(separatedBy: "\n")
        var blocks: [ArenaMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(text: joinParagraph(paragraph)))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = fenceInfo(rawLine) {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count {
                    if isFenceClose(lines[index], fence: fence) {
                        index += 1
                        break
                    }
                    code.append(dedent(lines[index], by: fence.indent))
                    index += 1
                }
                blocks.append(.code(text: code.joined(separator: "\n"), language: fence.language))
                continue
            }

            if let heading = atxHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            // Setext 标题：前一段只有一行，当前行是 === 或 --- 下划线。
            if !paragraph.isEmpty, paragraph.count == 1, let level = setextLevel(trimmed) {
                let title = joinParagraph(paragraph)
                paragraph.removeAll(keepingCapacity: true)
                blocks.append(.heading(level: level, text: title))
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if let table = parseTable(lines: lines, start: index) {
                flushParagraph()
                blocks.append(.table(header: table.header, rows: table.rows))
                index = table.next
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var content = candidate
                    // 压平嵌套引用，但保留其中的原始文字。
                    while content.hasPrefix(">") {
                        content.removeFirst()
                        if content.hasPrefix(" ") { content.removeFirst() }
                    }
                    quote.append(content)
                    index += 1
                }
                blocks.append(.quote(lines: quote))
                continue
            }

            if let first = listMarker(rawLine) {
                flushParagraph()
                let parsed = collectList(lines: lines, start: index, first: first)
                blocks.append(.list(items: parsed.items, ordered: parsed.ordered))
                index = parsed.next
                continue
            }

            if let level = chineseSectionHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, text: trimmed))
                index += 1
                continue
            }

            paragraph.append(rawLine)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    // MARK: 行工具

    static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{F8F0}", with: "")
            .replacingOccurrences(of: "\u{F8F1}", with: "")
    }

    private static func indentation(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
    }

    private static func dedent(_ line: String, by count: Int) -> String {
        guard count > 0 else { return line }
        var result = line
        var removed = 0
        while removed < count, result.hasPrefix(" ") {
            result.removeFirst()
            removed += 1
        }
        return result
    }

    // MARK: 标题

    private static func atxHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let remainder = trimmed.dropFirst(hashes)
        guard remainder.isEmpty || remainder.first == " " || remainder.first == "\t" else {
            return nil
        }
        var text = remainder.trimmingCharacters(in: .whitespaces)
        if let trailing = text.range(of: "\\s+#+\\s*$", options: .regularExpression) {
            text.removeSubrange(trailing)
            text = text.trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }
        return (hashes, text)
    }

    private static func setextLevel(_ trimmed: String) -> Int? {
        let marks = trimmed.filter { $0 != " " && $0 != "\t" }
        guard !marks.isEmpty, let first = marks.first else { return nil }
        guard marks.allSatisfy({ $0 == first }) else { return nil }
        if first == "=" { return 1 }
        if first == "-", marks.count >= 3 { return 2 }
        return nil
    }

    /// 网页抄录文本常见“一、”“（二）”“第 3 步”“1、”这类短标题。
    /// 只有短、不含句号或分号的行才升级为标题，避免把句子拆成标题。
    private static func chineseSectionHeading(_ trimmed: String) -> Int? {
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        guard !trimmed.contains("。"), !trimmed.contains("；"), !trimmed.contains(";") else {
            return nil
        }
        guard !trimmed.hasSuffix("，"), !trimmed.hasSuffix(","), !trimmed.hasSuffix("、") else {
            return nil
        }
        let patterns: [(String, Int)] = [
            ("^[一二三四五六七八九十百千零〇]{1,4}[、.．]\\s*\\S", 3),
            ("^[（(][一二三四五六七八九十百千零〇]{1,4}[）)]\\s*\\S", 4),
            ("^第[一二三四五六七八九十百千零〇0-9]{1,4}[章节部篇步]\\s*\\S", 3),
            ("^\\d{1,2}、\\s*\\S", 3),
        ]
        for (pattern, level) in patterns {
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                return level
            }
        }
        return nil
    }

    // MARK: 分隔线与围栏

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else {
            return false
        }
        return marks.allSatisfy { $0 == first }
    }

    private struct Fence {
        let marker: Character
        let length: Int
        let indent: Int
        let language: String?
    }

    private static func fenceInfo(_ line: String) -> Fence? {
        let indent = indentation(line)
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let run = body.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        let info = body.dropFirst(run).trimmingCharacters(in: .whitespaces)
        // 反引号围栏的 info 不允许再出现反引号，否则按普通文字处理。
        if first == "`", info.contains("`") { return nil }
        let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
        return Fence(marker: first, length: run, indent: indent, language: language)
    }

    private static func isFenceClose(_ line: String, fence: Fence) -> Bool {
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        let run = body.prefix(while: { $0 == fence.marker }).count
        guard run >= fence.length else { return false }
        return body.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: 列表

    private struct ListMarker {
        let ordered: Bool
        let marker: String
        let depth: Int
        let text: String
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = indentation(line)
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = body.first else { return nil }

        if "-*+•·‣–".contains(first) {
            let afterMarker = body.dropFirst()
            guard let space = afterMarker.first, space == " " || space == "\t" else { return nil }
            let text = afterMarker.drop(while: { $0 == " " || $0 == "\t" })
            guard !text.isEmpty else { return nil }
            return ListMarker(ordered: false,
                              marker: "•",
                              depth: min(indent / 2, 3),
                              text: String(text))
        }

        let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let afterDigits = body.dropFirst(digits.count)
            if let separator = afterDigits.first, separator == "." || separator == ")" {
                let after = afterDigits.dropFirst()
                if let space = after.first, space == " " || space == "\t" {
                    let text = after.drop(while: { $0 == " " || $0 == "\t" })
                    if !text.isEmpty {
                        return ListMarker(ordered: true,
                                          marker: String(digits),
                                          depth: min(indent / 2, 3),
                                          text: String(text))
                    }
                }
            }
        }

        if first == "（" || first == "(" {
            let afterParen = body.dropFirst()
            let innerDigits = afterParen.prefix(while: { $0.isASCII && $0.isNumber })
            if !innerDigits.isEmpty, innerDigits.count <= 2 {
                let afterDigits = afterParen.dropFirst(innerDigits.count)
                if let closing = afterDigits.first, closing == "）" || closing == ")" {
                    let text = afterDigits.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
                    if !text.isEmpty {
                        return ListMarker(ordered: true,
                                          marker: String(innerDigits),
                                          depth: min(indent / 2, 3),
                                          text: String(text))
                    }
                }
            }
        }

        return nil
    }

    private struct ParsedList {
        let items: [ArenaMarkdownListItem]
        let ordered: Bool
        let next: Int
    }

    private static func collectList(lines: [String], start: Int, first: ListMarker) -> ParsedList {
        var items: [ArenaMarkdownListItem] = []
        var current = ArenaMarkdownListItem(depth: first.depth,
                                            marker: first.marker,
                                            text: first.text)
        items.append(current)
        let baseIndent = first.depth * 2
        var index = start + 1

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                var probe = index + 1
                while probe < lines.count,
                      lines[probe].trimmingCharacters(in: .whitespaces).isEmpty {
                    probe += 1
                }
                if probe < lines.count, let nextMarker = listMarker(lines[probe]),
                   nextMarker.ordered == first.ordered {
                    index = probe
                    continue
                }
                break
            }

            if let marker = listMarker(line), marker.ordered == first.ordered {
                current = ArenaMarkdownListItem(depth: marker.depth,
                                                marker: marker.marker,
                                                text: marker.text)
                items.append(current)
                index += 1
                continue
            }

            // 列表项里的换行续写；缩进不够就结束列表，交给下一块。
            if indentation(line) > baseIndent, !isThematicBreak(trimmed) {
                current.text += "\n" + trimmed
                items[items.count - 1] = current
                index += 1
                continue
            }

            break
        }

        return ParsedList(items: items, ordered: first.ordered, next: index)
    }

    // MARK: 表格

    private struct ParsedTable {
        let header: [String]
        let rows: [[String]]
        let next: Int
    }

    private static func parseTable(lines: [String], start: Int) -> ParsedTable? {
        guard start + 1 < lines.count else { return nil }
        let headerLine = lines[start].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|") else { return nil }
        let delimiterLine = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard isTableDelimiter(delimiterLine) else { return nil }

        let header = splitTableCells(headerLine)
        let delimiter = splitTableCells(delimiterLine)
        guard !header.isEmpty, header.count == delimiter.count else { return nil }
        guard header.contains(where: { !$0.isEmpty }) else { return nil }

        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, candidate.contains("|") else { break }
            var cells = splitTableCells(candidate)
            if cells.count < header.count {
                cells.append(contentsOf: Array(repeating: "", count: header.count - cells.count))
            } else if cells.count > header.count {
                cells = Array(cells.prefix(header.count))
            }
            rows.append(cells)
            index += 1
        }

        return ParsedTable(header: header, rows: rows, next: index)
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        guard line.contains("|") || line.contains("-") else { return false }
        let cells = splitTableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy {
            $0.range(of: "^:?-{2,}:?$", options: .regularExpression) != nil
        }
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "|" {
                cells.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        cells.append(current)
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine.hasPrefix("|"), !cells.isEmpty {
            cells.removeFirst()
        }
        if trimmedLine.hasSuffix("|"), !trimmedLine.hasSuffix("\\|"), !cells.isEmpty {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: 段落拼接

    private static func joinParagraph(_ lines: [String]) -> String {
        var result = ""
        for (index, rawLine) in lines.enumerated() {
            let hardBreak = rawLine.hasSuffix("  ") || rawLine.hasSuffix("\\")
            var piece = rawLine.trimmingCharacters(in: .whitespaces)
            if hardBreak, piece.hasSuffix("\\") {
                piece.removeLast()
                piece = piece.trimmingCharacters(in: .whitespaces)
            }
            if index == 0 {
                result = piece
                continue
            }
            if hardBreak {
                result += "\n" + piece
            } else if shouldJoinTightly(result.last, piece.first) {
                result += piece
            } else {
                result += " " + piece
            }
        }
        return result
    }

    private static func shouldJoinTightly(_ previous: Character?, _ next: Character?) -> Bool {
        guard let previous, let next else { return true }
        if isWide(previous), isWide(next) { return true }
        if "，。！？；：、）》」』】…,.!?;:)".contains(next) { return true }
        if "（《「『【(".contains(previous) { return true }
        return false
    }

    private static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

// MARK: - Native document layout

private final class ParsedMarkdown: NSObject {
    let blocks: [ArenaMarkdownBlock]
    init(_ raw: String) { blocks = ArenaMarkdownParser.blocks(in: raw) }
    static let cache: NSCache<NSString, ParsedMarkdown> = {
        let cache = NSCache<NSString, ParsedMarkdown>()
        cache.totalCostLimit = 3_000_000
        return cache
    }()
    static func read(_ text: String) -> ParsedMarkdown {
        let key = text as NSString
        if let doc = cache.object(forKey: key) { return doc }
        let doc = ParsedMarkdown(text)
        cache.setObject(doc, forKey: key, cost: key.length)
        return doc
    }
}

struct ArenaMarkdownView: View {
    let text: String
    var onSource: ((String) -> Void)? = nil
    var sources: Set<String> = []
    private static let citationGroup = try! NSRegularExpression(pattern: #"\[\s*S\d+(?:\s*[,，、;；]\s*S\d+)*\s*\]"#)
    private static let citationID = try! NSRegularExpression(pattern: #"S\d+"#)

    var body: some View {
        let blocks = ParsedMarkdown.read(text).blocks
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { i in block(blocks[i]) }
        }
        .font(.system(size: 16))
        .lineSpacing(4)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "arena-source", url.host == "entry", sources.contains(url.lastPathComponent) {
                onSource?(url.lastPathComponent)
                return .handled
            }
            if Self.isWebURL(url) { return .systemAction }
            return .discarded
        })
    }

    private static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }

    @ViewBuilder private func block(_ block: ArenaMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text)).font(.system(size: level == 1 ? 24 : level == 2 ? 20 : 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader).padding(.top, 4)
        case let .paragraph(text):
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        case let .list(items, _):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: item.marker).monospacedDigit().foregroundStyle(.secondary)
                        Text(inline(item.text)).fixedSize(horizontal: false, vertical: true)
                    }.padding(.leading, CGFloat(min(6,item.depth))*12)
                }
            }
        case let .quote(lines):
            VStack(alignment: .leading, spacing: 4) {
                Text(inline(lines.joined(separator: "\n"))).foregroundStyle(.secondary)
            }.padding(.leading, 14)
             .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 3) }
        case let .code(code, _):
            ScrollView(.horizontal) {
                Text(verbatim: code).font(.system(size: 13, design: .monospaced)).padding(12)
            }.background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055)))
        case let .table(header, rows):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow { ForEach(header.indices, id: \.self) { i in tableCell(header[i]).fontWeight(.semibold) } }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow { ForEach(rows[r].indices, id: \.self) { c in tableCell(rows[r][c]) } }
                    }
                }.padding(10)
            }.background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        case .divider:
            Divider()
        }
    }

    private func tableCell(_ value: String) -> some View {
        Text(inline(value)).font(.system(size: 14)).frame(maxWidth: 290, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func inline(_ original: String) -> AttributedString {
        // Adjacent [S1][S2] is report notation. Escape its brackets before
        // inline Markdown parsing so the displayed source IDs stay intact.
        let escaped = NSMutableString(string: original)
        for m in Self.citationGroup.matches(in: original, range: NSRange(location: 0, length: escaped.length)).reversed() {
            let literal = escaped.substring(with: m.range)
            escaped.replaceCharacters(in: m.range, with: "\\[" + literal.dropFirst().dropLast() + "\\]")
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: escaped as String, options: options)) ?? AttributedString(original)
        for run in Array(result.runs) {
            if let url = run.link, !Self.isWebURL(url) { result[run.range].link = nil }
            if run.imageURL != nil { result[run.range].imageURL = nil }
        }
        if !sources.isEmpty {
            let plain = String(result.characters)
            for group in Self.citationGroup.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                for m in Self.citationID.matches(in: plain, range: group.range) {
                    guard let r = Range(m.range,in: plain), sources.contains(String(plain[r])),
                          let lo = AttributedString.Index(r.lowerBound,within: result),
                          let hi = AttributedString.Index(r.upperBound,within: result) else { continue }
                    result[lo..<hi].link = URL(string: "arena-source://entry/" + String(plain[r]))
                }
            }
        }
        return result
    }
}

// MARK: - 超长完整报告：单篇原生可选富文本

/// 完整报告整篇阅读面。逐块 SwiftUI 文本视图在超长报告上要创建上千个视图，
/// 表格和代码还各套一层横向滚动容器，展开时会明显卡住。这里改为一次排版出
/// 一份可选中的富文本：标题、正文、列表、引用、代码、表格和 [S#] 出处都在
/// 同一个文本视图里，因此可以跨段选择和复制，点出处仍然回到保存的原文。
///
/// 边界：只在用户展开「完整报告」且报告确实很长时使用；短材料继续走原有逐块
/// 排版，行内样式、动效和标题的无障碍层级都不变。排版是一次性的：外层滚动由
/// 阅读页统一管理，逐块懒加载会在滚动中估算高度，滚动条和阅读位置都会跳动。
enum ArenaReportSurfacePolicy {
    /// 旧排版要创建的子视图数达到此值才换单篇富文本。一张 500 行三列表或
    /// 一份 500 项列表只算一个块，但各自要创建上千个文本视图，所以按单元格和
    /// 列表项估算，而不是只看块数。普通完整报告约 40 块、几十个子视图。
    static let estimatedSubviewThreshold = 120

    /// 逐块累计估计，够了就早停：不必解析完整篇才知道该换面。
    static func prefersTextSurface(blocks: [ArenaMarkdownBlock]) -> Bool {
        var estimate = 0
        for block in blocks {
            estimate += estimatedSubviews(of: block)
            if estimate >= estimatedSubviewThreshold { return true }
        }
        return estimate >= estimatedSubviewThreshold
    }

    /// 解析结果已经按原文缓存，这里只读块。
    static func prefersTextSurface(for text: String) -> Bool {
        prefersTextSurface(blocks: ParsedMarkdown.read(text).blocks)
    }

    /// 估计旧排版会为这一块创建多少个子视图：表格按单元格、列表按项目，
    /// 其余块各算一个文本视图。
    static func estimatedSubviews(of block: ArenaMarkdownBlock) -> Int {
        switch block {
        case let .table(header, rows):
            // 每个单元格一个文本视图，外加网格与横向滚动容器的固定开销。
            let columns = max(1, header.count)
            let cells = columns + rows.reduce(0) { $0 + max(1, min($1.count, columns)) }
            return cells + 2
        case let .list(items, _):
            // 每个列表项一个项目符号加一个正文。
            return max(1, items.count) * 2
        default:
            return 1
        }
    }
}

/// 把解析后的块排成一份 NSAttributedString。字号、行距和块间距对齐逐块视图
/// 的取值（正文 16、行距 4、块间距 10），方便同一篇报告在两条路径上读起来一样。
/// 表格排成按列对齐的制表位文本，代码用等宽字体加整行底纹。
enum ArenaReportTypesetter {
    // 与 ArenaMarkdownView 相同的出处记号。这里保留一份独立定义：两条路径
    // 解析同一段文字，可见文字由定向检查逐字对齐。
    static let citationGroup = try! NSRegularExpression(pattern: #"\[\s*S\d+(?:\s*[,，、;；]\s*S\d+)*\s*\]"#)
    static let citationID = try! NSRegularExpression(pattern: #"S\d+"#)

    static let bodySize: CGFloat = 16
    static let codeSize: CGFloat = 13
    static let tableSize: CGFloat = 14
    static let blockSpacing: CGFloat = 10
    /// 阅读页最窄的真实内容宽度：详情窗口最小 520 点，减去阅读页左右内边距
    /// 16×2，再留一点余量。并排表格必须在这个宽度内排得下，否则改为竖排。
    static let sideBySideWidthBudget: CGFloat = 460

    static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }

    /// 出处链接。点击后由文本视图交给阅读页打开保存原文。
    static func sourceLink(_ identifier: String) -> URL? {
        URL(string: "arena-source://entry/" + identifier)
    }

    // MARK: 排版

    static func attributedString(blocks: [ArenaMarkdownBlock], sources: Set<String>) -> NSAttributedString {
        let sink = Sink()
        for block in blocks {
            switch block {
            case let .heading(level, text):
                let size: CGFloat = level <= 1 ? 24 : level == 2 ? 20 : 17
                sink.line(inline(text, size: size, weight: .semibold, color: .labelColor),
                          style: style(before: 12, lineSpacing: 2))
            case let .paragraph(text):
                sink.line(inline(text, size: bodySize, weight: .regular, color: .labelColor),
                          style: style(before: blockSpacing))
            case let .list(items, _):
                for item in items {
                    let indent = CGFloat(min(6, item.depth)) * 12
                    let bodyIndent = indent + 20
                    let marker = NSMutableAttributedString(string: item.marker + "\t", attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: bodySize - 1, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ])
                    let lines = inline(item.text, size: bodySize, weight: .regular, color: .labelColor)
                    marker.append(firstLine(of: lines))
                    sink.line(marker, style: style(before: 4,
                                                  headIndent: bodyIndent,
                                                  firstLineHeadIndent: indent,
                                                  tabStops: [NSTextTab(textAlignment: .left, location: bodyIndent)]))
                    // 列表项的续行按正文对齐，不回到项目符号的位置。
                    for rest in remainingLines(of: lines) {
                        sink.line(rest, style: style(before: 0,
                                                     headIndent: bodyIndent,
                                                     firstLineHeadIndent: bodyIndent))
                    }
                }
            case let .quote(lines):
                let joined = inline(lines.joined(separator: "\n"), size: bodySize, weight: .regular,
                                    color: .secondaryLabelColor)
                sink.paragraphs(joined, style: style(before: 8, headIndent: 14, firstLineHeadIndent: 14))
            case let .code(text, _):
                guard !text.isEmpty else { break }
                let mono = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
                let piece = NSMutableAttributedString(string: text, attributes: [
                    .font: mono,
                    .foregroundColor: NSColor.labelColor,
                ])
                piece.addAttribute(.backgroundColor, value: NSColor.labelColor.withAlphaComponent(0.06),
                                   range: NSRange(location: 0, length: piece.length))
                sink.block(piece,
                           style: style(before: blockSpacing, headIndent: 10, firstLineHeadIndent: 10, lineSpacing: 2),
                           recordsAsCode: true)
            case let .table(header, rows):
                sink.block(tableText(header: header, rows: rows, before: blockSpacing),
                           style: style(before: blockSpacing, lineSpacing: 3),
                           recordsAsCode: false)
            case .divider:
                sink.line(NSAttributedString(string: String(repeating: "─", count: 24), attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]), style: style(before: 8))
            }
        }
        sink.finish(sources: sources)
        return sink.out
    }

    /// 纯排版高度，供检查与预览使用；文本视图自己复用已排好的布局。
    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0, width > 1 else { return 0 }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    // MARK: 段落样式

    private static func style(before: CGFloat,
                              headIndent: CGFloat = 0,
                              firstLineHeadIndent: CGFloat = 0,
                              tabStops: [NSTextTab]? = nil,
                              lineSpacing: CGFloat = 4) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = before
        style.headIndent = headIndent
        style.firstLineHeadIndent = firstLineHeadIndent
        if let tabStops { style.tabStops = tabStops }
        style.lineBreakMode = .byWordWrapping
        return style
    }

    // MARK: 行内

    /// 与 ArenaMarkdownView.inline 同样的转义与解析：相邻的 [S1][S2] 是报告
    /// 记号，先转义再解析，链接只保留 http(s)，其余协议一律去掉。
    static func inline(_ raw: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSMutableAttributedString {
        var source = raw
        if raw.contains("[") {
            let escaped = NSMutableString(string: raw)
            for match in citationGroup.matches(in: raw, range: NSRange(location: 0, length: escaped.length)).reversed() {
                let literal = escaped.substring(with: match.range)
                escaped.replaceCharacters(in: match.range, with: "\\[" + literal.dropFirst().dropLast() + "\\]")
            }
            source = escaped as String
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(raw)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = NSMutableAttributedString(string: String(parsed[run.range].characters))
            let range = NSRange(location: 0, length: piece.length)
            piece.addAttributes([
                .font: font(size: size, weight: weight, intent: run.inlinePresentationIntent),
                .foregroundColor: color,
            ], range: range)
            if let url = run.link, isWebURL(url) {
                piece.addAttribute(.link, value: url, range: range)
            }
            // ~~已取消~~ 这类删除线只去掉标记、不保留样式会让内容看起来仍然有效。
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                piece.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            result.append(piece)
        }
        return result
    }

    static func font(size: CGFloat, weight: NSFont.Weight, intent: InlinePresentationIntent?) -> NSFont {
        var resolved = weight
        if intent?.contains(.stronglyEmphasized) == true {
            resolved = weight == .regular ? .semibold : .bold
        }
        if intent?.contains(.code) == true {
            return NSFont.monospacedSystemFont(ofSize: max(11, size - 1.5), weight: resolved == .regular ? .regular : .semibold)
        }
        var font = NSFont.systemFont(ofSize: size, weight: resolved)
        if intent?.contains(.emphasized) == true {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    // MARK: 表格

    /// 表格有两种排法，单元格都走与正文相同的行内解析，链接、强调和 [S#] 出处
    /// 都保留：
    /// - 列宽合计能放进最窄的真实阅读宽度时，按制表位并排，列首对齐；
    /// - 否则逐行写成「列标题　单元格内容」，交给文本视图按真实宽度自己折行。
    ///   不做逐字符测量、也不人工断行，因此 emoji 等多码元字符不会被拆开。
    static func tableText(header: [String], rows: [[String]], before: CGFloat) -> NSAttributedString {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return NSAttributedString() }

        let head = (0..<columns).map { index in
            index < header.count
                ? inline(header[index], size: tableSize, weight: .semibold, color: .labelColor)
                : NSAttributedString(string: "")
        }
        let body = rows.map { row in
            (0..<columns).map { index in
                index < row.count
                    ? inline(row[index], size: tableSize, weight: .regular, color: .labelColor)
                    : NSAttributedString(string: "")
            }
        }

        var widths = head.map(measured)
        for row in body {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], measured(cell))
            }
        }
        let padding: CGFloat = 18
        let total = widths.reduce(0, +) + padding * CGFloat(columns - 1)
        if total <= sideBySideWidthBudget {
            return sideBySide(header: head, rows: body, widths: widths, padding: padding, before: before)
        }
        return stacked(header: header, rows: rows, columns: columns, before: before)
    }

    /// 并排：一格一段，列之间用制表位，表头加重并加下划线。
    private static func sideBySide(header: [NSAttributedString],
                                   rows: [[NSAttributedString]],
                                   widths: [CGFloat],
                                   padding: CGFloat,
                                   before: CGFloat) -> NSAttributedString {
        var stops: [NSTextTab] = []
        var position: CGFloat = 0
        for width in widths.dropLast() {
            position += width + padding
            stops.append(NSTextTab(textAlignment: .left, location: position))
        }

        var paragraphs: [NSAttributedString] = []
        func emit(_ cells: [NSAttributedString], underlined: Bool) {
            let line = NSMutableAttributedString()
            for (index, cell) in cells.enumerated() {
                if index > 0 { line.append(NSAttributedString(string: "\t")) }
                line.append(cell)
            }
            let range = NSRange(location: 0, length: line.length)
            if underlined {
                line.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                line.addAttribute(.underlineColor, value: NSColor.tertiaryLabelColor, range: range)
            }
            line.addAttribute(.paragraphStyle,
                              value: style(before: paragraphs.isEmpty ? before : 0,
                                           tabStops: stops.isEmpty ? nil : stops,
                                           lineSpacing: 3),
                              range: range)
            paragraphs.append(line)
        }

        emit(header, underlined: true)
        for row in rows { emit(row, underlined: false) }
        return joined(paragraphs)
    }

    /// 竖排：每个单元格一行「列标题　内容」，折行交给文本视图；续行与内容起点
    /// 对齐，行的归属靠缩进和标题保持。
    private static func stacked(header: [String],
                                rows: [[String]],
                                columns: Int,
                                before: CGFloat) -> NSAttributedString {
        let space = "\u{3000}"
        let titles = (0..<columns).map { index -> NSAttributedString in
            index < header.count
                ? inline(header[index], size: tableSize, weight: .semibold, color: .secondaryLabelColor)
                : NSAttributedString(string: "第 \(index + 1) 列", attributes: [
                    .font: NSFont.systemFont(ofSize: tableSize, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                  ])
        }
        let separatorWidth = measured(NSAttributedString(
            string: "\u{3000}", attributes: [.font: NSFont.systemFont(ofSize: tableSize)]
        ))
        let hangingIndent = (titles.map(measured).max() ?? 0) + separatorWidth

        var paragraphs: [NSAttributedString] = []
        func emitCell(_ title: NSAttributedString, _ value: NSAttributedString) {
            let line = NSMutableAttributedString()
            line.append(title)
            line.append(NSAttributedString(string: space))
            line.append(value)
            line.addAttribute(.paragraphStyle,
                              value: style(before: paragraphs.isEmpty ? before : 3,
                                           headIndent: hangingIndent,
                                           lineSpacing: 3),
                              range: NSRange(location: 0, length: line.length))
            paragraphs.append(line)
        }
        for row in rows {
            for index in 0..<columns {
                let value = index < row.count
                    ? inline(row[index], size: tableSize, weight: .regular, color: .labelColor)
                    : NSAttributedString(string: "")
                emitCell(titles[index], value)
            }
        }
        // 只有表头的表也把标题写出来，避免整块内容变成空白。
        if rows.isEmpty {
            for title in titles { emitCell(title, NSAttributedString(string: "")) }
        }
        return joined(paragraphs)
    }

    private static func joined(_ paragraphs: [NSAttributedString]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(paragraph)
        }
        return result
    }

    /// 整格测量一次，按码元索引切开文字是禁止的：emoji 等代理对会被拆坏。
    private static func measured(_ cell: NSAttributedString) -> CGFloat {
        cell.size().width
    }

    // MARK: 拼装

    /// 收集每一行并在结束时补出处链接。代码块不参与链接，保持抄录原样。
    private final class Sink {
        let out = NSMutableAttributedString()
        private var codeRanges: [NSRange] = []

        func line(_ piece: NSAttributedString, style: NSParagraphStyle) {
            let start = out.length
            out.append(piece)
            out.append(NSAttributedString(string: "\n"))
            out.addAttribute(.paragraphStyle, value: style,
                             range: NSRange(location: start, length: out.length - start))
        }

        /// 多段内容按行拆开：只有块内第一段带前距，其余段不再拉开，
        /// 否则表格的每一行、代码的每一行都会多出一段空隙。
        func paragraphs(_ piece: NSAttributedString, style: NSParagraphStyle) {
            block(piece, style: style, recordsAsCode: false)
        }

        func block(_ piece: NSAttributedString, style: NSParagraphStyle, recordsAsCode: Bool) {
            let start = out.length
            out.append(piece)
            let plain = piece.string as NSString
            let body = ArenaReportTypesetter.style(before: 0,
                                                  headIndent: style.headIndent,
                                                  firstLineHeadIndent: style.firstLineHeadIndent,
                                                  tabStops: style.tabStops,
                                                  lineSpacing: style.lineSpacing)
            var cursor = 0
            var first = true
            while cursor < plain.length {
                let search = NSRange(location: cursor, length: plain.length - cursor)
                let cut = plain.range(of: "\n", range: search)
                let end = cut.location == NSNotFound ? plain.length : cut.location
                let range = NSRange(location: start + cursor, length: end - cursor)
                // 表格自带制表位样式，这里不再覆盖，否则列对齐会丢。
                if piece.attribute(.paragraphStyle, at: cursor, effectiveRange: nil) == nil {
                    out.addAttribute(.paragraphStyle, value: first ? style : body, range: range)
                }
                first = false
                cursor = cut.location == NSNotFound ? plain.length : cut.location + 1
            }
            out.append(NSAttributedString(string: "\n"))
            if recordsAsCode {
                codeRanges.append(NSRange(location: start, length: piece.length))
            }
        }

        func finish(sources: Set<String>) {
            if !sources.isEmpty {
                let plain = out.string
                let full = NSRange(location: 0, length: (plain as NSString).length)
                for group in ArenaReportTypesetter.citationGroup.matches(in: plain, range: full) {
                    for match in ArenaReportTypesetter.citationID.matches(in: plain, range: group.range) {
                        if codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
                        let identifier = (plain as NSString).substring(with: match.range)
                        guard sources.contains(identifier),
                              let url = ArenaReportTypesetter.sourceLink(identifier) else { continue }
                        out.addAttribute(.link, value: url, range: match.range)
                    }
                }
            }
            while out.length > 0, out.string.hasSuffix("\n") {
                out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
            }
        }
    }

    private static func firstLine(of piece: NSAttributedString) -> NSAttributedString {
        let plain = piece.string as NSString
        let cut = plain.range(of: "\n")
        guard cut.location != NSNotFound else { return piece }
        return piece.attributedSubstring(from: NSRange(location: 0, length: cut.location))
    }

    private static func remainingLines(of piece: NSAttributedString) -> [NSAttributedString] {
        let plain = piece.string as NSString
        var result: [NSAttributedString] = []
        var location = 0
        while location < plain.length {
            let rest = NSRange(location: location, length: plain.length - location)
            let cut = plain.range(of: "\n", range: rest)
            let end = cut.location == NSNotFound ? plain.length : cut.location
            result.append(piece.attributedSubstring(from: NSRange(location: location, length: end - location)))
            location = cut.location == NSNotFound ? plain.length : cut.location + 1
        }
        return result
    }
}

/// 完整报告的文本视图。到处保存原文仍然靠阅读页的既有覆盖层，这里只把
/// [S#] 交给阅读页，网页链接交给系统打开。
final class ArenaReportTextView: NSTextView {
    var onSource: ((String) -> Void)?

    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let url = link as? URL else { return }
        if url.scheme == "arena-source", url.host == "entry" {
            let identifier = url.lastPathComponent
            guard !identifier.isEmpty else { return }
            onSource?(identifier)
            return
        }
        if ArenaReportTypesetter.isWebURL(url) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 完整报告正文。高度由文本视图自己的布局管理器给出，跟随阅读页的可用宽度。
struct ArenaReportTextSurface: NSViewRepresentable {
    let text: String
    var onSource: ((String) -> Void)? = nil
    var sources: Set<String> = []

    final class Coordinator {
        var content: NSAttributedString?
        var renderedText: String?
        var renderedSources: Set<String> = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        // 报告可以有三万点高。连续布局会在显示时排完并绘制整篇；按需布局只处理
        // 可见部分。高度仍由整篇排版得到，选择和复制都不受影响。
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let view = ArenaReportTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 0), textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.importsGraphics = false
        view.usesFontPanel = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.linkTextAttributes = [
            NSAttributedString.Key.foregroundColor: NSColor.linkColor,
            NSAttributedString.Key.underlineStyle: 0,
            NSAttributedString.Key.cursor: NSCursor.pointingHand,
        ]
        view.onSource = onSource
        apply(to: view, context: context)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        (view as? ArenaReportTextView)?.onSource = onSource
        apply(to: view, context: context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let inset = nsView.textContainerInset
        let proposed = proposal.width ?? (nsView.bounds.width - inset.width * 2)
        guard proposed > 1,
              let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: proposed, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height) + inset.height * 2
        return CGSize(width: proposed + inset.width * 2, height: height)
    }

    private func apply(to view: NSTextView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.renderedText == text, coordinator.renderedSources == sources,
           coordinator.content != nil { return }
        let content = ArenaReportTypesetter.attributedString(
            blocks: ParsedMarkdown.read(text).blocks,
            sources: sources
        )
        coordinator.content = content
        coordinator.renderedText = text
        coordinator.renderedSources = sources
        view.textStorage?.setAttributedString(content)
    }
}

/// 长报告正文的挂载壳。`AXPress` 这类默认动作在按钮自己的调用栈里翻转展开状态，
/// 如果当场建出三万点高的文本视图，AX 请求会在挂载和绘制里超时（-25200），
/// 即使界面最终确实展开了。这里先让按钮那次调用尽快返回，等到下一次主循环再
/// 创建正文：普通点击感觉不到间隔，读屏拿到的仍是同一个按钮、同一份内容。
///
/// 占位只有 1 点且不参与无障碍，页面不会先塌陷再撑开。
struct ArenaDeferredReportSurface: View {
    let text: String
    var onSource: ((String) -> Void)? = nil
    var sources: Set<String> = []

    @State private var isMounted = false

    var body: some View {
        Group {
            if isMounted {
                ArenaReportTextSurface(text: text, onSource: onSource, sources: sources)
            } else {
                Color.clear
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
        }
        .onAppear {
            guard !isMounted else { return }
            DispatchQueue.main.async { isMounted = true }
        }
    }
}
