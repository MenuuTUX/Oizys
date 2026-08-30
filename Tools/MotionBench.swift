// A repeatable compositor workload for comparing display drivers. No screen recording.
// Build: swiftc -O Tools/MotionBench.swift -o build/MotionBench
// Run:   build/MotionBench [seconds] [--full | --fraction F]
//
//   seconds     how long to run before quitting. Default 120.
//   --full      the moving region covers the whole screen. Worst case for any driver
//               that encodes only what changed, and the case that says whether the
//               encoder keeps up when nothing can be skipped.
//   --fraction  moving region as a fraction of the screen's shorter dimension-ish box;
//               0.5 is roughly the historical 960x540 on a 1920x1080 head. Default 0.5.
//
// Windows follow displays as they appear. A driver under test creates its virtual
// displays after this process starts, and the original version enumerated NSScreen.screens
// exactly once at launch: every measurement taken across a driver restart then had a
// static desktop on the displays being captured, and a moving window only on the screens
// that happened to exist at launch. Any comparison made that way measured an idle encoder.
import AppKit
import QuartzCore

final class MotionBench: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var fraction = 0.5
    var full = false

    func makeWindow(_ screen: NSScreen, _ index: Int) -> NSWindow {
        let size = full ? screen.frame.size
                        : NSSize(width: screen.frame.width * fraction,
                                 height: screen.frame.height * fraction)
        let rect = NSRect(x: screen.frame.midX - size.width / 2,
                          y: screen.frame.midY - size.height / 2,
                          width: size.width, height: size.height)
        let window = NSWindow(contentRect: rect,
                              styleMask: full ? [.borderless] : [.titled, .closable],
                              backing: .buffered, defer: false, screen: screen)
        window.title = "MView motion comparison • screen \(index + 1)"
        window.isReleasedWhenClosed = false
        if full { window.level = .floating; window.setFrame(screen.frame, display: true) }
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer!.backgroundColor = NSColor(calibratedWhite: 0.95, alpha: 1).cgColor
        view.layer!.masksToBounds = true
        // The scrolling document is three times the visible height so the loop never shows
        // an edge, and the row count scales with the region so a full-screen run has the
        // same visual density as a windowed one rather than the same absolute row count.
        let rows = max(12, Int(size.height / 10))
        let document = CALayer()
        document.frame = CGRect(x: 0, y: -size.height, width: size.width, height: size.height * 3)
        for row in 0..<rows {
            let line = CALayer()
            line.frame = CGRect(x: 35, y: CGFloat(row) * (size.height * 3 / CGFloat(rows)),
                                width: size.width * 0.35 + CGFloat((row * 73) % 540),
                                height: 14)
            line.backgroundColor = NSColor(calibratedHue: CGFloat(row % 12) / 12,
                                           saturation: 0.5, brightness: 0.55, alpha: 1).cgColor
            line.cornerRadius = 3
            document.addSublayer(line)
        }
        view.layer!.addSublayer(document)
        let scroll = CABasicAnimation(keyPath: "transform.translation.y")
        scroll.fromValue = 0
        scroll.toValue = size.height
        scroll.duration = 2
        scroll.repeatCount = .infinity
        scroll.timingFunction = CAMediaTimingFunction(name: .linear)
        document.add(scroll, forKey: "scroll")
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    @objc func rebuild() {
        for window in windows { window.orderOut(nil) }
        windows = NSScreen.screens.enumerated().map { makeWindow($1, $0) }
        let names = NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }
        print("motion windows: \(windows.count) on \(names.joined(separator: ", "))"
              + (full ? " (full screen)" : " (\(fraction) of each screen)"))
        fflush(stdout)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = Array(CommandLine.arguments.dropFirst())
        let duration = args.first.flatMap(Double.init) ?? 120
        full = args.contains("--full")
        if let i = args.firstIndex(of: "--fraction"), i + 1 < args.count,
           let value = Double(args[i + 1]) { fraction = min(max(value, 0.05), 1.0) }
        rebuild()
        // Displays appear and disappear while a driver is being started, stopped or
        // restarted. Follow them; do not assume the set at launch is the set under test.
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
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
