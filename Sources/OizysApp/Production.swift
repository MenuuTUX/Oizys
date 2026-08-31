#if OIZYS_PRODUCTION
import AppKit
import CoreGraphics
import IOKit
import Darwin

// Only this event listener remains when the dock is absent. No timers, capture
// streams, virtual displays or USB workers run in the dormant state.
private final class ProductionController: NSObject, NSApplicationDelegate {
    private var port: IONotificationPortRef?
    private var attached: io_iterator_t = 0
    private var detached: io_iterator_t = 0
    private var worker: Process?
    private var stopping = false
    private var sleeping = false
    private var displaysAsleep = false
    private var sessionActive = true
    private var quitting = false
    private var replied = false
    private var quitDeadline: Timer?
    private var permissionPrompted = false
    private var retry: Timer?
    private var observers: [NSObjectProtocol] = []
    private var signals: [DispatchSourceSignal] = []
    private var failures = 0
    private var began = Date()
    private var workspace: URL!

    private func matchingDock() -> CFDictionary {
        ["IOProviderClass": "IOUSBHostDevice", "idVendor": 0x17e9, "idProduct": 0x6000] as CFDictionary
    }

    private func dockPresent() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDock(), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 { count += 1; IOObjectRelease(service) }
        return count == 1
    }

    private var eligible: Bool {
        guard !quitting, !sleeping, !displaysAsleep, sessionActive, !OizysLifecycle.developmentActive, dockPresent(),
              let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session[kCGSessionLoginDoneKey as String] as? Bool == true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil); return
        }
        // Allow installation to request this identity's permission before moving the dock.
        if CommandLine.arguments.contains("--permissions-only") {
            requestPermissionIfNeeded()
            NSApp.terminate(nil)
            return
        }
        workspace = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Oizys")
        do { try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { NSApp.terminate(nil); return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { NSApp.terminate(nil); return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let callback: IOServiceMatchingCallback = { reference, iterator in
            while case let device = IOIteratorNext(iterator), device != 0 { IOObjectRelease(device) }
            guard let reference else { return }
            Unmanaged<ProductionController>.fromOpaque(reference).takeUnretainedValue().reconcile()
        }
        let reference = Unmanaged.passUnretained(self).toOpaque()
        guard IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matchingDock(), callback, reference, &attached) == KERN_SUCCESS,
              IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matchingDock(), callback, reference, &detached) == KERN_SUCCESS else {
            NSApp.terminate(nil); return
        }
        // Drain both iterators to arm notifications; no polling while disconnected.
        while case let device = IOIteratorNext(attached), device != 0 { IOObjectRelease(device) }
        while case let device = IOIteratorNext(detached), device != 0 { IOObjectRelease(device) }
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ change: @escaping () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in change() })
        }
        observe(NSWorkspace.willSleepNotification) { [weak self] in self?.sleeping = true; self?.reconcile() }
        observe(NSWorkspace.didWakeNotification) { [weak self] in self?.sleeping = false; self?.reconcile() }
        observe(NSWorkspace.screensDidSleepNotification) { [weak self] in self?.displaysAsleep = true; self?.reconcile() }
        observe(NSWorkspace.screensDidWakeNotification) { [weak self] in self?.displaysAsleep = false; self?.reconcile() }
        observe(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.sessionActive = false; self?.reconcile() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.sessionActive = true; self?.reconcile() }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }; source.resume(); signals.append(source)
        }
        if !CommandLine.arguments.contains("--background") { requestPermissionIfNeeded() }
        reconcile()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        requestPermissionIfNeeded(); reconcile(); return false
    }

    private func requestPermissionIfNeeded() {
        guard !CGPreflightScreenCaptureAccess(), !permissionPrompted else { return }
        permissionPrompted = true
        _ = CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "Allow Oizys to access your displays"
        alert.informativeText = "Enable Oizys in System Settings → Privacy & Security → Screen & System Audio Recording. This one-time macOS permission is required. Login startup stays quiet if access is missing."
        alert.addButton(withTitle: "Open Settings"); alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    private func reconcile() {
        retry?.invalidate(); retry = nil
        guard eligible else { failures = 0; stopWorker(); return }
        guard CGPreflightScreenCaptureAccess() else {
            stopWorker()
            // Recheck only while an eligible dock is connected, without prompting.
            retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.reconcile() }
            return
        }
        guard worker == nil else { return }
        let process = Process()
        process.executableURL = Bundle.main.url(forAuxiliaryExecutable: "OizysDriver")
        process.arguments = ["serve", "--takeover"]
        process.currentDirectoryURL = workspace
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.worker === process else { return }
                self.worker = nil
                let expected = self.stopping; self.stopping = false
                if self.quitting { self.finishQuit(); return }
                guard self.eligible else { return }
                if expected || Date().timeIntervalSince(self.began) > 30 { self.failures = 0 }
                else { self.failures = min(self.failures + 1, 4) }
                self.retry = Timer.scheduledTimer(withTimeInterval: expected ? 0.1 : min(8, pow(2, Double(self.failures))), repeats: false) { [weak self] _ in self?.reconcile() }
            }
        }
        do { try process.run(); worker = process; began = Date() }
        catch { retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.reconcile() } }
    }

    private func stopWorker() {
        guard let worker, worker.isRunning, !stopping else { return }
        stopping = true
        // C supervisor bounds worker teardown. Never wait on the login/UI thread.
        worker.terminate()
    }

    private func finishQuit() {
        guard !replied else { return }
        replied = true
        quitDeadline?.invalidate(); quitDeadline = nil
        if let worker, worker.isRunning { kill(worker.processIdentifier, SIGKILL) }
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true; retry?.invalidate(); retry = nil
        stopWorker()
        guard worker != nil else { return .terminateNow }
        // A worker that ignores its own teardown must never hold login or a takeover open.
        quitDeadline = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in self?.finishQuit() }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if attached != 0 { IOObjectRelease(attached) }; if detached != 0 { IOObjectRelease(detached) }
        if let port { IONotificationPortDestroy(port) }
    }
}

func runProduction() {
    let app = NSApplication.shared
    let delegate = ProductionController()
    app.setActivationPolicy(.accessory); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
#endif
