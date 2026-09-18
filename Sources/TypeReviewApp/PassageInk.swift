import AppKit

/// How passage text is marked, on every surface that shows it: the three caret
/// shapes, the cell behind a mistyped space, and the whitespace marks.
///
/// These lived inside `TypingView`, which was the only thing drawing passage
/// text. Play draws it too — a falling word is a fragment of a passage — and a
/// second copy of the caret is how two screens of one app stop looking like
/// one app, so both now draw through here.
///
/// Every function draws in a y-up CoreText space, which is the space both
/// callers are already in when they draw glyphs.
enum PassageInk {
    /// Bar and underline carets. Two points reads as a caret at this size; one
    /// disappears against the text, three reads as a rule.
    static let caretThickness: CGFloat = 2
    /// Air between the descender line and the underline caret. Without it the
    /// tail of a `y` or a `g` lands exactly on the bar, which is the same
    /// collision that moving it off the baseline was meant to fix.
    static let caretGap: CGFloat = 1

    /// Whether a caret goes under the glyph it marks rather than over it. A
    /// block caret is a highlight, so it belongs under; a bar or an underline
    /// sits beside or below a glyph and can be drawn over the top.
    static func caretGoesUnderGlyphs(_ style: AppPreferences.CaretStyle) -> Bool {
        style == .block
    }

    /// The caret for the character in `cell`: its advance wide, from the bottom
    /// of the descender to the top of the ascender.
    static func drawCaret(
        _ style: AppPreferences.CaretStyle, cell: CGRect, in context: CGContext
    ) {
        switch style {
        case .vertical:
            context.setFillColor(Theme.caret.cgColor)
            context.fill(
                CGRect(x: cell.minX - 1, y: cell.minY, width: caretThickness, height: cell.height))
        case .block:
            // Translucent, and drawn under the glyph rather than over it. A
            // solid block would have to invert the character to keep it
            // readable, and an inverted glyph in a passage where colour
            // already means correct-or-wrong would be one signal too many.
            context.setFillColor(Theme.caret.withAlphaComponent(0.3).cgColor)
            context.fill(cell)
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
                    x: cell.minX, y: cell.minY - caretGap - caretThickness,
                    width: cell.width, height: caretThickness))
        }
    }

    /// A mistyped space, made visible: a faint red cell, since a space has no
    /// ink for the error colour to colour. See `TypingView.drawIncorrectSpaces`.
    static func drawIncorrectSpace(cell: CGRect, in context: CGContext) {
        context.setFillColor(Theme.incorrectSpace.cgColor)
        context.addPath(CGPath(roundedRect: cell, cornerWidth: 2, cornerHeight: 2, transform: nil))
        context.fillPath()
    }

    /// One whitespace mark, centred in the cell it stands for.
    ///
    /// Drawn with CoreText, in the flipped space the glyphs are already being
    /// drawn in. The obvious alternative — `NSAttributedString.draw(at:)` —
    /// renders through `NSGraphicsContext`, and mixing that with the raw
    /// `CGContext` transform this method sits inside does not survive a
    /// save/restore: every line of the passage *after* the first mark came out
    /// upside down and mirrored. Staying in CoreText means no second
    /// coordinate system to reconcile.
    static func drawMark(
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
        // found it. `TypingView.draw(_:)` sets the identity matrix once for
        // the whole frame and `CTFontDrawGlyphs` relies on it — so without this
        // the glyphs on every line after the first mark were transformed off
        // screen and the passage appeared to lose its text. Restoring the
        // graphics state alone does not cover it; the text matrix is not part
        // of what `saveGState` saves.
        context.textMatrix = .identity
    }
}
