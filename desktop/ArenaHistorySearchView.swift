//
//  ArenaHistorySearchView.swift
//  AI Arena · 本机历史检索面板（G3/G4，R07）
//
//  从主窗口「历史」菜单的“搜索历史…”打开。范围是本机已保存场次的摘要
//  （题面、时间、结果、阶段、席位、暂停标记），在进程内过滤，不读网络、
//  不建索引、不改场次。每个结果区分“只读回看”和“继续这一场…”；两者都
//  回到主窗口既有的打开/继续路径，运行中的场次照样先确认。
//

import SwiftUI

struct ArenaHistorySearchView: View {
    @ObservedObject var model: ArenaModel
    let isRunning: Bool
    let onView: (String) -> Void
    let onResume: (String) -> Void
    let onClose: () -> Void

    @State private var criteria = ArenaHistorySearchCriteria()
    @FocusState private var searchFocused: Bool

    private var items: [ArenaHistorySummary] { model.historyList }

    private var results: [ArenaHistorySummary] {
        ArenaHistorySearch.filter(
            items,
            criteria: criteria,
            seatName: ArenaSeatCatalog.name
        )
    }

    private var outcomeFacets: [ArenaHistoryFacet] {
        ArenaHistorySearch.outcomeFacets(items)
    }

    private var seatFacets: [ArenaHistoryFacet] {
        ArenaHistorySearch.seatFacets(items, seatName: ArenaSeatCatalog.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
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
            model.reloadHistorySummaries()
            searchFocused = true
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("搜索历史场次")
                    .font(.system(size: 15, weight: .semibold))
                Text("按题面、席位或结果查找本机保存的讨论")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("关闭搜索")
            .accessibilityLabel("关闭搜索")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索题面、席位或结果", text: $criteria.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .accessibilityLabel("搜索历史")
                if !criteria.query.isEmpty {
                    Button {
                        criteria.query = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )

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
                    "当前有讨论在运行：打开历史会先确认，并以只读方式回看。",
                    systemImage: "info.circle"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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
        }
        .controlSize(.small)
        .disabled(criteria.isDefault)
        .help("清除搜索与筛选")
    }

    // MARK: 结果

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(items.isEmpty ? "还没有保存的场次" : "没有符合条件的场次")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if !items.isEmpty {
                Text("换一个关键词，或重置状态、结果和席位筛选。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("\(results.count) 场 · 按最近更新排序")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                ForEach(results) { item in
                    resultRow(item)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private func resultRow(_ item: ArenaHistorySummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(dateLabel(item))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                outcomeBadge(item)
                Spacer(minLength: 8)
                Text(stageLabel(item))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Text(item.question.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13))
                .lineLimit(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 8) {
                seatChips(item)
                Spacer(minLength: 8)
                Button {
                    onView(item.id)
                } label: {
                    Label("只读回看", systemImage: "book.closed")
                }
                .controlSize(.small)
                .help("打开已保存的原文与报告；不会打开原页或重发")
                if !item.isFinished {
                    Button {
                        onResume(item.id)
                    } label: {
                        Label("继续这一场…", systemImage: "play.circle")
                    }
                    .controlSize(.small)
                    .help("先确认，再逐席核对原页；可能已发送的任务只做只读核对")
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
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

    private func seatChips(_ item: ArenaHistorySummary) -> some View {
        HStack(spacing: 4) {
            ForEach(item.providers, id: \.self) { provider in
                Text(ArenaSeatCatalog.name(provider))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
            if item.providers.isEmpty {
                Text("席位未记录")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func stageLabel(_ item: ArenaHistorySummary) -> String {
        let stage = ArenaStageNames.label(item.stage)
        guard !item.isFinished, item.round > 1 else { return stage }
        return "\(stage) · 第 \(item.round) 轮"
    }

    private func dateLabel(_ item: ArenaHistorySummary) -> String {
        Self.dateFormatter.string(from: Date(timeIntervalSince1970: item.updatedAt / 1000))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("历史只在本机；回看不会打开原页或发送。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button("完成") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
