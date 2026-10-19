import AppKit
import CoreImage
import CryptoKit
import Network
import Security
import SwiftUI

/*
 * Matching the displays to each other with a phone that has nothing installed on it.
 *
 * The phone is the only measuring instrument most people own, and it is a poor one: iOS
 * Safari exposes no manual exposure and no white-balance lock, so every frame has already
 * been through Apple's tone mapping. What survives that is the *ratio* between two patches
 * captured under the same settings, which is enough to answer "why is the left monitor bluer
 * than the right one" even though it cannot answer "what colour is this monitor".
 *
 * Three things this had to solve to work at all:
 *
 * getUserMedia needs a secure context. Safari grants the camera on HTTPS and localhost and
 * nowhere else, so a page served over plain HTTP on the LAN is refused with no useful error.
 * The listener below therefore speaks TLS with a certificate generated on the spot, and the
 * phone gets a certificate warning. The Mac exposes the certificate's SHA-256 fingerprint;
 * the warning alone cannot establish that the phone reached this Mac.
 *
 * The server is open on the network, so it exists only while a calibration is running,
 * binds one port, uses a one-time QR token and a session-scoped page/reading token,
 * and receives only RGB means. Camera frames stay on the phone.
 *
 * And the readings are handed to the driver rather than solved here. The fit and the solve
 * live in calibrate.c where they are tested; sending the arithmetic across the process
 * boundary would put it somewhere nothing checks it.
 */
final class CalibrationSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waitingForPhone
        case measuring(display: Int, patch: Int, total: Int)
        case solving
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var qr: NSImage?
    @Published private(set) var address = ""
    @Published private(set) var certificateFingerprint = ""
    @Published private(set) var canUndo = false
    private var savedCorrection: SavedCorrection?
    private var correctionURL: URL?
    var isActive: Bool {
        switch phase {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    /// Eight levels. Below the floor the camera's noise and the panel's black level dominate
    /// and the fit gets worse for having them, which is why this starts at an eighth rather
    /// than at zero.
    static let levels: [Double] = (1...8).map { Double($0) / 8 }

    private var listener: NWListener?
    private var tlsKeychain: SecKeychain?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var entryToken = ""
    private var readingToken = ""
    private var used = false
    private var patchWindows: [NSWindow] = []
    private var displays: [CGDirectDisplayID] = []
    private var readings: [String: Double] = [:]
    private var current = 0
    private var currentPatch = 0
    private var sessionID = UUID()
    private var deadline: Timer?
    private var serverOnly = false
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.stop() }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        deadline?.invalidate()
        listener?.cancel()
        for connection in connections.values { connection.cancel() }
        if let tlsKeychain { SecKeychainDelete(tlsKeychain) }
    }

    // MARK: - Lifecycle

    /// Bring up the certificate, listener and page without arming the patch sequence. The
    /// only caller is the command-line check that proves the transport works.
    func startServerOnly(host: String? = nil, identityDirectory: URL? = nil) {
        start(serverOnly: true, host: host, identityDirectory: identityDirectory)
    }

    func start(configPath: String) {
        guard !configPath.isEmpty else {
            phase = .failed("Read the driver settings before starting calibration.")
            return
        }
        correctionURL = URL(fileURLWithPath: configPath).deletingLastPathComponent()
            .appendingPathComponent("calibration.json")
        start(serverOnly: false, host: nil, identityDirectory: nil)
    }

    private func start(serverOnly: Bool, host: String?, identityDirectory: URL?) {
        stop()
        self.serverOnly = serverOnly
        readings.removeAll(); used = false; current = 0; currentPatch = 0
        displays = Self.onlineDisplays()
        guard serverOnly || displays.count >= 2 else {
            phase = .failed("Matching needs at least two displays. Only \(displays.count) is attached.")
            return
        }
        guard let host = host ?? Self.lanAddress() else {
            phase = .failed("This Mac has no LAN address, so the phone has nothing to reach.")
            return
        }
        guard let entry = Self.freshToken(), let session = Self.freshToken(), entry != session else {
            phase = .failed("Could not create secure calibration tokens.")
            return
        }
        entryToken = entry
        readingToken = session
        guard let (identity, fingerprint, keychain) = Self.identity(host: host, directory: identityDirectory) else {
            phase = .failed("Could not create the TLS certificate the phone's camera requires. "
                            + "Check that /usr/bin/openssl exists.")
            return
        }
        certificateFingerprint = fingerprint
        tlsKeychain = keychain
        do {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
            let parameters = NWParameters(tls: options)
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                DispatchQueue.main.async {
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        if let port = listener?.port { self.ready(port: port.rawValue, host: host) }
                    case .failed(let error):
                        self.phase = .failed("The capture server stopped: \(error.localizedDescription)")
                        self.shutdown()
                    default: break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
            phase = .waitingForPhone
        } catch {
            phase = .failed("Could not open the capture server: \(error.localizedDescription)")
            shutdown()
        }
        guard listener != nil else { return }
        // The server must not outlive the sitting, whatever happens to the UI.
        deadline = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.phase = .failed("Timed out. The server is closed; nothing was saved.")
            self.shutdown()
        }
    }

    func stop() {
        sessionID = UUID()
        shutdown()
        phase = .idle
    }

    private func shutdown() {
        deadline?.invalidate(); deadline = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        if let tlsKeychain { SecKeychainDelete(tlsKeychain); self.tlsKeychain = nil }
        entryToken = ""; readingToken = ""; used = true
        clearPatches()
        qr = nil; address = ""; certificateFingerprint = ""
    }

    private func ready(port: UInt16, host: String) {
        let url = "https://\(host):\(port)/\(entryToken)"
        address = url
        qr = Self.qrImage(url)
    }

    // MARK: - HTTP

    enum ParsedRequest: Equatable {
        case incomplete
        case invalid
        case complete(method: String, path: String, body: Data)
    }

    /// Safari normally sends the body in one packet, but TCP is free to split it anywhere.
    /// Limit both sections before retaining more data from a LAN peer.
    static func parseRequest(_ data: Data) -> ParsedRequest {
        guard let divider = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count <= 8192 ? .incomplete : .invalid
        }
        guard divider.lowerBound <= 8192,
              let head = String(data: data[..<divider.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .invalid }
        let requestLine = first.split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3,
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else {
            return .invalid
        }
        let method = String(requestLine[0]), path = String(requestLine[1])
        guard method == "GET" || method == "POST", path.hasPrefix("/") else { return .invalid }
        var contentLength: Int?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding" { return .invalid }
            if name == "content-length" {
                guard contentLength == nil, !value.isEmpty,
                      value.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let length = Int(value), length <= 4096 else { return .invalid }
                contentLength = length
            }
        }
        guard method == "POST" ? contentLength != nil : (contentLength ?? 0) == 0 else {
            return .invalid
        }
        let expected = divider.upperBound + (contentLength ?? 0)
        if data.count < expected { return .incomplete }
        guard data.count == expected else { return .invalid }
        return .complete(method: method, path: path, body: Data(data[divider.upperBound..<expected]))
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 8 else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        var receiving = false
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready where !receiving:
                receiving = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    self?.connections.removeValue(forKey: key)?.cancel()
                }
            case .failed, .cancelled: self?.connections.removeValue(forKey: key)
            default: break
            }
        }
        connection.start(queue: .main)
        receive(connection, data: Data())
        // Certificate confirmation happens before .ready and can take longer than a body read.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            if !receiving { self?.connections.removeValue(forKey: key)?.cancel() }
        }
    }

    private func receive(_ connection: NWConnection, data accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, self.connections[ObjectIdentifier(connection)] != nil else {
                connection.cancel(); return
            }
            if error != nil { self.close(connection); return }
            var request = accumulated
            if let data { request.append(data) }
            switch Self.parseRequest(request) {
            case .incomplete:
                if complete { self.reply(connection, 400, "text/plain", "incomplete request") }
                else { self.receive(connection, data: request) }
            case .invalid:
                self.reply(connection, 400, "text/plain", "bad request")
            case let .complete(method, path, body):
                self.handle(method: method, path: path, body: body, connection: connection)
            }
        }
    }

    private func handle(method: String, path: String, body: Data, connection: NWConnection) {
        if method == "GET", path == "/" + entryToken, !entryToken.isEmpty, !used {
            used = true
            reply(connection, 303, "text/plain", "", location: "/" + readingToken)
        } else if method == "GET", path == "/" + readingToken, !readingToken.isEmpty {
            if case .waitingForPhone = phase, !serverOnly { beginMeasuring() }
            if !serverOnly {
                guard case .measuring = phase else {
                    reply(connection, 410, "text/plain", "session ended"); return
                }
            }
            reply(connection, 200, "text/html; charset=utf-8",
                  Self.page(token: readingToken, display: current, patch: currentPatch))
        } else if method == "POST", path == "/" + readingToken + "/reading",
                  !readingToken.isEmpty {
            guard case .measuring = phase, !serverOnly else {
                reply(connection, 410, "application/json", "{\"ok\":false}"); return
            }
            ingest(body, connection: connection)
        } else {
            reply(connection, 404, "text/plain", "not found")
        }
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
    }

    private func reply(_ connection: NWConnection, _ status: Int, _ type: String, _ body: String,
                       location: String? = nil,
                       onSent: ((Bool) -> Void)? = nil) {
        let payload = Data(body.utf8)
        let reason = [200: "OK", 303: "See Other", 400: "Bad Request",
                      404: "Not Found", 410: "Gone"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\n"
            + (location.map { "Location: \($0)\r\n" } ?? "")
            + "Content-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + payload,
                        completion: .contentProcessed { [weak self] error in
                            DispatchQueue.main.async {
                                self?.close(connection)
                                onSent?(error == nil)
                            }
                        })
    }

    /// One patch's measurement. The page sends means already linearised, because fitting an
    /// exponent through an sRGB curve fits the wrong thing.
    struct Reading: Decodable {
        let display: Int
        let patch: Int
        let r: Double
        let g: Double
        let b: Double
    }

    static func decodeReading(_ data: Data, display: Int, patch: Int) -> Reading? {
        guard let reading = try? JSONDecoder().decode(Reading.self, from: data),
              reading.display == display, reading.patch == patch,
              [reading.r, reading.g, reading.b].allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { return nil }
        return reading
    }

    private func ingest(_ body: Data, connection: NWConnection) {
        guard current < displays.count,
              let reading = Self.decodeReading(body, display: current, patch: currentPatch) else {
            reply(connection, 400, "application/json", "{\"ok\":false}")
            return
        }
        let prefix = "display.\(reading.display).patch.\(reading.patch)"
        readings["\(prefix).input"] = Self.levels[reading.patch]
        readings["\(prefix).r"] = reading.r
        readings["\(prefix).g"] = reading.g
        readings["\(prefix).b"] = reading.b
        readings["display.\(reading.display).head"] = Double(headIndex(displays[reading.display]))

        let next = reading.patch + 1
        if next < Self.levels.count {
            currentPatch = next
            present(display: reading.display, level: Self.levels[next])
            phase = .measuring(display: reading.display, patch: next, total: Self.levels.count)
            reply(connection, 200, "application/json", "{\"ok\":true,\"next\":\(next)}")
        } else if reading.display + 1 < displays.count {
            current = reading.display + 1
            currentPatch = 0
            present(display: current, level: Self.levels[0])
            phase = .measuring(display: current, patch: 0, total: Self.levels.count)
            reply(connection, 200, "application/json",
                  "{\"ok\":true,\"nextDisplay\":\(current),\"next\":0}")
        } else {
            phase = .solving
            clearPatches()
            reply(connection, 200, "application/json", "{\"ok\":true,\"done\":true}") { [weak self] sent in
                guard let self, case .solving = self.phase else { return }
                if sent { self.solve() }
                else {
                    self.phase = .failed("The phone disconnected before the final reading was confirmed.")
                    self.shutdown()
                }
            }
        }
    }

    // MARK: - Patches

    private func beginMeasuring() {
        current = 0; currentPatch = 0
        present(display: 0, level: Self.levels[0])
        phase = .measuring(display: 0, patch: 0, total: Self.levels.count)
    }

    /// A full-screen neutral patch on one display, and black on the others so nothing else
    /// spills light onto the panel being measured.
    private func present(display index: Int, level: Double) {
        clearPatches()
        for (position, id) in displays.enumerated() {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }) else { continue }
            // The level is displayed sRGB-encoded, because that is what a desktop sends and
            // therefore what the correction has to sit in front of.
            let value = position == index ? level : 0
            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = true
            panel.backgroundColor = NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
            panel.level = .screenSaver
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            patchWindows.append(panel)
        }
    }

    private func clearPatches() {
        for window in patchWindows { window.orderOut(nil) }
        patchWindows.removeAll()
    }

    /// Which head a display is, or -1. Only heads Oizys drives can be corrected, because the
    /// correction is applied in its encoder.
    private func headIndex(_ id: CGDirectDisplayID) -> Int {
        guard CGDisplayVendorNumber(id) == 0x4d56 else { return -1 }
        switch CGDisplaySerialNumber(id) {
        case 0x4d560001: return 0
        case 0x4d560002: return 1
        default: return -1
        }
    }

    // MARK: - Solving

    private func solve() {
        // The dimmest display is the reference: matching can only darken, so anything else
        // pulls the whole desk down to meet it.
        if let dimmest = dimmestDisplayIndex() { readings["reference"] = Double(dimmest) }
        let measurements = readings
        let driver = Bundle.main.url(forAuxiliaryExecutable: "OizysDriver")
        guard let driver, let correctionURL else {
            shutdown()
            phase = .failed("The bundled driver or settings path is missing.")
            return
        }
        solve(measurements: measurements, driver: driver, correctionURL: correctionURL)
    }

    func solve(measurements: [String: Double], driver: URL, correctionURL: URL) {
        sessionID = UUID()
        let run = sessionID
        phase = .solving
        shutdown()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.solve(measurements: measurements, driver: driver)
            DispatchQueue.main.async {
                guard let self, self.sessionID == run, case .solving = self.phase else { return }
                switch result {
                case let .success(text, data):
                    do {
                        self.savedCorrection = try SavedCorrection.save(data, at: correctionURL)
                        self.canUndo = true
                        self.phase = .done(text)
                    } catch { self.phase = .failed("Could not save the correction: \(error.localizedDescription)") }
                case let .failure(text): self.phase = .failed(text)
                }
            }
        }
    }

    enum Solution {
        case success(String, Data)
        case failure(String)
    }

    /// The solver writes only inside this temporary directory. Cancelling a session can
    /// discard its result without letting the child change the active correction.
    static func solve(measurements: [String: Double], driver: URL) -> Solution {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oizys-solve-\(UUID().uuidString)")
        let file = folder.appendingPathComponent("readings.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys])
            try data.write(to: file, options: .atomic)
        } catch {
            return .failure("Could not write the measurements: \(error.localizedDescription)")
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = driver
        process.arguments = ["calibrate", "run", file.path]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["OIZYS_CONFIG_PATH": folder.appendingPathComponent("config.json").path]) { _, new in new }
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch {
            return .failure("Could not run the solver: \(error.localizedDescription)")
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 11) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .failure(output.isEmpty ? "The calibration solver failed or timed out." : output)
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("calibration.json")) else {
            return .failure("The solver did not produce a correction.")
        }
        return .success(output, data)
    }

    struct SavedCorrection {
        let url: URL
        let previous: Data?
        let saved: Data

        static func save(_ data: Data, at url: URL) throws -> SavedCorrection {
            let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            return SavedCorrection(url: url, previous: previous, saved: data)
        }

        func restore() throws {
            guard try Data(contentsOf: url) == saved else {
                throw NSError(domain: "OizysCalibration", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The correction changed since this calibration. Undo would overwrite that change."])
            }
            if let previous { try previous.write(to: url, options: .atomic) }
            else { try FileManager.default.removeItem(at: url) }
        }
    }

    func undo() {
        guard !isActive, let savedCorrection else { return }
        do {
            try savedCorrection.restore()
            self.savedCorrection = nil
            canUndo = false
            phase = .done("The previous correction has been restored.")
        } catch { phase = .failed("Could not undo calibration: \(error.localizedDescription)") }
    }

    private func dimmestDisplayIndex() -> Int? {
        var best: (index: Int, white: Double)?
        for index in displays.indices {
            let top = Self.levels.count - 1
            guard let r = readings["display.\(index).patch.\(top).r"],
                  let g = readings["display.\(index).patch.\(top).g"],
                  let b = readings["display.\(index).patch.\(top).b"] else { continue }
            let white = (r + g + b) / 3
            if best == nil || white < best!.white { best = (index, white) }
        }
        return best?.index
    }

    // MARK: - Plumbing

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func freshToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The first non-loopback IPv4 address. A phone needs something it can route to.
    private static func lanAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidate: String?
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = interface.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            let name = String(cString: interface.pointee.ifa_name)
            // Wi-Fi first: the phone is almost certainly on it, and a dock's Ethernet address
            // is often on a segment the phone cannot reach.
            if name.hasPrefix("en0") { return text }
            if candidate == nil { candidate = text }
        }
        return candidate
    }

    /// Keep the self-signed identity across sessions so the fingerprint stays stable until
    /// the certificate is replaced.
    private static func identity(host: String, directory: URL?) -> (sec_identity_t, String, SecKeychain)? {
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oizys", isDirectory: true)
        let p12 = support.appendingPathComponent("calibration-identity.p12")
        let hostFile = support.appendingPathComponent("calibration-identity-host")
        let password = "oizys"
        let modified = (try? FileManager.default.attributesOfItem(atPath: p12.path))?[.modificationDate] as? Date
        let expiresSoon = modified.map { Date().timeIntervalSince($0) >= 364 * 86400 } ?? true
        if !FileManager.default.fileExists(atPath: p12.path)
            || (try? String(contentsOf: hostFile, encoding: .utf8)) != host || expiresSoon {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let key = support.appendingPathComponent("calibration-key.pem")
            let cert = support.appendingPathComponent("calibration-cert.pem")
            let candidate = support.appendingPathComponent("calibration-new.p12")
            defer {
                try? FileManager.default.removeItem(at: key)
                try? FileManager.default.removeItem(at: cert)
                try? FileManager.default.removeItem(at: candidate)
            }
            // macOS has no public API for minting a self-signed X.509, and LibreSSL ships with
            // the system, so this is the shortest correct route rather than a dependency.
            guard run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048",
                                           "-keyout", key.path, "-out", cert.path,
                                           "-days", "365", "-nodes", "-subj", "/CN=Oizys",
                                           "-addext", "subjectAltName=IP:\(host),IP:127.0.0.1",
                                           "-addext", "extendedKeyUsage=serverAuth"]) == 0,
                  run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key.path,
                                           "-in", cert.path, "-out", candidate.path,
                                           "-passout", "pass:" + password]) == 0,
                  let candidateData = try? Data(contentsOf: candidate),
                  (try? candidateData.write(to: p12, options: .atomic)) != nil,
                  (try? Data(host.utf8).write(to: hostFile, options: .atomic)) != nil
            else { return nil }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
        }
        guard let data = try? Data(contentsOf: p12) else { return nil }
        // SecPKCS12Import stores macOS identities in the default keychain, whose ACL can
        // stall TLS after an ad hoc build changes its signing identity. Give this sitting a
        // private keychain whose access trusts this app, then delete it when the server ends.
        let keychainPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("oizys-calibration-\(UUID().uuidString).keychain-db").path
        guard let keychainPassword = freshToken() else { return nil }
        var keychain: SecKeychain?
        let createStatus = keychainPassword.withCString { pointer in
            SecKeychainCreate(keychainPath, UInt32(strlen(pointer)), pointer, false, nil, &keychain)
        }
        guard createStatus == errSecSuccess, let keychain else { return nil }
        var keepKeychain = false
        defer { if !keepKeychain { SecKeychainDelete(keychain) } }
        var access: SecAccess?
        guard SecAccessCreate("Oizys calibration" as CFString, nil, &access) == errSecSuccess,
              let access else { return nil }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password,
                       kSecImportExportKeychain as String: keychain,
                       kSecImportExportAccess as String: access] as CFDictionary
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let entries = items as? [[String: Any]],
              let raw = entries.first?[kSecImportItemIdentity as String] else { return nil }
        let identity = raw as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { return nil }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        let fingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        guard let tlsIdentity = sec_identity_create(identity) else { return nil }
        keepKeychain = true
        return (tlsIdentity, fingerprint, keychain)
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return 1 }
    }

    private static func qrImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 240, height: 240))
    }

    /// The capture page. Inline, with no network of its own: the only thing it talks to is
    /// the listener that served it.
    static func page(token: String, display: Int = 0, patch: Int = 0) -> String {
        """
        <!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
        <title>Oizys calibration</title>
        <style>
          body{margin:0;background:#0a0a0b;color:#eee;font:15px -apple-system,system-ui;
               display:flex;flex-direction:column;align-items:center;gap:12px;padding:16px}
          video{width:100%;max-width:420px;border-radius:10px;background:#000}
          #s{font-size:13px;color:#9a9a9a;text-align:center;min-height:3em}
          button{font:600 15px -apple-system;padding:12px 22px;border-radius:9px;border:0;
                 background:#eee;color:#111}
          #box{position:relative;width:100%;max-width:420px}
          #ret{position:absolute;inset:30% 35%;border:2px solid #fff8;border-radius:6px}
        </style>
        <h3>Oizys calibration</h3>
        <div id=box><video id=v playsinline autoplay muted></video><div id=ret></div></div>
        <div id=s>Allow the camera, point the box at the monitor Oizys is lighting up, and hold still.</div>
        <button id=go>Start</button>
        <canvas id=c hidden></canvas>
        <script>
        const V=document.getElementById('v'),S=document.getElementById('s'),C=document.getElementById('c');
        let display=DISPLAY,patch=PATCH;
        let running=false;
        // sRGB to linear. Fitting an exponent through the encoding curve fits the curve, not
        // the panel, so this has to happen before anything is sent.
        const lin=v=>{v/=255;return v<=0.04045?v/12.92:Math.pow((v+0.055)/1.055,2.4)};
        async function open(){
          try{
            V.srcObject=await navigator.mediaDevices.getUserMedia(
              {video:{facingMode:'environment',width:{ideal:1280}}});
            S.textContent='Camera ready. Fill the box with the monitor, then press Start.';
          }catch(e){S.textContent='The camera was refused. Reload and allow it, or check the certificate warning was accepted.';}
        }
        function sample(){
          const w=V.videoWidth,h=V.videoHeight;
          if(!w){return null}
          // Only the middle of the frame: the edges catch bezel, desk and reflections.
          const x=Math.floor(w*0.35),y=Math.floor(h*0.30),sw=Math.floor(w*0.30),sh=Math.floor(h*0.40);
          if(!sw||!sh){return null}
          C.width=sw;C.height=sh;
          const g=C.getContext('2d',{willReadFrequently:true});
          g.drawImage(V,x,y,sw,sh,0,0,sw,sh);
          const d=g.getImageData(0,0,sw,sh).data;
          let r=0,gr=0,b=0,n=0;
          for(let i=0;i<d.length;i+=4){r+=lin(d[i]);gr+=lin(d[i+1]);b+=lin(d[i+2]);n++}
          return {r:r/n,g:gr/n,b:b/n};
        }
        function closeCamera(){V.srcObject?.getTracks().forEach(track=>track.stop())}
        async function step(){
          // Two frames' grace after each patch change, so the camera's own auto-exposure has
          // settled before anything is measured.
          await new Promise(r=>setTimeout(r,900));
          const m=sample();
          if(!m){S.textContent='No camera frames yet.';running=false;return}
          try{
            const res=await fetch('/TOKEN/reading',{method:'POST',
              body:JSON.stringify({display,patch,r:m.r,g:m.g,b:m.b})});
            const j=await res.json();
            if(!res.ok||!j.ok){
              S.textContent=res.status===410?'The Mac ended this session. Start again there.':'That reading was refused.';
              running=false;if(res.status===410)closeCamera();return}
            if(j.done){S.textContent='Done. Look back at the Mac.';running=false;closeCamera();return}
            if(j.nextDisplay!==undefined){display=j.nextDisplay;
              S.textContent='Now point at the next monitor Oizys is lighting up.';
              await new Promise(r=>setTimeout(r,2500));}
            patch=j.next;
            S.textContent='Measuring '+(patch+1)+' of 8 on monitor '+(display+1)+'. Hold still.';
            step();
          }catch(e){S.textContent='Connection closed. Start again on the Mac.';
            running=false;closeCamera()}
        }
        document.getElementById('go').onclick=()=>{if(running)return;running=true;
          S.textContent='Measuring. Hold still.';step()};
        open();
        </script>
        """.replacingOccurrences(of: "/TOKEN/", with: "/\(token)/")
            .replacingOccurrences(of: "DISPLAY", with: "\(display)")
            .replacingOccurrences(of: "PATCH", with: "\(patch)")
    }
}
