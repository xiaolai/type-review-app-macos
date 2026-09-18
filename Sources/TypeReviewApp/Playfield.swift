import AppKit
import QuartzCore

/// Play's surface: where things fall, and where keys arrive.
///
/// Keys arrive exactly as they do in `TypingView`, and for its reasons: the key
/// code from `keyDown` for the keyboard highlight and the click, committed
/// characters through the input context — never `NSEvent.characters` — and
/// the same rules for held keys, key repeat, shortcuts and Latin-only
/// keyboards. The comments on `TypingView` explain each; they are not repeated
/// here.
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

    let world = CALayer()
    var latinInputOnly = true {
        didSet { applyInputSourceRestriction() }
    }

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var held: Set<UInt16> = []
    private var markedText = ""
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
        guard let window else { return }
        // Frames only while the view is in a window: switching to Practice
        // takes it out, and a game nobody can see should not be running.
        let link = displayLink(target: self, selector: #selector(advance(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFocusLost?() }
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

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        held.insert(event.keyCode)
        onKeyPressed?(event.keyCode)
        let isShortcut = !event.modifierFlags.intersection([.command, .control]).isEmpty
        if !event.isARepeat, !isShortcut { onKeyStruck?(event.keyCode) }
        if !isShortcut, inputContext?.handleEvent(event) == true { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        held.remove(event.keyCode)
        onKeyPressed?(held.first)
        if event.modifierFlags.intersection([.command, .control]).isEmpty {
            onKeyReleased?(event.keyCode)
        }
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        held.removeAll()
        onKeyPressed?(nil)
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
        guard isReplaceable(replacementRange) else { return }
        markedText = ""
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // One commit, one error tone at most; one code unit at a time, and
        // never half of a surrogate pair. `TypingView.deliver` explains all three.
        onCommitBegan?()
        for unit in Array(text.utf16) where !(0xD800...0xDFFF).contains(unit) {
            onCharacter?(String(utf16CodeUnits: [unit], count: 1))
        }
    }

    // A Latin layout's dead keys still compose, so composition is accepted,
    // though nothing here draws it: the key is committed a moment later.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard isReplaceable(replacementRange) else { return }
        markedText = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    }

    func unmarkText() {
        let text = markedText
        markedText = ""
        if !text.isEmpty { insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString?
    { nil }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }

    /// `TypingView.isReplaceable`: the insertion point, an empty range, or
    /// exactly the composition being held.
    private func isReplaceable(_ range: NSRange) -> Bool {
        range.location == NSNotFound || range.length == 0 || range == markedRange()
    }
}
