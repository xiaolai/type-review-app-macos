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
/// and its rows of small keys collapse into a grey smudge well before 16
/// points. Weight is deliberately *not* varied: `.regular` reads at every one
/// of these sizes, and the earlier plan to thicken the mark as it shrank was
/// tried and looked heavy at 32 rather than clearer.
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
    /// is a grey smear. Only at 16 does the badge become a smudge that makes
    /// the keyboard beside it harder to read, and there the plain keyboard
    /// stands alone. The weight is `.regular` throughout — see the note at
    /// the top of this file.
    ///
    /// `width` is the share of the tile the glyph should span, measured on the
    /// *rendered* image rather than set as a point size. A symbol's point size
    /// is its cap height, so sizing by it makes a wide mark overflow and a
    /// narrow one look lost.
    static func symbol(forPixelSize size: CGFloat) -> (name: String, weight: NSFont.Weight, width: CGFloat) {
        switch size {
        case ..<24: return ("keyboard.fill", .regular, 0.74)
        case ..<80: return ("keyboard.badge.eye.fill", .regular, 0.78)
        default: return ("keyboard.badge.eye", .regular, 0.78)
        }
    }

    /// The rounded silver tile: shadow, gradient and hairline border.
    ///
    /// Split out of `render`, which was doing this as well as bitmap setup and
    /// symbol placement in one 75-line block, with its graphics-state saves
    /// and restores separated by forty lines of unrelated drawing.
    static func drawTile(_ path: NSBezierPath, in tile: NSRect, pixelSize: CGFloat) {
        // The shadow is part of the artwork on macOS, not something the Dock
        // adds. Skipped under 64 pixels, where it is a smudge on an already
        // small mark.
        if pixelSize >= 64 {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.32)
            shadow.shadowBlurRadius = pixelSize * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -pixelSize * 0.012)
            shadow.set()
            NSColor.black.setFill()
            path.fill()
        }
        NSGradient(
            colors: [
                NSColor(calibratedWhite: 0.99, alpha: 1),
                NSColor(calibratedWhite: 0.86, alpha: 1),
            ])?.draw(in: path, angle: -90)

        // A hairline border. A dark tile needs a light edge to stop it reading
        // as a hole; a light one needs a dark edge to stop it dissolving into
        // a pale Dock background. Below 64 pixels it is thinner than a pixel
        // and only muddies the outline, so it is left off.
        if pixelSize >= 64 {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            path.setClip()
            let border = squircle(in: tile.insetBy(dx: pixelSize * 0.004, dy: pixelSize * 0.004))
            border.lineWidth = pixelSize * 0.007
            NSColor(calibratedWhite: 0, alpha: 0.14).setStroke()
            border.stroke()
        }
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

        // Silver, lit from the top — the colour of the keyboard case the app
        // draws, and of the hardware it is a picture of.
        drawTile(squircle(in: tile), in: tile, pixelSize: pixelSize)

        let choice = symbol(forPixelSize: pixelSize)
        let configuration = NSImage.SymbolConfiguration(
            pointSize: tileSide * 0.5, weight: choice.weight
        ).applying(
            NSImage.SymbolConfiguration(
                paletteColors: [NSColor(calibratedWhite: 0.13, alpha: 1)]))
        // Fails loudly. An `if let` here meant a symbol that could not be
        // found or configured was simply not drawn: the script still wrote ten
        // PNGs and reported success, and the app shipped a blank silver tile.
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
        symbol.draw(
            in: NSRect(
                x: canvas.midX - drawn.width / 2, y: canvas.midY - drawn.height / 2,
                width: drawn.width, height: drawn.height))

        return rep
    }
}

/// The mark on its own, for Icon Composer.
///
/// macOS 26 does not want a picture of an icon. It wants the *contents* — the
/// mark, on nothing — and supplies the tile, the lighting and the shadow
/// itself, live, so the icon can answer to light mode, dark mode and tinting.
/// Handing it the finished `.icns` instead is what put a cream plate behind
/// this app in the Dock: the system filled the transparent margin around our
/// own 80.5% tile with white and rounded the result, so the icon became a
/// small tile sitting inside a big white one.
///
/// So the same mark ships twice, and deliberately. `Resources/TypeReview.icns`
/// is the whole picture, tile included, for macOS 14 and 15, which draw an app
/// icon exactly as given and expect it to arrive pre-shaped. This layer is the
/// mark alone, for macOS 26, which shapes it. Neither is derivable from the
/// other by cropping: one must carry a tile and the other must not.
func writeLiquidGlassLayer(to path: String) {
    let pixelSize: CGFloat = 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixelSize), pixelsHigh: Int(pixelSize),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // The outlined variant, and black rather than the flat tile's graphite.
    //
    // Not a different design decision — the same one, corrected for what the
    // system does to it. Liquid Glass lights a layer, and lighting only ever
    // adds: the graphite the flat icon uses (0.13) comes out of the compositor
    // at 0.46 luminance, against 0.18 on the flat tile, so the mark arrives
    // washed out. Measured across three layer values, contrast against the
    // tile went 0.440 at 0.13, 0.499 at 0.07, 0.545 at black — and black is
    // the floor. The flat icon's 0.756 is simply not reachable through this
    // renderer, so this takes the most of it that exists rather than pretending
    // the two can be matched.
    //
    // This layer is only ever rendered large — the system derives every small
    // size from it — so the size-dependent simplification that
    // `symbol(forPixelSize:)` exists for does not apply here.
    let configuration = NSImage.SymbolConfiguration(pointSize: pixelSize * 0.40, weight: .regular)
        .applying(
            NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedWhite: 0, alpha: 1)]))
    guard let mark = NSImage(systemSymbolName: "keyboard.badge.eye", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else {
        die("could not render the Liquid Glass layer")
    }
    // Smaller than the share the mark takes on the `.icns`, and not by taste.
    // There the mark sits inside a tile that is itself 80.5% of the canvas;
    // here the system's tile is the whole canvas, so the same optical size
    // needs a smaller number. 0.63 of the canvas is 0.78 of the tile, which is
    // where the flat icon already puts it.
    let target = pixelSize * 0.63
    let scale = target / max(mark.size.width, 1)
    let drawn = NSSize(width: mark.size.width * scale, height: mark.size.height * scale)
    mark.draw(
        in: NSRect(
            x: pixelSize / 2 - drawn.width / 2, y: pixelSize / 2 - drawn.height / 2,
            width: drawn.width, height: drawn.height))

    guard let data = rep.representation(using: .png, properties: [:]) else {
        die("could not encode the Liquid Glass layer as PNG")
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        die("could not write \(path): \(error.localizedDescription)")
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

// The second product, when a path for it is given. Optional because the
// iconset alone is still useful on its own — `make icon` asks for both.
if CommandLine.arguments.count > 2 {
    writeLiquidGlassLayer(to: CommandLine.arguments[2])
    print("wrote the Liquid Glass layer to \(CommandLine.arguments[2])")
}
