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
    /// Whether the key that is next shows the number of the finger that
    /// presses it, in place of its legend. Read from the preference at birth
    /// and set again whenever it changes, which is how every other live
    /// setting reaches the view it draws.
    var showsFingerTips = AppPreferences.showFingerTips.value {
        didSet { if showsFingerTips != oldValue { needsDisplay = true } }
    }
    /// The next character, exactly as the passage has it. Matching a cap to it
    /// is case-blind; whether ⇧ is part of the keystroke is exactly the case
    /// question, so the case has to survive the journey here.
    private var expectedAsWritten: String?
    /// Letters the curriculum knows about but has not unlocked yet. Empty in
    /// benchmark mode, where there is no lesson and so nothing is locked.
    private var lockedLetters: Set<String> = []
    /// The one letter this lesson drills hardest.
    private var focusLetter: String?
    private var layoutObserver: NSObjectProtocol?
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

    /// Every legend comes from the *current* keyboard layout, read at draw
    /// time — so switching to Dvorak in System Settings has to force a redraw.
    /// Without this the old legends stayed on screen until something else
    /// happened to invalidate the view, which for an idle window is never.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver) }
        layoutObserver = nil
        guard window != nil else { return }
        layoutObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    func update(
        stats: OrderedMap<PerKeyStat>, plan: LessonPlan?, expected: String?, targetWpm: Double
    ) {
        self.stats = stats
        targetMs = Target(targetSpeed: targetWpm).timePerChar
        show(plan: plan, expected: expected)
    }

    /// The lesson and the next key, with no heat — for a screen that has no
    /// statistics to show, and so no target speed to measure them against.
    func showWithoutHeat(plan: LessonPlan?, expected: String?) {
        stats = OrderedMap()
        show(plan: plan, expected: expected)
    }

    private func show(plan: LessonPlan?, expected: String?) {
        // Kept as the two things this view draws rather than as the whole
        // plan: the locked set is a per-key lookup on every redraw, and a set
        // answers it in constant time where `keys` would be a linear scan.
        lockedLetters = Set(plan?.keys.lazy.filter { !$0.included }.map(\.letter) ?? [])
        focusLetter = plan?.focus
        expectedAsWritten = expected
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

    /// The size of the case at a given key pitch.
    private func caseSize(unit: CGFloat) -> NSSize {
        let rows = CGFloat(KeyboardGeometry.rows(for: SystemKeyboard.shape).count)
        let padding = casePadding(unit)
        let gap = keyGap(unit)
        return NSSize(
            width: unit * CGFloat(KeyboardGeometry.unitsPerRow) + 2 * padding - gap,
            height: unit * rows + 2 * padding - gap)
    }

    /// The largest cap size whose case fits both dimensions.
    ///
    /// Found by stepping down from an upper bound rather than by dividing.
    /// Padding and gap are each rounded to whole points, so there is no exact
    /// closed form — and the estimated divisor this used before was a hair too
    /// large, which silently cost a whole point of key size: at the default
    /// window the keyboard drew at 53 points inside a drawer sized for 54, and
    /// came out 14 points narrower than the space it had.
    ///
    /// Height matters as much as width because the drawer sizes the keyboard;
    /// `unit * unitsPerRow` is a safe upper bound since the padding always
    /// exceeds the one trailing gap.
    private func unitWidth(for width: CGFloat, height: CGFloat = .greatestFiniteMagnitude)
        -> CGFloat
    {
        var unit = min(Self.maxUnit, floor(width / CGFloat(KeyboardGeometry.unitsPerRow)))
        while unit > Self.minUnit {
            let size = caseSize(unit: unit)
            if size.width <= width && size.height + 2 <= height { break }
            unit -= 1
        }
        return max(Self.minUnit, unit)
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

    /// `.infinity` means "no height constraint", and it has to be infinity
    /// rather than `.greatestFiniteMagnitude`: the latter *is* finite, so the
    /// `isFinite` test below accepted it and centred the case at half of
    /// 1.8e308. Only the height-taking callers hid it.
    func layout(forWidth width: CGFloat, height: CGFloat = .infinity) -> Layout {
        let rows = KeyboardGeometry.rows(for: SystemKeyboard.shape)
        let unit = unitWidth(for: width, height: height)
        let padding = casePadding(unit)
        let gap = keyGap(unit)
        // The gap belongs *between* caps, so the case gives back the one
        // trailing gap on each axis. Without this the right and bottom margins
        // are a full gap wider than the left and top — small, consistent, and
        // exactly the kind of asymmetry the eye reads as "not quite right"
        // without being able to name it. `caseSize` is where that rule lives;
        // repeating it here meant `unitWidth` could size against one formula
        // while the case drew with another.
        let shell = caseSize(unit: unit)
        let caseWidth = shell.width
        let caseHeight = shell.height
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

    /// The tallest the keyboard has been drawn. Read by `--selftest`, which
    /// never shows a window and so requires it to be no taller than a shut
    /// drawer: a keyboard drawn open where nothing could see it cost 9.5 MB of
    /// bitmap, and leaves no other trace a check could find.
    ///
    /// A height, not a count of draws. AppKit draws the drawer once at its
    /// shut size, 100 by 1 points, whether or not anything opens it — a few
    /// hundred bytes, and a count cannot tell that from the open keyboard.
    private(set) var tallestDraw: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        tallestDraw = max(tallestDraw, bounds.height)
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

        // Asked of the system once per redraw, not once per key per question.
        // `UCKeyTranslate` is a layout lookup and a translation, and the board
        // was doing three per cap to draw it and two more per cap to find the
        // next one — on every keystroke.
        let printed = printedLegends(layout)
        // Worked out once for the whole board: which keys the next character
        // needs is decided by a *different* cap — the one that prints it — and
        // ⇧ and ⌥ are drawn before some of those and after others.
        let next = nextKeystroke(layout, printed: printed)
        for placed in layout.keys {
            draw(
                placed.key, in: placed.rect, unit: layout.unit, corner: placed.corner,
                printed: printed[placed.key.code], next: next)
        }
    }

    /// What a cap prints: unmodified, and with ⇧.
    struct Printed {
        let plain: String?
        let shifted: String?
        /// Both, for the heat map and for matching a key to a character.
        var both: [String] { [plain, shifted].compactMap { $0 } }
    }

    /// Every typing cap's legends, for one redraw.
    ///
    /// Internal rather than private so the self-test can put the same question
    /// to the same code the drawing uses. There is no other way to see which
    /// keys the aid would mark without rendering the board and reading it back.
    func printedLegends(_ layout: Layout) -> [UInt16: Printed] {
        var table: [UInt16: Printed] = [:]
        for placed in layout.keys where placed.key.types {
            let code = placed.key.code
            guard table[code] == nil else { continue }
            table[code] = Printed(
                plain: SystemKeyboard.character(forKeyCode: code),
                shifted: SystemKeyboard.character(forKeyCode: code, shift: true))
        }
        return table
    }

    /// The cap the next character is typed on, and the modifiers held with it.
    struct Keystroke {
        let key: UInt16
        /// ⇧ and ⌥, empty unless Finger tips is on: with the aid off the board
        /// marks the letter alone, as it always has.
        let modifiers: Set<UInt16>
    }

    /// Which keys the next character needs.
    ///
    /// The plain and shifted legends answer it on a US layout, and they are
    /// already in hand. When they do not — `@`, `[`, `{`, `\\` and `|` are ⌥
    /// chords on the German and Spanish keyboards, and a code drill is made of
    /// those — the ⌥ combinations are asked for as well. That second pass is
    /// worth its cost only because it runs when the first found nothing at all,
    /// which on a US keyboard is never.
    ///
    /// A modifier is taken with the hand that is *not* typing the letter, so
    /// the typing hand stays where it is. That is what the chart's hands are
    /// for.
    func nextKeystroke(_ layout: Layout, printed: [UInt16: Printed]) -> Keystroke? {
        guard let wanted = expectedAsWritten, !wanted.isEmpty else { return nil }

        func modifiers(for code: UInt16, shift: Bool, option: Bool) -> Set<UInt16> {
            guard showsFingerTips, let hand = FingerTips.hand(of: code) else { return [] }
            let other: FingerTips.Hand = hand == .left ? .right : .left
            var held: Set<UInt16> = []
            if shift { held.insert(FingerTips.shift(for: other)) }
            if option { held.insert(FingerTips.option(for: other)) }
            return held
        }

        let lowered = wanted.lowercased()
        for placed in layout.keys {
            guard let legends = printed[placed.key.code] else { continue }
            guard legends.both.contains(where: { $0.lowercased() == lowered }) else { continue }
            let code = placed.key.code
            let shift = legends.shifted == wanted && legends.plain != wanted
            return Keystroke(
                key: code, modifiers: modifiers(for: code, shift: shift, option: false))
        }

        for placed in layout.keys where placed.key.types {
            let code = placed.key.code
            for shift in [false, true] {
                guard SystemKeyboard.character(forKeyCode: code, shift: shift, option: true)
                    == wanted
                else { continue }
                return Keystroke(
                    key: code, modifiers: modifiers(for: code, shift: shift, option: true))
            }
        }
        return nil
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
        _ key: KeyboardGeometry.Key, in rect: NSRect, unit: CGFloat, corner: Corner?,
        printed: Printed?, next: Keystroke?
    ) {
        let isPressed = pressed == key.code && key.code != KeyboardGeometry.touchIDCode
        // A pressed cap sinks: the lip closes up and the whole cap moves down
        // by the point it loses. Same trick as the web's `translateY(1px)`,
        // and it reads as travel rather than as a highlight.
        let lip: CGFloat = isPressed ? 1 : 2
        let capRect = isPressed ? rect.offsetBy(dx: 0, dy: 1) : rect
        let radii = capRadii(corner, unit: unit)

        // The character this physical key types under the *current* layout.
        // Both of what this key can type. `!` lives on the `1` key and `A` on
        // `a`; matching only the unshifted output meant an expected `!` never
        // lit a key, and every capital letter's statistics were dropped on the
        // floor instead of counting towards the key that produces it.
        //
        // Read before the cap is drawn rather than after, because the lesson's
        // focus key is marked *by* its border rather than by a second ring
        // inside it, and the border is the first thing down.
        let character = printed?.plain
        let produced = printed?.both ?? []
        let isFocus = !isPressed && focusLetter != nil && character == focusLetter

        // The lip: the whole cap in the border colour, then the face inset by
        // one point on three sides and by the lip at the bottom.
        //
        // The lesson's focus key darkens this same edge instead of gaining a
        // ring of its own. A ring drawn inside the face left the cap wearing
        // two outlines, one of them the key's own — which reads as a rendering
        // mistake rather than as emphasis, whatever the inner one's weight.
        // Every cap already has exactly one border; this one is just told to
        // speak up.
        (isFocus ? Theme.correct.withAlphaComponent(0.38) : NSColor.separatorColor).setFill()
        capPath(capRect, radii).fill()
        let faceRect = NSRect(
            x: capRect.minX + 1, y: capRect.minY + 1,
            width: capRect.width - 2, height: capRect.height - 1 - lip)
        let face = capPath(
            faceRect, (radii.0 - 1, radii.1 - 1, radii.2 - 1, radii.3 - 1))
        NSColor.textBackgroundColor.setFill()
        face.fill()
        if let tint = heat(for: key, produced: produced), !isPressed {
            glaze(face, tint.color, strength: tint.strength)
        }
        // The ⇧ or ⌥ held for a character is as much "next" as the letter is,
        // so it takes the same tint and the same number.
        let isNext = next.map { $0.key == key.code || $0.modifiers.contains(key.code) } ?? false
        if isNext, !isPressed {
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
        // The other half of the lesson layer, marked subtractively: locked
        // letters lose contrast instead of unlocked ones gaining ink. An
        // alphabet grows one letter at a time, so for most of a run the
        // unlocked set is small and highlighting it would light up the board.
        //
        // Three states, not two — a cap can be unlocked, locked, or outside
        // the curriculum entirely, and only the middle one is dimmed. That is
        // why the test is membership in the locked set rather than
        // `key.types`: the first version dimmed every digit and every mark of
        // punctuation, which claimed the lesson excluded a comma no lesson has
        // ever offered.
        // The finger number instead of the legend, on the one key that is
        // next. Instead, rather than beside: a keyboard whose every cap wears
        // a second mark is a chart to study, and this is a keyboard to look at
        // while typing. It also settles where the mark goes — it goes where
        // the legend was, so nothing is covered and nothing moves.
        if showsFingerTips, isNext, let digit = FingerTips.digit(of: key.code) {
            drawFingerTip(digit, for: key, in: faceRect, unit: unit)
        } else {
            drawLabels(
                key, printed: printed, in: faceRect, unit: unit,
                locked: character.map(lockedLetters.contains) ?? false)
        }
        if key.isHoming {
            drawHomingRidge(key, legend: legend(of: key, printed: printed), in: faceRect, unit: unit)
        }
    }

    /// The bump on F and J: a short bar along the foot of the cap.
    ///
    /// On the real keyboard it is a ridge you feel rather than see — what
    /// shows is its shadow. Drawn here as the faintest mark on the board,
    /// because it is doing the same job a photograph of a keycap does: telling
    /// you which two keys the index fingers belong on, without asking to be
    /// read.
    ///
    /// As wide as the letter above it, and set a tenth of the cap's height
    /// above the bottom edge. Measured rather than taken as a fraction of the
    /// cap: a quarter of the cap's width — the moulding's own proportion —
    /// draws a bar noticeably wider than the `F` it belongs to, and the two
    /// being the same length is what makes it read as part of the key rather
    /// than as a rule under it. Measured from the legend, not from the finger
    /// number that may be standing in for it, because the ridge is a property
    /// of the keyboard and not of the aid.
    private func drawHomingRidge(
        _ key: KeyboardGeometry.Key, legend: String, in rect: NSRect, unit: CGFloat
    ) {
        let font = NSFont.systemFont(ofSize: max(6, unit * Self.labelScale(for: key)))
        let width = max(4, (legend as NSString).size(withAttributes: [.font: font]).width)
        let height = max(1, unit * 0.035)
        let bar = NSRect(
            x: rect.midX - width / 2, y: rect.maxY - unit * 0.12 - height,
            width: width, height: height)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2).fill()
    }

    /// What a cap has printed on it: its own label, or the character it types.
    ///
    /// One definition, because three things ask — the legend itself, the ridge
    /// that is drawn as wide as it, and the badge that steps aside from it.
    private func legend(of key: KeyboardGeometry.Key, printed: Printed?) -> String {
        key.label ?? printed?.plain?.uppercased() ?? ""
    }

    /// The finger number, in the space the legend has stepped out of.
    ///
    /// Set at exactly the size of the letter it replaces, and in the same
    /// face: the cap prints one thing at a time, and a number that arrived
    /// larger would make the key jump when the aid was switched on.
    ///
    /// On glass rather than bare. A digit set like a legend *is* a legend to
    /// read — on the number row a bare `2` on the `2` key says nothing about
    /// which of the two it is. The disc is what marks it as an instruction
    /// rather than a character, and it is drawn faintly because it only has to
    /// do that much.
    ///
    /// Semantic colours, so it follows the appearance with no test for which
    /// one is current, and the greys invert with the theme exactly as the cap
    /// under them does. `quaternaryLabelColor` is a tenth of the label colour
    /// and draws the edge; the glass is half of that again. The edge was a
    /// quarter to begin with, which drew a ring heavier than some of the
    /// legends it sat between — an outline around a hint has to be the
    /// quietest line on the board, not a second border competing with the
    /// cap's own.
    ///
    /// Written as half of quaternary rather than as `quinaryLabelColor`, which
    /// is the same colour by another name: that name is renamed in a later SDK
    /// than this machine's, so it compiled here and failed on CI. An arithmetic
    /// relation between two colours cannot be renamed out from under the
    /// build.
    private func drawFingerTip(
        _ digit: Int, for key: KeyboardGeometry.Key, in rect: NSRect, unit: CGFloat
    ) {
        let font = NSFont.systemFont(ofSize: max(6, unit * Self.labelScale(for: key)))
        let size = min(font.pointSize * 1.9, rect.height - 2, rect.width - 2)
        guard size > 0 else { return }
        let box = NSRect(
            x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)

        NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(ovalIn: box).fill()
        let width = max(0.6, unit * 0.014)
        let ring = NSBezierPath(ovalIn: box.insetBy(dx: width / 2, dy: width / 2))
        NSColor.quaternaryLabelColor.setStroke()
        ring.lineWidth = width
        ring.stroke()

        let text = String(digit) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]
        let measured = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: box.midX - measured.width / 2, y: box.midY - measured.height / 2),
            withAttributes: attributes)
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

    /// One line of legend on a cap.
    ///
    /// A caption sits nearer the cap edge than a glyph does, which is both how
    /// Apple prints it and the three points that decide whether the word
    /// "control" fits a one-unit key at all.
    private struct Line {
        let text: String
        let font: NSFont
        let color: NSColor
        let inset: CGFloat
    }

    /// What a cap should say, before anything is measured or placed.
    ///
    /// Split out of `drawLabels`, which resolved the text, chose the colours,
    /// asked the system for the shifted glyph, measured, filtered and drew —
    /// six jobs in one function, and the reason its length was flagged.
    private func labelLines(
        _ key: KeyboardGeometry.Key, printed: Printed?, unit: CGFloat, locked: Bool
    ) -> (lines: [Line], shifted: String?, glyphInset: CGFloat) {
        let character = printed?.plain
        let label = legend(of: key, printed: printed)
        guard !label.isEmpty, label != " " else { return ([], nil, 0) }
        let stat = character.flatMap { stats[$0] }
        var color: NSColor =
            switch key.role {
            case .letter: stat == nil ? Theme.secondaryText : Theme.correct
            default: Theme.secondaryText
            }
        // Letters the lesson has not unlocked lose contrast. Marked on the
        // legend rather than on the cap: the cap face is already
        // `textBackgroundColor`, so glazing it with anything near that colour
        // is a no-op — the first version of this washed white over white and
        // changed nothing at all.
        if locked { color = color.withAlphaComponent(0.28) }

        // The shifted glyph, as the system reported it for this redraw — so a
        // German keyboard prints its own. Suppressed when it is merely the
        // capital of the same letter, which is not a second glyph on any real
        // cap.
        var shiftedText: String?
        if key.role == .letter, let character, let shifted = printed?.shifted,
            shifted.lowercased() != character.lowercased()
        {
            shiftedText = shifted
        }

        let labelFont = NSFont.systemFont(ofSize: max(6, unit * Self.labelScale(for: key)))
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
        return (lines, shiftedText, glyphInset)
    }

    private func drawLabels(
        _ key: KeyboardGeometry.Key, printed: Printed?, in rect: NSRect, unit: CGFloat,
        locked: Bool = false
    ) {
        let (lines, shiftedText, glyphInset) = labelLines(
            key, printed: printed, unit: unit, locked: locked)
        guard !lines.isEmpty else { return }

        // Measured once, then carried. Every line was measured here to decide
        // whether it fitted and measured again below to place it — the same
        // text-layout call twice per line, on every redraw.
        let spacing = unit * 0.04
        var measured = lines.map { line in
            (line: line, size: (line.text as NSString).size(withAttributes: [.font: line.font]))
        }

        // Drop any line that does not fit its cap rather than clipping it.
        // Font sizes have a legibility floor, so below a certain cap size the
        // word "command" is wider than the key it names — and half a word
        // spilling onto its neighbour says less than no word at all. Measured
        // per line, so it adapts to the label, the font and the drawer height
        // instead of guessing a cap size to switch at. The primary label is
        // never dropped: a key with no label at all is worse than a tight one.
        let primary = measured.count == 1 ? 0 : (shiftedText == nil ? 0 : 1)
        measured = measured.enumerated().filter { index, entry in
            index == primary || entry.size.width <= rect.width - 2 * entry.line.inset
        }.map(\.element)

        // Height as well as width. A cap at the smallest supported size is 14
        // points of face and the `!` over `1` stack is 15.8 — so both legends
        // were drawn, over the edge of the key and onto its neighbour. Trimmed
        // from the ends inward, keeping the primary label, because that is the
        // one the key is for.
        func stackHeight() -> CGFloat {
            measured.reduce(0) { $0 + $1.size.height }
                + spacing * CGFloat(max(0, measured.count - 1))
        }
        // One inset, not two. The stack is placed against the *bottom* inset
        // on a bottom-aligned key and centred otherwise, so reserving the
        // inset at both ends was a margin the layout never uses — and it
        // trimmed the shifted glyph off every digit and punctuation cap at
        // ordinary sizes, which is a regression, not a fix.
        let available = rect.height - (key.vertical == .bottom ? glyphInset : 0)
        while measured.count > 1, stackHeight() > available {
            let dropLast = measured.count - 1 != primary
            measured.remove(at: dropLast ? measured.count - 1 : 0)
        }

        let total = stackHeight()
        // The view is flipped, so maxY is the visual bottom of the cap.
        var lineY =
            key.vertical == .bottom
            ? rect.maxY - glyphInset - total
            : rect.midY - total / 2
        for (line, size) in measured {
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

    /// The one key this lesson is drilling hardest.
    ///
    /// A ring, not a wash. Every other state on this keyboard is a fill — heat,
    /// the expected key, the pressed key — so a fourth fill would have to
    /// compete with three others for the same pixels and would be read as a
    /// shade of them. An outline occupies the edge instead, which nothing else
    /// uses, and survives whatever colour the cap already carries.
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
        for key: KeyboardGeometry.Key, produced: [String]
    ) -> (color: NSColor, strength: CGFloat)? {
        // Every character this key can type, combined rather than just the
        // unshifted one. Not a `PerKeyStat`: its memberwise initialiser is
        // internal to the engine, and the three numbers are all that is
        // needed here.
        let found = produced.compactMap { stats[$0] }
        guard key.types, !found.isEmpty else { return nil }
        let hits = found.reduce(0) { $0 + $1.hits }
        guard hits >= 5 else { return nil }
        // Weighted by `hits`, because that is `errorRate`'s own denominator —
        // the engine computes it as `misses / hits`. Weighting by
        // `hits + misses` mixed two different scales and skewed the colour of
        // any key whose two characters are typed at different rates.
        let errorRate = hits > 0
            ? found.reduce(0.0) { $0 + $1.errorRate * Double($1.hits) } / Double(hits)
            : 0
        // Hit-weighted, so a key typed mostly unshifted is coloured mostly by
        // that. Untimed entries contribute no weight rather than a zero.
        let timed = found.filter { $0.avgMs > 0 }
        let timedHits = timed.reduce(0) { $0 + $1.hits }
        let avgMs = timedHits > 0
            ? timed.reduce(0.0) { $0 + $1.avgMs * Double($1.hits) } / Double(timedHits)
            : 0

        if errorRate > 0.05 {
            return (Theme.incorrect, min(0.30, 0.08 + CGFloat(errorRate)))
        }
        // No timing, no speed colour. `avgMs` is zero when every attempt at a
        // key was excluded from timing — the first keystroke of a run, or one
        // after a correction — and `max(avgMs, 1)` turned that into a claimed
        // one millisecond per press, the strongest "fast" tint in the scale,
        // for a key there is no speed evidence about at all.
        guard avgMs > 0 else { return nil }
        // Confidence, the same ratio the planner uses to decide mastery: at or
        // above 1 the key is at target and stays cool; below it warms.
        let confidence = targetMs / avgMs
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
