import XCTest

// Run the existing suites from Xcode's Test navigator without a nested Xcode build.
final class SuiteTests: XCTestCase {
    func testPythonSuites() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let python = root.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            XCTFail("Run ./dev.sh setup once to prepare the Python test environment."); return
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-m", "pytest", "Tests", "-q"]
        process.currentDirectoryURL = root
        process.standardOutput = file; process.standardError = file
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        // The scheme supplies the configuration's dylib, including coverage builds.
        process.environment = environment
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        process.waitUntilExit()
        let log = try String(contentsOf: output)
        let attachment = XCTAttachment(string: log)
        attachment.name = "Python suite output"; attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(process.terminationStatus, 0, String(log.suffix(12000)))
    }
}
