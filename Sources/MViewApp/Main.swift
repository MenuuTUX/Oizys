import AppKit
import CoreGraphics

// Swift owns the user interface and process controls. The bundled C executable owns
// capture, encoding, USB and recovery; no pixel buffers cross this process boundary.
final class MViewApp: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var window: NSWindow!
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let detailLabel = NSTextField(wrappingLabelWithString:
        "Connect your USB displays with MView. DisplayLink will be stopped during use.")
    private let actionButton = NSButton(title: "Start MView", target: nil, action: nil)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        workspace = support.appendingPathComponent("MView", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workspace.appendingPathComponent("logs"),
                                                     withIntermediateDirectories: true)
        } catch {
            showError("Could not create MView's diagnostic folder: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }
        makeMenu()
        makeWindow()
        showWindow()
        if CommandLine.arguments.contains("--benchmark") { start() }
    }

    private func makeMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "MView")
        item.button?.toolTip = "MView — USB displays"
        let menu = NSMenu()
        statusMenu = NSMenuItem(title: "MView · Ready", action: nil, keyEquivalent: "")
        menu.addItem(statusMenu)
        menu.addItem(.separator())
        startMenu = add(menu, "Start MView", #selector(start), "")
        stopMenu = add(menu, "Stop MView", #selector(stop), "")
        stopMenu.isEnabled = false
        menu.addItem(.separator())
        _ = add(menu, "Open MView…", #selector(showWindow), ",")
        _ = add(menu, "Open Diagnostics…", #selector(openLogs), "")
        _ = add(menu, "Screen Recording Settings…", #selector(openPrivacy), "")
        menu.addItem(.separator())
        _ = add(menu, "Quit MView", #selector(quit), "q")
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 290),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "MView"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Your displays, with MView")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.preferredMaxLayoutWidth = 376
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
        let stack = NSStackView(views: [title, statusLabel, detailLabel, buttons, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -32),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)
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
        statusMenu.title = "MView · \(status)"
        startMenu.isEnabled = worker == nil
        stopMenu.isEnabled = worker != nil && !stopping
        actionButton.title = worker == nil ? "Start MView" : stopping ? "Stopping…" : "Stop MView"
        actionButton.isEnabled = !stopping
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "MView could not start"
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
                   "Allow MView in Screen Recording settings, then quit and reopen MView if macOS asks. DisplayLink has not been stopped.")
            return
        }
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "MViewDriver") else {
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
        process.arguments = ["serve", "--takeover", "--stats"]
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
        benchmarkStarted = false
        update("Connecting…", "MView is claiming the adapter and preparing your displays.")
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
        try? logFile?.write(contentsOf: data)
        pendingOutput.append(data)
        while let newline = pendingOutput.firstIndex(of: 10) {
            let line = String(decoding: pendingOutput[..<newline], as: UTF8.self)
            pendingOutput.removeSubrange(...newline)
            guard !stopping else { continue }
            if line.hasPrefix("MView worker ready") {
                update("Forwarding desktop", "MView is driving your configured USB displays. Recovery is automatic if the session fails.")
                if CommandLine.arguments.contains("--benchmark") && !benchmarkStarted {
                    benchmarkStarted = true
                    benchmarkTimer = Timer.scheduledTimer(withTimeInterval: 75, repeats: false) { [weak self] _ in
                        self?.stop()
                    }
                }
            } else if line.hasPrefix("waiting for one supported") {
                update("Waiting for your adapter", "Connect one supported Ridge adapter. MView will retry automatically.")
            } else if line.hasPrefix("retrying MView") || line.contains("worker stopped responding") {
                update("Reconnecting…", "MView is restarting its USB session. Your displays may briefly go dark.")
            }
        }
        // A misbehaving helper must not accumulate an unlimited unterminated log line.
        if pendingOutput.count > 65536 { pendingOutput.removeAll(keepingCapacity: true) }
    }

    @objc private func stop() {
        guard let process = worker, !stopping else { return }
        stopping = true
        benchmarkTimer?.invalidate()
        update("Stopping…", "Releasing the adapter and restoring the previous display driver, if one was running.")
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
               process.terminationStatus == 0 ? "The adapter has been released. You can start MView again."
                   : "Check Diagnostics for the failure. MView has stopped rather than retrying an unsafe startup.")
        if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard worker != nil else { return .terminateNow }
        quitting = true
        stop()
        return .terminateLater
    }
}

let application = NSApplication.shared
let delegate = MViewApp()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
