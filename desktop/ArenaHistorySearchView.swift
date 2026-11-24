//
//  ArenaHistorySearchView.swift
//  AI Arena · 本机历史检索面板（G3/G4，R07）
//
//  从主窗口「历史」按钮或 View 菜单的「历史…」（⌘⇧F）打开。范围是应用
//  已装入的本机场次摘要（题面、时间、结果、阶段、席位、暂停标记），在进程
//  内过滤，不读网络、不建索引、不改场次；打开面板不重扫磁盘，只有显式刷新
//  才重新读取。每个结果区分“只读回看”和“继续这一场…”；两者都回到主窗口
//  既有的打开/继续路径，运行中的场次照样先确认。
//
//  键盘路径像命令面板：打开时聚焦搜索，↑↓ 移动可见的当前选择，Return 只读
//  回看，Esc 关闭。选择状态只来自 ArenaHistorySelection 的纯规则：查询或
//  筛选变化时回到首行并滚入视口。按键只在搜索框自己的编辑器中处理，没有
//  全局事件监听，也没有改写其他控件的键；中文输入法有标记文字时交还输入法。
//  鼠标可点选、点按钮，辅助功能走原生文本和按钮。
//

import AppKit
import SwiftUI

struct ArenaHistorySearchView: View {
    @ObservedObject var model: ArenaModel
    let isRunning: Bool
    let onView: (String) -> Void
    let onResume: (String) -> Void
    let onClose: () -> Void

    @State private var criteria = ArenaHistorySearchCriteria()
    @State private var selection = ArenaHistorySelection()
    @State private var focusToken = 0
    @State private var scrollRequest = 0
    @State private var hoveredID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [ArenaHistorySummary] { model.historyList }

    private var results: [ArenaHistorySummary] {
        ArenaHistorySearch.filter(
            items,
            criteria: criteria,
            seatName: ArenaSeatCatalog.name
        )
    }

    private var resultIDs: [String] { results.map(\.id) }

    private var outcomeFacets: [ArenaHistoryFacet] {
        ArenaHistorySearch.outcomeFacets(items)
    }

    private var seatFacets: [ArenaHistoryFacet] {
        ArenaHistorySearch.seatFacets(items, seatName: ArenaSeatCatalog.name)
    }

    /// 分组标题跟着用户动作走：检索、筛选或默认的最近场次。
    private var groupTitle: String {
        if !criteria.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "搜索结果"
        }
        if criteria.state != .all || criteria.outcome != nil || criteria.seat != nil {
            return "筛选结果"
        }
        return "最近历史"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            controls
            Divider()
            if results.isEmpty {
                emptyState
            } else {
                resultList
            }
            Divider()
            footer
        }
        .frame(width: 640)
        .frame(minHeight: 420, maxHeight: 620)
        .onAppear {
            focusToken += 1
            selection.selectFirst(in: resultIDs)
        }
        .onChange(of: criteria) { _ in
            selection.selectFirst(in: resultIDs)
            scrollRequest += 1
        }
        .onChange(of: resultIDs) { _ in
            selection.reconcile(with: resultIDs)
            scrollRequest += 1
        }
    }

    // MARK: 键盘
    //
    // 只有搜索框自己的编辑器会转交这些命令。Return 在空结果或选择失效时
    // 不做事；面板其余按钮保持各自的默认键行为。

    private func move(_ direction: ArenaHistoryMove) {
        selection.move(direction, in: resultIDs)
        scrollRequest += 1
    }

    private func reviewSelected() {
        guard let id = selection.id, resultIDs.contains(id) else { return }
        onView(id)
    }

    // MARK: 顶部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("历史")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            Button {
                model.reloadHistorySummaries()
                scrollRequest += 1
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("重新读取本机场次（外部改动后使用）")
            .accessibilityLabel("刷新历史列表")
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("关闭历史（Esc）")
            .accessibilityLabel("关闭历史")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArenaHistorySearchField(
                text: $criteria.query,
                placeholder: "搜索题面、席位或结果",
                focusToken: focusToken,
                onMove: move,
                onSubmit: reviewSelected,
                onCancel: onClose
            )
            .frame(height: 24)
            .accessibilityLabel("搜索历史")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    statePicker
                    outcomePicker
                    seatPicker
                    Spacer(minLength: 0)
                    resetButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        statePicker
                        outcomePicker
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 10) {
                        seatPicker
                        Spacer(minLength: 0)
                        resetButton
                    }
                }
            }

            if isRunning {
                Label(
                    "有讨论在运行：打开前会确认，回看是只读的。",
                    systemImage: "info.circle"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var statePicker: some View {
        Picker("状态", selection: $criteria.state) {
            ForEach(ArenaHistoryStateFilter.allCases) { state in
                Text(state.label).tag(state)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    private var outcomePicker: some View {
        Picker("结果", selection: $criteria.outcome) {
            Text("全部结果").tag(String?.none)
            ForEach(outcomeFacets) { facet in
                Text(facet.label).tag(String?.some(facet.key))
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    private var seatPicker: some View {
        Picker("席位", selection: $criteria.seat) {
            Text("全部席位").tag(String?.none)
            ForEach(seatFacets) { facet in
                Text(facet.label).tag(String?.some(facet.key))
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    private var resetButton: some View {
        Button("重置") {
            criteria = ArenaHistorySearchCriteria()
            focusToken += 1
        }
        .controlSize(.small)
        .disabled(criteria.isDefault)
        .help("清除搜索与筛选")
    }

    // MARK: 结果

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: items.isEmpty ? "clock" : "magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(items.isEmpty ? "还没有保存的场次" : "没有符合条件的场次")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if !items.isEmpty {
                Text("换个关键词，或重置筛选。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(groupTitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text("\(results.count) 场")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 4)

                    ForEach(results) { item in
                        resultRow(item).id(item.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: scrollRequest) { _ in
                guard let id = selection.id else { return }
                if reduceMotion {
                    proxy.scrollTo(id)
                } else {
                    withAnimation(ArenaMotion.quick(reduceMotion)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func resultRow(_ item: ArenaHistorySummary) -> some View {
        let selected = selection.id == item.id
        let hovered = hoveredID == item.id
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.question.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 13.5, weight: selected ? .medium : .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    outcomeBadge(item)
                    Text(dateLabel(item))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let stage = stageLabel(item) {
                        Text(stage)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(seatLine(item))
                        .font(.system(size: 10.5))
                        .foregroundStyle(item.providers.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    onView(item.id)
                } label: {
                    Label("只读回看", systemImage: "book.closed")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("打开已保存的原文与报告；不会打开原页或重发")
                if !item.isFinished {
                    Button {
                        onResume(item.id)
                    } label: {
                        Label("继续这一场…", systemImage: "play.circle")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("先确认，再逐席核对原页；可能已发送的任务只做只读核对")
                }
            }
            .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    selected
                        ? Color.accentColor.opacity(0.14)
                        : (hovered ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .overlay(alignment: .leading) {
            if selected {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 7)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selection = ArenaHistorySelection(id: item.id)
        }
        .onHover { hovering in
            if hovering {
                hoveredID = item.id
            } else if hoveredID == item.id {
                hoveredID = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func outcomeBadge(_ item: ArenaHistorySummary) -> some View {
        Text(ArenaHistoryOutcome.label(for: item))
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    item.isFinished
                        ? Color.primary.opacity(0.07)
                        : Color.orange.opacity(0.14)
                )
            )
            .foregroundStyle(item.isFinished ? Color.secondary : Color.orange)
    }

    /// 未完成行总显示所在阶段；进入第二轮后补上轮次。已结束行由结果徽标
    /// 说明结论，不再重复“结束”。
    private func stageLabel(_ item: ArenaHistorySummary) -> String? {
        guard !item.isFinished else { return nil }
        let stage = ArenaStageNames.label(item.stage)
        guard item.round > 1 else { return stage }
        return "\(stage) · 第 \(item.round) 轮"
    }

    private func seatLine(_ item: ArenaHistorySummary) -> String {
        let names = item.providers.map(ArenaSeatCatalog.name)
        return names.isEmpty ? "席位未记录" : names.joined(separator: " · ")
    }

    private func dateLabel(_ item: ArenaHistorySummary) -> String {
        Self.dateFormatter.string(from: Date(timeIntervalSince1970: item.updatedAt / 1000))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("↑↓ 选择 · Return 只读回看 · Esc 关闭")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

// MARK: - Native search field

/// `NSSearchField` 自带放大镜、清除按钮和中文输入法支持。↑↓、Return、Esc
/// 只在它的 field editor 里转交给面板，标记文字期间一律交还输入法。
private struct ArenaHistorySearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusToken: Int
    let onMove: (ArenaHistoryMove) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13)
        field.controlSize = .regular
        field.focusRingType = .default
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchAction(_:))
        field.setAccessibilityLabel("搜索历史")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        context.coordinator.requestFocus()
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            context.coordinator.requestFocus()
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ArenaHistorySearchField
        weak var field: NSSearchField?
        var focusToken = -1

        init(_ parent: ArenaHistorySearchField) {
            self.parent = parent
        }

        func requestFocus() {
            // The sheet is still attaching its window when the field is made.
            // Retry briefly so the panel really opens with the caret in search.
            focusNow()
            for delay in [0.05, 0.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.focusNow()
                }
            }
        }

        private func focusNow() {
            guard let field, let window = field.window else { return }
            if let editor = field.currentEditor(), window.firstResponder === editor { return }
            window.makeFirstResponder(field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func searchAction(_ sender: Any?) {
            guard let field = sender as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // 输入法正在组合（拼音标记）时不抢方向键和 Return。
            if textView.hasMarkedText() { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(.up)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(.down)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
