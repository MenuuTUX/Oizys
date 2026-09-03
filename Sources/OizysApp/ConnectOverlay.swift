import AppKit
import SwiftUI

/*
 * When a display comes up, Oizys says so on that display and then gets out of the way.
 *
 * The rules this is built to: it never takes focus, never accepts a click, never covers a
 * screen for longer than it takes to read, and never appears twice for one event. A panel
 * that interrupts is worse than no panel, so the window is non-activating, mouse-transparent
 * and self-closing, and there is a switch to turn it off entirely.
 *
 * The art is the logo's own language: rings of white stipple running outward, as in
 * Assets/Logo.png, over the display's name.
 */

private struct ConnectRipple: View {
    let title: String
    let subtitle: String
    let start: Date
    static let duration: Double = 1.7

    private let dots = Stipple.ripple(rings: 18, perRing: 56, seed: 0x51D3)
    /// The scrim's reach. A display's short side is the right scale for it.
    private var geometrySide: CGFloat { 420 }

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            let progress = min(max(elapsed / Self.duration, 0), 1)
            // Out fast, settle slow: the ring is legible before it is gone.
            let eased = 1 - pow(1 - progress, 2.4)
            // Ramp in, hold, ramp out. A single triangular fade peaks for one instant, so
            // the name is never actually at full strength while anyone is reading it.
            let fade = progress < 0.12 ? progress / 0.12
                     : progress < 0.62 ? 1
                     : (1 - progress) / 0.38

            ZStack {
                // A radial scrim, never a full-screen one. White stipple over an unknown
                // desktop is unreadable, and darkening the whole display for a notice is
                // exactly the intrusion this is supposed to avoid. This darkens the middle
                // and reaches nothing near the edges.
                RadialGradient(colors: [.black.opacity(0.62 * fade), .black.opacity(0)],
                               center: .center, startRadius: 0,
                               endRadius: min(geometrySide, 520))
                Canvas { context, size in
                    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                    let reach = min(size.width, size.height) * 0.44
                    for dot in dots {
                        let distance = hypot(dot.point.x, dot.point.y)
                        // Each ring leaves a little after the one inside it.
                        let local = min(max((eased - distance * 0.28) / 0.72, 0), 1)
                        guard local > 0 else { continue }
                        let alpha = dot.alpha * fade * (1 - local * 0.30)
                        guard alpha > 0.015 else { continue }
                        let spread = reach * (0.25 + local * 0.95)
                        let radius = dot.radius * 1.5
                        let rect = CGRect(x: centre.x + dot.point.x * spread - radius,
                                          y: centre.y + dot.point.y * spread - radius,
                                          width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))
                    }
                }
                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 26, weight: .light)).tracking(6)
                        .foregroundStyle(.white.opacity(0.98 * fade))
                    Text(subtitle.uppercased())
                        .font(.system(size: 11, weight: .medium)).tracking(3.6)
                        .foregroundStyle(.white.opacity(0.72 * fade))
                }
                .shadow(color: .black.opacity(0.9 * fade), radius: 12)
                .scaleEffect(0.97 + eased * 0.03)
            }
        }
        .background(.clear)
        .allowsHitTesting(false)
    }
}

/// One frame of the ripple at a chosen point in its run, for rendering and review.
struct ConnectRipplePreview: View {
    var progress: Double
    /// Read from a real display, so a render shows the numbers the overlay would actually
    /// carry rather than a caption someone typed once and never checked again.
    private var described: (String, String) {
        ConnectOverlay.describe(CGMainDisplayID(), kind: nil)
    }
    var body: some View {
        ConnectRipple(title: described.0, subtitle: described.1,
                      start: Date().addingTimeInterval(-ConnectRipple.duration * progress))
    }
}

enum ConnectOverlay {
    /// Off by default is the wrong default for something whose whole job is reassurance, but
    /// it must be one switch away. UserDefaults, not driver config: this is the app's own.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "showConnectOverlay") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showConnectOverlay") }
    }

    /// Live panels, each with the display it belongs to, so they can be re-framed.
    private static var live: [(panel: NSWindow, display: CGDirectDisplayID)] = []
    private static var following: Any?

    /*
     * A ripple is shown exactly when the layout is at its least settled.
     *
     * The panel's frame used to be read once, at the moment the display was announced. But a
     * display arriving is the start of a cascade, not the end of one: the window server
     * re-lays-out every screen, resolutions move to whatever the new set of displays stores,
     * and Oizys puts modes and origins back a beat later. The panel kept the frame it was
     * born with, so the ripple drew off-centre on a screen that was no longer that size, and
     * a borderless screen-saver-level window whose bounds disagree with its screen tears.
     *
     * So the panel follows its screen for the few seconds it is up. The observer exists only
     * while something is on screen.
     */
    private static func followScreenChanges() {
        guard following == nil else { return }
        following = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil,
            queue: .main) { _ in reframe() }
    }

    private static func reframe() {
        for entry in live {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == entry.display
            }) else { continue }
            if entry.panel.frame != screen.frame {
                entry.panel.setFrame(screen.frame, display: true)
            }
        }
    }

    private static func retire(_ panel: NSWindow) {
        panel.orderOut(nil)
        live.removeAll { $0.panel === panel }
        if live.isEmpty, let token = following {
            NotificationCenter.default.removeObserver(token)
            following = nil
        }
    }
    private static var shownRecently: [CGDirectDisplayID: Date] = [:]

    static func show(on display: CGDirectDisplayID, title: String, subtitle: String) {
        guard enabled else { return }
        // A single reconfiguration can report the same display more than once, and a
        // reconnecting dock can report it repeatedly. One ripple per display per few seconds.
        if let last = shownRecently[display], Date().timeIntervalSince(last) < 4 { return }
        shownRecently[display] = Date()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }) else { return }

        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.setFrame(screen.frame, display: false)
        panel.contentView = NSHostingView(rootView:
            ConnectRipple(title: title, subtitle: subtitle, start: Date()))
        // orderFrontRegardless, never makeKey: the user's focus stays where they put it.
        panel.orderFrontRegardless()
        live.append((panel, display))
        followScreenChanges()

        DispatchQueue.main.asyncAfter(deadline: .now() + ConnectRipple.duration + 0.1) {
            retire(panel)
        }
    }

    /// What a display says about itself, read from CoreGraphics at the moment of drawing.
    /// The overlay lands on one specific panel, so it has to describe that panel: its own
    /// pixel size and its own refresh rate, not the set's or the caller's idea of them.
    static func describe(_ id: CGDirectDisplayID, kind: OizysDisplay.Kind?) -> (String, String) {
        let mode = CGDisplayCopyDisplayMode(id)
        let bounds = CGDisplayBounds(id)
        let width = mode.map { $0.pixelWidth } ?? Int(bounds.width)
        let height = mode.map { $0.pixelHeight } ?? Int(bounds.height)
        let refresh = mode?.refreshRate ?? 0

        var facts = ["\(width)×\(height)"]
        // A refresh of zero is what macOS reports for a panel whose rate it does not model,
        // which is most virtual displays. Printing "0 Hz" there would be a lie about the
        // panel rather than an admission about the API.
        if refresh > 0 { facts.append("\(String(format: "%.0f", refresh)) Hz") }
        if CGDisplayIsInMirrorSet(id) != 0 { facts.append("mirrored") }
        if CGDisplayIsMain(id) != 0 { facts.append("main") }

        let resolved = kind ?? {
            if CGDisplayIsBuiltin(id) != 0 { return .builtin }
            if CGDisplayVendorNumber(id) == 0x4d56 { return .head }
            if CGDisplayVendorNumber(id) == 0x6161706c { return .sidecar }
            return .external
        }()
        let prefix: String
        switch resolved {
        case .head: prefix = "Oizys"
        case .sidecar: prefix = "Sidecar"
        case .builtin: prefix = "Built-in"
        case .external: prefix = "External"
        }
        return (nameFor(id, resolved), ([prefix] + facts).joined(separator: " · "))
    }

    private static func nameFor(_ id: CGDirectDisplayID, _ kind: OizysDisplay.Kind) -> String {
        switch kind {
        case .head: return "Oizys head \(id % 100)"
        case .builtin: return "Built-in display"
        case .sidecar: return "iPad (Sidecar)"
        case .external: return "External display"
        }
    }

    /// Announce every display that just came online, each one describing itself.
    static func announce(_ added: Set<CGDirectDisplayID>, model: OizysModel) {
        for id in added {
            let kind = model.displays.first(where: { $0.id == id })?.kind
            // The built-in panel is announced too when it genuinely came back -- waking from
            // clamshell, or a GPU switch. It is in `added` only when it actually appeared.
            let (title, subtitle) = describe(id, kind: kind)
            show(on: id, title: title, subtitle: subtitle)
        }
    }

    /// Draw one ripple on every attached display at once, so the switch can be tried without
    /// unplugging anything and each panel shows its own numbers.
    static func preview(model: OizysModel) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success, count > 0 else {
            let (title, subtitle) = describe(CGMainDisplayID(), kind: nil)
            shownRecently[CGMainDisplayID()] = nil
            show(on: CGMainDisplayID(), title: title, subtitle: subtitle)
            return
        }
        for id in ids.prefix(Int(count)) {
            shownRecently[id] = nil
            let kind = model.displays.first(where: { $0.id == id })?.kind
            let (title, subtitle) = describe(id, kind: kind)
            show(on: id, title: title, subtitle: subtitle)
        }
    }
}
