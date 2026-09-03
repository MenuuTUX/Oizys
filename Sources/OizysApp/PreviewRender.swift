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
    static func run(into directory: String) -> Int32 {
        let folder = URL(fileURLWithPath: directory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fputs("Could not create \(folder.path): \(error.localizedDescription)\n", stderr)
            return 1
        }
        let model = OizysModel.preview()
        var failures = 0

        failures += write(MenuPopover(model: model, openWindow: {}, quit: {})
            .frame(width: 330), to: folder.appendingPathComponent("popover.png"))
        failures += write(MenuWindow(model: model, initial: .displays)
            .frame(width: 820, height: 560), to: folder.appendingPathComponent("window.png"))

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
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            fputs("Could not render \(url.lastPathComponent)\n", stderr)
            return 1
        }
        do { try png.write(to: url); return 0 }
        catch { fputs("Could not write \(url.path): \(error)\n", stderr); return 1 }
    }
}
#endif
