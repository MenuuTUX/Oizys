import Foundation

@main
struct ReportTest {
    static func main() throws {
        let workspace = URL(fileURLWithPath: CommandLine.arguments[1])
        let empty = try DiagnosticReport.export(log: "no samples", workspace: workspace, variant: "debug-minimal")
        let emptyText = try String(contentsOf: empty.appendingPathComponent("README.md"))
        assert(emptyText.contains("No latency samples"))
        let log = "head 0 latency: samples=12 replaced=3 processing mean=2.50ms max=4.00ms\n"
            + "head 1 latency: samples=8 replaced=0 processing mean=...ms max=9.00ms\n"
        let folder = try DiagnosticReport.export(log: log, workspace: workspace, variant: "debug-verbose")
        assert(folder != empty)
        let saved = try String(contentsOf: folder.appendingPathComponent("session.log"))
        let report = try String(contentsOf: folder.appendingPathComponent("README.md"))
        let chart = try String(contentsOf: folder.appendingPathComponent("processing.svg"))
        assert(saved == log)
        assert(report.contains("| 1 | 0 | 12 | 3 | 2.50 | 4.00 |"))
        assert(chart.contains("2 measurements"))
        assert(!chart.contains("nan") && !chart.contains("inf"))
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        assert((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let blocked = workspace.appendingPathComponent("file")
        try "not a directory".write(to: blocked, atomically: true, encoding: .utf8)
        do {
            _ = try DiagnosticReport.export(log: log, workspace: blocked, variant: "debug-minimal")
            assertionFailure("An unwritable export must throw")
        } catch { }
        print("PASS diagnostic report")
    }
}
