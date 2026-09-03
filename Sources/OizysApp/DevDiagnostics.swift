#if !OIZYS_PRODUCTION
import AppKit
import SwiftUI
import CoreVideo
import Darwin

private struct DevDisplay: Identifiable {
    let id: UInt32
    let name: String
    let pixels: String
    let refresh: String
    let cadence: String
    let capture: String
    let latency: String
}

private struct DevProcess: Identifiable {
    let id: Int32
    let name: String
    let cpu: String
    let memory: String
}

// Display-link callbacks measure scheduler cadence, not frames rendered by an app.
private final class DevDisplayClock {
    var link: CVDisplayLink?
    private let lock = NSLock()
    private var ticks = 0
    private var started = ProcessInfo.processInfo.systemUptime
    init(_ display: CGDirectDisplayID) {
        guard CVDisplayLinkCreateWithCGDisplay(display, &link) == kCVReturnSuccess, let link else { return }
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
            guard let context else { return kCVReturnError }
            let clock = Unmanaged<DevDisplayClock>.fromOpaque(context).takeUnretainedValue()
            clock.lock.lock(); clock.ticks += 1; clock.lock.unlock()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
    }
    func sample() -> String {
        guard let link, CVDisplayLinkIsRunning(link) else { return "Unavailable" }
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime, elapsed = now - started
        defer { ticks = 0; started = now }
        return elapsed > 0 ? String(format: "%.1f Hz", Double(ticks) / elapsed) : "Waiting"
    }
    deinit { if let link { CVDisplayLinkStop(link) } }
}

final class DevDiagnostics: NSObject, ObservableObject, NSWindowDelegate {
    @Published var rootPath = UserDefaults.standard.string(forKey: "developerRepository")
        ?? Bundle.main.object(forInfoDictionaryKey: "OizysDeveloperRoot") as? String ?? ""
    @Published var preparingTools = false
    @Published var settingsExist = false
    @Published var output = ""
    @Published var privateOutput = ""
    @Published var job = "Idle"
    @Published var busy = false
    @Published var progressSeconds = 0
    @Published var cpu = "Waiting"
    @Published var memory = "Waiting"
    @Published var thermal = "Waiting"
    @Published var cpuHistory: [Double] = []
    @Published fileprivate var displays: [DevDisplay] = []
    @Published fileprivate var processes: [DevProcess] = []
    @Published var monitoring = true
    @Published var recording = false
    @Published var recordingCount = 0
    @Published var suite = "All suites"
    @Published var suites = ["All suites"]
    @Published var testMode = "Suite"
    @Published var testFilter = ""
    @Published var coverageFloor = "80"
    @Published var mutationLimit = "40"
    @Published var mutationSeed = "1"
    @Published var profileFrames = "120"
    @Published var workload = "desktop"
    @Published var baseline = ""
    @Published var seconds = "60"
    @Published var timeout = "1800"
    @Published var pattern = "cycle"
    @Published var dwell = "10"
    @Published var full = true
    @Published var fraction = 0.6
    @Published var reportInput = ""
    @Published var unlocked = false
    @Published var replacingPrivateSettings = false
    @Published var privateStatus = "Locked"
    @Published var passphrase = ""
    @Published var source = ""
    @Published var repeatedPassphrase = ""
    @Published var fixtureCount = "6"
    @Published var fixturePerScreen = "auto"
    @Published var fixtureFPS = "0"
    @Published var fixtureSeconds = "30"
    @Published var fixtureFull = false
    @Published var fixtureFraction = 0.6

    var driverRunning: () -> Bool = { false }
    var otherTestsRunning: () -> Bool = { false }
    var stopOtherTests: () -> Void = {}
    var acquireAdapter: () -> Bool = { false }
    var releaseAdapter: () -> Void = {}
    private(set) var claimsAdapter = false
    private var dashboard: NSWindow?
    private var privateWindow: NSWindow?
    private var active: Process?
    private var deadline: Timer?
    private var escalation: Timer?
    private var timer: Timer?
    private var started = Date()
    private var privateJob = false
    private var stoppingJob = false
    private var privateEpoch = 0
    private var sampling = false
    private var clocks: [UInt32: DevDisplayClock] = [:]
    private var lastCPU: [UInt32]?
    private var lastProcesses: [Int32: (Double, Double)] = [:]
    private var frameMetrics: [UInt32: (Date, Double, Int)] = [:]
    private var latency: [Int: (Date, String)] = [:]
    private var recordedSamples: [[String: Any]] = []
    private var recordingStarted = 0.0
    private let workspace: URL
    private var fixtureSettings: String { NSHomeDirectory() + "/Library/Application Support/Oizys/fixture.json" }

    init(workspace: URL) {
        self.workspace = workspace
        super.init()
        if let index = CommandLine.arguments.firstIndex(of: "--developer-root"),
           CommandLine.arguments.indices.contains(index + 1) {
            rootPath = CommandLine.arguments[index + 1]
        }
        let embeddedRevision = Bundle.main.url(forResource: "developer-revision", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if rootPath.isEmpty, let revision = embeddedRevision ?? Bundle.main.object(forInfoDictionaryKey: "OizysDeveloperRevision") as? String {
            rootPath = workspace.appendingPathComponent("Developer/\(revision)").path
        }
        reportInput = workspace.appendingPathComponent("logs").path
        settingsExist = FileManager.default.fileExists(atPath: fixtureSettings)
        reloadSuites()
        prepareEmbeddedTools()
    }

    private func prepareEmbeddedTools() {
        let destination = URL(fileURLWithPath: rootPath)
        guard !FileManager.default.fileExists(atPath: destination.appendingPathComponent("Tools/dev_runner.py").path),
              let archive = Bundle.main.url(forResource: "Developer", withExtension: "zip") else { return }
        preparingTools = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let staging = destination.deletingLastPathComponent().appendingPathComponent("prepare-\(UUID().uuidString)")
            var failure: String?
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: staging) }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-x", "-k", archive.path, staging.path]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
                if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: staging, to: destination) }
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparingTools = false; self.reloadSuites()
                if let failure { self.append("Could not prepare embedded tools: \(failure)\n", privateLog: false) }
            }
        }
    }

    func prepareDependencies() {
        repository("Prepare developer tools", request: ["tool": "setup.py"], duration: 1800)
    }

    func preparePrivateDependencies() {
        privateStatus = "Preparing tools…"
        repository("Preparing required tools", request: ["tool": "fixture", "action": "prepare"],
                   privateLog: true, duration: 1800) { [weak self] code in
            self?.privateStatus = code == 0 ? "Tools ready" : "Tool setup failed"
        }
    }

    func show() {
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Oizys Developer Diagnostics"
            window.contentView = NSHostingView(rootView: DevDashboard(model: self))
            window.minSize = NSSize(width: 980, height: 700)
            window.isReleasedWhenClosed = false; window.delegate = self; window.center()
            dashboard = window
        }
        dashboard?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if timer == nil {
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func showPrivate() {
        settingsExist = FileManager.default.fileExists(atPath: fixtureSettings)
        if privateWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 670, height: 700),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Local fixture"
            window.contentView = NSHostingView(rootView: DevPrivateView(model: self))
            window.minSize = NSSize(width: 620, height: 600)
            window.isReleasedWhenClosed = false; window.delegate = self; window.center()
            privateWindow = window
        }
        privateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === privateWindow { lockPrivate() }
        if let window = notification.object as? NSWindow, window === dashboard {
            endRecording()
            timer?.invalidate(); timer = nil; clocks.removeAll()
            lastCPU = nil; lastProcesses.removeAll()
        }
    }

    func lockPrivate() {
        privateEpoch += 1
        if privateJob { stop() }
        unlocked = false; passphrase = ""; repeatedPassphrase = ""; source = ""; privateOutput = ""
        replacingPrivateSettings = false; privateStatus = "Locked"
    }

    func beginPrivateSetup() {
        guard !busy else { return }
        lockPrivate()
        replacingPrivateSettings = true
        privateStatus = "Create new settings"
    }

    func shutdown() {
        stop(); lockPrivate(); endRecording(); timer?.invalidate(); timer = nil; clocks.removeAll()
    }

    func ingest(_ line: String) {
        if line.contains("worker ready") { frameMetrics.removeAll(); latency.removeAll() }
        if line.hasPrefix("OIZYS_METRIC ") {
            let values = Dictionary(line.split(separator: " ").dropFirst().compactMap { token -> (String, String)? in
                let fields = token.split(separator: "=", maxSplits: 1)
                return fields.count == 2 ? (String(fields[0]), String(fields[1])) : nil
            }, uniquingKeysWith: { _, new in new })
            if let display = UInt32(values["display"] ?? ""), let fps = Double(values["capture_fps"] ?? ""),
               fps.isFinite, let head = Int(values["head"] ?? "") {
                frameMetrics[display] = (Date(), fps, head)
            }
        }
        if line.hasPrefix("head "), line.contains(" latency:"), let head = Int(line.split(separator: " ").dropFirst().first ?? "") {
            latency[head] = (Date(), line)
        }
    }

    func chooseRepository() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = url.path; UserDefaults.standard.set(rootPath, forKey: "developerRepository"); reloadSuites()
        }
    }

    private func reloadSuites() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: rootPath + "/Tests")) ?? []
        suites = ["All suites"] + files.filter { $0.hasPrefix("test_") && $0.hasSuffix(".py") }.sorted()
        suite = "All suites"
    }

    private func append(_ text: String, privateLog: Bool) {
        if privateLog { privateOutput = String((privateOutput + text).suffix(131072)) }
        else { output = String((output + text).suffix(262144)) }
    }

    private func integer(_ value: String, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let n = Int(value), range.contains(n) else {
            throw NSError(domain: "Developer controls", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) must be \(range.lowerBound)…\(range.upperBound)."])
        }
        return n
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { append(error.localizedDescription + "\n", privateLog: false) }
    }

    private func launch(_ title: String, executable: URL, arguments: [String], input: Data? = nil,
                        cwd: URL? = nil, privateLog: Bool = false, duration: Double = 1800,
                        claimsAdapter: Bool = false,
                        completion: ((Int32) -> Void)? = nil) {
        guard !busy, !otherTestsRunning() else { append("Stop the current operation first.\n", privateLog: privateLog); return }
        if claimsAdapter && !acquireAdapter() { return }
        let process = Process(), pipe = Pipe(), stdin = Pipe()
        let epoch = privateEpoch
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = cwd ?? workspace
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do {
            try process.run()
            active = process; busy = true; privateJob = privateLog; stoppingJob = false
            self.claimsAdapter = claimsAdapter
            job = privateLog ? "Local operation" : title; started = Date(); progressSeconds = 0
            append("\n\(title) started.\n", privateLog: privateLog)
            if let input { stdin.fileHandleForWriting.write(input); try? stdin.fileHandleForWriting.close() }
            deadline = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in self?.stop() }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    let text = String(decoding: data, as: UTF8.self)
                    DispatchQueue.main.async {
                        guard let self, !privateLog || self.privateEpoch == epoch else { return }
                        self.append(text, privateLog: privateLog)
                    }
                }
                process.waitUntilExit()
                DispatchQueue.main.async {
                    guard let self, self.active === process else { return }
                    self.deadline?.invalidate(); self.escalation?.invalidate()
                    self.active = nil; self.busy = false; self.privateJob = false; self.stoppingJob = false
                    self.claimsAdapter = false
                    if claimsAdapter { self.releaseAdapter() }
                    self.job = "\(privateLog ? "Local operation" : title): exit \(process.terminationStatus)"
                    if !privateLog || self.privateEpoch == epoch {
                        self.append("\nExited \(process.terminationStatus).\n", privateLog: privateLog)
                        completion?(process.terminationStatus)
                    }
                }
            }
        } catch {
            if claimsAdapter { releaseAdapter() }
            append("Could not start: \(error.localizedDescription)\n", privateLog: privateLog)
        }
    }

    private func repository(_ title: String, request: [String: Any], privateLog: Bool = false,
                            duration: Double? = nil, completion: ((Int32) -> Void)? = nil) {
        do {
            let root = URL(fileURLWithPath: rootPath)
            let runner = root.appendingPathComponent("Tools/dev_runner.py")
            guard FileManager.default.fileExists(atPath: runner.path) else {
                append("Choose the Oizys source checkout first.\n", privateLog: privateLog); return
            }
            let python = [root.appendingPathComponent(".venv/bin/python").path,
                          "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }!
            let limit = try duration ?? Double(integer(timeout, "Timeout", 10...14400))
            launch(title, executable: URL(fileURLWithPath: python), arguments: ["-u", runner.path],
                   input: try JSONSerialization.data(withJSONObject: request), cwd: root,
                   privateLog: privateLog, duration: limit, completion: completion)
        } catch { append(error.localizedDescription + "\n", privateLog: privateLog) }
    }

    func stop() {
        guard let process = active, !stoppingJob else { return }
        stoppingJob = true
        if process.isRunning { process.interrupt() }
        job = "Stopping…"
        guard escalation == nil || escalation?.isValid == false else { return }
        escalation = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self, weak process] _ in
            guard let self, let process, self.active === process, process.isRunning else { return }
            // The Python supervisor owns a session and cancels each child group in
            // finally blocks. Direct bundled tools have no child processes.
            process.terminate()
            self.escalation = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak process] _ in
                if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    func runTests() {
        attempt {
            var args: [String] = []
            switch testMode {
            case "Address + UB": args = ["--sanitize", "address"]
            case "Undefined": args = ["--sanitize", "undefined"]
            case "Thread": args = ["--sanitize", "thread"]
            case "Coverage": args = ["--coverage", "--coverage-floor", String(try integer(coverageFloor, "Coverage floor", 0...100))]
            case "Mutation": args = ["--mutate", "--limit", String(try integer(mutationLimit, "Mutation limit", 1...1000)),
                                      "--seed", String(try integer(mutationSeed, "Seed", 0...Int(Int32.max)))]
            default: break
            }
            if testMode != "Mutation" && testMode != "Address + UB" {
                var expressions: [String] = []
                if suite != "All suites" { expressions.append(String(suite.dropLast(3))) }
                if !testFilter.isEmpty { expressions.append("(\(testFilter))") }
                if !expressions.isEmpty { args += ["-k", expressions.joined(separator: " and ")] }
            }
            repository("\(testMode) tests", request: ["tool": "test.py", "arguments": args])
        }
    }

    func runDriver(_ command: String) {
        let exclusive = ["verify", "patterns", "diagnose"].contains(command)
        if exclusive && driverRunning() { append("Stop Oizys before a test that claims the USB adapter.\n", privateLog: false); return }
        attempt {
            var args = [command]
            if command == "selftest" { args = ["config", "selftest"] }
            if command == "settings" { args = ["config", "list"] }
            if exclusive {
                let alert = NSAlert(); alert.messageText = "Run a hardware diagnostic?"
                alert.informativeText = "This pauses production and claims the dock. Displays may go dark. Production resumes when the operation ends."
                alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                args += ["--takeover"]
                if command != "diagnose" { args += ["--seconds", String(try integer(seconds, "Seconds", 1...600))] }
            }
            guard let binary = Bundle.main.url(forAuxiliaryExecutable: "OizysDriver") else { return }
            launch(command, executable: binary, arguments: args, duration: exclusive ? 900 : 180, claimsAdapter: exclusive)
        }
    }

    func runProfile() {
        attempt {
            let frames = try integer(profileFrames, "Frames", 1...100000)
            let file = workspace.appendingPathComponent("logs/profile-\(UUID().uuidString).json")
            var args = ["--frames", String(frames), "--workload", workload, "--save", file.path]
            if !baseline.isEmpty { args += ["--compare", baseline] }
            repository("Scanout profile", request: ["tool": "profile.py", "arguments": args])
        }
    }

    func measure() {
        attempt {
            let n = try integer(seconds, "Seconds", 1...3600)
            let path = workspace.appendingPathComponent("logs/processes-\(UUID().uuidString).json").path
            repository("Process recording", request: ["tool": "measure_processes.py", "arguments": [path, "--seconds", String(n)]], duration: Double(n + 30))
        }
    }

    func stress() {
        attempt {
            let n = try integer(seconds, "Seconds", 1...3600)
            let d = try integer(dwell, "Pattern dwell", 1...600)
            guard let binary = Bundle.main.url(forAuxiliaryExecutable: "OizysMotionBench") else { return }
            launch("Motion stress", executable: binary, arguments: [String(n), "--pattern", pattern, "--dwell", String(d),
                full ? "--full" : "--windowed", "--fraction", String(fraction)], duration: Double(n + 15))
        }
    }

    func report() {
        let destination = workspace.appendingPathComponent("reports/\(UUID().uuidString)")
        repository("Run report", request: ["tool": "report.py", "arguments": [reportInput, "-o", destination.path]], completion: { status in
            if status == 0 { NSWorkspace.shared.open(destination) }
        })
    }

    func exportSnapshot() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "oizys-resources.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "cpu": cpu,
            "memory": memory, "thermal": thermal, "displays": displays.map {
                ["id": String($0.id), "name": $0.name, "pixels": $0.pixels, "refresh": $0.refresh,
                 "displayLink": $0.cadence, "captureFPS": $0.capture, "latency": $0.latency]
            }, "processes": processes.map { ["pid": String($0.id), "name": $0.name, "cpu": $0.cpu, "rss": $0.memory] }]
        attempt { try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
    }

    func beginRecording() {
        guard !recording else { return }
        monitoring = true; recordedSamples.removeAll(); recordingCount = 0
        recordingStarted = ProcessInfo.processInfo.systemUptime; recording = true
    }

    func endRecording() {
        guard recording else { return }
        recording = false
        let destination = workspace.appendingPathComponent("logs/resources-\(UUID().uuidString).json")
        attempt {
            try JSONSerialization.data(withJSONObject: recordedSamples, options: [.sortedKeys]).write(to: destination, options: .atomic)
            append("Resource recording saved: \(destination.path)\n", privateLog: false)
        }
        recordedSamples.removeAll()
    }

    func saveOutput() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "developer-run.log"
        if panel.runModal() == .OK, let url = panel.url { attempt { try output.write(to: url, atomically: true, encoding: .utf8) } }
    }

    func privateAction(_ action: String) {
        guard !busy else { return }
        privateOutput = ""
        if ["init", "replace"].contains(action) && (passphrase.count < 16 || passphrase != repeatedPassphrase) {
            privateStatus = "Check the new passphrase"
            privateOutput = "Use matching passphrases of at least 16 characters.\n"; return
        }
        guard !passphrase.isEmpty else { privateStatus = "Enter your passphrase"; return }
        guard ["unlock", "init", "replace"].contains(action) || unlocked else { return }
        if action == "replace" {
            guard replacingPrivateSettings else { return }
            let alert = NSAlert()
            alert.messageText = "Save new local settings?"
            alert.informativeText = "The previous encrypted settings will be kept as a private backup. The new passphrase opens only the new settings. Production is unchanged."
            alert.addButton(withTitle: "Back up and replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        privateStatus = action == "unlock" ? "Unlocking…" : "Working…"
        do {
            var request: [String: Any] = ["tool": "fixture", "action": action, "passphrase": passphrase]
            if ["source", "init", "replace"].contains(action) { request["source"] = source }
            if action == "run" || action == "check" {
                request["seconds"] = try integer(fixtureSeconds, "Seconds", 1...3600)
                request["count"] = try integer(fixtureCount, "Candidates", 2...96)
                request["perScreen"] = fixturePerScreen == "auto" ? 0 : try integer(fixturePerScreen, "Per screen", 1...96)
                guard let fps = Double(fixtureFPS), fps.isFinite, (0...240).contains(fps) else {
                    privateOutput = "Minimum source FPS must be 0…240.\n"; return
                }
                request["minFPS"] = fps; request["full"] = fixtureFull; request["fraction"] = fixtureFraction
            }
            repository("Local operation", request: request, privateLog: true,
                       duration: Double((Int(fixtureSeconds) ?? 120) + 960)) { [weak self] code in
                guard let self else { return }
                if ["unlock", "init", "replace"].contains(action) {
                    self.unlocked = code == 0 && !self.passphrase.isEmpty
                    if self.unlocked { self.replacingPrivateSettings = false }
                    self.privateStatus = self.unlocked ? "Unlocked" : action == "unlock" ? "Could not unlock" : "Could not save settings"
                } else {
                    self.privateStatus = code == 0 ? "Finished" : code == 130 ? "Stopped" : "Operation failed"
                }
                self.settingsExist = FileManager.default.fileExists(atPath: self.fixtureSettings)
                if code == 0 { self.source = ""; self.repeatedPassphrase = "" }
            }
        } catch { privateStatus = "Check the entered values"; privateOutput += error.localizedDescription + "\n" }
    }

    private func tick() {
        if busy { progressSeconds = Int(Date().timeIntervalSince(started)) }
        guard monitoring else { clocks.removeAll(); lastCPU = nil; lastProcesses.removeAll(); return }
        sampleHost(); sampleDisplays(); sampleProcesses()
    }

    private func sampleHost() {
        var cpuInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: cpuInfo) / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if result == KERN_SUCCESS {
            let ticks = [cpuInfo.cpu_ticks.0, cpuInfo.cpu_ticks.1, cpuInfo.cpu_ticks.2, cpuInfo.cpu_ticks.3]
            if let old = lastCPU {
                let delta = zip(ticks, old).map { Double($0 &- $1) }, total = zip(ticks, old).reduce(0.0) { $0 + Double($1.0 &- $1.1) }
                if total > 0 {
                    let value = 100 * (total - delta[Int(CPU_STATE_IDLE)]) / total
                    cpu = String(format: "%.1f%% of %d cores", value, ProcessInfo.processInfo.activeProcessorCount)
                    cpuHistory = Array((cpuHistory + [value]).suffix(120))
                }
            }
            lastCPU = ticks
        } else { cpu = "Unavailable" }
        var vm = vm_statistics64_data_t()
        count = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        if vmResult == KERN_SUCCESS {
            let used = (Double(vm.active_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)) * Double(vm_kernel_page_size) / 1073741824
            memory = String(format: "%.2f / %.1f GiB", used, Double(ProcessInfo.processInfo.physicalMemory) / 1073741824)
        } else { memory = "Unavailable" }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Nominal"
        case .fair: thermal = "Fair"
        case .serious: thermal = "Serious"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unknown"
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { thermal += " · low power mode" }
    }

    private func sampleDisplays() {
        var ids = Set<UInt32>()
        displays = NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            ids.insert(id)
            if clocks[id] == nil { clocks[id] = DevDisplayClock(id) }
            let mode = CGDisplayCopyDisplayMode(id)
            let hz = mode?.refreshRate ?? 0
            var capture = "Not observed", timing = "No driver samples"
            if let metric = frameMetrics[id], Date().timeIntervalSince(metric.0) < 12 {
                capture = String(format: "%.1f fps · head %d", metric.1, metric.2)
                if let detail = latency[metric.2], Date().timeIntervalSince(detail.0) < 12 { timing = detail.1 }
            }
            return DevDisplay(id: id, name: screen.localizedName,
                pixels: "\(mode?.pixelWidth ?? CGDisplayPixelsWide(id))×\(mode?.pixelHeight ?? CGDisplayPixelsHigh(id)) · \(Int(screen.frame.width))×\(Int(screen.frame.height)) pt",
                refresh: hz > 0 ? String(format: "%.2f Hz", hz) : "Variable / unreported",
                cadence: clocks[id]?.sample() ?? "Unavailable", capture: capture, latency: timing)
        }
        clocks = clocks.filter { ids.contains($0.key) }
    }

    private func sampleProcesses() {
        guard !sampling else { return }; sampling = true
        let ownPID = ProcessInfo.processInfo.processIdentifier, jobPID = active?.processIdentifier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,ppid=,time=,rss=,comm="]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            var text = ""
            do { try process.run(); text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit() } catch {}
            let now = ProcessInfo.processInfo.systemUptime
            var rows: [(Int32, Int32, Double, Double, String)] = []
            for line in text.split(separator: "\n") {
                let parts = line.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
                guard parts.count == 5, let pid = Int32(parts[0]), let parent = Int32(parts[1]), let rss = Double(parts[3]) else { continue }
                let dayClock = parts[2].split(separator: "-")
                let time = dayClock.last!.split(separator: ":").reversed().enumerated().reduce(0.0) { $0 + (Double($1.element) ?? 0) * pow(60, Double($1.offset)) }
                    + (dayClock.count == 2 ? (Double(dayClock[0]) ?? 0) * 86400 : 0)
                rows.append((pid, parent, time, rss, URL(fileURLWithPath: String(parts[4])).lastPathComponent))
            }
            var selected: Set<Int32> = [ownPID]
            if let jobPID { selected.insert(jobPID) }
            for row in rows where ["oizys", "oizysdriver", "windowserver", "displaylink manager", "oizysmotionbench", "fixturebench"].contains(row.4.lowercased()) { selected.insert(row.0) }
            var changed = true
            while changed {
                changed = false
                for row in rows where selected.contains(row.1) { if selected.insert(row.0).inserted { changed = true } }
            }
            let relevant = rows.filter { selected.contains($0.0) && $0.0 != process.processIdentifier }
            DispatchQueue.main.async {
                guard let self else { return }; self.sampling = false
                guard self.monitoring else { return }
                self.processes = relevant.map { row in
                    var cpu = "Waiting"
                    if let previous = self.lastProcesses[row.0], now > previous.0, row.2 >= previous.1 {
                        cpu = String(format: "%.1f%%", 100 * (row.2 - previous.1) / (now - previous.0))
                    }
                    return DevProcess(id: row.0, name: row.4, cpu: cpu, memory: String(format: "%.1f MiB", row.3 / 1024))
                }.sorted { $0.id < $1.id }
                self.lastProcesses = Dictionary(uniqueKeysWithValues: relevant.map { ($0.0, (now, $0.2)) })
                if self.recording {
                    let values = Dictionary(uniqueKeysWithValues: relevant.map {
                        (String($0.0), ["name": $0.4, "cpu_seconds": $0.2, "rss_kib": $0.3] as [String: Any])
                    })
                    self.recordedSamples.append(["elapsed": now - self.recordingStarted, "processes": values,
                        "system_cpu": self.cpu, "memory": self.memory, "thermal": self.thermal,
                        "displays": self.displays.map {
                            ["id": String($0.id), "refresh": $0.refresh, "display_link": $0.cadence,
                             "capture_fps": $0.capture, "latency": $0.latency]
                        }])
                    self.recordingCount = self.recordedSamples.count
                    if self.recordingCount >= 3600 { self.endRecording() }
                }
            }
        }
    }
}

private struct DevDashboard: View {
    @ObservedObject var model: DevDiagnostics
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Developer diagnostics").font(.title2.bold())
                    Text("\(model.job)\(model.busy ? " · \(model.progressSeconds)s" : "")").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop all tests") { model.stop(); model.stopOtherTests() }.keyboardShortcut(".", modifiers: .command)
            }
            HStack {
                Text("Checkout").foregroundStyle(.secondary)
                Text(model.rootPath.isEmpty ? "Select source checkout for Python tools" : model.rootPath).lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.preparingTools { ProgressView().controlSize(.small) }
                Button("Prepare tools") { model.prepareDependencies() }.disabled(model.busy || model.preparingTools)
                Button("Choose…") { model.chooseRepository() }.disabled(model.busy || model.preparingTools)
            }.font(.caption)
            TabView {
                overview.tabItem { Label("Live metrics", systemImage: "gauge.with.dots.needle.50percent") }
                tests.tabItem { Label("Tests", systemImage: "checklist") }
                profilers.tabItem { Label("Profilers", systemImage: "chart.bar.xaxis") }
                stress.tabItem { Label("Displays", systemImage: "display.2") }
                console.tabItem { Label("Output & reports", systemImage: "terminal") }
            }
            Text("Developer builds only. Tools run only when requested. Measurements add overhead; no physical panel FPS, GPU utilization or energy reading is inferred.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 940, minHeight: 640)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Toggle("Live sampling", isOn: $model.monitoring).disabled(model.recording)
                    Spacer()
                    if model.recording {
                        Text("\(model.recordingCount) samples").foregroundStyle(.secondary)
                        Button("Stop recording & save") { model.endRecording() }
                    } else { Button("Record samples") { model.beginRecording() } }
                    Button("Export snapshot…") { model.exportSnapshot() }
                }
                HStack(spacing: 24) {
                    metric("System CPU", model.cpu)
                    metric("Memory · active + wired + compressed", model.memory)
                    metric("Thermal state", model.thermal)
                }
                GeometryReader { geometry in
                    Path { path in
                        for (index, value) in model.cpuHistory.enumerated() {
                            let point = CGPoint(x: CGFloat(index) / CGFloat(max(1, model.cpuHistory.count - 1)) * geometry.size.width,
                                                y: geometry.size.height * (1 - value / 100))
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }.stroke(Color.accentColor, lineWidth: 2)
                }.frame(height: 64).background(Color.primary.opacity(0.035)).accessibilityLabel("Recent system CPU utilization, scale zero to one hundred percent")
                Text("Displays").font(.headline)
                ForEach(model.displays) { display in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack { Text(display.name).bold(); Text("ID \(display.id) · \(display.pixels)").foregroundStyle(.secondary) }
                            HStack(spacing: 30) {
                                metric("Mode refresh", display.refresh)
                                metric("Display-link cadence", display.cadence)
                                metric("Captured → processed", display.capture)
                            }
                            Text(display.latency).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Capture FPS comes from successful driver presentations averaged over its reporting interval. Static desktops can report zero; cached refreshes are excluded. Samples expire after 12 seconds. Other drivers' frame counts are unavailable.").font(.caption).foregroundStyle(.secondary)
                Text("Processes · 100% CPU = one core").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 35, verticalSpacing: 6) {
                    GridRow { Text("PID"); Text("Process"); Text("CPU"); Text("Resident memory") }.bold()
                    ForEach(model.processes) { process in
                        GridRow { Text(String(process.id)); Text(process.name); Text(process.cpu); Text(process.memory) }
                    }
                }.font(.system(.caption, design: .monospaced))
                Text("Includes Oizys, WindowServer, DisplayLink and descendants of developer jobs. Process memory is RSS; shared pages can be counted more than once. Recording runs alongside workloads, saves on close, and is capped at 3,600 samples. Pausing sampling reduces measurement overhead.").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(name).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(.body, design: .monospaced)) }
    }

    private var tests: some View {
        Form {
            Section("Repository suite") {
                Picker("Mode", selection: $model.testMode) { ForEach(["Suite", "Coverage", "Address + UB", "Undefined", "Thread", "Mutation"], id: \.self) { Text($0) } }
                Picker("Suite", selection: $model.suite) { ForEach(model.suites, id: \.self) { Text($0) } }.disabled(["Mutation", "Address + UB"].contains(model.testMode))
                TextField("Pytest -k expression", text: $model.testFilter).disabled(["Mutation", "Address + UB"].contains(model.testMode))
                if model.testMode == "Coverage" { TextField("Coverage floor %", text: $model.coverageFloor) }
                if model.testMode == "Mutation" {
                    TextField("Mutants per source", text: $model.mutationLimit); TextField("Seed", text: $model.mutationSeed)
                }
                TextField("Time limit, seconds", text: $model.timeout)
                Button("Run selected tests") { model.runTests() }.disabled(model.busy)
                Text("The first suite run creates .venv and installs pytest, hypothesis and numpy. Mutation runs use build copies. Sanitizer fallbacks and coverage limitations appear in the output. Nothing runs automatically.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Bundled diagnostics") {
                HStack {
                    Button("Configuration self-test") { model.runDriver("selftest") }
                    Button("Encoder benchmark") { model.runDriver("bench") }
                    Button("Encoder zone profile") { model.runDriver("profile") }
                }.disabled(model.busy)
            }
        }.formStyle(.grouped)
    }

    private var profilers: some View {
        Form {
            Section("Scanout profiler") {
                Picker("Workload", selection: $model.workload) { Text("Desktop damage").tag("desktop"); Text("Keyframe").tag("keyframe") }
                TextField("Frames", text: $model.profileFrames)
                TextField("Compare with baseline JSON, optional", text: $model.baseline)
                Button("Profile and save JSON") { model.runProfile() }.disabled(model.busy)
                Text("Uses the repository's built library. Run the suite once if the library or Python environment is missing. Profiles are saved under Application Support/Oizys/logs.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Process resource recording") {
                TextField("Duration, seconds", text: $model.seconds)
                Button("Record CPU and memory") { model.measure() }.disabled(model.busy)
                Text("Records cumulative CPU deltas and peak RSS. Does not start or stop a display driver.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Driver profiling") {
                Text("Enable ‘Fine profiler on next start’ in the main developer window before starting Oizys. Live metrics show capture throughput, processing time, capture age and replaced frames from that session.")
                Button("Open diagnostic folder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.reportInput)) }
            }
        }.formStyle(.grouped)
    }

    private var stress: some View {
        Form {
            Section("Compositor stress") {
                Picker("Pattern", selection: $model.pattern) { ForEach(["cycle", "scroll", "text", "noise", "gradient", "flash", "scatter", "still"], id: \.self) { Text($0) } }
                TextField("Duration, seconds", text: $model.seconds); TextField("Cycle dwell, seconds", text: $model.dwell)
                Toggle("Cover every screen", isOn: $model.full)
                if !model.full { Slider(value: $model.fraction, in: 0.1...1) { Text("Window fraction \(Int(model.fraction * 100))%") } }
                Button("Run motion stress") { model.stress() }.disabled(model.busy)
                Text("Borderless windows. Escape or Ctrl+C stops playback. Flash and cycle contain flashing images. This can saturate CPU, USB and displays.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Hardware and topology") {
                HStack {
                    Button("USB probe") { model.runDriver("probe") }; Button("List monitors") { model.runDriver("monitors") }
                    Button("Create virtual test heads") { model.runDriver("displays") }
                    Button("Routes") { model.runDriver("routes") }; Button("Configuration") { model.runDriver("settings") }
                }
                HStack {
                    Button("Verify physical heads…") { model.runDriver("verify") }
                    Button("Hardware patterns…") { model.runDriver("patterns") }
                    Button("Control-session diagnostic…") { model.runDriver("diagnose") }
                }
                Text("Hardware operations require Oizys stopped and explicit dock takeover. They do not mark visual confirmation as passed.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
        }.formStyle(.grouped)
    }

    private var console: some View {
        VStack(alignment: .leading) {
            HStack { Button("Save output…") { model.saveOutput() }; Button("Clear") { model.output = "" }; Spacer(); Text("256 KiB visible buffer").foregroundStyle(.secondary) }
            ScrollView { Text(model.output.isEmpty ? "Run a tool to see its output here." : model.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.background(Color.primary.opacity(0.035))
            TextField("Report input folder or file", text: $model.reportInput)
            HStack { Button("Build report from existing logs") { model.report() }.disabled(model.busy); Button("Open input folder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.reportInput)) } }
        }.padding()
    }
}

private struct DevPrivateView: View {
    @ObservedObject var model: DevDiagnostics
    @FocusState private var passphraseFocused: Bool
    private var settingUp: Bool { !model.settingsExist || model.replacingPrivateSettings }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Local fixture").font(.title2.bold()); Spacer(); if model.unlocked { Button("Lock") { model.lockPrivate() } } }
            Form {
                if !model.unlocked {
                    Text(settingUp ? "Choose a new passphrase and enter your source. Use four or more words you can remember." : "Unlock with the passphrase used to save these settings. If you do not have it, choose Set up again.")
                        .font(.callout)
                    SecureField(settingUp ? "New passphrase, at least 16 characters" : "Your passphrase", text: $model.passphrase)
                        .focused($passphraseFocused)
                        .onSubmit { if !settingUp { model.privateAction("unlock") } }
                    if NSEvent.modifierFlags.contains(.capsLock) { Text("Caps Lock is on.").foregroundStyle(.orange) }
                    if !settingUp {
                        HStack {
                            Button("Unlock") { model.privateAction("unlock") }.disabled(model.passphrase.isEmpty)
                            Button("Set up again…") { model.beginPrivateSetup(); passphraseFocused = true }
                        }.disabled(model.busy || model.preparingTools)
                    } else {
                        SecureField("Source profile URL", text: $model.source)
                        SecureField("Repeat new passphrase", text: $model.repeatedPassphrase)
                        HStack {
                            Button("Save and unlock") { model.privateAction(model.replacingPrivateSettings ? "replace" : "init") }
                            if model.replacingPrivateSettings { Button("Cancel") { model.lockPrivate() } }
                        }.disabled(model.busy || model.preparingTools)
                        Text("Nothing changes until you save. Existing encrypted settings are backed up before replacement.").font(.caption)
                    }
                } else {
                    Text("Start with a 30-second windowed run using six clips. Production can keep driving the displays. To test driver edits, start the debug driver in the main window first.").font(.callout)
                    HStack {
                        Button("Run") { model.privateAction("run") }; Button("Check sources only") { model.privateAction("check") }
                    }.disabled(model.busy || model.preparingTools)
                    DisclosureGroup("Workload options") {
                        TextField("Duration, seconds", text: $model.fixtureSeconds)
                        TextField("Candidate pool, 2–96", text: $model.fixtureCount)
                        TextField("Videos per screen, auto or 1–96", text: $model.fixturePerScreen)
                        TextField("Minimum source FPS, 0–240", text: $model.fixtureFPS)
                        Toggle("Cover all screens", isOn: $model.fixtureFull)
                        if !model.fixtureFull { Slider(value: $model.fixtureFraction, in: 0.1...1) { Text("Window fraction \(Int(model.fixtureFraction * 100))%") } }
                        Text("Clips never repeat across screens. Aspect ratios are preserved; slower sources are skipped, never interpolated.").font(.caption)
                    }
                    DisclosureGroup("Change encrypted source") {
                        SecureField("Source profile URL", text: $model.source)
                        Button("Update source") { model.privateAction("source") }.disabled(model.busy)
                    }
                }
                Button("Prepare required tools") { model.preparePrivateDependencies() }.disabled(model.busy || model.preparingTools)
                Text("Tool setup fixes missing dependencies, not an unlock failure. Sources must be accessible without a personal browser session.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            HStack { Text(model.privateStatus); Spacer(); Button("Stop") { model.stop() }.disabled(!model.busy) }
            ScrollView { Text(model.privateOutput).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 100, maxHeight: 170)
            Text("Closing locks this window and stops its job. Secrets travel through stdin, never command arguments or logs. Media stays in memory; OS and browser traces cannot be guaranteed erased.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 580, minHeight: 560)
            .onAppear { passphraseFocused = true }
    }
}
#endif
