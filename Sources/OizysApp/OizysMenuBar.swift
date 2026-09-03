import AppKit
import SwiftUI

/*
 * The menu bar is the whole interface for anyone who is not going to open a terminal, so it
 * is built into production as well as the diagnostic variants. It owns no driver state: it
 * reads what is there and runs the same CLI the terminal does.
 *
 * It is deliberately not an always-running poller. A one-second tick while the panel is
 * open costs nothing; with the panel closed it drops to a slow tick so a dormant login
 * item stays dormant, which is the property the production app is built around.
 */
final class OizysMenuBar: NSObject, NSWindowDelegate {
    private let model = OizysModel()
    private var item: NSStatusItem?
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var closedAt = Date.distantPast
    private var window: NSWindow?
    private var tick: Timer?
    private var quitAction: (() -> Void)?

    /// A diagnostic build folds its session controls in here as a submenu of the right-click
    /// menu. One product, one status item: a second item beside this one is two Oizyses in
    /// the menu bar as far as anyone reading the menu bar is concerned.
    var extraMenu: NSMenu?

    /// `quit` is passed in because the two variants end differently: production just
    /// terminates, and a debug session has a driver handover to finish first.
    func install(quit: @escaping () -> Void) {
        quitAction = quit
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Logo.menuBar(active: false)
        item.button?.setAccessibilityLabel("Oizys")
        item.button?.toolTip = "Oizys — USB displays"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item

        model.watchDisplays { [weak self] added in
            guard let self else { return }
            self.model.refresh()
            ConnectOverlay.announce(added, model: self.model)
        }
        model.refresh()
        model.refreshSlowly()
        // Sidecar auto-connect arms its own push triggers and then costs nothing until one
        // fires. It reads the switch on every decision, so an installed watcher with the
        // setting off does nothing at all.
        SidecarAuto.shared.start { [model] in model.sidecarSettings }
        retick(fast: false)
    }

    /// With nothing attached there is no timer at all: the dormant login item stays dormant
    /// and is woken by the dock's IOKit notification or a display reconfiguration, both of
    /// which already exist. A timer only runs while there is something to watch.
    private func retick(fast: Bool) {
        tick?.invalidate(); tick = nil
        guard fast || model.dockPresent else { return }
        tick = Timer.scheduledTimer(withTimeInterval: fast ? 1.5 : 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.refresh()
            self.item?.button?.image = Logo.menuBar(active: self.model.running)
            if !self.model.dockPresent, self.panel == nil { self.retick(fast: false) }
        }
    }

    /// Called by the host app when its own dock or session notification fires.
    func refreshNow() {
        model.refresh()
        item?.button?.image = Logo.menuBar(active: model.running)
        retick(fast: panel != nil)
    }

    @objc private func toggle() {
        // Right-click gets a plain menu, because a panel is the wrong shape for "quit".
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        if panel != nil { closePanel(); return }
        // Clicking the item while the panel is open takes key away from it first, so the
        // panel has already closed itself by the time this runs. Without this the click
        // would immediately reopen what it was meant to dismiss.
        guard Date().timeIntervalSince(closedAt) > 0.25 else { return }
        showPanel()
    }

    /*
     * This is a panel rather than an NSPopover on purpose. A transient popover anchored to a
     * status item decides for itself which screen it belongs on, and on a multi-display desk
     * it moves between them; it also stays up when the click that should dismiss it lands on
     * one of this app's own windows. A panel is placed against the status item's own screen
     * and closes on the one condition that actually means "the user went elsewhere": it
     * stopped being the key window.
     */
    private func showPanel() {
        guard let button = item?.button, let bar = button.window else { return }
        model.refresh()
        let size = NSSize(width: 330, height: 460)
        let content = NSHostingView(rootView:
            MenuPopover(model: model,
                        openWindow: { [weak self] in self?.openWindow() },
                        quit: { [weak self] in self?.quitAction?() }))
        content.frame = NSRect(origin: .zero, size: size)
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true

        let panel = MenuPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
        panel.contentView = content
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.animationBehavior = .utilityWindow
        panel.setFrameOrigin(origin(under: bar.convertToScreen(button.convert(button.bounds, to: nil)),
                                    size: size, on: bar.screen))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        // Key loss covers every click inside this app; the global monitor covers the clicks
        // that go to another app without ever reaching us.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
                                                           handler: { [weak self] _ in self?.closePanel() }) {
            monitors.append(outside)
        }
        if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }      // Escape
            self?.closePanel(); return nil
        }) {
            monitors.append(escape)
        }
        retick(fast: true)
    }

    /// Below the item, clamped to the screen the menu bar drew the item on.
    private func origin(under anchor: NSRect, size: NSSize, on screen: NSScreen?) -> NSPoint {
        let visible = (screen ?? NSScreen.screens.first { $0.frame.intersects(anchor) }
                              ?? NSScreen.main)?.visibleFrame
        var point = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        if let visible {
            point.x = min(max(visible.minX + 8, point.x), visible.maxX - size.width - 8)
            point.y = max(visible.minY + 8, point.y)
        }
        return point
    }

    private func closePanel() {
        guard let panel else { return }
        self.panel = nil
        closedAt = Date()
        panel.delegate = nil
        panel.orderOut(nil)
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        retick(fast: false)
    }

    func windowDidResignKey(_ notification: Notification) { closePanel() }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: model.summary, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: model.running ? "Stop Oizys" : "Start Oizys",
                                action: #selector(toggleDriver), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let open = NSMenuItem(title: "Open Oizys…", action: #selector(openWindow), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        if let extraMenu {
            menu.addItem(.separator())
            let entry = NSMenuItem(title: "Debug session", action: nil, keyEquivalent: "")
            entry.submenu = extraMenu
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Oizys", action: #selector(quitNow), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil // so the next left click returns to the popover
    }

    @objc private func toggleDriver() { model.running ? model.stop() : model.start() }
    @objc private func quitNow() { quitAction?() }

    @objc func openWindow() {
        closePanel()
        model.refreshSlowly()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Oizys"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.039, green: 0.039, blue: 0.043, alpha: 1)
        window.contentView = NSHostingView(rootView: MenuWindow(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func shutdown() {
        tick?.invalidate(); tick = nil
        closePanel()
        if let item { NSStatusBar.system.removeStatusItem(item) }
    }
}

/// A borderless panel takes key only if it says it can, and the panel holds switches and
/// buttons that need it.
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
