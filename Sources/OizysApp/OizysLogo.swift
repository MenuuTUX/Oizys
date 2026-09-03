import AppKit
import SwiftUI

/*
 * The artwork, and the effect stack it was made with.
 *
 * Two pictures, both in Assets/, each named for the one job it has. Assets/Logo.png is the
 * app's own mark — the stipple head that becomes the icon in the Dock and the header of the
 * panel. Assets/tiny_Logo.png is the smaller portrait the menu-bar item is cut from, and only
 * that: it survives being thresholded to 18 points, which the full mark does not. They are
 * bundled under those same names, so a resource lookup here and a glance at the repository
 * agree about which picture is which. Both are stipple on a near-black ground, so two things
 * follow for the interface.
 *
 * First, the menu-bar item cannot be the image scaled down. A menu-bar icon is a *template*:
 * macOS throws the colour away and tints whatever is opaque, so an image whose subject is
 * encoded in luminance against an opaque black ground arrives as a solid black square. The
 * fix is to rebuild alpha from luminance, which is what `template` below does — the bright
 * grain becomes opaque, the ground becomes transparent, and the stipple survives in whatever
 * colour the menu bar is currently using.
 *
 * Second, the same stack that made the artwork makes the interface: vignette, posterize,
 * contour, stipple, halftone. Those are the layers below, drawn rather than filtered, so the
 * panel and the picture look like they came from one place.
 */
enum Logo {
    private static func bundled(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        // A direct Xcode run has no packaged Resources; fall back to the app icon.
        return NSImage(named: NSImage.applicationIconName)
    }

    /// The app's mark, at full size: Dock icon and panel header. Nil in a build whose
    /// resources were not packaged.
    static let artwork: NSImage? = bundled("Logo")

    /// The only picture the menu-bar template is ever cut from.
    static let mark: NSImage? = bundled("tiny_Logo")

    private static var cache: [String: NSImage] = [:]

    /// Alpha rebuilt from luminance, so the stipple reads at menu-bar size in either theme.
    /// `floor` drops the ground grain that would otherwise smear the silhouette shut.
    static func template(side: CGFloat, floor: CGFloat = 0.30, boost: CGFloat = 1.9) -> NSImage? {
        let key = "\(side)-\(floor)-\(boost)"
        if let hit = cache[key] { return hit }
        guard let mark, let full = mark.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        // Crop to the head before scaling. The lower third of the artwork is body and hands,
        // which threshold away to almost nothing at this size and would otherwise cost a
        // third of an 18-point square to render as empty margin.
        let width = CGFloat(full.width), height = CGFloat(full.height)
        // CGImage crops from the top-left, so this takes the hood and face and leaves the
        // body below it out.
        let box = CGRect(x: width * 0.12, y: height * 0.02, width: width * 0.76, height: height * 0.76)
        let source = full.cropping(to: box) ?? full

        // Render at 3x so the Retina menu bar has real pixels to work with.
        let pixels = Int(side * 3)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                      bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let data = context.data else { return nil }

        let buffer = data.bindMemory(to: UInt8.self, capacity: pixels * pixels * 4)
        for index in stride(from: 0, to: pixels * pixels * 4, by: 4) {
            let red = CGFloat(buffer[index]) / 255
            let green = CGFloat(buffer[index + 1]) / 255
            let blue = CGFloat(buffer[index + 2]) / 255
            let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            // Below the floor is ground and goes away; above it is subject, lifted so the
            // mid greys of the stipple do not vanish into the menu bar.
            let lifted = luma <= floor ? 0 : min(1, (luma - floor) / (1 - floor) * boost)
            buffer[index] = 0; buffer[index + 1] = 0; buffer[index + 2] = 0
            buffer[index + 3] = UInt8(lifted * 255)
        }
        guard let masked = context.makeImage() else { return nil }
        let image = NSImage(cgImage: masked, size: NSSize(width: side, height: side))
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// The status-item glyph. Running lifts the stipple; stopped lets it fall back.
    static func menuBar(active: Bool) -> NSImage {
        if let image = template(side: 18, floor: active ? 0.26 : 0.38,
                                boost: active ? 2.1 : 1.4) { return image }
        return fallback(active: active)
    }

    /// Drawn rings, for a build with no artwork to read.
    private static func fallback(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            for (index, radius) in [3.2, 5.6, 8.0].enumerated() {
                let dots = 8 + index * 6
                NSColor.black.withAlphaComponent(active ? 1.0 - Double(index) * 0.22
                                                        : 0.55 - Double(index) * 0.14).setFill()
                for step in 0..<dots {
                    let angle = Double(step) / Double(dots) * .pi * 2 + Double(index) * 0.3
                    NSBezierPath(ovalIn: CGRect(x: centre.x + cos(angle) * radius - 0.8,
                                                y: centre.y + sin(angle) * radius - 0.8,
                                                width: 1.6, height: 1.6)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - The effect stack, as view layers

/// Fine grain over everything. The artwork's texture is its most recognisable property, and
/// a flat panel beside a grainy picture reads as two different products.
struct Grain: View {
    var opacity: Double = 0.030
    var body: some View {
        Canvas { context, size in
            var state: UInt64 = 0x9E3779B97F4A7C15
            func random() -> Double {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return Double(state % 1000) / 1000
            }
            // Dense and faint. Sparse bright dots read as stars; what the artwork has is a
            // continuous tooth, so almost every cell gets something and almost none of it
            // is visible on its own.
            let step: CGFloat = 2
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    let value = random()
                    if value > 0.35 {
                        context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)),
                                     with: .color(.white.opacity(value * opacity)))
                    }
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// Darkened corners, as in the Vignette layer. Keeps the eye on the middle of a dense panel.
struct Vignette: View {
    var strength: Double = 0.55
    var body: some View {
        RadialGradient(colors: [.clear, .black.opacity(strength)],
                       center: .center, startRadius: 40, endRadius: 260)
            .allowsHitTesting(false)
    }
}

/// The Halftone layer: a dot screen whose dot size follows a value. Used as a meter, so the
/// interface measures things in the artwork's own vocabulary rather than with a progress bar.
struct Halftone: View {
    var value: Double          // 0...1
    var columns: Int = 26
    var rows: Int = 4
    var body: some View {
        Canvas { context, size in
            let cell = size.width / CGFloat(columns)
            let filled = value * Double(columns)
            for row in 0..<rows {
                for column in 0..<columns {
                    // A dot grows to full size well before its column is reached, so the
                    // edge of the meter is a gradient of dot sizes rather than a hard stop.
                    let distance = filled - Double(column)
                    let weight = min(max(distance, 0), 1)
                    guard weight > 0.02 else { continue }
                    let radius = cell * 0.42 * CGFloat(weight)
                    let centre = CGPoint(x: (CGFloat(column) + 0.5) * cell,
                                         y: (CGFloat(row) + 0.5) * (size.height / CGFloat(rows)))
                    context.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                        width: radius * 2, height: radius * 2)),
                                 with: .color(.white.opacity(0.30 + weight * 0.55)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The halftone meter, made draggable. The meter and the control are one object: a dot
/// screen already shows a level, so putting a system slider beside it would say the same
/// thing twice in two visual languages.
struct HalftoneSlider: View {
    @Binding var value: Double          // 0...1
    var onCommit: (Double) -> Void = { _ in }
    var body: some View {
        GeometryReader { proxy in
            Halftone(value: value)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        value = min(1, max(0, drag.location.x / max(proxy.size.width, 1)))
                    }
                    .onEnded { _ in onCommit(value) })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(value * 100)) percent"))
    }
}

/// The artwork itself as a header, faded into the ground so text stays readable over it.
struct LogoHeader: View {
    var height: CGFloat = 108
    var active: Bool
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let artwork = Logo.artwork {
                // The head fills the frame, so a centred fill crop lands on jaw and shoulder.
                // Scale to the width and anchor high, which puts the profile in the band.
                GeometryReader { proxy in
                    Image(nsImage: artwork)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.width)
                        .offset(y: -proxy.size.width * 0.36)
                        .saturation(0)                       // the stack ends monochrome
                        .contrast(active ? 1.35 : 1.05)      // Curves
                        .brightness(active ? -0.04 : -0.12)
                        .opacity(active ? 0.92 : 0.62)
                }
                .frame(height: height).clipped()
            } else {
                RippleField(intensity: active ? 0.85 : 0.3).frame(height: height)
            }
            Vignette(strength: 0.5).frame(height: height)
            Grain(opacity: 0.05).frame(height: height)
            LinearGradient(colors: [Ink.ground.opacity(0), Ink.ground.opacity(0.75), Ink.ground],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: height)
        }
        .frame(height: height)
        .clipped()
        .allowsHitTesting(false)
    }
}
