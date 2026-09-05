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
        let unit = unitWidth(for: width)
        return unit * CGFloat(KeyboardGeometry.rows(for: SystemKeyboard.shape).count) + 4
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - bounds.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    private func unitWidth(for width: CGFloat) -> CGFloat {
        let rows = KeyboardGeometry.rows(for: SystemKeyboard.shape)
        let widest = rows.map { row in row.reduce(0) { $0 + $1.width } }.max() ?? 15
        return floor(width / CGFloat(widest))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rows = KeyboardGeometry.rows(for: SystemKeyboard.shape)
        let unit = unitWidth(for: bounds.width)
        let gap: CGFloat = 3
        var y: CGFloat = 0

        for row in rows {
            var x: CGFloat = 0
            for key in row {
                let width = unit * CGFloat(key.width)
                let rect = NSRect(x: x, y: y, width: width - gap, height: unit - gap)
                draw(key: key, in: rect)
                x += width
            }
            y += unit
        }
    }

    private func draw(key: KeyboardGeometry.Key, in rect: NSRect) {
        // The character this physical key types under the *current* layout.
        let character = SystemKeyboard.character(forKeyCode: key.code)
        let label = key.label ?? character?.uppercased() ?? ""
        let stat = character.flatMap { stats[$0] }

        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        fill(for: key, stat: stat, character: character).setFill()
        path.fill()

        if pressed == key.code {
            Theme.caret.setStroke()
            path.lineWidth = 2
            path.stroke()
        }

        guard !label.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(
                ofSize: min(13, rect.height * 0.42), weight: .regular),
            .foregroundColor: stat == nil ? Theme.secondaryText : Theme.correct,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes)
    }

    /// Heat by speed, with error rate overriding it.
    ///
    /// Speed and accuracy are different problems and a single colour ramp
    /// cannot say both. A key you hit slowly is warm; a key you keep getting
    /// wrong is red regardless of how fast you get it wrong.
    private func fill(
        for key: KeyboardGeometry.Key, stat: PerKeyStat?, character: String?
    ) -> NSColor {
        if let expected, let character, character == expected {
            return Theme.caret.withAlphaComponent(0.30)
        }
        guard let stat, stat.hits >= 5 else {
            return NSColor.quaternaryLabelColor.withAlphaComponent(0.25)
        }
        if stat.errorRate > 0.05 {
            return Theme.incorrect.withAlphaComponent(min(0.55, 0.15 + stat.errorRate * 2))
        }
        // Confidence, the same ratio the planner uses to decide mastery: at or
        // above 1 the key is at target and stays cool; below it warms.
        let confidence = targetMs / max(stat.avgMs, 1)
        if confidence >= 1 {
            return NSColor.systemTeal.withAlphaComponent(min(0.34, 0.12 + (confidence - 1) * 0.2))
        }
        let deficit = min(1, 1 - confidence)
        return NSColor(
            calibratedHue: 0.12 - 0.12 * deficit, saturation: 0.62, brightness: 0.95,
            alpha: 0.18 + 0.30 * deficit)
    }
}
