import AppKit
import Foundation

enum SidecarBridge {
    static var available = false
    static var deviceLookups = 0

    static func devices() -> [(name: String, handle: NSObject)] { [] }
    static func isConnected() -> Bool { false }
    static func device(named: String) -> (name: String, handle: NSObject)? {
        deviceLookups += 1
        return nil
    }
    static func connect(_ device: NSObject, done: @escaping (Error?) -> Void = { _ in }) -> Bool { false }
}

@main
struct SidecarAutoTest {
    static func main() {
        let auto = SidecarAuto.shared
        auto.start { SidecarAuto.Settings(enabled: true, requireDesk: false, device: "") }
        precondition(auto.status == "Unavailable on this version of macOS")

        SidecarBridge.available = true
        NotificationCenter.default.post(name: Notification.Name("SidecarDevicesChangedNotification"), object: nil)
        precondition(auto.status == "Waiting for an iPad")
        precondition(SidecarBridge.deviceLookups == 1)

        auto.start { SidecarAuto.Settings(enabled: true, requireDesk: false, device: "") }
        precondition(SidecarBridge.deviceLookups == 2)
        NotificationCenter.default.post(name: Notification.Name("SidecarDevicesChangedNotification"), object: nil)
        precondition(SidecarBridge.deviceLookups == 3)
        print("PASS sidecar auto")
    }
}
