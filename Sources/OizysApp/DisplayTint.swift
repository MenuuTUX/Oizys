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
    private struct Tint {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
        var brightness: Int
        var contrast: Int
    }

    /// Save each display's previous table before the first Oizys write.
    private static var tinted: [CGDirectDisplayID: Tint] = [:]

    /// `brightness` 10...100, `contrast` 50...150, both percentages where 100 is untouched.
    /// Both at 100 restores the display rather than writing an identity ramp, so a display
    /// nobody is tinting is left exactly as macOS had it.
    @discardableResult
    static func apply(_ display: CGDirectDisplayID, brightness: Int, contrast: Int) -> Bool {
        guard display != 0 else { return false }
        if brightness >= 100 && contrast == 100 {
            return clear(display)
        }
        let brightness = min(100, max(10, brightness))
        let contrast = min(150, max(50, contrast))
        // Same values is only "already applied" if the window server still has our ramp. A
        // display reconfiguration (an Oizys head attaching, a wake, a ColorSync change) can
        // put the system table back, and skipping on the cached values alone left the tint
        // gone until someone moved a slider.
        if let previous = tinted[display], previous.brightness == brightness,
           previous.contrast == contrast, rampIsLive(display, brightness: brightness, contrast: contrast) {
            return true
        }
        let size = Int(CGDisplayGammaTableCapacity(display))
        guard size >= 2, size <= 16384 else { return false }
        let original: Tint
        if let previous = tinted[display] {
            original = previous
        } else {
            var red = [CGGammaValue](repeating: 0, count: size)
            var green = red, blue = red, count: UInt32 = 0
            guard CGGetDisplayTransferByTable(display, UInt32(size), &red, &green, &blue,
                                              &count) == .success, count >= 2 else { return false }
            red = Array(red.prefix(Int(count)))
            green = Array(green.prefix(Int(count)))
            blue = Array(blue.prefix(Int(count)))
            original = Tint(red: red, green: green, blue: blue,
                            brightness: brightness, contrast: contrast)
        }
        let rampSize = min(size, 1024)
        var ramp = [CGGammaValue](repeating: 0, count: rampSize)
        for index in 0..<rampSize {
            ramp[index] = level(Double(index) / Double(rampSize - 1),
                                brightness: brightness, contrast: contrast)
        }
        guard CGSetDisplayTransferByTable(display, UInt32(rampSize), ramp, ramp, ramp) == .success
        else { return false }
        var applied = original
        applied.brightness = brightness
        applied.contrast = contrast
        tinted[display] = applied
        return true
    }

    /// One ramp entry. Contrast first about mid-grey, then brightness from black -- the same
    /// order the encoder composes them in, so a head and an iPad set to the same numbers agree.
    private static func level(_ input: Double, brightness: Int, contrast: Int) -> CGGammaValue {
        let gain = Double(min(100, max(10, brightness))) / 100
        let slope = Double(min(150, max(50, contrast))) / 100
        let shaped = (input - 0.5) * slope + 0.5
        return CGGammaValue(min(1, max(0, shaped)) * gain)
    }

    /// Whether the display's live table is still the ramp we wrote. Checked at a few points
    /// against the formula rather than entry by entry, because the window server may hand the
    /// table back at its own length.
    private static func rampIsLive(_ display: CGDirectDisplayID, brightness: Int, contrast: Int) -> Bool {
        let size = Int(CGDisplayGammaTableCapacity(display))
        guard size >= 2, size <= 16384 else { return false }
        var red = [CGGammaValue](repeating: 0, count: size)
        var green = red, blue = red, count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, UInt32(size), &red, &green, &blue, &count) == .success,
              count >= 2 else { return false }
        let last = Int(count) - 1
        for index in [0, last / 4, last / 2, 3 * last / 4, last] {
            let expected = level(Double(index) / Double(last), brightness: brightness, contrast: contrast)
            for table in [red, green, blue] where abs(table[index] - expected) > 0.01 { return false }
        }
        return true
    }

    /// Put one display back the way macOS had it.
    @discardableResult
    static func clear(_ display: CGDirectDisplayID) -> Bool {
        guard let previous = tinted[display] else { return true }
        guard CGSetDisplayTransferByTable(display, UInt32(previous.red.count), previous.red,
                                          previous.green, previous.blue) == .success else { return false }
        tinted.removeValue(forKey: display)
        return true
    }

    /// Every display we tinted. Called when Oizys quits: a ramp left behind is a screen the
    /// user cannot fix without finding a display setting they never knowingly changed.
    static func clearAll() {
        for display in Array(tinted.keys) { clear(display) }
    }

    static func forgetDisconnected(_ online: Set<CGDirectDisplayID>) {
        tinted = tinted.filter { online.contains($0.key) }
    }
}
