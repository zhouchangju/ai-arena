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
