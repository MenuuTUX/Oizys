import AppKit
import SwiftUI

final class SliderState: ObservableObject {
    @Published var value = 0.5
    var commits: [Double] = []
}

struct SliderHarness: View {
    @ObservedObject var state: SliderState
    var body: some View {
        HalftoneSlider(value: $state.value, onCommit: { state.commits.append($0) },
                       label: "Left picture brightness",
                       announcedValue: "\(Int(10 + state.value * 90)) percent")
            .frame(width: 200, height: 24)
    }
}

@main
struct SliderTest {
    static func findSlider(_ item: Any, depth: Int = 0) -> AnyObject? {
        guard depth < 20 else { return nil }
        // SwiftUI's virtual nodes implement the selectors without declaring conformance.
        let element = item as AnyObject
        if element.accessibilityRole?() == .slider { return element }
        for child in element.accessibilityChildren?() ?? [] {
            if let found = findSlider(child, depth: depth + 1) { return found }
        }
        return nil
    }

    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.accessibilitySetValue(true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let state = SliderState()
        let hosting = NSHostingView(rootView: SliderHarness(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 24),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 40000, y: 40000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard let slider = findSlider(hosting) else { fatalError("No accessible native slider") }
        precondition(slider.accessibilityLabel?() == "Left picture brightness")
        precondition(slider.accessibilityValueDescription?() == "55 percent")
        for _ in 0..<5 { precondition(slider.accessibilityPerformIncrement?() == true) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        precondition(state.value > 0.5 && state.commits.count == 1,
                     "Accessibility increments must coalesce to one final commit")
        precondition(state.commits[0] == state.value)
        let announced = "\(Int(10 + state.value * 90)) percent"
        precondition(slider.accessibilityValueDescription?() == announced)
        precondition(slider.accessibilityPerformDecrement?() == true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        precondition(state.commits.count == 2 && state.commits[1] == state.value)
        let beforeKey = state.value
        window.makeKey()
        window.makeFirstResponder(hosting)
        slider.setAccessibilityFocused?(true)
        let arrow = "\u{F703}"
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil,
                                    characters: arrow, charactersIgnoringModifiers: arrow,
                                    isARepeat: false, keyCode: 124)!
        window.sendEvent(event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        precondition(state.value > beforeKey && state.commits.count == 3,
                     "Arrow-key input did not commit the focused slider value")
        print("PASS slider accessibility")
    }
}
