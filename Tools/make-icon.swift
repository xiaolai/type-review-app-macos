import AppKit

/// Draws the app icon, twice, from one set of numbers.
///
/// Run with `make icon`. It writes the ten `.iconset` representations that
/// `iconutil` turns into `Resources/TypeReview.icns`, and the SVG layer inside
/// `Resources/AppIcon.icon` that `actool` compiles for macOS 26. Both outputs
/// are committed, so an ordinary build needs neither this nor a Swift
/// toolchain detour — but the artwork stays reproducible and changing it is an
/// edit to code.
///
/// ## Why the mark is drawn rather than taken from SF Symbols
///
/// It was `keyboard.badge.eye`, and the shape was wrong for a square. Measured:
/// that symbol is 1.66 wide to 1 tall, so fitting it by width leaves two
/// fifths of the canvas empty top and bottom; and its badge hangs 87 units off
/// the right of the plain keyboard, which pushes the keyboard left of centre.
/// `keyboard.macwindow` is the squarest of the family at 1.35 and is the shape
/// this follows — redrawn as a true square, so there is nothing left over in
/// either direction and the mark is centred because it fills its frame.
///
/// ## Why two artworks
///
/// macOS 14 and 15 draw an app icon exactly as handed over, so the `.icns`
/// arrives pre-shaped: Apple's grid, an 824-point tile on a 1024 canvas, its
/// own shadow. macOS 26 draws icons itself — shaping, lighting, and re-lighting
/// them for dark mode and tinting — and can only do that for an icon supplied
/// as *contents*. Given only the `.icns` it fills our transparent margin with
/// white and rounds the result, which is how this app came to sit in a cream
/// plate in the Dock. Neither file is derivable from the other: one must carry
/// a tile and the other must not.
///
/// ## Why the two artworks use different colours
///
/// Liquid Glass lights a layer, and lighting only ever adds. Every colour
/// handed to it comes back lighter and less saturated, so the vector layer is
/// pre-compensated and the flat tile is not. The numbers below were not picked
/// by eye: each was rendered through the real pipeline and measured against
/// the traffic lights of the running system, and the set that ships is the one
/// with the smallest total distance.
enum Palette {
    /// The window dots as this Mac actually draws them, sampled from
    /// `NSWindow.standardWindowButton` with the window key — not from the hex
    /// values that circulate for them, which are from an older macOS and which
    /// this system does not match.
    ///
    /// Taken as the mean of the most-saturated 40% of each button's pixels.
    /// The centre of a dot carries a specular highlight and its rim carries a
    /// dark edge, so both a single centre sample and a whole-dot average come
    /// out wrong; the first attempt read #E3E3E3 three times, which was the
    /// unfocused state rather than a sampling fault.
    static let systemDots = ["#F17067", "#F4CD3F", "#64C669"]

    /// What to hand Liquid Glass so that what comes *out* is `systemDots`.
    ///
    /// Distance from the system colours, in RGB units, at each stage of
    /// getting here — smaller is closer:
    ///
    ///     layer colours            red    yellow  green   total
    ///     the sampled values       0.178  0.210   0.223   0.611
    ///     naively deepened         0.220  0.092   0.140   0.452
    ///     these                    0.077  0.092   0.049   0.217
    ///
    /// The middle row is why this is a measurement and not a rule of thumb:
    /// deepening helped yellow and green and made red worse, so red was swept
    /// separately.
    static let glassDots = ["#EE5A44", "#F0BE00", "#12B92E"]

    /// Black on the vector track, graphite on the flat one, for the same
    /// reason and by the same measurement: 0.13 graphite comes out of the
    /// compositor at 0.46 luminance where the flat tile puts it at 0.18.
    /// Contrast against the tile ran 0.440 at 0.13, 0.499 at 0.07 and 0.545 at
    /// black, and black is the floor.
    static let flatInk = "#1C1C1E"
    static let glassInk = "#000000"
}

/// Fails loudly. `iconutil` and `actool` both run straight after this in the
/// Makefile, and a swallowed write error produced an iconset missing
/// representations while the script still reported writing all ten — so the
/// build carried on and the app shipped with a blurred icon at one size.
func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

func colour(_ hex: String) -> NSColor {
    var value: UInt64 = 0
    Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

/// The mark as SVG, for Icon Composer.
///
/// Vector, not a bitmap: the compiled catalogue carries it as a `Vector` asset
/// exactly as Apple's own icons do, so macOS 26 rasterises it at whatever size
/// it needs rather than resampling ours.
enum SVGWriter {
    static func number(_ value: CGFloat) -> String {
        let rounded = (Double(value) * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    static func write(_ g: Mark.Geometry, ink: String, dots: [String]) -> String {
        let n = number
        var out = """
            <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" \
            viewBox="0 0 1024 1024">
            """
        let b = g.box.insetBy(dx: g.stroke / 2, dy: g.stroke / 2)
        out += "\n  <rect x=\"\(n(b.minX))\" y=\"\(n(b.minY))\" width=\"\(n(b.width))\""
        out += " height=\"\(n(b.height))\" rx=\"\(n(g.corner))\" fill=\"none\""
        out += " stroke=\"\(ink)\" stroke-width=\"\(n(g.stroke))\"/>"
        for (index, dot) in g.dots.enumerated() {
            out += "\n  <circle cx=\"\(n(dot.x))\" cy=\"\(n(dot.y))\""
            out += " r=\"\(n(g.dotRadius))\" fill=\"\(dots[index])\"/>"
        }
        for row in g.keyRows {
            for key in row {
                out += "\n  <rect x=\"\(n(key.minX))\" y=\"\(n(key.minY))\""
                out += " width=\"\(n(key.width))\" height=\"\(n(key.height))\""
                out += " rx=\"\(n(min(key.width, key.height) * 0.30))\" fill=\"\(ink)\"/>"
            }
        }
        return out + "\n</svg>\n"
    }
}

/// The tile the flat icon sits on, and the composition of the two.
enum IconArtwork {
    /// Apple's grid: on a 1024 canvas the rounded tile is 824 across.
    static let tileFraction: CGFloat = 824.0 / 1024.0

    /// A superellipse, not a rounded rectangle.
    ///
    /// macOS icon tiles use a continuous corner — the curvature eases in
    /// rather than meeting the straight edge abruptly — and `NSBezierPath`
    /// has no such thing. `|x/a|^n + |y/b|^n = 1` at n = 5 is the shape, and
    /// sampling it is both shorter and more accurate than faking it with arcs.
    static func squircle(in rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
        let path = NSBezierPath()
        let a = rect.width / 2, b = rect.height / 2
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let steps = 720
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let cosT = cos(t), sinT = sin(t)
            let x = a * copysign(pow(abs(cosT), 2 / exponent), cosT)
            let y = b * copysign(pow(abs(sinT), 2 / exponent), sinT)
            let point = NSPoint(x: centre.x + x, y: centre.y + y)
            if step == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }

    /// Near-white, lit from the top, with a shadow and a hairline edge.
    ///
    /// White rather than the silver this used to be: the mark now carries
    /// three saturated dots and is otherwise black, so the tile's job is to
    /// stay out of their way. A tile with its own grey defeats that twice — it
    /// mutes the dots and it leaves the whole icon reading as colourless.
    static func drawTile(_ path: NSBezierPath, in tile: NSRect, pixelSize: CGFloat) {
        // The shadow is part of the artwork on macOS, not something the Dock
        // adds. Skipped under 64 pixels, where it is a smudge on an already
        // small mark.
        if pixelSize >= 64 {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.30)
            shadow.shadowBlurRadius = pixelSize * 0.020
            shadow.shadowOffset = NSSize(width: 0, height: -pixelSize * 0.012)
            shadow.set()
            NSColor.black.setFill()
            path.fill()
        }
        NSGradient(
            colors: [
                NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                NSColor(srgbRed: 0.918, green: 0.925, blue: 0.937, alpha: 1),
            ])?.draw(in: path, angle: -90)

        // A hairline border. A light tile needs a dark edge to stop it
        // dissolving into a pale Dock background. Below 64 pixels it is
        // thinner than a pixel and only muddies the outline, so it is left off.
        if pixelSize >= 64 {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            path.setClip()
            let border = squircle(in: tile.insetBy(dx: pixelSize * 0.004, dy: pixelSize * 0.004))
            border.lineWidth = pixelSize * 0.007
            NSColor(calibratedWhite: 0, alpha: 0.13).setStroke()
            border.stroke()
        }
    }

    /// The mark's side, as a share of the *canvas*, so that it lands at a
    /// consistent share of the tile inside it.
    static let markShare: CGFloat = 0.560

    static func render(pixelSize: CGFloat) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixelSize), pixelsHigh: Int(pixelSize),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        // Paired with the setup rather than left to a `restore` at the far end
        // of the function, which every later early exit would have to remember.
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        let tileSide = pixelSize * tileFraction
        let tile = NSRect(
            x: (pixelSize - tileSide) / 2, y: (pixelSize - tileSide) / 2,
            width: tileSide, height: tileSide)
        drawTile(squircle(in: tile), in: tile, pixelSize: pixelSize)

        // The geometry is always built on the 1024 grid and scaled down at the
        // point of drawing, so a 16-pixel icon is the same drawing as a 1024
        // one rather than a second set of numbers that has to be kept in step.
        let detail = Mark.detail(forPixelSize: pixelSize)
        let geometry = Mark.geometry(
            side: Mark.canvas * markShare, bandShare: 0.26,
            rows: detail.rows, columns: detail.columns, strokeShare: detail.stroke)
        MarkRenderer.draw(
            geometry, ink: colour(Palette.flatInk),
            dots: detail.dots
                ? Palette.systemDots.map(colour)
                : [NSColor.clear, NSColor.clear, NSColor.clear],
            scale: pixelSize / Mark.canvas)
        return rep
    }
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

do {
    try FileManager.default.createDirectory(
        atPath: outputDirectory, withIntermediateDirectories: true)
} catch {
    die("could not create \(outputDirectory): \(error.localizedDescription)")
}

/// The ten representations macOS asks for, by name.
let representations: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in representations {
    let rep = IconArtwork.render(pixelSize: size)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        die("could not encode \(name) as PNG")
    }
    do {
        try data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name).png"))
    } catch {
        die("could not write \(name).png: \(error.localizedDescription)")
    }
}
print("wrote \(representations.count) representations to \(outputDirectory)")

// The second product, when a path for it is given. Optional because the
// iconset alone is still useful on its own — `make icon` asks for both.
if CommandLine.arguments.count > 2 {
    let path = CommandLine.arguments[2]
    // Full detail, always: the system rasterises this itself at every size, so
    // the size-dependent simplification the flat set needs does not apply.
    let geometry = Mark.geometry(
        side: Mark.canvas * 0.68, bandShare: 0.26, rows: 3, columns: 5)
    let svg = SVGWriter.write(geometry, ink: Palette.glassInk, dots: Palette.glassDots)
    do {
        try svg.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        die("could not write \(path): \(error.localizedDescription)")
    }
    print("wrote the Liquid Glass layer to \(path)")
}
