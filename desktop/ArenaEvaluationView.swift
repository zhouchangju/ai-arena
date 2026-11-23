import SwiftUI

struct ArenaEvaluationSection: View {
    let sessionID: String
    let chatGPTParticipated: Bool
    @ObservedObject var model: ArenaModel
    let openSource: (String) -> Void

    @State private var saved: ArenaEvaluation?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let saved {
                Text("本场独立作答评估").font(.headline).accessibilityAddTraits(.isHeader)
                Text(chatGPTParticipated ? "裁判：ChatGPT 网页（同站参赛）" : "裁判：ChatGPT 网页")
                    .foregroundStyle(.secondary)
                if let ranks = saved.ranks {
                    Text(ranks.map { group in
                        group.map { ArenaSeatCatalog.name($0.provider) }.joined(separator: "、")
                    }.joined(separator: "  >  "))
                    .fontWeight(.semibold)
                } else {
                    Text("本场暂无一致排名").fontWeight(.semibold)
                }
                ForEach(saved.comparisons) { row in
                    comparisonRow(row, evaluation: saved)
                }
            } else if loaded {
                Button("评估本场") { evaluate() }
                    .disabled(model.evaluatingSessionID != nil)
                Text("将题面、附件和去掉席位标签的独立作答发到 ChatGPT 新会话。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.evaluatingSessionID == sessionID {
                ProgressView("等待 ChatGPT 裁判结果…").controlSize(.small)
            }
            if let error {
                Text(verbatim: error).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: sessionID) {
            do {
                saved = try model.evaluation(sessionID: sessionID)
                loaded = true
            } catch {
                self.error = "无法读取本场评估：\(error.localizedDescription)"
            }
        }
        .onChange(of: model.evaluatingSessionID) { active in
            if active == nil, let latest = try? model.evaluation(sessionID: sessionID) {
                saved = latest
            }
        }
    }

    private func evaluate(pairID: String? = nil) {
        error = nil
        Task {
            do {
                saved = try await model.runEvaluation(sessionID: sessionID, reversing: pairID)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func seat(_ label: String, in evaluation: ArenaEvaluation) -> String {
        evaluation.entries.first { $0.label == label }.map { ArenaSeatCatalog.name($0.provider) } ?? label
    }

    private func outcome(_ row: ArenaEvaluation.Comparison, in evaluation: ArenaEvaluation) -> String {
        if let winner = row.winner() { return seat(winner, in: evaluation) + "胜" }
        return row.verdict == .tie ? "平局" : "证据不足"
    }

    private func comparisonRow(_ row: ArenaEvaluation.Comparison, evaluation: ArenaEvaluation) -> some View {
        let check = evaluation.checks[row.id]
        let disputed = check.map { !ArenaEvaluation.agrees(row, $0) } ?? false
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(seat(row.left, in: evaluation)) 对 \(seat(row.right, in: evaluation))")
                    .fontWeight(.medium)
                Text(disputed ? "待复核" : outcome(row, in: evaluation))
                    .foregroundStyle(.secondary)
                Spacer()
                if check == nil {
                    Button("交换顺序复判") { evaluate(pairID: row.id) }
                        .buttonStyle(.link)
                        .disabled(model.evaluatingSessionID != nil)
                }
            }
            if disputed { Text("初判 · \(outcome(row, in: evaluation))").fontWeight(.medium) }
            evidence(row)
            if let check {
                Text("复判 · \(outcome(check, in: evaluation))").fontWeight(.medium)
                evidence(check)
            }
        }
        .padding(.vertical, 5)
    }

    private func evidence(_ row: ArenaEvaluation.Comparison) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: row.reason).textSelection(.enabled)
            HStack(spacing: 8) {
                ForEach(Array(Set(row.sources)).sorted(), id: \.self) { source in
                    Button(source) { openSource(source) }.buttonStyle(.link)
                }
            }
        }
        .foregroundStyle(.secondary)
    }
}
