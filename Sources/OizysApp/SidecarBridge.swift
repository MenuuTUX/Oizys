import AppKit
import CoreGraphics
import Foundation
import ObjectiveC

/*
 * Apple ships no public API for connecting or disconnecting a Sidecar iPad. The only route
 * is SidecarCore.framework, which is private: the class and selector names below are not a
 * contract, and Apple may rename or remove them in any macOS update.
 *
 * So this bridge is built to fail as a no-op rather than a crash. Every symbol is resolved
 * at runtime, `available` is false the moment one of them is missing, and the menu shows the
 * section as unsupported instead of offering a button that does nothing. Once a Sidecar
 * display is attached, everything else about it -- arrangement, mirroring, resolution, and
 * whether Oizys treats it as a head -- goes through the public display APIs like any other
 * screen, and none of that depends on this file.
 *
 * ponytail: private framework, dynamically resolved, no compile-time checking possible.
 * If Apple ever ships a public Sidecar API, delete this file and call that; nothing else
 * in the app changes.
 */
enum SidecarBridge {
    private static let loaded: Bool = {
        // Already resident when anything on the system has used Sidecar this boot.
        if NSClassFromString("SidecarDisplayManager") != nil { return true }
        return dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore",
                      RTLD_LAZY) != nil
    }()

    private static var manager: NSObject? {
        guard loaded, let type = NSClassFromString("SidecarDisplayManager") as? NSObject.Type
        else { return nil }
        let selector = NSSelectorFromString("sharedManager")
        guard type.responds(to: selector) else { return nil }
        return type.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    /// True only when the framework loaded *and* it answers the calls this needs.
    static var available: Bool {
        guard let manager else { return false }
        return manager.responds(to: NSSelectorFromString("devices"))
            && manager.responds(to: NSSelectorFromString("connectToDevice:completion:"))
    }

    /// Devices Sidecar will actually accept.
    ///
    /// `-devices` returns every paired device the framework knows about, including iPhones,
    /// which cannot be Sidecar displays -- offering one is a button that fails. Prefer an
    /// eligibility list where the framework publishes one, and where it does not, ask each
    /// device whether it supports the feature before listing it. A device that answers
    /// neither question is listed: refusing to show a real iPad because its metadata moved
    /// is the worse failure.
    static func devices() -> [(name: String, handle: NSObject)] {
        guard let manager else { return [] }
        var list: [NSObject] = []
        for candidate in ["eligibleDevices", "availableDevices", "devices"] {
            let selector = NSSelectorFromString(candidate)
            guard manager.responds(to: selector),
                  let found = manager.perform(selector)?.takeUnretainedValue() as? [NSObject]
            else { continue }
            list = found
            if candidate != "devices" { break }   // already filtered by the framework
            list = found.filter(supportsSidecar)
            break
        }
        return list.compactMap { device in
            let name = NSSelectorFromString("name")
            guard device.responds(to: name),
                  let text = device.perform(name)?.takeUnretainedValue() as? String
            else { return nil }
            return (text, device)
        }
    }

    /// True unless the device says outright that it cannot. Unknown counts as yes.
    private static func supportsSidecar(_ device: NSObject) -> Bool {
        for question in ["isEligible", "supportsSidecar", "isSidecarCapable", "canDisplay"] {
            let selector = NSSelectorFromString(question)
            guard device.responds(to: selector) else { continue }
            // A BOOL-returning selector cannot go through `perform`, which reads the return
            // as an object pointer: a false would arrive as nil and a true as garbage.
            guard let implementation = class_getMethodImplementation(type(of: device), selector)
            else { continue }
            typealias Ask = @convention(c) (NSObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Ask.self)(device, selector)
        }
        return true
    }

    /// Devices Sidecar reports as currently attached.
    ///
    /// The framework's own answer comes first because it is the only one that distinguishes
    /// an iPad from an AirPlay receiver, which share a display vendor. Where it does not
    /// answer, an attached Sidecar screen is still visible as a display, and a display is
    /// enough to know not to start connecting again.
    static func isConnected() -> Bool {
        if let manager {
            let selector = NSSelectorFromString("connectedDevices")
            if manager.responds(to: selector),
               let list = manager.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                return !list.isEmpty
            }
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) == 0x6161_706c
        }
    }

    /// The device to connect: the one named, or failing that whichever is offered first.
    /// A name that matches nothing falls back rather than doing nothing -- an iPad renamed
    /// on the iPad is the likeliest reason a stored name stops matching.
    static func device(named name: String) -> (name: String, handle: NSObject)? {
        let list = devices()
        let needle = name.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            if let exact = list.first(where: { $0.name.lowercased() == needle }) { return exact }
            if let loose = list.first(where: { $0.name.lowercased().contains(needle) }) { return loose }
        }
        return list.first
    }

    /// -connectToDevice:completion: takes a block, which `perform` cannot pass, so the
    /// implementation is called through its own signature instead. The completion has to be
    /// declared @convention(block): a plain Swift closure in that slot puts a Swift context
    /// pointer where the framework will send an Objective-C message.
    private static func send(_ selector: String, _ device: NSObject,
                             _ done: @escaping (Error?) -> Void) -> Bool {
        guard let manager else { return false }
        let action = NSSelectorFromString(selector)
        guard manager.responds(to: action),
              let implementation = class_getMethodImplementation(type(of: manager), action)
        else { return false }
        let completion: @convention(block) (NSError?) -> Void = { error in
            DispatchQueue.main.async { done(error) }
        }
        typealias Call = @convention(c) (NSObject, Selector, NSObject, AnyObject) -> Void
        unsafeBitCast(implementation, to: Call.self)(manager, action, device, completion as AnyObject)
        return true
    }

    /// False when the framework does not offer the call at all; the completion reports what
    /// happened when it does. `done` always runs on the main queue.
    @discardableResult
    static func connect(_ device: NSObject, done: @escaping (Error?) -> Void = { _ in }) -> Bool {
        send("connectToDevice:completion:", device, done)
    }

    @discardableResult
    static func disconnect(_ device: NSObject, done: @escaping (Error?) -> Void = { _ in }) -> Bool {
        send("disconnectFromDevice:completion:", device, done)
    }

    /// The supported route, for when the private one is gone.
    static func openSystemSidecar() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }
}
