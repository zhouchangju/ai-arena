//
//  report_artifacts.swift
//  AI Arena · 结构化候选、图解、离线 HTML 与本地视频
//
//  目标：G2/G3/G4，R05/R07。只验证读取与产物规则：固定 Markdown 区块、
//  旧格式回退、图解连线来源、HTML 转义与离线边界、分镜无删减、H.264 MP4。
//  不启动应用、不创建窗口、不加载网页、不访问真实账号。

import AVFoundation
import Foundation

@main
struct ReportArtifactsCheck {
    static func main() {
        var failures = 0

        func check(_ name: String, _ value: Bool) {
            if value {
                print("ok   \(name)")
            } else {
                failures += 1
                print("FAIL \(name)")
            }
        }

        let candidate = """
        ## 直接建议
        先用手机快捷入口验证采集频次，再决定是否做完整移动端。[S1]

        ## 成立条件
        - 采集确实发生在路上。[S1]
        - 两个周末内只做入口，不做完整同步。
        - 无额外条件。

        ## 影响建议的未决分歧
        - 采集频次尚未证实，需要一周记录。[S2]

        ## 其他说明
        **最强反例**：现有数据只证明检索慢。[S2]
        """

        guard let digest = ArenaCandidateDigest.parse(candidate) else {
            print("FAIL fixed blocks did not parse")
            exit(1)
        }

        check("advice keeps the whole first block",
              digest.advicePlain.contains("先用手机快捷入口验证采集频次"))
        check("advice keeps its citation", digest.advicePlain.contains("[S1]"))
        check("conditions parse as separate items",
              digest.conditions.count == 3)
        check("condition markers are stripped",
              digest.conditions[0].plain == "采集确实发生在路上。[S1]")
        check("condition citations are retained",
              digest.conditions[0].citations == ["S1"])
        check("disputes parse separately", digest.disputes.count == 1)
        check("disputes keep the open question",
              digest.disputes[0].plain.contains("采集频次尚未证实"))
        check("other body keeps the strongest counterexample",
              digest.hasOther && digest.otherPlain.contains("最强反例"))

        // The old candidate formatting and a partially structured candidate
        // both fall back instead of being guessed into the new contract.
        let oldFormat = """
        候选结论

        先做移动端，因为采集常发生在路上。

        适用条件：仅限两个周末。
        """
        check("old lead-paragraph candidate does not pretend to parse",
              ArenaCandidateDigest.parse(oldFormat) == nil)
        let missingConditions = """
        ## 直接建议
        先做入口。

        ## 影响建议的未决分歧
        无。
        """
        check("missing conditions block is not a reliable parse",
              ArenaCandidateDigest.parse(missingConditions) == nil)
        let missingDisputes = """
        ## 直接建议
        先做入口。

        ## 成立条件
        - 采集发生在路上。
        """
        check("a missing dispute block falls back instead of claiming none",
              ArenaCandidateDigest.parse(missingDisputes) == nil)
        let outOfOrder = """
        ## 成立条件
        - 采集发生在路上。

        ## 直接建议
        先做入口。

        ## 影响建议的未决分歧
        无。
        """
        check("fixed blocks out of order fall back",
              ArenaCandidateDigest.parse(outOfOrder) == nil)
        let duplicate = """
        ## 直接建议
        先做入口。

        ## 成立条件
        - 采集发生在路上。

        ## 影响建议的未决分歧
        无。

        ## 成立条件
        - 第二条。
        """
        check("a duplicated fixed block falls back",
              ArenaCandidateDigest.parse(duplicate) == nil)

        // web-driver reads innerText, which removes Markdown heading markers.
        let innerText = """
        直接建议

        先验证检索，再扩大覆盖。[S1]

        成立条件

        须覆盖高峰，且支持独立回滚。[S2]

        影响建议的未决分歧

        月末样本不足时，继续试点。[S3]

        其他说明

        验证主要反例的依据。[S4]
        """
        if let plain = ArenaCandidateDigest.parse(innerText) {
            check("bare innerText headings parse",
                  plain.advicePlain.contains("先验证检索")
                      && plain.conditions.count == 1
                      && plain.disputes.count == 1)
            check("bare innerText citations stay attached",
                  plain.adviceRaw.contains("[S1]")
                      && plain.conditions[0].citations == ["S2"]
                      && plain.disputes[0].citations == ["S3"])
            check("bare innerText other body is retained",
                  plain.otherPlain.contains("验证主要反例的依据"))
        } else {
            check("bare innerText candidate parses", false)
        }

        let boldHeadings = """
        **直接建议**：先做入口。[S1]

        **成立条件**
        - 采集发生在路上。[S1]

        **影响建议的未决分歧**
        - 采集频次待核对。[S2]
        """
        let bold = ArenaCandidateDigest.parse(boldHeadings)
        check("bold headings are tolerated", bold?.advicePlain.contains("先做入口") == true)
        check("bold condition heading is parsed", bold?.conditions.count == 1)

        check("only a whole source-id group is a citation",
              ArenaDigestCitations.ids(in: "见 [备注 S2] 与 [S1, S2]") == ["S1", "S2"]
                  && ArenaDigestCitations.ids(in: "[备注 S2]").isEmpty)

        let fenced = """
        ## 直接建议
        先做入口。[S1]

        ## 成立条件
        - 采集发生在路上。[S1]

        ## 影响建议的未决分歧
        无。

        ## 其他说明
        ```markdown
        ## 直接建议
        这不是新标题，只是示例代码。
        ```
        """
        if let fencedDigest = ArenaCandidateDigest.parse(fenced) {
            check("a fenced heading does not overwrite the real advice block",
                  fencedDigest.advicePlain.contains("先做入口")
                      && !fencedDigest.advicePlain.contains("这不是新标题"))
            check("a fenced heading stays in the other body",
                  fencedDigest.otherPlain.contains("这不是新标题"))
        } else {
            check("fenced candidate parses", false)
        }

        let graph = ArenaReportGraphBuilder.build(digest)
        check("graph has advice, conditions, one dispute and a verify node",
              graph.nodes.filter { $0.kind == .advice }.count == 1
                  && graph.nodes.filter { $0.kind == .condition }.count == 2
                  && graph.nodes.filter { $0.kind == .dispute }.count == 1
                  && graph.nodes.filter { $0.kind == .verify }.count == 1)
        check("each real condition points only to the advice node",
              graph.edges.filter { $0.label == "成立条件" }.count == 2
                  && graph.edges.filter { $0.label == "成立条件" }.allSatisfy { $0.to == "advice" })
        check("the dispute points to verification, never to the advice as fact",
              graph.edges.filter { $0.label == "待核对" }.count == 1
                  && graph.edges.filter { $0.label == "待核对" }.allSatisfy { $0.to == "verify" }
                  && !graph.edges.contains { $0.from.hasPrefix("dispute") && $0.to == "advice" })
        check("every edge names a real node",
              graph.edges.allSatisfy { edge in
                  graph.nodes.contains { $0.id == edge.from }
                      && graph.nodes.contains { $0.id == edge.to }
              })

        let noConditions = """
        ## 直接建议
        直接做。[S1]

        ## 成立条件
        - 无额外条件。

        ## 影响建议的未决分歧
        - 无。
        """
        if let none = ArenaCandidateDigest.parse(noConditions) {
            let noneGraph = ArenaReportGraphBuilder.build(none)
            check("none markers create no invented condition or dispute edges",
                  noneGraph.nodes.filter { $0.kind == .condition }.isEmpty
                      && noneGraph.nodes.filter { $0.kind == .dispute }.isEmpty
                      && noneGraph.edges.isEmpty)
        } else {
            check("none marker candidate parses", false)
        }

        // MARK: HTML

        let hostile = """
        ## 直接建议
        <script>alert('candidate')</script> 先用入口。[S1] 另见 [备注 S2]。

        ## 成立条件
        - <img src=x onerror=alert(1)> 采集发生在路上。[S1]

        ## 影响建议的未决分歧
        - 采集频次待核对。[S2]
        """
        guard let hostileDigest = ArenaCandidateDigest.parse(hostile) else {
            print("FAIL hostile candidate did not parse")
            exit(1)
        }
        let input = ArenaReportArtifactInput(
            question: "<script>alert('question')</script>\n第二行",
            outcome: "有条件同意",
            isVerifiedConsensus: false,
            version: 1,
            candidateAuthor: "ChatGPT",
            candidateSourceID: "S1",
            digest: hostileDigest,
            participants: ["chatgpt", "gemini"],
            seatLabels: ["chatgpt": "ChatGPT", "gemini": "Gemini"],
            positions: [
                ArenaReportPositionRow(
                    provider: "chatgpt",
                    seatLabel: "ChatGPT",
                    stance: "conditional",
                    stanceLabel: "有条件同意",
                    sourceID: "S3",
                    answer: "<script>alert('vote')</script> 只有一周记录才同意。"
                ),
            ],
            sources: [
                ArenaReportSourceRow(
                    id: "S1",
                    seatLabel: "ChatGPT",
                    stageLabel: "互评 · 第 1 轮",
                    answer: "<script>alert('source')</script> 原文"
                ),
                ArenaReportSourceRow(
                    id: "S2",
                    seatLabel: "Gemini",
                    stageLabel: "互评 · 第 1 轮",
                    answer: "第二席原文"
                ),
                ArenaReportSourceRow(
                    id: "S3",
                    seatLabel: "ChatGPT",
                    stageLabel: "表态 · 第 1 轮",
                    answer: "表态原文"
                ),
            ]
        )
        let html = ArenaReportHTML.build(input)
        check("HTML escapes the question",
              html.contains("&lt;script&gt;alert(&#39;question&#39;)&lt;/script&gt;"))
        check("HTML escapes candidate and source text",
              html.contains("&lt;script&gt;alert(&#39;candidate&#39;)&lt;/script&gt;")
                  && html.contains("&lt;script&gt;alert(&#39;source&#39;)&lt;/script&gt;"))
        check("HTML contains no executable script or image tag",
              !html.lowercased().contains("<script")
                  && !html.lowercased().contains("<img")
                  && !html.lowercased().contains("<link"))
        check("HTML has no remote anchor",
              !html.contains("href=\"http")
                  && !html.contains("src=\"http")
                  && !html.contains("@import"))
        check("HTML sets a static offline CSP",
              html.contains("content=\"default-src 'none'; style-src 'unsafe-inline'\""))
        check("HTML uses details for interaction",
              html.contains("<details") && html.contains("<summary>"))
        check("HTML puts the source anchor inside details",
              html.contains("<div class=\"raw\" id=\"source-S1\">")
                  && html.contains("href=\"#source-S1\"")
                  && !html.contains("id=\"source-S1\" open"))
        check("ordinary bracket notes are not linkified",
              html.contains("[备注 S2]")
                  && !html.contains("备注 <a"))
        check("HTML shows an absent seat as not agreeing",
              html.contains("Gemini")
                  && html.contains("未对 v1 明确表态（不计为同意）"))

        // MARK: 视频分镜

        let shots = ArenaReportVideoPlan.shots(for: input)
        check("first shot is the independent session state",
              shots.first?.title == "本场状态"
                  && shots.first?.body.contains("候选 v1") == true)
        let joined = shots.map(\.body).joined(separator: "\n")
        check("advice appears in full in the storyboard",
              joined.contains(hostileDigest.advicePlain))
        check("all conditions appear in full in the storyboard",
              hostileDigest.conditions.allSatisfy { joined.contains($0.plain) })
        check("all disputes appear in full in the storyboard",
              hostileDigest.disputes.allSatisfy { joined.contains($0.plain) })
        check("the conditional vote keeps its qualifier",
              joined.contains("只有一周记录才同意"))
        check("the storyboard does not add an ellipsis summary",
              !shots.contains { $0.body.contains("…") })

        let long = String(repeating: "限定语必须完整保留。", count: 30)
        let chunks = ArenaReportVideoPlan.chunks(long, limit: 140)
        let normalizedChunks = chunks.joined().filter { !$0.isWhitespace }
        let normalizedLong = long.filter { !$0.isWhitespace }
        check("chunking never drops text", normalizedChunks == normalizedLong)

        // MARK: 真正可播放的本地 MP4

        let videoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arena-report-video-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: videoDirectory) }
        let output = videoDirectory.appendingPathComponent("brief.mp4")
        let brief = [
            ArenaReportVideoShot(id: 0, title: "本场状态", body: "有条件同意 · 候选 v1", footer: "本地生成", duration: 2.6),
            ArenaReportVideoShot(id: 1, title: "直接建议", body: "先用手机快捷入口验证采集频次。[S1]", footer: "候选 S1", duration: 2.6),
        ]
        do {
            try ArenaReportVideo.render(
                shots: brief,
                to: output,
                options: ArenaReportVideoOptions(width: 480, height: 270, frameRate: 10)
            )
        } catch {
            check("video render completes: \(error.localizedDescription)", false)
            exit(1)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        check("video file exists and is non-trivial", size > 1_000)
        let asset = AVURLAsset(url: output)
        let tracks = asset.tracks(withMediaType: .video)
        check("video has a video track", tracks.count == 1)
        check("video has a positive duration", asset.duration.seconds > 0.5)
        check("video keeps the requested frame size",
              tracks.first?.naturalSize.width == 480 && tracks.first?.naturalSize.height == 270)

        // A failed render must not delete the user's previous file.
        let protected = videoDirectory.appendingPathComponent("protected.mp4")
        try? Data("ORIGINAL_VIDEO_BYTES".utf8).write(to: protected)
        do {
            try ArenaReportVideo.render(
                shots: brief,
                to: protected,
                options: ArenaReportVideoOptions(width: 0, height: 270, frameRate: 10)
            )
            check("invalid video options fail", false)
        } catch {
            // Expected: validation fails before any file operation.
        }
        let kept = (try? String(contentsOf: protected, encoding: .utf8)) ?? ""
        check("a failed render leaves the previous file untouched",
              kept == "ORIGINAL_VIDEO_BYTES")

        // A successful render atomically replaces an existing file.
        let replacement = videoDirectory.appendingPathComponent("replacement.mp4")
        try? Data("OLD".utf8).write(to: replacement)
        do {
            try ArenaReportVideo.render(
                shots: brief,
                to: replacement,
                options: ArenaReportVideoOptions(width: 480, height: 270, frameRate: 10)
            )
        } catch {
            check("replacement render completes: \(error.localizedDescription)", false)
        }
        let replacementSize = ((try? FileManager.default.attributesOfItem(atPath: replacement.path))?[.size] as? NSNumber)?.intValue ?? 0
        check("a successful render replaces the previous file", replacementSize > 1_000)

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: videoDirectory.path))?
            .filter { $0.hasPrefix(".arena-video-") } ?? []
        check("no temporary video file remains after success or failure", leftovers.isEmpty)

        if failures == 0 {
            print("report artifact checks passed")
        } else {
            print("\(failures) report artifact check(s) failed")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
