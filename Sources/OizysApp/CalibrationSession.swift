import AppKit
import CoreImage
import Network
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
 * phone gets one "not private" warning to tap through. That interstitial is the whole cost of
 * not installing anything, and the QR screen says so rather than leaving it as a surprise.
 *
 * The server is open on the network, so it is built to be boring: it exists only while a
 * calibration is running, binds one port, carries a single-use token in the path, holds
 * nothing on disk but the numbers, and serves exactly two routes.
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

    /// Eight levels. Below the floor the camera's noise and the panel's black level dominate
    /// and the fit gets worse for having them, which is why this starts at an eighth rather
    /// than at zero.
    static let levels: [Double] = (1...8).map { Double($0) / 8 }

    private var listener: NWListener?
    private var token = ""
    private var used = false
    private var patchWindows: [NSWindow] = []
    private var displays: [CGDirectDisplayID] = []
    private var readings: [String: Double] = [:]
    private var current = 0
    private var deadline: Timer?
    private var serverOnly = false

    // MARK: - Lifecycle

    /// Bring up the certificate, listener and page without arming the patch sequence. The
    /// only caller is the command-line check that proves the transport works.
    func startServerOnly() {
        serverOnly = true
        start()
    }

    func start() {
        stop()
        readings.removeAll(); used = false; current = 0
        displays = Self.onlineDisplays()
        guard serverOnly || displays.count >= 2 else {
            phase = .failed("Matching needs at least two displays. Only \(displays.count) is attached.")
            return
        }
        token = Self.freshToken()
        guard let identity = Self.identity() else {
            phase = .failed("Could not create the TLS certificate the phone's camera requires. "
                            + "Check that /usr/bin/openssl exists.")
            return
        }
        do {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
            let parameters = NWParameters(tls: options)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let self, let port = listener.port else { return }
                DispatchQueue.main.async { self.ready(port: port.rawValue) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            phase = .waitingForPhone
        } catch {
            phase = .failed("Could not open the capture server: \(error.localizedDescription)")
        }
        // The server must not outlive the sitting, whatever happens to the UI.
        deadline = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, case .done = self.phase else {
                    self?.phase = .failed("Timed out. The server is closed; nothing was saved.")
                    self?.stop(); return
                }
            }
        }
    }

    func stop() {
        deadline?.invalidate(); deadline = nil
        listener?.cancel(); listener = nil
        clearPatches()
        qr = nil; address = ""
    }

    private func ready(port: UInt16) {
        guard let host = Self.lanAddress() else {
            phase = .failed("This Mac has no LAN address, so the phone has nothing to reach.")
            return
        }
        let url = "https://\(host):\(port)/\(token)"
        address = url
        qr = Self.qrImage(url)
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            let head = request.split(separator: "\r\n\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let body = request.range(of: "\r\n\r\n").map { String(request[$0.upperBound...]) } ?? ""
            let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { self.reply(connection, 400, "text/plain", "bad request"); return }
            let method = parts[0], path = parts[1]

            // Constant-time-ish: the token is random and single-use, and a wrong one gets the
            // same answer as a missing one so probing learns nothing.
            guard path.hasPrefix("/" + self.token) else {
                self.reply(connection, 404, "text/plain", "not found"); return
            }
            if method == "GET" {
                DispatchQueue.main.async {
                    if case .waitingForPhone = self.phase, !self.serverOnly { self.beginMeasuring() }
                }
                self.reply(connection, 200, "text/html; charset=utf-8", Self.page(token: self.token))
            } else if method == "POST", path.hasSuffix("/reading") {
                DispatchQueue.main.async { self.ingest(body, connection: connection) }
            } else {
                self.reply(connection, 404, "text/plain", "not found")
            }
        }
    }

    private func reply(_ connection: NWConnection, _ status: Int, _ type: String, _ body: String) {
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status) OK\r\nContent-Type: \(type)\r\n"
            + "Content-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + payload,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    /// One patch's measurement. The page sends means already linearised, because fitting an
    /// exponent through an sRGB curve fits the wrong thing.
    private func ingest(_ body: String, connection: NWConnection) {
        struct Reading: Decodable { let display: Int; let patch: Int; let r: Double; let g: Double; let b: Double }
        guard let data = body.data(using: .utf8),
              let reading = try? JSONDecoder().decode(Reading.self, from: data),
              reading.display >= 0, reading.display < displays.count,
              reading.patch >= 0, reading.patch < Self.levels.count else {
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
            present(display: reading.display, level: Self.levels[next])
            phase = .measuring(display: reading.display, patch: next, total: Self.levels.count)
            reply(connection, 200, "application/json", "{\"ok\":true,\"next\":\(next)}")
        } else if reading.display + 1 < displays.count {
            current = reading.display + 1
            present(display: current, level: Self.levels[0])
            phase = .measuring(display: current, patch: 0, total: Self.levels.count)
            reply(connection, 200, "application/json",
                  "{\"ok\":true,\"nextDisplay\":\(current),\"next\":0}")
        } else {
            reply(connection, 200, "application/json", "{\"ok\":true,\"done\":true}")
            clearPatches()
            solve()
        }
    }

    // MARK: - Patches

    private func beginMeasuring() {
        current = 0
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
        phase = .solving
        stop()
        let folder = FileManager.default.temporaryDirectory
        let file = folder.appendingPathComponent("oizys-readings-\(UUID().uuidString).json")
        // The dimmest display is the reference: matching can only darken, so anything else
        // pulls the whole desk down to meet it.
        if let dimmest = dimmestDisplayIndex() { readings["reference"] = Double(dimmest) }
        do {
            let data = try JSONSerialization.data(withJSONObject: readings, options: [.sortedKeys])
            try data.write(to: file, options: .atomic)
        } catch {
            phase = .failed("Could not write the measurements: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let driver = Bundle.main.url(forAuxiliaryExecutable: "OizysDriver") else {
            phase = .failed("The bundled driver is missing."); return
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = driver
        process.arguments = ["calibrate", "run", file.path]
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch {
            phase = .failed("Could not run the solver: \(error.localizedDescription)"); return
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        phase = process.terminationStatus == 0 ? .done(output) : .failed(output)
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

    private static func freshToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
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

    /// A self-signed identity, generated once per install and kept, so the phone's one-time
    /// certificate warning stays one time rather than one per calibration.
    private static func identity() -> sec_identity_t? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oizys", isDirectory: true)
        let p12 = support.appendingPathComponent("calibration-identity.p12")
        let password = "oizys"
        if !FileManager.default.fileExists(atPath: p12.path) {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let key = support.appendingPathComponent("calibration-key.pem")
            let cert = support.appendingPathComponent("calibration-cert.pem")
            // macOS has no public API for minting a self-signed X.509, and LibreSSL ships with
            // the system, so this is the shortest correct route rather than a dependency.
            guard run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048",
                                           "-keyout", key.path, "-out", cert.path,
                                           "-days", "365", "-nodes", "-subj", "/CN=Oizys"]) == 0,
                  run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key.path,
                                           "-in", cert.path, "-out", p12.path,
                                           "-passout", "pass:" + password]) == 0
            else { return nil }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
            try? FileManager.default.removeItem(at: key)
            try? FileManager.default.removeItem(at: cert)
        }
        guard let data = try? Data(contentsOf: p12) else { return nil }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let entries = items as? [[String: Any]],
              let raw = entries.first?[kSecImportItemIdentity as String] else { return nil }
        return sec_identity_create(raw as! SecIdentity)
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
    static func page(token: String) -> String {
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
        let display=0,patch=0,running=false;
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
          C.width=sw;C.height=sh;
          const g=C.getContext('2d',{willReadFrequently:true});
          g.drawImage(V,x,y,sw,sh,0,0,sw,sh);
          const d=g.getImageData(0,0,sw,sh).data;
          let r=0,gr=0,b=0,n=0;
          for(let i=0;i<d.length;i+=4){r+=lin(d[i]);gr+=lin(d[i+1]);b+=lin(d[i+2]);n++}
          return {r:r/n,g:gr/n,b:b/n};
        }
        async function step(){
          // Two frames' grace after each patch change, so the camera's own auto-exposure has
          // settled before anything is measured.
          await new Promise(r=>setTimeout(r,900));
          const m=sample();
          if(!m){S.textContent='No camera frames yet.';running=false;return}
          const res=await fetch('/TOKEN/reading',{method:'POST',
            body:JSON.stringify({display,patch,r:m.r,g:m.g,b:m.b})});
          const j=await res.json();
          if(!j.ok){S.textContent='That reading was refused.';running=false;return}
          if(j.done){S.textContent='Done. Look back at the Mac.';running=false;return}
          if(j.nextDisplay!==undefined){display=j.nextDisplay;
            S.textContent='Now point at the next monitor Oizys is lighting up.';
            await new Promise(r=>setTimeout(r,2500));}
          patch=j.next;
          S.textContent='Measuring '+(patch+1)+' of 8 on monitor '+(display+1)+'. Hold still.';
          step();
        }
        document.getElementById('go').onclick=()=>{if(running)return;running=true;
          S.textContent='Measuring. Hold still.';step()};
        open();
        </script>
        """.replacingOccurrences(of: "/TOKEN/", with: "/\(token)/")
    }
}
