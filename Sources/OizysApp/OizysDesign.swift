import AppKit
import SwiftUI

// The palette follows the system: semantic colors and materials adapt to Light, Dark,
// Increase Contrast and desktop tinting automatically. Status keeps one color per
// meaning, always paired with text, never color alone.
enum Ink {
    static let ground = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let raised = Color(nsColor: .controlColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let faint = Color(nsColor: .secondaryLabelColor)
    static let live = Color(nsColor: .systemGreen)
    static let warn = Color(nsColor: .systemOrange)

    static let section = Font.caption.weight(.semibold)
    static let label = Font.body
    static let value = Font.body.monospacedDigit()
}

enum Health: Equatable { case live, idle, waiting
    var tint: Color {
        switch self {
        case .live: return Ink.live
        case .idle: return Ink.faint
        case .waiting: return Ink.warn
        }
    }
}

/// Small tracked caps over a hairline, the way the palmier inspector groups its rows.
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased()).font(Ink.section).tracking(1.1).foregroundStyle(Ink.faint)
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(Ink.section).tracking(0.6).foregroundStyle(Ink.faint) }
        }
        .padding(.top, 14).padding(.bottom, 6)
    }
}

/// Label left, value right, one line. The whole panel is built from this.
struct Row<Trailing: View>: View {
    let label: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(Ink.label).foregroundStyle(Ink.primary)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(Ink.faint).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing.font(Ink.value).foregroundStyle(Ink.secondary)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
    }
}

extension Row where Trailing == Text {
    init(_ label: String, _ value: String, detail: String? = nil) {
        self.init(label: label, detail: detail) { Text(value) }
    }
}

struct StatusDot: View {
    let health: Health
    var body: some View {
        Circle().fill(health.tint).frame(width: 6, height: 6)
            .shadow(color: health.tint.opacity(0.7), radius: 3)
            .accessibilityHidden(true)
    }
}

/// A standard button. Native behavior — keyboard focus with a visible ring, press and
/// hover states, VoiceOver naming from the title — takes precedence over custom chrome.
struct QuietButton: View {
    let title: String
    var disabled = false
    var prominent = false
    var defaultAction = false
    var action: () -> Void
    var body: some View {
        Group {
            if prominent {
                Button(title, action: action).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action).buttonStyle(.bordered)
            }
        }
        .controlSize(.small).disabled(disabled)
        .keyboardShortcut(defaultAction ? .defaultAction : nil)
    }
}

/// A choice among a few fixed values. A native segmented picker: Full Keyboard Access,
/// visible focus and VoiceOver value announcements come with the system control.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value
    var label: String = ""

    /// A stored value that is not one of the presets still has to be visible and still has to
    /// read as selected. Dropping it would show a control with nothing chosen while the
    /// setting underneath is set, which is the worst of both.
    private var shown: [(label: String, value: Value)] {
        options.contains { $0.value == selection }
            ? options
            : options + [(label: "\(selection)", value: selection)]
    }

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(shown, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(label.isEmpty ? "Options" : label)
    }
}

/// A dozen resolutions do not fit one row, so this is a pop-up menu: the standard
/// control for choosing one of many values, with keyboard and VoiceOver support.
struct ChipChoice<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value
    var label: String = ""

    /// A stored value that is not one of the presets still has to be visible: a pop-up
    /// showing a blank button while holding a value is a lie about having nothing chosen.
    var shown: [(label: String, value: Value)] {
        if options.contains(where: { $0.value == selection }) { return options }
        return options + [(label: String(describing: selection), value: selection)]
    }

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(shown, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .labelsHidden()
        .accessibilityLabel(label.isEmpty ? "Options" : label)
    }
}

/// A native switch: accent-aware, keyboard-operable with a visible focus ring, and
/// announced by VoiceOver with the row's label. The label lives in the row, so it is
/// passed in for accessibility.
struct QuietSwitch: View {
    @Binding var isOn: Bool
    var disabled = false
    var label: String = ""
    var body: some View {
        Toggle(label.isEmpty ? "On" : label, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(label.isEmpty ? "On" : label)
            .disabled(disabled)
    }
}

// MARK: - Stipple

/// One deterministic stipple field. The logo's dots are not a texture with a seam, so this
/// is generated from a fixed seed rather than tiled: same art every launch, no image file.
struct Stipple {
    struct Dot { let point: CGPoint; let radius: CGFloat; let alpha: CGFloat }

    /// Dots on `rings` concentric arcs, densest at the centre, as in the logo's background.
    static func ripple(rings: Int, perRing: Int, seed: UInt64 = 0x0129) -> [Dot] {
        var state = seed | 1
        func random() -> CGFloat { // xorshift64; a seeded generator keeps the art stable
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return CGFloat(state % 10000) / 10000
        }
        var dots: [Dot] = []
        for ring in 0..<rings {
            let base = CGFloat(ring + 1) / CGFloat(rings)
            let count = max(6, Int(CGFloat(perRing) * base))
            for index in 0..<count {
                let angle = (CGFloat(index) / CGFloat(count)) * .pi * 2 + random() * 0.10
                let jitter = 1 + (random() - 0.5) * 0.07
                dots.append(Dot(point: CGPoint(x: cos(angle) * base * jitter,
                                               y: sin(angle) * base * jitter),
                                radius: 0.7 + random() * 1.1,
                                alpha: (1 - base) * 0.75 + 0.08))
            }
        }
        return dots
    }
}
