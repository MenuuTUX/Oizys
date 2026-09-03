import AppKit
import SwiftUI

// The visual language comes from Assets/Logo.png: white stipple on black, with concentric
// ripples running out behind the subject. Everything here is monochrome by construction,
// so the only colour in the app is a status dot, and it means something.
enum Ink {
    static let ground = Color(red: 0.039, green: 0.039, blue: 0.043)
    static let panel = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let raised = Color(red: 0.098, green: 0.098, blue: 0.11)
    static let hairline = Color.white.opacity(0.08)
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.58)
    static let faint = Color.white.opacity(0.34)
    static let live = Color(red: 0.60, green: 0.85, blue: 0.62)
    static let warn = Color(red: 0.92, green: 0.70, blue: 0.36)

    static let section = Font.system(size: 10, weight: .semibold)
    static let label = Font.system(size: 12, weight: .regular)
    static let value = Font.system(size: 12, weight: .regular).monospacedDigit()
}

enum Health { case live, idle, waiting
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
                    Text(detail).font(.system(size: 10)).foregroundStyle(Ink.faint).lineLimit(2)
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
    }
}

struct QuietButton: View {
    let title: String
    var action: () -> Void
    @State private var over = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.primary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(over ? Ink.raised : Ink.panel))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.hairline))
        }
        .buttonStyle(.plain).onHover { over = $0 }
    }
}

/// A choice among a few fixed values. Replaces the system Picker for the same two reasons
/// as the switch: it carries an accent colour, and it cannot be rendered for review.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    /// A stored value that is not one of the presets still has to be visible and still has to
    /// read as selected. Dropping it would show a control with nothing chosen while the
    /// setting underneath is set, which is the worst of both.
    private var shown: [(label: String, value: Value)] {
        options.contains { $0.value == selection }
            ? options
            : options + [(label: "\(selection)", value: selection)]
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(shown, id: \.value) { option in
                let chosen = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.system(size: 11, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Ink.primary : Ink.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(chosen ? Color.white.opacity(0.14) : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Ink.panel))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Ink.hairline))
    }
}

/// A switch drawn rather than borrowed. The system toggle brings its own accent colour into
/// a strictly monochrome panel, and it is AppKit-backed, so it does not survive being
/// rendered offscreen for review. This is two shapes and reads the same in both themes.
struct QuietSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.white.opacity(0.22) : Color.white.opacity(0.06))
                    .overlay(Capsule().stroke(Ink.hairline))
                Circle()
                    .fill(isOn ? Ink.primary : Ink.faint)
                    .padding(2)
            }
            .frame(width: 30, height: 17)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: isOn)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
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

/// The header art: ripples fading outward, drifting slowly so the panel is never quite still.
struct RippleField: View {
    var intensity: Double = 1
    private let dots = Stipple.ripple(rings: 22, perRing: 54)
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: intensity <= 0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let centre = CGPoint(x: size.width / 2, y: size.height * 0.52)
                let scale = min(size.width, size.height * 2.4) * 0.72
                for dot in dots {
                    let distance = hypot(dot.point.x, dot.point.y)
                    // One slow wave outward, so the field reads as a ripple, not noise.
                    let wave = sin(distance * 9 - time * 1.1) * 0.5 + 0.5
                    let alpha = dot.alpha * (0.35 + wave * 0.65) * intensity
                    guard alpha > 0.02 else { continue }
                    let rect = CGRect(x: centre.x + dot.point.x * scale - dot.radius,
                                      y: centre.y + dot.point.y * scale - dot.radius,
                                      width: dot.radius * 2, height: dot.radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))
                }
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}
