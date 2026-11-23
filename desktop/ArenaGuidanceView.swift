//
//  ArenaGuidanceView.swift
//  AI Arena · 讨论中补充条件的编辑与已保存条件展示（G1/G2/G4，R03/R06）
//
//  入口只在独立作答或互评阶段出现。点开时先走与「暂停」按钮相同的暂停
//  路径，再打开这个弹窗；弹窗里明确写出条件会进入哪些之后新建的提示，
//  保存成功后继续保持暂停，需要用户自己点「继续」。保存失败时草稿留在
//  输入框里，不关闭弹窗。
//

import SwiftUI

struct ArenaGuidanceComposer: View {
    @ObservedObject var model: ArenaModel
    let target: ArenaGuidanceTarget
    let onClose: () -> Void

    @State private var draft: String = ""
    @State private var status: String?
    @State private var statusIsError = false
    @FocusState private var editorFocused: Bool

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// JavaScript's `MAX_GUIDANCE` counts UTF-16 code units; count the same way
    /// so the UI limit matches what the shared engine will enforce.
    private var draftLength: Int {
        draft.utf16.count
    }

    private var overLimit: Bool {
        draftLength > ArenaGuidanceRules.maxTextLength
    }

    private var phaseMatches: Bool {
        model.guidancePhaseMatches(target)
    }

    private var canSave: Bool {
        phaseMatches && !trimmedDraft.isEmpty && !overLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    effectNotice
                    ArenaSavedConditionsCard(notes: model.savedGuidance)
                    editor
                    if let status {
                        Label(status, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(statusIsError ? Color.orange : Color.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 540)
        .frame(minHeight: 380, maxHeight: 620)
        .onAppear { editorFocused = true }
        .onChange(of: phaseMatches) { matches in
            if !matches {
                statusIsError = true
                status = "讨论阶段或暂停状态已变化，条件不再可保存；请关闭后重新打开。"
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("补充讨论条件")
                    .font(.system(size: 15, weight: .semibold))
                Text("当前已暂停 · 保存后仍保持暂停")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var effectNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("只写入保存之后新建的提示", systemImage: "arrow.turn.down.right")
                .font(.system(size: 12.5, weight: .semibold))
            Text("新的独立作答、互评或候选提示会带上这条条件。已经发出、待处理或已归档的任务及其表态不会被改写，也不会重发；继续讨论需要你手动点「继续」。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("条件")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("例如：预算最多两周；如果没有真实数据，请明确标出待核实。")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $draft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .focused($editorFocused)
                    .frame(minHeight: 96)
                    .accessibilityLabel("补充条件")
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            HStack(spacing: 6) {
                if overLimit {
                    Text("已超过 \(ArenaGuidanceRules.maxTextLength) 个字符上限，保存已停用")
                        .foregroundStyle(Color.orange)
                }
                Spacer(minLength: 0)
                Text("\(draftLength) / \(ArenaGuidanceRules.maxTextLength)")
                    .foregroundStyle(overLimit ? Color.orange : Color.secondary)
            }
            .font(.system(size: 11))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !phaseMatches {
                Text("阶段已变化")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
            }
            Spacer(minLength: 8)
            Button("关闭") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("保存条件") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func save() {
        switch model.saveGuidance(draft, target: target) {
        case let .saved(note):
            draft = ""
            statusIsError = false
            status = "已保存条件 #\(note.seq)；讨论仍保持暂停。"
            editorFocused = true
        case let .rejected(message):
            statusIsError = true
            status = message
            editorFocused = true
        }
    }
}

/// Read-only list of the conditions saved in this session, including where
/// each one has been delivered so far. Used inside the composer and on the
/// details「当前提示」tab, where a reader can check what the seats were told.
struct ArenaSavedConditionsCard: View {
    let notes: [ArenaGuidanceNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(notes.isEmpty ? "本场还没有补充条件" : "已保存的条件（\(notes.count)）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if notes.isEmpty {
                Text("补充条件只在暂停时记录，并只进入之后新建的提示。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("#\(note.seq) · \(note.originLabel)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(note.text)
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(note.deliveryLabel)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}
