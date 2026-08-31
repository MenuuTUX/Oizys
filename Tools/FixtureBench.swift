#if !OIZYS_FIXTURE_DEBUG || OIZYS_PRODUCTION
#error("FixtureBench is a local debug tool and must not be built into Oizys products.")
#endif

import AppKit
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers
import WebKit
import Darwin

struct Request: Decodable {
    struct Clip: Decodable {
        let id: String?
        let url: URL?
        let source: URL?
        let fallback: URL?
        let headers: [String: String]?
    }
    let mode: String
    let key: Data?
    let data: Data?
    let clips: [Clip]?
    let seconds: Double?
    let full: Bool?
    let fraction: Double?
    let check: Bool?
    let videosPerScreen: Int?
    let minFPS: Double?
    let layoutSizes: [Dimensions]?
    let screenSizes: [Dimensions]?
    let resolver: String?
}

enum FixtureError: Error { case invalid, tooLarge, unreadable, unavailable }
let mediaLimit = 64 * 1024 * 1024
let totalLimit = 512 * 1024 * 1024

struct Dimensions: Codable {
    let width: Double
    let height: Double
    var size: CGSize { CGSize(width: width, height: height) }
}

struct GridPlan: Codable {
    var indices: [Int] = []
    var columns = 1
    var rows = 1
}

func gridPlans(sizes: [CGSize], screens: [CGSize], limit: Int) -> [GridPlan] {
    guard !screens.isEmpty else { return [] }
    var plans = screens.map { _ in GridPlan() }
    // The video index never wraps. Each source is assigned exactly once, spread
    // evenly across monitors; excess capacity stays empty instead of repeating.
    for index in sizes.indices {
        let monitor = index % screens.count
        if limit > 0 && plans[monitor].indices.count >= limit { break }
        plans[monitor].indices.append(index)
    }
    for monitor in screens.indices {
        let indices = plans[monitor].indices
        guard !indices.isEmpty else { continue }
        var bestArea: CGFloat = -1
        var bestEmpty = Int.max
        for columns in 1...indices.count {
            let rows = (indices.count + columns - 1) / columns
            let area = indices.enumerated().reduce(CGFloat.zero) { total, item in
                let (offset, index) = item
                let rowCount = min(columns, indices.count - (offset / columns) * columns)
                let cell = CGSize(width: screens[monitor].width / CGFloat(rowCount),
                                  height: screens[monitor].height / CGFloat(rows))
                let size = sizes[index]
                let scale = min(cell.width / size.width, cell.height / size.height)
                return total + size.width * size.height * scale * scale
            }
            let empty = columns * rows - indices.count
            if area > bestArea + 0.01 || (abs(area - bestArea) <= 0.01 && empty < bestEmpty) {
                bestArea = area
                bestEmpty = empty
                plans[monitor].columns = columns
                plans[monitor].rows = rows
            }
        }
    }
    return plans
}

func allowedMediaURL(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil,
          url.port == nil || url.port == 443, let host = url.host else { return false }
    return ["cdninstagram.com", "fbcdn.net", "tiktok.com", "tiktokcdn.com"].contains {
        host == $0 || host.hasSuffix("." + $0)
    }
}

// TikTok's selected URL may require the downloader's transient session. Read its
// stdout directly; no media paths, cookie exports, or shell commands are involved.
final class SourceStream {
    let process = Process()
    let output = Pipe()

    func start(_ source: URL, executable: String, minimumFPS: Double) throws {
        guard source.scheme == "https", source.host == "www.tiktok.com",
              source.user == nil, source.password == nil, source.query == nil,
              source.fragment == nil, source.port == nil,
              source.path.range(of: "^/@[A-Za-z0-9_.]+/video/[0-9]+$", options: .regularExpression) != nil,
              URL(fileURLWithPath: executable).lastPathComponent == "yt-dlp"
        else { throw FixtureError.invalid }
        process.executableURL = URL(fileURLWithPath: executable)
        let format = minimumFPS > 0
            ? "bestvideo[fps>=\(minimumFPS - 0.1)]/best[fps>=\(minimumFPS - 0.1)]/bestvideo/best"
            : "bestvideo/best"
        process.arguments = ["--ignore-config", "--no-cache-dir", "--no-plugin-dirs",
            "--quiet", "--no-progress", "--no-warnings", "--no-playlist",
            "--socket-timeout", "15", "--retries", "0", "-f", format,
            "-o", "-", "--batch-file", "-"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data((source.absoluteString + "\n").utf8))
        try input.fileHandleForWriting.close()
    }

    func read() async throws -> Data {
        let handle = output.fileHandleForReading
        let bytes = try await Task.detached {
            var data = Data()
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                guard data.count + chunk.count <= mediaLimit else { throw FixtureError.tooLarge }
                data.append(chunk)
            }
            return data
        }.value
        process.waitUntilExit()
        guard process.terminationStatus == 0, !bytes.isEmpty else { throw FixtureError.unavailable }
        return bytes
    }

    func stop() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? output.fileHandleForReading.close()
    }
}

func stopRun() {
    NSApp.stop(nil)
    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0,
        data1: 0, data2: 0) {
        NSApp.postEvent(event, atStart: true)
    }
}

func interruptRun() {
    (NSApp.delegate as? FixtureBench)?.result = 130
    stopRun()
}

// An ephemeral URLSession plus a byte limit avoids files, cookies and URL caches.
// The OS can still swap memory. This is not a promise of forensic erasure.
final class Fetch: NSObject, URLSessionDataDelegate {
    var bytes = Data()
    var continuation: CheckedContinuation<Data, Error>?
    var session: URLSession?

    func load(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        guard allowedMediaURL(url) else { throw FixtureError.invalid }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration, delegate: self,
                                     delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            for (key, value) in headers where ["user-agent", "referer"].contains(key.lowercased()) {
                guard !value.contains("\r"), !value.contains("\n") else { continue }
                request.setValue(value, forHTTPHeaderField: key)
            }
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= mediaLimit else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // TikTok can redirect between its CDN hosts; never leave the allowlist.
        completionHandler(request.url.map(allowedMediaURL) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= mediaLimit else {
            dataTask.cancel()
            return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if error != nil || bytes.isEmpty {
            continuation?.resume(throwing: FixtureError.unavailable)
        } else {
            continuation?.resume(returning: bytes)
        }
        continuation = nil
        bytes = Data()
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}

// AVFoundation seeks within these original compressed bytes. There is no transcoder,
// temporary movie file, local HTTP server, or persistent AVAsset download task.
final class MemoryMovie: NSObject, AVAssetResourceLoaderDelegate {
    let bytes: Data
    let asset: AVURLAsset
    let queue = DispatchQueue(label: "fixture.asset")
    var size = CGSize.zero
    var fps: Float = 0
    var duration: Double = 0

    init(_ data: Data) {
        bytes = data
        asset = AVURLAsset(url: URL(string: "fixture://\(UUID().uuidString)/clip.mp4")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func inspect() async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first
        else { throw FixtureError.unreadable }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayed = CGRect(origin: .zero, size: natural).applying(transform)
        size = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        fps = try await track.load(.nominalFrameRate)
        duration = try await asset.load(.duration).seconds
        guard size.width > 0, size.height > 0, duration.isFinite, duration > 0,
              fps.isFinite, fps > 0 else { throw FixtureError.unreadable }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = UTType.mpeg4Movie.identifier
            info.contentLength = Int64(bytes.count)
            info.isByteRangeAccessSupported = true
        }
        if let data = request.dataRequest {
            let offset = max(data.requestedOffset, data.currentOffset)
            guard offset >= 0, offset <= Int64(bytes.count) else {
                request.finishLoading(with: FixtureError.invalid)
                return true
            }
            let start = Int(offset)
            let end = data.requestsAllDataToEndOfResource ? bytes.count
                : min(bytes.count, Int(data.requestedOffset) + data.requestedLength)
            if end > start { data.respond(with: bytes.subdata(in: start..<end)) }
        }
        request.finishLoading()
        return true
    }
}

final class FixtureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.modifierFlags.contains(.control) && event.keyCode == 8) {
            interruptRun()
        }
        else { super.keyDown(with: event) }
    }
}

// WebKit can decode the source's full-resolution VP9 streams on systems where
// AVPlayer rejects the same MP4. The web content only sees our in-memory scheme,
// never Instagram pages, signed CDN URLs, cookies, or remote JavaScript.
final class MediaScheme: NSObject, WKURLSchemeHandler {
    var movies: [MemoryMovie]
    let namespace = UUID().uuidString.lowercased()
    init(_ movies: [MemoryMovie]) { self.movies = movies }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == namespace,
              let index = Int(url.deletingPathExtension().lastPathComponent),
              movies.indices.contains(index) else {
            task.didFailWithError(FixtureError.invalid)
            return
        }
        let bytes = movies[index].bytes
        var start = 0, end = bytes.count - 1
        let range = task.request.value(forHTTPHeaderField: "Range")
        if let range = range {
            let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard range.hasPrefix("bytes="), parts.count == 2 else {
                task.didFailWithError(FixtureError.invalid)
                return
            }
            if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 {
                start = max(0, bytes.count - suffix)
            } else if let lower = Int(parts[0]) {
                start = lower
                if !parts[1].isEmpty {
                    guard let upper = Int(parts[1]) else {
                        task.didFailWithError(FixtureError.invalid)
                        return
                    }
                    end = min(end, upper)
                }
            } else {
                task.didFailWithError(FixtureError.invalid)
                return
            }
        }
        guard start >= 0, end >= start, end < bytes.count else {
            task.didFailWithError(FixtureError.invalid)
            return
        }
        var headers = ["Content-Type": "video/mp4", "Accept-Ranges": "bytes",
                       "Content-Length": "\(end - start + 1)", "Cache-Control": "no-store"]
        if range != nil { headers["Content-Range"] = "bytes \(start)-\(end)/\(bytes.count)" }
        task.didReceive(HTTPURLResponse(url: url, statusCode: range == nil ? 200 : 206,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(bytes.subdata(in: start..<(end + 1)))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class FixtureWebView: WKWebView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class Playback {
    let web: WKWebView
    let source: MediaScheme
    let count: Int
    var sawFrames = false

    init(_ movies: [MemoryMovie], size: CGSize, plan: GridPlan, store: WKWebsiteDataStore) {
        source = MediaScheme(movies)
        count = movies.count
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(source, forURLScheme: "fixture")
        web = FixtureWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        let rows = stride(from: 0, to: movies.count, by: plan.columns).map { start in
            let tiles = (start..<min(start + plan.columns, movies.count)).map {
                "<div class='tile'><canvas aria-hidden='true'></canvas>"
                    + "<video src='fixture://\(source.namespace)/\($0).mp4' autoplay muted loop playsinline></video></div>"
            }.joined()
            return "<div class='row'>\(tiles)</div>"
        }.joined()
        let nonce = UUID().uuidString
        web.loadHTMLString("""
            <!doctype html><html><head><meta name='viewport' content='width=device-width'>
            <meta http-equiv='Content-Security-Policy' content="default-src 'none'; media-src fixture:; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'">
            <style>html,body{margin:0;width:100%;height:100%;background:#252b36;overflow:hidden}
            body{display:flex;flex-direction:column}
            .row{display:flex;flex:1;min-height:0}
            .tile{position:relative;flex:1;min-width:0;overflow:hidden;isolation:isolate;background:#252b36}
            canvas{position:absolute;inset:-24px;width:calc(100% + 48px);height:calc(100% + 48px);object-fit:cover;filter:blur(16px);pointer-events:none;opacity:0}
            video{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;pointer-events:none;opacity:0}
            canvas[data-frames],canvas[data-frames]+video{opacity:1}</style>
            </head><body>\(rows)
            <script nonce='\(nonce)'>
            // One decoder per unique clip. A small canvas reuses its frames for
            // the blurred backdrop; the foreground retains its native cadence.
            const stops = [];
            document.querySelectorAll('video').forEach(video => {
                const canvas = video.previousElementSibling;
                const context = canvas.getContext('2d', {alpha:false});
                let last = -Infinity, token = 0, stopped = false;
                const native = typeof video.requestVideoFrameCallback === 'function';
                function draw(now) {
                    if (stopped) return;
                    if (video.readyState >= 2 && video.videoWidth && now - last >= 1000 / 15) {
                        const scale = Math.min(1, 256 / Math.max(video.videoWidth, video.videoHeight));
                        const width = Math.max(1, Math.round(video.videoWidth * scale));
                        const height = Math.max(1, Math.round(video.videoHeight * scale));
                        if (canvas.width !== width || canvas.height !== height) {
                            canvas.width = width; canvas.height = height;
                        }
                        context.drawImage(video, 0, 0, width, height);
                        canvas.dataset.frames = String(Number(canvas.dataset.frames || 0) + 1);
                        last = now;
                    }
                    token = native ? video.requestVideoFrameCallback(draw) : requestAnimationFrame(draw);
                }
                stops.push(() => {
                    stopped = true;
                    if (native) video.cancelVideoFrameCallback(token); else cancelAnimationFrame(token);
                    canvas.width = canvas.height = 1;
                });
                draw(performance.now());
            });
            window.stopBackdrops = () => stops.forEach(stop => stop());
            </script></body></html>
            """, baseURL: nil)
    }

    func poll(_ completion: @escaping (Int, Bool) -> Void) {
        web.evaluateJavaScript("""
            [...document.querySelectorAll('video')].map(v=>({
                ready:v.readyState>=2 && v.videoWidth>0 && v.currentTime>0 && Number(v.previousElementSibling.dataset.frames)>0,
                frames:v.getVideoPlaybackQuality().totalVideoFrames,error:!!v.error,
                fits:(()=>{let r=v.getBoundingClientRect();return r.left>=-1 && r.top>=-1 && r.right<=innerWidth+1 && r.bottom<=innerHeight+1 && getComputedStyle(v).objectFit==='contain'})(),
                filled:(()=>{
                    const tile=v.parentElement.getBoundingClientRect(), canvas=v.previousElementSibling.getBoundingClientRect();
                    const row=v.parentElement.parentElement;
                    const tiles=[...row.children].map(t=>t.getBoundingClientRect());
                    const rows=[...document.body.querySelectorAll('.row')].map(r=>r.getBoundingClientRect());
                    return canvas.left<=tile.left && canvas.top<=tile.top && canvas.right>=tile.right && canvas.bottom>=tile.bottom
                        && Math.abs(tiles[0].left)<1 && Math.abs(tiles.at(-1).right-innerWidth)<1
                        && tiles.every((t,i)=>i===0 || Math.abs(t.left-tiles[i-1].right)<1)
                        && Math.abs(rows[0].top)<1 && Math.abs(rows.at(-1).bottom-innerHeight)<1
                        && rows.every((r,i)=>i===0 || Math.abs(r.top-rows[i-1].bottom)<1);
                })()}))
            """) { [weak self] value, error in
            guard let self = self else { return }
            guard error == nil, let rows = value as? [[String: Any]], rows.count == self.count else {
                completion(0, true)
                return
            }
            let ready = rows.filter { $0["ready"] as? Bool == true && ($0["frames"] as? Int ?? 0) > 0 }.count
            self.sawFrames = self.sawFrames || ready == self.count
            completion(ready, rows.contains {
                $0["error"] as? Bool == true || $0["fits"] as? Bool != true || $0["filled"] as? Bool != true
            })
        }
    }

    func stop() {
        web.evaluateJavaScript("window.stopBackdrops?.();document.querySelectorAll('video').forEach(v=>{v.pause();v.removeAttribute('src');v.load()})")
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
        web.removeFromSuperview()
        source.movies.removeAll()
    }
}

final class FixtureBench: NSObject, NSApplicationDelegate {
    let request: Request
    var movies: [MemoryMovie] = []
    var windows: [NSWindow] = []
    var playbacks: [Playback] = []
    var signals: [DispatchSourceSignal] = []
    var result: Int32 = 0
    var deadline: Timer?
    var watchdog: Timer?
    var startup: Timer?
    var keyMonitor: Any?
    var sourceStream: SourceStream?
    let websiteData = WKWebsiteDataStore.nonPersistent()

    init(_ request: Request) { self.request = request }

    func fail(_ message: String = "Fixture playback failed; no media files were saved.") {
        fputs(message + "\n", stderr)
        result = 1
        stopRun()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 || (event.modifierFlags.contains(.control) && event.keyCode == 8) {
                interruptRun()
                return nil
            }
            return event
        }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { interruptRun() }
            source.resume()
            signals.append(source)
        }
        startup = Timer.scheduledTimer(withTimeInterval: Double(min(900, (request.clips?.count ?? 0) * 60 + 30)), repeats: false) { [weak self] _ in
            self?.fail()
        }
        Task { @MainActor in
            do {
                let limit = request.videosPerScreen ?? 0
                let minimumFPS = request.minFPS ?? 0
                guard let clips = request.clips, (2...96).contains(clips.count),
                      let seconds = request.seconds, seconds.isFinite, (1...3600).contains(seconds),
                      let fraction = request.fraction, fraction.isFinite, (0.1...1).contains(fraction),
                      (0...96).contains(limit), minimumFPS.isFinite, (0...240).contains(minimumFPS)
                else { throw FixtureError.invalid }
                var total = 0, belowFPS = 0
                var identities = Set<String>()
                var hashes = Set<Data>()
                for (index, clip) in clips.enumerated() {
                    defer { fflush(stdout) }
                    if let id = clip.id, identities.contains(id) {
                        print("Skipped duplicate source \(index + 1)")
                        continue
                    }
                    print("Buffering clip \(index + 1) in memory…")
                    fflush(stdout)
                    let data: Data
                    do {
                        if let source = clip.source, let executable = request.resolver {
                            let stream = SourceStream()
                            sourceStream = stream
                            try stream.start(source, executable: executable, minimumFPS: minimumFPS)
                            data = try await stream.read()
                            stream.stop()
                            sourceStream = nil
                        } else if let url = clip.url {
                            data = try await Fetch().load(url, headers: clip.headers ?? [:])
                        } else { throw FixtureError.invalid }
                    } catch {
                        sourceStream?.stop()
                        sourceStream = nil
                        print("Skipped unavailable clip \(index + 1)")
                        continue
                    }
                    var movie = MemoryMovie(data)
                    print("Inspecting clip \(index + 1)…")
                    fflush(stdout)
                    do {
                        try await movie.inspect()
                    } catch {
                        guard let fallback = clip.fallback, fallback != clip.url else {
                            print("Skipped unreadable clip \(index + 1)")
                            continue
                        }
                        print("Clip \(index + 1): highest stream metadata unreadable; trying progressive source.")
                        fflush(stdout)
                        do {
                            movie = MemoryMovie(try await Fetch().load(fallback, headers: clip.headers ?? [:]))
                            try await movie.inspect()
                        } catch {
                            print("Skipped unreadable fallback \(index + 1)")
                            continue
                        }
                    }
                    print("Clip \(index + 1): \(Int(movie.size.width))×\(Int(movie.size.height)), "
                          + "\(String(format: "%.3f", movie.fps)) source fps")
                    if Double(movie.fps) + 0.1 < minimumFPS {
                        belowFPS += 1
                        print("Skipped clip \(index + 1): below requested \(minimumFPS) fps")
                        continue
                    }
                    let hash = Data(SHA256.hash(data: movie.bytes))
                    guard !hashes.contains(hash) else {
                        print("Skipped duplicate video bytes \(index + 1)")
                        continue
                    }
                    guard total + movie.bytes.count <= totalLimit else {
                        print("Skipped clip \(index + 1): 512 MiB media budget reached")
                        continue
                    }
                    total += movie.bytes.count
                    hashes.insert(hash)
                    if let id = clip.id { identities.insert(id) }
                    movies.append(movie)
                    fflush(stdout)
                }
                startup?.invalidate()
                guard !movies.isEmpty else {
                    fail(belowFPS > 0
                         ? "No clips passed the requested frame rate and playback checks. Set Minimum source FPS to 0 to accept original rates, or choose faster sources."
                         : "No playable clips fit within the memory limit. Try fewer clips or another public source.")
                    return
                }
                if request.check == true {
                    print("Validated \(movies.count) unique in-memory clips; no video files saved.")
                    stopRun()
                    return
                }
                guard !NSScreen.screens.isEmpty else { throw FixtureError.unavailable }
                print("Original stream bytes, native playback cadence; no added compression. "
                      + "60 fps requires a 60 fps source, display and driver. Muted; Escape or Ctrl-C stops.")
                rebuild()
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.addObserver(self, selector: #selector(rebuild),
                    name: NSApplication.didChangeScreenParametersNotification, object: nil)
                deadline = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                    stopRun()
                }
                startWatchdog()
            } catch {
                fail()
            }
        }
    }

    func startWatchdog() {
        watchdog = Timer.scheduledTimer(timeInterval: 5, target: self,
            selector: #selector(checkPlayback), userInfo: nil, repeats: true)
    }

    @objc func rebuild() {
        guard !movies.isEmpty else { return }
        for playback in playbacks { playback.stop() }
        for window in windows { window.close() }
        windows.removeAll()
        playbacks.removeAll()
        let full = request.full == true
        let fraction = full ? 1.0 : request.fraction!
        let screens = NSScreen.screens
        let areas = screens.map { full ? $0.frame : $0.visibleFrame }
        let sizes = areas.map { CGSize(width: $0.width * fraction, height: $0.height * fraction) }
        let plans = gridPlans(sizes: movies.map(\.size), screens: sizes,
                              limit: request.videosPerScreen ?? 0)
        var used = Set<Int>()
        for (monitor, screen) in screens.enumerated() {
            let plan = plans[monitor]
            guard !plan.indices.isEmpty else {
                print("Screen \(monitor + 1): no unused source remains; left unchanged")
                continue
            }
            guard plan.indices.allSatisfy({ used.insert($0).inserted }) else { fail(); return }
            let area = areas[monitor]
            let size = sizes[monitor]
            let rect = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height)
            let window = FixtureWindow(contentRect: rect, styleMask: .borderless,
                                       backing: .buffered, defer: false, screen: screen)
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(srgbRed: 37 / 255, green: 43 / 255, blue: 54 / 255, alpha: 1)
            window.hasShadow = !full
            window.isMovableByWindowBackground = !full
            window.level = full ? .screenSaver : .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrame(rect, display: false)
            let selected = plan.indices.map { movies[$0] }
            let playback = Playback(selected, size: size, plan: plan, store: websiteData)
            playbacks.append(playback)
            window.contentView = playback.web
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
            print("Screen \(monitor + 1): \(plan.columns)×\(plan.rows) grid, unique clips "
                  + plan.indices.map { String($0 + 1) }.joined(separator: ","))
        }
        print("\(windows.count) borderless windows, \(used.count) globally unique video tiles; "
              + (full ? "full screen" : "windowed"))
        fflush(stdout)
    }

    @objc func checkPlayback() {
        var ready = 0, remaining = playbacks.count
        let count = playbacks.reduce(0) { $0 + $1.count }
        for playback in playbacks {
            playback.poll { [weak self] active, failed in
                if failed { self?.fail(); return }
                ready += active
                remaining -= 1
                if remaining == 0 {
                    print("Playback active: \(ready)/\(count) tiles (not a panel fps measurement)")
                    fflush(stdout)
                }
            }
        }
    }

    func cleanup() {
        sourceStream?.stop()
        sourceStream = nil
        startup?.invalidate()
        deadline?.invalidate()
        watchdog?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        for playback in playbacks {
            if result == 0 && !playback.sawFrames { result = 1 }
            playback.stop()
        }
        for window in windows { window.close() }
        playbacks.removeAll()
        windows.removeAll()
        movies.removeAll()
    }
}

do {
    var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
    setrlimit(RLIMIT_CORE, &coreLimit)
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 2 * 1024 * 1024 else { throw FixtureError.invalid }
    let request = try JSONDecoder().decode(Request.self, from: input)
    switch request.mode {
    case "screens":
        let sizes = NSScreen.screens.map { Dimensions(width: $0.frame.width, height: $0.frame.height) }
        FileHandle.standardOutput.write(try JSONEncoder().encode(sizes))
    case "layout":
        guard let sizes = request.layoutSizes, sizes.count <= 96,
              let screens = request.screenSizes, screens.count <= 32,
              (0...96).contains(request.videosPerScreen ?? 0),
              (sizes + screens).allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 })
        else { throw FixtureError.invalid }
        let plans = gridPlans(sizes: sizes.map(\.size), screens: screens.map(\.size),
                              limit: request.videosPerScreen ?? 0)
        FileHandle.standardOutput.write(try JSONEncoder().encode(plans))
    case "seal", "open":
        guard let rawKey = request.key, rawKey.count == 32, let data = request.data else {
            throw FixtureError.invalid
        }
        let key = SymmetricKey(data: rawKey)
        // Stable v1 cryptographic context; keep existing encrypted settings readable.
        let context = Data(base64Encoded: "TVZpZXcgbG9jYWwgZml4dHVyZSBzZXR0aW5ncyB2MQ==")!
        let output: Data
        if request.mode == "seal" {
            output = try AES.GCM.seal(data, using: key, authenticating: context).combined!
        } else {
            output = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key,
                                      authenticating: context)
        }
        FileHandle.standardOutput.write(output)
    case "play":
        let app = NSApplication.shared
        let delegate = FixtureBench(request)
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        delegate.cleanup()
        exit(delegate.result)
    default:
        throw FixtureError.invalid
    }
} catch CryptoKitError.authenticationFailure {
    fputs("Saved settings could not be authenticated.\n", stderr)
    exit(3)
} catch {
    fputs("Fixture request rejected.\n", stderr)
    exit(1)
}
