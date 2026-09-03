import CoreGraphics
import Foundation

/*
 * Brightness and contrast for a display Oizys does not own the pixels of.
 *
 * An Oizys head is easy: every pixel on it was encoded here, so brightness is a gain in the
 * encoder. A Sidecar iPad is the opposite. macOS composites that desktop and Apple's own
 * path sends it, so there is nothing of ours to scale -- and the backlight is not reachable
 * either. macOS says so directly: DisplayServicesCanChangeBrightness is false for a Sidecar
 * display, and reading its brightness fails. The iPad's own slider is on the iPad.
 *
 * What every display does have is a transfer table, between the framebuffer and the wire.
 * That is what this writes. It is a software transform and it costs output levels the way
 * any gamma ramp does -- 1024 entries here, so there is room -- but it reaches the one
 * screen nothing else can touch, and it takes effect immediately.
 *
 * The arithmetic matches the encoder's deliberately, so the two controls mean the same thing
 * wherever they appear: brightness scales from black, contrast pivots on mid-grey.
 *
 * ponytail: the ramp belongs to the window server, not to us, and it outlives the process
 * that set it. Anything that stops tinting has to put it back -- see `clear` and the call in
 * applicationWillTerminate.
 */
enum DisplayTint {
    /// Displays currently carrying a ramp of ours, so they can be restored on the way out.
    private static var tinted: Set<CGDirectDisplayID> = []

    /// `brightness` 10...100, `contrast` 50...150, both percentages where 100 is untouched.
    /// Both at 100 restores the display rather than writing an identity ramp, so a display
    /// nobody is tinting is left exactly as macOS had it.
    @discardableResult
    static func apply(_ display: CGDirectDisplayID, brightness: Int, contrast: Int) -> Bool {
        guard display != 0 else { return false }
        if brightness >= 100 && contrast == 100 {
            clear(display)
            return true
        }
        let size = max(2, min(Int(CGDisplayGammaTableCapacity(display)), 1024))
        let gain = Double(min(100, max(10, brightness))) / 100
        let slope = Double(min(150, max(50, contrast))) / 100
        var ramp = [CGGammaValue](repeating: 0, count: size)
        for index in 0..<size {
            let input = Double(index) / Double(size - 1)
            // Contrast first about mid-grey, then brightness from black -- the same order the
            // encoder composes them in, so a head and an iPad set to the same numbers agree.
            let shaped = (input - 0.5) * slope + 0.5
            ramp[index] = CGGammaValue(min(1, max(0, shaped)) * gain)
        }
        guard CGSetDisplayTransferByTable(display, UInt32(size), ramp, ramp, ramp) == .success
        else { return false }
        tinted.insert(display)
        return true
    }

    /// Put one display back the way macOS had it.
    static func clear(_ display: CGDirectDisplayID) {
        guard tinted.remove(display) != nil else { return }
        // The identity formula rather than CGDisplayRestoreColorSyncSettings, which resets
        // every display on the machine and would undo a colour profile we never touched.
        CGSetDisplayTransferByFormula(display, 0, 1, 1, 0, 1, 1, 0, 1, 1)
    }

    /// Every display we tinted. Called when Oizys quits: a ramp left behind is a screen the
    /// user cannot fix without finding a display setting they never knowingly changed.
    static func clearAll() {
        for display in tinted { CGSetDisplayTransferByFormula(display, 0, 1, 1, 0, 1, 1, 0, 1, 1) }
        tinted.removeAll()
    }
}
