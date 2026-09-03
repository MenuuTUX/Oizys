import AppKit
import Darwin
import IOKit

// Shared by the CLI and GUI; only this user's Oizys applications are controlled.
enum OizysLifecycle {
    static let label = "org.oizys.Oizys.login"
    static var domain: String { "gui/\(getuid())" }
    static var job: String { "\(domain)/\(label)" }
    static var agent: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    /*
     * What counts as the dock, in one place.
     *
     * There were two of these, and they disagreed: the app matched on idVendor alone and the
     * driver on vendor and product. Vendor alone matches nothing -- IOKit returns an empty
     * iterator for it -- so the menu bar reported "No dock connected" while the driver was
     * happily encoding to two panels off that very dock. Anything that needs to know whether
     * the dock is here asks this.
     */
    static let dockVendor = 0x17e9
    static let dockProduct = 0x6000

    static func dockMatching() -> CFDictionary {
        ["IOProviderClass": "IOUSBHostDevice",
         "idVendor": dockVendor, "idProduct": dockProduct] as CFDictionary
    }

    /// How many docks are attached. Callers that need exactly one say so themselves.
    static func dockCount() -> Int {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dockMatching(), &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }
        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            count += 1
            IOObjectRelease(service)
        }
        return count
    }

    static var lease: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Oizys/development-session.json")
    }

    static var leaseInfo: [String: Any] {
        guard let data = try? Data(contentsOf: lease),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    static var developmentActive: Bool {
        guard let owner = leaseInfo["pid"] as? Int32, owner > 1 else { return false }
        return kill(owner, 0) == 0 || errno == EPERM
    }

    static func recoverDevelopmentSession() -> Int32 {
        let info = leaseInfo
        guard let owner = info["pid"] as? Int32 else { return 0 }
        if kill(owner, 0) == 0 || errno == EPERM { return 0 }
        guard stop(includeDebug: false) == 0 else { return 1 }
        try? FileManager.default.removeItem(at: lease)
        return info["resume"] as? Bool == true ? resume() : 0
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String], quiet: Bool = true) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if quiet { process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice }
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return 1 }
    }

    static var agentLoaded: Bool { run("/bin/launchctl", ["print", job]) == 0 }

    static var applications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != getpid() && ($0.bundleIdentifier?.hasPrefix("org.oizys.") ?? false)
                && isAppInstance($0)
        }
    }

    /*
     * True for a running copy of the app itself, false for the driver.
     *
     * OizysDriver lives inside the app bundle, so macOS attributes it to the app's bundle
     * identifier and it turns up in runningApplications like any GUI process. Matching on the
     * identifier alone therefore counts the service as a second copy of the app -- which made
     * the menu-bar item vanish, because the app terminates itself when it thinks another copy
     * is up, and the login agent starts the driver first. Compare the executable instead.
     *
     * Unknown counts as an app: a process that will not say what it is running should still be
     * stopped before an install replaces the bundle underneath it.
     */
    static func isAppInstance(_ app: NSRunningApplication) -> Bool {
        guard let executable = app.executableURL?.lastPathComponent,
              let bundle = app.bundleURL,
              let main = Bundle(url: bundle)?.infoDictionary?["CFBundleExecutable"] as? String
        else { return true }
        return executable == main
    }

    static func resume() -> Int32 {
        if developmentActive {
            fputs("Stop the debug driver or hardware test before resuming production.\n", stderr); return 1
        }
        guard FileManager.default.fileExists(atPath: agent) else {
            fputs("Install production using ./dev.sh install before starting its login service.\n", stderr)
            return 1
        }
        if agentLoaded { return 0 }
        return run("/bin/launchctl", ["bootstrap", domain, agent], quiet: false)
    }

    static func supervisor() -> pid_t? {
        var directory = [CChar](repeating: 0, count: 1024)
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, &directory, directory.count)
        guard count > 0, count <= directory.count else { return nil }
        let path = String(cString: directory) + "oizys-driver.lock"
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 { return nil }
        var bytes = [CChar](repeating: 0, count: 32)
        let length = read(descriptor, &bytes, bytes.count - 1)
        guard length > 0, let pid = Int32(String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, pid != getpid() else { return nil }
        var executable = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &executable, UInt32(executable.count)) > 0 else { return nil }
        let name = URL(fileURLWithPath: String(cString: executable)).lastPathComponent
        return name == "oizys" || name == "OizysDriver" ? pid : nil
    }

    static func stop(includeDebug: Bool = true) -> Int32 {
        if agentLoaded { _ = run("/bin/launchctl", ["bootout", job]) }
        let others = applications.filter { includeDebug || $0.bundleIdentifier?.contains(".debug") != true }
        for application in others { application.terminate() }
        // An app wedged in its own teardown must not block a takeover; escalate, then give up.
        let grace = Date().addingTimeInterval(10)
        let deadline = Date().addingTimeInterval(20)
        var forced = false
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            if !forced, Date() > grace {
                forced = true
                for application in others where !application.isTerminated { application.forceTerminate() }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if others.contains(where: { !$0.isTerminated }) {
            fputs("An Oizys app has not stopped; refusing concurrent takeover.\n", stderr); return 1
        }
        if let pid = supervisor() {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(12)
            while supervisor() == pid, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if supervisor() == pid {
                kill(pid, SIGKILL)
                let deadline = Date().addingTimeInterval(3)
                while supervisor() == pid, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            }
            if supervisor() == pid { return 1 }
        }
        return 0
    }

    static func command(_ action: String) -> Int32 {
        switch action {
        case "status":
            print("Login service: \(agentLoaded ? "loaded" : "not loaded")")
            for app in applications { print("PID \(app.processIdentifier): \(app.bundleURL?.path ?? app.localizedName ?? "Oizys")") }
            print("Capture supervisor: \(supervisor().map(String.init) ?? "stopped")")
            print("Screen Recording access for this executable: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")")
            print("An undocked production listener waits for USB events without capture or polling.")
            return 0
        case "stop": return stop()
        case "recover-debug": return recoverDevelopmentSession()
        case "start": return resume()
        case "restart": return stop() == 0 ? resume() : 1
        case "login-enable":
            guard run("/bin/launchctl", ["enable", job], quiet: false) == 0 else { return 1 }
            return resume()
        case "login-disable":
            guard run("/bin/launchctl", ["disable", job], quiet: false) == 0 else { return 1 }
            return stop()
        case "permissions":
            // TCC is owned by macOS, and a running service never touches it: opening the pane
            // is the whole of what this does. The single exception in the project is
            // Tools/install_app.py, which clears Oizys's own approval during an install the
            // user asked for, because an ad-hoc rebuild leaves an approval that shows as
            // ticked and fails every preflight. Nothing here, and nothing at runtime, resets
            // anything -- and neither ever grants.
            return run("/usr/bin/open", ["x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"], quiet: false)
        default:
            fputs("oizys service status|start|stop|restart|login-enable|login-disable|permissions\n", stderr)
            return 2
        }
    }
}

#if !OIZYS_PRODUCTION
final class OizysDevelopmentSession {
    private var finished = false
    private var descriptor: Int32 = -1
    init() throws {
        try FileManager.default.createDirectory(at: OizysLifecycle.lease.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        descriptor = open(OizysLifecycle.lease.appendingPathExtension("lock").path,
                          O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw NSError(domain: "Oizys", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another debug session owns the dock. Stop its driver or hardware test first."])
        }
        var acquired = false
        defer { if !acquired, descriptor >= 0 { close(descriptor); descriptor = -1 } }
        guard !OizysLifecycle.developmentActive else {
            throw NSError(domain: "Oizys", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another debug session owns the dock. Stop its driver or hardware test first."])
        }
        let previous = OizysLifecycle.leaseInfo
        let resume = OizysLifecycle.agentLoaded || previous["resume"] as? Bool == true
        let data = try JSONSerialization.data(withJSONObject: ["pid": getpid(), "resume": resume])
        try FileManager.default.createDirectory(at: OizysLifecycle.lease.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Transfer restoration responsibility before asking an older debug app to quit.
        try data.write(to: OizysLifecycle.lease, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: OizysLifecycle.lease.path)
        guard OizysLifecycle.stop(includeDebug: false) == 0 else {
            finish()
            throw NSError(domain: "Oizys", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another driver did not release the dock."])
        }
        acquired = true
    }

    func finish() {
        guard !finished else { return }; finished = true
        defer { if descriptor >= 0 { close(descriptor); descriptor = -1 } }
        let info = OizysLifecycle.leaseInfo
        guard info["pid"] as? Int32 == getpid() else { return }
        try? FileManager.default.removeItem(at: OizysLifecycle.lease)
        if info["resume"] as? Bool == true { _ = OizysLifecycle.resume() }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}
#endif

@_cdecl("oizys_service_command")
func oizysServiceCommand(_ action: UnsafePointer<CChar>) -> Int32 {
    OizysLifecycle.command(String(cString: action))
}
