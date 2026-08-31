import AppKit
import CoreGraphics

// Swift owns the user interface and process controls. The bundled C executable owns
// capture, encoding, USB and recovery; no pixel buffers cross this process boundary.
#if !OIZYS_PRODUCTION
final class OizysApp: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var window: NSWindow!
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let detailLabel = NSTextField(wrappingLabelWithString:
        "Production keeps running while you use developer tools. Start the debug driver to temporarily take over the dock; Stop returns it to production.")
    private let actionButton = NSButton(title: "Start debug driver", target: nil, action: nil)
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
    // names MotionBench takes, and the same keys `oizys config set` takes.
    private let patternMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stressSeconds = NSTextField(string: "60")
    private let configKey = NSTextField(string: "")
    private let configValue = NSTextField(string: "")
    private var diagnostics: [Process] = []
    private var diagnosticTimers: [Int32: Timer] = [:]
    private var developer: DevDiagnostics!
    private var developerKeys: Any?
    private var quitPoll: Timer?
    private var quitBy = Date.distantFuture
    private var session: OizysDevelopmentSession?
    private let screenPermission = OizysDebugPermissions()
    private var explicitQuit = false
    private var signals: [DispatchSourceSignal] = []
    private let info = Bundle.main.infoDictionary ?? [:]
    private var fallback: Bool { info["OizysFallback"] as? Bool ?? (info["OizysFallback"] as? NSString)?.boolValue ?? false }


    func applicationDidFinishLaunching(_ notification: Notification) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }; source.resume(); signals.append(source)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        workspace = support.appendingPathComponent("Oizys/Debug/\(info["OizysVariant"] as? String ?? "debug-minimal")", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workspace.appendingPathComponent("logs"),
                                                     withIntermediateDirectories: true)
        } catch {
            showError("Could not create Oizys's diagnostic folder: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }
        developer = DevDiagnostics(workspace: workspace)
        developer.driverRunning = { [weak self] in self?.worker != nil }
        developer.otherTestsRunning = { [weak self] in self?.diagnostics.contains(where: { $0.isRunning }) ?? false }
        developer.stopOtherTests = { [weak self] in self?.stopTests() }
        developer.acquireAdapter = { [weak self] in
            guard let self else { return false }
            do { self.session = try OizysDevelopmentSession(); return true }
            catch { self.showError(error.localizedDescription); return false }
        }
        developer.releaseAdapter = { [weak self] in self?.releaseSession() }
        developerKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if (modifiers == [.command, .shift] || modifiers == [.command, .option, .control]), event.keyCode == 34 {
                self?.developer.showPrivate(); return nil
            }
            if modifiers == .control, event.keyCode == 8 {
                self?.developer.stop(); self?.stopTests(); return nil
            }
            return event
        }
        makeEditMenu()
        makeMenu()
        makeWindow()
        showWindow()
        if CommandLine.arguments.contains("--benchmark") { start() }
    }

    private func makeEditMenu() {
        // A menu-bar-only app has no Edit menu by default, so Cmd+V/C/X never reach
        // any text field: macOS routes those key equivalents through the menu bar.
        let bar = NSMenu()
        let editItem = NSMenuItem(); bar.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = bar
    }

    private func makeMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Oizys")
        item.button?.toolTip = "Oizys — USB displays"
        let menu = NSMenu()
        statusMenu = NSMenuItem(title: "Oizys · Ready", action: nil, keyEquivalent: "")
        menu.addItem(statusMenu)
        menu.addItem(.separator())
        startMenu = add(menu, "Start debug driver", #selector(start), "")
        stopMenu = add(menu, "Stop debug and restore production", #selector(stop), "")
        stopMenu.isEnabled = false
        menu.addItem(.separator())
        _ = add(menu, "Open Oizys…", #selector(showWindow), ",")
        _ = add(menu, "Open Diagnostics…", #selector(openLogs), "")
        _ = add(menu, "Developer Dashboard…", #selector(openDeveloper), "d")
        _ = add(menu, "Screen Recording Settings…", #selector(openPrivacy), "")
        menu.addItem(.separator())
        _ = add(menu, "Quit Oizys", #selector(quit), "q")
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
        window.title = info["CFBundleDisplayName"] as? String ?? "Oizys-debug"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Your displays, with Oizys")
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
        buttons.addArrangedSubview(diagnosticButton("Developer Dashboard…", #selector(openDeveloper)))
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let footer = NSTextField(labelWithString: "ScreenCaptureKit → C encoder → USB")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        let variant = NSTextField(labelWithString: "Build: \(info["OizysVariant"] as? String ?? "Debug") · DisplayLink fallback: \(fallback ? "enabled after three failed recoveries" : "excluded")")
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
        if !CGPreflightScreenCaptureAccess() {
            _ = requestScreenAccess()
            guard screenPermission.failure == nil else { return }
        }
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private func requestScreenAccess() -> Bool {
        if OizysLifecycle.developmentActive && session == nil {
            update("Another debug session is active", "Stop its driver before changing debug Screen Recording permissions.")
            return false
        }
        let granted = screenPermission.request()
        if !granted {
            update("Screen Recording permission needed", screenPermission.failure ??
                   "Enable this app in Screen Recording settings. If macOS offers Quit & Reopen, use that button. The app's own Quit command ends testing and removes its permission. Production permission was not changed.")
        }
        return granted
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(workspace.appendingPathComponent("logs"))
    }

    @objc private func openDeveloper() { developer.show() }

    private func update(_ status: String, _ detail: String) {
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
        statusMenu.title = "Oizys · \(status)"
        profileBox.isEnabled = worker == nil
        startMenu.isEnabled = worker == nil
        stopMenu.isEnabled = worker != nil && !stopping
        actionButton.title = worker == nil ? "Start debug driver" : stopping ? "Stopping…" : "Stop debug and restore production"
        actionButton.isEnabled = !stopping
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Oizys could not start"
        alert.informativeText = text
        alert.runModal()
    }

    @objc private func toggle() {
        if worker == nil { start() } else { stop() }
    }

    @objc private func start() {
        guard worker == nil else { return }
        guard developer?.claimsAdapter != true else { appendLog("Stop the hardware diagnostic before starting Oizys.\n"); return }
        guard requestScreenAccess() else { return }
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "OizysDriver") else {
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
        environment["OIZYS_LOG_STDOUT"] = "1"
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
        update("Connecting…", "Oizys is claiming the adapter and preparing your displays.")
        do {
            session = try OizysDevelopmentSession()
            try process.run()
        }
        catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            worker = nil
            outputPipe = nil
            try? logFile?.close()
            logFile = nil
            releaseSession()
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
            developer.ingest(line)
            guard !stopping else { continue }
            if line.hasPrefix("Oizys worker ready") || line.hasPrefix("Oizys worker ready") {
                update("Forwarding desktop", "Oizys is driving your configured USB displays. Recovery is automatic if the session fails.")
                if CommandLine.arguments.contains("--benchmark") && !benchmarkStarted {
                    benchmarkStarted = true
                    benchmarkTimer = Timer.scheduledTimer(withTimeInterval: 75, repeats: false) { [weak self] _ in
                        self?.stop()
                    }
                }
            } else if line.hasPrefix("waiting for one supported") {
                update("Waiting for your adapter", "Connect one supported Ridge adapter. Oizys will retry automatically.")
            } else if line.hasPrefix("retrying Oizys") || line.hasPrefix("retrying Oizys") || line.contains("worker stopped responding") {
                update("Reconnecting…", "Oizys is restarting its USB session. Your displays may briefly go dark.")
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
        releaseSession()
        update(process.terminationStatus == 0 ? "Stopped" : "Driver stopped",
               process.terminationStatus == 0 ? "The debug driver released the adapter. Previously running production has been resumed."
                   : "Check Diagnostics for the failure. Oizys has stopped rather than retrying an unsafe startup.")
        if quitting { finishQuitIfReady() }
    }

    private func releaseSession() {
        session?.finish(); session = nil
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
        guard developer?.busy != true else { appendLog("Stop the developer dashboard operation first.\n"); return }
        guard diagnostics.count < 2 else { appendLog("Two diagnostics are already running. Stop them first.\n"); return }
        let process = Process(), pipe = Pipe()
        process.executableURL = executable ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("OizysDriver")
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
        guard worker != nil else { appendLog("Start Oizys before stress testing its displays.\n"); return }
        // The workload covers every screen and sits above every window while it runs. It
        // ignores the mouse, so the machine stays usable, and it ends on its own timer.
        let seconds = max(1, min(600, Int(stressSeconds.stringValue) ?? 60))
        let pattern = patternMenu.titleOfSelectedItem ?? "cycle"
        diagnostic(["\(seconds)", "--pattern", pattern],
                   executable: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("OizysMotionBench"),
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
    @objc private func stopTests() {
        developer?.stop()
        for process in diagnostics where process.isRunning {
            process.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak process] in
                if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    @objc private func exportReport() {
        do {
            let folder = try DiagnosticReport.export(log: logView.string, workspace: workspace, variant: info["OizysVariant"] as? String ?? "debug")
            NSWorkspace.shared.open(folder.appendingPathComponent("README.md"))
        } catch { appendLog("Report export failed: \(error)\n") }
    }

    @objc private func quit() { explicitQuit = true; NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        releaseSession()
        // Keep installed production as the main app, unless another debug session owns the dock.
        if !OizysLifecycle.developmentActive,
           FileManager.default.fileExists(atPath: OizysLifecycle.agent),
           OizysLifecycle.resume() != 0 {
            fputs("Could not resume production. Run oizys service recover-debug, then oizys service start.\n", stderr)
        }
        let permissionRestart = !explicitQuit && screenPermission.awaitingPermissionRestart
        if !screenPermission.cleanupOnQuit(permissionRestart: permissionRestart) {
            fputs((screenPermission.failure ?? "Debug permission cleanup failed.") + "\n", stderr)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        developer?.shutdown()
        stopTests()
        guard worker != nil || developer?.busy == true || diagnostics.contains(where: { $0.isRunning }) else { return .terminateNow }
        quitting = true
        stop()
        // Outlives the worker's own 15 second kill timer, so quitting always completes.
        quitBy = Date().addingTimeInterval(20)
        quitPoll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.finishQuitIfReady() }
        return .terminateLater
    }

    private func finishQuitIfReady() {
        let expired = Date() >= quitBy
        guard expired || (quitting && worker == nil && developer?.busy != true
                          && !diagnostics.contains(where: { $0.isRunning })) else { return }
        quitPoll?.invalidate(); quitPoll = nil
        if expired {
            for process in diagnostics + [worker].compactMap({ $0 }) where process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

#endif

@main
struct OizysApplication {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--cli",
           let driver = Bundle.main.url(forAuxiliaryExecutable: "OizysDriver") {
            let arguments = [driver.path] + Array(CommandLine.arguments.dropFirst(2))
            let pointers = arguments.map { strdup($0) } + [nil]
            pointers.withUnsafeBufferPointer { buffer in _ = execv(driver.path, buffer.baseAddress!) }
            perror("Oizys CLI"); exit(1)
        }
        #if OIZYS_PRODUCTION
        runProduction()
        #else
        let application = NSApplication.shared
        let delegate = OizysApp()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
        #endif
    }
}
