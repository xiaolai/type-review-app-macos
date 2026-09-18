import AppKit
import QuartzCore

/// Play's surface: where things fall, and where keys arrive.
///
/// Keys arrive exactly as they do on the practice screen, through the same
/// `KeyInput`: the key code from `keyDown` for the keyboard highlight and the
/// click, committed characters through the input context — never
/// `NSEvent.characters` — and Latin keyboards only when that is set. What is
/// Play's own is where the caret is: the next character of the item being
/// typed, which the screen tells this view through `caretIndex` and
/// `caretRect`, so an input method's selection and candidate window sit there.
///
/// Layer-hosting rather than layer-backed: every layer inside is this view's
/// to arrange, and AppKit draws into none of them.
final class Playfield: NSView, @preconcurrency NSTextInputClient {
    var onCharacter: ((String) -> Void)?
    var onCommitBegan: (() -> Void)?
    var onKeyPressed: ((UInt16?) -> Void)?
    var onKeyStruck: ((UInt16) -> Void)?
    var onKeyReleased: ((UInt16) -> Void)?
    var onPause: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onRestart: (() -> Void)?
    /// Once a frame, with the seconds since the last one.
    var onFrame: ((Double) -> Void)?
    /// The appearance or the display's scale changed.
    var onDisplayChange: (() -> Void)?
    /// The window stopped being the one that takes keys.
    var onFocusLost: (() -> Void)?
    /// The text an input method is composing changed; empty when it ends.
    var onCompositionChanged: ((String) -> Void)?
    /// Where the caret is in the text being typed, in characters: the
    /// document position an input method's ranges are measured from.
    var caretIndex: () -> Int = { 0 }
    /// The next character's cell, in this view's coordinates, or nil when
    /// nothing is being typed.
    var caretRect: () -> NSRect? = { nil }

    let world = CALayer()
    var latinInputOnly = true {
        didSet { applyInputSourceRestriction() }
    }

    private lazy var input: KeyInput = {
        let input = KeyInput()
        input.onCharacter = { [weak self] in self?.onCharacter?($0) }
        input.onCommitBegan = { [weak self] in self?.onCommitBegan?() }
        input.onKeyPressed = { [weak self] in self?.onKeyPressed?($0) }
        input.onKeyStruck = { [weak self] in self?.onKeyStruck?($0) }
        input.onKeyReleased = { [weak self] in self?.onKeyReleased?($0) }
        return input
    }()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var windowObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = world
        wantsLayer = true
        world.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        guard let window else {
            // Out of the window — switched to Practice. A composition left
            // here would commit into a game nobody is looking at.
            discardComposition()
            return
        }
        // Frames only while the view is in a window: switching to Practice
        // takes it out, and a game nobody can see should not be running.
        let link = displayLink(target: self, selector: #selector(advance(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Keys still down are released somewhere else now.
                self?.input.releaseAll()
                self?.onFocusLost?()
            }
        }
        applyInputSourceRestriction()
        paintGround()
        onDisplayChange?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintGround()
        onDisplayChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onDisplayChange?()
    }

    private func applyInputSourceRestriction() {
        inputContext?.allowedInputSourceLocales =
            latinInputOnly ? [NSAllRomanInputSourcesLocaleIdentifier] : nil
    }

    /// The passage's own ground, resolved for this view's appearance, since a
    /// layer holds a colour rather than the name of one.
    private func paintGround() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            world.backgroundColor = Theme.background.cgColor
        }
    }

    @objc private func advance(_ link: CADisplayLink) {
        let now = link.timestamp
        // Capped, so coming back from a sleep or a stall is one ordinary frame
        // rather than a leap that drops everything on the floor at once.
        let dt = lastTimestamp.map { min(0.05, max(0, now - $0)) } ?? 0
        lastTimestamp = now
        onFrame?(dt)
    }

    /// Ends a composition without committing it — for a new game, where a
    /// half-typed character belongs to text that is gone.
    func discardComposition() {
        if input.discard(from: inputContext) { onCompositionChanged?("") }
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        if input.keyDown(event), inputContext?.handleEvent(event) == true { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        input.keyUp(event)
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        input.releaseAll()
        return super.resignFirstResponder()
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): onPause?()
        case #selector(NSResponder.insertNewline(_:)): onConfirm?()
        case #selector(NSResponder.insertTab(_:)): onRestart?()
        // Delete and the arrows mean nothing to something falling.
        default: break
        }
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard input.isReplaceable(replacementRange, markedRange: markedRange()) else { return }
        let hadComposition = !input.markedText.isEmpty
        input.insert(string)
        if hadComposition { onCompositionChanged?("") }
    }

    // A Latin layout's dead keys compose too, so a composition is shown at the
    // caret until it commits — the way the practice screen shows one.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard input.isReplaceable(replacementRange, markedRange: markedRange()) else { return }
        input.mark(string, selectedRange: selectedRange)
        onCompositionChanged?(input.markedText)
    }

    func unmarkText() {
        input.unmark()
        onCompositionChanged?("")
    }

    func hasMarkedText() -> Bool { !input.markedText.isEmpty }

    func markedRange() -> NSRange {
        input.markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: caretIndex(), length: input.markedText.utf16.count)
    }

    /// The selection in document coordinates: the composition's own selection
    /// offset by the caret, or the caret itself.
    func selectedRange() -> NSRange {
        let selection = input.markedSelection
        guard !input.markedText.isEmpty, selection.location != NSNotFound else {
            return NSRange(location: caretIndex(), length: 0)
        }
        return NSRange(location: caretIndex() + selection.location, length: selection.length)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString?
    { nil }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Where the candidate window goes: under the requested character of what
    /// is being typed, as on the practice screen, or the field's lower-left
    /// corner when nothing is.
    ///
    /// One character's cell, and `actualRange` says it is one character: the
    /// rect covers no more than that, whatever was asked for. An empty range is
    /// the insertion point, so it has no width.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let caret = caretIndex()
        let location = range.location == NSNotFound ? caret : range.location
        actualRange?.pointee = NSRange(location: location, length: min(range.length, 1))
        var local: NSRect
        if let cell = caretRect() {
            // Every cell is one advance wide, so a character past the caret —
            // inside a composition, which is drawn from the caret on — is that
            // many cells along.
            local = cell.offsetBy(dx: CGFloat(max(0, location - caret)) * cell.width, dy: 0)
        } else {
            local = NSRect(x: bounds.minX, y: bounds.minY, width: 1, height: 1)
        }
        if range.length == 0 { local.size.width = 0 }
        guard let window else { return local }
        return window.convertToScreen(convert(local, to: nil))
    }
}
