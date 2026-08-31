#if !OIZYS_PRODUCTION
import AppKit
import CoreGraphics

// Only these developer identities may be reset. Never use a global TCC reset or
// include production, even when a reset fails. Valid access is kept during a session.
final class OizysDebugPermissions {
    static let identifiers = [
        "org.oizys.Oizys.debug-minimal",
        "org.oizys.Oizys.debug-verbose",
        "org.oizys.Oizys.debug-fallback",
    ]
    private var cleaned = false
    private var quitCleaned = false
    private(set) var awaitingPermissionRestart = false
    private(set) var failure: String?

    func request(
        identifier: String? = Bundle.main.bundleIdentifier,
        hasAccess: () -> Bool = CGPreflightScreenCaptureAccess,
        registered: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
        reset: ([String]) -> Int32 = OizysDebugPermissions.reset,
        prompt: () -> Bool = CGRequestScreenCaptureAccess
    ) -> Bool {
        failure = nil
        guard let identifier, Self.identifiers.contains(identifier) else {
            failure = "Permission cleanup is available only in an identified debug app."
            return false
        }
        if hasAccess() { awaitingPermissionRestart = false; return true }
        if !cleaned {
            // Clear stale copies of the current identity last, just before its
            // fresh prompt. A reset is needed only when this build lacks access.
            let others = Self.identifiers.filter { $0 != identifier && registered($0) }
            for target in others + [identifier] {
                guard reset(["reset", "ScreenCapture", target]) == 0 else {
                    failure = "Could not clear old Screen Recording permission for \(target). No new permission was requested. Try again; production permission was not changed."
                    return false
                }
            }
            cleaned = true
        }
        // Repeated clicks in this process must not erase an approval that the
        // user just enabled while macOS is asking them to quit and reopen.
        let granted = prompt()
        awaitingPermissionRestart = !granted
        return granted
    }

    @discardableResult
    func cleanupOnQuit(
        identifier: String? = Bundle.main.bundleIdentifier,
        permissionRestart: Bool = false,
        anotherInstance: (String) -> Bool = { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .contains { $0.processIdentifier != getpid() && !$0.isTerminated }
        },
        reset: ([String]) -> Int32 = OizysDebugPermissions.reset
    ) -> Bool {
        failure = nil
        guard let identifier, Self.identifiers.contains(identifier) else {
            failure = "Quit permission cleanup refused an unrecognized app identity."
            return false
        }
        // A system permission relaunch continues this session. Do not undo its new grant.
        // Permission is shared by bundle ID, so another running copy must retain it too.
        if permissionRestart || anotherInstance(identifier) || quitCleaned { return true }
        guard reset(["reset", "ScreenCapture", identifier]) == 0 else {
            failure = "Could not remove this debug app's Screen Recording entry. Production permission was not changed."
            return false
        }
        quitCleaned = true
        return true
    }

    private static func reset(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return 1 }
    }
}
#endif
