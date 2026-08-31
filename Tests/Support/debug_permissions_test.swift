import Foundation

@main
struct DebugPermissionsTest {
    static func main() {
        let current = "org.oizys.Oizys.debug-verbose"
        let permissions = OizysDebugPermissions()
        var calls: [[String]] = []
        var prompts = 0
        let mode = CommandLine.arguments[1]
        func request(access: Bool = false, identifier: String = current, succeeds: Bool = true) -> Bool {
            permissions.request(identifier: identifier, hasAccess: { access }, registered: { _ in true },
                reset: { calls.append($0); return succeeds ? 0 : 1 },
                prompt: { prompts += 1; return false })
        }
        switch mode {
        case "preserve":
            precondition(request(access: true))
            precondition(calls.isEmpty && prompts == 0)
        case "production":
            precondition(!request(identifier: "org.oizys.Oizys.production"))
            precondition(calls.isEmpty && prompts == 0 && permissions.failure != nil)
        case "order":
            var events: [String] = []
            _ = permissions.request(identifier: current, hasAccess: { false }, registered: { _ in true },
                reset: { events.append($0.last!); return 0 }, prompt: { events.append("prompt"); return false })
            precondition(events == ["org.oizys.Oizys.debug-minimal", "org.oizys.Oizys.debug-fallback", current, "prompt"])
        case "repeat":
            _ = request(); _ = request()
            precondition(calls.count == 3 && prompts == 2)
            precondition(request(access: true))
            precondition(calls.count == 3 && prompts == 2)
        case "failure":
            _ = request(succeeds: false)
            precondition(prompts == 0 && permissions.failure != nil)
            _ = request()
            precondition(prompts == 1 && permissions.failure == nil)
        case "unregistered":
            _ = permissions.request(identifier: current, hasAccess: { false }, registered: { _ in false },
                reset: { calls.append($0); return 0 }, prompt: { false })
            precondition(calls == [["reset", "ScreenCapture", current]])
        case "quit":
            precondition(permissions.cleanupOnQuit(identifier: current, anotherInstance: { _ in false },
                reset: { calls.append($0); return 0 }))
            precondition(permissions.cleanupOnQuit(identifier: current, anotherInstance: { _ in false },
                reset: { calls.append($0); return 0 }))
            precondition(calls == [["reset", "ScreenCapture", current]])
        case "quit-production":
            precondition(!permissions.cleanupOnQuit(identifier: "org.oizys.Oizys.production",
                anotherInstance: { _ in false }, reset: { calls.append($0); return 0 }))
            precondition(calls.isEmpty && permissions.failure != nil)
        case "quit-shared":
            precondition(permissions.cleanupOnQuit(identifier: current, anotherInstance: { _ in true },
                reset: { calls.append($0); return 0 }))
            precondition(calls.isEmpty)
        case "quit-restart":
            _ = request()
            precondition(permissions.awaitingPermissionRestart)
            calls.removeAll()
            precondition(permissions.cleanupOnQuit(identifier: current, permissionRestart: true,
                anotherInstance: { _ in false }, reset: { calls.append($0); return 0 }))
            precondition(calls.isEmpty)
            precondition(request(access: true))
            precondition(!permissions.awaitingPermissionRestart)
        case "quit-failure":
            precondition(!permissions.cleanupOnQuit(identifier: current, anotherInstance: { _ in false },
                reset: { _ in 1 }))
            precondition(permissions.failure != nil)
            precondition(permissions.cleanupOnQuit(identifier: current, anotherInstance: { _ in false },
                reset: { calls.append($0); return 0 }))
            precondition(permissions.failure == nil && calls.count == 1)
        default: fatalError("Unknown test")
        }
        for call in calls {
            precondition(call.count == 3 && call[0] == "reset" && call[1] == "ScreenCapture")
            precondition(OizysDebugPermissions.identifiers.contains(call[2]))
        }
        print("PASS \(mode)")
    }
}
