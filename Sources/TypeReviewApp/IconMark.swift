import AppKit

// The app icon's mark, and the only definition of it.
//
// It lives in the app rather than in `Tools/make-icon.swift` because two
// things draw it: that tool, which compiles this file alongside itself to
// produce `Resources/TypeReview.icns` and the Icon Composer layer, and the
// status item, which draws it live at menu-bar size. Kept in the tool it would
// have had to be copied here, and a menu-bar mark that has quietly stopped
// matching the Dock icon is exactly the kind of drift nobody notices until a
// screenshot puts the two side by side.
//
// No AppKit drawing happens at parse time, so importing this costs the app
// nothing until something asks for a path.

/// The mark's geometry, defined once and rendered twice.
enum Mark {
    /// Both renderers work on a 1024 grid in SVG's convention, y downward.
    /// AppKit's y runs the other way and is flipped at the point of drawing,
    /// so there is one definition rather than two that can disagree.
    static let canvas: CGFloat = 1024

    struct Geometry {
        var box: CGRect
        var corner: CGFloat
        var stroke: CGFloat
        var dots: [CGPoint]
        var dotRadius: CGFloat
        var keyRows: [[CGRect]]
    }

    /// - Parameters:
    ///   - side: the housing's side, as pixels on the 1024 grid.
    ///   - bandShare: how much of the interior height the title band takes.
    ///   - rows: rows of keys. The last is always the spacebar row.
    ///   - columns: keys per row.
    static func geometry(
        side: CGFloat, bandShare: CGFloat, rows: Int, columns: Int,
        strokeShare: CGFloat = 0.075
    ) -> Geometry {
        let box = CGRect(
            x: (canvas - side) / 2, y: (canvas - side) / 2, width: side, height: side)
        let stroke = side * strokeShare
        let corner = side * 0.185
        let pad = stroke * 1.55
        let inner = box.insetBy(dx: pad + stroke / 2, dy: pad + stroke / 2)

        // The three dots, left-aligned, where a Mac window puts them and where
        // `keyboard.macwindow` puts them. The mark still reads as centred
        // because they sit *inside* a square housing rather than hanging off
        // an edge, which was the whole problem with a badge.
        let band = inner.height * bandShare
        let dotR = band * 0.235
        let dotGap = dotR * 2.75
        let dotCY = inner.minY + band * 0.46
        let dots = (0..<3).map {
            CGPoint(x: inner.minX + dotR + dotGap * CGFloat($0), y: dotCY)
        }

        // No keys at all is a real request, not an edge case to guard against:
        // see `detail(forPixelSize:)`. Everything below divides by `rows`.
        guard rows > 0 else {
            return Geometry(
                box: box, corner: corner, stroke: stroke,
                dots: dots, dotRadius: dotR, keyRows: [])
        }

        let keyTop = inner.minY + band + inner.height * 0.055
        let area = CGRect(
            x: inner.minX, y: keyTop, width: inner.width, height: inner.maxY - keyTop)
        let gapY = area.height * 0.16
        let keyH = (area.height - gapY * CGFloat(rows - 1)) / CGFloat(rows)
        let gapX = area.width * 0.075
        let keyW = (area.width - gapX * CGFloat(columns - 1)) / CGFloat(columns)

        var keyRows: [[CGRect]] = []
        for row in 0..<rows {
            let y = area.minY + (keyH + gapY) * CGFloat(row)
            if row == rows - 1 {
                keyRows.append([
                    CGRect(x: area.minX, y: y, width: keyW, height: keyH),
                    CGRect(
                        x: area.minX + keyW + gapX, y: y,
                        width: keyW * CGFloat(columns - 2) + gapX * CGFloat(columns - 3),
                        height: keyH),
                    CGRect(x: area.maxX - keyW, y: y, width: keyW, height: keyH),
                ])
            } else {
                keyRows.append(
                    (0..<columns).map {
                        CGRect(
                            x: area.minX + (keyW + gapX) * CGFloat($0), y: y,
                            width: keyW, height: keyH)
                    })
            }
        }
        return Geometry(
            box: box, corner: corner, stroke: stroke,
            dots: dots, dotRadius: dotR, keyRows: keyRows)
    }

    /// How much detail survives at a given rendered size.
    ///
    /// The thresholds come from rendering the candidates and looking, not from
    /// guessing. A Dock icon is admired at 1024 and *used* at 32, so 32 is the
    /// size that decides: five columns and three rows still read there, with
    /// the dots still distinguishable as three colours.
    ///
    /// At 16 the keys go entirely. Coarsening them to two rows of three was
    /// tried first and was worse than dropping them: at that size a key is
    /// about a pixel and a half and the gaps are under one, so the grid fuses
    /// into vertical bars and takes the housing's outline down with it. A
    /// rounded window with three coloured dots is less information and more
    /// of it survives, which is the whole point of simplifying rather than
    /// shrinking.
    static func detail(
        forPixelSize size: CGFloat
    ) -> (rows: Int, columns: Int, dots: Bool, stroke: CGFloat) {
        switch size {
        case ..<24: return (0, 0, true, 0.075)
        // The menu bar draws the mark at about 30 pixels with no tile behind
        // it, and at the full weight it reads as a solid block rather than as
        // a window. Thinning the wall is the same kind of size-dependent
        // correction as dropping the keys, so it lives with it rather than
        // being a number the status item passes in from outside.
        case ..<40: return (3, 5, true, 0.055)
        default: return (3, 5, true, 0.075)
        }
    }
}

/// The mark as pixels: the flat `.icns`, and the menu bar.
enum MarkRenderer {
    /// The one place the two coordinate conventions meet. Everything else
    /// works in SVG's, so there is no second definition to drift.
    static func flip(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: Mark.canvas - r.maxY, width: r.width, height: r.height)
    }

    static func draw(_ g: Mark.Geometry, ink: NSColor, dots: [NSColor], scale: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()

        let outline = flip(g.box).insetBy(dx: g.stroke / 2, dy: g.stroke / 2)
        let housing = NSBezierPath(
            roundedRect: outline, xRadius: g.corner, yRadius: g.corner)
        housing.lineWidth = g.stroke
        ink.setStroke()
        housing.stroke()

        for (index, dot) in g.dots.enumerated() {
            dots[index].setFill()
            let y = Mark.canvas - dot.y
            NSBezierPath(
                ovalIn: NSRect(
                    x: dot.x - g.dotRadius, y: y - g.dotRadius,
                    width: g.dotRadius * 2, height: g.dotRadius * 2)
            ).fill()
        }

        ink.setFill()
        for row in g.keyRows {
            for key in row {
                let r = flip(key)
                let radius = min(r.width, r.height) * 0.30
                NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            }
        }
    }
}

extension Mark {
    /// The mark as a menu-bar template image.
    ///
    /// A template, so macOS inverts it for a dark bar and dims it when the bar
    /// is inactive — the two things a hand-tinted image gets wrong. Templates
    /// read only alpha, so the three window dots arrive as holes in the ink
    /// rather than as red, yellow and green. That is not a loss: at menu-bar
    /// size the colours would be three pixels each, and what survives is the
    /// arrangement, which is the part that says "window".
    ///
    /// Drawn through `NSImage`'s handler rather than baked into a bitmap so
    /// the system re-renders it per scale factor, which is what keeps it crisp
    /// when a window is dragged between a Retina display and an external one.
    ///
    /// - Parameter pointSize: the side of the square, in points. This is the
    ///   ink, not a bounding box with padding: the mark fills what it is given.
    static func menuBarImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) {
            rect in
            // The geometry is always built on the 1024 grid and scaled at the
            // point of drawing, so the menu bar draws the same numbers the
            // Dock icon does rather than a second, smaller design.
            let detail = Mark.detail(forPixelSize: rect.width * 2)
            let geometry = Mark.geometry(
                side: Mark.canvas, bandShare: 0.26,
                rows: detail.rows, columns: detail.columns, strokeShare: detail.stroke)
            // Black: a template's colour is discarded, and black is the
            // convention for the ink so the image is legible when something
            // renders it without the template treatment.
            MarkRenderer.draw(
                geometry, ink: .black, dots: [.black, .black, .black],
                scale: rect.width / Mark.canvas)
            return true
        }
        image.isTemplate = true
        return image
    }
}
