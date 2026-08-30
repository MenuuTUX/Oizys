import AppKit
import CoreGraphics
import Darwin

#if MVIEW_PRODUCTION
// One-time permission and LaunchServices identity, then exec replaces the launcher.
// No resident AppKit UI, log viewer, motion benchmark or extra menu-bar item.
func runProduction() {
    guard CGPreflightScreenCaptureAccess() else {
        _ = CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "Allow Mview to access your displays"
        alert.informativeText = "Enable Mview in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Mview. DisplayLink has not been stopped."
        alert.addButton(withTitle: "Open Settings"); alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return
    }
    guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MviewDriver") else { exit(1) }
    let workspace = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MView")
    do { try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    catch { exit(1) }
    guard chdir(workspace.path) == 0 else { exit(1) }
    // Normal production operation does not retain terminal output or diagnostic files.
    let null = open("/dev/null", O_RDWR)
    if null >= 0 { dup2(null, STDIN_FILENO); dup2(null, STDOUT_FILENO); dup2(null, STDERR_FILENO); if null > 2 { close(null) } }
    let args = [executable.path, "serve", "--takeover"].map { strdup($0) } + [nil]
    args.withUnsafeBufferPointer { _ = execv(executable.path, $0.baseAddress!) }
    for arg in args { free(arg) }
    exit(1)
}
#endif
