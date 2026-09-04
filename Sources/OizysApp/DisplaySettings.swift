import AppKit
import CoreGraphics
import Foundation
import ObjectiveC

/*
 * The things System Settings > Displays does, done here.
 *
 * Almost all of it is public CoreGraphics and belongs in Swift rather than behind the CLI:
 * a resolution picker that spawns a process and parses its output to fill itself in is the
 * wrong shape for a menu. `oizys monitor` still exists and still does the same work from a
 * terminal; this is the same calls without the round trip.
 *
 * Every write goes through one CGBeginDisplayConfiguration/CGComplete pair, because each
 * commit is a mode set and each mode set blanks the whole desk for a beat. Changing a
 * resolution and its refresh rate together is one blank, not two.
 *
 * What is not here, and why: HDR, Presets, True Tone and the colour profile assignment have
 * no public route, and one of them -- the colour profile -- has an Oizys equivalent already,
 * in the Colour panel. Rotation is shown but not settable: the only route to it is an
 * undocumented IOKit transform on a real framebuffer, which a head driven over the dock does
 * not have. Those four open System Settings instead of pretending.
 */
enum DisplaySettings {
    struct Mode: Identifiable, Hashable {
        let index: Int
        let width: Int, height: Int          // points
        let pixelWidth: Int, pixelHeight: Int
        let refresh: Double

        var id: Int { index }
        /// A mode whose backing store is denser than its point size is a Retina "looks like"
        /// mode, and that is the only sense in which two entries of the same size differ.
        var hiDPI: Bool { pixelWidth > width }
        var label: String {
            "\(width) × \(height)" + (hiDPI ? " (HiDPI)" : "")
        }
        var rate: String { refresh > 0 ? "\(Int(refresh.rounded())) Hz" : "—" }
    }

    static func online() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Every mode macOS will accept for this display, newest-looking first: biggest area,
    /// then highest refresh. The raw list arrives in the driver's order, which is nobody's.
    static func modes(_ display: CGDirectDisplayID) -> [Mode] {
        guard let raw = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] else {
            return []
        }
        var seen = Set<String>()
        var out: [Mode] = []
        for (index, mode) in raw.enumerated() {
            let entry = Mode(index: index, width: mode.width, height: mode.height,
                             pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                             refresh: mode.refreshRate)
            // The list repeats a mode once per pixel encoding it supports. They are the same
            // choice to anyone reading a menu, so the first of each wins.
            let key = "\(entry.width)x\(entry.height)x\(entry.pixelWidth)x\(Int(entry.refresh))"
            if seen.insert(key).inserted { out.append(entry) }
        }
        return out.sorted {
            $0.width * $0.height != $1.width * $1.height
                ? $0.width * $0.height > $1.width * $1.height
                : ($0.hiDPI != $1.hiDPI ? $0.hiDPI : $0.refresh > $1.refresh)
        }
    }

    static func current(_ display: CGDirectDisplayID) -> Mode? {
        guard let now = CGDisplayCopyDisplayMode(display) else { return nil }
        return modes(display).first {
            $0.width == now.width && $0.height == now.height
                && $0.pixelWidth == now.pixelWidth && $0.refresh == now.refreshRate
        }
    }

    /// The refresh rates offered at one point size, which is how the Displays pane splits
    /// them: resolution is one control and refresh rate is another beside it.
    static func rates(_ display: CGDirectDisplayID, like mode: Mode) -> [Mode] {
        modes(display)
            .filter { $0.width == mode.width && $0.height == mode.height && $0.hiDPI == mode.hiDPI }
            .sorted { $0.refresh > $1.refresh }
    }

    @discardableResult
    static func apply(_ display: CGDirectDisplayID, _ mode: Mode) -> Bool {
        guard let raw = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode],
              mode.index < raw.count else { return false }
        return transaction { CGConfigureDisplayWithDisplayMode($0, display, raw[mode.index], nil) }
    }

    static func rotation(_ display: CGDirectDisplayID) -> Int {
        Int(CGDisplayRotation(display).rounded())
    }

    // MARK: - Arrangement

    /*
     * Main display, the CoreGraphics way: the main display is whichever one sits at the
     * origin, so making one main is translating the entire arrangement so that it does.
     * Moving only the chosen display to 0,0 would leave it overlapping whatever was there.
     */
    @discardableResult
    static func makeMain(_ display: CGDirectDisplayID) -> Bool {
        let shift = CGDisplayBounds(display).origin
        guard shift != .zero else { return true }
        return transaction { config in
            for other in online() {
                let bounds = CGDisplayBounds(other)
                let error = CGConfigureDisplayOrigin(config, other,
                                                     Int32(bounds.minX - shift.x),
                                                     Int32(bounds.minY - shift.y))
                if error != .success { return error }
            }
            return .success
        }
    }

    enum Side: String, CaseIterable { case left = "Left", right = "Right", above = "Above", below = "Below" }

    /// Seat a run of displays on one side of an anchor, each touching the next, in one
    /// transaction, in whole pixels: a one-pixel gap or overlap is a seam the pointer catches
    /// on every time it crosses. A run rather than a single display because the two Oizys
    /// heads are a pair and the driver reseats them as a pair, so moving one of them on its
    /// own is a layout the driver undoes a moment later.
    @discardableResult
    static func placeRun(_ displays: [CGDirectDisplayID], _ side: Side,
                         of anchor: CGDirectDisplayID) -> Bool {
        guard let first = displays.first else { return false }
        let target = CGDisplayBounds(anchor)
        let span = displays.reduce(0.0) { $0 + CGDisplayBounds($1).width }
        var point = target.origin
        switch side {
        case .left: point.x = target.minX - span
        case .right: point.x = target.maxX
        case .above: point.y = target.minY - CGDisplayBounds(first).height
        case .below: point.y = target.maxY
        }
        if side == .above || side == .below { point.x = target.midX - span / 2 }
        return transaction { config in
            var x = point.x
            for display in displays {
                let error = CGConfigureDisplayOrigin(config, display, Int32(x), Int32(point.y))
                if error != .success { return error }
                x += CGDisplayBounds(display).width
            }
            return .success
        }
    }

    @discardableResult
    static func mirror(_ display: CGDirectDisplayID, of master: CGDirectDisplayID?) -> Bool {
        transaction {
            CGConfigureDisplayMirrorOfDisplay($0, display, master ?? kCGNullDirectDisplay)
        }
    }

    /// One transaction, one commit, one blank. A staging call that fails cancels rather than
    /// committing half an arrangement.
    private static func transaction(_ stage: (CGDisplayConfigRef) -> CGError) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard stage(config) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    // MARK: - System Settings

    /// For the four things macOS keeps to itself. Naming them is better than a control that
    /// silently does nothing.
    static func openDisplaysSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }
}

/*
 * Night Shift.
 *
 * CoreBrightness is private, so this is resolved at runtime and reports itself unsupported
 * rather than crashing when a macOS release moves it -- the same shape as SidecarBridge, and
 * for the same reason.
 *
 * `getBlueLightStatus:` fills a struct whose layout is not published. Only its first two
 * bytes are read here, which are the active and enabled flags; if that ever moves, the
 * switch shows the wrong position and nothing else breaks, because every write goes through
 * `setEnabled:` and not through the struct.
 */
enum NightShift {
    private static let client: NSObject? = {
        if NSClassFromString("CBBlueLightClient") == nil {
            _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                       RTLD_LAZY)
        }
        guard let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return type.init()
    }()

    static var available: Bool {
        guard let client else { return false }
        return client.responds(to: NSSelectorFromString("setEnabled:"))
            && client.responds(to: NSSelectorFromString("setStrength:commit:"))
    }

    static var enabled: Bool {
        guard let client else { return false }
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: client), selector)
        else { return false }
        var status = [UInt8](repeating: 0, count: 64)
        typealias Ask = @convention(c) (NSObject, Selector, UnsafeMutablePointer<UInt8>) -> Bool
        guard status.withUnsafeMutableBufferPointer({ buffer -> Bool in
            unsafeBitCast(implementation, to: Ask.self)(client, selector, buffer.baseAddress!)
        }) else { return false }
        return status[1] != 0
    }

    /// 0...1. Warmer is higher, exactly as the slider in System Settings reads.
    static var strength: Float {
        guard let client else { return 0 }
        let selector = NSSelectorFromString("getStrength:")
        guard client.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: client), selector)
        else { return 0 }
        var value: Float = 0
        typealias Ask = @convention(c) (NSObject, Selector, UnsafeMutablePointer<Float>) -> Bool
        _ = unsafeBitCast(implementation, to: Ask.self)(client, selector, &value)
        return value
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        guard let client else { return false }
        let selector = NSSelectorFromString("setEnabled:")
        guard client.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: client), selector)
        else { return false }
        typealias Call = @convention(c) (NSObject, Selector, Bool) -> Bool
        return unsafeBitCast(implementation, to: Call.self)(client, selector, on)
    }

    @discardableResult
    static func setStrength(_ value: Float) -> Bool {
        guard let client else { return false }
        let selector = NSSelectorFromString("setStrength:commit:")
        guard client.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: client), selector)
        else { return false }
        typealias Call = @convention(c) (NSObject, Selector, Float, Bool) -> Bool
        return unsafeBitCast(implementation, to: Call.self)(client, selector,
                                                            min(1, max(0, value)), true)
    }
}
