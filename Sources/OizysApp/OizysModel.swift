import AppKit
import CoreGraphics
import Darwin
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
    var layoutSize: CGSize? = nil

    var name: String {
        switch kind {
        case .head: return head == 0 ? "Left dock display" : "Right dock display"
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

struct ConnectionEvent: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
}

final class OizysModel: ObservableObject {
    @Published private(set) var displays: [OizysDisplay] = []
    @Published private(set) var running = false
    @Published private(set) var supervisorStatus: OizysLifecycle.SupervisorStatus?
    @Published private(set) var loginEnabled = false
    @Published private(set) var dockPresent = false
    @Published private(set) var dockCount = 0
    @Published private(set) var settings: [Setting] = []
    @Published private(set) var ports: [PortRow] = []
    @Published private(set) var displaySleepMinutes = 0
    @Published private(set) var brightness: [CGDirectDisplayID: Double] = [:]
    @Published private(set) var brightnessMaximum: [CGDirectDisplayID: Double] = [:]
    @Published private(set) var brightnessBusy: Set<CGDirectDisplayID> = []
    @Published private(set) var brightnessError: Set<CGDirectDisplayID> = []
    private var confirmedBrightness: [CGDirectDisplayID: Double] = [:]
    private var confirmedSettings: [String: String] = [:]
    private var draftSettings: [String: String] = [:]
    private var commandFailed = false
    @Published var lastMessage = ""
    @Published private(set) var serviceBusy = false
    @Published private(set) var connectionEvents: [ConnectionEvent] = []
    @Published private(set) var connectionChangedAt = Date()
    private var observedSummary: String?
    var onServiceChange: (() -> Void)?
    /// Set only by preview(). Suppresses the refresh that would replace the
    /// representative state with whatever this machine happens to be doing.
    private(set) var isPreview = false
    private var previewRecordingGranted = true

    private var onlineHeadMask: Int {
        displays.reduce(0) { mask, display in
            mask | (display.head.map { 1 << $0 } ?? 0)
        }
    }

    var health: Health {
        if !dockPresent { return .waiting }
        if !screenRecordingGranted { return .waiting }
        guard running else { return .idle }
        guard let supervisorStatus, supervisorStatus.phase == .forwarding,
              supervisorStatus.headMask == 3 else { return .waiting }
        return onlineHeadMask & 3 == 3 ? .live : .waiting
    }

    var connectionHint: String {
        if dockCount == 0 { return "Connect the dock with a USB 3 data cable. Try another Mac port if it is not detected." }
        if dockCount > 1 { return "Disconnect the extra dock. Oizys supports one dock at a time." }
        if !screenRecordingGranted { return "Allow Screen Recording in System Settings to send your desktop to the dock displays." }
        if !running { return "Start the display service to send your desktop to the dock." }
        guard let status = supervisorStatus else { return "The service has not reported its state. Retry the connection or export a report from Diagnostics." }
        switch status.phase {
        case .waiting: return "Oizys is waiting for the dock. Check the data cable and USB port."
        case .starting: return "Oizys is starting the dock displays."
        case .recovering: return "Oizys is reconnecting the displays. If this continues, retry the connection and check the USB cable."
        case .stopping: return "The display service is stopping."
        case .forwarding:
            let mask = onlineHeadMask & status.headMask
            if mask == 3 { return "Both desktops are being sent. Confirm visible output on the monitors separately." }
            if mask == 1 { return "The right dock display is not forwarding. Check its monitor cable, then retry the connection." }
            if mask == 2 { return "The left dock display is not forwarding. Check its monitor cable, then retry the connection." }
            return "The dock displays are not online yet. Retry the connection if they remain unavailable."
        }
    }

    var primaryActionTitle: String {
        if !screenRecordingGranted { return "Grant access…" }
        if !running { return "Start" }
        return !dockPresent || health == .live || supervisorStatus?.phase == .starting
            || supervisorStatus?.phase == .stopping ? "Stop" : "Retry connection"
    }

    var primaryActionEnabled: Bool {
        !serviceBusy && (!screenRecordingGranted || dockPresent || running)
    }

    func performPrimaryAction() {
        if !screenRecordingGranted { requestScreenRecording() }
        else if !running { start() }
        else if primaryActionTitle == "Stop" { stop() }
        else { restart() }
    }

    private func recordConnectionState() {
        let current = summary
        guard current != observedSummary else { return }
        observedSummary = current
        connectionChangedAt = Date()
        connectionEvents.insert(ConnectionEvent(date: connectionChangedAt, text: current), at: 0)
        connectionEvents = Array(connectionEvents.prefix(8))
    }
    var summary: String {
        if dockCount == 0 { return "No dock connected" }
        if dockCount > 1 { return "Multiple supported docks connected" }
        if !screenRecordingGranted { return "Screen Recording required" }
        if !running { return "Stopped" }
        guard let supervisorStatus else { return "Driver active; status unavailable" }
        switch supervisorStatus.phase {
        case .waiting: return "Waiting for a supported dock"
        case .starting: return "Starting display forwarding…"
        case .recovering: return "Recovering connection…"
        case .stopping: return "Stopping…"
        case .forwarding:
            let mask = supervisorStatus.headMask
            guard mask > 0, onlineHeadMask & mask == mask else {
                return "Waiting for dock displays…"
            }
            let heads = mask.nonzeroBitCount
            return "Forwarding to \(heads) display\(heads == 1 ? "" : "s")"
        }
    }

    private let driver: URL?
    private let cliQueue = DispatchQueue(label: "org.oizys.app.cli", qos: .userInitiated)

    init(driver: URL? = Bundle.main.url(forAuxiliaryExecutable: "OizysDriver")) {
        self.driver = driver
    }

    // MARK: - Driver CLI

    private struct CLIResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool

        var message: String {
            if timedOut { return "Driver command timed out." }
            if status != 0 {
                let detail = (stderr.isEmpty ? stdout : stderr)
                    .split(separator: "\n").last.map(String.init) ?? ""
                return detail.isEmpty ? "Driver command failed (status \(status))." : detail
            }
            return stdout.split(separator: "\n").last.map(String.init) ?? ""
        }
    }

    private final class OutputBox { var data = Data() }

    private func cli(_ arguments: [String], timeout: TimeInterval = 8) -> CLIResult {
        guard let driver else {
            return CLIResult(status: -1, stdout: "", stderr: "Driver executable is missing.", timedOut: false)
        }
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = driver
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do { try process.run() }
        catch { return CLIResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false) }
        output.fileHandleForWriting.closeFile()
        error.fileHandleForWriting.closeFile()
        let out = OutputBox(), err = OutputBox(), readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            out.data = output.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            err.data = error.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { process.waitUntilExit(); finished.signal() }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                finished.wait()
            }
        }
        readers.wait()
        return CLIResult(status: process.terminationStatus,
                         stdout: String(decoding: out.data, as: UTF8.self),
                         stderr: String(decoding: err.data, as: UTF8.self), timedOut: timedOut)
    }

    func run(_ arguments: [String], onComplete: ((Bool) -> Void)? = nil) {
        cliQueue.async { [weak self] in
            guard let self else { return }
            let result = self.cli(arguments)
            DispatchQueue.main.async {
                let success = result.status == 0 && !result.timedOut
                self.commandFailed = !success
                self.lastMessage = result.message
                if arguments.count == 4 && arguments.prefix(2) == ["config", "set"] {
                    let key = arguments[2], value = arguments[3]
                    let wasDraft = self.draftSettings[key] != nil
                    if success && wasDraft { self.confirmedSettings[key] = value }
                    if self.draftSettings[key] == value { self.draftSettings.removeValue(forKey: key) }
                    if wasDraft, let index = self.settings.firstIndex(where: { $0.id == key }),
                       let confirmed = self.confirmedSettings[key] {
                        self.settings[index].value = self.draftSettings[key] ?? confirmed
                    }
                    self.applySidecarTint()
                    self.reloadSettings()
                } else {
                    if success && arguments == ["config", "reset"] { self.draftSettings.removeAll() }
                    self.refresh()
                    self.refreshSlowly()
                }
                onComplete?(success)
            }
        }
    }

    // MARK: - Refresh

    func refresh() {
        guard !isPreview else { return }
        readDisplays()
        applySidecarTint()
        dockCount = OizysLifecycle.dockCount()
        dockPresent = dockCount == 1
        let supervisor = OizysLifecycle.supervisor()
        running = supervisor != nil
        supervisorStatus = supervisor.flatMap { OizysLifecycle.supervisorStatus(for: $0) }
        recordConnectionState()
    }

    func refreshSlowly() {
        guard !isPreview else { return }
        cliQueue.async { [weak self] in
            guard let self else { return }
            let loadedSettings = self.readSettings()
            let ports = self.readPorts()
            let loginEnabled = OizysLifecycle.agentLoaded
            let displaySleepMinutes = Self.readDisplaySleep()
            DispatchQueue.main.async {
                guard !self.isPreview else { return }
                self.acceptSettings(loadedSettings)
                if let ports {
                    self.ports = ports
                    if self.lastMessage == "Could not scan USB ports." { self.lastMessage = "" }
                } else if loadedSettings != nil && !self.commandFailed {
                    self.lastMessage = "Could not scan USB ports."
                }
                self.loginEnabled = loginEnabled
                self.displaySleepMinutes = displaySleepMinutes
                self.applySidecarTint()
            }
        }
    }

    private func readDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { displays = []; return }
        displays = ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let bounds = CGDisplayBounds(id)
            let serial = CGDisplaySerialNumber(id)
            let kind: OizysDisplay.Kind
            if CGDisplayIsBuiltin(id) != 0 { kind = .builtin }
            else if CGDisplayVendorNumber(id) == 0x4d56 && (serial == 0x4d560001 || serial == 0x4d560002) { kind = .head }
            else if Self.isSidecar(id) { kind = .sidecar }
            else { kind = .external }
            return OizysDisplay(id: id, kind: kind,
                                width: mode.map { $0.pixelWidth } ?? Int(bounds.width),
                                height: mode.map { $0.pixelHeight } ?? Int(bounds.height),
                                refresh: mode?.refreshRate ?? 0, origin: bounds.origin,
                                main: CGDisplayIsMain(id) != 0,
                                mirrored: CGDisplayIsInMirrorSet(id) != 0,
                                serial: serial, layoutSize: bounds.size)
        }
        DisplayTint.forgetDisconnected(Set(displays.map(\.id)))
    }

    /// Apple's own virtual panels -- a Sidecar iPad and an AirPlay receiver -- share this
    /// vendor. The driver's C side makes the same call; see oizys_display_is_sidecar.
    private static func isSidecar(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x6161706c && CGDisplayIsBuiltin(id) == 0
    }

    // MARK: - Permission and paths

    /// This process's own Screen Recording grant. The driver is a separate executable with a
    /// separate grant, which is why the service log is worth pointing at as well.
    var screenRecordingGranted: Bool {
        isPreview ? previewRecordingGranted : CGPreflightScreenCaptureAccess()
    }

    /// The only place in the app that asks. Everything else reports and waits.
    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Where the login agent's refusals land, as written by Tools/install_app.py.
    var serviceLogPath: String {
        NSHomeDirectory() + "/Library/Application Support/Oizys/logs/service.log"
    }

    /// Path reported by the driver's versioned config listing.
    private(set) var configPath = ""

    private struct ConfigListing: Decodable {
        struct Entry: Decodable {
            let key: String
            let value: String
            let `default`: String
        }
        let version: Int
        let path: String
        let settings: [Entry]
    }

    private struct PortListing: Decodable {
        struct Entry: Decodable {
            let depth: Int
            let name: String
            let vid: UInt16
            let pid: UInt16
            let linkBps: UInt64
            let capableBps: UInt64
            let sinkMA: UInt32
            let verdict: String?

            enum CodingKeys: String, CodingKey {
                case depth, name, vid, pid, verdict
                case linkBps = "link_bps"
                case capableBps = "capable_bps"
                case sinkMA = "sink_ma"
            }
        }
        let version: Int
        let ports: [Entry]
    }

    private func readSettings() -> (String, [Setting])? {
        let result = cli(["config", "list", "--json"])
        guard result.status == 0, !result.timedOut,
              let listing = try? JSONDecoder().decode(ConfigListing.self, from: Data(result.stdout.utf8)),
              listing.version == 1 else { return nil }
        return (listing.path, listing.settings.map {
            Setting(id: $0.key, value: $0.value, fallback: $0.default)
        })
    }

    /// A refresh confirms saved values without replacing an in-progress slider edit.
    private func acceptSettings(_ listing: (String, [Setting])?) {
        guard let (path, loaded) = listing else {
            if !commandFailed { lastMessage = "Could not read driver settings." }
            return
        }
        let previous = sidecarSettings
        configPath = path
        confirmedSettings = Dictionary(loaded.map { ($0.id, $0.value) }, uniquingKeysWith: { _, last in last })
        settings = loaded.map { setting in
            var shown = setting
            shown.value = draftSettings[setting.id] ?? setting.value
            return shown
        }
        if lastMessage == "Could not read driver settings." { lastMessage = "" }
        let updated = sidecarSettings
        if previous.enabled != updated.enabled || previous.requireDesk != updated.requireDesk
            || previous.device != updated.device {
            SidecarAuto.shared.settingsChanged()
        }
    }

    private func editSetting(_ key: String, _ value: String) {
        draftSettings[key] = value
        if let index = settings.firstIndex(where: { $0.id == key }) { settings[index].value = value }
    }

    private func readPorts() -> [PortRow]? {
        let result = cli(["ports", "--json"])
        guard result.status == 0, !result.timedOut,
              let listing = try? JSONDecoder().decode(PortListing.self, from: Data(result.stdout.utf8)),
              listing.version == 1 else { return nil }
        guard !listing.ports.isEmpty else { return [PortRow(text: "No USB devices are attached.", warning: false)] }
        return listing.ports.flatMap { port -> [PortRow] in
            let indent = String(repeating: "  ", count: max(0, min(8, port.depth)))
            let name = port.name.isEmpty ? "(unnamed)" : port.name
            let identity = String(format: "%04x:%04x", port.vid, port.pid)
            let power = port.sinkMA == 0 ? "power unreported" : "\(port.sinkMA) mA"
            let detail = "\(Self.portRate(port.linkBps)) actual · \(Self.portRate(port.capableBps)) capable · \(power)"
            var rows = [PortRow(text: "\(indent)\(name) · \(identity)\n\(indent)  \(detail)", warning: false)]
            if let verdict = port.verdict { rows.append(PortRow(text: "\(indent)! \(verdict)", warning: true)) }
            return rows
        }
    }

    private static func portRate(_ bps: UInt64) -> String {
        if bps == 0 { return "unreported" }
        if bps >= 1_000_000_000 { return String(format: "%.4g Gb/s", Double(bps) / 1e9) }
        return String(format: "%.4g Mb/s", Double(bps) / 1e6)
    }

    func set(_ key: String, _ value: String) {
        run(["config", "set", key, value])
    }

    func resetSetting(_ key: String) {
        guard let setting = settings.first(where: { $0.id == key }) else { return }
        editSetting(key, setting.fallback)
        set(key, setting.fallback)
    }

    /// Export only the facts shown in the app. Raw logs, paths, USB serials and desktop
    /// content stay out of this report.
    func diagnosticReport() -> String {
        let events = connectionEvents.map { "\($0.date.formatted(date: .omitted, time: .standard)): \($0.text)" }
        return (["Oizys connection report", "Generated: \(Date().formatted())", summary,
                 connectionHint, "Screen Recording: \(screenRecordingGranted ? "granted" : "required")",
                 "Detected supported docks: \(dockCount)", "Displays:"]
                + displays.map { "\($0.name): \($0.geometry), origin \(Int($0.origin.x)),\(Int($0.origin.y))" }
                + ["Recent states observed in this app session:"] + events).joined(separator: "\n") + "\n"
    }

    func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Oizys-connection-report.txt"
        panel.message = "Saves connection state, display geometry, and recent app observations. No raw logs, USB serials, file paths, or desktop content."
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.diagnosticReport().write(to: url, atomically: true, encoding: .utf8)
                self.lastMessage = "Connection report saved."
            } catch { self.lastMessage = "Could not save the connection report: \(error.localizedDescription)" }
        }
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
        editSetting(key, value)
        run(["config", "set", key, value])
    }

    func setting(_ key: String, _ fallback: String) -> String {
        settings.first { $0.id == key }?.value ?? fallback
    }

    /// Re-read the config file. Cheap, but it spawns the CLI, so it is for after a write or
    /// a window opening rather than for a tick.
    func reloadSettings() {
        guard !isPreview else { return }
        cliQueue.async { [weak self] in
            guard let self else { return }
            let loaded = self.readSettings()
            DispatchQueue.main.async {
                self.acceptSettings(loaded)
                self.applySidecarTint()
            }
        }
    }

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

    func setHeadBrightness(_ head: Int, _ percent: Double, persist: Bool = true) {
        let key = head == 0 ? "head.left.brightness" : "head.right.brightness"
        let clamped = Int(min(100, max(10, percent.rounded())))
        editSetting(key, String(clamped))
        if persist { run(["config", "set", key, String(clamped)]) }
    }

    // MARK: - Sidecar tint

    /// The iPad's brightness and contrast, as a gamma ramp. Re-applied whenever the settings
    /// or the displays change, because a Sidecar display that detaches and comes back is a
    /// new display id carrying none of our ramp.
    func applySidecarTint() {
        guard !isPreview else { return }
        guard let sidecar = displays.first(where: { $0.kind == .sidecar }) else { return }
        let applied = DisplayTint.apply(sidecar.id,
                                        brightness: Int(setting("sidecar.brightness", "100")) ?? 100,
                                        contrast: Int(setting("sidecar.contrast", "100")) ?? 100)
        if !applied { lastMessage = "Could not apply the Sidecar display tint." }
    }

    func sidecarTint(_ leaf: String) -> Double {
        Double(setting("sidecar.\(leaf)", "100")) ?? 100
    }

    func setSidecarTint(_ leaf: String, _ percent: Double, persist: Bool = true) {
        let key = "sidecar.\(leaf)"
        let limits = leaf == "brightness" ? (10.0, 100.0) : (50.0, 150.0)
        let clamped = Int(min(limits.1, max(limits.0, percent.rounded())))
        editSetting(key, String(clamped))
        if persist { run(["config", "set", key, String(clamped)]) }
        applySidecarTint()
    }

    /// Contrast runs either side of unity, because it pivots on mid-grey rather than scaling
    /// from black. 100 is the panel as sent; above it, highlights clip.
    func headContrast(_ head: Int) -> Double {
        let key = head == 0 ? "head.left.contrast" : "head.right.contrast"
        return Double(settings.first { $0.id == key }?.value ?? "100") ?? 100
    }

    func setHeadContrast(_ head: Int, _ percent: Double, persist: Bool = true) {
        let key = head == 0 ? "head.left.contrast" : "head.right.contrast"
        let clamped = Int(min(150, max(50, percent.rounded())))
        editSetting(key, String(clamped))
        if persist { run(["config", "set", key, String(clamped)]) }
    }

    // MARK: - DDC

    /// Brightness over DDC/CI reaches a monitor on a real display pipe only. A head driven
    /// over the dock has no I2C path, so this is absent for those by design, not broken.
    func readBrightness(_ id: CGDirectDisplayID) {
        guard !brightnessBusy.contains(id) else { return }
        brightnessBusy.insert(id)
        cliQueue.async { [weak self] in
            guard let self else { return }
            let result = self.cli(["ddc", "get", "0x10", "--display", String(id)], timeout: 4)
            let reading: (Double, Double)? = {
                guard result.status == 0, !result.timedOut,
                      let line = result.stdout.split(separator: "\n").first(where: { $0.contains(" = ") }),
                      let equals = line.range(of: " = ") else { return nil }
                let numbers = line[equals.upperBound...].split(whereSeparator: { !$0.isNumber })
                    .compactMap { Double($0) }
                guard let current = numbers.first else { return nil }
                let maximum = numbers.count > 1 ? numbers[1] : 100
                guard maximum > 0, current >= 0, current <= maximum else { return nil }
                return (current, maximum)
            }()
            DispatchQueue.main.async {
                guard !self.isPreview else { return }
                self.brightnessBusy.remove(id)
                guard let reading else {
                    // Keep the last good reading: losing a DDC response must not make the
                    // slider disappear or look like the monitor went to zero.
                    self.brightnessError.insert(id)
                    self.lastMessage = "Display \(id) did not answer a DDC brightness request."
                    return
                }
                self.brightness[id] = reading.0
                self.confirmedBrightness[id] = reading.0
                self.brightnessMaximum[id] = reading.1
                self.brightnessError.remove(id)
            }
        }
    }

    func setBrightness(_ id: CGDirectDisplayID, _ value: Double, persist: Bool = true) {
        brightness[id] = value
        guard persist else { return }
        run(["ddc", "set", "0x10", String(Int(value)), "--display", String(id)]) { [weak self] success in
            guard let self else { return }
            if success { self.readBrightness(id) }
            else {
                self.brightness[id] = self.confirmedBrightness[id]
                self.brightnessError.insert(id)
            }
        }
    }

    // MARK: - Service

    private func service(_ action: @escaping () -> Int32) {
        guard !serviceBusy else { return }
        serviceBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = action()
            DispatchQueue.main.async {
                guard let self else { return }
                self.serviceBusy = false
                self.commandFailed = status != 0
                self.lastMessage = ""
                if status != 0 { self.lastMessage = "Service command failed (status \(status))." }
                self.refresh()
                self.refreshSlowly()
                self.onServiceChange?()
            }
        }
    }

    func start() { service { OizysLifecycle.resume() } }
    func stop() { service { OizysLifecycle.stop() } }
    func restart() { service { OizysLifecycle.command("restart") } }
    func setLoginStart(_ on: Bool) {
        service { OizysLifecycle.command(on ? "login-enable" : "login-disable") }
    }

    // MARK: - Preview

#if !OIZYS_PRODUCTION
    /// A model filled with representative state, so the interface can be rendered and looked
    /// at without a dock, a driver or a running session. `private(set)` is writable here
    /// because this lives in the same file as the declarations.
    static func preview(recordingGranted: Bool = true,
                        phase: OizysLifecycle.SupervisorStatus.Phase = .forwarding,
                        headMask: Int = 3, dockCount: Int = 1) -> OizysModel {
        let model = OizysModel(driver: nil)
        model.isPreview = true
        model.previewRecordingGranted = recordingGranted
        SidecarAuto.shared.previewStatus("Connected")
        model.displays = [
            OizysDisplay(id: 1, kind: .builtin, width: 2560, height: 1664, refresh: 60,
                         origin: .zero, main: true, mirrored: false, serial: 0,
                         layoutSize: CGSize(width: 1280, height: 832)),
            OizysDisplay(id: 10, kind: .sidecar, width: 2360, height: 1640, refresh: 60,
                         origin: CGPoint(x: 1280, y: 0), main: false, mirrored: false, serial: 0,
                         layoutSize: CGSize(width: 1180, height: 820)),
            OizysDisplay(id: 21, kind: .head, width: 1920, height: 1080, refresh: 60,
                         origin: CGPoint(x: -1245, y: -1080), main: false, mirrored: false,
                         serial: 0x4d560001),
            OizysDisplay(id: 22, kind: .head, width: 1920, height: 1080, refresh: 60,
                         origin: CGPoint(x: 675, y: -1080), main: false, mirrored: false,
                         serial: 0x4d560002),
        ]
        model.running = recordingGranted && dockCount == 1
        model.supervisorStatus = OizysLifecycle.SupervisorStatus(version: 1, pid: 1,
                                                                phase: phase,
                                                                headMask: phase == .forwarding ? headMask : 0)
        model.dockPresent = dockCount == 1
        model.dockCount = dockCount
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
            PortRow(text: "USB Hub · 1a86:8095\n  480 Mb/s actual · 480 Mb/s capable · power unreported", warning: false),
            PortRow(text: "USB TO DP HDMI · 17e9:6000\n  5 Gb/s actual · 10 Gb/s capable · 504 mA", warning: false),
            PortRow(text: "  Backup drive · 0781:5583\n    480 Mb/s actual · 10 Gb/s capable · power unreported", warning: false),
            PortRow(text: "  ! Declares SuperSpeed but negotiated USB 2.0. Try another USB 3 cable or port.", warning: true),
        ]
        model.recordConnectionState()
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
    private var settleGeneration = 0

    func start(_ context: UnsafeMutableRawPointer) {
        guard !started else { return }
        started = true
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { DisplayWatch.shared.scheduleSettle() }
        }, context)
        known = Self.online()
    }

    private static func online() -> Set<CGDirectDisplayID> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count)))
    }

    fileprivate func scheduleSettle() {
        // macOS reports a display before its mode is final; a short settle keeps the
        // overlay from drawing on a screen that is about to change size under it.
        settleGeneration += 1
        let generation = settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.settleGeneration == generation else { return }
            let now = Self.online()
            let added = now.subtracting(known)
            known = now
            onAny?()
            if !added.isEmpty { onAdded?(added) }
        }
    }
}
