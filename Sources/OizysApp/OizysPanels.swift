import AppKit
import Darwin
import SwiftUI

// MARK: - Popover

/// The everyday surface. Status, the displays, and the two things anyone actually wants to
/// do. Everything else lives one click away in the window, so this stays readable.
struct MenuPopover: View {
    @ObservedObject var model: OizysModel
    var openWindow: () -> Void
    var quit: () -> Void
    var refresh: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("OIZYS").font(.system(size: 17, weight: .regular)).tracking(6)
                            .foregroundStyle(Ink.primary)
                        HStack(spacing: 6) {
                            StatusDot(health: model.health)
                            Text(model.summary).font(.callout).foregroundStyle(Ink.secondary)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

                    VStack(alignment: .leading, spacing: 0) {
                        if model.health != .live {
                            Text(model.connectionHint)
                                .font(.callout).foregroundStyle(Ink.secondary)
                                .padding(.vertical, 6)
                            if model.supervisorStatus?.phase == .recovering {
                                RecoveryElapsed(since: model.connectionChangedAt)
                            }
                        }
                        if model.health == .live {
                            SectionLabel(text: "Picture brightness")
                            ForEach(model.displays.filter { $0.head != nil }) { display in
                                if let head = display.head {
                                    let value = model.headBrightness(head)
                                    HStack(spacing: 8) {
                                        Text(head == 0 ? "Left" : "Right").font(.callout)
                                            .frame(width: 42, alignment: .leading)
                                        HalftoneSlider(value: Binding(
                                            get: { (model.headBrightness(head) - 10) / 90 },
                                            set: { model.setHeadBrightness(head, 10 + $0 * 90,
                                                                           persist: false) }),
                                                       onCommit: { model.setHeadBrightness(head, 10 + $0 * 90) },
                                                       label: "\(display.name) picture brightness",
                                                       announcedValue: "\(Int(value)) percent")
                                        Text("\(Int(value))%").font(Ink.value)
                                            .frame(width: 42, alignment: .trailing)
                                    }
                                    .padding(.vertical, 5)
                                    HStack {
                                        Spacer()
                                        QuietButton(title: "Reset \(head == 0 ? "left" : "right") to 100%",
                                                    disabled: value == 100) { model.setHeadBrightness(head, 100) }
                                    }
                                }
                            }
                        }
                        SectionLabel(text: "Displays", trailing: model.displays.isEmpty ? nil : "\(model.displays.count)")
                        if model.displays.isEmpty {
                            Text("No displays reported.").font(Ink.label).foregroundStyle(Ink.faint)
                                .padding(.vertical, 6)
                        }
                        ForEach(model.displays) { display in
                            Row(label: display.name, detail: display.geometry) {
                                Text(display.kind.rawValue).foregroundStyle(Ink.faint)
                            }
                        }

                        SectionLabel(text: "Driver")
                        Row(label: "Service", detail: model.dockPresent ? nil :
                            model.dockCount > 1 ? "Disconnect one dock to start." : "Connect the dock to start.") {
                            HStack(spacing: 6) {
                                StatusDot(health: model.health)
                                Text(model.dockPresent && !model.screenRecordingGranted
                                     ? "Permission needed" : model.running ? "Service active" : "Stopped")
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !model.lastMessage.isEmpty {
                    Text(model.lastMessage).font(.caption).foregroundStyle(Ink.faint)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    QuietButton(title: model.primaryActionTitle,
                                disabled: !model.primaryActionEnabled,
                                prominent: true, defaultAction: true) {
                        model.performPrimaryAction()
                        refresh()
                    }
                    QuietButton(title: "Open Oizys…", action: openWindow)
                    Spacer()
                    QuietButton(title: "Quit", action: quit)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 330)
        .background(.regularMaterial)
        .onAppear { model.refresh() }
    }
}

private struct MenuBarSection: View {
    @State private var mirroringIcon = MenuBarExtras.mirroringIconVisible
    @State private var preferenceFailed = false

    var body: some View {
        Row(label: "Screen mirroring module",
            detail: "Show the optional Screen Mirroring shortcut in the menu bar.") {
            QuietSwitch(isOn: Binding(get: { mirroringIcon },
                                      set: { value in
                preferenceFailed = !MenuBarExtras.setMirroringIconVisible(value)
                mirroringIcon = MenuBarExtras.mirroringIconVisible
            }), label: "Screen mirroring module")
        }
        if preferenceFailed {
            Text("Could not save the menu-bar preference. Try System Settings.")
                .font(.caption).foregroundStyle(Ink.faint)
        }
        Row(label: "Screen recording permission",
            detail: MenuBarExtras.screenRecordingGranted
                ? "Granted. Oizys uses this permission while driving the dock displays."
                : "Required to send the dock desktops to your monitors.") {
            QuietButton(title: "Settings…") { MenuBarExtras.openScreenRecordingSettings() }
        }
        Row(label: "Menu bar item",
            detail: "Oizys can run without its menu bar item; reopen it from Spotlight.") {
            QuietSwitch(isOn: Binding(get: { OizysMenuBar.extraVisible },
                                      set: { OizysMenuBar.setExtraVisibleRequest($0) }),
                        label: "Menu bar item")
        }
        Text("Oizys installs one menu-bar item. macOS shows the purple status item while "
             + "screen capture or Sidecar is active; that one is not Oizys's, and no "
             + "supported API hides it. The shortcut setting above does not remove an "
             + "active session's indicator.")
            .font(.caption).foregroundStyle(Ink.faint).padding(.top, 6)
    }
}

// MARK: - Window

enum Panel: String, CaseIterable, Identifiable {
    case overview = "Overview", displays = "Displays", arrangement = "Arrangement"
    case calibrate = "Colour", diagnostics = "Diagnostics", settings = "Settings"
    var id: String { rawValue }
}

struct MenuWindow: View {
    @ObservedObject var model: OizysModel
    @State private var panel: Panel

    init(model: OizysModel, initial: Panel = .overview) {
        self.model = model
        _panel = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $panel) {
                    ForEach(Panel.allCases) { entry in
                        Text(entry.rawValue).tag(entry)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 184)
                HStack(spacing: 6) {
                    StatusDot(health: model.health)
                    Text(model.summary).font(.caption).foregroundStyle(Ink.faint)
                }
                .padding(10)
            }
            .frame(width: 184)

            Divider()

            ScrollView {
                PanelBody(model: model, panel: panel)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { model.refresh(); model.refreshSlowly() }
    }
}

/// Render sections separately to review the content below the window's scroll viewport.
struct PanelBody: View {
    @ObservedObject var model: OizysModel
    let panel: Panel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch panel {
            case .overview: OverviewPanel(model: model)
            case .displays: DisplaysPanel(model: model)
            case .arrangement: ArrangementPanel(model: model)
            case .calibrate: ColourPanel(model: model)
            case .diagnostics:
                ConnectionPanel(model: model)
                PortsPanel(model: model)
            case .settings: SettingsPanel(model: model)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Panels

private struct RecoveryElapsed: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text("Recovering for \(max(0, Int(context.date.timeIntervalSince(since)))) seconds")
                .font(.caption).foregroundStyle(Ink.secondary)
        }
    }
}

private struct ConnectionPanel: View {
    @ObservedObject var model: OizysModel
    var body: some View {
        SectionLabel(text: "Connection")
        HStack(spacing: 8) {
            StatusDot(health: model.health)
            Text(model.summary).font(.headline).foregroundStyle(Ink.primary)
        }
        Text(model.connectionHint).font(.callout).foregroundStyle(Ink.secondary).padding(.vertical, 6)
        if model.supervisorStatus?.phase == .recovering {
            RecoveryElapsed(since: model.connectionChangedAt)
        }
        HStack(spacing: 8) {
            QuietButton(title: model.primaryActionTitle,
                        disabled: !model.primaryActionEnabled, prominent: true) {
                model.performPrimaryAction()
            }
            if model.running && model.primaryActionTitle != "Stop" {
                QuietButton(title: "Stop", disabled: model.serviceBusy) { model.stop() }
            }
            QuietButton(title: "Check again") { model.refresh(); model.refreshSlowly() }
            QuietButton(title: "Export report…") { model.exportReport() }
            Spacer()
        }.padding(.vertical, 6)
        if !model.lastMessage.isEmpty {
            Text(model.lastMessage).font(.callout).foregroundStyle(Ink.secondary).padding(.top, 4)
        }
        DisclosureGroup("Recent connection states") {
            SectionLabel(text: "Recent observations", trailing: "this app session")
            ForEach(model.connectionEvents) { event in
                Row(event.text, event.date.formatted(date: .omitted, time: .standard))
            }
        }.padding(.top, 10)
    }
}

private struct OverviewPanel: View {
    @ObservedObject var model: OizysModel
    var body: some View {
        ConnectionPanel(model: model)
        SectionLabel(text: "Dock displays")
        ForEach([0, 1], id: \.self) { head in
            let display = model.displays.first { $0.head == head }
            let forwarding = model.screenRecordingGranted && model.running
                && model.supervisorStatus?.phase == .forwarding
                && ((model.supervisorStatus?.headMask ?? 0) & (1 << head)) != 0 && display != nil
            Row(label: head == 0 ? "Left dock display" : "Right dock display",
                detail: display?.geometry ?? "Not online") {
                Text(forwarding ? "Forwarding" : "Unavailable")
            }
        }
        SectionLabel(text: "Arrangement")
        ArrangementMap(displays: model.displays).frame(height: 160)
        ForEach(model.ports.filter(\.warning)) { port in
            Text(port.text).font(.callout).foregroundStyle(Ink.warn).padding(.top, 8)
        }
    }
}

private struct ArrangementMap: View {
    let displays: [OizysDisplay]
    var body: some View {
        Canvas { context, size in
            let rectangles = displays.map {
                CGRect(origin: $0.origin, size: $0.layoutSize ?? CGSize(width: $0.width, height: $0.height))
            }
            let bounds = rectangles.reduce(CGRect.null) { $0.union($1) }
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
            let scale = min((size.width - 24) / bounds.width, (size.height - 24) / bounds.height)
            for (display, rectangle) in zip(displays, rectangles) {
                let box = CGRect(x: 12 + (rectangle.minX - bounds.minX) * scale,
                                 y: 12 + (rectangle.minY - bounds.minY) * scale,
                                 width: rectangle.width * scale, height: rectangle.height * scale)
                context.fill(Path(roundedRect: box.insetBy(dx: 2, dy: 2), cornerRadius: 4), with: .color(Ink.panel))
                context.stroke(Path(roundedRect: box.insetBy(dx: 2, dy: 2), cornerRadius: 4), with: .color(Ink.hairline))
                let label = display.head.map { $0 == 0 ? "Left" : "Right" } ?? display.kind.rawValue
                context.draw(Text(label).font(.caption).foregroundStyle(Ink.primary), at: CGPoint(x: box.midX, y: box.midY))
            }
        }
        .accessibilityLabel("Display arrangement")
        .accessibilityValue(displays.map { "\($0.name), x \(Int($0.origin.x)), y \(Int($0.origin.y))" }.joined(separator: "; "))
    }
}

private struct ArrangementPanel: View {
    @ObservedObject var model: OizysModel
    var body: some View {
        SectionLabel(text: "Display arrangement")
        ArrangementMap(displays: model.displays).frame(height: 180)
        Text("Position and mirroring changes have a 15-second Keep or Revert confirmation.")
            .font(.callout).foregroundStyle(Ink.secondary).padding(.vertical, 8)
        ForEach(model.displays) { display in
            SectionLabel(text: display.name, trailing: display.main ? "main" : nil)
            PlacementRows(model: model, display: display)
        }
        Row(label: "Keep the other screens' resolutions") {
            QuietSwitch(isOn: Binding(
                get: { model.setting("display.keep_modes", "true") == "true" },
                set: { model.set("display.keep_modes", $0 ? "true" : "false") }),
                        label: "Keep the other screens' resolutions")
        }
        QuietButton(title: "Open Displays settings…") { DisplaySettings.openDisplaysSettings() }
            .padding(.top, 10)
    }
}

private struct DisplaysPanel: View {
    @ObservedObject var model: OizysModel

    var body: some View {
        SectionLabel(text: "Attached displays", trailing: "\(model.displays.count)")
        ForEach(model.displays) { display in
            DisplayCard(model: model, display: display)
        }
        NightShiftRows()
        DisclosureGroup("iPad and Sidecar") { SidecarPanel(model: model) }.padding(.top, 14)
        DisclosureGroup("Shared power settings") { PowerPanel(model: model) }.padding(.top, 14)

        SectionLabel(text: "What macOS keeps to itself")
        Text("HDR, Presets, True Tone and the display colour profile have no route out of "
             + "System Settings, and rotation only has an undocumented one that a display "
             + "driven over the dock has no framebuffer for. Everything else the Displays "
             + "pane does is above. Oizys has its own answer to the colour profile: the "
             + "Colour panel measures a head and stores a per-channel correction for it.")
            .font(.caption).foregroundStyle(Ink.faint)
        HStack(spacing: 8) {
            QuietButton(title: "Open Displays settings…") {
                DisplaySettings.openDisplaysSettings()
            }
            Spacer()
        }
        .padding(.top, 8)
    }
}

/*
 * One display, and everything that can be done to it from here.
 *
 * An Oizys head is the exception in every row. Its resolution is fixed: the dock is trained
 * for 1920x1080 and ScreenCaptureKit is opened on a surface that size, so offering a
 * resolution list for one would be offering a way to make the panel go dark. Its brightness
 * is a gain in the encoder rather than a DDC write, for the same reason its monitor's own
 * controls stay on its front panel — a DisplayLink output has no I2C channel.
 */
private struct DisplayCard: View {
    @ObservedObject var model: OizysModel
    let display: OizysDisplay

    private var badges: String {
        var parts = ["at \(Int(display.origin.x)),\(Int(display.origin.y))"]
        if display.mirrored { parts.append("mirrored") }
        if display.main { parts.append("main") }
        let angle = DisplaySettings.rotation(display.id)
        if angle != 0 { parts.append("rotated \(angle)°") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Row(label: display.name, detail: "\(display.geometry) · \(badges)") {
            Text(display.kind.rawValue).foregroundStyle(Ink.faint)
        }
        if display.kind == .head {
            Row(label: "Resolution", detail: "Fixed by the dock: the heads are trained for "
                                             + "1920×1080 and captured at that size.") {
                Text("1920 × 1080 · 60 Hz")
            }
        } else {
            ModeRows(model: model, display: display)
        }
        if let head = display.head {
            HeadBrightnessRow(model: model, head: head)
            HeadContrastRow(model: model, head: head)
            HeadPowerRows(model: model, head: head)
        } else if display.kind != .sidecar {
            BrightnessRow(model: model, display: display)
        }
    }
}

/// Resolution and refresh rate, split the way the Displays pane splits them: one control for
/// the size, one for the rates that size offers. A display with a single rate shows none.
private struct ModeRows: View {
    @ObservedObject var model: OizysModel
    let display: OizysDisplay

    var body: some View {
        let modes = model.isPreview
            ? [DisplaySettings.Mode(index: 0, width: display.width, height: display.height,
                                    pixelWidth: display.width, pixelHeight: display.height,
                                    refresh: display.refresh)]
            : DisplaySettings.modes(display.id)
        let now = model.isPreview ? modes.first : DisplaySettings.current(display.id)
        if modes.isEmpty {
            Row(label: "Resolution", detail: "This display did not report a mode list.") {
                Text("—")
            }
        } else {
            // One entry per size; the rate control below picks among that size's rates.
            let sizes = sizeOptions(modes)
            let selectedSize = now.flatMap { current in
                sizes.first { $0.width == current.width && $0.height == current.height
                    && $0.hiDPI == current.hiDPI }
            }
            let options = sizes.map { ($0.label, $0.index) }
                + (selectedSize == nil ? [("\(display.width) × \(display.height)", -1)] : [])
            VStack(alignment: .leading, spacing: 6) {
                Text("RESOLUTION").font(Ink.section).tracking(1.1).foregroundStyle(Ink.faint)
                ChipChoice(options: options,
                           selection: Binding(get: { selectedSize?.index ?? -1 },
                                              set: { apply(modes, $0) }),
                           label: "Resolution")
            }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }

            if let now, case let rates = modes.filter({
                $0.width == now.width && $0.height == now.height && $0.hiDPI == now.hiDPI
            }),
               rates.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("REFRESH RATE").font(Ink.section).tracking(1.1).foregroundStyle(Ink.faint)
                    ChipChoice(options: rates.map { ($0.rate, $0.index) },
                               selection: Binding(get: { now.index }, set: { apply(modes, $0) }),
                               label: "Refresh rate")
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
            }
        }
    }

    /// The highest-refresh entry for each distinct size, so the size chips are one per size.
    /// Picking a size keeps whatever rate that size offers first; the rate chips move it.
    private func sizeOptions(_ modes: [DisplaySettings.Mode]) -> [DisplaySettings.Mode] {
        var seen = Set<String>()
        return modes.filter { seen.insert("\($0.width)x\($0.height)x\($0.hiDPI)").inserted }
    }

    private func apply(_ modes: [DisplaySettings.Mode], _ index: Int) {
        guard let mode = modes.first(where: { $0.index == index }) else { return }
        if DisplaySettings.apply(display.id, mode) { model.refresh() }
        else { model.lastMessage = "Could not change this display mode." }
    }
}

/// Where this display sits, and what it is showing. Mirroring and "make this the main
/// display" are the two arrangement choices with consequences; the sides are a shortcut for
/// the drag that System Settings makes you do.
private struct PlacementRows: View {
    @ObservedObject var model: OizysModel
    let display: OizysDisplay

    private var others: [OizysDisplay] {
        model.displays.filter { $0.id != display.id }
    }

    /// The heads, left to right. Moving one of them moves both: the driver seats them as a
    /// contiguous run and reseats anything else, so a lone head would snap back.
    private var run: [CGDirectDisplayID] {
        guard display.head != nil else { return [display.id] }
        return model.displays.filter { $0.head != nil }
            .sorted { ($0.head ?? 0) < ($1.head ?? 0) }.map(\.id)
    }

    var body: some View {
        if let anchor, !run.contains(anchor.id) {
            Row(label: "Position",
                detail: "Relative to \(anchor.name), edges touching"
                        + (run.count > 1 ? ". Moves both heads: the driver seats them as a pair."
                                         : ".")) {
                HStack(spacing: 4) {
                        ForEach(DisplaySettings.Side.allCases, id: \.self) { side in
                        QuietButton(title: side.rawValue) {
                            if DisplaySettings.placeRun(run, side, of: anchor.id) { model.refresh() }
                            else { model.lastMessage = "Could not move the display." }
                        }
                    }
                }
            }
        }
        if display.head != nil {
            Row(label: "Mirroring",
                detail: "A head in a mirror set scans out the other display's desktop at the "
                        + "wrong aspect ratio, so the driver refuses to run with one.") {
                Text("Not available")
            }
        }
        HStack(spacing: 8) {
            if !display.main {
                QuietButton(title: "Make main") {
                    if DisplaySettings.makeMain(display.id) { model.refresh() }
                    else { model.lastMessage = "Could not make this display primary." }
                }
            }
            if display.head == nil, !display.main, let anchor, anchor.head == nil {
                QuietButton(title: display.mirrored ? "Unmirror" : "Mirror \(anchor.name)") {
                    if DisplaySettings.mirror(display.id, of: display.mirrored ? nil : anchor.id) {
                        model.refresh()
                    } else { model.lastMessage = "Could not change mirroring." }
                }
            }
            Spacer()
        }
        .padding(.top, 6).padding(.bottom, 14)
    }

    /// The main display, or failing that whatever else is attached. A display cannot be
    /// placed relative to itself, and the main one is what everybody means by "next to".
    private var anchor: OizysDisplay? {
        others.first { $0.main } ?? others.first
    }
}

/// Night Shift, which is a Displays setting on this Mac and lives in a private framework.
/// The rows disappear rather than misbehave on a release that has moved it.
private struct NightShiftRows: View {
    @State private var on = NightShift.enabled
    @State private var strength = NightShift.strength

    var body: some View {
        if NightShift.available {
            SectionLabel(text: "Night Shift")
            Row(label: "Night Shift", detail: "Warms every display, Oizys heads included: it "
                                              + "is applied by the window server, above the "
                                              + "pixels Oizys reads.") {
                QuietSwitch(isOn: Binding(get: { on },
                                          set: { on = $0; NightShift.setEnabled($0) }),
                                    label: "Night Shift")
            }
            Row(label: "Warmth") {
                HStack(spacing: 10) {
                    HalftoneSlider(value: Binding(get: { Double(strength) },
                                                  set: { strength = Float($0) }),
                                   onCommit: { level in
                                       if !NightShift.setStrength(Float(level)) {
                                           strength = NightShift.strength
                                       }
                                   }, label: "Night Shift warmth")
                        .frame(width: 150)
                    Text("\(Int(strength * 100))%").frame(width: 38, alignment: .trailing)
                }
            }
        }
    }
}

private struct HeadBrightnessRow: View {
    @ObservedObject var model: OizysModel
    let head: Int
    var body: some View {
        let value = model.headBrightness(head)
        Row(label: "Picture brightness",
            detail: "A gain applied while encoding, because Oizys owns every pixel this "
                    + "panel receives. It dims the picture, not the backlight.") {
            HStack(spacing: 10) {
                    HalftoneSlider(value: Binding(
                        get: { (value - 10) / 90 },
                        set: { model.setHeadBrightness(head, 10 + $0 * 90, persist: false) }),
                                   onCommit: { model.setHeadBrightness(head, 10 + $0 * 90) },
                                   label: head == 0 ? "Left head brightness" : "Right head brightness",
                                   announcedValue: "\(Int(value)) percent")
                    .frame(width: 150)
                Text("\(Int(value))%").frame(width: 38, alignment: .trailing)
                QuietButton(title: "Reset", disabled: value == 100) { model.setHeadBrightness(head, 100) }
            }
        }
    }
}

private struct HeadContrastRow: View {
    @ObservedObject var model: OizysModel
    let head: Int
    var body: some View {
        let value = model.headContrast(head)
        Row(label: "Contrast",
            detail: value > 100 ? "Above 100 clips the brightest pixels, as on a monitor."
                                : "Pivots on mid-grey, so it goes both ways.") {
            HStack(spacing: 10) {
                    HalftoneSlider(value: Binding(
                        get: { (value - 50) / 100 },
                        set: { model.setHeadContrast(head, 50 + $0 * 100, persist: false) }),
                                   onCommit: { model.setHeadContrast(head, 50 + $0 * 100) },
                                   label: head == 0 ? "Left head contrast" : "Right head contrast",
                                   announcedValue: "\(Int(value)) percent")
                    .frame(width: 150)
                Text("\(Int(value))%").frame(width: 38, alignment: .trailing)
            }
        }
    }
}

private struct BrightnessRow: View {
    @ObservedObject var model: OizysModel
    let display: OizysDisplay
    var body: some View {
        let failed = model.brightnessError.contains(display.id)
        Row(label: "Brightness", detail: failed
            ? "This monitor did not answer a DDC brightness request." : nil) {
            if let value = model.brightness[display.id] {
                let top = model.brightnessMaximum[display.id] ?? 100
                HStack(spacing: 10) {
                    HalftoneSlider(value: Binding(
                        get: { top > 0 ? value / top : 0 },
                        set: { model.setBrightness(display.id, $0 * top, persist: false) }),
                                   onCommit: { model.setBrightness(display.id, $0 * top) },
                                   label: "\(display.name) brightness",
                                   announcedValue: "\(Int(value)) of \(Int(top))")
                        .frame(width: 150)
                    Text("\(Int(value))").frame(width: 38, alignment: .trailing)
                }
            } else {
                QuietButton(title: failed ? "Retry" : "Read",
                            disabled: model.brightnessBusy.contains(display.id)) {
                    model.readBrightness(display.id)
                }
            }
        }
    }
}

private struct PowerPanel: View {
    @ObservedObject var model: OizysModel

    var body: some View {
        SectionLabel(text: "System")
        Row(label: "macOS display sleep",
            detail: "One timer for every screen; macOS exposes no per-monitor setting.") {
            HStack(spacing: 8) {
                Text(model.displaySleepMinutes > 0 ? "\(model.displaySleepMinutes) min" : "Never")
                QuietButton(title: "Change…") { model.openDisplaySleepSettings() }
            }
        }

        SectionLabel(text: "Power saving")
        Row(label: "Lower the frame rate when idle",
            detail: "Capture, encoding and USB all scale with it, and a still desktop has "
                    + "nothing to send at any rate. The first change restores full speed.") {
            QuietSwitch(isOn: Binding(
                get: { model.setting("power.saving", "true") == "true" },
                set: { model.set("power.saving", $0 ? "true" : "false") }),
                          label: "Lower the frame rate when idle")
        }
        if model.setting("power.saving", "true") == "true" {
            Row(label: "Idle frame rate") {
                SegmentedChoice(options: [("5", "5"), ("10", "10"), ("15", "15"), ("30", "30")],
                                selection: Binding(get: { model.setting("power.idle_fps", "10") },
                                                   set: { model.set("power.idle_fps", $0) }),
                                label: "Idle frame rate")
            }
            Row(label: "Idle after") {
                SegmentedChoice(options: [("10s", "10"), ("20s", "20"), ("60s", "60"), ("5m", "300")],
                                selection: Binding(get: { model.setting("power.idle_after_s", "20") },
                                                   set: { model.set("power.idle_after_s", $0) }),
                                label: "Idle after")
            }
        }
        Text("Everything here is re-read by a running driver within a second. Nothing needs a restart.")
            .font(.caption).foregroundStyle(Ink.faint).padding(.top, 8)
        DisclosureGroup("Why a monitor sleeps") {
            Text("macOS has one display-sleep timer for all screens. Each monitor can also sleep when its input stops changing. Use the per-display Keep awake control for a monitor that sleeps too soon, or Blank when idle to darken one monitor without removing its desktop.")
                .font(.callout).foregroundStyle(Ink.secondary).padding(.top, 6)
        }.padding(.top, 10)
    }
}

/// The two opposite controls, per head. They are opposite on purpose: one monitor sleeping
/// too eagerly and another never sleeping are different faults on the same desk.
private struct HeadPowerRows: View {
    @ObservedObject var model: OizysModel
    let head: Int

    var body: some View {
        let keepalive = model.headSetting(head, "keepalive_s", "0")
        let standby = model.headSetting(head, "standby_min", "0")
        Row(label: "Keep this display awake",
            detail: keepalive == "0"
                ? "Off. This panel may sleep on its own once the desktop stops changing."
                : "Repaints the cached image on this interval, so the panel never sees a still input.") {
            SegmentedChoice(options: [("Off", "0"), ("30s", "30"), ("60s", "60"), ("2m", "120")],
                            selection: Binding(get: { keepalive },
                                               set: { model.setHeadSetting(head, "keepalive_s", $0) }),
                            label: "\(head == 0 ? "Left" : "Right") display keep awake")
        }
        Row(label: "Let it blank when idle",
            detail: standby == "0"
                ? "Off. This panel stays lit for as long as macOS keeps the desktop awake."
                : "Goes black after this long with nothing changing. The display stays in place, "
                  + "so no window moves and the next frame brings it straight back.") {
            SegmentedChoice(options: [("Never", "0"), ("4m", "4"), ("10m", "10"), ("30m", "30")],
                            selection: Binding(get: { standby },
                                               set: { model.setHeadSetting(head, "standby_min", $0) }),
                            label: "\(head == 0 ? "Left" : "Right") display blank when idle")
        }
        if keepalive != "0" && standby != "0" {
            Text("Blanking wins: this panel is repainted while it is in use and goes black after "
                 + standby + " minutes still.")
                .font(.caption).foregroundStyle(Ink.warn).padding(.top, 4)
        }
    }
}

private struct SidecarPanel: View {
    @ObservedObject var model: OizysModel
    @ObservedObject private var auto = SidecarAuto.shared
    @State private var devices: [(name: String, handle: NSObject)] = []
    private var attached: OizysDisplay? { model.displays.first { $0.kind == .sidecar } }

    private var autoConnect: Bool { model.setting("sidecar.auto_connect", "false") == "true" }

    private func setSidecar(_ key: String, _ value: String) {
        model.set("sidecar.\(key)", value)
    }

    var body: some View {
        SectionLabel(text: "Sidecar")
        Row(label: "iPad display", detail: attached.map { $0.geometry }) {
            Text(attached == nil ? "Not attached" : "Attached")
                .foregroundStyle(attached == nil ? Ink.faint : Ink.primary)
        }
        if attached != nil {
            Row(label: "Brightness",
                detail: "A gamma ramp, not the iPad's backlight — macOS exposes no way to "
                        + "reach that, and Oizys never sees these pixels. The iPad's own "
                        + "slider still works and stacks with this.") {
                HStack(spacing: 10) {
                    HalftoneSlider(value: Binding(
                        get: { (model.sidecarTint("brightness") - 10) / 90 },
                        set: { model.setSidecarTint("brightness", 10 + $0 * 90, persist: false) }),
                                   onCommit: { model.setSidecarTint("brightness", 10 + $0 * 90) },
                                   label: "Sidecar brightness",
                                   announcedValue: "\(Int(model.sidecarTint("brightness"))) percent")
                        .frame(width: 150)
                    Text("\(Int(model.sidecarTint("brightness")))%").frame(width: 38, alignment: .trailing)
                }
            }
            Row(label: "Contrast", detail: "Pivots on mid-grey; above 100 clips the brightest pixels.") {
                HStack(spacing: 10) {
                    HalftoneSlider(value: Binding(
                        get: { (model.sidecarTint("contrast") - 50) / 100 },
                        set: { model.setSidecarTint("contrast", 50 + $0 * 100, persist: false) }),
                                   onCommit: { model.setSidecarTint("contrast", 50 + $0 * 100) },
                                   label: "Sidecar contrast",
                                   announcedValue: "\(Int(model.sidecarTint("contrast"))) percent")
                        .frame(width: 150)
                    Text("\(Int(model.sidecarTint("contrast")))%").frame(width: 38, alignment: .trailing)
                }
            }
        }
        if let attached {
            Row(label: "Arrangement", detail: "at \(Int(attached.origin.x)),\(Int(attached.origin.y))") {
                QuietButton(title: attached.mirrored ? "Unmirror" : "Mirror main") {
                    if DisplaySettings.mirror(attached.id,
                                              of: attached.mirrored ? nil : CGMainDisplayID()) {
                        model.refresh()
                    } else { model.lastMessage = "Could not change Sidecar mirroring." }
                }
            }
        }

        SectionLabel(text: "Connect")
        if SidecarBridge.available {
            if devices.isEmpty {
                Row("Nearby iPads", "None found")
            }
            ForEach(devices.indices, id: \.self) { index in
                Row(label: devices[index].name) {
                    QuietButton(title: attached == nil ? "Connect" : "Disconnect") { [model] in
                        let sent: Bool
                        if attached == nil {
                            sent = SidecarBridge.connect(devices[index].handle) { [weak model] error in
                                model?.lastMessage = error.map { "Sidecar connect failed: \($0.localizedDescription)" }
                                    ?? "Sidecar connected."
                                model?.refresh()
                            }
                        } else {
                            sent = SidecarBridge.disconnect(devices[index].handle) { [weak model] error in
                                model?.lastMessage = error.map { "Sidecar disconnect failed: \($0.localizedDescription)" }
                                    ?? "Sidecar disconnected."
                                model?.refresh()
                            }
                        }
                        if !sent { model.lastMessage = "Sidecar is unavailable on this Mac." }
                    }
                }
            }
            HStack { QuietButton(title: "Look again") { devices = SidecarBridge.devices() }; Spacer() }
                .padding(.top, 10)

            SectionLabel(text: "Connect on its own", trailing: auto.status)
            Row(label: "Attach the iPad when it turns up",
                detail: "Nothing polls for it. macOS tells Oizys when the iPad comes into "
                        + "range, and that is the only moment this looks at anything.") {
                QuietSwitch(isOn: Binding(get: { autoConnect },
                                          set: { setSidecar("auto_connect", $0 ? "true" : "false") }),
                                    label: "Attach the iPad when it turns up")
            }
            if autoConnect {
                Row(label: "Only at a desk",
                    detail: "On the charger with another screen attached. An iPad in your "
                            + "hands on a sofa is not a second monitor, and taking it over "
                            + "there is worse than doing nothing.") {
                    QuietSwitch(isOn: Binding(
                        get: { model.setting("sidecar.require_desk", "true") == "true" },
                        set: { setSidecar("require_desk", $0 ? "true" : "false") }),
                                      label: "Only at a desk")
                }
                Row(label: "Which iPad",
                    detail: model.setting("sidecar.device", "").isEmpty
                        ? "Whichever is offered first."
                        : "Falls back to the first one offered if this name stops matching.") {
                    SegmentedChoice(options: [("Any", "")] + devices.map { ($0.name, $0.name) },
                                    selection: Binding(
                                        get: { model.setting("sidecar.device", "") },
                                        set: { setSidecar("device", $0) }),
                                    label: "Which iPad")
                }
                Text("Disconnecting the iPad by hand is respected: Oizys leaves it alone for "
                     + "five minutes rather than taking the display straight back.")
                    .font(.caption).foregroundStyle(Ink.faint).padding(.top, 4)
            }

            Text("macOS ships no public interface for connecting Sidecar, so this drives a private "
                 + "Apple framework. It can stop working after any macOS update, and if it does, "
                 + "this section says so rather than offering a button that does nothing. "
                 + "Everything above works through the ordinary display APIs and is unaffected.")
                .font(.caption).foregroundStyle(Ink.faint).padding(.top, 10)
        } else {
            Text("Connecting Sidecar is not available on this version of macOS. Use the Displays "
                 + "menu in Control Center; once the iPad is attached, every control above works "
                 + "on it like any other screen.")
                .font(Ink.label).foregroundStyle(Ink.secondary).padding(.vertical, 6)
            HStack { QuietButton(title: "Open Displays settings") { SidecarBridge.openSystemSidecar() }; Spacer() }
        }

        SectionLabel(text: "Power")
        Text("An iPad loses charge while it works as a display because it draws more than the "
             + "cable supplies, and the difference comes out of the battery. No software on this "
             + "Mac can raise a dock port's output: the dock negotiates that with the iPad "
             + "directly and never tells the host.\n\n"
             + "Check Ports & power first. If no Apple device appears there while Sidecar is "
             + "running, the iPad is on Wi-Fi — the more expensive mode — or its cable carries "
             + "power without data. Either way, charging it from its own adapter is the only "
             + "thing that reliably gains ground during use.")
            .font(Ink.label).foregroundStyle(Ink.secondary)
        .onAppear { devices = SidecarBridge.devices() }
    }
}

/// The colour panel: run the phone calibration, and see or clear what it stored.
private struct ColourPanel: View {
    @ObservedObject var model: OizysModel
    @StateObject private var session = CalibrationSession()

    var body: some View {
        SectionLabel(text: "Match the monitors")
            .onDisappear { session.stop() }
        Text("Compare grey patches with an iPhone camera to make the monitors look more alike. This is a relative match, not a measured colour profile.")
            .font(Ink.label).foregroundStyle(Ink.secondary)

        switch session.phase {
        case .idle:
            Row(label: "Phone calibration",
                detail: model.health == .live ? "Scan a QR code, then measure eight grey patches per monitor."
                    : "Connect both dock displays and grant Screen Recording before starting.") {
                QuietButton(title: "Start", disabled: model.health != .live || model.configPath.isEmpty || model.isPreview) {
                    session.start(configPath: model.configPath)
                }
            }
        case .waitingForPhone:
            if let qr = session.qr {
                HStack(alignment: .top, spacing: 18) {
                    Image(nsImage: qr).interpolation(.none)
                        .frame(width: 150, height: 150)
                        .background(Color.white).cornerRadius(6)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan this with the iPhone camera.")
                            .font(Ink.label).foregroundStyle(Ink.primary)
                        Text("Before allowing camera access, compare Safari's certificate "
                             + "SHA-256 fingerprint with this Mac. Stop if it differs or "
                             + "Safari cannot show it.")
                            .font(.callout).foregroundStyle(Ink.secondary)
                        Text(session.certificateFingerprint)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Ink.secondary).textSelection(.enabled)
                        Text(session.address).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Ink.faint).textSelection(.enabled)
                        QuietButton(title: "Cancel") { session.stop() }
                    }
                }
                .padding(.vertical, 10)
            }
        case let .measuring(display, patch, total):
            Row(label: "Measuring monitor \(display + 1)",
                detail: "Hold the phone steady with the box filled by the lit monitor.") {
                HStack(spacing: 10) {
                    Halftone(value: Double(patch + 1) / Double(total)).frame(width: 110, height: 14)
                    Text("\(patch + 1)/\(total)")
                }
            }
            Text("Certificate SHA-256: \(session.certificateFingerprint)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Ink.secondary).textSelection(.enabled)
            HStack { QuietButton(title: "Stop") { session.stop() }; Spacer() }.padding(.top, 8)
        case .solving:
            Row(label: "Solving", detail: "The correction is saved only if this session remains active.") {
                QuietButton(title: "Cancel") { session.stop() }
            }
        case let .done(text):
            SectionLabel(text: "Result")
            Text(text).font(.system(.callout, design: .monospaced))
                .foregroundStyle(Ink.secondary).textSelection(.enabled)
            HStack(spacing: 8) {
                QuietButton(title: "Run again", disabled: model.health != .live || model.configPath.isEmpty || model.isPreview) {
                    session.start(configPath: model.configPath)
                }
                Spacer()
            }.padding(.top, 10)
        case let .failed(text):
            Text(text).font(.callout).foregroundStyle(Ink.warn).padding(.vertical, 6)
            HStack {
                QuietButton(title: "Try again", disabled: model.health != .live || model.configPath.isEmpty || model.isPreview) {
                    session.start(configPath: model.configPath)
                }
                Spacer()
            }
        }

        DisclosureGroup("Measurement limits") {
            Text("Safari does not provide exposure or white-balance lock. Camera readings are relative, so this cannot certify colour accuracy. Matching only darkens the picture; the dimmest monitor becomes the reference.")
                .font(.callout).foregroundStyle(Ink.secondary).padding(.top, 6)
        }.padding(.top, 14)
        HStack(spacing: 8) {
            QuietButton(title: "Show stored correction") { model.run(["calibrate", "show"]) }
            QuietButton(title: "Clear stored correction", disabled: session.isActive) { model.run(["calibrate", "clear"]) }
            if session.canUndo {
                QuietButton(title: "Undo last calibration", disabled: session.isActive) { session.undo() }
            }
            Spacer()
        }
            .padding(.top, 10)
        if !model.lastMessage.isEmpty {
            Text(model.lastMessage).font(.system(.caption, design: .monospaced))
                .foregroundStyle(Ink.faint).padding(.top, 6)
        }
    }
}

private struct PortsPanel: View {
    @ObservedObject var model: OizysModel
    var body: some View {
        SectionLabel(text: "USB ports", trailing: "read-only")
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.ports) { row in
                Text(row.text).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(row.warning ? Ink.warn : Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ink.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ink.hairline))
        Text("Actual is the negotiated link rate. Capable is the USB revision's maximum. "
             + "A powered dock's downstream power budget is not exposed to macOS.")
            .font(.caption).foregroundStyle(Ink.faint).padding(.top, 6)
        HStack { QuietButton(title: "Scan again") { model.refreshSlowly() }; Spacer() }.padding(.top, 10)
    }
}

private struct SettingsPanel: View {
    @ObservedObject var model: OizysModel
    @State private var editing: String?
    @State private var draft = ""
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    private var filtered: [Setting] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.settings.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        SectionLabel(text: "App settings")
        Row(label: "Start at login") {
            QuietSwitch(isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginStart($0) }),
                        disabled: model.serviceBusy, label: "Start at login")
        }
        Row(label: "Announce new displays", detail: "A short ripple on the screen that just arrived.") {
            HStack(spacing: 8) {
                QuietButton(title: "Preview") { ConnectOverlay.preview(model: model) }
                QuietSwitch(isOn: Binding(get: { ConnectOverlay.enabled }, set: { ConnectOverlay.enabled = $0 }),
                            label: "Announce new displays")
            }
        }
        MenuBarSection()
        SectionLabel(text: "Advanced driver settings", trailing: "applied live")
        HStack(spacing: 8) {
            TextField("Search driver settings", text: $search)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Search driver settings")
                .focused($searchFocused)
            Button("Find") { searchFocused = true }
                .buttonStyle(.bordered).controlSize(.small).keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("Find driver setting")
        }.padding(.vertical, 6)
        if filtered.isEmpty {
            Text(model.settings.isEmpty ? "Driver settings have not been read yet." : "No matching settings.")
                .font(.callout).foregroundStyle(Ink.secondary).padding(.vertical, 6)
        }
        ForEach(filtered) { setting in
            Row(label: setting.id,
                detail: "Default: \(setting.fallback.isEmpty ? "empty" : setting.fallback)") {
                if editing == setting.id {
                    HStack(spacing: 6) {
                        TextField("Value", text: $draft)
                            .accessibilityLabel("\(setting.id) value")
                            .textFieldStyle(.roundedBorder).frame(width: 96).controlSize(.small)
                            .onSubmit { save(setting) }
                        QuietButton(title: "Set") { save(setting) }
                        QuietButton(title: "Cancel") { editing = nil }
                    }
                } else {
                    Button { editing = setting.id; draft = setting.value } label: {
                        Text(setting.value).foregroundStyle(setting.changed ? Ink.primary : Ink.secondary)
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel("Edit \(setting.id), current value \(setting.value)")
                }
                QuietButton(title: "Reset", disabled: !setting.changed) { model.resetSetting(setting.id) }
                    .accessibilityLabel("Reset \(setting.id) to default")
            }
        }
        HStack(spacing: 8) {
            QuietButton(title: "Reset all to defaults") { model.run(["config", "reset"]) }
            QuietButton(title: "Restart driver", disabled: model.serviceBusy) { model.restart() }
            Spacer()
        }
        .padding(.top, 14)
        Text("A running driver re-reads this file within a second, so most changes take effect "
             + "without a restart. Values outside a setting's safe range are clamped rather than rejected. "
             + "control.poll_ms is load-bearing: polling the dock harder than its default reads "
             + "back as a false disconnect.")
            .font(.caption).foregroundStyle(Ink.faint).padding(.top, 8)
        if !model.lastMessage.isEmpty {
            Text(model.lastMessage).font(.callout).foregroundStyle(Ink.secondary).padding(.top, 8)
        }
        DisclosureGroup("About and permission details") { InfoPanel(model: model) }.padding(.top, 14)
        DisclosureGroup("Help: how Oizys works") { AboutPanel(model: model) }.padding(.top, 14)
    }

    private func save(_ setting: Setting) {
        model.run(["config", "set", setting.id, draft]) { success in
            if success { editing = nil }
        }
    }
}

// MARK: - Diagram

/*
 * About: what this build is, and the one permission it needs.
 *
 * The permission lives here because macOS's own dialog cannot be dismissed for good and this
 * app used to raise it on launch, on reopen, and every five seconds a dock was plugged in
 * without access. A row that states the truth and a button somebody presses on purpose does
 * the same job without following anyone around.
 */
private struct InfoPanel: View {
    @ObservedObject var model: OizysModel
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private func text(_ key: String) -> String { info[key] as? String ?? "unknown" }

    var body: some View {
        if !model.screenRecordingGranted {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(health: .waiting)
                    Text("Finish setting up Oizys")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                }
                Text("Oizys needs Screen & System Audio Recording to capture your desktop and send it to the dock. macOS requires you to approve this once in System Settings; Oizys cannot grant it for you.")
                    .font(Ink.label).foregroundStyle(Ink.secondary)
                HStack(spacing: 8) {
                    QuietButton(title: "Open Screen Recording Settings…") {
                        model.requestScreenRecording()
                    }
                    QuietButton(title: "Check again") { model.refresh() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.hairline))
            .padding(.bottom, 6)
        }
        SectionLabel(text: "Permission")
        Row(label: "Screen Recording",
            detail: model.screenRecordingGranted
                ? "Granted to this app. The driver holds its own, and reports to the log below."
                : "Oizys captures your desktop to encode it for the dock. Without this, the "
                  + "driver starts, declines to take the dock, and waits.") {
            HStack(spacing: 8) {
                Text(model.screenRecordingGranted ? "Granted" : "Not granted")
                    .foregroundStyle(model.screenRecordingGranted ? Ink.primary : Ink.warn)
                if !model.screenRecordingGranted {
                    QuietButton(title: "Grant…") { model.requestScreenRecording() }
                }
            }
        }
        Text("Local development builds may need Screen Recording approved again after a rebuild. "
             + "If the dock remains blocked while an old Oizys entry is enabled, check the current "
             + "app in System Settings. Oizys requests access only when you press Grant.")
            .font(.caption).foregroundStyle(Ink.faint).padding(.top, 6)

        SectionLabel(text: "This build")
        Row("Version", text("CFBundleShortVersionString"))
        Row("Variant", text("OizysVariant"))
        Row("Identifier", text("CFBundleIdentifier"))

        SectionLabel(text: "Where things are")
        Row("Settings", model.configPath.isEmpty ? "not read yet" : model.configPath)
        Row("Service log", model.serviceLogPath,
            detail: "One line per refusal from the login agent; empty when it is running.")
        HStack(spacing: 8) {
            QuietButton(title: "Reveal settings") {
                guard !model.configPath.isEmpty else { return }
                NSWorkspace.shared.selectFile(model.configPath, inFileViewerRootedAtPath: "")
            }
            QuietButton(title: "Reveal log") {
                NSWorkspace.shared.selectFile(model.serviceLogPath, inFileViewerRootedAtPath: "")
            }
            Spacer()
        }
        .padding(.top, 10)
    }
}

private struct AboutPanel: View {
    @ObservedObject var model: OizysModel
    var body: some View {
        SectionLabel(text: "The path a pixel takes")
        SignalPath(model: model)
            .frame(height: 172)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.hairline))
        Text("Your desktop is captured by macOS, encoded in Oizys's own C encoder, and sent to "
             + "the dock over USB as the colour strips its hardware expects. No DisplayLink "
             + "software runs, and no vendor driver is loaded.")
            .font(Ink.label).foregroundStyle(Ink.secondary).padding(.top, 12)

        SectionLabel(text: "What moves, and when")
        Row("Still desktop", "0 bytes on the video link")
        Row("Something moved", "only the tiles whose pixels changed")
        Row("After a reconnect", "one full frame, sent three times")
        Text("Each frame rides three consecutive presentations so it reaches every buffer the "
             + "dock rotates through. A still desktop is silent, which is why a panel can decide "
             + "nothing is arriving and sleep — see Standby.")
            .font(.caption).foregroundStyle(Ink.faint).padding(.top, 8)
    }
}

/// The live topology, not a picture of one: the stages are fixed, the heads and their state
/// come from what is actually attached right now.
private struct SignalPath: View {
    @ObservedObject var model: OizysModel

    private var heads: [OizysDisplay] { model.displays.filter { $0.kind == .head } }

    var body: some View {
        Canvas { context, size in
            // Six columns, laid out as fractions so the panels never run off the right edge
            // and their labels never land on the node beside them.
            let column: [CGFloat] = [0.08, 0.22, 0.36, 0.50, 0.66, 0.87]
            let midY = size.height * 0.40
            let stages = ["Desktop", "Capture", "Encoder", "USB"]

            func point(_ index: Int, _ y: CGFloat = 0) -> CGPoint {
                CGPoint(x: column[index] * size.width, y: midY + y)
            }
            func caption(_ text: String, _ at: CGPoint, _ tint: Color, _ size: CGFloat = 9) {
                context.draw(Text(text).font(.system(size: size, weight: .medium))
                    .foregroundStyle(tint), at: at, anchor: .center)
            }

            for (index, stage) in stages.enumerated() {
                let centre = point(index)
                stipple(&context, at: centre, radius: 16,
                        alpha: model.running ? 0.85 : 0.4, dots: 24, seed: index)
                caption(stage, CGPoint(x: centre.x, y: midY + 30), Ink.secondary)
                dotted(&context, from: CGPoint(x: centre.x + 19, y: midY),
                       to: CGPoint(x: point(index + 1).x - 19, y: midY),
                       alpha: model.running ? 0.6 : 0.22)
            }

            let dock = point(4)
            stipple(&context, at: dock, radius: 20,
                    alpha: model.dockPresent ? 0.9 : 0.25, dots: 30, seed: 9)
            caption(model.dockPresent ? "Dock" : "No dock", CGPoint(x: dock.x, y: midY + 34),
                    model.dockPresent ? Ink.secondary : Ink.faint)

            // One branch per head, stacked clear of the dock's own label.
            let panels: [OizysDisplay?] = heads.isEmpty ? [nil, nil] : heads.map { Optional($0) }
            for (index, head) in panels.enumerated() {
                let offset = (CGFloat(index) - CGFloat(panels.count - 1) / 2) * 66
                let centre = point(5, offset)
                let alive = head != nil
                dotted(&context, from: CGPoint(x: dock.x + 23, y: midY),
                       to: CGPoint(x: centre.x - 26, y: centre.y), alpha: alive ? 0.6 : 0.16)
                let box = CGRect(x: centre.x - 25, y: centre.y - 15, width: 50, height: 30)
                context.stroke(Path(roundedRect: box, cornerRadius: 3),
                               with: .color(.white.opacity(alive ? 0.55 : 0.16)), lineWidth: 1)
                if alive { stipple(&context, at: centre, radius: 9, alpha: 0.5, dots: 14, seed: 20 + index) }
                caption(head.map { "\($0.width)×\($0.height)" } ?? "no head",
                        CGPoint(x: centre.x, y: centre.y + 26),
                        alive ? Ink.faint : Ink.faint.opacity(0.6), 8)
            }
        }
        .allowsHitTesting(false)
    }

    private func stipple(_ context: inout GraphicsContext, at centre: CGPoint, radius: CGFloat,
                         alpha: Double, dots: Int, seed: Int) {
        for ring in 0..<3 {
            let scale = radius * (0.42 + CGFloat(ring) * 0.29)
            let count = dots - ring * 5
            for step in 0..<max(4, count) {
                let angle = Double(step) / Double(max(4, count)) * .pi * 2 + Double(seed + ring) * 0.4
                let point = CGRect(x: centre.x + CGFloat(Darwin.cos(angle)) * scale - 0.8,
                                   y: centre.y + CGFloat(Darwin.sin(angle)) * scale - 0.8,
                                   width: 1.6, height: 1.6)
                context.fill(Path(ellipseIn: point),
                             with: .color(.white.opacity(alpha * (1 - Double(ring) * 0.22))))
            }
        }
    }

    private func dotted(_ context: inout GraphicsContext, from: CGPoint, to: CGPoint, alpha: Double) {
        let steps = Int(hypot(to.x - from.x, to.y - from.y) / 5)
        guard steps > 0 else { return }
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGRect(x: from.x + (to.x - from.x) * t - 0.7,
                               y: from.y + (to.y - from.y) * t - 0.7, width: 1.4, height: 1.4)
            context.fill(Path(ellipseIn: point), with: .color(.white.opacity(alpha)))
        }
    }
}
