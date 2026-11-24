import Foundation

// MARK: - 候选结论的固定区块

/// The drafting prompt asks for four readable Markdown blocks. This parser is
/// deliberately strict about the three fixed headings: it only returns a digest
/// when `## 直接建议` and `## 成立条件` are both present with content. Anything
/// else falls back to the old lead-paragraph reader, so a saved report from an
/// older session is never re-interpreted as the new format.
struct ArenaDigestSection: Identifiable, Equatable {
    enum Kind: String, Hashable {
        case advice
        case conditions
        case disputes
        case other
    }

    let id: String
    let kind: Kind
    let raw: String
}

struct ArenaDigestItem: Identifiable, Equatable {
    let id: String
    let raw: String

    var plain: String { ArenaDigestText.plain(raw) }
    var citations: [String] { ArenaDigestCitations.ids(in: raw) }
    var isNoneMarker: Bool { ArenaDigestText.isNoneMarker(plain) }
}

struct ArenaCandidateDigest: Equatable {
    let sections: [ArenaDigestSection]
    let adviceSection: ArenaDigestSection
    let conditionSection: ArenaDigestSection
    let disputeSection: ArenaDigestSection?
    let otherSection: ArenaDigestSection?

    var adviceRaw: String { adviceSection.raw }
    var advicePlain: String { ArenaDigestText.plain(adviceSection.raw) }
    var conditions: [ArenaDigestItem] {
        ArenaDigestItems.parse(conditionSection.raw, prefix: "condition")
    }
    var disputes: [ArenaDigestItem] {
        guard let disputeSection else { return [] }
        return ArenaDigestItems.parse(disputeSection.raw, prefix: "dispute")
    }
    var otherRaw: String {
        sections
            .filter { $0.kind == .other }
            .map(\.raw)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
    var otherPlain: String { ArenaDigestText.plain(otherRaw) }
    var hasOther: Bool { !otherPlain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Reliable parse: the three fixed blocks appear once each, in order, and
    /// none is empty. "无" is written explicitly inside a block; a missing
    /// dispute block is not treated as "no disputes" and falls back to the old
    /// lead-paragraph reader. The fourth block stays optional.
    static func parse(_ text: String) -> ArenaCandidateDigest? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var collected: [(kind: ArenaDigestSection.Kind, level: Int, heading: String, lines: [String])] = []
        var current: (kind: ArenaDigestSection.Kind, level: Int, heading: String, lines: [String])?

        func flush() {
            guard let value = current else { return }
            let raw = value.lines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            collected.append((value.kind, value.level, value.heading, [raw]))
            current = nil
        }

        var openFence: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = openFence {
                current?.lines.append(line)
                if trimmed.hasPrefix(fence) { openFence = nil }
                continue
            }
            if let fence = ArenaDigestHeading.fence(line) {
                openFence = fence
                current?.lines.append(line)
                continue
            }
            if let heading = ArenaDigestHeading.read(line),
               let kind = ArenaDigestHeading.kind(heading.name) {
                flush()
                var content: [String] = []
                if !heading.rest.isEmpty { content.append(heading.rest) }
                current = (kind, heading.level, heading.name, content)
                continue
            }
            if let value = current {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#"),
                   let heading = ArenaDigestHeading.read(line),
                   heading.level <= value.level {
                    // A different Markdown heading ends a fixed block. The
                    // free-form other section keeps its own subheadings.
                    if value.kind == .other {
                        current?.lines.append(line)
                        continue
                    }
                    flush()
                    continue
                }
                current?.lines.append(line)
            }
        }
        flush()

        let fixedKinds: [ArenaDigestSection.Kind] = [.advice, .conditions, .disputes]
        let fixed = collected.filter { fixedKinds.contains($0.kind) }
        guard fixed.count == 3,
              fixed.map(\.kind) == fixedKinds,
              fixed.allSatisfy({
                  !$0.lines.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return nil
        }

        func section(_ part: (kind: ArenaDigestSection.Kind, level: Int, heading: String, lines: [String])) -> ArenaDigestSection {
            ArenaDigestSection(
                id: "\(part.kind.rawValue)-1",
                kind: part.kind,
                raw: part.lines.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let adviceSection = section(fixed[0])
        let conditionSection = section(fixed[1])
        let disputeSection = section(fixed[2])
        let otherRaw = collected
            .filter { $0.kind == .other }
            .map { $0.lines.joined().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let otherSection = otherRaw.isEmpty
            ? nil
            : ArenaDigestSection(id: "other-1", kind: .other, raw: otherRaw)

        var sections: [ArenaDigestSection] = [adviceSection, conditionSection, disputeSection]
        if let otherSection { sections.append(otherSection) }
        return ArenaCandidateDigest(
            sections: sections,
            adviceSection: adviceSection,
            conditionSection: conditionSection,
            disputeSection: disputeSection,
            otherSection: otherSection
        )
    }
}

private enum ArenaDigestHeading {
    struct Value {
        let level: Int
        let name: String
        let rest: String
    }

    static func read(_ line: String) -> Value? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(hashes) else { return nil }
            let remainder = trimmed.dropFirst(hashes)
            guard remainder.first == " " || remainder.first == "\t" else { return nil }
            var body = remainder.trimmingCharacters(in: .whitespaces)
            if let trailing = body.range(of: #"\s+#+\s*$"#, options: .regularExpression) {
                body.removeSubrange(trailing)
            }
            body = body.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return nil }
            return Value(level: hashes, name: body, rest: "")
        }

        // Tolerate a bold heading line, e.g. "**直接建议**：" or
        // "**直接建议**：先用手机验证". The rest of the line is block content.
        for marker in ["**", "__"] {
            guard trimmed.hasPrefix(marker) else { continue }
            let bodyStart = trimmed.index(trimmed.startIndex, offsetBy: marker.count)
            guard let closing = trimmed.range(of: marker, range: bodyStart..<trimmed.endIndex) else {
                continue
            }
            let name = String(trimmed[bodyStart..<closing.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            var rest = String(trimmed[closing.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("：") || rest.hasPrefix(":") {
                rest.removeFirst()
                rest = rest.trimmingCharacters(in: .whitespaces)
            }
            if rest == marker { rest = "" }
            return Value(level: 2, name: name, rest: rest)
        }

        // web-driver reads the page's innerText, so a Markdown heading arrives
        // as a bare line: "直接建议" instead of "## 直接建议". Recognize only
        // the fixed names (longest first) and an optional colon; ordinary
        // prose is never promoted to a block heading.
        let bareNames = [
            "影响建议的未决分歧",
            "未决分歧",
            "直接建议",
            "成立条件",
            "适用条件",
            "其他说明",
            "其他正文",
            "其他",
        ]
        for name in bareNames {
            if trimmed == name {
                return Value(level: 2, name: name, rest: "")
            }
            for separator in ["：", ":"] {
                let prefix = name + separator
                guard trimmed.hasPrefix(prefix) else { continue }
                let rest = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                return Value(level: 2, name: name, rest: rest)
            }
        }
        return nil
    }

    /// A fenced code block is content, never a source of fixed headings. The
    /// returned marker is the three-character opener used as its closing test.
    static func fence(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        return String(trimmed.prefix(3))
    }

    static func kind(_ name: String) -> ArenaDigestSection.Kind? {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "**", with: "")
        value = value.replacingOccurrences(of: "__", with: "")
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t：:"))
        if let suffix = value.range(of: #"[（(][^）)]*[）)]\s*$"#, options: .regularExpression) {
            value.removeSubrange(suffix)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t：:"))
        }
        switch value {
        case "直接建议":
            return .advice
        case "成立条件", "适用条件":
            return .conditions
        case "影响建议的未决分歧", "未决分歧":
            return .disputes
        case "其他说明", "其他正文", "其他":
            return .other
        default:
            return nil
        }
    }
}

private enum ArenaDigestItems {
    static func parse(_ raw: String, prefix: String) -> [ArenaDigestItem] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var chunks: [String] = []
        var current: [String] = []

        func flush() {
            guard !current.isEmpty else { return }
            let text = current
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { chunks.append(text) }
            current.removeAll(keepingCapacity: true)
        }

        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                continue
            }
            if let stripped = ArenaDigestText.stripListMarker(trimmed) {
                flush()
                current = [stripped]
                continue
            }
            if current.isEmpty {
                current = [trimmed]
            } else {
                current.append(trimmed)
            }
        }
        flush()

        return chunks.enumerated().map { index, text in
            ArenaDigestItem(id: "\(prefix)-\(index + 1)", raw: text)
        }
    }
}

enum ArenaDigestText {
    static func plain(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            var value = line.trimmingCharacters(in: .whitespaces)
            if let stripped = stripListMarker(value) { value = stripped }
            value = value.replacingOccurrences(
                of: #"^\s*#{1,6}\s*"#,
                with: "",
                options: .regularExpression
            )
            value = value.replacingOccurrences(of: "> ", with: "")
            value = value.replacingOccurrences(of: "**", with: "")
            value = value.replacingOccurrences(of: "__", with: "")
            value = value.replacingOccurrences(of: "`", with: "")
            value = value.replacingOccurrences(of: "~~", with: "")
            lines.append(value)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripListMarker(_ line: String) -> String? {
        guard let range = line.range(
            of: #"^\s*(?:[-*+•·‣–]|\d{1,3}[.)、])\s+(.*)$"#,
            options: .regularExpression
        ) else { return nil }
        let matched = String(line[range])
        guard let content = matched.range(
            of: #"^\s*(?:[-*+•·‣–]|\d{1,3}[.)、])\s+"#,
            options: .regularExpression
        ) else { return matched }
        return String(matched[content.upperBound...])
    }

    static func isNoneMarker(_ text: String) -> Bool {
        let compact = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "。．.；;，,、:："))
        return [
            "无",
            "无额外条件",
            "没有",
            "暂无",
            "无待核对项",
            "没有额外条件",
            "无未决分歧",
            "暂无未决分歧",
            "无待核对事实",
            "暂无需核对",
        ].contains(compact)
    }
}

enum ArenaDigestCitations {
    private static let bracket = try! NSRegularExpression(pattern: #"\[([^\]]+)\]"#)
    private static let identifier = try! NSRegularExpression(pattern: #"S\d+"#)
    // Only a whole bracket of source ids is a citation group. "[备注 S2]" is
    // ordinary text and must stay verbatim.
    private static let group = try! NSRegularExpression(
        pattern: #"^S\d+(?:\s*[,，、;；]\s*S\d+)*$"#
    )

    static func ids(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in bracket.matches(in: text, range: range) {
            guard let innerRange = Range(match.range(at: 1), in: text) else { continue }
            let inner = String(text[innerRange]).trimmingCharacters(in: .whitespaces)
            let innerRangeNS = NSRange(inner.startIndex..., in: inner)
            guard let first = group.firstMatch(in: inner, range: innerRangeNS),
                  first.range == innerRangeNS else { continue }
            for token in identifier.matches(in: inner, range: innerRangeNS) {
                guard let tokenRange = Range(token.range, in: inner) else { continue }
                let value = String(inner[tokenRange])
                if !result.contains(value) { result.append(value) }
            }
        }
        return result
    }
}

// MARK: - 图解模型

enum ArenaReportGraphNodeKind: Equatable {
    case advice
    case condition
    case dispute
    case verify
}

struct ArenaReportGraphNode: Identifiable, Equatable {
    let id: String
    let kind: ArenaReportGraphNodeKind
    let title: String
    let text: String
    let citations: [String]
}

struct ArenaReportGraphEdge: Identifiable, Equatable {
    let id: String
    let from: String
    let to: String
    let label: String
}

struct ArenaReportGraph: Equatable {
    let nodes: [ArenaReportGraphNode]
    let edges: [ArenaReportGraphEdge]
    let note: String
}

enum ArenaReportGraphBuilder {
    static let note = "连线只表示候选原文把该条目列在对应区块，不表示因果、先后或时间顺序。点击节点可读原文并打开出处。"

    static func build(_ digest: ArenaCandidateDigest) -> ArenaReportGraph {
        var nodes: [ArenaReportGraphNode] = []
        var edges: [ArenaReportGraphEdge] = []

        let advice = ArenaReportGraphNode(
            id: "advice",
            kind: .advice,
            title: "直接建议",
            text: digest.advicePlain,
            citations: ArenaDigestCitations.ids(in: digest.adviceRaw)
        )
        nodes.append(advice)

        let conditions = digest.conditions.filter { !$0.isNoneMarker }
        for item in conditions {
            nodes.append(
                ArenaReportGraphNode(
                    id: item.id,
                    kind: .condition,
                    title: "成立条件",
                    text: item.plain,
                    citations: item.citations
                )
            )
            edges.append(
                ArenaReportGraphEdge(
                    id: "\(item.id)->advice",
                    from: item.id,
                    to: advice.id,
                    label: "成立条件"
                )
            )
        }

        let disputes = digest.disputes.filter { !$0.isNoneMarker }
        if !disputes.isEmpty {
            let verify = ArenaReportGraphNode(
                id: "verify",
                kind: .verify,
                title: "待核对",
                text: "按候选列出的未决分歧逐条打开出处，核对事实和条件是否成立。候选没有把未决分歧直接当作结论。",
                citations: []
            )
            nodes.append(verify)
            for item in disputes {
                nodes.append(
                    ArenaReportGraphNode(
                        id: item.id,
                        kind: .dispute,
                        title: "影响建议的未决分歧",
                        text: item.plain,
                        citations: item.citations
                    )
                )
                edges.append(
                    ArenaReportGraphEdge(
                        id: "\(item.id)->verify",
                        from: item.id,
                        to: verify.id,
                        label: "待核对"
                    )
                )
            }
        }

        return ArenaReportGraph(nodes: nodes, edges: edges, note: note)
    }
}

// MARK: - 独立离线 HTML

struct ArenaReportSourceRow: Identifiable, Equatable {
    let id: String
    let seatLabel: String
    let stageLabel: String
    let answer: String
}

struct ArenaReportPositionRow: Identifiable, Equatable {
    let provider: String
    let seatLabel: String
    let stance: String
    let stanceLabel: String
    let sourceID: String
    let answer: String

    var id: String { provider }
}

/// Everything the HTML and video artifacts need. It is built from the same
/// saved ballot and candidate text the reader shows; no model call is made.
struct ArenaReportArtifactInput {
    let question: String
    let outcome: String
    let isVerifiedConsensus: Bool
    let version: Int
    let candidateAuthor: String
    let candidateSourceID: String
    let digest: ArenaCandidateDigest
    let participants: [String]
    let seatLabels: [String: String]
    let positions: [ArenaReportPositionRow]
    let sources: [ArenaReportSourceRow]

    func seatLabel(_ provider: String) -> String {
        seatLabels[provider] ?? provider
    }

    var concernPositions: [ArenaReportPositionRow] {
        positions.filter { $0.stance == "conditional" || $0.stance == "oppose" }
    }
}

enum ArenaReportHTML {
    static func build(_ input: ArenaReportArtifactInput) -> String {
        let known = Set(input.sources.map(\.id))
        let graph = ArenaReportGraphBuilder.build(input.digest)
        let conditions = input.digest.conditions
        let disputes = input.digest.disputes
        let title = "AI Arena 讨论报告"

        var html: [String] = []
        html.append("<!doctype html>")
        html.append("<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">")
        html.append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">")
        html.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
        html.append("<meta name=\"generator\" content=\"AI Arena local report\">")
        html.append("<title>\(escape(title))</title>")
        html.append("<style>\(style)</style></head><body><main>")

        html.append("<header class=\"head\">")
        html.append("<p class=\"kicker\">AI Arena · 本地报告</p>")
        html.append("<h1>\(escape(title))</h1>")
        html.append("<p class=\"meta\"><span class=\"pill \(input.isVerifiedConsensus ? "ok" : "note")\">\(escape(input.outcome))</span>")
        html.append("<span>候选 v\(input.version)</span>")
        html.append("<span>起草：\(escape(input.candidateAuthor))")
        if !input.candidateSourceID.isEmpty {
            html.append("<a class=\"source-link\" href=\"#source-\(attribute(input.candidateSourceID))\">[\(escape(input.candidateSourceID))]</a>")
        }
        html.append("</span></p>")
        html.append("<p class=\"notice\">本文件由 AI Arena 本地模板生成。未包含原场附件，不加载远程资源，不执行模型 HTML 或脚本。缺席、跳过、未表态不计为同意。</p>")
        html.append("</header>")

        html.append("<section id=\"question\"><h2>原始问题</h2>")
        html.append("<blockquote class=\"raw\">\(escape(input.question))</blockquote></section>")

        html.append("<section id=\"map\"><h2>图解</h2>")
        html.append("<p class=\"note\">\(escape(graph.note))</p>")
        html.append("<div class=\"graph\">")
        html.append("<div class=\"column\"><h3>成立条件 → 直接建议</h3>")
        if conditions.isEmpty || conditions.allSatisfy(\.isNoneMarker) {
            html.append("<p class=\"empty\">候选写明无额外条件。</p>")
        } else {
            for (index, item) in conditions.enumerated() where !item.isNoneMarker {
                html.append("<a class=\"node\" href=\"#condition-\(index + 1)\"><span class=\"node-title\">条件 \(index + 1)</span><span>\(escape(short(item.plain, limit: 72)))</span></a>")
            }
        }
        html.append("</div>")
        html.append("<div class=\"column advice-column\"><h3>直接建议</h3>")
        html.append("<a class=\"node advice\" href=\"#advice\"><span class=\"node-title\">建议原文</span><span>\(escape(short(input.digest.advicePlain, limit: 120)))</span></a>")
        html.append("</div>")
        html.append("<div class=\"column\"><h3>未决分歧 → 待核对</h3>")
        if disputes.isEmpty || disputes.allSatisfy(\.isNoneMarker) {
            html.append("<p class=\"empty\">候选写明没有未决分歧。</p>")
        } else {
            for (index, item) in disputes.enumerated() where !item.isNoneMarker {
                html.append("<a class=\"node\" href=\"#dispute-\(index + 1)\"><span class=\"node-title\">分歧 \(index + 1)</span><span>\(escape(short(item.plain, limit: 72)))</span></a>")
            }
            html.append("<a class=\"node verify\" href=\"#verify\"><span class=\"node-title\">待核对</span><span>打开出处，逐条核对事实和条件。</span></a>")
        }
        html.append("</div></div></section>")

        html.append("<section id=\"advice\"><h2>直接建议</h2>")
        html.append("<div class=\"raw\">\(renderText(input.digest.adviceRaw, known: known))</div></section>")

        html.append("<section id=\"conditions\"><h2>成立条件</h2><ul class=\"items\">")
        if conditions.isEmpty {
            html.append("<li class=\"empty\">候选没有列出成立条件。</li>")
        } else {
            for (index, item) in conditions.enumerated() {
                let marker = item.isNoneMarker ? "none" : "item"
                html.append("<li class=\"\(marker)\" id=\"condition-\(index + 1)\"><div class=\"raw\">\(renderText(item.raw, known: known))</div>")
                html.append(citationLinks(item.citations, known: known))
                html.append("</li>")
            }
        }
        html.append("</ul></section>")

        html.append("<section id=\"disputes\"><h2>影响建议的未决分歧</h2><ul class=\"items\">")
        if disputes.isEmpty {
            html.append("<li class=\"empty\">候选没有列出未决分歧。</li>")
        } else {
            for (index, item) in disputes.enumerated() {
                let marker = item.isNoneMarker ? "none" : "item"
                html.append("<li class=\"\(marker)\" id=\"dispute-\(index + 1)\"><div class=\"raw\">\(renderText(item.raw, known: known))</div>")
                html.append(citationLinks(item.citations, known: known))
                if !item.isNoneMarker {
                    html.append("<p class=\"hint\"><a href=\"#verify\">按原文待核对</a></p>")
                }
                html.append("</li>")
            }
        }
        html.append("</ul></section>")

        if input.digest.hasOther {
            html.append("<details class=\"other\"><summary>其他正文</summary>")
            html.append("<div class=\"raw\">\(renderText(input.digest.otherRaw, known: known))</div></details>")
        }

        html.append("<section id=\"verify\"><h2>待核对</h2>")
        html.append("<p class=\"note\">这里只列出候选自己写明的未决分歧。请打开对应出处，核对事实、条件和适用范围；本文件不替模型补充结论。</p></section>")

        html.append("<section id=\"positions\"><h2>各席对 v\(input.version) 的表态</h2>")
        html.append("<p class=\"note\">只显示共享引擎按同版候选正文摘要核对过的表态。未出现的席位按“未明确表态”处理，不计为同意。</p>")
        html.append("<ul class=\"positions\">")
        for provider in input.participants {
            let seat = input.seatLabel(provider)
            if let position = input.positions.first(where: { $0.provider == provider }) {
                let stanceClass = "stance-\(escape(position.stance))"
                html.append("<li class=\"\(stanceClass)\"><span class=\"dot\"></span><strong>\(escape(seat))</strong>")
                html.append("<span class=\"stance\">\(escape(position.stanceLabel))</span>")
                if !position.sourceID.isEmpty {
                    html.append("<a class=\"source-link\" href=\"#source-\(attribute(position.sourceID))\">[\(escape(position.sourceID))]</a>")
                }
                if !position.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    html.append("<details><summary>表态原文</summary><div class=\"raw\">\(renderText(position.answer, known: known))</div></details>")
                }
                html.append("</li>")
            } else {
                html.append("<li class=\"missing\"><span class=\"dot\"></span><strong>\(escape(seat))</strong>")
                html.append("<span class=\"stance\">未对 v\(input.version) 明确表态（不计为同意）</span></li>")
            }
        }
        html.append("</ul></section>")

        html.append("<section id=\"sources\"><h2>保存原文与出处</h2>")
        html.append("<p class=\"note\">[S#] 与本场保存的历史记录一一对应。这里是原文，不是摘要。</p>")
        if input.sources.isEmpty {
            html.append("<p class=\"empty\">本场没有已保存的原文。</p>")
        } else {
            for source in input.sources {
                // The anchor lives on the raw-text container inside details.
                // Chromium/Safari open the nearest closed details when a
                // fragment points into it, so a source link reveals the text
                // without forcing every long source open by default.
                html.append("<details class=\"source\">")
                html.append("<summary><span class=\"source-id\">\(escape(source.id))</span> ")
                html.append("\(escape(source.seatLabel)) · \(escape(source.stageLabel))</summary>")
                html.append("<div class=\"raw\" id=\"source-\(attribute(source.id))\">\(renderText(source.answer, known: known))</div></details>")
            }
        }
        html.append("</section>")

        html.append("<footer>本报告对应保存的候选 v\(input.version) 与同版表态。模型陈述未经事实核验；缺席、跳过、超时与沉默均未计为同意。</footer>")
        html.append("</main></body></html>")
        return html.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func attribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: " ", with: "")
    }

    private static func short(_ text: String, limit: Int) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= limit { return compact }
        return String(compact.prefix(limit)) + "…"
    }

    private static let bracket = try! NSRegularExpression(pattern: #"\[([^\]]+)\]"#)
    private static let identifier = try! NSRegularExpression(pattern: #"S\d+"#)

    private static func renderText(_ text: String, known: Set<String>) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let ns = normalized as NSString
        let matches = bracket.matches(in: normalized, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return escape(normalized) }

        var result = ""
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result += escape(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            let original = ns.substring(with: match.range)
            let inner = ns.substring(with: match.range(at: 1))
            let identifiers = ArenaDigestCitations.ids(in: original)
            if !identifiers.isEmpty, identifiers.allSatisfy(known.contains) {
                // Keep the model's own grouping and separators; only the source
                // tokens become anchors. "[S1, S2]" stays one bracketed group.
                var innerHTML = ""
                var innerCursor = 0
                let innerNS = inner as NSString
                for token in identifier.matches(in: inner, range: NSRange(location: 0, length: innerNS.length)) {
                    if token.range.location > innerCursor {
                        innerHTML += escape(innerNS.substring(
                            with: NSRange(location: innerCursor, length: token.range.location - innerCursor)
                        ))
                    }
                    let tokenText = innerNS.substring(with: token.range)
                    innerHTML += "<a class=\"source-link\" href=\"#source-\(attribute(tokenText))\">\(escape(tokenText))</a>"
                    innerCursor = token.range.location + token.range.length
                }
                if innerCursor < innerNS.length {
                    innerHTML += escape(innerNS.substring(from: innerCursor))
                }
                result += "[" + innerHTML + "]"
            } else {
                result += escape(original)
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += escape(ns.substring(from: cursor))
        }
        return result
    }

    private static func citationLinks(_ identifiers: [String], known: Set<String>) -> String {
        let valid = identifiers.filter(known.contains)
        guard !valid.isEmpty else { return "" }
        return "<p class=\"citations\">出处：" + valid.map {
            "<a class=\"source-link\" href=\"#source-\(attribute($0))\">[\(escape($0))]</a>"
        }.joined(separator: " ") + "</p>"
    }

    private static let style = """
    :root { color-scheme: light; --ink:#17211d; --muted:#5f6b64; --line:#d9ded8; --paper:#f7f5ef; --card:#fffefb; --accent:#2f6f5e; --warm:#9a5b2e; --alert:#9b3b32; }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--paper); color:var(--ink); font-family:-apple-system, BlinkMacSystemFont, "PingFang SC", "Noto Sans CJK SC", "Hiragino Sans GB", sans-serif; line-height:1.65; }
    main { max-width:900px; margin:0 auto; padding:44px 24px 64px; }
    .head { border-bottom:2px solid var(--ink); padding-bottom:20px; margin-bottom:28px; }
    .kicker { margin:0 0 6px; color:var(--accent); font-size:12px; font-weight:700; letter-spacing:.12em; text-transform:uppercase; }
    h1 { margin:0 0 10px; font-size:30px; line-height:1.25; letter-spacing:-.01em; }
    h2 { margin:34px 0 12px; font-size:19px; line-height:1.35; }
    h3 { margin:0 0 8px; font-size:13px; color:var(--muted); font-weight:700; }
    .meta { display:flex; flex-wrap:wrap; gap:8px 12px; align-items:center; margin:0; color:var(--muted); font-size:13px; }
    .pill { display:inline-block; padding:2px 9px; border-radius:999px; font-weight:700; font-size:12px; letter-spacing:.02em; }
    .pill.ok { background:#e4efe9; color:#1d5b49; }
    .pill.note { background:#f3e8d8; color:#7b4a1e; }
    .notice, .note, .hint, footer { color:var(--muted); font-size:12.5px; }
    .notice { margin:12px 0 0; border-left:3px solid var(--line); padding-left:10px; }
    .raw { white-space:pre-wrap; overflow-wrap:anywhere; }
    blockquote { margin:0; padding:14px 16px; background:var(--card); border-left:4px solid var(--accent); border-radius:0 8px 8px 0; }
    .graph { display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr) minmax(0,1fr); gap:12px; margin-top:12px; }
    .column { min-width:0; }
    .node { display:block; margin:0 0 8px; padding:10px 11px; background:var(--card); border:1px solid var(--line); border-radius:9px; color:inherit; text-decoration:none; font-size:12.5px; }
    .node:hover, .node:focus { border-color:var(--accent); }
    .node-title { display:block; margin-bottom:3px; color:var(--muted); font-size:10.5px; font-weight:700; letter-spacing:.06em; }
    .node.advice { border-color:#b9d2c7; background:#f4faf7; }
    .verify { border-style:dashed; }
    .items { margin:0; padding:0; list-style:none; }
    .items li { margin:0 0 10px; padding:12px 14px; background:var(--card); border:1px solid var(--line); border-radius:9px; }
    .items li.none { color:var(--muted); }
    .citations { margin:6px 0 0; font-size:12px; }
    .source-link { color:var(--accent); text-decoration:none; font-variant-numeric:tabular-nums; }
    .source-link:hover { text-decoration:underline; }
    .positions { margin:0; padding:0; list-style:none; }
    .positions li { display:flex; flex-wrap:wrap; gap:7px; align-items:baseline; padding:9px 0; border-bottom:1px solid var(--line); }
    .positions li details { flex-basis:100%; }
    .dot { width:8px; height:8px; border-radius:50%; background:var(--muted); display:inline-block; }
    .stance-agree .dot { background:#2f7d5e; }
    .stance-conditional .dot { background:#b06a24; }
    .stance-oppose .dot { background:var(--alert); }
    .stance { color:var(--muted); font-size:12.5px; }
    .missing { color:var(--muted); }
    .missing .dot { background:transparent; border:1px solid var(--muted); }
    details { margin-top:8px; }
    summary { cursor:pointer; color:var(--accent); font-weight:600; }
    .source { background:var(--card); border:1px solid var(--line); border-radius:9px; padding:10px 12px; margin:0 0 8px; }
    .source summary { color:var(--ink); }
    .source-id { color:var(--accent); font-variant-numeric:tabular-nums; }
    .other { margin-top:22px; padding:12px 14px; background:var(--card); border:1px solid var(--line); border-radius:9px; }
    footer { margin-top:38px; padding-top:14px; border-top:1px solid var(--line); }
    @media (max-width:640px) { main { padding:28px 16px 48px; } h1 { font-size:24px; } .graph { grid-template-columns:1fr; } }
    @media print { body { background:#fff; } main { max-width:none; padding:0; } .node { break-inside:avoid; } }
    """
}
