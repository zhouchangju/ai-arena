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
                    VStack(alignment: .leading, spacing: 19) {
                        Text("讨论报告")
                            .font(.system(size: 24, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        if let question { questionSection(question) }
                        if !currentSources.isEmpty {
                            decisionLine
                            if let proposal, let answer = proposal.answer {
                                candidateExcerpt(answer, author: proposal)
                            } else {
                                Text("本场尚无可核对的候选结论。可在下方查看已保存的材料。")
                                    .foregroundStyle(.secondary)
                            }
                            if !participants.isEmpty { positions }
                            if let answer = proposal?.answer {
                                DisclosureGroup("候选全文", isExpanded: $showCandidate) {
                                    if showCandidate { markdown(answer).padding(.top, 12) }
                                }
                            }
                            DisclosureGroup(isExpanded: $showSources) {
                                if showSources { sourceList }
                            } label: {
                                Label("发言与出处（\(currentSources.count)）", systemImage: "books.vertical")
                            }
                        }
                        if let original = ArenaSessionDigest.report(session) {
                            DisclosureGroup(isExpanded: $showArchive) {
                                if showArchive { markdown(original).padding(.top, 12) }
                            } label: {
                                Label("完整报告", systemImage: "doc.richtext")
                            }
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
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

    private func candidateExcerpt(_ answer: String, author: ArenaTaskRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("结论摘录")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { selectedSource = author } label: {
                    Text("\(ArenaSeatCatalog.name(author.provider)) 起草 · \(author.sourceId)")
                }
                .buttonStyle(.link)
            }
            markdown(ArenaCandidateLead.excerpt(answer)).lineLimit(9)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.045)))
    }

    @ViewBuilder private var positions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("各席表态").font(.headline).accessibilityAddTraits(.isHeader)
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
                    DisclosureGroup("\(ArenaSeatCatalog.name(row.provider)) · \(Self.stance(vote["stance"]))原文") {
                        markdown(answer).padding(.top, 8)
                    }
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
        VStack(alignment: .leading, spacing: 5) {
            Button {
                showQuestion.toggle()
            } label: {
                Label(showQuestion ? "收起原始问题" : "原始问题", systemImage: showQuestion ? "chevron.down" : "chevron.right")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text(verbatim: question)
                .font(.system(size: 16))
                .lineSpacing(4)
                .lineLimit(showQuestion ? nil : 1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
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
enum ArenaCandidateLead {
    static func excerpt(_ original: String) -> String {
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
            let t = body[i].trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.range(of: #"^(?:#{1,6}\s|[一二三四五六七八九十]+[、．])"#,options:.regularExpression) != nil
        } ?? body.count
        let lead = body.prefix(cut).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return lead.isEmpty ? raw : lead
    }
}
