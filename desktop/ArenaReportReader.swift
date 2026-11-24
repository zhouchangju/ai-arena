import SwiftUI

/// The ballot comes from the same JS state machine that created the Markdown.
/// The reader only arranges saved text and links each quote back to a task.
struct ArenaReportReader: View {
    let session: [String: Any]?
    let ballot: [String: Any]?
    @ObservedObject var model: ArenaModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showCandidate = false
    @State private var showQuestion = false
    @State private var showSources = false
    @State private var showArchive = false
    @State private var selectedSource: ArenaTaskRow?
    @State private var showComparison = false
    @State private var compareLeft = 0
    @State private var compareRight = 0
    @State private var comparisonChanges: [ArenaParagraphChange] = []
    @State private var comparisonTruncated = false
    @State private var olderSnapshot: ArenaCandidateSnapshot?
    @State private var newerSnapshot: ArenaCandidateSnapshot?
    @State private var priorConcerns: [ArenaCandidateVote] = []
    @State private var changePulse = false
    @State private var pulseSequence = 0

    private var rows: [ArenaTaskRow] { ArenaSessionDigest.rows(session) }
    private var participants: [String] { ArenaSessionDigest.participants(session) }
    private var candidateHistory: ArenaCandidateHistory { ArenaCandidateHistory(session: session) }
    private var proposal: ArenaTaskRow? {
        guard let id = ballot?["candidateID"] as? String else { return nil }
        return rows.first { $0.id == id }
    }
    private var votes: [[String: Any]] { ballot?["votes"] as? [[String: Any]] ?? [] }
    private var reason: String { ArenaSessionDigest.stopReason(session) ?? "" }
    private var version: Int { ArenaValue.int(ballot?["version"]) ?? 0 }
    /// Only candidates that follow the fixed Markdown blocks get the structured
    /// first screen, diagram and artifacts. Older or malformed candidates keep
    /// the original lead-paragraph path below.
    private var digest: ArenaCandidateDigest? {
        guard let answer = proposal?.answer else { return nil }
        return ArenaCandidateDigest.parse(answer)
    }
    private var artifactInput: ArenaReportArtifactInput? {
        guard let proposal, let digest else { return nil }
        let sourceRows = currentSources.compactMap { row -> ArenaReportSourceRow? in
            guard let answer = row.answer, !row.sourceId.isEmpty else { return nil }
            return ArenaReportSourceRow(
                id: row.sourceId,
                seatLabel: ArenaSeatCatalog.name(row.provider),
                stageLabel: ArenaStageNames.taskLabel(
                    row.stage,
                    round: row.round,
                    session: session
                ),
                answer: answer
            )
        }

        var labels: [String: String] = [:]
        for provider in participants + rows.map(\.provider) where !provider.isEmpty {
            labels[provider] = ArenaSeatCatalog.name(provider)
        }

        var positions: [ArenaReportPositionRow] = []
        var seen = Set<String>()
        for raw in votes {
            guard let provider = ArenaValue.string(raw["provider"]),
                  !provider.isEmpty,
                  !seen.contains(provider),
                  let id = ArenaValue.string(raw["id"]),
                  let row = rows.first(where: { $0.id == id }) else { continue }
            seen.insert(provider)
            let stance = ArenaValue.string(raw["stance"])
            positions.append(
                ArenaReportPositionRow(
                    provider: provider,
                    seatLabel: ArenaSeatCatalog.name(provider),
                    stance: stance ?? "",
                    stanceLabel: Self.stance(stance),
                    sourceID: row.sourceId,
                    answer: row.answer ?? ""
                )
            )
        }

        return ArenaReportArtifactInput(
            question: question ?? "",
            outcome: outcome,
            isVerifiedConsensus: verifiedConsensus,
            version: version,
            candidateAuthor: ArenaSeatCatalog.name(proposal.provider),
            candidateSourceID: proposal.sourceId,
            digest: digest,
            participants: participants,
            seatLabels: labels,
            positions: positions,
            sources: sourceRows
        )
    }
    private var verifiedConsensus: Bool {
        reason == "consensus" && proposal != nil && !participants.isEmpty &&
        participants.allSatisfy { provider in
            votes.contains {
                ArenaValue.string($0["provider"]) == provider
                    && ArenaValue.string($0["stance"]) == "agree"
            }
        }
    }
    private var outcome: String {
        if verifiedConsensus { return "全体一致" }
        switch reason {
        case "conditional-agreement":
            return votes.contains { ArenaValue.string($0["stance"]) == "conditional" } ? "有条件同意" : "表态记录不完整"
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
        // The report stays mounted while a source is open. Returning keeps its
        // scroll position, disclosures and version comparison exactly as they
        // were. The overlay alone receives accessibility and hit testing.
        ZStack {
            GeometryReader { viewport in
                reportPage(compact: viewport.size.width < 620 || viewport.size.height < 430)
                    .accessibilityHidden(selectedSource != nil)
                    .allowsHitTesting(selectedSource == nil)
            }
            if let row = selectedSource {
                sourceReader(row)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .zIndex(1)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func reportPage(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 10 : 19) {
                    Text("讨论报告")
                        .font(.system(size: compact ? 20 : 24, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    if let question { questionSection(question) }
                    decisionLine(compact: compact) {
                        openComparison()
                        DispatchQueue.main.async {
                            if reduceMotion {
                                proxy.scrollTo("candidate-comparison", anchor: .top)
                            } else {
                                withAnimation(.easeOut(duration: 0.22)) {
                                    proxy.scrollTo("candidate-comparison", anchor: .top)
                                }
                            }
                        }
                    }
                    if let proposal, let answer = proposal.answer {
                        if let digest, let artifactInput {
                            ArenaReportDigestView(
                                digest: digest,
                                input: artifactInput,
                                compact: compact,
                                knownSources: Set(currentSources.map(\.sourceId)),
                                onOpenSource: { identifier in
                                    if let row = currentSources.first(where: { $0.sourceId == identifier }) {
                                        selectedSource = row
                                    }
                                },
                                onOpenAuthor: { selectedSource = proposal }
                            )
                        } else {
                            candidateExcerpt(answer, author: proposal, compact: compact)
                        }
                    } else {
                        emptyCandidateState
                    }
                    if !currentSources.isEmpty {
                        if !participants.isEmpty { positions(compact: compact) }
                        if candidateHistory.hasMultipleVersions {
                            comparisonSection(compact: compact)
                                .id("candidate-comparison")
                        }
                        if let answer = proposal?.answer {
                            ReportDisclosure(isExpanded: $showCandidate) {
                                Text("候选全文")
                            } content: {
                                markdown(answer).padding(.top, 12)
                            }
                        }
                        ReportDisclosure(isExpanded: $showSources) {
                            Label("发言与出处（\(currentSources.count)）", systemImage: "books.vertical")
                        } content: {
                            sourceList
                        }
                    }
                    if session?["stage"] as? String == "done",
                       let id = ArenaSessionDigest.id(session), ArenaSessionDigest.evaluationCandidates(session).count >= 2 {
                        ArenaEvaluationSection(sessionID: id, chatGPTParticipated: participants.contains("chatgpt"), model: model) { source in
                            selectedSource = currentSources.first { $0.sourceId == source }
                        }
                    }
                    if let original = ArenaSessionDigest.report(session) {
                        ReportDisclosure(isExpanded: $showArchive) {
                            Label("完整报告", systemImage: "doc.richtext")
                        } content: {
                            markdown(original).padding(.top, 12)
                        }
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, compact ? 16 : 24)
                .padding(.vertical, compact ? 12 : 22)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func decisionLine(compact: Bool, openComparison: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Label(outcome, systemImage: verifiedConsensus ? "checkmark.circle.fill" : "circle.lefthalf.filled")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(verifiedConsensus ? Color.green : Color.primary)
            if let reviewRound = ArenaStageNames.reviewRound(session) {
                Divider().frame(height: 15)
                Text(reviewRound)
            }
            if version > 0 {
                if candidateHistory.hasMultipleVersions {
                    Button(action: openComparison) {
                        HStack(spacing: 4) {
                            Text("候选 v\(version)")
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("候选 v\(version)，共 \(candidateHistory.versions.count) 个保存版本")
                    .accessibilityHint("打开版本对比")
                } else {
                    Text("候选 v\(version)")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    private var emptyCandidateState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("最终报告没有候选结论")
                    .font(.subheadline.weight(.semibold))
                Text("本场没有形成可核对的候选。若已保存材料，下方仍可查看；缺席、跳过、未完成和未表态都不能当作一致。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
    }

    private func candidateExcerpt(_ answer: String, author: ArenaTaskRow, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
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
            markdown(ArenaCandidateLead.excerpt(answer)).lineLimit(compact ? 4 : 9)
        }
        .padding(.vertical, compact ? 8 : 12)
        .padding(.horizontal, compact ? 12 : 16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.045)))
    }

    private func positions(compact: Bool) -> some View {
        let concerns = votes.filter { ArenaCandidateStance.isConcern(ArenaValue.string($0["stance"])) }
        return VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            Text("各席表态").font(.headline).accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                ForEach(participants, id: \.self) { provider in
                    let vote = votes.first { ArenaValue.string($0["provider"]) == provider }
                    let source = vote.flatMap { vote in
                        rows.first { $0.id == ArenaValue.string(vote["id"]) }
                    }
                    Button {
                        if let source { selectedSource = source }
                    } label: {
                        let label = Label {
                            Text(ArenaSeatCatalog.name(provider)).fontWeight(.medium)
                        } icon: {
                            Circle()
                                .fill(Self.color(ArenaValue.string(vote?["stance"])))
                                .frame(width: 7, height: 7)
                        }
                        let stance = Text(Self.stance(ArenaValue.string(vote?["stance"])))
                            .foregroundStyle(.secondary)
                        let layout = compact
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
                            : AnyLayout(HStackLayout(spacing: 7))
                        layout {
                            label
                            if !compact { Spacer(minLength: 3) }
                            stance
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, compact ? 6 : 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(source == nil)
                }
            }
            ForEach(Array(concerns.enumerated()), id: \.offset) { _, vote in
                let id = ArenaValue.string(vote["id"]) ?? ""
                if let row = rows.first(where: { $0.id == id }), let answer = row.answer {
                    DisclosureGroup("\(ArenaSeatCatalog.name(row.provider)) · \(Self.stance(ArenaValue.string(vote["stance"])))原文") {
                        markdown(answer).padding(.top, 8)
                    }
                }
            }
        }
    }

    // MARK: - 版本对比

    private var comparisonPairLabel: String {
        let pair = candidateHistory.defaultComparison()
        let left = candidateHistory.versions.contains(compareLeft) ? compareLeft : (pair?.older ?? 0)
        let right = candidateHistory.versions.contains(compareRight) ? compareRight : (pair?.newer ?? 0)
        guard left > 0, right > 0 else { return "" }
        return "v\(left) → v\(right)"
    }

    private func comparisonSection(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showComparison.toggle()
                if showComparison {
                    let pair = normalizeComparisonSelection()
                    rebuildComparison(left: pair?.0, right: pair?.1)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showComparison ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Label("版本对比", systemImage: "rectangle.split.2x1")
                    if !showComparison, !comparisonPairLabel.isEmpty {
                        Text(comparisonPairLabel).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showComparison ? "已展开" : "已收起")
            if showComparison {
                VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                    versionSelectors(compact: compact)
                    if compareLeft != compareRight,
                       let older = olderSnapshot,
                       let newer = newerSnapshot,
                       let olderCandidate = older.candidate,
                       let newerCandidate = newer.candidate {
                        comparisonChangesView(
                            older: olderCandidate,
                            newer: newerCandidate,
                            concerns: priorConcerns
                        )
                        comparisonBallotsView(older: older, newer: newer, compact: compact)
                    } else if olderSnapshot != nil, newerSnapshot != nil {
                        Text("所选版本没有可核对的保存候选原文，因此不显示表态记录。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("选择两个不同的保存版本进行对比。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 10)
                .onAppear {
                    let pair = normalizeComparisonSelection()
                    rebuildComparison(left: pair?.0, right: pair?.1)
                }
                .onChange(of: compareLeft) { _ in rebuildComparison() }
                .onChange(of: compareRight) { _ in rebuildComparison() }
            }
        }
    }

    private func versionSelectors(compact: Bool) -> some View {
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            versionMenu(title: "旧版", selected: compareLeft, asOlder: true)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            versionMenu(title: "新版", selected: compareRight, asOlder: false)
            if !compact { Spacer(minLength: 0) }
        }
    }

    private func versionMenu(title: String, selected: Int, asOlder: Bool) -> some View {
        Menu {
            ForEach(candidateHistory.versions, id: \.self) { version in
                Button {
                    selectVersion(version, asOlder: asOlder)
                } label: {
                    if version == selected {
                        Label(versionLabel(version), systemImage: "checkmark")
                    } else {
                        Text(versionLabel(version))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title).foregroundStyle(.secondary)
                Text(versionLabel(selected)).fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("\(title)，\(versionLabel(selected))")
    }

    private func versionLabel(_ version: Int) -> String {
        candidateHistory.versions.contains(version) ? "v\(version)" : "未选择"
    }

    @discardableResult
    private func normalizeComparisonSelection() -> (Int, Int)? {
        guard let pair = candidateHistory.defaultComparison() else { return nil }
        let known = candidateHistory.versions
        if !known.contains(compareLeft) || compareLeft == compareRight {
            compareLeft = pair.older
        }
        if !known.contains(compareRight) || compareRight == compareLeft {
            compareRight = pair.newer
        }
        if compareLeft > compareRight {
            swap(&compareLeft, &compareRight)
        }
        return (compareLeft, compareRight)
    }

    private func selectVersion(_ value: Int, asOlder: Bool) {
        var left = compareLeft
        var right = compareRight
        if asOlder {
            if value == right { right = left }
            left = value
        } else {
            if value == left { left = right }
            right = value
        }
        let known = candidateHistory.versions
        if !known.contains(left) { left = known.first ?? left }
        if !known.contains(right) { right = known.last ?? right }
        if left == right, let other = known.first(where: { $0 != right }) {
            left = other
        }
        if left > right { swap(&left, &right) }
        compareLeft = left
        compareRight = right
        rebuildComparison(left: left, right: right)
        pulseChangeHighlight()
    }

    private func openComparison() {
        showComparison = true
        let pair = normalizeComparisonSelection()
        rebuildComparison(left: pair?.0, right: pair?.1)
    }

    private func rebuildComparison(left: Int? = nil, right: Int? = nil) {
        let leftValue = left ?? compareLeft
        let rightValue = right ?? compareRight
        guard candidateHistory.versions.contains(leftValue),
              candidateHistory.versions.contains(rightValue),
              leftValue != rightValue else {
            comparisonChanges = []
            comparisonTruncated = false
            olderSnapshot = nil
            newerSnapshot = nil
            priorConcerns = []
            return
        }

        // One bridge call per version: canonical candidateID and the accepted
        // vote ids. Saved rows only supply text, seat labels and gap reasons.
        var snapshots: [Int: ArenaCandidateSnapshot] = [:]
        for version in candidateHistory.versions where version <= rightValue {
            snapshots[version] = candidateHistory.snapshot(
                version: version,
                ballot: model.reportBallot(forVersion: version)
            )
        }
        olderSnapshot = snapshots[leftValue]
        newerSnapshot = snapshots[rightValue]
        priorConcerns = candidateHistory.versions
            .filter { $0 < rightValue }
            .flatMap { snapshots[$0]?.concerns ?? [] }

        guard let olderText = snapshots[leftValue]?.candidate?.text,
              let newerText = snapshots[rightValue]?.candidate?.text else {
            comparisonChanges = []
            comparisonTruncated = false
            return
        }
        let result = ArenaParagraphDiff.compare(old: olderText, new: newerText)
        comparisonChanges = result.rows
        comparisonTruncated = result.truncated
    }

    /// Only a deliberate selector change pulses. Reduce Motion shows the same
    /// restrained fill immediately, with no animated transition.
    private func pulseChangeHighlight() {
        pulseSequence += 1
        let sequence = pulseSequence
        if reduceMotion {
            changePulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard pulseSequence == sequence else { return }
                changePulse = false
            }
        } else {
            withAnimation(.easeOut(duration: 0.16)) { changePulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard pulseSequence == sequence else { return }
                withAnimation(.easeOut(duration: 0.5)) { changePulse = false }
            }
        }
    }

    private func comparisonChangesView(
        older: ArenaCandidateVersion,
        newer: ArenaCandidateVersion,
        concerns: [ArenaCandidateVote]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("段落变化").font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Text("\(older.title) → \(newer.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if comparisonChanges.isEmpty {
                Text("两版正文按段落核对，没有文字变化。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(comparisonChanges) { change in
                    comparisonChangeRow(change, concerns: concerns)
                }
            }
            if comparisonTruncated {
                Text("原文较长，只核对了靠前的段落；其余内容没有参与对比。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            priorConcernsView(concerns)
        }
    }

    @ViewBuilder
    private func comparisonChangeRow(
        _ change: ArenaParagraphChange,
        concerns: [ArenaCandidateVote]
    ) -> some View {
        switch change.kind {
        case .gap:
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("省略 \(change.gapCount) 段未变内容")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        case .unchanged:
            markdown(change.newText ?? "")
                .lineLimit(6)
                .opacity(0.72)
        case .changed:
            VStack(alignment: .leading, spacing: 6) {
                changeTag("修改", color: .accentColor)
                markdown(change.newText ?? "")
                if let old = change.oldText {
                    DisclosureGroup("旧版这一段") {
                        Text(verbatim: old)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                    .font(.caption)
                }
                comparisonCitations(change.newCitations, concerns: concerns)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(changePulse ? 0.10 : 0.035))
            )
        case .added:
            VStack(alignment: .leading, spacing: 6) {
                changeTag("新增", color: .green)
                markdown(change.newText ?? "")
                comparisonCitations(change.newCitations, concerns: concerns)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(changePulse ? 0.10 : 0.035))
            )
        case .removed:
            VStack(alignment: .leading, spacing: 4) {
                changeTag("删除", color: .secondary)
                Text(verbatim: change.oldText ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        }
    }

    private func changeTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.10)))
            .accessibilityLabel("变化类型：\(text)")
    }

    @ViewBuilder
    private func comparisonCitations(
        _ identifiers: [String],
        concerns: [ArenaCandidateVote]
    ) -> some View {
        if !identifiers.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("改段明确引用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(identifiers, id: \.self) { identifier in
                    if let row = candidateSource(identifier) {
                        Button {
                            selectedSource = row
                        } label: {
                            HStack(spacing: 4) {
                                Text(citationTitle(identifier, row: row, concerns: concerns))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.link)
                        .accessibilityLabel("打开 \(identifier) 的保存原文")
                    } else {
                        Text("\(identifier) · 未找到保存原文")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func citationTitle(
        _ identifier: String,
        row: ArenaTaskRow,
        concerns: [ArenaCandidateVote]
    ) -> String {
        var parts = ["\(identifier) · \(ArenaStageNames.label(row.stage))"]
        if let concern = concerns.first(where: { $0.sourceID == identifier }) {
            parts.append("v\(concern.version) \(ArenaCandidateStance.label(concern.stance))")
        }
        return parts.joined(separator: " · ")
    }

    private func priorConcernsView(_ concerns: [ArenaCandidateVote]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("修改前的反对或附加条件")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("只作核对依据，不据此推断修改原因。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if concerns.isEmpty {
                Text("修改前没有保存的反对或有条件同意。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(concerns) { concern in
                    let source = candidateSource(concern.sourceID)
                    Button {
                        if let source { selectedSource = source }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Self.color(concern.stance))
                                .frame(width: 6, height: 6)
                            Text("v\(concern.version)")
                            Text(ArenaSeatCatalog.name(concern.provider))
                            Text(ArenaCandidateStance.label(concern.stance))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(concern.sourceID)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            if source != nil {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(source == nil)
                }
            }
        }
        .padding(.top, 4)
    }

    private func comparisonBallotsView(
        older: ArenaCandidateSnapshot,
        newer: ArenaCandidateSnapshot,
        compact: Bool
    ) -> some View {
        let layout = compact
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return VStack(alignment: .leading, spacing: 8) {
            Text("各版同版表态").font(.subheadline.weight(.semibold))
            Text("只计入版本号与文本摘要都相符的保存表态。缺席、跳过和摘要不符都不算同意。")
                .font(.caption)
                .foregroundStyle(.secondary)
            layout {
                versionBallotPanel(older)
                versionBallotPanel(newer)
            }
        }
    }

    private func versionBallotPanel(_ snapshot: ArenaCandidateSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("v\(snapshot.version) 表态").fontWeight(.semibold)
                Spacer(minLength: 4)
                Text(snapshot.coverageLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if snapshot.candidate == nil {
                Text("没有可核对的候选原文，未显示表态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if snapshot.coverage == .noneRecorded {
                Text("该版没有保存的同版表态记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.votes) { vote in
                    versionVoteRow(vote)
                }
                ForEach(snapshot.gaps) { gap in
                    versionGapRow(gap)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
    }

    private func versionVoteRow(_ vote: ArenaCandidateVote) -> some View {
        let source = candidateSource(vote.sourceID)
        return Button {
            if let source { selectedSource = source }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(Self.color(vote.stance))
                    .frame(width: 6, height: 6)
                Text(ArenaSeatCatalog.name(vote.provider)).fontWeight(.medium)
                Text(ArenaCandidateStance.label(vote.stance))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if source != nil {
                    Text(vote.sourceID)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(source == nil)
        .help("打开 \(vote.sourceID) 的保存原文")
    }

    private func versionGapRow(_ gap: ArenaCandidateVoteGap) -> some View {
        let source = gap.sourceID.flatMap { candidateSource($0) }
        return Button {
            if let source { selectedSource = source }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
                    .frame(width: 6, height: 6)
                Text(ArenaSeatCatalog.name(gap.provider))
                Text(gap.reason.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let sourceID = gap.sourceID, source != nil {
                    Text(sourceID)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(source == nil)
    }

    private func candidateSource(_ identifier: String) -> ArenaTaskRow? {
        guard !identifier.isEmpty else { return nil }
        return rows.first { $0.sourceId == identifier && $0.answer?.isEmpty == false }
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

            if showQuestion { ArenaSavedMaterials(model: model) }
            Text(verbatim: question)
                .font(.system(size: 16))
                .lineSpacing(4)
                .lineLimit(showQuestion ? nil : 1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceReader(_ row: ArenaTaskRow) -> some View {
        ArenaSourceReader(row: row, session: session, returnLabel: "返回报告") {
            selectedSource = nil
        }
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

    /// One collapsed block of the report. The chevron, the caller's label and the
    /// empty space to the right are a single plain full-width button, so the whole
    /// row toggles while the content stays inert. Accessibility reads the current
    /// state; content only exists while expanded, exactly like the original
    /// 完整报告 row.
    private struct ReportDisclosure<RowLabel: View, Content: View>: View {
        @Binding var isExpanded: Bool
        private let label: () -> RowLabel
        private let content: () -> Content

        init(
            isExpanded: Binding<Bool>,
            @ViewBuilder label: @escaping () -> RowLabel,
            @ViewBuilder content: @escaping () -> Content
        ) {
            self._isExpanded = isExpanded
            self.label = label
            self.content = content
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        label()
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "已展开" : "已收起")
                if isExpanded { content() }
            }
        }
    }
}

/// The existing source-navigation surface, reused by the report and by the
/// history tab's review-material rows. `returnLabel` names the real way back.
struct ArenaSourceReader: View {
    let row: ArenaTaskRow
    let session: [String: Any]?
    let returnLabel: String
    let onReturn: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onReturn) {
                    Label(returnLabel, systemImage: "chevron.left")
                }
                .buttonStyle(.link)
                Text("\(ArenaSeatCatalog.name(row.provider)) · \(ArenaStageNames.label(row.stage))")
                    .font(.title.weight(.semibold))
                Text([ArenaStageNames.taskLabel(row.stage, round: row.round, session: session), row.sourceId]
                    .joined(separator: " · "))
                    .foregroundStyle(.secondary)
                Divider()
                ArenaMarkdownView(text: row.answer ?? "")
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .id(row.id)
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
