//
//  ArenaMotion.swift
//  AI Arena desktop · 统一交互动效（G4，R06/R07）
//
//  One small vocabulary for feedback that must never get in the way of
//  reading:
//
//    * `quick`  — press feedback, disclosure arrows, the transient toast;
//    * `change` — local state changes such as scrolling a section into view
//                 or fading a deliberate highlight.
//
//  Both return `nil` when the system asks to reduce motion, so callers never
//  keep a second branch of their own. Long report bodies never animate their
//  height: only the chevron, the pressed tint and a colour/value change use
//  these values. Every press state below is derived from `isPressed`, so a
//  gesture can be interrupted mid-flight without leaving a stuck state.
//

import SwiftUI

enum ArenaMotion {
    static let quickDuration: Double = 0.14
    static let changeDuration: Double = 0.2

    /// Press feedback and tiny geometry changes. Reduce Motion resolves to
    /// `nil`, which makes the same call site switch instantly.
    static func quick(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: quickDuration)
    }

    /// Slightly larger state changes: scrolling a section into view, fading a
    /// deliberate highlight. Deliberately still short enough to feel direct.
    static func change(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: changeDuration)
    }
}

/// Pressed state for plain, row-sized controls. The tint follows `isPressed`
/// directly (no `@State`), so releasing or dragging out reverses from wherever
/// the gesture is. It only paints a background while pressed, which keeps long
/// lists cheap, and it never animates layout.
struct ArenaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ArenaPressBody(configuration: configuration)
    }

    private struct ArenaPressBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background {
                    if configuration.isPressed {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    }
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
                .animation(ArenaMotion.quick(reduceMotion), value: configuration.isPressed)
        }
    }
}

/// The single chevron used by report disclosures. It rotates in place instead
/// of swapping glyphs, so expansion stays interruptible, the label never
/// reflows and the arrow always points the same way as the accessibility
/// state. Reduce Motion switches instantly.
struct ArenaDisclosureChevron: View {
    let isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(ArenaMotion.quick(reduceMotion), value: isExpanded)
            .accessibilityHidden(true)
    }
}
