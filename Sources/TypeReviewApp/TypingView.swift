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

    private var expected: String = ""
    private var statuses: [CharStatus] = []
    private var cursor: Int = 0
    private var markedText: String = ""

    private var framesetter: CTFramesetter?
    private var textFrame: CTFrame?
    private var layoutWidth: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    /// Replaces the passage. Rebuilds layout — the only time that happens.
    func setPassage(_ text: String, statuses: [CharStatus], cursor: Int) {
        let passageChanged = text != expected
        expected = text
        self.statuses = statuses
        self.cursor = cursor
        if passageChanged { invalidateLayout() }
        needsDisplay = true
    }

    /// Updates only what a keystroke changes. No relayout.
    func update(statuses: [CharStatus], cursor: Int) {
        self.statuses = statuses
        self.cursor = cursor
        needsDisplay = true
    }

    private func invalidateLayout() {
        framesetter = nil
        textFrame = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - layoutWidth) > 0.5 { invalidateLayout() }
    }

    // MARK: - Layout

    /// The attributed string carries font only — never colour. Colour is
    /// applied per glyph at draw time, so line breaking cannot depend on how
    /// much of the passage has been typed.
    private func makeFramesetter() -> CTFramesetter {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: expected,
            attributes: [.font: Theme.typingFont, .paragraphStyle: paragraph])
        return CTFramesetterCreateWithAttributedString(attributed)
    }

    private func ensureLayout() {
        guard framesetter == nil || textFrame == nil else { return }
        guard !expected.isEmpty else { return }
        let setter = makeFramesetter()
        framesetter = setter
        layoutWidth = bounds.width
        let path = CGPath(rect: bounds, transform: nil)
        textFrame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    }

    /// The height this passage needs at the current width, so the container
    /// can size itself without guessing.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard !expected.isEmpty else { return 0 }
        let setter = framesetter ?? makeFramesetter()
        framesetter = setter
        var fitRange = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), &fitRange)
        return ceil(size.height) + 8
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
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let lines = CTFrameGetLines(textFrame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(textFrame, CFRange(location: 0, length: 0), &origins)

        for (index, line) in lines.enumerated() {
            let origin = origins[index]
            drawColoured(line: line, at: origin, in: context)
            drawCaretIfNeeded(line: line, at: origin, in: context)
        }
        context.restoreGState()
    }

    /// Draws one line, recolouring each glyph run by typing status.
    ///
    /// Colouring at draw time rather than in the attributed string is what
    /// keeps the layout stable: the same `CTFrame` serves every keystroke.
    private func drawColoured(line: CTLine, at origin: CGPoint, in context: CGContext) {
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)

            let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
            let font = (attributes[.font] as? NSFont) ?? Theme.typingFont

            // One draw call per colour change rather than per glyph: a run of
            // untyped text is a single call.
            var index = 0
            while index < count {
                let colour = colour(forCharacterAt: indices[index])
                var end = index + 1
                while end < count, colour == self.colour(forCharacterAt: indices[end]) { end += 1 }
                context.setFillColor(colour.cgColor)
                let slice = index..<end
                var slicePositions = Array(positions[slice])
                for offset in slicePositions.indices {
                    slicePositions[offset].x += origin.x
                    slicePositions[offset].y += origin.y
                }
                CTFontDrawGlyphs(font, Array(glyphs[slice]), slicePositions, slice.count, context)
                index = end
            }
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

        let offset = CTLineGetOffsetForStringIndex(line, cursor, nil)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let caret = CGRect(
            x: origin.x + offset - 1, y: origin.y - descent, width: 2, height: ascent + descent)
        context.setFillColor(Theme.caret.cgColor)
        context.fill(caret)
    }

    // MARK: - Input

    override func keyUp(with event: NSEvent) {
        onKeyPressed?(nil)
        super.keyUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
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
        markedText = ""
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // One code unit at a time, because that is the engine's coordinate
        // system. A committed CJK character is one unit and arrives whole.
        for unit in Array(text.utf16) {
            onCharacter?(String(utf16CodeUnits: [unit], count: 1))
        }
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Composition in progress. Held, not committed — the engine never sees
        // a pre-composition keystroke.
        markedText = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        needsDisplay = true
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: cursor, length: markedText.utf16.count)
    }
    func selectedRange() -> NSRange { NSRange(location: cursor, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString?
    { nil }
    func characterIndex(for point: NSPoint) -> Int { cursor }

    /// Where the candidate window goes. Anchored to the caret, so the IME
    /// palette appears under the text being composed rather than at the
    /// window's corner.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let local = NSRect(x: 0, y: 0, width: 1, height: Theme.typingFont.pointSize * 1.6)
        guard let window else { return local }
        return window.convertToScreen(convert(local, to: nil))
    }
}
