import AppKit
import CoreText
import TypeReviewKit

/// The typing surface: CoreText glyphs, a caret, and the real text input path.
///
/// Two decisions here are the reason this is a custom view rather than an
/// `NSTextView`.
///
/// **Input goes through `NSTextInputClient`.** Reading `NSEvent.characters` in
/// `keyDown` is the tempting shortcut and it is the one silent data-corruption
/// bug in this app: during CJK composition every keystroke reports its
/// pre-composition character, so a profile would fill with letters the user
/// never typed. Going through the input context means marked text is drawn as
/// marked text and only committed characters reach the engine — which is also
/// the difference between "CJK users are protected" and "CJK users can use the
/// app", something the web version cannot offer.
///
/// **Layout is independent of typing status.** Colour is not a layout
/// attribute, so the framesetter is rebuilt only when the passage or the width
/// changes, never on a keystroke.
// `@preconcurrency` on the conformance: NSTextInputClient predates Swift
// concurrency and is not annotated, while every call to it arrives on the main
// thread from AppKit. Without this the compiler refuses the conformance.
final class TypingView: NSView, @preconcurrency NSTextInputClient {
    /// Committed text, one code unit at a time.
    var onCharacter: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onRestart: (() -> Void)?
    var onConfirm: (() -> Void)?
    /// The physical key being held, by virtual key code. Position, not
    /// character — which is what makes the highlight correct under Dvorak,
    /// where the key labelled S types "o".
    var onKeyPressed: ((UInt16?) -> Void)?
    /// The physical key that was just pressed, for the sound layer.
    ///
    /// Reported from `keyDown` rather than from `insertText`, and that is the
    /// point: the click has to land when the key goes down, not when the
    /// input context decides a character is finished. During CJK composition
    /// those are seconds apart, and a keyboard whose sound lags the key is
    /// worse than one with no sound at all.
    var onKeyStruck: ((UInt16) -> Void)?
    /// A commit is about to deliver one or more characters.
    ///
    /// Separate from `onCharacter`, which cannot express it: by the time the
    /// characters arrive they are indistinguishable from characters typed one
    /// at a time.
    var onCommitBegan: (() -> Void)?
    /// The other half of a keystroke. Separate from `onKeyStruck` rather than
    /// one callback with a flag, because the two have different owners: a
    /// press always sounds, a release only when the pack has one.
    var onKeyReleased: ((UInt16) -> Void)?

    private var expected: String = ""
    private var statuses: [CharStatus] = []
    private var cursor: Int = 0
    private var markedText: String = ""

    /// Read from `AppPreferences` and pushed in, rather than read here: this
    /// view is drawn on every keystroke and should not be querying
    /// `UserDefaults` in a draw call.
    var caretStyle: AppPreferences.CaretStyle = .vertical {
        didSet { if caretStyle != oldValue { needsDisplay = true } }
    }
    var showsWhitespace = false {
        didSet { if showsWhitespace != oldValue { needsDisplay = true } }
    }

    /// Bar and underline carets. Two points reads as a caret at this size; one
    /// disappears against the text, three reads as a rule.
    private static let caretThickness: CGFloat = 2
    /// Air between the descender line and the underline caret. Without it the
    /// tail of a `y` or a `g` lands exactly on the bar, which is the same
    /// collision that moving it off the baseline was meant to fix.
    private static let caretGap: CGFloat = 1

    private var framesetter: CTFramesetter?
    private var textFrame: CTFrame?
    /// The bounds the current frame was laid out against.
    private var layoutSize: CGSize = .zero
    /// The passage as UTF-16, rebuilt only when the passage changes.
    private var utf16Cache: [UInt16]?
    private var passageUTF16: [UInt16] {
        if let utf16Cache { return utf16Cache }
        let units = Array(expected.utf16)
        utf16Cache = units
        return units
    }
    /// The selection inside the composition, in composition coordinates.
    private var markedSelection = NSRange(location: 0, length: 0)
    /// Height of the whole passage at the current width, which can exceed the
    /// view's.
    private var contentHeight: CGFloat = 0
    /// How far the viewport has scrolled down the passage. Sticky: it moves
    /// only when the caret would otherwise be off screen, so the text does not
    /// shift under the reader on every keystroke.
    private var scrollOffset: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    /// Replaces the passage. Rebuilds layout — the only time that happens.
    func setPassage(_ text: String, statuses: [CharStatus], cursor: Int) {
        let passageChanged = text != expected
        expected = text
        if passageChanged { invalidateLayout(); utf16Cache = nil }
        // A new passage starts at its top, whatever the last one had scrolled to.
        scrollOffset = 0
        // A composition belongs to the run that started it. Left standing
        // across a reset, a half-typed CJK syllable would commit into the new
        // passage — characters the user typed against text that is no longer
        // on screen, scored against text they never saw. Cleared even when the
        // text is identical, because "start this passage again" is still a new
        // run.
        discardComposition()
        update(statuses: statuses, cursor: cursor)
    }

    /// Updates only what a keystroke changes. No relayout.
    func update(statuses: [CharStatus], cursor: Int) {
        self.statuses = statuses
        self.cursor = cursor
        restartBlink()
        needsDisplay = true
    }

    /// Ends any composition in progress without committing it, and tells the
    /// input context so its candidate window goes away with it.
    private func discardComposition() {
        guard !markedText.isEmpty else { return }
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        inputContext?.discardMarkedText()
    }

    // MARK: - Blinking

    /// The blink phase. The caret is drawn only on the lit half.
    private var caretIsVisible = true
    private var blinkTimer: Timer?
    /// Key-window observers for the window this view is currently in.
    private var windowObservers: [NSObjectProtocol] = []
    /// Key codes currently held down, so releasing one does not unlight another.
    private var held: Set<UInt16> = []

    /// How long the caret stays lit and dark, from the system's own settings.
    ///
    /// `NSTextInsertionPointBlinkPeriod` is a real preference people set —
    /// raised to slow a distracting cursor, and set to zero to stop it moving
    /// at all, which is an accessibility setting rather than a curiosity. A
    /// hard-coded half second would quietly ignore all of it, so these read
    /// what the system reads, in the order AppKit reads it: the combined key
    /// first, then either half on top.
    ///
    /// Zero anywhere means no blink. That is not a degenerate case to guard
    /// against — it is the setting doing exactly what it says.
    private static var blinkPeriods: (on: TimeInterval, off: TimeInterval)? {
        let defaults = UserDefaults.standard
        func milliseconds(_ key: String) -> Double? {
            defaults.object(forKey: key) != nil ? defaults.double(forKey: key) : nil
        }
        let both = milliseconds("NSTextInsertionPointBlinkPeriod")
        let on = milliseconds("NSTextInsertionPointBlinkPeriodOn") ?? both ?? 500
        let off = milliseconds("NSTextInsertionPointBlinkPeriodOff") ?? both ?? 500
        guard on > 0, off > 0 else { return nil }
        return (on / 1000, off / 1000)
    }

    /// Whether the caret should be blinking at all.
    ///
    /// Only where keystrokes would actually land. A caret blinking in a window
    /// that is not accepting input is an invitation to type into nothing, and
    /// it is the one thing every Mac text field agrees on.
    private var caretShouldBlink: Bool {
        guard let window, !isHidden, Self.blinkPeriods != nil else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    /// Puts the caret back on and starts the cycle again.
    ///
    /// Called from every cursor move, and that is the point rather than an
    /// optimisation: without it a keystroke landing during the dark half
    /// would leave the place you just reached unmarked for up to half a
    /// second, which is precisely when you are looking for it.
    private func restartBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        if caretIsVisible == false { needsDisplay = true }
        caretIsVisible = true
        guard caretShouldBlink else { return }
        scheduleBlinkPhase()
    }

    /// One phase at a time rather than a repeating timer, because the lit and
    /// dark halves can be different lengths — a single interval would have to
    /// pick one and be wrong about the other.
    private func scheduleBlinkPhase() {
        guard let periods = Self.blinkPeriods else { return }
        let timer = Timer(
            timeInterval: caretIsVisible ? periods.on : periods.off, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Re-checked rather than assumed: the window can stop being
                // key without this view being told, and a caret still winking
                // in a background window is the thing this guards against.
                guard self.caretShouldBlink else { return self.restartBlink() }
                self.caretIsVisible.toggle()
                self.needsDisplay = true
                self.scheduleBlinkPhase()
            }
        }
        // `.common`, not the default mode. A timer in the default mode stops
        // while a menu is open or a window is being resized, and a caret that
        // freezes mid-blink for as long as a menu is down looks like the app
        // has hung.
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    override func becomeFirstResponder() -> Bool {
        defer { restartBlink() }
        return super.becomeFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Key-window changes are not sent to a view, and `caretShouldBlink`
        // depends on one. Without these the caret stopped blinking the first
        // time the window lost focus and stayed frozen after it came back,
        // until some unrelated update happened to restart it.
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        if let window {
            let centre = NotificationCenter.default
            let restart: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.restartBlink() }
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(
                    centre.addObserver(forName: name, object: window, queue: .main, using: restart))
            }
        }
        restartBlink()
    }

    override func viewDidHide() {
        super.viewDidHide()
        restartBlink()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        restartBlink()
    }

    /// Drops the laid-out frame. The framesetter survives a resize — it
    /// depends on the text, not on the box — so only the frame is rebuilt.
    private func invalidateFrame() {
        textFrame = nil
    }

    private func invalidateLayout() {
        framesetter = nil
        textFrame = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Height counts as much as width. A `CTFrame` is built against a path,
        // and the drawing transform flips against `bounds.height` — so a
        // height-only resize left the text laid out for the old box and drawn
        // against the new one, shifting the whole passage and keeping the old
        // number of visible lines.
        if abs(newSize.width - layoutSize.width) > 0.5
            || abs(newSize.height - layoutSize.height) > 0.5
        {
            invalidateFrame()
        }
    }

    // MARK: - Layout

    /// The attributed string carries font only — never colour. Colour is
    /// applied per glyph at draw time, so line breaking cannot depend on how
    /// much of the passage has been typed.
    private func makeFramesetter() -> CTFramesetter {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = PracticeWindowMetrics.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: expected,
            attributes: [.font: Theme.typingFont, .paragraphStyle: paragraph])
        return CTFramesetterCreateWithAttributedString(attributed)
    }

    private func ensureLayout() {
        guard textFrame == nil else { return }
        guard !expected.isEmpty else { return }
        let setter = framesetter ?? makeFramesetter()
        framesetter = setter
        layoutSize = bounds.size
        // Laid out to the height the passage actually needs, then drawn
        // through a viewport that follows the caret. Fitting the frame to
        // `bounds` meant a passage longer than the window silently lost its
        // tail: typing carried on past the last visible line, into text
        // nobody could see and nobody could check.
        var fitRange = CFRange()
        let needed = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: bounds.width, height: .greatestFiniteMagnitude), &fitRange)
        contentHeight = max(bounds.height, ceil(needed.height) + 8)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: bounds.width, height: contentHeight),
            transform: nil)
        textFrame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    }


    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        // `bounds`, not `dirtyRect`. AppKit is free to hand a view a dirty
        // rect larger than its own bounds — it passes the union of what needs
        // redrawing — and NSView does not clip drawing to bounds by default.
        // Filling the dirty rect therefore painted the background over
        // whatever sat above this view, which is why the header of live
        // numbers was invisible from the first day this view existed: it was
        // there, laid out correctly, and covered.
        bounds.fill()
        ensureLayout()
        guard let textFrame, let context = NSGraphicsContext.current?.cgContext else { return }

        // CoreText draws in a flipped-from-AppKit coordinate space; the view is
        // flipped for layout convenience, so undo that for the text.
        let lines = CTFrameGetLines(textFrame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(textFrame, CFRange(location: 0, length: 0), &origins)

        context.saveGState()
        context.textMatrix = .identity
        // `contentHeight`, not `bounds.height`: the frame is as tall as the
        // passage needs, and the two are the same only when it fits. The
        // offset is what scrolls the viewport down to the caret.
        context.translateBy(x: 0, y: contentHeight - viewportOffset(lines: lines, origins: origins))
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(
            x: 0, y: contentHeight - bounds.height - scrollOffset,
            width: bounds.width, height: bounds.height))

        for (index, line) in lines.enumerated() {
            let origin = origins[index]
            // A block caret is a highlight, so it belongs under the glyph it
            // marks. A bar or an underline sits beside or below one and can be
            // drawn over the top.
            if caretStyle == .block {
                drawCaretIfNeeded(line: line, at: origin, in: context)
            }
            drawColoured(line: line, at: origin, in: context)
            if caretStyle != .block {
                drawCaretIfNeeded(line: line, at: origin, in: context)
            }
            if showsWhitespace {
                drawWhitespaceMarks(
                    line: line, at: origin, in: context,
                    isLast: index == lines.count - 1)
            }
        }
        context.restoreGState()
        drawComposition(in: context)
    }

    /// The text an input method is still composing, drawn at the caret.
    ///
    /// It was stored and never shown: the comment promised an inline preview
    /// and there was none, so a CJK user typed a syllable into a surface that
    /// showed nothing until it committed. Underlined and in the pending
    /// colour, which is the platform's way of saying "not accepted yet".
    private func drawComposition(in context: CGContext) {
        guard !markedText.isEmpty else { return }
        let attributed = NSAttributedString(
            string: markedText,
            attributes: [
                .font: Theme.typingFont,
                .foregroundColor: Theme.correct,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        let origin = caretOrigin()
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: origin.x, y: bounds.height - origin.y - ascent)
        CTLineDraw(line, context)
        context.restoreGState()
        // `CTLineDraw` leaves the text matrix altered and `restoreGState` does
        // not cover it — the same trap the whitespace marks hit.
        context.textMatrix = .identity
    }

    /// How far down the passage the viewport sits, so the caret is on screen.
    ///
    /// Sticky rather than centring: it moves only when the caret's line would
    /// otherwise fall outside the view, which keeps the text still while you
    /// type across a line and steps it exactly one line when you leave one.
    private func viewportOffset(lines: [CTLine], origins: [CGPoint]) -> CGFloat {
        let overflow = contentHeight - bounds.height
        guard overflow > 0, let index = cursorLineIndex(lines) else {
            scrollOffset = 0
            return 0
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(lines[index], &ascent, &descent, nil)
        // Distances from the top of the passage, which is the direction the
        // offset is measured in.
        let top = contentHeight - (origins[index].y + ascent)
        let bottom = contentHeight - (origins[index].y - descent)
        var offset = scrollOffset
        if top < offset { offset = top }
        if bottom > offset + bounds.height { offset = bottom - bounds.height }
        // Snapped to a line boundary. An arbitrary offset leaves the line
        // above the viewport sliced through the middle, so its descenders sit
        // along the top edge as a row of red fragments — which reads as a
        // drawing bug rather than as a passage that continues upward.
        scrollOffset = min(max(0, snappedToLineTop(offset, lines: lines, origins: origins)), overflow)
        return scrollOffset
    }

    /// The top of the first line at or below `offset`, so a whole line is
    /// always the topmost thing on screen.
    private func snappedToLineTop(
        _ offset: CGFloat, lines: [CTLine], origins: [CGPoint]
    ) -> CGFloat {
        guard offset > 0 else { return 0 }
        var best = offset
        for (index, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, nil, nil)
            let top = contentHeight - (origins[index].y + ascent)
            // The first boundary at or after the requested offset. Lines are
            // in order, so the first match is the nearest one.
            if top >= offset - 0.5 {
                best = top
                break
            }
        }
        return best
    }

    /// Which laid-out line the caret sits on. The same test `drawCaretIfNeeded`
    /// makes, so the two cannot disagree about where the caret is.
    private func cursorLineIndex(_ lines: [CTLine]) -> Int? {
        for (index, line) in lines.enumerated() {
            let range = CTLineGetStringRange(line)
            let end = range.location + range.length
            let isLast = index == lines.count - 1
            if cursor >= range.location, cursor < end || (isLast && cursor == end) {
                return index
            }
        }
        return nil
    }

    /// Draws one line, recolouring each glyph run by typing status.
    ///
    /// Colouring at draw time rather than in the attributed string is what
    /// keeps the layout stable: the same `CTFrame` serves every keystroke.
    private func drawColoured(line: CTLine, at origin: CGPoint, in context: CGContext) {
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            guard let shaped = ShapedRun(run) else { continue }
            drawBatched(shaped, at: origin, in: context)
        }
    }

    /// One glyph run, unpacked from CoreText into plain arrays.
    ///
    /// Its own type because the four parallel `CTRunGet…` calls are a single
    /// step — "read this run" — and reading them inline left the batching
    /// logic below buried under a dozen lines of out-parameters.
    private struct ShapedRun {
        let glyphs: [CGGlyph]
        let positions: [CGPoint]
        let indices: [CFIndex]
        let font: NSFont

        @MainActor init?(_ run: CTRun) {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { return nil }
            let all = CFRange(location: 0, length: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, all, &indices)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, all, &glyphs)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetPositions(run, all, &positions)
            let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
            self.glyphs = glyphs
            self.positions = positions
            self.indices = indices
            self.font = (attributes[.font] as? NSFont) ?? Theme.typingFont
        }
    }

    /// Draws a run in as few calls as its colours allow: one per colour change
    /// rather than one per glyph, so a stretch of untyped text is a single call.
    private func drawBatched(_ run: ShapedRun, at origin: CGPoint, in context: CGContext) {
        var index = 0
        while index < run.glyphs.count {
            let colour = colour(forCharacterAt: run.indices[index])
            var end = index + 1
            while end < run.glyphs.count, colour == self.colour(forCharacterAt: run.indices[end]) {
                end += 1
            }
            context.setFillColor(colour.cgColor)
            let slice = index..<end
            let positions = run.positions[slice].map {
                CGPoint(x: $0.x + origin.x, y: $0.y + origin.y)
            }
            CTFontDrawGlyphs(run.font, Array(run.glyphs[slice]), positions, slice.count, context)
            index = end
        }
    }

    private func colour(forCharacterAt index: Int) -> NSColor {
        guard index >= 0, index < statuses.count else { return Theme.pending }
        switch statuses[index] {
        case .correct: return Theme.correct
        case .incorrect: return Theme.incorrect
        case .untyped: return Theme.pending
        }
    }

    /// A caret one line tall, placed by asking the line for the cursor's
    /// offset. Choosing the line explicitly — rather than deriving a rect from
    /// the whole frame — is what keeps it one line tall at a wrap boundary,
    /// where a space belongs to two line fragments at once.
    private func drawCaretIfNeeded(line: CTLine, at origin: CGPoint, in context: CGContext) {
        let range = CTLineGetStringRange(line)
        let start = range.location
        let end = range.location + range.length
        let isLastLine = end >= expected.utf16.count
        guard cursor >= start, cursor < end || (isLastLine && cursor == end) else { return }

        guard caretIsVisible else { return }

        let offset = CTLineGetOffsetForStringIndex(line, cursor, nil)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let x = origin.x + offset
        let bottom = origin.y - descent
        let height = ascent + descent

        switch caretStyle {
        case .vertical:
            context.setFillColor(Theme.caret.cgColor)
            context.fill(
                CGRect(
                    x: x - 1, y: bottom, width: Self.caretThickness, height: height))
        case .block:
            // Translucent, and drawn under the glyph rather than over it. A
            // solid block would have to invert the character to keep it
            // readable, and an inverted glyph in a passage where colour
            // already means correct-or-wrong would be one signal too many.
            context.setFillColor(Theme.caret.withAlphaComponent(0.3).cgColor)
            context.fill(CGRect(x: x, y: bottom, width: advance(on: line, at: cursor), height: height))
        case .horizontal:
            // Below the descender, not on the baseline. Sitting on the
            // baseline put the bar straight through the tail of `g`, `y` and
            // `p` — the font descends 4.6 points at this size and the bar was
            // 2 — so the caret and the letter it marks were drawn on top of
            // each other. Clearing the descender costs a little of the
            // "attached to this character" reading and buys a caret that can
            // always be seen.
            context.setFillColor(Theme.caret.cgColor)
            context.fill(
                CGRect(
                    x: x, y: origin.y - descent - Self.caretGap - Self.caretThickness,
                    width: advance(on: line, at: cursor), height: Self.caretThickness))
        }
    }

    /// The width of the character at `index`, from the line's own offsets.
    ///
    /// Measured rather than taken from the font, because the last character of
    /// a line has no next offset to subtract from — there the trailing edge of
    /// the line is the answer. The font is monospaced, so a fallback to one
    /// advance is exact rather than approximate.
    private func advance(on line: CTLine, at index: Int) -> CGFloat {
        let here = CTLineGetOffsetForStringIndex(line, index, nil)
        let next = CTLineGetOffsetForStringIndex(line, index + 1, nil)
        let width = next - here
        guard width > 0.5 else {
            return ("0" as NSString).size(withAttributes: [.font: Theme.typingFont]).width
        }
        return width
    }

    // MARK: - Whitespace marks

    /// Space, tab and line ends, drawn *over* the text rather than in it.
    ///
    /// The marks are not characters in the attributed string, and that is the
    /// whole design. Putting them in the string — even as attributes — changes
    /// what CoreText measures, so the line height moves the moment they are
    /// switched on and the passage reflows under the reader. Drawn here they
    /// are ink on top of a layout that has not changed, so toggling them moves
    /// nothing.
    ///
    /// The three glyphs are the website's, so the same passage reads the same
    /// way in both. The fourth is this app's own: the website never marks a
    /// soft wrap.
    private func drawWhitespaceMarks(
        line: CTLine, at origin: CGPoint, in context: CGContext, isLast: Bool
    ) {
        let range = CTLineGetStringRange(line)
        guard range.length > 0 else { return }
        // Cached. This rebuilt the whole passage's code units once per visible
        // line, on every keystroke *and* every caret blink — for a ten-line
        // window that is ten walks of the passage twice a second, to read a
        // handful of characters.
        let units = passageUTF16
        let font = Theme.typingFont
        let colour = Theme.whitespaceMark
        var endsWithHardBreak = false

        for index in range.location..<(range.location + range.length) {
            guard index < units.count else { break }
            let mark: String
            switch units[index] {
            case 0x20: mark = "·"
            case 0x09: mark = "→"
            case 0x0A:
                // A hard break is the newline actually in the passage. It is
                // drawn at the end of the line rather than at its own offset,
                // which is past the visible edge.
                endsWithHardBreak = true
                continue
            default: continue
            }
            let x = origin.x + CTLineGetOffsetForStringIndex(line, index, nil)
            draw(
                mark, at: CGPoint(x: x, y: origin.y), width: advance(on: line, at: index),
                font: font, colour: colour, in: context)
        }

        // The line's own ending. `¶` for a paragraph break the passage
        // contains, `↵` for a wrap this window's width happens to cause —
        // the word-processor distinction, and the one the request asked for.
        // The final line of a passage ends because the text ran out, which is
        // neither, so it gets nothing.
        if !isLast || endsWithHardBreak {
            let trailing = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
            draw(
                endsWithHardBreak ? "¶" : "↵",
                at: CGPoint(x: origin.x + trailing, y: origin.y),
                width: advance(on: line, at: range.location + range.length - 1),
                font: font, colour: colour, in: context)
        }
    }

    /// One mark, centred in the cell it stands for.
    ///
    /// Drawn with CoreText, in the flipped space the glyphs are already being
    /// drawn in. The obvious alternative — `NSAttributedString.draw(at:)` —
    /// renders through `NSGraphicsContext`, and mixing that with the raw
    /// `CGContext` transform this method sits inside does not survive a
    /// save/restore: every line of the passage *after* the first mark came out
    /// upside down and mirrored. Staying in CoreText means no second
    /// coordinate system to reconcile.
    private func draw(
        _ mark: String, at point: CGPoint, width: CGFloat, font: NSFont, colour: NSColor,
        in context: CGContext
    ) {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: mark, attributes: [.font: font, .foregroundColor: colour]))
        let markWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.saveGState()
        context.textPosition = CGPoint(x: point.x + (width - markWidth) / 2, y: point.y)
        CTLineDraw(line, context)
        context.restoreGState()
        // `CTLineDraw` leaves the text matrix as it found it useful, not as it
        // found it. `draw(_:)` sets the identity matrix once for the whole
        // frame and `CTFontDrawGlyphs` relies on it — so without this the
        // glyphs on every line after the first mark were transformed off
        // screen and the passage appeared to lose its text. Restoring the
        // graphics state alone does not cover it; the text matrix is not part
        // of what `saveGState` saves.
        context.textMatrix = .identity
    }

    // MARK: - Input

    override func keyUp(with event: NSEvent) {
        // Only the key that was actually released. Clearing unconditionally
        // meant pressing A, then B, then releasing A unlit B while it was
        // still held — and the keyboard showed nothing pressed while a finger
        // was still down.
        held.remove(event.keyCode)
        onKeyPressed?(held.first)
        // The same rule the press follows, for the same reason: ⌘S is a menu
        // command rather than typing, and its release is not typing either.
        if event.modifierFlags.intersection([.command, .control]).isEmpty {
            onKeyReleased?(event.keyCode)
        }
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        // Keys released while another view has focus never reach this one, so
        // the highlight would stay lit on a key nobody is holding. The caret
        // stops blinking here for the same reason it starts on becoming first
        // responder: it marks where keystrokes land, and they no longer do.
        held.removeAll()
        onKeyPressed?(nil)
        defer { restartBlink() }
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        held.insert(event.keyCode)
        onKeyPressed?(event.keyCode)
        // Not on auto-repeat. Holding a key down would otherwise fire the
        // click at the system's repeat rate, which is both unlike a real
        // keyboard — where a held key makes one sound — and, at ~30 Hz, a
        // machine-gun burst through eight voices.
        //
        // Also not for shortcuts: ⌘S is not typing, and it is about to be
        // handled by the menu bar rather than by this view.
        if !event.isARepeat, event.modifierFlags.intersection([.command, .control]).isEmpty {
            onKeyStruck?(event.keyCode)
        }
        // Modified keys are never typing: they belong to the menu bar, and
        // consuming them here would break every shortcut in the app.
        if event.modifierFlags.intersection([.command, .control]).isEmpty {
            if inputContext?.handleEvent(event) == true { return }
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)):
            onBackspace?()
        case #selector(NSResponder.insertTab(_:)):
            onRestart?()
        case #selector(NSResponder.insertNewline(_:)):
            onConfirm?()
        default:
            break
        }
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        // Checked *before* the composition is cleared. `isReplaceable`
        // compares the requested range against `markedRange()`, and clearing
        // first made that range `NSNotFound` — so an input method committing
        // its composition by naming the range it occupies was refused, and the
        // text was lost.
        guard isReplaceable(replacementRange) else { return }
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // A replacement of anything other than the composition currently being
        // held is not something this surface can do — there is no editable
        // document behind it, only a passage being typed against. Silently
        // appending was the wrong answer: an input method asking to replace
        // two characters got two *extra* ones, and the run's statistics
        // counted keystrokes the user never made.
        // One code unit at a time, because that is the engine's coordinate
        // system. A committed CJK character is one unit and arrives whole.
        //
        // Anything outside the basic plane is refused rather than split. An
        // emoji is a surrogate pair, and feeding the halves separately turned
        // one character into two `\u{FFFD}` replacements — two fabricated
        // mistakes, and the cursor advanced by two.
        deliver(text)
        needsDisplay = true
    }

    /// Hands one committed string to the engine, one code unit at a time.
    ///
    /// Both commit paths go through here, and that is the point rather than
    /// tidiness. `unmarkText` had its own copy of this loop, and when the
    /// commit boundary was added to the other one it was not added here — so a
    /// composition committed through unmarking inherited the previous commit's
    /// latch and went silent. One loop cannot drift from itself.
    private func deliver(_ text: String) {
        // One commit, however many code units it carries. The error tone needs
        // this boundary rather than a stopwatch: an input method committing
        // three wrong characters is one act by the typist and deserves one
        // sound, and no interval in milliseconds can tell that apart from
        // three deliberate keys typed quickly.
        onCommitBegan?()
        for unit in Array(text.utf16) {
            guard !(0xD800...0xDFFF).contains(unit) else { continue }
            onCharacter?(String(utf16CodeUnits: [unit], count: 1))
        }
    }

    /// Whether a requested replacement range is one this surface can honour.
    ///
    /// `NSNotFound` means "wherever the insertion point is", which is the only
    /// place text can go here. A range covering exactly the current
    /// composition is the ordinary commit and means the same thing.
    private func isReplaceable(_ range: NSRange) -> Bool {
        // `NSNotFound` is the documented "wherever the insertion point is".
        if range.location == NSNotFound { return true }
        // A zero-length range replaces nothing, which is an insertion however
        // it is located. Requiring it to sit exactly at the cursor rejected
        // every character after the first — the self-test caught it, because
        // AppKit's own committed-text path passes a plain `NSRange()`.
        if range.length == 0 { return true }
        // What is left is a real replacement, and the only span this surface
        // can replace is the composition it is holding.
        return range == markedRange()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard isReplaceable(replacementRange) else { return }
        // Composition in progress. Held, not committed — the engine never sees
        // a pre-composition keystroke.
        markedText = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // Kept so `selectedRange()` can answer in document coordinates. An
        // input method moving its selection inside a composition was told the
        // caret had not moved at all, which is what places a candidate window
        // under the wrong character.
        markedSelection = selectedRange
        if markedText.isEmpty { markedSelection = NSRange(location: 0, length: 0) }
        needsDisplay = true
    }

    /// Ends the composition by *accepting* it.
    ///
    /// Apple's contract is that the marked text stops being marked, not that
    /// it disappears. Throwing it away lost text the user had already
    /// accepted — a committed syllable vanishing when the input method
    /// happened to unmark rather than insert. Cancelling is a different verb
    /// and lives in `discardComposition`.
    func unmarkText() {
        let pending = markedText
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        deliver(pending)
        needsDisplay = true
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: cursor, length: markedText.utf16.count)
    }

    /// The selection, in document coordinates.
    ///
    /// Inside a composition that is the composition's own selection offset by
    /// the caret; outside one it is the caret itself.
    func selectedRange() -> NSRange {
        guard !markedText.isEmpty, markedSelection.location != NSNotFound else {
            return NSRange(location: cursor, length: 0)
        }
        return NSRange(location: cursor + markedSelection.location, length: markedSelection.length)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString?
    { nil }

    /// The character under a screen point, from the same CoreText frame the
    /// view draws. It used to answer with the caret whatever it was asked.
    func characterIndex(for point: NSPoint) -> Int {
        let local = convert(convert(NSRect(origin: point, size: .zero), from: nil).origin, from: nil)
        ensureLayout()
        guard let textFrame else { return cursor }
        let lines = CTFrameGetLines(textFrame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(textFrame, CFRange(location: 0, length: 0), &origins)
        // View coordinates are flipped and scrolled relative to the frame's.
        let flipped = CGPoint(x: local.x, y: contentHeight - scrollOffset - local.y)
        for (index, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let top = origins[index].y + ascent
            let bottom = origins[index].y - descent
            guard flipped.y <= top, flipped.y >= bottom else { continue }
            return CTLineGetStringIndexForPosition(
                line, CGPoint(x: flipped.x - origins[index].x, y: 0))
        }
        return cursor
    }

    /// Where the candidate window goes. Anchored to the caret, so the IME
    /// palette appears under the text being composed rather than at the
    /// window's corner — which is what a hardcoded rectangle at the view's
    /// origin actually did, despite the comment that used to sit here.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let height = Theme.typingFont.pointSize * 1.6
        let local = NSRect(origin: caretOrigin(), size: NSSize(width: 1, height: height))
        guard let window else { return local }
        return window.convertToScreen(convert(local, to: nil))
    }

    /// The caret's top-left corner in view coordinates, or the text's origin
    /// when there is no layout yet.
    private func caretOrigin() -> NSPoint {
        ensureLayout()
        guard let textFrame else { return .zero }
        let lines = CTFrameGetLines(textFrame) as! [CTLine]
        guard let index = cursorLineIndex(lines) else { return .zero }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(textFrame, CFRange(location: 0, length: 0), &origins)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(lines[index], &ascent, nil, nil)
        let offset = CTLineGetOffsetForStringIndex(lines[index], cursor, nil)
        return NSPoint(
            x: origins[index].x + offset,
            y: contentHeight - scrollOffset - (origins[index].y + ascent))
    }
}
