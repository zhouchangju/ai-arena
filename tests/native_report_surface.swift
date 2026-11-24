//
//  native_report_surface.swift
//  AI Arena · 超长完整报告单篇富文本的定向检查
//
//  目标：G2/G4，R05/R07。只验证排版结果本身：内容不丢、表格行列对应、
//  出处与网页链接仍可点、删除线保留、大表大列表触发换面，以及 emoji 不被
//  按码元拆开。不启动应用、不打开窗口、不联网。由
//  tests/native_report_surface.py 编译运行。
//

import AppKit
import Foundation
import SwiftUI

@main
struct NativeReportSurfaceCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        var failures = 0

        func check(_ name: String, _ value: Bool) {
            if value {
                print("ok   \(name)")
            } else {
                failures += 1
                print("FAIL \(name)")
            }
        }

        /// 一段文字在整篇里的属性，用来核对链接、字体与删除线。
        func attribute(_ text: NSAttributedString, of needle: String, key: NSAttributedString.Key) -> Any? {
            let range = (text.string as NSString).range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return text.attribute(key, at: range.location, effectiveRange: nil)
        }

        func lineRanges(_ text: NSAttributedString) -> [NSRange] {
            let plain = text.string as NSString
            var result: [NSRange] = []
            var location = 0
            while location <= plain.length {
                let search = NSRange(location: location, length: plain.length - location)
                let cut = plain.range(of: "\n", range: search)
                let end = cut.location == NSNotFound ? plain.length : cut.location
                result.append(NSRange(location: location, length: end - location))
                if cut.location == NSNotFound { break }
                location = cut.location + 1
            }
            return result.filter { $0.length > 0 }
        }

        // MARK: 策略：按估计子视图数换面，一张大表或一份大列表也算

        let wideTable = ArenaMarkdownBlock.table(
            header: ["证据", "状态", "说明"],
            rows: (0..<500).map { ["首轮答复 \($0)", "已保存", "核对原文"] }
        )
        check("a 500-row three-column table asks for the text surface",
              ArenaReportSurfacePolicy.prefersTextSurface(blocks: [wideTable]))

        let longList = ArenaMarkdownBlock.list(
            items: (0..<500).map { ArenaMarkdownListItem(depth: 0, marker: "•", text: "核对第 \($0) 项") },
            ordered: false
        )
        check("a 500-item list asks for the text surface",
              ArenaReportSurfacePolicy.prefersTextSurface(blocks: [longList]))

        let shortTable = ArenaMarkdownBlock.table(header: ["证据", "状态"], rows: [["首轮答复", "已保存"]])
        let ordinary: [ArenaMarkdownBlock] = [
            .heading(level: 1, text: "讨论报告"),
            .paragraph(text: "本场三席各自作答。"),
            shortTable,
            .paragraph(text: "结论需要复核。"),
        ]
        check("an ordinary short report keeps the per-block layout",
              !ArenaReportSurfacePolicy.prefersTextSurface(blocks: ordinary))
        check("a short table alone does not ask for the text surface",
              ArenaReportSurfacePolicy.estimatedSubviews(of: shortTable) < ArenaReportSurfacePolicy.estimatedSubviewThreshold)
        check("table cost counts cells, not blocks",
              ArenaReportSurfacePolicy.estimatedSubviews(of: wideTable) > 500)

        // MARK: 并排表格：短列对齐，链接与出处保留

        // 与生产一致：整篇排版时才补出处链接，因此这里走 attributedString。
        let narrow = ArenaReportTypesetter.attributedString(
            blocks: [.table(header: ["证据", "状态"],
                            rows: [["[官网](https://example.com) 首轮 [S1]", "已保存"]])],
            sources: ["S1"]
        )
        check("a short table keeps cells on one aligned line", narrow.string.contains("\t"))
        check("a short table keeps the column values", narrow.string.contains("首轮") && narrow.string.contains("已保存"))
        check("a short table keeps a live web link",
              attribute(narrow, of: "官网", key: .link) as? URL == URL(string: "https://example.com"))
        check("a short table keeps the source reference as a link",
              (attribute(narrow, of: "S1", key: .link) as? URL)?.absoluteString == "arena-source://entry/S1")
        check("a short table marks its header",
              (attribute(narrow, of: "证据", key: .underlineStyle) as? Int) == NSUnderlineStyle.single.rawValue)

        let narrowLines = lineRanges(narrow)
        check("every side-by-side line carries its own tab stops", !narrowLines.isEmpty && narrowLines.allSatisfy { range in
            guard let style = narrow.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle else {
                return false
            }
            return style.tabStops.count == 1 && style.tabStops[0].location <= ArenaReportTypesetter.sideBySideWidthBudget
        })

        // MARK: 竖排表格：不适合并排时逐行「列标题　单元格内容」

        let longCell = String(repeating: "核对这一段的原始记录并说明适用范围。", count: 12)
        let stacked = ArenaReportTypesetter.attributedString(
            blocks: [.table(header: ["证据", "状态"],
                            rows: [["[官网](https://example.com) \(longCell)", "已保存"]])],
            sources: []
        )
        check("a table that cannot fit stops using tab stops", !stacked.string.contains("\t"))
        check("a table that cannot fit keeps the column titles", stacked.string.contains("证据") && stacked.string.contains("状态"))
        check("a table that cannot fit keeps the long cell in full",
              stacked.string.contains(longCell))
        check("a table that cannot fit keeps the live web link",
              attribute(stacked, of: "官网", key: .link) as? URL == URL(string: "https://example.com"))

        let stackedLines = lineRanges(stacked).map { (stacked.string as NSString).substring(with: $0) }
        check("each stacked line starts with its column title",
              stackedLines.count == 2
                && stackedLines[0].hasPrefix("证据\u{3000}")
                && stackedLines[1].hasPrefix("状态\u{3000}"))
        check("stacked values stay under their own title",
              stackedLines[0].hasSuffix("已保存") == false && stackedLines[1].hasSuffix("已保存"))

        // MARK: emoji 与规模：不按码元拆字，不产生越界制表位

        let emojiCells = (0..<1000).map { _ in "资料😀" }
        let emojiTable = ArenaMarkdownBlock.table(header: ["说明", "备注"], rows: emojiCells.map { [$0, "已保存"] })
        var emojiText = NSAttributedString()
        let start = DispatchTime.now().uptimeNanoseconds
        emojiText = ArenaReportTypesetter.attributedString(blocks: [emojiTable], sources: [])
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        check("1000 emoji cells keep every scalar intact",
              emojiText.string.components(separatedBy: "资料😀").count - 1 == 1000)
        check("no replacement characters are introduced",
              !emojiText.string.contains("\u{FFFD}"))
        check("the emoji table produces no wild tab stop", lineRanges(emojiText).allSatisfy { range in
            guard let style = emojiText.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle else {
                return true
            }
            return style.tabStops.allSatisfy { $0.location <= ArenaReportTypesetter.sideBySideWidthBudget }
        })
        check("1000 emoji cells typeset well under a second", elapsed < 1000)
        print(String(format: "     1000 emoji cells: %.1f ms", elapsed))

        let giantCells = (0..<2500).map { _ in "资料😀" }
        var giantText = NSAttributedString()
        let giantStart = DispatchTime.now().uptimeNanoseconds
        giantText = ArenaReportTypesetter.attributedString(
            blocks: [.table(header: ["说明", "备注"], rows: giantCells.map { [$0, "已保存"] })],
            sources: []
        )
        let giantElapsed = Double(DispatchTime.now().uptimeNanoseconds - giantStart) / 1_000_000
        check("2500 emoji cells keep every scalar intact",
              giantText.string.components(separatedBy: "资料😀").count - 1 == 2500)
        check("2500 emoji cells typeset well under two seconds", giantElapsed < 2000)
        print(String(format: "     2500 emoji cells: %.1f ms", giantElapsed))

        // MARK: 删除线与正文内容

        let struck = ArenaReportTypesetter.inline(
            "~~已取消~~ 改为按月", size: 16, weight: .regular, color: .labelColor
        )
        check("a cancelled phrase keeps its strikethrough",
              (attribute(struck, of: "已取消", key: .strikethroughStyle) as? Int) == NSUnderlineStyle.single.rawValue)
        check("replacement text after a cancelled phrase stays plain",
              attribute(struck, of: "改为按月", key: .strikethroughStyle) == nil)
        check("strikethrough markers are not shown as text",
              !struck.string.contains("~~"))

        let report = """
        # 讨论结论

        三席各自作答；这一句带一处出处 [S2]，另有一处 [官网](https://example.com)。

        ```text
        输入 -> 互评 -> 结论 [S2]
        ```

        | 证据 | 状态 |
        | --- | --- |
        | 首轮答复 | 已保存 |
        """
        let blocks = ArenaMarkdownParser.blocks(in: report)
        let surface = ArenaReportTypesetter.attributedString(blocks: blocks, sources: ["S2"])

        check("headings, paragraphs, code and tables all keep their text",
              surface.string.contains("讨论结论")
                && surface.string.contains("三席各自作答")
                && surface.string.contains("输入 -> 互评 -> 结论")
                && surface.string.contains("首轮答复"))
        check("a paragraph citation opens the saved source",
              (attribute(surface, of: "S2", key: .link) as? URL)?.absoluteString == "arena-source://entry/S2")
        check("a web link stays clickable", surface.string.contains("官网")
              && attribute(surface, of: "官网", key: .link) as? URL == URL(string: "https://example.com"))
        check("code stays monospaced",
              (attribute(surface, of: "输入 -> 互评", key: .font) as? NSFont)?.isFixedPitch == true)
        check("unsafe schemes are not left clickable",
              ArenaReportTypesetter.inline("[点我](javascript:alert(1))", size: 16, weight: .regular,
                                           color: .labelColor).attribute(.link, at: 0, effectiveRange: nil) == nil)

        // MARK: 整篇选择/复制与出处跳转

        check("the whole report is one contiguous selectable string",
              surface.length > 0 && surface.string == (surface.string as NSString) as String)
        let copied = surface.attributedSubstring(from: NSRange(location: 0, length: surface.length)).string
        check("copying the whole range keeps every block", copied == surface.string)

        // 与 ArenaReportTextSurface 相同的接线：仓库 → 布局 → 容器 → 文本视图。
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = ArenaReportTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 400), textContainer: container)
        var opened: [String] = []
        view.onSource = { opened.append($0) }
        view.isEditable = false
        view.isSelectable = true
        view.textStorage?.setAttributedString(surface)
        if let url = ArenaReportTypesetter.sourceLink("S2") {
            view.clicked(onLink: url, at: 0)
        }
        view.clicked(onLink: URL(string: "javascript:alert(1)")!, at: 0)
        check("clicking a source link routes to the reader", opened == ["S2"])
        check("the reading surface is selectable and not editable",
              view.isSelectable && !view.isEditable)
        check("a click does not change the text", view.string == surface.string)

        // MARK: 挂载时机：AXPress 的调用栈里不创建整篇正文

        func firstTextView(_ view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView { return textView }
            for subview in view.subviews {
                if let found = firstTextView(subview) { return found }
            }
            return nil
        }

        let host = NSHostingView(rootView: ArenaDeferredReportSurface(text: report, sources: ["S2"]))
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 400)
        host.layoutSubtreeIfNeeded()
        check("the whole report is not laid out inside the pressing call stack",
              firstTextView(host) == nil)

        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let mounted = firstTextView(host)
        check("the report mounts on the next main-loop turn", mounted != nil)
        check("the mounted surface carries the whole report",
              mounted?.string == surface.string)
        check("selection and copy still work after the deferred mount",
              mounted.map { $0.isSelectable && !$0.isEditable } == true
                && mounted?.string.contains("首轮答复") == true)

        let height = ArenaReportTypesetter.height(of: surface, width: 460)
        check("the measured height is positive and stable",
              height > 0 && height == ArenaReportTypesetter.height(of: surface, width: 460))

        /// 按需布局只影响绘制，不应改变整篇高度；否则滚动范围和阅读位置会变。
        func contiguousHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            return ceil(layout.usedRect(for: container).height)
        }
        check("on-demand layout reports the same height as continuous layout",
              height == contiguousHeight(surface, width: 460))
        let longReportHeight = ArenaReportTypesetter.height(of: emojiText, width: 460)
        check("on-demand layout keeps a large table's height exact",
              longReportHeight == contiguousHeight(emojiText, width: 460))

        if failures == 0 {
            print("native report surface: all checks passed")
            exit(0)
        }
        print("native report surface: \(failures) failure(s)")
        exit(1)
    }
}
