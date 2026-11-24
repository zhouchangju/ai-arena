//
//  ArenaSourceButton.swift
//  AI Arena · 已保存来源的原生入口（G2/G3/G4，R03/R07）
//
//  互评材料行和报告作者入口共用一个真正的 AppKit borderless link 按钮：
//  它就是该行唯一的可交互控件，没有隐形代理。按钮可被显式设为所在窗口的
//  first responder，并本地处理 Space / Return，避免依赖系统键盘导航设置。
//  只有 focusRequest 从旧值增长（用户刚从这条来源返回）时才延后设置焦点，
//  不 makeKey、不 activate，也不在初次挂载或无关更新时抢焦点。
//

import AppKit
import SwiftUI

/// Shared native button behaviour for real toolbar/link controls: it always
/// accepts first responder and activates locally once for Space or Return.
/// Only this control handles its own key events; no global event monitor.
final class ArenaKeyboardActionButton: NSButton {
    override var acceptsFirstResponder: Bool { true }

    /// Only a plain Space/Return on an enabled button is claimed locally, so
    /// shortcuts that carry modifiers still reach the system and the rest of
    /// the window. Space still activates once (key up is swallowed).
    private func claims(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        let modifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        guard event.modifierFlags.intersection(modifiers).isEmpty else { return false }
        switch event.keyCode {
        case 49, 36, 76: // Space, Return, keypad Enter
            return true
        default:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        guard claims(event) else {
            super.keyDown(with: event)
            return
        }
        performClick(nil)
    }

    override func keyUp(with event: NSEvent) {
        guard claims(event) else {
            super.keyUp(with: event)
            return
        }
    }
}

/// One real source-entry button. `focusRequest` starts at 0; a later increase
/// means the reader just returned to this exact entry, so the button becomes
/// its window's first responder. `updateNSView` records the request and defers
/// the responder change to a later main-loop turn, after the covering reader is
/// gone and the row is enabled again.
struct ArenaSourceButton: NSViewRepresentable {
    let title: String
    let identifier: String
    let focusRequest: Int
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = ArenaKeyboardActionButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.openSource)
        button.isBordered = false
        button.focusRingType = .exterior
        button.controlSize = .regular
        button.alignment = .left
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A freshly mounted row never steals focus, even if it is created while
        // its request is already non-zero (for example a remount).
        context.coordinator.lastFocusRequest = focusRequest
        apply(title: title, identifier: identifier, to: button)
        button.isEnabled = context.environment.isEnabled
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        apply(title: title, identifier: identifier, to: button)
        // Mirror SwiftUI's disabled state so a covered row cannot respond to
        // the keyboard while the source reader is on top of it.
        button.isEnabled = context.environment.isEnabled
        let previous = context.coordinator.lastFocusRequest
        context.coordinator.lastFocusRequest = focusRequest
        guard focusRequest > previous else { return }
        context.coordinator.focus(button, attempt: 0)
    }

    /// Keeps the link text left aligned while the whole row stays clickable and
    /// tall enough to sit comfortably among the surrounding material rows.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(
            width: proposal.width ?? intrinsic.width,
            height: max(intrinsic.height, 24)
        )
    }

    private func apply(title: String, identifier: String, to button: NSButton) {
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp("打开这条材料的已保存原文")
        button.toolTip = title
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 8
        paragraph.headIndent = 8
        paragraph.tailIndent = -8
        paragraph.lineBreakMode = .byTruncatingTail
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.linkColor,
                .paragraphStyle: paragraph
            ]
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        var lastFocusRequest = 0

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func openSource() {
            action()
        }

        /// Never activates or keys the window. It only retries briefly while
        /// the covering reader is still going away or the row is still
        /// disabled, so the deferred responder change lands on a live control.
        func focus(_ button: NSButton, attempt: Int) {
            DispatchQueue.main.async {
                guard let window = button.window,
                      window.attachedSheet == nil,
                      button.isEnabled,
                      !button.isHiddenOrHasHiddenAncestor,
                      !button.visibleRect.isEmpty else {
                    guard attempt < 2 else { return }
                    self.focus(button, attempt: attempt + 1)
                    return
                }
                window.makeFirstResponder(button)
            }
        }
    }
}
