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
    @State private var finishedComparison: ArenaComparisonKey?
    @State private var snapshotCache: [Int: ArenaSnapshotCacheEntry] = [:]
    @State private var changePulse = false
    @State private var pulseSequence = 0
    /// Keyboard focus for the discrete controls that open a saved original.
    /// Returning from the source hands focus back to the control that asked.
    @FocusState private var entryFocus: String?
    /// The token of the control that opened the current source; `nil` when the
    /// jump came from something without its own focusable row (an inline
    /// citation or the evaluation section).
    @State private var focusReturnToken: String?
    /// Monotonic request for the AppKit-backed drafting button. It starts at 0
    /// and only increments when a source opened from it (or from the excerpt
    /// that falls back to it) returns, so ordinary refreshes never steal focus.
    @State private var candidateAuthorFocusRequest = 0
    private static let candidateAuthorIdentifier = "candidate-author"

    private var rows: [ArenaTaskRow] { ArenaSessionDigest.rows(session) }
    private var participants: [String] { ArenaSessionDigest.participants(session) }
    private var candidateHistory: ArenaCandidateHistory { ArenaCandidateHistory(session: session) }
    private var proposal: ArenaTaskRow? {
        guard let id = ballot?["candidateID"] as? String else { return nil }
        return rows.first { $0.id == id }
    }
    private var votes: [[String: Any]] { ballot?["votes"] as? [[String: Any]] ?? [] }
    private var version: Int { ArenaValue.int(ballot?["version"]) ?? 0 }
    private var verifiedConsensus: Bool {
        ArenaHistoryOutcome.verifiedConsensus(
            stopReason: ArenaSessionDigest.stopReason(session),
            ballot: ballot,
            participants: participants
        )
    }
    private var outcome: String {
        ArenaHistoryOutcome.conservativeLabel(
            stopReason: ArenaSessionDigest.stopReason(session),
            ballot: ballot,
            participants: participants
        )
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
                    // Disabled, not just hit-test transparent: the report stays
                    // mounted, but nothing in it can keep keyboard focus or
                    // take a click while a saved original is open.
                    .disabled(selectedSource != nil)
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

    /// Open one saved original and remember which row asked for it. The report
    /// stays mounted underneath, so its scroll position, disclosures and
    /// version comparison are untouched; only keyboard focus moves, to the
    /// source's own「返回」control.
    private func openSource(_ row: ArenaTaskRow, from token: String?) {
        focusReturnToken = token
        selectedSource = row
    }

    private func openSource(matching sourceID: String, from token: String?) {
        guard let row = currentSources.first(where: { $0.sourceId == sourceID }) else { return }
        openSource(row, from: token)
    }

    /// Return to the mounted report and put focus back on the row that opened
    /// the source, once that row is interactive again. A jump that had no
    /// discrete row leaves focus alone rather than guessing at a neighbour.
    private func closeSource() {
        let token = focusReturnToken
        focusReturnToken = nil
        selectedSource = nil
        guard let token else { return }
        if token == Self.candidateAuthorIdentifier {
            // SwiftUI focus on a macOS sheet/window here lands on the window,
            // so this entry asks its real AppKit button for first responder.
            candidateAuthorFocusRequest &+= 1
        } else {
            DispatchQueue.main.async { entryFocus = token }
        }
    }

    private func reportPage(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 10 : 19) {
                    Text("讨论报告")
                        .font(.system(size: compact ? 20 : 24, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    if let question { questionSection(question) }
                    if !currentSources.isEmpty {
                        decisionLine(compact: compact) {
                            openComparison()
                            DispatchQueue.main.async {
                                if let animation = ArenaMotion.change(reduceMotion) {
                                    withAnimation(animation) {
                                        proxy.scrollTo("candidate-comparison", anchor: .top)
                                    }
                                } else {
                                    proxy.scrollTo("candidate-comparison", anchor: .top)
                                }
                            }
                        }
                        if let proposal, let answer = proposal.answer {
                            candidateExcerpt(answer, author: proposal, compact: compact)
                        } else {
                            Text("本场尚无可核对的候选结论。可在下方查看已保存的材料。")
                                .foregroundStyle(.secondary)
                        }
                        if !participants.isEmpty { positions(compact: compact) }
                        if candidateHistory.hasMultipleVersions {
                            comparisonSection(compact: compact)
                                .id("candidate-comparison")
                        }
                        if let answer = proposal?.answer {
                            ReportDisclosure(
                                isExpanded: $showCandidate,
                                focusToken: "candidate-full",
                                focus: $entryFocus
                            ) {
                                Text("候选全文")
                            } content: {
                                markdown(answer, from: "candidate-full").padding(.top, 12)
                            }
                        }
                        ReportDisclosure(
                            isExpanded: $showSources,
                            focusToken: "sources",
                            focus: $entryFocus
                        ) {
                            Label("发言与出处（\(currentSources.count)）", systemImage: "books.vertical")
                        } content: {
                            sourceList
                        }
                    }
                    if session?["stage"] as? String == "done",
                       let id = ArenaSessionDigest.id(session), ArenaSessionDigest.evaluationCandidates(session).count >= 2 {
                        ArenaEvaluationSection(sessionID: id, chatGPTParticipated: participants.contains("chatgpt"), model: model) { source in
                            // The section owns its own controls; this jump has no
                            // row of ours to hand focus back to.
                            openSource(matching: source, from: nil)
                        }
                    }
                    if let original = ArenaSessionDigest.report(session) {
                        ReportDisclosure(
                            isExpanded: $showArchive,
                            focusToken: "archive",
                            focus: $entryFocus
                        ) {
                            Label("完整报告", systemImage: "doc.richtext")
                        } content: {
                            fullReport(original, from: "archive").padding(.top, 12)
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
                    .buttonStyle(ArenaPressStyle())
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

    private func candidateExcerpt(_ answer: String, author: ArenaTaskRow, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack {
                Text("结论摘录")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // The drafting link is the section's own source entry, including
                // for inline citations in the excerpt below. It is a real
                // AppKit-backed button so keyboard focus can return to it after
                // the saved original closes (SwiftUI FocusState alone leaves
                // first responder on the window here).
                ArenaSourceButton(
                    title: "\(ArenaSeatCatalog.name(author.provider)) 起草 · \(author.sourceId)",
                    identifier: Self.candidateAuthorIdentifier,
                    focusRequest: candidateAuthorFocusRequest
                ) {
                    openSource(author, from: Self.candidateAuthorIdentifier)
                }
            }
            markdown(ArenaCandidateLead.excerpt(answer), from: Self.candidateAuthorIdentifier).lineLimit(compact ? 4 : 9)
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
                        if let source { openSource(source, from: "position-\(provider)") }
                    } label: {
                        let label = Label {
                            Text(ArenaSeatCatalog.name(provider)).fontWeight(.medium)
                        } icon: {
                            Circle()
                                .fill(Self.color(ArenaValue.string(vote?["stance"])))
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
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
                    }
                    .buttonStyle(ArenaPressStyle())
                    .disabled(source == nil)
                    .accessibilityHint(source == nil ? "没有可打开的保存原文" : "打开保存原文")
                    .reportFocusEntry("position-\(provider)", in: $entryFocus)
                }
            }
            ForEach(Array(concerns.enumerated()), id: \.offset) { _, vote in
                let id = ArenaValue.string(vote["id"]) ?? ""
                if let row = rows.first(where: { $0.id == id }), let answer = row.answer {
                    ReportSelfDisclosure(
                        focusToken: "concern-body-\(row.id)",
                        focus: $entryFocus
                    ) {
                        Text("\(ArenaSeatCatalog.name(row.provider)) · \(Self.stance(ArenaValue.string(vote["stance"])))原文")
                            .font(.system(size: 13))
                    } content: {
                        markdown(answer, from: "concern-body-\(row.id)").padding(.top, 8)
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
                    ArenaDisclosureChevron(isExpanded: showComparison)
                    Label("版本对比", systemImage: "rectangle.split.2x1")
                    if !showComparison, !comparisonPairLabel.isEmpty {
                        Text(comparisonPairLabel).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ArenaPressStyle())
            .accessibilityValue(showComparison ? "已展开" : "已收起")
            .accessibilityHint(showComparison ? "收起版本对比" : "展开版本对比")
            .reportFocusEntry("comparison", in: $entryFocus)
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
        let history = candidateHistory
        guard history.versions.contains(leftValue),
              history.versions.contains(rightValue),
              leftValue != rightValue else {
            comparisonChanges = []
            comparisonTruncated = false
            olderSnapshot = nil
            newerSnapshot = nil
            priorConcerns = []
            finishedComparison = nil
            return
        }

        // Opening the section, the selector and each of its size changes all
        // report a change. Only the first rebuild for this exact pair and this
        // exact history does the work; the rest keep the result already shown.
        let key = ArenaComparisonKey(stamp: comparisonStamp(), left: leftValue, right: rightValue)
        if key == finishedComparison { return }

        // One bridge call per version: canonical candidateID and the accepted
        // vote ids. Saved rows only supply text, seat labels and gap reasons.
        // A snapshot is reused only while the stamp of the saved rows is the
        // same, so a changed session never keeps an older ballot or text.
        var snapshots: [Int: ArenaCandidateSnapshot] = [:]
        for version in history.versions where version <= rightValue {
            if let cached = snapshotCache[version], cached.stamp == key.stamp {
                snapshots[version] = cached.snapshot
                continue
            }
            let snapshot = history.snapshot(
                version: version,
                ballot: model.reportBallot(forVersion: version)
            )
            snapshotCache[version] = ArenaSnapshotCacheEntry(stamp: key.stamp, snapshot: snapshot)
            snapshots[version] = snapshot
        }
        olderSnapshot = snapshots[leftValue]
        newerSnapshot = snapshots[rightValue]
        priorConcerns = history.versions
            .filter { $0 < rightValue }
            .flatMap { snapshots[$0]?.concerns ?? [] }

        guard let olderText = snapshots[leftValue]?.candidate?.text,
              let newerText = snapshots[rightValue]?.candidate?.text else {
            comparisonChanges = []
            comparisonTruncated = false
            finishedComparison = key
            return
        }
        let result = ArenaParagraphDiff.compare(old: olderText, new: newerText)
        comparisonChanges = result.rows
        comparisonTruncated = result.truncated
        finishedComparison = key
    }

    /// Fingerprint of the saved rows a comparison reads: session id, seats,
    /// and every proposal/vote row's identity, status, stance, digest and
    /// candidate text. A new session, a newly recorded vote or a changed
    /// candidate therefore produces a different stamp; unrelated rows (prompts,
    /// independent answers) do not.
    private func comparisonStamp() -> Int {
        var hasher = Hasher()
        hasher.combine(ArenaSessionDigest.id(session) ?? "")
        hasher.combine(participants.joined(separator: "\u{1F}"))
        for row in session?["history"] as? [[String: Any]] ?? [] {
            let stage = ArenaValue.string(row["stage"]) ?? ""
            guard stage == "proposal" || stage == "vote" else { continue }
            hasher.combine(ArenaValue.string(row["id"]) ?? "")
            hasher.combine(stage)
            hasher.combine(ArenaValue.string(row["provider"]) ?? "")
            hasher.combine(ArenaValue.string(row["status"]) ?? "")
            hasher.combine(ArenaValue.string(row["sourceId"]) ?? "")
            hasher.combine(ArenaValue.int(row["version"]) ?? 0)
            hasher.combine(ArenaValue.string(row["stance"]) ?? "")
            hasher.combine(ArenaValue.string(row["proposalDigest"]) ?? "")
            if stage == "proposal" {
                hasher.combine(ArenaValue.string(row["answer"]) ?? "")
            }
        }
        return hasher.finalize()
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
            withAnimation(ArenaMotion.quick(reduceMotion)) { changePulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard pulseSequence == sequence else { return }
                withAnimation(ArenaMotion.change(reduceMotion)) { changePulse = false }
            }
        }
    }

    private func comparisonChangesView(
        older: ArenaCandidateVersion,
        newer: ArenaCandidateVersion,
        concerns: [ArenaCandidateVote]
    ) -> some View {
        // One token prefix for this exact version pair: the same S9 can be
        // quoted by several changed paragraphs and by both panels, so every
        // focus token also carries the change id and the source id.
        let pairToken = "v\(older.version)-v\(newer.version)"
        return VStack(alignment: .leading, spacing: 8) {
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
                    comparisonChangeRow(change, scope: pairToken, concerns: concerns)
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
        scope: String,
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
            markdown(change.newText ?? "", from: "comparison")
                .lineLimit(6)
                .opacity(0.72)
        case .changed:
            VStack(alignment: .leading, spacing: 6) {
                changeTag("修改", color: .accentColor)
                markdown(change.newText ?? "", from: "comparison")
                if let old = change.oldText {
                    ReportSelfDisclosure {
                        Text("旧版这一段").font(.caption)
                    } content: {
                        Text(verbatim: old)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                }
                comparisonCitations(change.newCitations, scope: scope, change: change.id, concerns: concerns)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(changePulse ? 0.10 : 0.035))
            )
        case .added:
            VStack(alignment: .leading, spacing: 6) {
                changeTag("新增", color: .green)
                markdown(change.newText ?? "", from: "comparison")
                comparisonCitations(change.newCitations, scope: scope, change: change.id, concerns: concerns)
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
        scope: String,
        change: Int,
        concerns: [ArenaCandidateVote]
    ) -> some View {
        if !identifiers.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("改段明确引用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(identifiers, id: \.self) { identifier in
                    if let row = candidateSource(identifier) {
                        let token = "\(scope)-c\(change)-\(identifier)"
                        Button {
                            openSource(row, from: token)
                        } label: {
                            HStack(spacing: 4) {
                                Text(citationTitle(identifier, row: row, concerns: concerns))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .accessibilityHidden(true)
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.link)
                        .accessibilityLabel("打开 \(identifier) 的保存原文")
                        .reportFocusEntry(token, in: $entryFocus)
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
                    let token = "concern-\(concern.version)-\(concern.provider)-\(concern.sourceID)"
                    Button {
                        if let source { openSource(source, from: token) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Self.color(concern.stance))
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
                            }
                        }
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ArenaPressStyle())
                    .disabled(source == nil)
                    .reportFocusEntry(token, in: $entryFocus)
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
                    versionVoteRow(vote, version: snapshot.version)
                }
                ForEach(snapshot.gaps) { gap in
                    versionGapRow(gap, version: snapshot.version)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
    }

    private func versionVoteRow(_ vote: ArenaCandidateVote, version: Int) -> some View {
        let source = candidateSource(vote.sourceID)
        let token = "ballot-\(version)-\(vote.provider)"
        return Button {
            if let source { openSource(source, from: token) }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(Self.color(vote.stance))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
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
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ArenaPressStyle())
        .disabled(source == nil)
        .help("打开 \(vote.sourceID) 的保存原文")
        .reportFocusEntry(token, in: $entryFocus)
    }

    private func versionGapRow(_ gap: ArenaCandidateVoteGap, version: Int) -> some View {
        let source = gap.sourceID.flatMap { candidateSource($0) }
        let token = "gap-\(version)-\(gap.provider)-\(gap.sourceID ?? "none")"
        return Button {
            if let source { openSource(source, from: token) }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
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
        .buttonStyle(ArenaPressStyle())
        .disabled(source == nil)
        .reportFocusEntry(token, in: $entryFocus)
    }

    private func candidateSource(_ identifier: String) -> ArenaTaskRow? {
        guard !identifier.isEmpty else { return nil }
        return rows.first { $0.sourceId == identifier && $0.answer?.isEmpty == false }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(currentSources) { row in
                let token = "source-\(row.id)"
                Button { openSource(row, from: token) } label: {
                    HStack {
                        Text(row.sourceId).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Text(ArenaSeatCatalog.name(row.provider))
                        Spacer()
                        Text("\(ArenaStageNames.taskLabel(row.stage, round: row.round, session: session))").foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                    }
                    .padding(.vertical, 7).padding(.horizontal, 4).contentShape(Rectangle())
                }
                .buttonStyle(ArenaPressStyle())
                .accessibilityHint("打开 \(row.sourceId) 的保存原文")
                .reportFocusEntry("source-\(row.id)", in: $entryFocus)
            }
        }.padding(.top, 8)
    }

    private func questionSection(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                showQuestion.toggle()
            } label: {
                HStack(spacing: 8) {
                    ArenaDisclosureChevron(isExpanded: showQuestion)
                    Text(showQuestion ? "收起原始问题" : "原始问题")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ArenaPressStyle())
            .foregroundStyle(.secondary)
            .accessibilityLabel("原始问题")
            .accessibilityValue(showQuestion ? "已展开" : "已收起")
            .accessibilityHint(showQuestion ? "收起原始问题" : "展开原始问题")

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
            closeSource()
        }
    }

    /// Markdown bodies render citations as text links, so the jump has no
    /// character-level focus of its own. `from` names the section's own
    /// operable button (its disclosure header or drafting link); returning puts
    /// focus there instead of guessing a neighbour.
    private func markdown(_ text: String, from token: String? = nil) -> some View {
        ArenaMarkdownView(text: text, onSource: { ref in
            openSource(matching: ref, from: token)
        }, sources: Set(currentSources.map(\.sourceId)))
    }

    /// 完整报告正文。超长报告换成单篇可选富文本，一次排版完再显示；普通材料
    /// 继续用原有逐块排版。两条路径的出处跳转都落到同一份保存原文。
    @ViewBuilder private func fullReport(_ text: String, from token: String?) -> some View {
        if ArenaReportSurfacePolicy.prefersTextSurface(for: text) {
            // 挂到下一次主循环再创建正文，AXPress 不会卡在整篇排版里超时。
            ArenaDeferredReportSurface(
                text: text,
                onSource: { ref in
                    openSource(matching: ref, from: token)
                },
                sources: Set(currentSources.map(\.sourceId))
            )
        } else {
            markdown(text, from: token)
        }
    }

    private static func stance(_ value: String?) -> String {
        switch value { case "agree": return "同意"; case "conditional": return "有条件同意"; case "oppose": return "反对"; default: return "未核实表态" }
    }
    private static func color(_ value: String?) -> Color {
        switch value { case "agree": return .green; case "conditional": return .orange; case "oppose": return .red; default: return .secondary }
    }

    /// One collapsed block of the report. The chevron, the caller's label and the
    /// empty space to the right are a single plain full-width button, so the whole
    /// row toggles while the content stays inert. Only the chevron rotates and
    /// only the pressed tint follows the gesture; the long body itself is never
    /// animated. Accessibility reads the current state; content only exists
    /// while expanded, exactly like the original 完整报告 row.
    private struct ReportDisclosure<RowLabel: View, Content: View>: View {
        @Binding var isExpanded: Bool
        /// Optional entry token for the report's focus state. It must land on
        /// the header button itself, because that is the control a return
        /// hands keyboard focus back to.
        var focusToken: String? = nil
        var focus: FocusState<String?>.Binding? = nil
        private let label: () -> RowLabel
        private let content: () -> Content

        init(
            isExpanded: Binding<Bool>,
            focusToken: String? = nil,
            focus: FocusState<String?>.Binding? = nil,
            @ViewBuilder label: @escaping () -> RowLabel,
            @ViewBuilder content: @escaping () -> Content
        ) {
            self._isExpanded = isExpanded
            self.focusToken = focusToken
            self.focus = focus
            self.label = label
            self.content = content
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        ArenaDisclosureChevron(isExpanded: isExpanded)
                        label()
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ArenaPressStyle())
                .accessibilityValue(isExpanded ? "已展开" : "已收起")
                .accessibilityHint(isExpanded ? "收起内容" : "展开内容")
                .modifier(ArenaReportFocusEntry(token: focusToken, focus: focus))
                if isExpanded { content() }
            }
        }
    }

    /// A report disclosure that owns its own expansion, for repeated rows such
    /// as saved originals and prior-diff text. Same chevron, same press
    /// feedback, same accessibility state as `ReportDisclosure`.
    private struct ReportSelfDisclosure<RowLabel: View, Content: View>: View {
        @State private var isExpanded = false
        var focusToken: String? = nil
        var focus: FocusState<String?>.Binding? = nil
        private let label: () -> RowLabel
        private let content: () -> Content

        init(
            focusToken: String? = nil,
            focus: FocusState<String?>.Binding? = nil,
            @ViewBuilder label: @escaping () -> RowLabel,
            @ViewBuilder content: @escaping () -> Content
        ) {
            self.focusToken = focusToken
            self.focus = focus
            self.label = label
            self.content = content
        }

        var body: some View {
            ReportDisclosure(
                isExpanded: $isExpanded,
                focusToken: focusToken,
                focus: focus,
                label: label,
                content: content
            )
        }
    }
}

/// Identity of one finished comparison. The stamp covers the saved rows the
/// comparison read, so the same version pair in a changed session rebuilds.
private struct ArenaComparisonKey: Equatable {
    let stamp: Int
    let left: Int
    let right: Int
}

/// One version's bridge-backed snapshot and the stamp it was computed from.
private struct ArenaSnapshotCacheEntry {
    let stamp: Int
    let snapshot: ArenaCandidateSnapshot
}

/// The existing source-navigation surface, reused by the report and by the
/// history tab's review-material rows. `returnLabel` names the real way back.
struct ArenaSourceReader: View {
    let row: ArenaTaskRow
    let session: [String: Any]?
    let returnLabel: String
    let onReturn: () -> Void
    /// Opening a saved original disables the report underneath, so keyboard
    /// focus starts on this「返回」control and never stays on an inert row.
    @FocusState private var returnFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onReturn) {
                    Label(returnLabel, systemImage: "chevron.left")
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.link)
                .keyboardShortcut(.cancelAction)
                .help("\(returnLabel)（Esc）")
                .accessibilityHint("返回后保留原来的阅读位置，焦点回到打开它的条目")
                .focused($returnFocused)
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
        .onAppear { returnFocused = true }
        .id(row.id)
    }
}

/// Applies the report's one focus state to a discrete entry control, so
/// returning from a saved original can put keyboard focus back on the row that
/// opened it. A view without a token is left untouched rather than being turned
/// into a focus stop of its own; real buttons already take keyboard focus.
fileprivate struct ArenaReportFocusEntry: ViewModifier {
    let token: String?
    let focus: FocusState<String?>.Binding?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let token, let focus {
            content.focused(focus, equals: token)
        } else {
            content
        }
    }
}

fileprivate extension View {
    func reportFocusEntry(_ token: String?, in focus: FocusState<String?>.Binding) -> some View {
        modifier(ArenaReportFocusEntry(token: token, focus: focus))
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
