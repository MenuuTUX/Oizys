// A repeatable compositor workload for comparing display drivers. No screen recording.
// Build: swiftc -O Tools/MotionBench.swift -o build/MotionBench
// Run: build/MotionBench [seconds]
import AppKit
import QuartzCore

final class MotionBench: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let duration = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 25
        for (index, screen) in NSScreen.screens.enumerated() {
            let size = NSSize(width: 960, height: 540)
            let rect = NSRect(x: screen.frame.midX - size.width / 2,
                              y: screen.frame.midY - size.height / 2,
                              width: size.width, height: size.height)
            let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false, screen: screen)
            window.title = "MView motion comparison • screen \(index + 1) • \(Int(duration)) seconds"
            window.isReleasedWhenClosed = false
            let view = NSView(frame: NSRect(origin: .zero, size: size))
            view.wantsLayer = true
            view.layer!.backgroundColor = NSColor(calibratedWhite: 0.95, alpha: 1).cgColor
            view.layer!.masksToBounds = true
            let document = CALayer()
            document.frame = CGRect(x: 0, y: -540, width: 960, height: 1620)
            for row in 0..<54 {
                let line = CALayer()
                line.frame = CGRect(x: 35, y: row * 30, width: 350 + (row * 73) % 540, height: 14)
                line.backgroundColor = NSColor(calibratedHue: CGFloat(row % 12) / 12,
                                                saturation: 0.5, brightness: 0.55, alpha: 1).cgColor
                line.cornerRadius = 3
                document.addSublayer(line)
            }
            view.layer!.addSublayer(document)
            let scroll = CABasicAnimation(keyPath: "transform.translation.y")
            scroll.fromValue = 0
            scroll.toValue = 540
            scroll.duration = 2
            scroll.repeatCount = .infinity
            scroll.timingFunction = CAMediaTimingFunction(name: .linear)
            document.add(scroll, forKey: "scroll")
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }
        print("motion windows: \(windows.count); duration: \(duration)s; region: 960x540")
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
