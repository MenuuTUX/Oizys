#if !OIZYS_PRODUCTION
import AppKit
import SwiftUI

/*
 * Render the interface to PNG without a dock, a driver, or anyone looking at a screen.
 *
 * This exists because "it compiles" says nothing about whether a panel is readable, and the
 * alternative -- plug in hardware, start a session, take a screenshot -- is a slow loop that
 * cannot run in CI and cannot run at all while someone is using the machine. Every panel is
 * rendered from OizysModel.preview(), so the output is deterministic.
 *
 *     oizys-debug --render-preview <directory>
 */
enum PreviewRender {
    @MainActor
    static func checkInteractions() -> Int32 {
        NSApplication.shared.accessibilitySetValue(true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let hosting = NSHostingView(rootView: MenuWindow(model: OizysModel.preview(), initial: .settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 40000, y: 40000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        func legacy(_ element: AnyObject, _ attribute: String) -> Any? {
            let selector = NSSelectorFromString("accessibilityAttributeValue:")
            guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
            return object.perform(selector, with: attribute as NSString)?.takeUnretainedValue()
        }
        func nodes(_ item: Any, depth: Int = 0) -> [AnyObject] {
            guard depth < 30 else { return [] }
            let element = item as AnyObject
            let children = element.accessibilityChildren?() ?? (legacy(element, "AXChildren") as? [Any]) ?? []
            return [element] + children.flatMap { nodes($0, depth: depth + 1) }
        }
        func name(_ element: AnyObject) -> String {
            let selector = NSSelectorFromString("accessibilityValue")
            var value = ""
            if let object = element as? NSObject, object.responds(to: selector) {
                value = object.perform(selector)?.takeUnretainedValue() as? String ?? ""
            }
            if value.isEmpty { value = legacy(element, "AXValue") as? String ?? "" }
            return (element.accessibilityLabel?() ?? "") + " "
                + (element.accessibilityTitle?() ?? (legacy(element, "AXTitle") as? String) ?? "") + " " + value
        }
        var tree = nodes(hosting)
        guard Panel.allCases.allSatisfy({ panel in tree.contains { name($0).contains(panel.rawValue) } }),
              tree.contains(where: { $0.accessibilityRole?() == .textField
                  && name($0).contains("Search driver settings") }) else {
            fputs("Interface check: navigation or accessible search field is missing\n", stderr)
            return 1
        }
        window.makeKey()
        window.makeFirstResponder(hosting)
        guard let find = tree.first(where: { $0.accessibilityRole?() == .button && name($0).contains("Find driver setting") }),
              find.accessibilityPerformPress?() == true else {
            fputs("Interface check: Find action is unavailable\n", stderr)
            return 1
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let query = "head.left.brightness"
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil,
                                    characters: query, charactersIgnoringModifiers: query,
                                    isARepeat: false, keyCode: 0)!
        window.sendEvent(event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        tree = nodes(hosting)
        guard tree.contains(where: { name($0).contains("Edit head.left.brightness") }),
              !tree.contains(where: { name($0).contains("Edit control.poll_ms") }),
              tree.contains(where: { name($0).contains("Reset head.left.brightness to default") }) else {
            fputs("Interface check: keyboard search did not filter settings or reset is unnamed\n", stderr)
            return 1
        }
        guard let sidebar = tree.first(where: { $0 is NSOutlineView }) as? NSOutlineView,
              window.makeFirstResponder(sidebar) else {
            fputs("Interface check: sidebar cannot receive keyboard focus\n", stderr)
            return 1
        }
        for heading in ["USB PORTS", "MATCH THE MONITORS", "DISPLAY ARRANGEMENT", "ATTACHED DISPLAYS", "DOCK DISPLAYS"] {
            let up = "\u{F700}"
            let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: up, charactersIgnoringModifiers: up,
                                        isARepeat: false, keyCode: 126)!
            window.sendEvent(arrow)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            guard nodes(hosting).contains(where: { name($0).contains(heading) }) else {
                fputs("Interface check: keyboard navigation did not reach \(heading)\n", stderr)
                return 1
            }
        }
        for (model, action, sliders) in [(OizysModel.preview(), "Stop", 2),
                                        (OizysModel.preview(recordingGranted: false), "Grant access…", 0),
                                        (OizysModel.preview(recordingGranted: false, dockCount: 0), "Grant access…", 0),
                                        (OizysModel.preview(phase: .recovering), "Retry connection", 0)] {
            let popover = NSHostingView(rootView: MenuPopover(model: model, openWindow: {}, quit: {}))
            window.contentView = popover
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let elements = nodes(popover)
            guard elements.contains(where: { $0.accessibilityRole?() == .button && name($0).contains(action) }),
                  elements.filter({ $0.accessibilityRole?() == .slider }).count == sliders else {
                fputs("Interface check: incorrect action or brightness controls for \(model.summary)\n", stderr)
                return 1
            }
        }
        print("PASS interface keyboard navigation, search and accessible state controls")
        return 0
    }

    @MainActor
    static func run(into directory: String) -> Int32 {
        let folder = URL(fileURLWithPath: directory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fputs("Could not create \(folder.path): \(error.localizedDescription)\n", stderr)
            return 1
        }
        let model = OizysModel.preview()
        let blocked = OizysModel.preview(recordingGranted: false)
        let recovering = OizysModel.preview(phase: .recovering)
        var failures = 0
        if model.health != .live || blocked.summary != "Screen Recording required"
            || recovering.summary != "Recovering connection…" {
            fputs("Preview status states are inconsistent\n", stderr)
            failures += 1
        }

        failures += write(MenuPopover(model: model, openWindow: {}, quit: {})
            .frame(width: 330), to: folder.appendingPathComponent("popover.png"))
        failures += write(MenuPopover(model: blocked, openWindow: {}, quit: {})
            .frame(width: 330), to: folder.appendingPathComponent("popover-permission.png"))
        failures += write(MenuPopover(model: recovering, openWindow: {}, quit: {})
            .frame(width: 330), to: folder.appendingPathComponent("popover-recovering.png"))
        failures += write(MenuPopover(model: OizysModel.preview(recordingGranted: false, dockCount: 0), openWindow: {}, quit: {})
            .frame(width: 330), to: folder.appendingPathComponent("popover-setup.png"))
        failures += write(MenuWindow(model: model)
            .frame(width: 820, height: 560), to: folder.appendingPathComponent("window.png"))
        failures += write(MenuWindow(model: model)
            .frame(width: 720, height: 480), to: folder.appendingPathComponent("window-minimum.png"))

        for panel in Panel.allCases {
            let name = panel.rawValue.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "&", with: "and")
            failures += write(
                ZStack(alignment: .topLeading) {
                    Ink.ground
                    Grain(opacity: 0.030)
                    Vignette(strength: 0.42)
                    PanelBody(model: model, panel: panel)
                }
                .frame(width: 640, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true),
                to: folder.appendingPathComponent("panel-\(name).png"))
        }

        // The status item, at the size it is actually drawn, on both menu-bar grounds. This
        // is the one asset whose failure mode is silent: a template that resolves to a solid
        // block still "renders", it just looks like a bug in the menu bar.
        failures += write(
            HStack(spacing: 0) {
                ForEach([Color.black, Color.white], id: \.self) { ground in
                    ZStack {
                        ground
                        VStack(spacing: 10) {
                            ForEach([true, false], id: \.self) { active in
                                Image(nsImage: Logo.menuBar(active: active))
                                    .renderingMode(.template)
                                    .foregroundStyle(ground == .black ? Color.white : Color.black)
                                    .frame(width: 18, height: 18)
                            }
                        }
                    }
                    .frame(width: 60, height: 70)
                }
            }
            .frame(width: 120, height: 70),
            to: folder.appendingPathComponent("menubar-icon.png"))

        // The overlay draws over a live screen, so it is rendered on its own dark ground at
        // three points through the animation rather than as a single frozen frame.
        for (index, offset) in [0.18, 0.45, 0.78].enumerated() {
            failures += write(
                ZStack {
                    Color.black
                    ConnectRipplePreview(progress: offset)
                }.frame(width: 640, height: 400),
                to: folder.appendingPathComponent("overlay-\(index + 1).png"))
        }

        if failures == 0 { print("wrote previews to \(folder.path)") }
        return failures == 0 ? 0 : 1
    }

    @MainActor
    private static func write<V: View>(_ view: V, to url: URL) -> Int {
        // ImageRenderer cannot snapshot AppKit-backed controls (Toggle, Picker, Slider,
        // List): they come out as yellow placeholders with a prohibition sign. A real
        // window, never shown, gives them a host to draw into.
        // An opaque ground prevents cacheDisplay from saving only the compositing mask.
        let hosting = NSHostingView(rootView: view.background(Ink.ground)
            .environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // Pin the review look: offscreen windows resolve an inconsistent mix of
        // appearances, which photographs native bezels white with white text.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        var size = hosting.fittingSize
        size.width = max(size.width, 1)
        size.height = max(size.height, 1)
        window.setContentSize(size)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            fputs("Could not render \(url.lastPathComponent)\n", stderr)
            return 1
        }
        window.appearance?.performAsCurrentDrawingAppearance {
            content.cacheDisplay(in: content.bounds, to: bitmap)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fputs("Could not render \(url.lastPathComponent)\n", stderr)
            return 1
        }
        do { try png.write(to: url); return 0 }
        catch { fputs("Could not write \(url.path): \(error)\n", stderr); return 1 }
    }
}
#endif
