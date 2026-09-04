import AppKit
import CoreGraphics
import Foundation

/*
 * The two purple items in the menu bar, and the honest limit of what Oizys can do about them.
 *
 * One is macOS's screen-recording indicator, lit because Oizys is capturing the head
 * desktops. The other is the mirroring session indicator, lit by whatever iPad or AirPlay
 * display is attached and staying lit for as long as it is. Neither is Oizys's own status
 * item, which is why turning Oizys off removes neither, and neither has a supported switch.
 *
 * Control Center's Screen Mirroring *module* does have one, and it is not the same item. The
 * preference below is the one System Settings > Control Center writes: per-host
 * com.apple.controlcenter, key `ScreenMirroring`, holding 2 for "don't show in the menu bar",
 * 8 for "show when active" and 18 for "always show". ControlCenter watches its own domain, so
 * a write from here takes effect the way the System Settings switch does, with nothing killed.
 * What it governs is the module. It does not suppress the session indicator: with the key at 2
 * and an iPad attached over Sidecar, that purple item is still there. Oizys used to write a 2
 * on first run and treat the matter as closed, which changed a system setting nobody asked it
 * to change and removed nothing; the switch in the panel is all that is left of it.
 *
 * Screen Recording is a different kind of thing again. The indicator macOS shows while an app
 * is capturing is a privacy signal: there is no preference behind it, no supported API for it,
 * and a driver that quietly hid it would be hiding the one thing telling its owner what it
 * does. Oizys states its capture plainly instead -- see `capturing` below and the Menu bar
 * section of the panel.
 */
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

    /// This process's Screen Recording grant, which is what the system indicator reflects.
    /// Oizys captures the two head desktops and encodes them onto the dock; it reads no
    /// other screen, and it sends nothing anywhere but the USB endpoints.
    static var capturing: Bool { CGPreflightScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
