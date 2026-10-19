import Foundation
import AppKit

@main
struct CalibrationSessionChecks {
    static func main() {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--save-cancel" {
            let driver = URL(fileURLWithPath: CommandLine.arguments[2])
            let folder = URL(fileURLWithPath: CommandLine.arguments[3])
            let target = folder.appendingPathComponent("calibration.json")
            let started = folder.appendingPathComponent("started")
            let finished = folder.appendingPathComponent("finished")
            let original = Data("original correction".utf8)
            try! original.write(to: target)
            func wait(_ predicate: () -> Bool) {
                let deadline = Date().addingTimeInterval(5)
                while !predicate(), Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                precondition(predicate(), "Timed out waiting for solver")
            }
            let session = CalibrationSession()
            session.solve(measurements: ["reference": 0], driver: driver, correctionURL: target)
            wait { FileManager.default.fileExists(atPath: started.path) }
            session.stop()
            wait { FileManager.default.fileExists(atPath: finished.path) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            precondition(session.phase == .idle && !session.canUndo)
            precondition(try! Data(contentsOf: target) == original,
                         "The cancelled solver changed the active correction")
            try! FileManager.default.removeItem(at: started)
            try! FileManager.default.removeItem(at: finished)
            session.solve(measurements: ["reference": 0], driver: driver, correctionURL: target)
            wait { session.canUndo }
            precondition(try! Data(contentsOf: target) == Data("new correction".utf8))
            session.undo()
            precondition(!session.canUndo && (try! Data(contentsOf: target)) == original)
            print("PASS calibration save, cancel and undo")
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--staged-solver" {
            let driver = URL(fileURLWithPath: CommandLine.arguments[2])
            guard case let .success(text, correction) = CalibrationSession.solve(measurements: ["reference": 0], driver: driver) else {
                fatalError("Staged solver failed")
            }
            assert(text.trimmingCharacters(in: .whitespacesAndNewlines) == "staged")
            assert(correction == Data("new correction".utf8))
            print("PASS staged solver")
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--undo" {
            let folder = URL(fileURLWithPath: CommandLine.arguments[2])
            let url = folder.appendingPathComponent("calibration.json")
            let original = Data("prior correction".utf8), updated = Data("updated correction".utf8)
            try! original.write(to: url)
            let snapshot = try! CalibrationSession.SavedCorrection.save(updated, at: url)
            try! snapshot.restore()
            assert(try! Data(contentsOf: url) == original)
            try! FileManager.default.removeItem(at: url)
            let absent = try! CalibrationSession.SavedCorrection.save(updated, at: url)
            try! absent.restore()
            assert(!FileManager.default.fileExists(atPath: url.path))
            let conflicting = try! CalibrationSession.SavedCorrection.save(updated, at: url)
            try! original.write(to: url)
            do { try conflicting.restore(); fatalError("Undo overwrote a newer correction") }
            catch { assert(try! Data(contentsOf: url) == original) }
            print("PASS calibration undo")
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--serve" {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            let session = CalibrationSession()
            session.startServerOnly(host: "127.0.0.1",
                                    identityDirectory: URL(fileURLWithPath: CommandLine.arguments[2]))
            var announced = false
            _ = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                if !announced, !session.address.isEmpty {
                    announced = true
                    let data = try! JSONSerialization.data(withJSONObject: [
                        "address": session.address, "fingerprint": session.certificateFingerprint
                    ])
                    print(String(decoding: data, as: UTF8.self))
                    fflush(stdout)
                }
            }
            FileHandle.standardInput.readabilityHandler = { handle in
                let command = String(decoding: handle.availableData, as: UTF8.self)
                DispatchQueue.main.async {
                    if command.hasPrefix("terminate") {
                        NotificationCenter.default.post(name: NSApplication.willTerminateNotification,
                                                        object: application)
                    } else { session.stop() }
                    print("STOPPED")
                    fflush(stdout)
                    exit(0)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                session.stop()
                exit(1)
            }
            application.run()
            return
        }
        let body = #"{"display":0,"patch":0,"r":0.2,"g":0.3,"b":0.4}"#
        let header = "POST /secret/reading HTTP/1.1\r\nHost: local\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        let request = Data((header + body).utf8)
        for count in [1, 15, header.utf8.count - 1, request.count - 1] {
            assert(CalibrationSession.parseRequest(Data(request.prefix(count))) == .incomplete)
        }
        assert(CalibrationSession.parseRequest(request) ==
               .complete(method: "POST", path: "/secret/reading", body: Data(body.utf8)))
        assert(CalibrationSession.parseRequest(request + Data("x".utf8)) == .invalid)

        let duplicate = "POST /secret/reading HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx"
        let chunked = "POST /secret/reading HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        let oversized = "POST /secret/reading HTTP/1.1\r\nContent-Length: 4097\r\n\r\n"
        let missing = "POST /secret/reading HTTP/1.1\r\nHost: local\r\n\r\n"
        for bad in [duplicate, chunked, oversized, missing] {
            assert(CalibrationSession.parseRequest(Data(bad.utf8)) == .invalid)
        }
        assert(CalibrationSession.parseRequest(Data(repeating: 65, count: 8193)) == .invalid)

        func reading(_ value: String, expectedPatch: Int = 0) -> Bool {
            CalibrationSession.decodeReading(Data(value.utf8), display: 0,
                                             patch: expectedPatch) != nil
        }
        assert(reading(body))
        assert(!reading(body, expectedPatch: 1))
        assert(!reading(#"{"display":1,"patch":0,"r":0.2,"g":0.3,"b":0.4}"#))
        assert(!reading(#"{"display":0,"patch":0,"r":-0.1,"g":0.3,"b":0.4}"#))
        assert(!reading(#"{"display":0,"patch":0,"r":0.2,"g":1.1,"b":0.4}"#))
        assert(!reading(#"{"display":0,"patch":0,"r":1e999,"g":0.3,"b":0.4}"#))
        print("PASS calibration session")
    }
}
