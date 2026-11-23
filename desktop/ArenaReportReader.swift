import SwiftUI

/// The ballot comes from the same JS state machine that created the Markdown.
/// The reader only arranges saved text and links each quote back to a task.
struct ArenaReportReader: View {
    let session: [String: Any]?
    let ballot: [String: Any]?
    @State private var showCandidate = false
    @State private var showQuestion = false
    @State private var showSources = false
    @State private var showArchive = false
    @State private var selectedSource: ArenaTaskRow?

    private var rows: [ArenaTaskRow] { ArenaSessionDigest.rows(session) }
    private var participants: [String] { ArenaSessionDigest.participants(session) }
    private var proposal: ArenaTaskRow? {
        guard let id = ballot?["candidateID"] as? String else { return nil }
        return rows.first { $0.id == id }
    }
    private var votes: [[String: String]] { ballot?["votes"] as? [[String: String]] ?? [] }
    private var reason: String { ArenaSessionDigest.stopReason(session) ?? "" }
    private var version: Int { ArenaValue.int(ballot?["version"]) ?? 0 }
    private var verifiedConsensus: Bool {
        reason == "consensus" && proposal != nil && !participants.isEmpty &&
        participants.allSatisfy { provider in votes.contains { $0["provider"] == provider && $0["stance"] == "agree" } }
    }
    private var outcome: String {
        if verifiedConsensus { return "全体一致" }
        switch reason {
        case "conditional-agreement": return votes.contains { $0["stance"] == "conditional" } ? "有条件同意" : "表态记录不完整"
        case "unresolved-opposition": return "存在分歧"
        case "user-finished": return "提前结束"
        case "no-answers": return "尚无回答"
        case "no-cross-review": return "互评未完成"
        case "draft": return "候选草稿"
        case "proposal-skipped", "no-critique": return "尚无最终候选"
        case "partial-participation": return "部分席位参与"
        case "partial-votes", "consensus": return "表态记录不完整"
        default: return "讨论已结束"
        }
    }
    private var currentSources: [ArenaTaskRow] {
        rows.filter { $0.status == "answered" && $0.answer?.isEmpty == false }
    }
    private var question: String? {
        guard let raw = session?["question"] as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    var body: some View {
        Group {
            if let row = selectedSource {
                sourceReader(row)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 23) {
                        if currentSources.isEmpty, let original = ArenaSessionDigest.report(session) {
                            ArenaMarkdownView(text: original)
                            if let question { questionSection(question) }
                        } else {
                            Text("讨论报告")
                                .font(.system(size: 24, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                            decisionLine
                            if let proposal, let answer = proposal.answer {
                                candidate(answer, author: proposal)
                            } else {
                                Text("本场尚无可核对的候选结论。可在下方查看已保存的材料。")
                                    .foregroundStyle(.secondary)
                            }
                            if !participants.isEmpty { positions }
                            if let question { questionSection(question) }
                            Divider()
                            DisclosureGroup(isExpanded: $showSources) {
                                if showSources { sourceList }
                            } label: {
                                Label("发言与出处（\(currentSources.count)）", systemImage: "books.vertical")
                            }
                            if let original = ArenaSessionDigest.report(session) {
                                DisclosureGroup(isExpanded: $showArchive) {
                                    if showArchive { markdown(original).padding(.top, 10) }
                                } label: {
                                    Label("完整报告", systemImage: "doc.richtext")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 26)
                    .frame(maxWidth: 1080, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var decisionLine: some View {
        HStack(spacing: 12) {
            Label(outcome, systemImage: verifiedConsensus ? "checkmark.circle.fill" : "circle.lefthalf.filled")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(verifiedConsensus ? Color.green : Color.primary)
            if let reviewRound = ArenaStageNames.reviewRound(session) {
                Divider().frame(height: 15)
                Text(reviewRound)
            }
            if version > 0 { Text("候选 v\(version)") }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    private func candidate(_ answer: String, author: ArenaTaskRow) -> some View {
        let lead = ArenaCandidateLead(answer)
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("建议回答").font(.title3.weight(.semibold))
                Spacer()
                Button { selectedSource = author } label: {
                    Text("\(ArenaSeatCatalog.name(author.provider)) 起草 · \(author.sourceId)")
                }
                .buttonStyle(.link)
            }
            markdown(showCandidate ? answer : lead.text)
            if lead.hasMore {
                Button { showCandidate.toggle() } label: {
                    Label(showCandidate ? "收起候选全文" : "展开候选全文", systemImage: showCandidate ? "chevron.up" : "chevron.down")
                }.buttonStyle(.link)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.14)))
    }

    @ViewBuilder private var positions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("各席表态").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 400), spacing: 10)], alignment: .leading, spacing: 8) {
                ForEach(participants, id: \.self) { provider in
                    let vote = votes.first { $0["provider"] == provider }
                    let source = rows.first { $0.id == vote?["id"] }
                    Button {
                        if let source { selectedSource = source }
                    } label: {
                        HStack(spacing: 7) {
                            Circle().fill(Self.color(vote?["stance"])).frame(width: 7, height: 7)
                            Text(ArenaSeatCatalog.name(provider)).fontWeight(.medium)
                            Spacer(minLength: 3)
                            Text(Self.stance(vote?["stance"])).foregroundStyle(.secondary)
                        }.font(.system(size: 13)).padding(10)
                         .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
                         .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(source == nil)
                }
            }
            ForEach(votes.filter { $0["stance"] == "conditional" || $0["stance"] == "oppose" }, id: \.self) { vote in
                if let row = rows.first(where: { $0.id == vote["id"] }), let answer = row.answer {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(ArenaSeatCatalog.name(row.provider)) · \(Self.stance(vote["stance"]))原文")
                            .font(.subheadline.weight(.semibold))
                        markdown(answer)
                    }
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Self.color(vote["stance"])).frame(width: 3) }
                }
            }
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(currentSources) { row in
                Button { selectedSource = row } label: {
                    HStack {
                        Text(row.sourceId).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Text(ArenaSeatCatalog.name(row.provider))
                        Spacer()
                        Text("\(ArenaStageNames.taskLabel(row.stage, round: row.round, session: session))").foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .padding(.vertical, 7).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(.top, 8)
    }

    private func questionSection(_ question: String) -> some View {
        DisclosureGroup(isExpanded: $showQuestion) {
            if showQuestion {
                Text(verbatim: question)
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
        } label: {
            Label("原始问题", systemImage: "text.quote")
        }
    }

    private func sourceReader(_ row: ArenaTaskRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button { selectedSource = nil } label: { Label("返回报告", systemImage: "chevron.left") }
                .buttonStyle(.link)
                Text("\(ArenaSeatCatalog.name(row.provider)) · \(ArenaStageNames.label(row.stage))").font(.title.weight(.semibold))
                Text([ArenaStageNames.taskLabel(row.stage, round: row.round, session: session), row.sourceId].joined(separator: " · ")).foregroundStyle(.secondary)
                Divider()
                ArenaMarkdownView(text: row.answer ?? "")
            }
            .padding(28).frame(maxWidth: 1080, alignment: .leading).frame(maxWidth: .infinity)
        }.id(row.id)
    }

    private func markdown(_ text: String) -> some View {
        ArenaMarkdownView(text: text, onSource: { ref in
            if let row = currentSources.first(where: { $0.sourceId == ref }) { selectedSource = row }
        }, sources: Set(currentSources.map(\.sourceId)))
    }

    private static func stance(_ value: String?) -> String {
        switch value { case "agree": return "同意"; case "conditional": return "有条件同意"; case "oppose": return "反对"; default: return "未核实表态" }
    }
    private static func color(_ value: String?) -> Color {
        switch value { case "agree": return .green; case "conditional": return .orange; case "oppose": return .red; default: return .secondary }
    }
}
/// Extracts the actual opening answer for the compact reading view. Subsequent
/// sections still belong to the full candidate, with the original wording.
struct ArenaCandidateLead {
    var text: String
    var hasMore: Bool
    init(_ original: String) {
        let raw = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = raw.components(separatedBy: .newlines)
        func isPreface(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return true }
            return t.range(of: #"^(?:#{1,6}\s*)?(?:\*\*)?(?:(?:[一二三四五六七八九十]+[、.．]|[0-9]+[.、])\s*)?(?:候选(?:结论|方案|版本|回答)(?:\s*版本)?\s*(?:[vV]\s*\d+)?|建议回答|核心结论|推荐结论|最终结论|结论摘要)(?:\*\*)?[：:]?$"#, options: .regularExpression) != nil
        }
        let start = lines.firstIndex { !isPreface($0) } ?? 0
        let body = Array(lines.dropFirst(start))
        // A missing paragraph break is common in plain text recovered from a
        // web page. Treat distinct headings as paragraph boundaries too.
        let cut = body.indices.dropFirst().first { i in
            let t=body[i].trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.range(of: #"^(?:#{1,6}\s|[一二三四五六七八九十]+[、．])"#,options:.regularExpression) != nil
        } ?? body.count
        let lead = body.prefix(cut).joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
        let rest = body.dropFirst(cut).contains { !$0.trimmingCharacters(in:.whitespaces).isEmpty }
        if lead.isEmpty || !rest {text = raw; hasMore = false}
        else {text = lead; hasMore = true}
    }
}
