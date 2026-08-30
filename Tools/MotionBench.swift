// A repeatable compositor workload for comparing display drivers. No screen recording.
// Build: swiftc -O Tools/MotionBench.swift -o build/MotionBench
// Run:   build/MotionBench [seconds] [--pattern NAME] [--dwell S] [--windowed [--fraction F]]
//
//   seconds       how long to run before quitting. Default 120. Ctrl-C also ends it, and
//                 the app's "Stop tests" button terminates it.
//   --pattern     scroll | text | noise | gradient | flash | scatter | still | cycle.
//                 Default cycle: every pattern in turn, so one run touches every part of
//                 the pipeline. `--pattern scroll` reproduces the historical baseline the
//                 comparisons in logs/ were recorded against.
//   --dwell       seconds per pattern under `cycle`. Default 10.
//   --windowed    the old half-screen titled window, for when the machine has to stay
//                 usable during the run.
//   --fraction    windowed size as a fraction of each screen. Default 0.5.
//
// By default the workload is a borderless, click-through, always-on-top surface covering
// every screen, so what the driver captures is the workload and nothing else. A titled
// window measured the compositor compositing a window: the desktop behind it never
// changed, most strips never moved, and the encoder was rated on a fraction of a screen.
//
// Why more than one pattern. Scrolling lines pressurise one thing — mid-density damage
// with sharp edges — and a driver can look healthy on it while failing on everything else
// a desktop does. The set below was chosen so that each one is the worst case for a
// different stage:
//
//   scroll    mid-sized damage, sharp edges. The historical baseline.
//   text      dense small glyphs. High-frequency luma: the worst case for the Haar
//             pyramid and quantiser, and where visible artefacts show up first.
//   noise     incompressible pixels changing every frame on every strip. The ceiling:
//             encoder throughput and USB bandwidth with nothing skippable.
//   gradient  a smooth ramp panning slowly. Every pixel changes by a little, which is the
//             worst case for a fingerprint that could miss a small change, and the case
//             where chroma quantisation shows as banding.
//   flash     full-screen black/white at 10 Hz. Keyframe and dock-buffer churn: the phase
//             handling that made panels alternate between the desktop and a training frame.
//   scatter   many small squares blinking in place across the whole surface. Damage that
//             is large in strip count and tiny in bytes: per-strip and per-record overhead
//             rather than bandwidth, and the y-band grouping in the frame builder.
//   still     nothing moves. ScreenCaptureKit stops delivering, so this measures the
//             refresh timer, the strip debt repayment and the control keepalive — the path
//             that decides whether an idle desktop stays lit or goes dark.
//
// Frames are pre-rendered and the animation runs in the compositor, so the generator's own
// CPU stays out of the driver's measurement. Every pattern is deterministic: same seed,
// same positions, same order, so two runs are comparable.
//
// Windows follow displays as they appear. A driver under test creates its virtual displays
// after this process starts, and the original version enumerated NSScreen.screens exactly
// once at launch: every measurement taken across a driver restart then had a static desktop
// on the displays being captured, and a moving window only on the screens that happened to
// exist at launch. Any comparison made that way measured an idle encoder.
import AppKit
import QuartzCore

enum Pattern: String, CaseIterable {
    case scroll, text, noise, gradient, flash, scatter, still
}

// A fixed-seed generator, so noise and scatter are the same pixels on every run and two
// drivers can be compared on identical work.
struct Deterministic {
    var state: UInt64 = 0x2545F4914F6CDD1D
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53) }
}

func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage? {
    guard width > 0, height > 0,
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    draw(context)
    return context.makeImage()
}

final class MotionBench: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var fraction = 0.5
    var windowed = false
    var pattern = Pattern.scroll
    var cycling = true
    var dwell: TimeInterval = 10
    var cycleTimer: Timer?
    var random = Deterministic()

    // MARK: patterns

    /// Scrolling coloured rules. Mid-sized damage with sharp edges.
    func scrollLayer(_ size: NSSize) -> CALayer {
        let document = CALayer()
        document.frame = CGRect(x: 0, y: -size.height, width: size.width, height: size.height * 3)
        // Three times the visible height so the loop never shows an edge, and the row count
        // scales with the region so a full-screen run has the same visual density as a
        // windowed one rather than the same absolute row count.
        let rows = max(12, Int(size.height / 10))
        for row in 0..<rows {
            let line = CALayer()
            line.frame = CGRect(x: 35, y: CGFloat(row) * (size.height * 3 / CGFloat(rows)),
                                width: size.width * 0.35 + CGFloat((row * 73) % 540), height: 14)
            line.backgroundColor = NSColor(calibratedHue: CGFloat(row % 12) / 12,
                                           saturation: 0.5, brightness: 0.55, alpha: 1).cgColor
            line.cornerRadius = 3
            document.addSublayer(line)
        }
        document.add(scrolling(by: size.height, duration: 2), forKey: "scroll")
        return document
    }

    /// Dense monospaced text, scrolled. High-frequency luma across the whole surface.
    func textLayer(_ size: NSSize) -> CALayer {
        let height = size.height * 2
        let words = ["driver", "strip", "damage", "encode", "0x2f", "usb", "haar", "quantize",
                     "entropy", "frame", "head", "commit", "trailer", "keyframe", "poll"]
        var generator = Deterministic()
        let rendered = image(width: Int(size.width), height: Int(height)) { context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: height))
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.black]
            var y = CGFloat(4)
            while y < height {
                var line = ""
                while CGFloat(line.count) * 6.6 < size.width {
                    line += words[Int(generator.next() % UInt64(words.count))] + " "
                }
                line.draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
                y += 13
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let document = CALayer()
        document.frame = CGRect(x: 0, y: -height + size.height, width: size.width, height: height)
        document.contents = rendered
        document.add(scrolling(by: height - size.height, duration: 8), forKey: "scroll")
        return document
    }

    /// Incompressible pixels, replaced every frame. Tiles rather than one screen-sized
    /// image per frame: eight 3840x2160 buffers per screen is a gigabyte of workload
    /// competing with the driver for memory bandwidth, which is not what is being measured.
    func noiseLayer(_ size: NSSize) -> CALayer {
        let side = 320
        var generator = Deterministic()
        let frames: [CGImage] = (0..<8).compactMap { _ in
            image(width: side, height: side) { context in
                guard let data = context.data else { return }
                let bytes = data.assumingMemoryBound(to: UInt8.self)
                for offset in stride(from: 0, to: side * side * 4, by: 8) {
                    var word = generator.next()
                    for byte in 0..<8 {
                        bytes[offset + byte] = UInt8(truncatingIfNeeded: word)
                        word >>= 8
                    }
                }
            }
        }
        let host = CALayer()
        host.frame = CGRect(origin: .zero, size: size)
        guard !frames.isEmpty else { return host }
        var phase = 0
        for x in stride(from: 0, to: Int(size.width), by: side) {
            for y in stride(from: 0, to: Int(size.height), by: side) {
                let tile = CALayer()
                tile.frame = CGRect(x: x, y: y, width: side, height: side)
                tile.magnificationFilter = .nearest
                tile.contents = frames[phase % frames.count]
                let flip = CAKeyframeAnimation(keyPath: "contents")
                // Each tile starts at a different frame, so neighbouring strips never
                // carry the same bytes and the fingerprint cannot coalesce them.
                flip.values = (0..<frames.count).map { frames[($0 + phase) % frames.count] }
                flip.calculationMode = .discrete
                flip.duration = Double(frames.count) / 60
                flip.repeatCount = .infinity
                tile.add(flip, forKey: "noise")
                host.addSublayer(tile)
                phase += 1
            }
        }
        return host
    }

    /// A smooth ramp panning slowly: every pixel changes by a little every frame.
    func gradientLayer(_ size: NSSize) -> CALayer {
        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: -size.width, y: 0, width: size.width * 3, height: size.height)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.colors = [NSColor.systemTeal, NSColor.systemPink, NSColor.systemIndigo,
                           NSColor.systemYellow, NSColor.systemTeal].map(\.cgColor)
        let pan = CABasicAnimation(keyPath: "transform.translation.x")
        pan.fromValue = 0
        pan.toValue = size.width
        pan.duration = 6
        pan.repeatCount = .infinity
        pan.timingFunction = CAMediaTimingFunction(name: .linear)
        gradient.add(pan, forKey: "pan")
        return gradient
    }

    /// Whole surface black to white at 10 Hz. Every strip changes, every frame is a
    /// candidate keyframe, and the dock's buffer rotation has nowhere to hide.
    func flashLayer(_ size: NSSize) -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: size)
        layer.backgroundColor = NSColor.black.cgColor
        let flash = CAKeyframeAnimation(keyPath: "backgroundColor")
        flash.values = [NSColor.black.cgColor, NSColor.white.cgColor]
        flash.calculationMode = .discrete
        flash.duration = 0.2
        flash.repeatCount = .infinity
        layer.add(flash, forKey: "flash")
        return layer
    }

    /// Small squares blinking in place, spread over the whole surface. Large in strips,
    /// tiny in bytes.
    func scatterLayer(_ size: NSSize) -> CALayer {
        let host = CALayer()
        host.frame = CGRect(origin: .zero, size: size)
        host.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        var generator = Deterministic()
        let count = max(64, Int(size.width * size.height / 24000))
        for index in 0..<count {
            let square = CALayer()
            square.frame = CGRect(x: generator.unit() * (size.width - 24),
                                  y: generator.unit() * (size.height - 24), width: 24, height: 24)
            square.backgroundColor = NSColor(calibratedHue: generator.unit(), saturation: 0.8,
                                             brightness: 0.9, alpha: 1).cgColor
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1.0, 0.0]
            blink.calculationMode = .discrete
            blink.duration = 0.1
            blink.repeatCount = .infinity
            // Spread the phases so the count of dirty strips per frame stays steady
            // instead of arriving as one screen-wide pulse.
            blink.timeOffset = Double(index % 6) * 0.0166
            square.add(blink, forKey: "blink")
            host.addSublayer(square)
        }
        return host
    }

    func scrolling(by distance: CGFloat, duration: Double) -> CABasicAnimation {
        let scroll = CABasicAnimation(keyPath: "transform.translation.y")
        scroll.fromValue = 0
        scroll.toValue = distance
        scroll.duration = duration
        scroll.repeatCount = .infinity
        scroll.timingFunction = CAMediaTimingFunction(name: .linear)
        return scroll
    }

    func content(_ pattern: Pattern, _ size: NSSize) -> CALayer? {
        switch pattern {
        case .scroll: return scrollLayer(size)
        case .text: return textLayer(size)
        case .noise: return noiseLayer(size)
        case .gradient: return gradientLayer(size)
        case .flash: return flashLayer(size)
        case .scatter: return scatterLayer(size)
        case .still: return nil
        }
    }

    // MARK: windows

    func makeWindow(_ screen: NSScreen, _ index: Int) -> NSWindow {
        let size = windowed ? NSSize(width: screen.frame.width * fraction,
                                     height: screen.frame.height * fraction)
                            : screen.frame.size
        let rect = NSRect(x: screen.frame.midX - size.width / 2,
                          y: screen.frame.midY - size.height / 2,
                          width: size.width, height: size.height)
        let window = NSWindow(contentRect: rect,
                              styleMask: windowed ? [.titled, .closable] : [.borderless],
                              backing: .buffered, defer: false, screen: screen)
        window.title = "MView motion comparison • screen \(index + 1)"
        window.isReleasedWhenClosed = false
        if !windowed {
            // Above everything, on every space, and transparent to the mouse: the point is
            // to own what the driver captures, not to take the machine away from whoever
            // is watching the run.
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone,
                                         .ignoresCycle]
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.setFrame(screen.frame, display: true)
        }
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer!.backgroundColor = NSColor(calibratedWhite: 0.95, alpha: 1).cgColor
        view.layer!.masksToBounds = true
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    func paint() {
        for window in windows {
            guard let host = window.contentView?.layer else { continue }
            host.sublayers?.forEach { $0.removeFromSuperlayer() }
            host.backgroundColor = (pattern == .still
                ? NSColor(calibratedWhite: 0.12, alpha: 1)
                : NSColor(calibratedWhite: 0.95, alpha: 1)).cgColor
            if let layer = content(pattern, window.frame.size) { host.addSublayer(layer) }
        }
        print("motion pattern: \(pattern.rawValue)")
        fflush(stdout)
    }

    @objc func rebuild() {
        for window in windows { window.orderOut(nil) }
        windows = NSScreen.screens.enumerated().map { makeWindow($1, $0) }
        let names = NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }
        print("motion windows: \(windows.count) on \(names.joined(separator: ", "))"
              + (windowed ? " (\(fraction) of each screen)" : " (full screen, always on top)"))
        paint()
    }

    @objc func advance() {
        let all = Pattern.allCases
        pattern = all[(all.firstIndex(of: pattern).map { $0 + 1 } ?? 0) % all.count]
        paint()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        let duration = args.first.flatMap(Double.init) ?? 120
        // --full was the old opt-in to what is now the default. Still accepted so existing
        // scripts and the recorded comparison commands keep working.
        windowed = args.contains("--windowed") && !args.contains("--full")
        if let text = value("--fraction"), let number = Double(text) {
            fraction = min(max(number, 0.05), 1.0)
        }
        if let text = value("--dwell"), let number = Double(text) { dwell = max(1, number) }
        if let name = value("--pattern") {
            if name == "cycle" {
                cycling = true
            } else if let chosen = Pattern(rawValue: name) {
                pattern = chosen
                cycling = false
            } else {
                let names = Pattern.allCases.map(\.rawValue).joined(separator: ", ")
                print("unknown pattern \(name). Use cycle, or one of: \(names)")
                exit(2)
            }
        }
        if cycling { pattern = .scroll }
        rebuild()
        if cycling {
            cycleTimer = Timer.scheduledTimer(timeInterval: dwell, target: self,
                                              selector: #selector(advance), userInfo: nil,
                                              repeats: true)
        }
        // Displays appear and disappear while a driver is being started, stopped or
        // restarted. Follow them; do not assume the set at launch is the set under test.
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        print("running for \(Int(duration))s; Ctrl-C ends it early")
        fflush(stdout)
        Timer.scheduledTimer(withTimeInterval: max(1, duration), repeats: false) { _ in
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = MotionBench()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
