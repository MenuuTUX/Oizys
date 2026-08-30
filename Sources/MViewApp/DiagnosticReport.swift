import Foundation

#if !MVIEW_PRODUCTION
enum DiagnosticReport {
    static func export(log: String, workspace: URL, variant: String) throws -> URL {
        let folder = workspace.appendingPathComponent("reports/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try log.write(to: folder.appendingPathComponent("session.log"), atomically: true, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"head (\d) latency: samples=(\d+) replaced=(\d+).*?processing mean=([\d.]+)ms max=([\d.]+)ms"#)
        let text = log as NSString
        let matches = regex.matches(in: log, range: NSRange(location: 0, length: text.length))
        var rows = "| Window | Head | Captures | Replaced | Mean processing ms | Max ms |\n|---:|---:|---:|---:|---:|---:|\n"
        var points: [Double] = []
        for (i, match) in matches.enumerated() {
            let fields = (1...5).map { text.substring(with: match.range(at: $0)) }
            rows += "| \(i + 1) | \(fields.joined(separator: " | ")) |\n"
            points.append(Double(fields[3]) ?? 0)
        }
        let maxValue = max(points.max() ?? 0, 1)
        let polyline = points.enumerated().map { i, value in
            "\(40 + Double(i) * 700 / Double(max(points.count - 1, 1))),\(230 - value * 190 / maxValue)"
        }.joined(separator: " ")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="800" height="280" viewBox="0 0 800 280">
        <rect width="800" height="280" fill="white"/><text x="40" y="24" font-family="sans-serif" font-size="16">Mean frame processing time, chronological head/window samples</text>
        <path d="M40 40V230H760" fill="none" stroke="#555"/>
        <text x="42" y="55" font-family="sans-serif">\(String(format: "%.2f", maxValue)) ms</text>
        <polyline points="\(polyline)" fill="none" stroke="#2459bb" stroke-width="2"/>
        <text x="40" y="260" font-family="sans-serif">\(points.count) measurements. Capture-to-USB processing, not panel latency.</text></svg>
        """
        try svg.write(to: folder.appendingPathComponent("processing.svg"), atomically: true, encoding: .utf8)
        let report = """
        # Mview diagnostic report

        Build: \(variant). Exported: \(ISO8601DateFormatter().string(from: Date())).
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString).

        This export contains the bounded visible log, not every historical session. Fine profiling changes the workload. No test coverage percentage or physical panel result is inferred from these logs. Paths and device identities can be sensitive; review before sharing.

        ![Processing time](processing.svg)

        \(matches.isEmpty ? "No latency samples were collected. Start Mview and let it run for at least five seconds." : rows)
        
        Raw evidence: [session.log](session.log). CPU, energy, physical latency and hardware fault coverage are not measured by this export.
        """
        try report.write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return folder
    }
}
#endif
