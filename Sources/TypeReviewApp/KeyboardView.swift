import AppKit
import TypeReviewKit

/// The on-screen keyboard: real geometry, real labels, tinted by how well each
/// key is going.
///
/// Every label comes from `UCKeyTranslate`, so switching to Dvorak in System
/// Settings relabels this view and nothing here knows what Dvorak is. The
/// keyboard shape comes from the hardware, so an ISO machine gets its extra
/// key and a JIS machine gets 英数 / かな — neither of which the web version
/// can draw.
///
/// Drawn as Apple draws the thing: white chiclet caps with a slim dark bottom
/// lip, set into a recessed case. The lip is what makes a flat rectangle read
/// as a key, and it is a single inset — the cap is filled in the border colour
/// and then refilled 1 pt in on three sides and 2 pt in at the bottom.
final class KeyboardView: NSView {
    /// Per-key statistics, keyed by the character the key produces.
    private var stats: OrderedMap<PerKeyStat> = OrderedMap()
    private var pressed: UInt16?
    private var expected: String?
    /// Milliseconds per character at the user's target speed. The heat scale
    /// is anchored to this rather than to their own slowest key: a relative
    /// scale paints the whole keyboard warm as soon as timings cluster, and
    /// answers "which key is worst" when the useful question is "which keys
    /// are behind target".
    private var targetMs: Double = 240

    /// Bounds on one key's width, in points. The keyboard is sized by its
    /// drawer, which is sized by the window; these only stop the extremes.
    private static let maxUnit: CGFloat = 80
    private static let minUnit: CGFloat = 12

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Everything here is drawn from the view's own size, so a cached
        // layer goes stale the moment the window is resized. Without this the
        // keyboard keeps its old cap size, clipped, until the resize ends.
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(stats: OrderedMap<PerKeyStat>, expected: String?, targetWpm: Double) {
        self.stats = stats
        self.expected = expected
        targetMs = Target(targetSpeed: targetWpm).timePerChar
        needsDisplay = true
    }

    func setPressed(_ keyCode: UInt16?) {
        pressed = keyCode
        needsDisplay = true
    }

    /// The keyboard reports its own height rather than being told one. A
    /// constant works until the window is a different width, or the keyboard
    /// is an ISO or JIS one with an extra key per row — then the bottom row is
    /// quietly drawn outside the view.
    /// The height this keyboard needs to draw a full keyboard at the given
    /// width. The drawer asks before it has a height of its own, which is why
    /// this takes a width rather than reading the view's own bounds — those
    /// are zero until the drawer has been sized, and a height derived from
    /// zero is a drawer that never opens.
    func naturalHeight(forWidth width: CGFloat) -> CGFloat {
        ceil(layout(forWidth: width, height: .greatestFiniteMagnitude).caseRect.height + 2)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// The cap size that fits both dimensions.
    ///
    /// Height matters as much as width now that the keyboard lives in a
    /// drawer: dragging the divider is *how* you resize it, and a keyboard
    /// that only reads its width would either overflow the drawer or ignore
    /// the drag. Padding scales with the unit, so it belongs inside the
    /// division rather than being subtracted first.
    private func unitWidth(for width: CGFloat, height: CGFloat = .greatestFiniteMagnitude)
        -> CGFloat
    {
        let rows = CGFloat(KeyboardGeometry.rows(for: SystemKeyboard.shape).count)
        // The case fills the width it is given. `unitsPerRow` keys plus the
        // padding either side less the one trailing gap comes to 15.3 units,
        // and dividing by that makes the case exactly as wide as the view —
        // the drawer decides how wide that is.
        let byWidth = width / (CGFloat(KeyboardGeometry.unitsPerRow) + 0.3)
        let byHeight = (height - 2) / (rows + 0.3)
        return floor(min(Self.maxUnit, max(Self.minUnit, min(byWidth, byHeight))))
    }

    private func casePadding(_ unit: CGFloat) -> CGFloat { max(4, (unit * 0.2).rounded()) }

    /// The case's corner radius, as a fraction of the key pitch. A Magic
    /// Keyboard's shell is about 10 mm round on a 19 mm pitch.
    private static let caseRadiusScale: CGFloat = 0.5

    /// The air between caps, as a fraction of the key pitch.
    ///
    /// Apple's own: a Magic Keyboard is a 19 mm pitch with a 16 mm cap, which
    /// is a gap of 0.158.
    private func keyGap(_ unit: CGFloat) -> CGFloat { max(3, (unit * 0.16).rounded()) }

    /// Where everything goes, for a given available width.
    ///
    /// Shared with the selftest rather than recomputed there: a check that
    /// re-derives the layout from the same formula proves only that the
    /// formula equals itself. This way the check measures the rectangles the
    /// view actually draws.
    /// Which corner of the case a key sits in, if any.
    enum Corner {
        case topLeading, topTrailing, bottomTrailing, bottomLeading
    }

    struct Layout {
        let caseRect: NSRect
        let unit: CGFloat
        let keys: [(key: KeyboardGeometry.Key, rect: NSRect, corner: Corner?)]
    }

    func layout(forWidth width: CGFloat, height: CGFloat = .greatestFiniteMagnitude) -> Layout {
        let rows = KeyboardGeometry.rows(for: SystemKeyboard.shape)
        let unit = unitWidth(for: width, height: height)
        let padding = casePadding(unit)
        let gap = keyGap(unit)
        // The gap belongs *between* caps, so the case gives back the one
        // trailing gap on each axis. Without this the right and bottom margins
        // are a full gap wider than the left and top — small, consistent, and
        // exactly the kind of asymmetry the eye reads as "not quite right"
        // without being able to name it.
        let caseWidth = unit * CGFloat(KeyboardGeometry.unitsPerRow) + 2 * padding - gap
        let caseHeight = unit * CGFloat(rows.count) + 2 * padding - gap
        // Centred rather than stretched: a keyboard is a fixed object, and one
        // that changes shape with the window stops looking like hardware.
        // Centred both ways. Horizontally because a keyboard is a fixed
        // object and one that stretches with the window stops looking like
        // hardware; vertically because the drawer can be dragged taller than
        // the cap size allows, and the slack should sit around the keyboard
        // rather than under it.
        let caseRect = NSRect(
            x: ((width - caseWidth) / 2).rounded(),
            y: max(1, ((height.isFinite ? height : caseHeight + 2) - caseHeight) / 2).rounded(),
            width: caseWidth, height: caseHeight)

        var placed: [(KeyboardGeometry.Key, NSRect, Corner?)] = []
        var y = caseRect.minY + padding
        for (rowIndex, row) in rows.enumerated() {
            var x = caseRect.minX + padding
            let drawn = row.filter { $0.width > 0 }
            for (index, key) in drawn.enumerated() {
                let width = unit * CGFloat(key.width)
                let corner: Corner? =
                    switch (rowIndex, index) {
                    case (0, 0): .topLeading
                    case (0, drawn.count - 1): .topTrailing
                    case (rows.count - 1, 0): .bottomLeading
                    case (rows.count - 1, drawn.count - 1): .bottomTrailing
                    default: nil
                    }
                placed.append(
                    (key.key, NSRect(x: x, y: y, width: width - gap, height: unit - gap), corner))
                x += width
            }
            y += unit
        }
        return Layout(caseRect: caseRect, unit: unit, keys: placed)
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = layout(forWidth: bounds.width, height: bounds.height)

        let radius = layout.unit * Self.caseRadiusScale
        let casePath = NSBezierPath(
            roundedRect: layout.caseRect, xRadius: radius, yRadius: radius)
        // Apple's body is silver against white caps — a quiet frame, not a
        // dark tray. `underPageBackgroundColor` reads as the latter and turned
        // the keyboard into the loudest thing on the screen.
        NSColor.windowBackgroundColor.setFill()
        casePath.fill()
        NSColor.separatorColor.setStroke()
        casePath.lineWidth = 1
        casePath.stroke()

        for placed in layout.keys {
            draw(placed.key, in: placed.rect, unit: layout.unit, corner: placed.corner)
        }
    }

    /// A rounded rectangle whose corners can differ.
    ///
    /// `NSBezierPath(roundedRect:)` gives every corner the same radius, and
    /// the four keys in the corners of the case need one corner rounder than
    /// the rest. Corner order runs clockwise from the top-left in this
    /// flipped view.
    private func capPath(_ rect: NSRect, _ radii: (CGFloat, CGFloat, CGFloat, CGFloat))
        -> NSBezierPath
    {
        let (topLeading, topTrailing, bottomTrailing, bottomLeading) = radii
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + topLeading, y: rect.minY))
        path.appendArc(
            from: NSPoint(x: rect.maxX, y: rect.minY),
            to: NSPoint(x: rect.maxX, y: rect.maxY), radius: topTrailing)
        path.appendArc(
            from: NSPoint(x: rect.maxX, y: rect.maxY),
            to: NSPoint(x: rect.minX, y: rect.maxY), radius: bottomTrailing)
        path.appendArc(
            from: NSPoint(x: rect.minX, y: rect.maxY),
            to: NSPoint(x: rect.minX, y: rect.minY), radius: bottomLeading)
        path.appendArc(
            from: NSPoint(x: rect.minX, y: rect.minY),
            to: NSPoint(x: rect.maxX, y: rect.minY), radius: topLeading)
        path.close()
        return path
    }

    /// The four radii for a cap, given which corner of the case it sits in.
    ///
    /// The outer corner is **concentric** with the case: its radius is the
    /// case's radius less the padding between them. That is the whole rule on
    /// a Magic Keyboard — the corner caps are cut to follow the shell, and it
    /// is the detail that stops a grid of rounded rectangles reading as a
    /// grid of rounded rectangles.
    private func capRadii(_ corner: Corner?, unit: CGFloat) -> (
        CGFloat, CGFloat, CGFloat, CGFloat
    ) {
        let normal = max(3, unit * 0.15)
        guard let corner else { return (normal, normal, normal, normal) }
        let outer = max(normal, unit * Self.caseRadiusScale - casePadding(unit))
        switch corner {
        case .topLeading: return (outer, normal, normal, normal)
        case .topTrailing: return (normal, outer, normal, normal)
        case .bottomTrailing: return (normal, normal, outer, normal)
        case .bottomLeading: return (normal, normal, normal, outer)
        }
    }

    private func draw(
        _ key: KeyboardGeometry.Key, in rect: NSRect, unit: CGFloat, corner: Corner?
    ) {
        let isPressed = pressed == key.code && key.code != 0xFFFF
        // A pressed cap sinks: the lip closes up and the whole cap moves down
        // by the point it loses. Same trick as the web's `translateY(1px)`,
        // and it reads as travel rather than as a highlight.
        let lip: CGFloat = isPressed ? 1 : 2
        let capRect = isPressed ? rect.offsetBy(dx: 0, dy: 1) : rect
        let radii = capRadii(corner, unit: unit)

        // The lip: the whole cap in the border colour, then the face inset by
        // one point on three sides and by the lip at the bottom.
        NSColor.separatorColor.setFill()
        capPath(capRect, radii).fill()
        let faceRect = NSRect(
            x: capRect.minX + 1, y: capRect.minY + 1,
            width: capRect.width - 2, height: capRect.height - 1 - lip)
        let face = capPath(
            faceRect, (radii.0 - 1, radii.1 - 1, radii.2 - 1, radii.3 - 1))
        NSColor.textBackgroundColor.setFill()
        face.fill()

        // The character this physical key types under the *current* layout.
        let character = key.types ? SystemKeyboard.character(forKeyCode: key.code) : nil
        if let tint = heat(for: key, character: character), !isPressed {
            glaze(face, tint.color, strength: tint.strength)
        }
        if let expected, let character, character == expected, !isPressed {
            // The drilling target. Laid over the heat rather than replacing it
            // — a ring or a border would say "next" while hiding "how is this
            // key going", and both are worth knowing at once.
            glaze(face, Theme.caret, strength: 0.20)
        }
        if isPressed {
            glaze(face, Theme.caret, strength: 0.30)
        }

        if key.role == .touchID {
            drawTouchID(in: faceRect, unit: unit)
            return
        }
        drawLabels(key, character: character, in: faceRect, unit: unit)
    }

    /// Legend size as a fraction of the key.
    ///
    /// Sans, not monospace, and smaller than feels right on paper. Apple's
    /// keycap legends are a sans face at roughly a quarter of the key pitch;
    /// a monospaced face at a third — what this drew first — is the wrong
    /// shape *and* the wrong size, and it shows most on the modifier symbols,
    /// where SF Mono's ⇧ and ⌘ are thin stylised outlines rather than the
    /// solid ones the system font uses everywhere else on macOS.
    ///
    /// Words are set smaller than glyphs because they are longer: `esc` and
    /// `F12` are printed small on the real thing for the same reason.
    private static func labelScale(for key: KeyboardGeometry.Key) -> CGFloat {
        switch key.role {
        case .letter, .space: return 0.26
        case .modifier: return 0.22
        case .function: return 0.19
        case .touchID: return 0.19
        }
    }

    private func drawLabels(
        _ key: KeyboardGeometry.Key, character: String?, in rect: NSRect, unit: CGFloat
    ) {
        let label = key.label ?? character?.uppercased() ?? ""
        guard !label.isEmpty, label != " " else { return }
        let stat = character.flatMap { stats[$0] }
        let color: NSColor =
            switch key.role {
            case .letter: stat == nil ? Theme.secondaryText : Theme.correct
            default: Theme.secondaryText
            }

        // The shifted glyph, from the system rather than a table — so a German
        // keyboard prints its own. Suppressed when it is merely the capital of
        // the same letter, which is not a second glyph on any real cap.
        var shiftedText: String?
        if key.role == .letter, let character,
            let shifted = SystemKeyboard.character(forKeyCode: key.code, shift: true),
            shifted.lowercased() != character.lowercased()
        {
            shiftedText = shifted
        }

        let labelFont = NSFont.systemFont(ofSize: max(6, unit * Self.labelScale(for: key)))

        /// A caption sits nearer the cap edge than a glyph does, which is both
        /// how Apple prints it and the three points that decide whether the
        /// word "control" fits a one-unit key at all.
        struct Line {
            let text: String
            let font: NSFont
            let color: NSColor
            let inset: CGFloat
        }
        let glyphInset = max(2, unit * 0.12)
        var lines: [Line] = []
        if let shiftedText {
            lines.append(
                Line(
                    text: shiftedText,
                    font: NSFont.systemFont(ofSize: max(5, unit * 0.21)),
                    color: Theme.secondaryText.withAlphaComponent(0.75), inset: glyphInset))
        }
        lines.append(Line(text: label, font: labelFont, color: color, inset: glyphInset))
        if let sub = key.sub {
            lines.append(
                Line(
                    text: sub, font: NSFont.systemFont(ofSize: max(5, unit * 0.15)),
                    color: Theme.secondaryText.withAlphaComponent(0.55), inset: 2))
        }

        // Drop any line that does not fit its cap rather than clipping it.
        // Font sizes have a legibility floor, so below a certain cap size the
        // word "command" is wider than the key it names — and half a word
        // spilling onto its neighbour says less than no word at all. Measured
        // per line, so it adapts to the label, the font and the drawer height
        // instead of guessing a cap size to switch at. The primary label is
        // never dropped: a key with no label at all is worse than a tight one.
        let primary = lines.count == 1 ? 0 : (shiftedText == nil ? 0 : 1)
        lines = lines.enumerated().filter { index, line in
            index == primary
                || (line.text as NSString).size(withAttributes: [.font: line.font]).width
                    <= rect.width - 2 * line.inset
        }.map(\.element)

        let spacing = unit * 0.04
        let sizes = lines.map { line in
            (line.text as NSString).size(withAttributes: [.font: line.font])
        }
        let total = sizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(lines.count - 1)
        // The view is flipped, so maxY is the visual bottom of the cap.
        var lineY =
            key.vertical == .bottom
            ? rect.maxY - glyphInset - total
            : rect.midY - total / 2
        for (line, size) in zip(lines, sizes) {
            let lineX: CGFloat =
                switch key.align {
                case .start: rect.minX + line.inset
                case .end: rect.maxX - line.inset - size.width
                case .center: rect.midX - size.width / 2
                }
            (line.text as NSString).draw(
                at: NSPoint(x: lineX, y: lineY),
                withAttributes: [.font: line.font, .foregroundColor: line.color])
            lineY += size.height + spacing
        }
    }

    /// The round button, as a thin outlined circle. A drawn circle rather than
    /// a glyph: no font places one predictably.
    ///
    /// Both the ring's width and its weight are deliberately small. The stroke
    /// scales with the key, so a width that looked right on a 20-point cap
    /// becomes a three-point band on a 54-point one — the button ended up
    /// heavier than every letter on the keyboard, when on the real thing it is
    /// the quietest thing in the row.
    private func drawTouchID(in rect: NSRect, unit: CGFloat) {
        let diameter = min(rect.width, rect.height) * 0.52
        let circle = NSBezierPath(
            ovalIn: NSRect(
                x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                width: diameter, height: diameter))
        circle.lineWidth = max(0.75, unit * 0.022)
        Theme.secondaryText.withAlphaComponent(0.3).setStroke()
        circle.stroke()
    }

    /// A pane of tinted glass over the cap.
    ///
    /// Flat colour at the alpha these tints need reads as paint — the cap
    /// stops being white plastic and becomes a coloured tile, and eleven
    /// coloured tiles are louder than the text they are supposed to annotate.
    /// A vertical ramp from nearly clear at the top to `strength` at the
    /// bottom reads instead as something laid *over* the cap: the cap is still
    /// white, and the colour is a property of the light on it.
    private func glaze(_ face: NSBezierPath, _ color: NSColor, strength: CGFloat) {
        guard
            let gradient = NSGradient(
                starting: color.withAlphaComponent(strength * 0.35),
                ending: color.withAlphaComponent(strength))
        else {
            color.withAlphaComponent(strength).setFill()
            face.fill()
            return
        }
        // -90 in a flipped view puts the light end at the top.
        gradient.draw(in: face, angle: -90)
    }

    /// Heat by speed, with error rate overriding it.
    ///
    /// Speed and accuracy are different problems and a single colour ramp
    /// cannot say both. A key you hit slowly is warm; a key you keep getting
    /// wrong is red regardless of how fast you get it wrong.
    ///
    /// Strengths are deliberately low. This is an annotation on a keyboard,
    /// not a chart: it has to be readable at a glance and invisible when you
    /// are looking at the passage instead.
    private func heat(
        for key: KeyboardGeometry.Key, character: String?
    ) -> (color: NSColor, strength: CGFloat)? {
        guard key.types, let character, let stat = stats[character], stat.hits >= 5
        else { return nil }
        if stat.errorRate > 0.05 {
            return (Theme.incorrect, min(0.30, 0.08 + CGFloat(stat.errorRate)))
        }
        // Confidence, the same ratio the planner uses to decide mastery: at or
        // above 1 the key is at target and stays cool; below it warms.
        let confidence = targetMs / max(stat.avgMs, 1)
        if confidence >= 1 {
            return (.systemTeal, min(0.18, 0.07 + CGFloat(confidence - 1) * 0.11))
        }
        let deficit = CGFloat(min(1, 1 - confidence))
        return (
            NSColor(
                calibratedHue: 0.12 - 0.12 * deficit, saturation: 0.5, brightness: 0.92, alpha: 1),
            0.09 + 0.17 * deficit
        )
    }
}
