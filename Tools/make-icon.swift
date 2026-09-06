import AppKit

/// Draws the app icon set.
///
/// Run with `make icon`, which pipes the result through `iconutil`. The output
/// is committed, so a normal build needs neither this nor a Swift toolchain
/// detour — but the icon stays reproducible, and changing it is an edit here
/// rather than a trip through a drawing program.
///
/// Two things make this an icon *set* rather than one picture scaled ten ways.
/// The artwork simplifies below 64 points, where `keyboard.macwindow`'s window
/// frame and its rows of small keys collapse into a grey smudge; and the
/// symbol's optical weight rises as it shrinks, because a hairline that reads
/// at 512 disappears at 16.
enum IconArtwork {
    /// Apple's grid: on a 1024 canvas the rounded tile is 824 across.
    static let tileFraction: CGFloat = 824.0 / 1024.0
    /// And its corner is 185.4 of that 824.
    static let cornerFraction: CGFloat = 185.4 / 824.0

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
    /// `keyboard.macwindow` is the app's mark. Below 64 points its window
    /// frame and key rows fall below a pixel apiece, so the plain `keyboard`
    /// stands in — the same silhouette, minus the detail that has stopped
    /// being detail. Weight climbs as size falls for the same reason.
    /// `width` is the share of the tile the glyph should span, measured on the
    /// *rendered* image rather than set as a point size. A symbol's point size
    /// is its cap height, so sizing by it makes a wide mark like
    /// `keyboard.macwindow` overflow and a narrow one look lost.
    static func symbol(forPixelSize size: CGFloat) -> (name: String, weight: NSFont.Weight, width: CGFloat) {
        switch size {
        case ..<40: return ("keyboard.fill", .regular, 0.62)
        case ..<80: return ("keyboard", .medium, 0.62)
        default: return ("keyboard.macwindow", .regular, 0.60)
        }
    }

    static func render(pixelSize: CGFloat) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixelSize), pixelsHigh: Int(pixelSize),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        let canvas = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        let tileSide = pixelSize * tileFraction
        let tile = NSRect(
            x: (pixelSize - tileSide) / 2, y: (pixelSize - tileSide) / 2,
            width: tileSide, height: tileSide)

        // Graphite, lit from the top, like every other dark tile in the Dock.
        let path = squircle(in: tile)
        // The shadow is part of the artwork on macOS, not something the Dock
        // adds. Skipped under 64 pixels, where it is a smudge on an already
        // small mark.
        if pixelSize >= 64 {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.32)
            shadow.shadowBlurRadius = pixelSize * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -pixelSize * 0.012)
            shadow.set()
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGradient(
            colors: [
                NSColor(calibratedWhite: 0.26, alpha: 1),
                NSColor(calibratedWhite: 0.11, alpha: 1),
            ])?.draw(in: path, angle: -90)

        // A hairline along the top edge: the highlight that keeps a dark tile
        // from reading as a hole. Below 64 pixels it is thinner than a pixel
        // and only muddies the edge, so it is left off.
        if pixelSize >= 64 {
            NSGraphicsContext.saveGraphicsState()
            path.setClip()
            let highlight = squircle(in: tile.insetBy(dx: pixelSize * 0.004, dy: pixelSize * 0.004))
            highlight.lineWidth = pixelSize * 0.006
            NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
            highlight.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        let choice = symbol(forPixelSize: pixelSize)
        let configuration = NSImage.SymbolConfiguration(
            pointSize: tileSide * 0.5, weight: choice.weight
        ).applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: choice.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        {
            // Scale the rendered mark to the wanted share of the tile.
            let natural = symbol.size
            let target = tileSide * choice.width
            let scale = target / max(natural.width, 1)
            let drawn = NSSize(width: natural.width * scale, height: natural.height * scale)
            symbol.draw(
                in: NSRect(
                    x: canvas.midX - drawn.width / 2, y: canvas.midY - drawn.height / 2,
                    width: drawn.width, height: drawn.height))
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true)

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
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name).png"))
}
print("wrote \(representations.count) representations to \(outputDirectory)")
