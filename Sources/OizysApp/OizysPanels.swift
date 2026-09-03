import AppKit
import SwiftUI

// MARK: - Popover

/// The everyday surface. Status, the displays, and the two things anyone actually wants to
/// do. Everything else lives one click away in the window, so this stays readable.
struct MenuPopover: View {
    @ObservedObject var model: OizysModel
    var openWindow: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LogoHeader(height: 108, active: model.running)
                VStack(alignment: .leading, spacing: 3) {
                    Text("OIZYS").font(.system(size: 17, weight: .light)).tracking(6)
                        .foregroundStyle(Ink.primary)
                    HStack(spacing: 6) {
                        StatusDot(health: model.health)
                        Text(model.summary).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    }
                }
                .padding(.leading, 16).padding(.bottom, 10)
            }

            VStack(alignment: .leading, spacing: 0) {
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
                Row(label: "Status", detail: model.dockPresent ? nil : "Connect the dock to start.") {
                    HStack(spacing: 6) {
                        StatusDot(health: model.health)
                        Text(model.running ? "Running" : "Stopped")
                    }
                }
                Row(label: "Start at login") {
                    QuietSwitch(isOn: Binding(get: { model.loginEnabled },
                                              set: { model.setLoginStart($0) }))
                }
                Row(label: "Announce new displays", detail: "A short ripple on the screen that just arrived.") {
                    HStack(spacing: 8) {
                        QuietButton(title: "Preview") { ConnectOverlay.preview(model: model) }
                        QuietSwitch(isOn: Binding(get: { ConnectOverlay.enabled },
                                                  set: { ConnectOverlay.enabled = $0 }))
                    }
                }

                HStack(spacing: 8) {
                    QuietButton(title: model.running ? "Stop" : "Start") {
                        model.running ? model.stop() : model.start()
                    }
                    QuietButton(title: "Open Oizys…", action: openWindow)
                    Spacer()
                    QuietButton(title: "Quit", action: quit)
                }
                .padding(.top, 14)

                if !model.lastMessage.isEmpty {
                    Text(model.lastMessage).font(.system(size: 10)).foregroundStyle(Ink.faint)
                        .lineLimit(2).padding(.top, 8)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
        .frame(width: 330)
        .background(Ink.ground)
        .onAppear { model.refresh() }
    }
}

// MARK: - Window

enum Panel: String, CaseIterable, Identifiable {
    case displays = "Displays", power = "Power & standby", sidecar = "Sidecar"
    case calibrate = "Colour", ports = "USB ports", settings = "All settings"
    case about = "How it works", info = "About"
    var id: String { rawValue }
}

struct MenuWindow: View {
    @ObservedObject var model: OizysModel
    @State private var panel: Panel

    init(model: OizysModel, initial: Panel = .displays) {
        self.model = model
        _panel = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if let mark = Logo.template(side: 20, floor: 0.34, boost: 2.6) {
                        Image(nsImage: mark).renderingMode(.template)
                            .foregroundStyle(Ink.primary).frame(width: 22, height: 22)
                    }
                    Text("OIZYS").font(.system(size: 13, weight: .light)).tracking(4.5)
                        .foregroundStyle(Ink.primary)
                }
                .padding(.bottom, 12).padding(.leading, 10)
                ForEach(Panel.allCases) { entry in
                    Button { panel = entry } label: {
                        Text(entry.rawValue).font(Ink.label)
                            .foregroundStyle(panel == entry ? Ink.primary : Ink.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(panel == entry ? Ink.raised : .clear))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(health: model.health)
                    Text(model.summary).font(.system(size: 10)).foregroundStyle(Ink.faint)
                }
                .padding(.leading, 10).padding(.bottom, 4)
            }
            .frame(width: 172).padding(12)
            .background(Ink.panel)

            Divider().overlay(Ink.hairline)

            ScrollView {
                PanelBody(model: model, panel: panel)
            }
            .background(
                ZStack {
                    Ink.ground
                    Grain(opacity: 0.045)
                    Vignette(strength: 0.42)
                }
            )
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Ink.ground)
        .onAppear { model.refresh(); model.refreshSlowly() }
    }
}

/// The content of one section. Extracted from the window so it can be rendered on its own:
/// ImageRenderer does not lay out a ScrollView's content offscreen, so a review render of the
/// window alone shows an empty pane and proves nothing.
struct PanelBody: View {
    @ObservedObject var model: OizysModel
    let panel: Panel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch panel {
            case .displays: DisplaysPanel(model: model)
            case .power: PowerPanel(model: model)
            case .sidecar: SidecarPanel(model: model)
            case .calibrate: ColourPanel(model: model)
            case .ports: PortsPanel(model: model)
            case .settings: SettingsPanel(model: model)
            case .about: AboutPanel(model: model)
            case .info: InfoPanel(model: model)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Panels

private struct DisplaysPanel: View {
    @ObservedObject var model: OizysModel
    var body: some View {
        SectionLabel(text: "Attached displays", trailing: "\(model.displays.count)")
        ForEach(model.displays) { display in
            Row(label: display.name,
                detail: "\(display.geometry) · at \(Int(display.origin.x)),\(Int(display.origin.y))"
                        + (display.mirrored ? " · mirrored" : "") + (display.main ? " · main" : "")) {
                Text(display.kind.rawValue).foregroundStyle(Ink.faint)
            }
            if let head = display.head {
                HeadBrightnessRow(model: model, head: head)
                HeadContrastRow(model: model, head: head)
            } else if display.kind != .sidecar {
                BrightnessRow(model: model, display: display)
            }
            HStack(spacing: 8) {
                if !display.main {
                    QuietButton(title: display.mirrored ? "Unmirror" : "Mirror main") {
                        model.run(["monitor", String(display.id), "mirror",
                                   display.mirrored ? "off" : String(CGMainDisplayID())])
                    }
                }
                Spacer()
            }
            .padding(.top, 6).padding(.bottom, 14)
        }
        Text("Brightness on an Oizys head is a gain applied while encoding, because Oizys owns "
             + "every pixel those panels receive. It dims the picture, not the backlight — a "
             + "DisplayLink output has no I2C channel, so the monitor's own controls, including "
             + "its power state, stay on its front-panel menu.")
            .font(.system(size: 10)).foregroundStyle(Ink.faint).padding(.top, 4)

        SectionLabel(text: "Arrangement")
        Row(label: "Keep the other screens' resolutions",
            detail: "macOS stores a resolution per set of screens, and the set with the "
                    + "heads in it gets a smaller one.") {
            QuietSwitch(isOn: Binding(
                get: { model.setting("display.keep_modes", "true") == "true" },
                set: { model.set("display.keep_modes", $0 ? "true" : "false") }))
        }
        Text("Off, macOS decides the resolution of every screen each time the heads appear. "
             + "Turn it off if you want a different resolution while the dock is attached and "
             + "you would rather set that up yourself — Oizys adopts a resolution you choose "
             + "yourself a few seconds after the screens settle, so it will not fight you.")
            .font(.system(size: 10)).foregroundStyle(Ink.faint).padding(.top, 4)
    }
}

private struct HeadBrightnessRow: View {
    @ObservedObject var model: OizysModel
    let head: Int
    var body: some View {
        let value = model.headBrightness(head)
        Row(label: "Brightness", detail: "Applied in the encoder; takes effect immediately.") {
            HStack(spacing: 10) {
                HalftoneSlider(value: Binding(
                    get: { (value - 10) / 90 },
                    set: { model.setHeadBrightness(head, 10 + $0 * 90) }))
                    .frame(width: 150)
                Text("\(Int(value))%").frame(width: 38, alignment: .trailing)
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
                    set: { model.setHeadContrast(head, 50 + $0 * 100) }))
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
        Row(label: "Brightness", detail: model.brightness[display.id] == nil
            ? "This monitor did not answer a DDC brightness request." : nil) {
            if let value = model.brightness[display.id] {
                let top = model.brightnessMaximum[display.id] ?? 100
                HStack(spacing: 10) {
                    HalftoneSlider(value: Binding(
                        get: { top > 0 ? value / top : 0 },
                        set: { model.setBrightness(display.id, $0 * top) }))
                        .frame(width: 150)
                    Text("\(Int(value))").frame(width: 38, alignment: .trailing)
                }
            } else {
                QuietButton(title: "Read") { model.readBrightness(display.id) }
            }
        }
    }
}

private struct PowerPanel: View {
    @ObservedObject var model: OizysModel

    private var heads: [OizysDisplay] {
        model.displays.filter { $0.head != nil }.sorted { ($0.head ?? 0) < ($1.head ?? 0) }
    }

    var body: some View {
        SectionLabel(text: "Why a panel sleeps")
        Text("Two different clocks, and they fail differently.\n\n"
             + "macOS has one display-sleep timer covering every screen. If both monitors sleep "
             + "together at the same interval, that is this timer, and it is the only one of "
             + "the two that lives in System Settings.\n\n"
             + "A monitor also sleeps on its own once its input stops changing, and every model "
             + "has its own patience. Monitors sleeping at different times — one after four "
             + "minutes, one straight away — is this, not macOS. An idle desktop puts zero bytes "
             + "on the video endpoint by design, so a panel can decide nothing is arriving. "
             + "Keep awake below is the fix, and it is per monitor because the problem is.")
            .font(Ink.label).foregroundStyle(Ink.secondary)

        ForEach(heads) { head in
            let index = head.head ?? 0
            SectionLabel(text: head.name, trailing: index == 0 ? "left" : "right")
            HeadPowerRows(model: model, head: index)
        }
        if heads.isEmpty {
            SectionLabel(text: "Oizys heads")
            Text("No Oizys head is attached, so there is nothing per-monitor to set. Connect the "
                 + "dock and these appear.")
                .font(Ink.label).foregroundStyle(Ink.faint).padding(.vertical, 6)
        }

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
                set: { model.set("power.saving", $0 ? "true" : "false") }))
        }
        if model.setting("power.saving", "true") == "true" {
            Row(label: "Idle frame rate") {
                SegmentedChoice(options: [("5", "5"), ("10", "10"), ("15", "15"), ("30", "30")],
                                selection: Binding(get: { model.setting("power.idle_fps", "10") },
                                                   set: { model.set("power.idle_fps", $0) }))
            }
            Row(label: "Idle after") {
                SegmentedChoice(options: [("10s", "10"), ("20s", "20"), ("60s", "60"), ("5m", "300")],
                                selection: Binding(get: { model.setting("power.idle_after_s", "20") },
                                                   set: { model.set("power.idle_after_s", $0) }))
            }
        }
        Text("Everything here is re-read by a running driver within a second. Nothing needs a restart.")
            .font(.system(size: 10)).foregroundStyle(Ink.faint).padding(.top, 8)
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
        Row(label: "Keep awake",
            detail: keepalive == "0"
                ? "Off. This panel may sleep on its own once the desktop stops changing."
                : "Repaints the cached image on this interval, so the panel never sees a still input.") {
            SegmentedChoice(options: [("Off", "0"), ("30s", "30"), ("60s", "60"), ("2m", "120")],
                            selection: Binding(get: { keepalive },
                                               set: { model.setHeadSetting(head, "keepalive_s", $0) }))
        }
        Row(label: "Blank when idle",
            detail: standby == "0"
                ? "Off. This panel stays lit for as long as macOS keeps the desktop awake."
                : "Goes black after this long with nothing changing. The display stays in place, "
                  + "so no window moves and the next frame brings it straight back.") {
            SegmentedChoice(options: [("Never", "0"), ("4m", "4"), ("10m", "10"), ("30m", "30")],
                            selection: Binding(get: { standby },
                                               set: { model.setHeadSetting(head, "standby_min", $0) }))
        }
        if keepalive != "0" && standby != "0" {
            Text("Blanking wins: this panel is repainted while it is in use and goes black after "
                 + standby + " minutes still.")
                .font(.system(size: 10)).foregroundStyle(Ink.warn).padding(.top, 4)
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
        SidecarAuto.shared.settingsChanged()
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
                        set: { model.setSidecarTint("brightness", 10 + $0 * 90) }))
                        .frame(width: 150)
                    Text("\(Int(model.sidecarTint("brightness")))%").frame(width: 38, alignment: .trailing)
                }
            }
            Row(label: "Contrast", detail: "Pivots on mid-grey; above 100 clips the brightest pixels.") {
                HStack(spacing: 10) {
                    HalftoneSlider(value: Binding(
                        get: { (model.sidecarTint("contrast") - 50) / 100 },
                        set: { model.setSidecarTint("contrast", 50 + $0 * 100) }))
                        .frame(width: 150)
                    Text("\(Int(model.sidecarTint("contrast")))%").frame(width: 38, alignment: .trailing)
                }
            }
        }
        if let attached {
            Row(label: "Arrangement", detail: "at \(Int(attached.origin.x)),\(Int(attached.origin.y))") {
                QuietButton(title: attached.mirrored ? "Unmirror" : "Mirror main") {
                    model.run(["monitor", String(attached.id), "mirror",
                               attached.mirrored ? "off" : String(CGMainDisplayID())])
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
                    QuietButton(title: attached == nil ? "Connect" : "Disconnect") {
                        if attached == nil { SidecarBridge.connect(devices[index].handle) }
                        else { SidecarBridge.disconnect(devices[index].handle) }
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
                                          set: { setSidecar("auto_connect", $0 ? "true" : "false") }))
            }
            if autoConnect {
                Row(label: "Only at a desk",
                    detail: "On the charger with another screen attached. An iPad in your "
                            + "hands on a sofa is not a second monitor, and taking it over "
                            + "there is worse than doing nothing.") {
                    QuietSwitch(isOn: Binding(
                        get: { model.setting("sidecar.require_desk", "true") == "true" },
                        set: { setSidecar("require_desk", $0 ? "true" : "false") }))
                }
                Row(label: "Which iPad",
                    detail: model.setting("sidecar.device", "").isEmpty
                        ? "Whichever is offered first."
                        : "Falls back to the first one offered if this name stops matching.") {
                    SegmentedChoice(options: [("Any", "")] + devices.map { ($0.name, $0.name) },
                                    selection: Binding(
                                        get: { model.setting("sidecar.device", "") },
                                        set: { setSidecar("device", $0) }))
                }
                Text("Disconnecting the iPad by hand is respected: Oizys leaves it alone for "
                     + "five minutes rather than taking the display straight back.")
                    .font(.system(size: 10)).foregroundStyle(Ink.faint).padding(.top, 4)
            }

            Text("macOS ships no public interface for connecting Sidecar, so this drives a private "
                 + "Apple framework. It can stop working after any macOS update, and if it does, "
                 + "this section says so rather than offering a button that does nothing. "
                 + "Everything above works through the ordinary display APIs and is unaffected.")
                .font(.system(size: 10)).foregroundStyle(Ink.faint).padding(.top, 10)
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
        SectionLabel(text: "Matching the monitors")
        Text("An iPhone camera is not a colorimeter: iOS Safari exposes no manual exposure and "
             + "no white-balance lock, so nothing it reports is absolute. What survives its "
             + "pipeline is the ratio between two patches shot under the same settings, which "
             + "is enough to make the monitors match each other — the fault people actually see.")
            .font(Ink.label).foregroundStyle(Ink.secondary)

        switch session.phase {
        case .idle:
            Row(label: "Phone calibration",
                detail: "Shows a QR code, then eight grey patches per monitor. About a minute.") {
                QuietButton(title: "Start") { session.start() }
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
                        Text("Safari will warn that the connection is not private. That is "
                             + "expected: the camera is only offered over HTTPS, so Oizys serves "
                             + "the page with its own certificate. Tap through it once, then "
                             + "allow the camera.")
                            .font(.system(size: 11)).foregroundStyle(Ink.faint)
                        Text(session.address).font(.system(size: 10, design: .monospaced))
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
            HStack { QuietButton(title: "Stop") { session.stop() }; Spacer() }.padding(.top, 8)
        case .solving:
            Row("Solving", "…")
        case let .done(text):
            SectionLabel(text: "Result")
            Text(text).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Ink.secondary).textSelection(.enabled)
            HStack(spacing: 8) {
                QuietButton(title: "Run again") { session.start() }
                QuietButton(title: "Clear") { model.run(["calibrate", "clear"]) }
                Spacer()
            }.padding(.top, 10)
        case let .failed(text):
            Text(text).font(.system(size: 11)).foregroundStyle(Ink.warn).padding(.vertical, 6)
            HStack { QuietButton(title: "Try again") { session.start() }; Spacer() }
        }

        SectionLabel(text: "What this cannot do")
        Text("No absolute colour and no accuracy figure: there is no reference in the loop, so "
             + "there is no scale to be accurate against. It matches panels to each other, "
             + "always by darkening — a panel cannot be driven above its own white — so the "
             + "dimmest monitor becomes the reference.")
            .font(.system(size: 11)).foregroundStyle(Ink.faint)
        HStack { QuietButton(title: "Show stored correction") { model.run(["calibrate", "show"]) }; Spacer() }
            .padding(.top, 10)
        if !model.lastMessage.isEmpty {
            Text(model.lastMessage).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Ink.faint).padding(.top, 6)
        }
    }
}

private struct PortsPanel: View {
    @ObservedObject var model: OizysModel
    var body: some View {
        SectionLabel(text: "USB ports", trailing: "read-only")
        // A fixed-width table must not reflow: wrapping a column header onto its own line
        // destroys the alignment that carries the meaning. The driver prints it narrow
        // enough to fit here, and anything unexpectedly long is clipped rather than wrapped.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.ports) { row in
                Text(row.text).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(row.warning ? Ink.warn : Ink.secondary)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ink.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ink.hairline))
        HStack { QuietButton(title: "Scan again") { model.refreshSlowly() }; Spacer() }.padding(.top, 10)
    }
}

private struct SettingsPanel: View {
    @ObservedObject var model: OizysModel
    @State private var editing: String?
    @State private var draft = ""
    var body: some View {
        SectionLabel(text: "Driver settings", trailing: "applied live")
        ForEach(model.settings) { setting in
            Row(label: setting.id,
                detail: setting.changed ? "default \(setting.fallback)" : nil) {
                if editing == setting.id {
                    HStack(spacing: 6) {
                        TextField("", text: $draft)
                            .textFieldStyle(.roundedBorder).frame(width: 96).controlSize(.small)
                            .onSubmit { model.set(setting.id, draft); editing = nil }
                        QuietButton(title: "Set") { model.set(setting.id, draft); editing = nil }
                    }
                } else {
                    Button { editing = setting.id; draft = setting.value } label: {
                        Text(setting.value).foregroundStyle(setting.changed ? Ink.primary : Ink.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        HStack(spacing: 8) {
            QuietButton(title: "Reset all to defaults") { model.run(["config", "reset"]); model.refreshSlowly() }
            QuietButton(title: "Restart driver") { model.restart() }
            Spacer()
        }
        .padding(.top, 14)
        Text("A running driver re-reads this file within a second, so most changes take effect "
             + "without a restart. Values outside a setting's safe range are clamped rather than rejected. "
             + "control.poll_ms is load-bearing: polling the dock harder than its default reads "
             + "back as a false disconnect.")
            .font(.system(size: 10)).foregroundStyle(Ink.faint).padding(.top, 8)
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
        Text("macOS ties this permission to a code signature, so a rebuilt copy of Oizys arrives "
             + "as a stranger and has to ask again — even where System Settings still shows the "
             + "old entry ticked. Installing clears Oizys's own entry for that reason. Nothing "
             + "asks on its own: this button is the only thing in the app that does.")
            .font(.system(size: 10)).foregroundStyle(Ink.faint).padding(.top, 6)

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
            .font(.system(size: 10)).foregroundStyle(Ink.faint).padding(.top, 8)
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
                let point = CGRect(x: centre.x + cos(angle) * scale - 0.8,
                                   y: centre.y + sin(angle) * scale - 0.8, width: 1.6, height: 1.6)
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
