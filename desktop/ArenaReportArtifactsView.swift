import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 首屏候选要点

/// Shows the fixed blocks from the candidate verbatim. Unlike the old
/// lead-paragraph path there is no line limit here: the direct advice, its
/// conditions and the unresolved disagreements stay readable on the first
/// screen. The full candidate and source reader remain below this block.
struct ArenaReportDigestView: View {
    let digest: ArenaCandidateDigest
    let input: ArenaReportArtifactInput
    let compact: Bool
    let knownSources: Set<String>
    let onOpenSource: (String) -> Void
    let onOpenAuthor: () -> Void

    @State private var showDiagram = false
    @State private var notice: String?
    @State private var noticeIsError = false
    @State private var videoURL: URL?
    @State private var isRendering = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 13) {
            HStack(spacing: 10) {
                Text("候选要点")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                Button(action: onOpenAuthor) {
                    Text("\(input.candidateAuthor) 起草 · \(input.candidateSourceID)")
                }
                .buttonStyle(.link)
            }

            textSection("直接建议", text: digest.adviceRaw)
            itemSection(
                "成立条件",
                items: digest.conditions,
                empty: "候选没有列出成立条件。"
            )
            itemSection(
                "影响建议的未决分歧",
                items: digest.disputes,
                empty: "候选没有列出未决分歧。"
            )

            if digest.hasOther {
                DisclosureGroup("其他正文") {
                    markdown(digest.otherRaw)
                        .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
            }

            actionRow
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(noticeIsError ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showDiagram {
                ArenaReportDiagramView(
                    digest: digest,
                    knownSources: knownSources,
                    onOpenSource: onOpenSource
                )
                .padding(.top, 4)
            }
        }
        .padding(.vertical, compact ? 9 : 13)
        .padding(.horizontal, compact ? 12 : 16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.045))
        )
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                showDiagram.toggle()
            } label: {
                Label(showDiagram ? "隐藏图解" : "图解", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Button {
                exportHTML()
            } label: {
                Label("离线 HTML", systemImage: "safari")
            }
            Button {
                renderVideo()
            } label: {
                Label(isRendering ? "生成中…" : "讲解视频", systemImage: isRendering ? "hourglass" : "film")
            }
            .disabled(isRendering)
            if let videoURL {
                Button {
                    NSWorkspace.shared.open(videoURL)
                } label: {
                    Label("打开视频", systemImage: "play.rectangle")
                }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.top, 2)
    }

    private func textSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            markdown(text)
        }
    }

    private func itemSection(_ title: String, items: [ArenaDigestItem], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        markdown(item.raw)
                    }
                }
            }
        }
    }

    private func markdown(_ text: String) -> some View {
        ArenaMarkdownView(
            text: text,
            onSource: { identifier in
                if knownSources.contains(identifier) { onOpenSource(identifier) }
            },
            sources: knownSources
        )
    }

    private func setNotice(_ text: String, error: Bool = false) {
        notice = text
        noticeIsError = error
    }

    private func exportHTML() {
        let panel = NSSavePanel()
        panel.title = "导出离线 HTML"
        panel.prompt = "导出"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "AI Arena 报告 v\(input.version).html"
        if let type = UTType(filenameExtension: "html") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ArenaReportHTML.build(input).write(to: url, atomically: true, encoding: .utf8)
            setNotice("已导出离线 HTML（不含附件与远程资源）")
        } catch {
            setNotice("导出失败：\(error.localizedDescription)", error: true)
        }
    }

    private func renderVideo() {
        let panel = NSSavePanel()
        panel.title = "生成讲解视频"
        panel.prompt = "生成"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "AI Arena 讲解 v\(input.version).mp4"
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let shots = ArenaReportVideoPlan.shots(for: input)
        isRendering = true
        setNotice("正在本地生成无声字幕视频…")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ArenaReportVideo.render(shots: shots, to: url)
                }.value
                await MainActor.run {
                    isRendering = false
                    videoURL = url
                    setNotice("已生成讲解视频，可在这里打开")
                }
            } catch {
                await MainActor.run {
                    isRendering = false
                    setNotice("生成失败：\(error.localizedDescription)", error: true)
                }
            }
        }
    }
}

// MARK: - 原生图解

struct ArenaReportDiagramView: View {
    let digest: ArenaCandidateDigest
    let knownSources: Set<String>
    let onOpenSource: (String) -> Void

    @State private var selectedID: String?

    private var graph: ArenaReportGraph { ArenaReportGraphBuilder.build(digest) }

    var body: some View {
        let graph = self.graph
        VStack(alignment: .leading, spacing: 9) {
            Text("候选图解")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(graph.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                horizontalGraph(graph)
                verticalGraph(graph)
            }

            if let selectedID, let node = graph.nodes.first(where: { $0.id == selectedID }) {
                nodeDetail(node)
            } else {
                Text("点击节点查看原文与出处。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.028)))
    }

    private func horizontalGraph(_ graph: ArenaReportGraph) -> some View {
        HStack(alignment: .top, spacing: 12) {
            column(
                "成立条件 → 直接建议",
                nodes: graph.nodes.filter { $0.kind == .condition }
            )
            column(
                "直接建议",
                nodes: graph.nodes.filter { $0.kind == .advice }
            )
            column(
                "未决分歧 → 待核对",
                nodes: graph.nodes.filter { $0.kind == .dispute || $0.kind == .verify }
            )
        }
        .overlayPreferenceValue(ArenaGraphFrameKey.self) { anchors in
            edges(graph, anchors: anchors)
        }
    }

    private func verticalGraph(_ graph: ArenaReportGraph) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            column(
                "成立条件 → 直接建议",
                nodes: graph.nodes.filter { $0.kind == .condition || $0.kind == .advice }
            )
            column(
                "未决分歧 → 待核对",
                nodes: graph.nodes.filter { $0.kind == .dispute || $0.kind == .verify }
            )
        }
        .overlayPreferenceValue(ArenaGraphFrameKey.self) { anchors in
            edges(graph, anchors: anchors)
        }
    }

    private func column(_ title: String, nodes: [ArenaReportGraphNode]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if nodes.isEmpty {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(nodes) { node in
                    nodeButton(node)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nodeButton(_ node: ArenaReportGraphNode) -> some View {
        let selected = selectedID == node.id
        return Button {
            selectedID = selected ? nil : node.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(node.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if !node.citations.isEmpty {
                        Text(node.citations.joined(separator: " "))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(node.text)
                    .font(.system(size: 12.5))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(node.kind == .advice
                          ? Color.accentColor.opacity(selected ? 0.14 : 0.055)
                          : Color.primary.opacity(selected ? 0.10 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .anchorPreference(key: ArenaGraphFrameKey.self, value: .bounds) { [node.id: $0] }
        .accessibilityLabel("\(node.title)：\(node.text)")
        .accessibilityHint("显示原文与出处")
    }

    private func nodeDetail(_ node: ArenaReportGraphNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(node.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !node.citations.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(node.citations, id: \.self) { identifier in
                            Button("[\(identifier)]") {
                                onOpenSource(identifier)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
            }
            Text(verbatim: node.text)
                .font(.system(size: 13.5))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.72)))
    }

    private func edges(
        _ graph: ArenaReportGraph,
        anchors: [String: Anchor<CGRect>]
    ) -> some View {
        GeometryReader { proxy in
            ForEach(graph.edges) { edge in
                if let fromAnchor = anchors[edge.from], let toAnchor = anchors[edge.to] {
                    let from = proxy[fromAnchor]
                    let to = proxy[toAnchor]
                    let points = connector(from: from, to: to)
                    Path { path in
                        path.move(to: points.start)
                        path.addLine(to: points.end)
                    }
                    .stroke(
                        Color.accentColor.opacity(0.34),
                        style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])
                    )
                    arrowHead(from: points.start, to: points.end)
                        .stroke(Color.accentColor.opacity(0.46), lineWidth: 1.2)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func arrowHead(from start: CGPoint, to end: CGPoint) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 6
        let left = CGPoint(
            x: end.x - length * cos(angle - 0.55),
            y: end.y - length * sin(angle - 0.55)
        )
        let right = CGPoint(
            x: end.x - length * cos(angle + 0.55),
            y: end.y - length * sin(angle + 0.55)
        )
        var path = Path()
        path.move(to: end)
        path.addLine(to: left)
        path.move(to: end)
        path.addLine(to: right)
        return path
    }

    private func connector(from: CGRect, to: CGRect) -> (start: CGPoint, end: CGPoint) {
        let fromCenter = CGPoint(x: from.midX, y: from.midY)
        let toCenter = CGPoint(x: to.midX, y: to.midY)
        let dx = toCenter.x - fromCenter.x
        let dy = toCenter.y - fromCenter.y
        if abs(dx) >= abs(dy) {
            return (
                CGPoint(x: dx >= 0 ? from.maxX : from.minX, y: from.midY),
                CGPoint(x: dx >= 0 ? to.minX : to.maxX, y: to.midY)
            )
        }
        return (
            CGPoint(x: from.midX, y: dy >= 0 ? from.maxY : from.minY),
            CGPoint(x: to.midX, y: dy >= 0 ? to.minY : to.maxY)
        )
    }
}

private struct ArenaGraphFrameKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
