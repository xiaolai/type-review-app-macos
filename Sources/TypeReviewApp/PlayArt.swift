import AppKit
import CoreText
import TypeReviewKit

/// How falling text is drawn: the typing surface's own font, colours, caret
/// and whitespace marks, rendered once per change into an image a layer moves.
///
/// Rendered rather than drawn live because the text moves every frame and
/// changes only on a keystroke: redrawing a view sixty times a second to move
/// it would be the expensive way to do nothing. The marks come from
/// `PassageInk`, the same as the practice screen's, so a falling word is a
/// fragment of a passage and looks it.
@MainActor
struct PlayArt {
    /// Room either side, so a bar caret one point left of the first character
    /// is not clipped.
    static let padX: CGFloat = 2
    /// Below the descender, room for the underline caret: its gap, its
    /// thickness and a point of air.
    static let caretRoom: CGFloat = PassageInk.caretGap + PassageInk.caretThickness + 1

    let font: NSFont
    let letterFont: NSFont
    let popFont: NSFont
    var scale: CGFloat = 2
    var appearance = NSAppearance(named: .aqua)!
    var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)! {
        didSet { colorSpaceIdentity = Self.identity(of: colorSpace) }
    }
    /// `colorSpace`, as the signature compares it. Worked out once per change,
    /// because the signature is read for every item on every frame.
    private var colorSpaceIdentity = PlayArt.identity(of: CGColorSpace(name: CGColorSpace.sRGB)!)
    /// Play underlines, whatever Settings says.
    ///
    /// The preference is about a passage that sits still, where all three
    /// shapes read the same. Here the word is falling and being typed at once,
    /// and the other two fight that: the bar stands *between* two letters,
    /// which on a moving word reads as a gap opening in it, and the block
    /// tints the very character it is asking you to find. The underline marks
    /// the place without touching the letter. Room for it is reserved under
    /// the descender of every item anyway — see `caretRoom` — so this costs
    /// the layout nothing.
    let caret = AppPreferences.CaretStyle.horizontal
    var showsWhitespace = AppPreferences.showWhitespace.value

    init() {
        font = Theme.typingFont
        // Single letters are the one place Play sets type larger: a lone
        // 22-point letter is too small a target to find while it moves. Same
        // face, twice the size.
        letterFont = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 2) ?? font
        popFont = NSFont(descriptor: Theme.statFont.fontDescriptor, size: 17) ?? Theme.statFont
    }

    /// Everything that changes how an image looks, so a stale one is redrawn —
    /// the colour space included, since two displays can share a scale.
    var signature: String {
        "\(appearance.name.rawValue) \(scale) \(colorSpaceIdentity) \(showsWhitespace)"
    }

    /// A colour space by its profile, not its name. The name is only what the
    /// space was created with, and two displays' profiles can share one — so a
    /// window moved between them kept images drawn for the first.
    private static func identity(of space: CGColorSpace) -> String {
        let name = (space.name as String?) ?? "unnamed"
        guard let profile = space.copyICCData() as Data? else {
            return "\(name) model \(space.model.rawValue)"
        }
        // Every byte. `Data`'s own hash samples only a prefix, and an ICC
        // profile's header can match another display's.
        var hasher = Hasher()
        profile.withUnsafeBytes { hasher.combine(bytes: $0) }
        return "\(name) \(profile.count) \(hasher.finalize())"
    }

    func face(_ mode: PlayMode) -> NSFont { mode == .letters ? letterFont : font }

    /// One character's box: the advance, measured the way
    /// `PracticeWindowMetrics.characterWidth` measures it, by the line's height
    /// plus room for an underline caret.
    func cell(_ mode: PlayMode) -> PlaySize {
        let face = face(mode)
        let width = ("0" as NSString).size(withAttributes: [.font: face]).width
        return PlaySize(
            width: Double(width), height: Double(ceil(face.ascender - face.descender + Self.caretRoom)))
    }

    func box(for item: FallingItem) -> CGSize {
        CGSize(width: CGFloat(item.size.width) + 2 * Self.padX, height: CGFloat(item.size.height))
    }

    func resolve(_ colour: NSColor) -> CGColor {
        var resolved = colour.cgColor
        appearance.performAsCurrentDrawingAppearance { resolved = colour.cgColor }
        return resolved
    }

    /// A falling item, drawn as a line of a passage would be.
    func image(of item: FallingItem, mode: PlayMode, target: Bool, wrong: Bool) -> CGImage? {
        let face = face(mode)
        let advance = CGFloat(cell(mode).width)
        let descent = -face.descender
        let baseline = Self.caretRoom + descent
        let caretAt: Int? = target && item.typed < item.chars.count ? item.typed : nil
        func cellRect(_ index: Int) -> CGRect {
            CGRect(
                x: Self.padX + CGFloat(index) * advance, y: baseline - descent, width: advance,
                height: face.ascender + descent)
        }

        return render(size: box(for: item), opaque: true) { context in
            if let index = caretAt, wrong, item.chars[index] == " " {
                PassageInk.drawIncorrectSpace(cell: cellRect(index), in: context)
            }
            if let index = caretAt, PassageInk.caretGoesUnderGlyphs(caret) {
                PassageInk.drawCaret(caret, cell: cellRect(index), in: context)
            }

            let text = NSMutableAttributedString()
            let colourKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
            for (index, character) in item.chars.enumerated() {
                let colour: NSColor =
                    item.gone.contains(index) ? .clear
                    : index < item.typed ? Theme.correct
                    : (wrong && index == item.typed) ? Theme.incorrect
                    : Theme.pending
                text.append(
                    NSAttributedString(
                        string: character, attributes: [.font: face, colourKey: colour.cgColor]))
            }
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: Self.padX, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)

            if showsWhitespace {
                for (index, character) in item.chars.enumerated()
                where character == " " && !item.gone.contains(index) {
                    let missed = wrong && index == item.typed
                    PassageInk.drawMark(
                        "·", at: CGPoint(x: cellRect(index).minX, y: baseline), width: advance,
                        font: face, colour: missed ? Theme.incorrect : Theme.whitespaceMark,
                        in: context)
                }
            }
            if let index = caretAt, !PassageInk.caretGoesUnderGlyphs(caret) {
                PassageInk.drawCaret(caret, cell: cellRect(index), in: context)
            }
        }
    }

    /// What an input method is composing, drawn as the practice screen draws
    /// a composition: the typing face, underlined, in the typed colour — the
    /// platform's way of saying "not accepted yet" — on the passage's ground,
    /// so it covers the character it sits over.
    func composition(_ text: String, mode: PlayMode) -> CGImage? {
        let face = face(mode)
        let cell = cell(mode)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: face,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Theme.correct.cgColor,
            NSAttributedString.Key(kCTUnderlineStyleAttributeName as String): CTUnderlineStyle.single.rawValue,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = max(CGFloat(cell.width), ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
        return render(size: CGSize(width: width, height: cell.height), opaque: true) { context in
            // Resolved inside the render, where the appearance is current.
            let resolved = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: attributes.merging([
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                            Theme.correct.cgColor
                    ]) { $1 }))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 0, y: Self.caretRoom - face.descender)
            CTLineDraw(resolved, context)
        }
    }

    enum GlyphRole { case typed, pending }

    /// One character on a clear ground, for the pieces a burst throws.
    func glyph(_ character: String, mode: PlayMode, role: GlyphRole) -> CGImage? {
        let face = face(mode)
        let size = cell(mode)
        return render(size: CGSize(width: size.width, height: size.height), opaque: false) { context in
            let colour = role == .typed ? Theme.correct : Theme.pending
            let text = NSAttributedString(
                string: character,
                attributes: [
                    .font: face,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour.cgColor,
                ])
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 0, y: Self.caretRoom - face.descender)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
    }

    private func render(size: CGSize, opaque: Bool, _ body: (CGContext) -> Void) -> CGImage? {
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            // An item sits on the passage's own ground, which is what
            // `TypingView` draws its text over.
            if opaque {
                context.setFillColor(Theme.background.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
            body(context)
            image = context.makeImage()
        }
        return image
    }
}
