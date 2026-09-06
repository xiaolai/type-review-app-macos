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

    /// One key's width, in points, at the largest size worth drawing.
    ///
    /// Without a ceiling the keyboard grows with the window and a 900-point
    /// window renders 60-point keycaps — a diagram of a keyboard rather than a
    /// picture of one. 33 points is the web's `--u: 22px` at its 1.5× cap,
    /// which is where its proportions were tuned.
    private static let maxUnit: CGFloat = 33
    private static let minUnit: CGFloat = 12

    override var isFlipped: Bool { true }

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
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        ceil(layout(forWidth: width).caseRect.maxY + 1)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - bounds.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    private func unitWidth(for width: CGFloat) -> CGFloat {
        let units = CGFloat(KeyboardGeometry.unitsPerRow)
        // Solve for the unit that makes case + padding exactly fill the width,
        // then clamp. Padding scales with the unit, so it is part of the
        // equation rather than subtracted first.
        let raw = width / (units + 0.7)
        return floor(min(Self.maxUnit, max(Self.minUnit, raw)))
    }

    private func casePadding(_ unit: CGFloat) -> CGFloat { max(4, (unit * 0.2).rounded()) }

    private func keyGap(_ unit: CGFloat) -> CGFloat { max(3, (unit * 0.1).rounded()) }

    /// Where everything goes, for a given available width.
    ///
    /// Shared with the selftest rather than recomputed there: a check that
    /// re-derives the layout from the same formula proves only that the
    /// formula equals itself. This way the check measures the rectangles the
    /// view actually draws.
    struct Layout {
        let caseRect: NSRect
        let unit: CGFloat
        let keys: [(key: KeyboardGeometry.Key, rect: NSRect)]
    }

    func layout(forWidth width: CGFloat) -> Layout {
        let rows = KeyboardGeometry.rows(for: SystemKeyboard.shape)
        let unit = unitWidth(for: width)
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
        let caseRect = NSRect(
            x: ((width - caseWidth) / 2).rounded(), y: 1, width: caseWidth, height: caseHeight)

        var placed: [(KeyboardGeometry.Key, NSRect)] = []
        var y = caseRect.minY + padding
        for row in rows {
            var x = caseRect.minX + padding
            for key in row where key.width > 0 {
                let width = unit * CGFloat(key.width)
                placed.append(
                    (key.key, NSRect(x: x, y: y, width: width - gap, height: unit - gap)))
                x += width
            }
            y += unit
        }
        return Layout(caseRect: caseRect, unit: unit, keys: placed)
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = layout(forWidth: bounds.width)

        let radius = layout.unit * 0.35
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
            draw(placed.key, in: placed.rect, unit: layout.unit)
        }
    }

    private func draw(_ key: KeyboardGeometry.Key, in rect: NSRect, unit: CGFloat) {
        let isPressed = pressed == key.code && key.code != 0xFFFF
        // A pressed cap sinks: the lip closes up and the whole cap moves down
        // by the point it loses. Same trick as the web's `translateY(1px)`,
        // and it reads as travel rather than as a highlight.
        let lip: CGFloat = isPressed ? 1 : 2
        let capRect = isPressed ? rect.offsetBy(dx: 0, dy: 1) : rect
        let radius = max(3, unit * 0.15)

        // The lip: the whole cap in the border colour, then the face inset by
        // one point on three sides and by the lip at the bottom.
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: capRect, xRadius: radius, yRadius: radius).fill()
        let faceRect = NSRect(
            x: capRect.minX + 1, y: capRect.minY + 1,
            width: capRect.width - 2, height: capRect.height - 1 - lip)
        let face = NSBezierPath(
            roundedRect: faceRect, xRadius: radius - 1, yRadius: radius - 1)
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

        let labelFont = NSFont.monospacedSystemFont(
            ofSize: max(7, unit * (key.role == .letter ? 0.34 : 0.30)), weight: .regular)
        var lines: [(String, NSFont, NSColor)] = []
        if let shiftedText {
            lines.append((
                shiftedText,
                NSFont.monospacedSystemFont(ofSize: max(6, unit * 0.26), weight: .regular),
                Theme.secondaryText.withAlphaComponent(0.75)
            ))
        }
        lines.append((label, labelFont, color))
        if let sub = key.sub, unit >= 20 {
            // Apple prints the word under the glyph. It only fits at full
            // size — below that the ellipsis says less than nothing.
            lines.append((
                sub, NSFont.systemFont(ofSize: max(6, unit * 0.18)),
                Theme.secondaryText.withAlphaComponent(0.55)
            ))
        }

        let spacing = unit * 0.04
        let sizes = lines.map { line in
            (line.0 as NSString).size(withAttributes: [.font: line.1])
        }
        let total = sizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(lines.count - 1)
        var lineY = rect.midY - total / 2
        let inset = max(2, unit * 0.12)
        for (line, size) in zip(lines, sizes) {
            let lineX: CGFloat =
                switch key.align {
                case .start: rect.minX + inset
                case .end: rect.maxX - inset - size.width
                case .center: rect.midX - size.width / 2
                }
            (line.0 as NSString).draw(
                at: NSPoint(x: lineX, y: lineY),
                withAttributes: [.font: line.1, .foregroundColor: line.2])
            lineY += size.height + spacing
        }
    }

    /// The round button, as an outlined circle at two thirds of the cap. A
    /// drawn circle rather than a glyph: no font places one predictably.
    private func drawTouchID(in rect: NSRect, unit: CGFloat) {
        let diameter = min(rect.width, rect.height) * 0.666
        let circle = NSBezierPath(
            ovalIn: NSRect(
                x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                width: diameter, height: diameter))
        circle.lineWidth = max(1, unit * 0.06)
        Theme.secondaryText.withAlphaComponent(0.55).setStroke()
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
