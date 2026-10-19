import CoreGraphics
import Foundation

// Shadow the hardware calls while exercising the shipping table ownership logic.
enum GammaDevice {
    static var red: [CGGammaValue] = [0.02, 0.1, 0.3, 0.6, 0.8, 0.95]
    static var green: [CGGammaValue] = [0.01, 0.12, 0.32, 0.58, 0.82, 0.97]
    static var blue: [CGGammaValue] = [0.03, 0.15, 0.35, 0.62, 0.85, 0.99]
    static var writes = 0
    static var failWrite = false
}

func CGDisplayGammaTableCapacity(_ display: CGDirectDisplayID) -> UInt32 { 6 }
func CGGetDisplayTransferByTable(_ display: CGDirectDisplayID, _ capacity: UInt32,
                                _ red: inout [CGGammaValue], _ green: inout [CGGammaValue],
                                _ blue: inout [CGGammaValue], _ count: inout UInt32) -> CGError {
    red = GammaDevice.red; green = GammaDevice.green; blue = GammaDevice.blue
    count = 6
    return .success
}
func CGSetDisplayTransferByTable(_ display: CGDirectDisplayID, _ count: UInt32,
                                _ red: [CGGammaValue], _ green: [CGGammaValue],
                                _ blue: [CGGammaValue]) -> CGError {
    if GammaDevice.failWrite { return .failure }
    GammaDevice.red = red; GammaDevice.green = green; GammaDevice.blue = blue
    GammaDevice.writes += 1
    return .success
}

@main
struct DisplayTintTest {
    static func main() {
        let original = [GammaDevice.red, GammaDevice.green, GammaDevice.blue]
        precondition(DisplayTint.apply(1, brightness: 80, contrast: 110))
        precondition(GammaDevice.red != original[0] && GammaDevice.writes == 1)
        precondition(DisplayTint.apply(1, brightness: 80, contrast: 110))
        precondition(GammaDevice.writes == 1, "Unchanged refresh rewrote the gamma table")
        precondition(DisplayTint.apply(1, brightness: 70, contrast: 110))
        GammaDevice.failWrite = true
        precondition(!DisplayTint.clear(1), "Failed restoration was reported as successful")
        GammaDevice.failWrite = false
        DisplayTint.clearAll()
        precondition([GammaDevice.red, GammaDevice.green, GammaDevice.blue] == original,
                     "The original nonidentity RGB tables were not restored after retry")
        precondition(DisplayTint.apply(1, brightness: 80, contrast: 110))
        precondition(DisplayTint.apply(1, brightness: 100, contrast: 100))
        precondition([GammaDevice.red, GammaDevice.green, GammaDevice.blue] == original)
        print("PASS display tint restoration")
    }
}
