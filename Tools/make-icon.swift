import AppKit

/// Draws the app icon set.
///
/// Run with `make icon`, which pipes the result through `iconutil`. The output
/// is committed, so a normal build needs neither this nor a Swift toolchain
/// detour — but the icon stays reproducible, and changing it is an edit here
/// rather than a trip through a drawing program.
///
/// Two things make this an icon *set* rather than one picture scaled ten ways.
/// The artwork simplifies as it shrinks, because `keyboard.badge.eye`'s badge
/// and its rows of small keys collapse into a smudge well before 16 points.
/// Weight is deliberately *not* varied across sizes: one weight reads at all of
/// them, and the earlier plan to thicken the mark as it shrank was tried and
/// looked heavy at 32 rather than clearer.
///
/// The mark is *cut out* of the tile rather than painted on it. Where the
/// keyboard is, there is nothing — the desktop shows through. That is the
/// point and it is also the risk: the mark has no colour of its own, so on a
/// dark wallpaper it goes dark. The lit edge in `drawMark` is what answers
/// that. A hole in a thick piece of glass catches light along its cut, and
/// tracing every cut edge in near-white gives the shape an outline that
/// survives whatever is behind it.
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

    /// Which symbol to draw, and how heavy, at a given rendered size.
    ///
    /// `keyboard.badge.eye` is the app's mark — a keyboard being watched,
    /// which is what this app does to your typing.
    ///
    /// It simplifies twice on the way down, and the thresholds come from
    /// rendering the candidates side by side rather than from guessing. At 32
    /// pixels the *filled* badge is still a distinguishable eye, so the eye —
    /// which is the mark — survives there; the outlined variant at that size
    /// is a smear. Only at 16 does the badge become a smudge that makes the
    /// keyboard beside it harder to read, and there the plain keyboard stands
    /// alone.
    ///
    /// Both the weight and the widths went up when the tile went blue, and for
    /// one reason rather than taste. A shape cut out of a dark ground reads
    /// thinner than the same shape painted on a light one — light bleeds
    /// across the cut edge and eats into it. `.medium` on blue lands about
    /// where `.regular` landed on silver. The widths were then set from the
    /// same side-by-side pass: at 32 the badge holds together at 0.90 of the
    /// tile and loses the eye at 0.80, which is the size that decides it,
    /// because a Dock icon is admired at 1024 and *used* at 32.
    ///
    /// `width` is the share of the tile the glyph should span, measured on the
    /// *rendered* image rather than set as a point size. A symbol's point size
    /// is its cap height, so sizing by it makes a wide mark overflow and a
    /// narrow one look lost.
    static func symbol(forPixelSize size: CGFloat) -> (name: String, weight: NSFont.Weight, width: CGFloat) {
        switch size {
        case ..<24: return ("keyboard.fill", .medium, 0.86)
        case ..<80: return ("keyboard.badge.eye.fill", .medium, 0.90)
        default: return ("keyboard.badge.eye", .medium, 0.84)
        }
    }

    /// sRGB, written as bytes because that is how the ramp was chosen.
    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    /// The blue glass tile: shadow, body, specular, bounce and rim.
    ///
    /// Five passes, and each one is a thing glass actually does. Take any of
    /// them away and it flattens into a coloured square: the body alone is
    /// paint, the body plus the specular is plastic, and it is the rim — the
    /// lit edge of a slab thick enough to have an edge — that makes it read as
    /// a material with depth rather than a colour.
    ///
    /// Everything but the body is size-gated. A specular highlight at 16
    /// pixels is two grey pixels in the corner, which is noise rather than
    /// light.
    static func drawTile(_ path: NSBezierPath, in tile: NSRect, pixelSize: CGFloat) {
        // The shadow is part of the artwork on macOS, not something the Dock
        // adds. Skipped under 64 pixels, where it is a smudge on an already
        // small mark.
        if pixelSize >= 64 {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.36)
            shadow.shadowBlurRadius = pixelSize * 0.022
            shadow.shadowOffset = NSSize(width: 0, height: -pixelSize * 0.014)
            shadow.set()
            NSColor.black.setFill()
            path.fill()
        }

        // The body. Four stops rather than two: a straight two-stop ramp puts
        // its fastest change in the middle of the tile, which is exactly where
        // the mark sits, and the mark's cut edge then crosses a visible band.
        // Weighting the stops toward the foot keeps the middle even and puts
        // the darkening where there is nothing to interfere with.
        NSGradient(
            colors: [rgb(74, 139, 224), rgb(36, 91, 192), rgb(22, 50, 126), rgb(12, 30, 87)],
            atLocations: [0, 0.42, 0.74, 1], colorSpace: .sRGB
        )?.draw(in: path, angle: -90)

        guard pixelSize >= 32 else { return }

        NSGraphicsContext.saveGraphicsState()
        path.setClip()
        // Specular: the broad reflection a curved face throws back at the top.
        // The ellipse is deliberately wider than the tile so its own edges
        // leave the frame — contained, it draws a visible arc across the
        // artwork and reads as a drawn shape instead of as light.
        let sheen = NSRect(
            x: tile.minX - tile.width * 0.28, y: tile.midY - tile.height * 0.06,
            width: tile.width * 1.56, height: tile.height * 0.92)
        NSGradient(
            colors: [
                NSColor(white: 1, alpha: 0.34), NSColor(white: 1, alpha: 0.05),
                NSColor(white: 1, alpha: 0),
            ], atLocations: [0, 0.55, 1], colorSpace: .sRGB
        )?.draw(in: NSBezierPath(ovalIn: sheen), angle: -90)

        // Bounce: light coming back up off whatever the tile sits on. Small,
        // and the one warm-ward note in an otherwise cold object — without it
        // the foot of the tile goes to flat navy and the whole thing reads as
        // painted rather than lit.
        let bounce = NSRect(
            x: tile.minX - tile.width * 0.2, y: tile.minY - tile.height * 0.42,
            width: tile.width * 1.4, height: tile.height * 0.62)
        NSGradient(
            colors: [NSColor(white: 1, alpha: 0), rgb(120, 190, 255, 0.30)],
            atLocations: [0, 1], colorSpace: .sRGB
        )?.draw(in: NSBezierPath(ovalIn: bounce), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Rim: bright along the top edge, gone by the foot. Drawn as a ring —
        // the tile path with an inset copy of itself punched out under the
        // even-odd rule — because a gradient can fill a shape and cannot
        // stroke one, and this edge has to fade from lit to unlit along its
        // length. Below 64 pixels the ring is thinner than a pixel and only
        // muddies the outline.
        if pixelSize >= 64 {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let inset = pixelSize * 0.010
            let ring = NSBezierPath()
            ring.append(path)
            ring.append(squircle(in: tile.insetBy(dx: inset, dy: inset)))
            ring.windingRule = .evenOdd
            ring.setClip()
            NSGradient(
                colors: [
                    NSColor(white: 1, alpha: 0.72), NSColor(white: 1, alpha: 0.14),
                    rgb(110, 170, 255, 0.26),
                ], atLocations: [0, 0.45, 1], colorSpace: .sRGB
            )?.draw(in: tile, angle: -90)
        }
    }

    /// Cuts the mark out of the tile, and lights the cut.
    ///
    /// Two passes over the same glyph. The first draws it with a pale shadow
    /// and no offset, which lays a halo on the tile in the exact shape of the
    /// mark; the second punches the glyph away with `.destinationOut`, taking
    /// the tile with it and leaving the halo behind as a lit edge. Doing it
    /// this way rather than by drawing a scaled-up copy underneath matters:
    /// scaling a glyph moves every part of it away from the centre by a
    /// different distance, so the edge would come out thick at the rim of the
    /// mark and invisible near the middle. A shadow spreads the same distance
    /// everywhere, including into the gaps between the keys.
    static func drawMark(_ mark: NSImage, in box: NSRect, pixelSize: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = rgb(209, 235, 255, 0.95)
        // Floored at a pixel. Below that the blur rounds to nothing and the
        // edge silently stops existing at exactly the sizes that need it most.
        glow.shadowBlurRadius = max(pixelSize * 0.016, 1)
        glow.shadowOffset = .zero
        glow.set()
        mark.draw(in: box)
        NSGraphicsContext.restoreGraphicsState()

        mark.draw(in: box, from: .zero, operation: .destinationOut, fraction: 1)
    }

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

        let canvas = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        let tileSide = pixelSize * tileFraction
        let tile = NSRect(
            x: (pixelSize - tileSide) / 2, y: (pixelSize - tileSide) / 2,
            width: tileSide, height: tileSide)

        // Blue, lit from the top.
        drawTile(squircle(in: tile), in: tile, pixelSize: pixelSize)

        let choice = symbol(forPixelSize: pixelSize)
        // Black, and the colour is arbitrary. The mark is never painted — it
        // is used twice as a stencil, once to cast the halo and once to punch
        // the hole, and both passes read only its alpha.
        let configuration = NSImage.SymbolConfiguration(
            pointSize: tileSide * 0.5, weight: choice.weight
        ).applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
        // Fails loudly. An `if let` here meant a symbol that could not be
        // found or configured was simply not drawn: the script still wrote ten
        // PNGs and reported success, and the app shipped a blank tile.
        guard let symbol = NSImage(systemSymbolName: choice.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else {
            die("could not render \(choice.name) at \(Int(pixelSize))px")
        }
        // Scale the rendered mark to the wanted share of the tile.
        let natural = symbol.size
        let target = tileSide * choice.width
        let scale = target / max(natural.width, 1)
        let drawn = NSSize(width: natural.width * scale, height: natural.height * scale)
        drawMark(
            symbol,
            in: NSRect(
                x: canvas.midX - drawn.width / 2, y: canvas.midY - drawn.height / 2,
                width: drawn.width, height: drawn.height),
            pixelSize: pixelSize)

        return rep
    }
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

/// Fails loudly. `iconutil` runs straight after this in the Makefile, and a
/// swallowed write error produced an iconset missing representations while the
/// script still reported writing all ten — so the build carried on and the app
/// shipped with a blurred icon at one size.
func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

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
