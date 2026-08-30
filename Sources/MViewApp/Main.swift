import AppKit
import CoreGraphics

// Swift owns the user interface and process controls. The bundled C executable owns
// capture, encoding, USB and recovery; no pixel buffers cross this process boundary.
#if !MVIEW_PRODUCTION
final class MviewApp: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var window: NSWindow!
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let detailLabel = NSTextField(wrappingLabelWithString:
        "Connect your USB displays with Mview. DisplayLink will be stopped during use.")
    private let actionButton = NSButton(title: "Start Mview", target: nil, action: nil)
    private var statusMenu: NSMenuItem!
    private var startMenu: NSMenuItem!
    private var stopMenu: NSMenuItem!
    private var worker: Process?
    private var outputPipe: Pipe?
    private var logFile: FileHandle?
    private var pendingOutput = Data()
    private var stopping = false
    private var quitting = false
    private var benchmarkTimer: Timer?
    private var stopTimer: Timer?
    private var benchmarkStarted = false
    private var workspace: URL!
    private let logView = NSTextView()
    private let profileBox = NSButton(checkboxWithTitle: "Fine profiler on next start (adds measurement overhead)", target: nil, action: nil)
    // Developer controls. This window is only built into diagnostic variants, so it can
    // expose the driver's own vocabulary rather than a simplified one: the same pattern
    // names MotionBench takes, and the same keys `mview config set` takes.
    private let patternMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stressSeconds = NSTextField(string: "60")
    private let configKey = NSTextField(string: "")
    private let configValue = NSTextField(string: "")
    private var diagnostics: [Process] = []
    private var diagnosticTimers: [Int32: Timer] = [:]
    private let info = Bundle.main.infoDictionary ?? [:]
    private var fallback: Bool { info["MviewFallback"] as? Bool ?? false }


    func applicationDidFinishLaunching(_ notification: Notification) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        workspace = support.appendingPathComponent("MView", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workspace.appendingPathComponent("logs"),
                                                     withIntermediateDirectories: true)
        } catch {
            showError("Could not create Mview's diagnostic folder: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateIgnoringOtherApps]); NSApp.terminate(nil); return
        }
        makeMenu()
        makeWindow()
        showWindow()
        if CommandLine.arguments.contains("--benchmark") { start() }
    }

    private func makeMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Mview")
        item.button?.toolTip = "Mview — USB displays"
        let menu = NSMenu()
        statusMenu = NSMenuItem(title: "Mview · Ready", action: nil, keyEquivalent: "")
        menu.addItem(statusMenu)
        menu.addItem(.separator())
        startMenu = add(menu, "Start Mview", #selector(start), "")
        stopMenu = add(menu, "Stop Mview", #selector(stop), "")
        stopMenu.isEnabled = false
        menu.addItem(.separator())
        _ = add(menu, "Open Mview…", #selector(showWindow), ",")
        _ = add(menu, "Open Diagnostics…", #selector(openLogs), "")
        _ = add(menu, "Screen Recording Settings…", #selector(openPrivacy), "")
        menu.addItem(.separator())
        _ = add(menu, "Quit Mview", #selector(quit), "q")
        menu.autoenablesItems = false
        item.menu = menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ selector: Selector,
                     _ key: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Mview"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Your displays, with Mview")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.preferredMaxLayoutWidth = 800
        actionButton.target = self
        actionButton.action = #selector(toggle)
        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"
        let privacy = NSButton(title: "Screen Recording Settings…", target: self,
                               action: #selector(openPrivacy))
        privacy.bezelStyle = .rounded
        let buttons = NSStackView(views: [actionButton, privacy])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let footer = NSTextField(labelWithString: "ScreenCaptureKit → C encoder → USB")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        let variant = NSTextField(labelWithString: "Build: \(info["MviewVariant"] as? String ?? "Debug") · DisplayLink fallback: \(fallback ? "enabled after three failed recoveries" : "excluded")")
        variant.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let diagnosticsRow = NSStackView(views: [
            diagnosticButton("Status", #selector(checkStatus)),
            diagnosticButton("Settings", #selector(checkSettings)),
            diagnosticButton("Self tests", #selector(selfTests)),
            diagnosticButton("Encoder benchmark", #selector(benchmark)),
            diagnosticButton("Stop tests", #selector(stopTests)),
            diagnosticButton("Export report", #selector(exportReport))
        ])
        diagnosticsRow.orientation = .horizontal; diagnosticsRow.spacing = 6
        patternMenu.addItems(withTitles: ["cycle", "scroll", "text", "noise", "gradient",
                                          "flash", "scatter", "still"])
        patternMenu.controlSize = .small
        patternMenu.toolTip = "cycle runs every pattern in turn. Each one is the worst case for a different stage; see the header of Tools/MotionBench.swift."
        stressSeconds.controlSize = .small
        stressSeconds.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let stressRow = NSStackView(views: [
            smallLabel("Stress pattern"), patternMenu,
            smallLabel("seconds"), stressSeconds,
            diagnosticButton("Run stress", #selector(stress))])
        stressRow.orientation = .horizontal; stressRow.spacing = 6
        configKey.placeholderString = "capture.fps"
        configValue.placeholderString = "30"
        configKey.controlSize = .small; configValue.controlSize = .small
        configKey.widthAnchor.constraint(equalToConstant: 190).isActive = true
        configValue.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let configRow = NSStackView(views: [
            smallLabel("config set"), configKey, configValue,
            diagnosticButton("Apply", #selector(applySetting)),
            diagnosticButton("Reset all", #selector(resetSettings))])
        configRow.orientation = .horizontal; configRow.spacing = 6
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        logView.isEditable = false; logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]; logView.isVerticallyResizable = true
        logView.textContainer?.widthTracksTextView = true
        scroll.documentView = logView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        let notice = NSTextField(wrappingLabelWithString: "Live capture, queue and driver logs. Buffer capped at 256 KiB; disk log rotates at 10 MiB. Reports stay local. Stress tests animate all screens; Stop tests ends them. No screenshots are collected automatically.")
        notice.font = .systemFont(ofSize: 11); notice.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, variant, statusLabel, detailLabel, buttons, profileBox, diagnosticsRow, stressRow, configRow, scroll, notice, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center()
    }

    @objc private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(workspace.appendingPathComponent("logs"))
    }

    private func update(_ status: String, _ detail: String) {
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
        statusMenu.title = "Mview · \(status)"
        profileBox.isEnabled = worker == nil
        startMenu.isEnabled = worker == nil
        stopMenu.isEnabled = worker != nil && !stopping
        actionButton.title = worker == nil ? "Start Mview" : stopping ? "Stopping…" : "Stop Mview"
        actionButton.isEnabled = !stopping
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Mview could not start"
        alert.informativeText = text
        alert.runModal()
    }

    @objc private func toggle() {
        if worker == nil { start() } else { stop() }
    }

    @objc private func start() {
        guard worker == nil else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            update("Screen Recording permission needed",
                   "Allow Mview in Screen Recording settings, then quit and reopen Mview if macOS asks. DisplayLink has not been stopped.")
            return
        }
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "MviewDriver") else {
            update("Driver missing", "Rebuild the app; its bundled C driver could not be found.")
            return
        }
        let process = Process()
        let pipe = Pipe()
        let logURL = workspace.appendingPathComponent("logs/app-session.log")
        do {
            try Data().write(to: logURL)
            logFile = try FileHandle(forWritingTo: logURL)
        } catch {
            update("Could not open diagnostics", error.localizedDescription)
            return
        }
        process.executableURL = executable
        process.arguments = ["serve", "--takeover", profileBox.state == .on ? "--profile" : "--stats"]
        var environment = ProcessInfo.processInfo.environment
        environment["MVIEW_LOG_STDOUT"] = "1"
        process.environment = environment
        process.currentDirectoryURL = workspace
        process.standardOutput = pipe
        process.standardError = pipe
        pendingOutput.removeAll(keepingCapacity: true)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.didStop(ended) }
        }
        worker = process
        outputPipe = pipe
        stopping = false
        update("Connecting…", "Mview is claiming the adapter and preparing your displays.")
        do { try process.run() }
        catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            worker = nil
            outputPipe = nil
            try? logFile?.close()
            logFile = nil
            update("Could not start the driver", error.localizedDescription)
        }
    }

    private func consume(_ data: Data) {
        appendLog(String(decoding: data, as: UTF8.self))
        if let file = logFile, (try? file.offset()) ?? 0 > 10 * 1024 * 1024 {
            try? file.close()
            let current = workspace.appendingPathComponent("logs/app-session.log")
            let previous = workspace.appendingPathComponent("logs/app-session.previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: current, to: previous)
            FileManager.default.createFile(atPath: current.path, contents: nil)
            logFile = try? FileHandle(forWritingTo: current)
        }
        try? logFile?.write(contentsOf: data)
        pendingOutput.append(data)
        while let newline = pendingOutput.firstIndex(of: 10) {
            let line = String(decoding: pendingOutput[..<newline], as: UTF8.self)
            pendingOutput.removeSubrange(...newline)
            guard !stopping else { continue }
            if line.hasPrefix("Mview worker ready") || line.hasPrefix("MView worker ready") {
                update("Forwarding desktop", "Mview is driving your configured USB displays. Recovery is automatic if the session fails.")
                if CommandLine.arguments.contains("--benchmark") && !benchmarkStarted {
                    benchmarkStarted = true
                    benchmarkTimer = Timer.scheduledTimer(withTimeInterval: 75, repeats: false) { [weak self] _ in
                        self?.stop()
                    }
                }
            } else if line.hasPrefix("waiting for one supported") {
                update("Waiting for your adapter", "Connect one supported Ridge adapter. Mview will retry automatically.")
            } else if line.hasPrefix("retrying Mview") || line.hasPrefix("retrying MView") || line.contains("worker stopped responding") {
                update("Reconnecting…", "Mview is restarting its USB session. Your displays may briefly go dark.")
            }
        }
        // A misbehaving helper must not accumulate an unlimited unterminated log line.
        if pendingOutput.count > 65536 { pendingOutput.removeAll(keepingCapacity: true) }
    }

    @objc private func stop() {
        guard let process = worker, !stopping else { return }
        stopping = true
        benchmarkTimer?.invalidate()
        update("Stopping…", fallback ? "Releasing the adapter and restoring the previous DisplayLink session." : "Releasing the adapter. This build will never launch DisplayLink.")
        process.terminate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self, weak process] _ in
            guard let self = self, let process = process, self.worker === process,
                  process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func didStop(_ process: Process) {
        guard worker === process else { return }
        stopTimer?.invalidate()
        benchmarkTimer?.invalidate()
        worker = nil
        outputPipe = nil
        try? logFile?.close()
        logFile = nil
        stopping = false
        update(process.terminationStatus == 0 ? "Stopped" : "Driver stopped",
               process.terminationStatus == 0 ? "The adapter has been released. You can start Mview again."
                   : "Check Diagnostics for the failure. Mview has stopped rather than retrying an unsafe startup.")
        if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
    }

    private func smallLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func diagnosticButton(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded; button.controlSize = .small
        return button
    }

    private func appendLog(_ text: String) {
        guard let storage = logView.textStorage else { return }
        storage.append(NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]))
        if storage.length > 262144 { storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 262144)) }
        logView.scrollToEndOfDocument(nil)
    }

    private func diagnostic(_ arguments: [String], executable: URL? = nil, timeout: TimeInterval = 90) {
        guard diagnostics.count < 2 else { appendLog("Two diagnostics are already running. Stop them first.\n"); return }
        let process = Process(), pipe = Pipe()
        process.executableURL = executable ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MviewDriver")
        process.arguments = arguments; process.currentDirectoryURL = workspace
        process.standardOutput = pipe; process.standardError = pipe
        appendLog("\n> \(process.executableURL?.lastPathComponent ?? "driver") \(arguments.joined(separator: " "))\n")
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                self?.diagnosticTimers.removeValue(forKey: ended.processIdentifier)?.invalidate()
                self?.diagnostics.removeAll { $0 === ended }
                self?.consume(Data("Diagnostic exited: \(ended.terminationStatus)\n".utf8))
            }
        }
        do {
            try process.run(); diagnostics.append(process)
            diagnosticTimers[process.processIdentifier] = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak process] _ in
                if let process, process.isRunning { process.terminate() }
            }
        } catch { appendLog("Could not run diagnostic: \(error)\n") }
    }
    @objc private func checkStatus() { diagnostic(["probe"]); diagnostic(["displays"]) }
    @objc private func checkSettings() { diagnostic(["config", "list"]) }
    @objc private func selfTests() { diagnostic(["config", "selftest"]) }
    @objc private func benchmark() { diagnostic(["bench"]) }
    @objc private func stress() {
        guard worker != nil else { appendLog("Start Mview before stress testing its displays.\n"); return }
        // The workload covers every screen and sits above every window while it runs. It
        // ignores the mouse, so the machine stays usable, and it ends on its own timer.
        let seconds = max(1, min(600, Int(stressSeconds.stringValue) ?? 60))
        let pattern = patternMenu.titleOfSelectedItem ?? "cycle"
        diagnostic(["\(seconds)", "--pattern", pattern],
                   executable: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MviewMotionBench"),
                   timeout: TimeInterval(seconds + 5))
    }
    @objc private func applySetting() {
        let key = configKey.stringValue.trimmingCharacters(in: .whitespaces)
        let value = configValue.stringValue.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { appendLog("Give both a config key and a value.\n"); return }
        // The driver rereads its configuration when it starts, so a change made while it
        // is running takes effect on the next start rather than now. It says so rather
        // than looking like it did nothing.
        diagnostic(["config", "set", key, value])
        if worker != nil { appendLog("Applies when the driver next starts.\n") }
    }
    @objc private func resetSettings() { diagnostic(["config", "reset"]) }
    @objc private func stopTests() { for process in diagnostics where process.isRunning { process.terminate() } }
    @objc private func exportReport() {
        do {
            let folder = try DiagnosticReport.export(log: logView.string, workspace: workspace, variant: info["MviewVariant"] as? String ?? "debug")
            NSWorkspace.shared.open(folder.appendingPathComponent("README.md"))
        } catch { appendLog("Report export failed: \(error)\n") }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stopTests()
        guard worker != nil else { return .terminateNow }
        quitting = true
        stop()
        return .terminateLater
    }
}

let application = NSApplication.shared
let delegate = MviewApp()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
#else
runProduction()
#endif
