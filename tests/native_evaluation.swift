import Foundation

@main
struct EvaluationTest {
    static func main() throws {
        let candidates = ["chatgpt", "gemini", "deepseek"].enumerated().map { index, provider in
            ArenaEvaluationDraft.Candidate(provider: provider, source: "S\(index + 1)", answer: "作答 \(index + 1)")
        }
        let draft = ArenaEvaluationDraft(
            question: "相同题面", candidates: candidates, images: [], texts: ["文本": "相同材料"]
        )
        assert(candidates.allSatisfy { !draft.prompt.contains($0.provider) && draft.prompt.contains($0.answer) })
        assert(draft.prompt.contains("相同材料"))
        let ac = comparison(draft, "A", "C", .left)
        let ab = comparison(draft, "A", "B", .left)
        let bc = comparison(draft, "B", "C", .left)
        let parsed = try draft.parse("```json\n" + response(draft, [bc, ab, ac]) + "\n```")
        var saved = ArenaEvaluation(id: draft.id, entries: draft.entries, judge: "独立裁判", comparisons: parsed)
        assert(saved.ranks?.map { $0.map(\.label) } == [["A"], ["B"], ["C"]])
        let reverse = ArenaEvaluationDraft(
            question: draft.question, evaluation: saved, reversing: ab, images: [], texts: [:], candidates: candidates
        )
        assert(reverse.entries.map(\.label) == ["B", "A"])
        assert(!reverse.prompt.contains(draft.answers[draft.entries[2].source]!))
        let rechecked = try reverse.parse(response(reverse, [comparison(reverse, "B", "A", .right)]))
        saved.checks[ab.id] = rechecked[0]
        assert(saved.ranks != nil)
        saved.checks[ab.id] = comparison(reverse, "B", "A", .left)
        assert(saved.ranks == nil)
        let restored = try JSONDecoder().decode(ArenaEvaluation.self, from: JSONEncoder().encode(saved))
        assert(restored.ranks == nil && restored.checks[ab.id]?.left == "B")

        let cycle = ArenaEvaluation(id: draft.id, entries: draft.entries, judge: "裁判",
                                    comparisons: [ab, comparison(draft, "A", "C", .right), bc])
        assert(cycle.ranks == nil)
        let tied = ArenaEvaluation(id: draft.id, entries: draft.entries, judge: "裁判",
                                   comparisons: [comparison(draft, "A", "B", .tie), ac, bc])
        assert(tied.ranks?.map { $0.map(\.label) } == [["A", "B"], ["C"]])
        let insufficient = ArenaEvaluation(id: draft.id, entries: draft.entries, judge: "裁判",
                                           comparisons: [ab, ac, comparison(draft, "B", "C", .insufficient)])
        assert(insufficient.ranks == nil)
        let wrongSource = ArenaEvaluation.Comparison(left: "A", right: "B", verdict: .left, reason: "理由", sources: ["S99"])
        assert((try? draft.parse(response(draft, [wrongSource, ac, bc]))) == nil)
        assert((try? draft.parse(response(draft, [ab, ab, bc]))) == nil)
        assert((try? draft.parse(response(reverse, [ab, ac, bc]))) == nil)

        let two = ArenaEvaluationDraft(question: "两席", candidates: Array(candidates.prefix(2)), images: [], texts: [:])
        let pair = comparison(two, "A", "B", .tie)
        let twoRows = try two.parse(response(two, [pair]))
        let twoResult = ArenaEvaluation(id: two.id, entries: two.entries, judge: "裁判", comparisons: twoRows)
        assert(twoResult.ranks?.first?.count == 2)
        print("PASS: blind input, two/three seats, import validation, ties, cycles, and reversed-order review")
    }

    private static func comparison(
        _ draft: ArenaEvaluationDraft, _ left: String, _ right: String, _ verdict: ArenaEvaluation.Verdict
    ) -> ArenaEvaluation.Comparison {
        let source = draft.entries.first { $0.label == left }!.source
        return ArenaEvaluation.Comparison(left: left, right: right, verdict: verdict, reason: "引用具体原文", sources: [source])
    }

    private static func response(_ draft: ArenaEvaluationDraft, _ rows: [ArenaEvaluation.Comparison]) -> String {
        let json = try! JSONEncoder().encode(rows)
        return """
        {"evaluationID":"\(draft.id.uuidString)","comparisons":\(String(decoding: json, as: UTF8.self))}
        """
    }
}
