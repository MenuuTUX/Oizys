import AppKit
import Combine
import Foundation

// Keep service and gamma operations out of this command-boundary test.
enum Health { case live, idle, waiting }
enum DisplayTint {
    static func apply(_ id: CGDirectDisplayID, brightness: Int, contrast: Int) -> Bool { true }
    static func forgetDisconnected(_ ids: Set<CGDirectDisplayID>) {}
}
final class SidecarAuto {
    static let shared = SidecarAuto()
    var changes = 0
    struct Settings { let enabled: Bool; let requireDesk: Bool; let device: String }
    func previewStatus(_ text: String) {}
    func settingsChanged() { changes += 1 }
}
enum OizysLifecycle {
    struct SupervisorStatus {
        enum Phase { case waiting, starting, forwarding, recovering, stopping }
        let version: Int
        let pid: pid_t
        let phase: Phase
        let headMask: Int
    }
    static var agentLoaded: Bool { false }
    static var detectedDocks = 0
    static func dockCount() -> Int { detectedDocks }
    static func supervisor() -> pid_t? { nil }
    static func supervisorStatus(for pid: pid_t) -> SupervisorStatus? { nil }
    static func resume() -> Int32 { fatalError("Service writes are forbidden in this test") }
    static func stop() -> Int32 { fatalError("Service writes are forbidden in this test") }
    static func command(_ action: String) -> Int32 { fatalError("Service writes are forbidden in this test") }
}

@main
struct AppModelTest {
    static func wait(_ predicate: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(predicate(), "Timed out waiting for app state")
    }

    static func main() {
        let mode = CommandLine.arguments[1]
        let model = OizysModel(driver: URL(fileURLWithPath: CommandLine.arguments[2]))
        model.refreshSlowly()
        wait { model.headBrightness(0) == 72 && !model.ports.isEmpty }
        precondition(model.configPath == "/test/oizys.conf")

        switch mode {
        case "failed-write":
            model.setHeadBrightness(0, 86, persist: false)
            precondition(model.headBrightness(0) == 86)
            model.setHeadBrightness(0, 86)
            wait { model.lastMessage == "write rejected" }
            precondition(model.headBrightness(0) == 72,
                         "A rejected write must restore the last saved value even when rereading fails")
        case "drag":
            for value in 10...90 { model.setHeadBrightness(0, Double(value), persist: false) }
            model.setHeadBrightness(0, 90)
            wait { model.lastMessage == "saved" && model.headBrightness(0) == 90 }
        case "read-failure":
            let flags = URL(fileURLWithPath: CommandLine.arguments[2]).deletingLastPathComponent()
                .appendingPathComponent("fail-read")
            try! Data().write(to: flags)
            let ports = model.ports.map(\.text)
            model.refreshSlowly()
            wait { model.lastMessage == "Could not read driver settings." }
            precondition(model.headBrightness(0) == 72 && model.ports.map(\.text) == ports)
        case "refresh-during-drag":
            model.setHeadBrightness(0, 86, persist: false)
            var updates = 0
            let observation = model.$settings.dropFirst().sink { _ in updates += 1 }
            model.reloadSettings()
            wait { updates > 0 }
            precondition(model.headBrightness(0) == 86, "Refresh replaced an unfinished slider edit")
            withExtendedLifetime(observation) {}
            model.setHeadBrightness(0, 86)
            wait { model.lastMessage == "saved" }
        case "sidecar-save":
            precondition(SidecarAuto.shared.changes == 0)
            model.set("sidecar.auto_connect", "true")
            wait { model.sidecarSettings.enabled }
            precondition(SidecarAuto.shared.changes == 1,
                         "Sidecar rules were not applied after the save completed")
        case "reset-draft":
            model.setHeadBrightness(0, 86, persist: false)
            model.run(["config", "reset"])
            wait { model.headBrightness(0) == 100 }
        case "reset-key":
            model.resetSetting("head.left.brightness")
            wait { model.headBrightness(0) == 100 && model.lastMessage == "saved" }
            precondition(model.setting("sidecar.auto_connect", "missing") == "false")
        case "timeline-report":
            model.refresh()
            precondition(model.connectionEvents.count == 1 && model.summary == "No dock connected")
            model.refresh()
            precondition(model.connectionEvents.count == 1, "Repeated refresh added duplicate events")
            OizysLifecycle.detectedDocks = 1
            model.refresh()
            precondition(model.connectionEvents.count == 2)
            precondition(model.connectionEvents.last?.text == "No dock connected")
            let report = model.diagnosticReport()
            precondition(report.contains(model.summary) && report.contains("No dock connected"))
            precondition(!report.contains(model.configPath) && !report.contains(model.serviceLogPath))
            OizysLifecycle.detectedDocks = 0
        case "timeout":
            model.setHeadBrightness(0, 86)
            wait({ model.lastMessage == "Driver command timed out." }, timeout: 12)
            precondition(model.headBrightness(0) == 72)
        case "states":
            let healthy = OizysModel.preview()
            let blocked = OizysModel.preview(recordingGranted: false)
            let recovering = OizysModel.preview(phase: .recovering)
            let leftOnly = OizysModel.preview(headMask: 1)
            let rightOnly = OizysModel.preview(headMask: 2)
            let setupWithoutDock = OizysModel.preview(recordingGranted: false, dockCount: 0)
            precondition(healthy.health == .live && healthy.summary == "Forwarding to 2 displays")
            precondition(blocked.health == .waiting && blocked.summary == "Screen Recording required")
            precondition(recovering.health == .waiting && recovering.summary == "Recovering connection…")
            precondition(healthy.primaryActionTitle == "Stop")
            precondition(blocked.primaryActionTitle == "Grant access…")
            precondition(setupWithoutDock.primaryActionTitle == "Grant access…" && setupWithoutDock.primaryActionEnabled)
            precondition(recovering.primaryActionTitle == "Retry connection")
            precondition(leftOnly.health == .waiting && leftOnly.connectionHint.contains("right dock display"))
            precondition(rightOnly.health == .waiting && rightOnly.connectionHint.contains("left dock display"))
        default: fatalError("Unknown test mode")
        }
        print("PASS " + mode)
    }
}
