import AppKit
import CoreGraphics
import Combine
import Foundation
import IOKit.ps

/*
 * Connecting the iPad by itself, when it turns up somewhere it makes sense to use it.
 *
 * This was a separate launchd agent before it lived here (sidecar-auto), which is why it was
 * built the way it was: launchd woke it on a USB match, it re-read its own preferences with
 * `defaults`, and it logged to a file because nothing was watching it. None of that is true
 * inside Oizys. The menu-bar app is already resident, already reads the config the rest of
 * the driver reads, and already has somewhere to say what it is doing -- so the USB matching,
 * the usbmuxd socket, the separate preferences domain and the log file are all gone, and what
 * is left is the part that was doing the work: the triggers, the desk gate and the retries.
 *
 * Nothing polls. SidecarCore keeps its own link to SidecarRelay and posts to this process's
 * notification centre when the reachable set changes, so the run loop stays parked until the
 * iPad actually arrives or leaves. The list has to be read once to make it start pushing.
 *
 * ponytail: dropped the USB trigger the agent needed. SidecarCore reports a reachable iPad
 * over cable and over Wi-Fi alike, and this process is always running to hear it; the agent
 * needed IOKit matching to be started at all. Put it back only if an iPad on a cable turns
 * out not to raise the vicinity notification.
 */
final class SidecarAuto: ObservableObject {
    static let shared = SidecarAuto()

    struct Settings {
        var enabled = false
        var requireDesk = true
        var device = ""
    }

    /// What it is doing and why, for the Sidecar panel. The reason a connect is not being
    /// attempted is the only interesting state this has, so it is the one that is shown.
    @Published private(set) var status = "Off"

    private var read: () -> Settings = { Settings() }
    private var armed = false
    private var busy = false
    private var attempt = 0
    private var retry: Timer?
    private var quietUntil = Date.distantPast
    private var wasConnected = false
    private var nearby = false
    private var observers: [Any] = []

    /// Seconds before each attempt. Spent, it stands down for half an hour rather than
    /// pushing at a framework that has already refused five times.
    private let ladder = [5.0, 10.0, 20.0, 40.0, 60.0]
    private let standDown: TimeInterval = 30 * 60

    private init() {}

#if !OIZYS_PRODUCTION
    /// The rendered previews never arm anything, so the line they would otherwise show is
    /// the initial one rather than a real state. Set what a working watcher would say.
    func previewStatus(_ text: String) { status = text }
#endif

    /// Arms the triggers once. `settings` is read fresh on every decision, so toggling the
    /// switch in the panel takes effect at the next event without restarting anything.
    func start(reading settings: @escaping () -> Settings) {
        read = settings
        guard !armed, SidecarBridge.available else {
            evaluate("settings")
            return
        }
        armed = true
        _ = SidecarBridge.devices()   // prime: SidecarCore only pushes once it has been asked

        let center = NotificationCenter.default
        for name in ["SidecarDevicesChangedNotification",
                     "SidecarDisplayManagerConnectedDevicesChangedNotification"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil,
                                                queue: .main) { [weak self] _ in
                self?.evaluate("devices changed")
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
            queue: .main) { [weak self] _ in self?.evaluate("screen unlocked") })

        // Docking, undocking and plugging in all push; there is no power timer.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { SidecarAuto.shared.evaluate("power changed") }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard flags.contains(.addFlag) || flags.contains(.removeFlag)
                    || flags.contains(.enabledFlag) || flags.contains(.disabledFlag) else { return }
            DispatchQueue.main.async { SidecarAuto.shared.evaluate("displays changed") }
        }, nil)

        wasConnected = SidecarBridge.isConnected()
        evaluate("startup")
    }

    /// Called when the panel writes one of the sidecar.* keys.
    func settingsChanged() { evaluate("settings") }

    // MARK: - Decision

    private func evaluate(_ why: String) {
        let settings = read()
        guard settings.enabled else {
            cancelRetry()
            status = "Off"
            return
        }
        guard SidecarBridge.available else {
            status = "Unavailable on this version of macOS"
            return
        }
        guard let target = SidecarBridge.device(named: settings.device) else {
            if nearby { cancelRetry() }
            nearby = false
            status = "Waiting for an iPad"
            return
        }
        if !nearby {
            // Carried away and brought back is a fresh start, whatever happened last time.
            // This is the one thing that clears a stand-down.
            nearby = true
            quietUntil = .distantPast
            cancelRetry()
        }
        if SidecarBridge.isConnected() {
            cancelRetry()
            wasConnected = true
            status = "Connected"
            return
        }
        if wasConnected, !busy {
            // It went away and this did not ask for it, so the user pressed Disconnect.
            // Taking the display straight back is the one behaviour that would make this
            // unusable.
            wasConnected = false
            quietUntil = Date().addingTimeInterval(5 * 60)
            status = "Disconnected by hand; leaving it alone for 5 minutes"
            cancelRetry()
            return
        }
        wasConnected = false
        if busy || retry != nil {
            return   // one connect at a time; the ladder is already on the clock
        }
        if Self.screenLocked() {
            status = "\(target.name) nearby; waiting for the screen to unlock"
            return
        }
        if settings.requireDesk, let blocked = Self.deskProblem() {
            status = "\(target.name) nearby, but \(blocked)"
            return
        }
        if Date() < quietUntil {
            status = "\(target.name) nearby; standing down"
            return
        }
        _ = why
        connect(target)
    }

    private func connect(_ target: (name: String, handle: NSObject)) {
        busy = true
        status = "Connecting to \(target.name)…"
        let sent = SidecarBridge.connect(target.handle) { [weak self] error in
            guard let self else { return }
            self.busy = false
            if error == nil {
                self.attempt = 0
                self.wasConnected = true
                self.status = "Connected to \(target.name)"
            } else {
                self.armRetry(target.name)
            }
        }
        if !sent {
            busy = false
            status = "Sidecar refused the request"
        }
    }

    private func armRetry(_ name: String) {
        guard attempt < ladder.count else {
            attempt = 0
            quietUntil = Date().addingTimeInterval(standDown)
            status = "\(ladder.count) attempts failed; standing down for 30 minutes"
            return
        }
        let delay = ladder[attempt]
        attempt += 1
        status = "\(name) did not connect; trying again in \(Int(delay))s"
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.retry = nil
            self.evaluate("retry")
        }
    }

    private func cancelRetry() {
        retry?.invalidate()
        retry = nil
        attempt = 0
    }

    // MARK: - Gates

    private static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
    }

    /*
     * An iPad as a second display only makes sense at a desk. Charger in and at least one
     * other external screen attached is a dock, and the iPad earns its place; on battery on
     * a sofa it does not, and grabbing the iPad out of somebody's hands there is worse than
     * doing nothing. Returns what is missing, or nil when this looks like a desk.
     */
    private static func deskProblem() -> String? {
        if !onACPower() { return "on battery" }
        if !externalDisplayAttached() { return "no dock or external display" }
        return nil
    }

    private static func onACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return true   // cannot tell; do not block on it
        }
        guard let source = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue()
        else { return true }
        return (source as String) == kIOPSACPowerValue
    }

    /// Any screen that is not the built-in panel and not another Apple virtual one. An Oizys
    /// head counts, which is the point: the dock being attached is what "at a desk" means.
    private static func externalDisplayAttached() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != 0x6161_706c
        }
    }
}
