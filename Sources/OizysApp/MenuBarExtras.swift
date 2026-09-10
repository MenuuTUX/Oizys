import AppKit
import CoreGraphics
import Foundation

// This preference controls the optional Screen Mirroring module, not macOS's
// active capture or Sidecar session indicators. Those have no supported hiding API.
enum MenuBarExtras {
    private static let domain = "com.apple.controlcenter" as CFString
    private static let key = "ScreenMirroring" as CFString
    private static let dontShow = 2
    private static let whenActive = 8

    /// False only when the preference says "don't show in the menu bar". An unset key is
    /// macOS's own default, which is to show it while something is mirroring.
    static var mirroringIconVisible: Bool {
        let stored = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser,
                                            kCFPreferencesCurrentHost) as? Int
        return (stored ?? whenActive) != dontShow
    }

    @discardableResult
    static func setMirroringIconVisible(_ visible: Bool) -> Bool {
        CFPreferencesSetValue(key, (visible ? whenActive : dontShow) as CFNumber, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser,
                                        kCFPreferencesCurrentHost)
    }

    /// Permission does not establish whether a capture stream is running.
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
