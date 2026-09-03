import AppKit
import CoreGraphics
import IOKit
import SwiftUI

// The app has no bridging header by design: Swift is the glue, C owns the driver. So every
// driver question here is asked by running the bundled `OizysDriver` CLI and reading its
// output, exactly as the terminal does. Display enumeration is the one exception -- it goes
// straight to CoreGraphics, because the menu has to redraw the instant a cable moves.

struct OizysDisplay: Identifiable, Equatable {
    enum Kind: String { case head = "Oizys head", builtin = "Built-in", sidecar = "Sidecar", external = "External" }
    let id: CGDirectDisplayID
    let kind: Kind
    let width: Int
    let height: Int
    let refresh: Double
    let origin: CGPoint
    let main: Bool
    let mirrored: Bool
    let serial: UInt32

    var name: String {
        switch kind {
        case .head: return "Oizys head \(id % 100)"
        case .builtin: return "Built-in display"
        case .sidecar: return "iPad (Sidecar)"
        case .external: return "External display"
        }
    }
    var geometry: String {
        refresh > 0 ? "\(width)×\(height) · \(String(format: "%.0f", refresh)) Hz" : "\(width)×\(height)"
    }

    /// 0 for the left head, 1 for the right, nil for anything Oizys does not drive. The
    /// serials are assigned in main.c when the virtual displays are created.
    var head: Int? {
        guard kind == .head else { return nil }
        switch serial {
        case 0x4d560001: return 0
        case 0x4d560002: return 1
        default: return nil
        }
    }
}

struct PortRow: Identifiable {
    let id = UUID()
    let text: String
    let warning: Bool
}

struct Setting: Identifiable {
    let id: String
    var value: String
    let fallback: String
    var changed: Bool { value != fallback }
}

final class OizysModel: ObservableObject {
    @Published private(set) var displays: [OizysDisplay] = []
    @Published private(set) var running = false
    @Published private(set) var loginEnabled = false
    @Published private(set) var dockPresent = false
    @Published private(set) var settings: [Setting] = []
    @Published private(set) var ports: [PortRow] = []
    @Published private(set) var displaySleepMinutes = 0
    @Published private(set) var brightness: [CGDirectDisplayID: Double] = [:]
    @Published private(set) var brightnessMaximum: [CGDirectDisplayID: Double] = [:]
    @Published var lastMessage = ""
    /// Set only by preview(). Suppresses the refresh that would replace the
    /// representative state with whatever this machine happens to be doing.
    private(set) var isPreview = false

    var health: Health {
        if !dockPresent { return .waiting }
        if running { return displays.contains { $0.kind == .head } ? .live : .waiting }
        return .idle
    }
    var summary: String {
        if !dockPresent { return "No dock connected" }
        if !running { return "Stopped" }
        let heads = displays.filter { $0.kind == .head }.count
        return heads > 0 ? "Driving \(heads) display\(heads == 1 ? "" : "s")" : "Starting…"
    }

    private var driver: URL? { Bundle.main.url(forAuxiliaryExecutable: "OizysDriver") }

    // MARK: - Driver CLI

    @discardableResult
    private func cli(_ arguments: [String], timeout: TimeInterval = 8) -> String {
        guard let driver else { return "" }
        let process = Process(), pipe = Pipe()
        process.executableURL = driver
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "" }
        // A driver that wedges must never wedge the menu with it. readDataToEndOfFile only
        // returns when the child closes the pipe, so the bound has to be a watchdog that
        // terminates the child -- that is what closes the pipe and releases the read.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    func run(_ arguments: [String]) {
        let output = cli(arguments)
        lastMessage = output.split(separator: "\n").last.map(String.init) ?? ""
        refresh()
    }

    // MARK: - Refresh

    func refresh() {
        guard !isPreview else { return }
        readDisplays()
        applySidecarTint()
        dockPresent = Self.dockAttached()
        running = OizysLifecycle.supervisor() != nil
        loginEnabled = OizysLifecycle.agentLoaded
        displaySleepMinutes = Self.readDisplaySleep()
    }

    func refreshSlowly() {
        guard !isPreview else { return }
        readSettings()
        readPorts()
    }

    private func readDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { displays = []; return }
        displays = ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let bounds = CGDisplayBounds(id)
            let kind: OizysDisplay.Kind
            if CGDisplayIsBuiltin(id) != 0 { kind = .builtin }
            else if CGDisplayVendorNumber(id) == 0x4d56 { kind = .head }
            else if Self.isSidecar(id) { kind = .sidecar }
            else { kind = .external }
            return OizysDisplay(id: id, kind: kind,
                                width: mode.map { $0.pixelWidth } ?? Int(bounds.width),
                                height: mode.map { $0.pixelHeight } ?? Int(bounds.height),
                                refresh: mode?.refreshRate ?? 0, origin: bounds.origin,
                                main: CGDisplayIsMain(id) != 0,
                                mirrored: CGDisplayIsInMirrorSet(id) != 0,
                                serial: CGDisplaySerialNumber(id))
        }
    }

    /// Apple's own virtual panels -- a Sidecar iPad and an AirPlay receiver -- share this
    /// vendor. The driver's C side makes the same call; see oizys_display_is_sidecar.
    private static func isSidecar(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x6161706c && CGDisplayIsBuiltin(id) == 0
    }

    private static func dockAttached() -> Bool { OizysLifecycle.dockCount() > 0 }

    // MARK: - Permission and paths

    /// This process's own Screen Recording grant. The driver is a separate executable with a
    /// separate grant, which is why the service log is worth pointing at as well.
    var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// The only place in the app that asks. Everything else reports and waits.
    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Where the login agent's refusals land, as written by Tools/install_app.py.
    var serviceLogPath: String {
        NSHomeDirectory() + "/Library/Application Support/Oizys/logs/service.log"
    }

    /// oizys_config_print writes the file's path as its first line.
    private(set) var configPath = ""

    private func readSettings() {
        // oizys_config_print writes the file path, a blank line, then one indented
        // "key value" per field, with "(default x)" appended only where they differ.
        // The value is everything after the key rather than the next word: a device name is
        // free text and "shib\'s iPad Pro" is one value, not three.
        let listing = cli(["config", "list"])
        configPath = listing.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        settings = listing.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("  ") else { return nil }
            let body = line.drop { $0 == " " }
            guard let gap = body.firstIndex(of: " ") else { return nil }
            let key = String(body[..<gap])
            var value = String(body[gap...]).trimmingCharacters(in: .whitespaces)
            var fallback = value
            if let marker = value.range(of: "(default ") {
                fallback = String(value[marker.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                value = String(value[..<marker.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return key.isEmpty ? nil : Setting(id: key, value: value, fallback: fallback)
        }
    }

    private func readPorts() {
        ports = cli(["ports"]).split(separator: "\n").map {
            PortRow(text: String($0), warning: $0.trimmingCharacters(in: .whitespaces).hasPrefix("!"))
        }
    }

    func set(_ key: String, _ value: String) {
        run(["config", "set", key, value])
        readSettings()
    }

    // MARK: - Display sleep

    /// macOS has one display-sleep timer for every screen; there is no per-monitor setting
    /// to expose. A panel that sleeps sooner than this is sleeping on its own clock, which
    /// is what display.keepalive_s is for.
    private static func readDisplaySleep() -> Int {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "live"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let line = text.split(separator: "\n").first(where: { $0.contains("displaysleep") }),
              let value = line.split(separator: " ").compactMap({ Int($0) }).first else { return 0 }
        return value
    }

    /// Changing this needs an administrator, so it opens the pane rather than failing
    /// silently at a password prompt no menu-bar app should be showing.
    func openDisplaySleepSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!)
    }

    // MARK: - Per-head power

    func headSetting(_ head: Int, _ leaf: String, _ fallback: String) -> String {
        let key = "head.\(head == 0 ? "left" : "right").\(leaf)"
        return settings.first { $0.id == key }?.value ?? fallback
    }

    func setHeadSetting(_ head: Int, _ leaf: String, _ value: String) {
        let key = "head.\(head == 0 ? "left" : "right").\(leaf)"
        if let index = settings.firstIndex(where: { $0.id == key }) {
            settings[index].value = value          // move the control now, write behind it
        }
        _ = cli(["config", "set", key, value], timeout: 4)
    }

    func setting(_ key: String, _ fallback: String) -> String {
        settings.first { $0.id == key }?.value ?? fallback
    }

    /// Re-read the config file. Cheap, but it spawns the CLI, so it is for after a write or
    /// a window opening rather than for a tick.
    func reloadSettings() { readSettings() }

    /// The sidecar.* keys, in the shape the auto-connect watcher asks for them.
    var sidecarSettings: SidecarAuto.Settings {
        SidecarAuto.Settings(enabled: setting("sidecar.auto_connect", "false") == "true",
                             requireDesk: setting("sidecar.require_desk", "true") == "true",
                             device: setting("sidecar.device", ""))
    }

    // MARK: - Head brightness

    /// Oizys owns every pixel on a head, so brightness for one is a gain in the encoder and
    /// not a DDC write. It reaches the panel because it changes what is sent to it.
    func headBrightness(_ head: Int) -> Double {
        let key = head == 0 ? "head.left.brightness" : "head.right.brightness"
        return Double(settings.first { $0.id == key }?.value ?? "100") ?? 100
    }

    func setHeadBrightness(_ head: Int, _ percent: Double) {
        let key = head == 0 ? "head.left.brightness" : "head.right.brightness"
        let clamped = Int(min(100, max(10, percent.rounded())))
        if let index = settings.firstIndex(where: { $0.id == key }) {
            settings[index].value = String(clamped) // move the slider now, write behind it
        }
        _ = cli(["config", "set", key, String(clamped)], timeout: 4)
    }

    // MARK: - Sidecar tint

    /// The iPad's brightness and contrast, as a gamma ramp. Re-applied whenever the settings
    /// or the displays change, because a Sidecar display that detaches and comes back is a
    /// new display id carrying none of our ramp.
    func applySidecarTint() {
        guard let sidecar = displays.first(where: { $0.kind == .sidecar }) else { return }
        DisplayTint.apply(sidecar.id,
                          brightness: Int(setting("sidecar.brightness", "100")) ?? 100,
                          contrast: Int(setting("sidecar.contrast", "100")) ?? 100)
    }

    func sidecarTint(_ leaf: String) -> Double {
        Double(setting("sidecar.\(leaf)", "100")) ?? 100
    }

    func setSidecarTint(_ leaf: String, _ percent: Double) {
        let key = "sidecar.\(leaf)"
        let limits = leaf == "brightness" ? (10.0, 100.0) : (50.0, 150.0)
        let clamped = Int(min(limits.1, max(limits.0, percent.rounded())))
        if let index = settings.firstIndex(where: { $0.id == key }) {
            settings[index].value = String(clamped)
        }
        _ = cli(["config", "set", key, String(clamped)], timeout: 4)
        applySidecarTint()
    }

    /// Contrast runs either side of unity, because it pivots on mid-grey rather than scaling
    /// from black. 100 is the panel as sent; above it, highlights clip.
    func headContrast(_ head: Int) -> Double {
        let key = head == 0 ? "head.left.contrast" : "head.right.contrast"
        return Double(settings.first { $0.id == key }?.value ?? "100") ?? 100
    }

    func setHeadContrast(_ head: Int, _ percent: Double) {
        let key = head == 0 ? "head.left.contrast" : "head.right.contrast"
        let clamped = Int(min(150, max(50, percent.rounded())))
        if let index = settings.firstIndex(where: { $0.id == key }) {
            settings[index].value = String(clamped)
        }
        _ = cli(["config", "set", key, String(clamped)], timeout: 4)
    }

    // MARK: - DDC

    /// Brightness over DDC/CI reaches a monitor on a real display pipe only. A head driven
    /// over the dock has no I2C path, so this is absent for those by design, not broken.
    func readBrightness(_ id: CGDirectDisplayID) {
        let output = cli(["ddc", "get", "0x10", "--display", String(id)], timeout: 4)
        guard let line = output.split(separator: "\n").first(where: { $0.contains(" = ") }),
              let equals = line.range(of: " = ") else { brightness[id] = nil; return }
        let tail = line[equals.upperBound...]
        let numbers = tail.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
        guard let current = numbers.first else { brightness[id] = nil; return }
        brightness[id] = current
        // A monitor reports the maximum its own scale uses, and it is not always 100.
        brightnessMaximum[id] = numbers.count > 1 ? numbers[1] : 100
    }

    func setBrightness(_ id: CGDirectDisplayID, _ value: Double) {
        brightness[id] = value
        _ = cli(["ddc", "set", "0x10", String(Int(value)), "--display", String(id)], timeout: 4)
    }

    // MARK: - Service

    func start() { _ = OizysLifecycle.resume(); refresh() }
    func stop() { _ = OizysLifecycle.stop(); refresh() }
    func restart() { _ = OizysLifecycle.command("restart"); refresh() }
    func setLoginStart(_ on: Bool) { _ = OizysLifecycle.command(on ? "login-enable" : "login-disable"); refresh() }

    // MARK: - Preview

#if !OIZYS_PRODUCTION
    /// A model filled with representative state, so the interface can be rendered and looked
    /// at without a dock, a driver or a running session. `private(set)` is writable here
    /// because this lives in the same file as the declarations.
    static func preview() -> OizysModel {
        let model = OizysModel()
        model.isPreview = true
        SidecarAuto.shared.previewStatus("Connected")
        model.displays = [
            OizysDisplay(id: 1, kind: .builtin, width: 2560, height: 1664, refresh: 60,
                         origin: .zero, main: true, mirrored: false, serial: 0),
            OizysDisplay(id: 10, kind: .sidecar, width: 2360, height: 1640, refresh: 60,
                         origin: CGPoint(x: 1280, y: 0), main: false, mirrored: false, serial: 0),
            OizysDisplay(id: 21, kind: .head, width: 1920, height: 1080, refresh: 60,
                         origin: CGPoint(x: -1245, y: -1080), main: false, mirrored: false,
                         serial: 0x4d560001),
            OizysDisplay(id: 22, kind: .head, width: 1920, height: 1080, refresh: 60,
                         origin: CGPoint(x: 675, y: -1080), main: false, mirrored: false,
                         serial: 0x4d560002),
        ]
        model.running = true
        model.dockPresent = true
        model.loginEnabled = true
        model.displaySleepMinutes = 30
        model.settings = [
            Setting(id: "capture.fps", value: "60", fallback: "60"),
            Setting(id: "control.poll_ms", value: "13", fallback: "13"),
            Setting(id: "head.left.brightness", value: "72", fallback: "100"),
            Setting(id: "head.left.contrast", value: "115", fallback: "100"),
            Setting(id: "head.right.contrast", value: "100", fallback: "100"),
            Setting(id: "head.right.brightness", value: "100", fallback: "100"),
            Setting(id: "head.left.keepalive_s", value: "30", fallback: "0"),
            Setting(id: "head.right.keepalive_s", value: "0", fallback: "0"),
            Setting(id: "head.left.standby_min", value: "0", fallback: "0"),
            Setting(id: "head.right.standby_min", value: "20", fallback: "0"),
            Setting(id: "display.keep_modes", value: "true", fallback: "true"),
            Setting(id: "sidecar.auto_connect", value: "true", fallback: "false"),
            Setting(id: "sidecar.require_desk", value: "true", fallback: "true"),
            Setting(id: "sidecar.device", value: "iPad Pro", fallback: ""),
            Setting(id: "power.saving", value: "true", fallback: "true"),
            Setting(id: "power.idle_fps", value: "10", fallback: "10"),
            Setting(id: "power.idle_after_s", value: "20", fallback: "20"),
            Setting(id: "dock.buffers", value: "2", fallback: "2"),
            Setting(id: "log.level", value: "info", fallback: "info"),
        ]
        model.ports = [
            PortRow(text: "Device                     VID:PID    Declares  Actual    Budget", warning: false),
            PortRow(text: "USB Hub                   1a86:8095  480 Mb/s  480 Mb/s  -", warning: false),
            PortRow(text: "USB TO DP HDMI            17e9:6000  10 Gb/s   5 Gb/s    504 mA", warning: false),
            PortRow(text: "  Backup drive            0781:5583  10 Gb/s   480 Mb/s  -", warning: false),
            PortRow(text: "  ! declares SuperSpeed but negotiated USB 2.0. Its SuperSpeed pairs are not", warning: true),
            PortRow(text: "    connected: try the other end of the cable, a cable rated for USB 3,", warning: true),
            PortRow(text: "    or another port.", warning: true),
        ]
        return model
    }
#endif

    // MARK: - Reconfiguration

    /// One CoreGraphics callback drives both the menu's own refresh and the connect overlay.
    func watchDisplays(_ onChange: @escaping (Set<CGDirectDisplayID>) -> Void) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        DisplayWatch.shared.onAdded = onChange
        DisplayWatch.shared.onAny = { [weak self] in self?.refresh() }
        DisplayWatch.shared.start(context)
    }
}

/// CGDisplayRegisterReconfigurationCallback fires twice per change (begin and end) and for
/// every display in the set. Only the "a display just came online" edge is interesting.
final class DisplayWatch {
    static let shared = DisplayWatch()
    var onAdded: ((Set<CGDirectDisplayID>) -> Void)?
    var onAny: (() -> Void)?
    private var known: Set<CGDirectDisplayID> = []
    private var started = false

    func start(_ context: UnsafeMutableRawPointer) {
        guard !started else { return }
        started = true
        known = Self.online()
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard flags.contains(.setModeFlag) || flags.contains(.addFlag)
                    || flags.contains(.removeFlag) || flags.contains(.enabledFlag) else { return }
            DispatchQueue.main.async { DisplayWatch.shared.settle() }
        }, context)
    }

    private static func online() -> Set<CGDirectDisplayID> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count)))
    }

    private func settle() {
        // macOS reports a display before its mode is final; a short settle keeps the
        // overlay from drawing on a screen that is about to change size under it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [self] in
            let now = Self.online()
            let added = now.subtracting(known)
            known = now
            onAny?()
            if !added.isEmpty { onAdded?(added) }
        }
    }
}
