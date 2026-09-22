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
    /// Keys and composition, shared with Play's surface. See `KeyInput`.
    private lazy var input: KeyInput = {
        let input = KeyInput()
        input.onCharacter = { [weak self] in self?.onCharacter?($0) }
        input.onCommitBegan = { [weak self] in self?.onCommitBegan?() }
        input.onKeyPressed = { [weak self] in self?.onKeyPressed?($0) }
        input.onKeyStruck = { [weak self] in self?.onKeyStruck?($0) }
        input.onKeyReleased = { [weak self] in self?.onKeyReleased?($0) }
        return input
    }()

    /// Read from `AppPreferences` and pushed in, rather than read here: this
    /// view is drawn on every keystroke and should not be querying
    /// `UserDefaults` in a draw call.
    var caretStyle: AppPreferences.CaretStyle = .vertical {
        didSet { if caretStyle != oldValue { needsDisplay = true } }
    }
    /// Whether only Latin keyboard layouts may type into this view.
    ///
    /// The passages are English and ASCII, so an input method that composes —
    /// Pinyin, Kotoeri, Hangul — can only hold letters back until it commits,
    /// turn a space into choosing a candidate, and commit characters no passage
    /// contains. `NSAllRomanInputSourcesLocaleIdentifier` is every Latin layout
    /// rather than ABC alone, so Dvorak, Colemak and AZERTY are untouched, and
    /// the composition support below stays: dead keys on a Latin layout compose
    /// too.
    ///
    /// AppKit applies it while this view's input context is active, so the
    /// practice window alone is affected. It is changed from the Settings
    /// window, which is key at that moment, so the context is inactive when it
    /// changes and picks the new value up when the practice window returns.
    var latinInputOnly = true {
        didSet { applyInputSourceRestriction() }
    }

    /// Hands the setting to the input context, which is where AppKit reads it.
    ///
    /// Called when the view joins a window as well as on every change, and the
    /// second call is insurance rather than a repair. Measured: the context
    /// already exists when the preference is first applied, while the practice
    /// screen is being built, so that first assignment takes. It takes only
    /// because of that ordering, though. If the context did not exist yet, the
    /// assignment would do nothing and the view would read `true` while
    /// restricting nothing — and the launch check in `--selftest` is what would
    /// say so.
    private func applyInputSourceRestriction() {
        inputContext?.allowedInputSourceLocales =
            latinInputOnly ? [NSAllRomanInputSourcesLocaleIdentifier] : nil
    }

    var showsWhitespace = false {
        didSet { if showsWhitespace != oldValue { needsDisplay = true } }
    }

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
        input.discard(from: inputContext)
    }

    // MARK: - Blinking

    /// The blink phase. The caret is drawn only on the lit half.
    private var caretIsVisible = true
    private var blinkTimer: Timer?
    /// Key-window observers for the window this view is currently in.
    private var windowObservers: [NSObjectProtocol] = []

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
        applyInputSourceRestriction()
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
            // Keys still down when the window stops taking keys are released
            // somewhere else, so this view never hears it: let them go now.
            windowObservers.append(
                centre.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.input.releaseAll() }
                })
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
        //
        // Narrower than the view by the spaces a line can end in. CoreText does
        // not carry a line's closing space onto the next line; it leaves it
        // hanging past the frame's edge. With the frame as wide as the view, a
        // line that filled it exactly put that space wholly outside the clip in
        // `draw`, so a space mistyped at a wrap was scored and drawn nowhere —
        // 0 of its 13.6 points visible — and the caret on it vanished with it.
        // `PracticeWindowMetrics.contentSize` adds the column back, so a
        // 60-column window still wraps at 60.
        let layoutWidth = max(1, bounds.width - hangingWhitespaceWidth)
        var fitRange = CFRange()
        let needed = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: layoutWidth, height: .greatestFiniteMagnitude), &fitRange)
        contentHeight = max(bounds.height, ceil(needed.height) + 8)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: layoutWidth, height: contentHeight),
            transform: nil)
        textFrame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    }

    /// The widest run of spaces a line of this passage can end in.
    ///
    /// One space for prose, where cleaning collapses every run. More only for a
    /// run in the middle of a line, which no bundled passage has and code with
    /// aligned columns would. Indentation does not count: CoreText breaks after
    /// a leading run rather than inside it, so a run at the start of a line can
    /// end one only by being wider than the whole frame.
    private var hangingWhitespaceWidth: CGFloat {
        var longest = 1
        var run = 0
        var atLineStart = true
        for unit in passageUTF16 {
            if unit == 0x20 {
                run += 1
                if !atLineStart { longest = max(longest, run) }
            } else {
                run = 0
                atLineStart = unit == 0x0A
            }
        }
        return PracticeWindowMetrics.characterWidth * CGFloat(longest)
    }


    // MARK: - Drawing

    /// How many times this view has been drawn. Read by `--selftest`, which
    /// never shows a window and so requires it to still be zero when it looks:
    /// the main window is created deferred so that nothing under it is drawn
    /// before it is shown, and a passage drawn where nothing could see it cost
    /// 8.9 MB of bitmap and left no other trace a check could find.
    private(set) var drawCount = 0

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
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
            drawIncorrectSpaces(line: line, at: origin, in: context)
            // A block caret is a highlight, so it belongs under the glyph it
            // marks. A bar or an underline sits beside or below one and can be
            // drawn over the top.
            if PassageInk.caretGoesUnderGlyphs(caretStyle) {
                drawCaretIfNeeded(line: line, at: origin, in: context)
            }
            drawColoured(line: line, at: origin, in: context)
            if !PassageInk.caretGoesUnderGlyphs(caretStyle) {
                drawCaretIfNeeded(line: line, at: origin, in: context)
            }
            if showsWhitespace {
                drawWhitespaceMarks(line: line, at: origin, in: context)
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
        guard !input.markedText.isEmpty else { return }
        let line = compositionLine()
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

    /// The composition as one line of text, as it is drawn — which is also
    /// what an input method's character positions inside it are measured on.
    private func compositionLine() -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: input.markedText,
                attributes: [
                    .font: Theme.typingFont,
                    .foregroundColor: Theme.correct,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]))
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

    /// A mistyped space, made visible.
    ///
    /// Glyphs are coloured by status, and a space has no ink to colour. So a
    /// wrong key where a space belonged was scored as a mistake and drawn as
    /// nothing: the cursor moved on over a blank cell, and the mistake looked
    /// accepted. The website has always shown it with a faint red cell, and this
    /// is that cell. Drawn whatever "Show invisibles" says, because a mistake is
    /// not an invisible, and under the glyphs, like the block caret.
    ///
    /// Spaces only. A tab would have the same problem, but no passage can hold
    /// one: prose cleaning turns tabs into spaces and no bundled code contains a
    /// tab, which is also why the website backgrounds spaces alone.
    private func drawIncorrectSpaces(line: CTLine, at origin: CGPoint, in context: CGContext) {
        let range = CTLineGetStringRange(line)
        guard range.length > 0 else { return }
        let units = passageUTF16
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        for index in range.location..<(range.location + range.length) {
            guard index < units.count, index < statuses.count else { break }
            guard units[index] == 0x20, statuses[index] == .incorrect else { continue }
            let cell = CGRect(
                x: origin.x + CTLineGetOffsetForStringIndex(line, index, nil),
                y: origin.y - descent, width: advance(on: line, at: index),
                height: ascent + descent)
            PassageInk.drawIncorrectSpace(cell: cell, in: context)
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
        // The shapes themselves are `PassageInk`'s, shared with Play.
        let cell = CGRect(
            x: origin.x + offset, y: origin.y - descent, width: advance(on: line, at: cursor),
            height: ascent + descent)
        PassageInk.drawCaret(caretStyle, cell: cell, in: context)
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
    /// Not the website's glyphs, though this used to say they were. The website
    /// marks a space with an open box and a line break with an arrow; this app
    /// uses a middle dot and a pilcrow. What the two share is what gets a mark
    /// at all, which is a character the passage contains, and the colour rule:
    /// a mark turns red when the character it stands for was mistyped.
    private func drawWhitespaceMarks(line: CTLine, at origin: CGPoint, in context: CGContext) {
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
            let mistyped = index < statuses.count && statuses[index] == .incorrect
            PassageInk.drawMark(
                mark, at: CGPoint(x: x, y: origin.y), width: advance(on: line, at: index),
                font: font, colour: mistyped ? Theme.incorrect : colour, in: context)
        }

        // A line break the passage contains, and only that. A line this
        // window's width wrapped used to end in `↵` as well, on the theory that
        // this was the word-processor distinction. It is the reverse: a word
        // processor draws that arrow for a line break someone typed and nothing
        // for a wrap, and the website draws it for a real break too. So the one
        // mark meaning "there is no character here" was the one every typist
        // reads as the Return key, and it sat at the end of nearly every line of
        // a quote, none of which contains a line break at all. A wrap is layout,
        // not text, and the marks are for text.
        if endsWithHardBreak {
            let trailing = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
            PassageInk.drawMark(
                "¶", at: CGPoint(x: origin.x + trailing, y: origin.y),
                width: advance(on: line, at: range.location + range.length - 1),
                font: font, colour: colour, in: context)
        }
    }

    // MARK: - Input

    override func keyUp(with event: NSEvent) {
        input.keyUp(event)
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        // Keys released while another view has focus never reach this one. The
        // caret stops blinking here for the same reason it starts on becoming
        // first responder: it marks where keystrokes land, and they no longer do.
        input.releaseAll()
        defer { restartBlink() }
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if input.keyDown(event), inputContext?.handleEvent(event) == true { return }
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
        guard input.isReplaceable(replacementRange, markedRange: markedRange()) else { return }
        input.insert(string)
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard input.isReplaceable(replacementRange, markedRange: markedRange()) else { return }
        input.mark(string, selectedRange: selectedRange)
        needsDisplay = true
    }

    func unmarkText() {
        input.unmark()
        needsDisplay = true
    }

    func hasMarkedText() -> Bool { !input.markedText.isEmpty }
    func markedRange() -> NSRange {
        input.markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: cursor, length: input.markedText.utf16.count)
    }

    /// The selection, in document coordinates.
    ///
    /// Inside a composition that is the composition's own selection offset by
    /// the caret; outside one it is the caret itself.
    func selectedRange() -> NSRange {
        let selection = input.markedSelection
        guard !input.markedText.isEmpty, selection.location != NSNotFound else {
            return NSRange(location: cursor, length: 0)
        }
        return NSRange(location: cursor + selection.location, length: selection.length)
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
    /// Where an input method's candidate window goes: the requested character
    /// of the composition, which is drawn from the caret on, or the caret when
    /// there is none. One character at most, and `actualRange` says exactly
    /// what the rect covers — it used to echo the whole request back, for a
    /// rect one point wide.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let marked = input.markedText.utf16.count
        let location = range.location == NSNotFound ? cursor : range.location
        let start = min(max(0, location - cursor), marked)
        let length = min(range.length, 1, marked - start)
        actualRange?.pointee = NSRange(location: cursor + start, length: length)
        let line = compositionLine()
        let from = CTLineGetOffsetForStringIndex(line, start, nil)
        let to = CTLineGetOffsetForStringIndex(line, start + length, nil)
        let origin = caretOrigin()
        let height = Theme.typingFont.pointSize * 1.6
        let local = NSRect(x: origin.x + from, y: origin.y, width: to - from, height: height)
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
