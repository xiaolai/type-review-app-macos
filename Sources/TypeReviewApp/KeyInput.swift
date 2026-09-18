import AppKit

/// Keys and composition, for both surfaces that take typing.
///
/// `TypingView` and Play's `Playfield` each had their own copy of this, and the
/// second had already lost what the first had learned — the composition's
/// selection, clearing a composition on reset. So everything a surface does not
/// own lives here once: which physical keys are down and which of them
/// sounded, the text an input method is holding, and how a commit is handed
/// on. A surface keeps what is its own: where its caret is, how it draws a
/// composition, and what Tab and Return mean on it.
@MainActor
final class KeyInput {
    var onCharacter: ((String) -> Void)?
    var onCommitBegan: (() -> Void)?
    var onKeyPressed: ((UInt16?) -> Void)?
    var onKeyStruck: ((UInt16) -> Void)?
    var onKeyReleased: ((UInt16) -> Void)?

    /// Text an input method is composing: shown, not yet typed.
    private(set) var markedText = ""
    /// The input method's selection inside the composition, in composition
    /// coordinates. Kept so a surface can say where its caret is inside a
    /// composition: an input method moving its selection was told the caret
    /// had not moved at all, which is what places a candidate window under the
    /// wrong character.
    private(set) var markedSelection = NSRange(location: 0, length: 0)
    /// Key codes currently held down, so releasing one does not unlight another.
    private var held: Set<UInt16> = []
    /// Key codes whose press sounded, so exactly those sound on release.
    private var struck: Set<UInt16> = []

    /// Modified keys are never typing: ⌘S belongs to the menu bar, and a
    /// surface consuming it would break every shortcut in the app.
    static func isShortcut(_ event: NSEvent) -> Bool {
        !event.modifierFlags.intersection([.command, .control]).isEmpty
    }

    /// The text of whatever an input method hands over.
    static func text(of string: Any) -> String {
        (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    }

    // MARK: - Keys

    /// A key went down. Answers whether it is typing, which is whether the
    /// surface should hand it to its input context.
    func keyDown(_ event: NSEvent) -> Bool {
        held.insert(event.keyCode)
        onKeyPressed?(event.keyCode)
        let shortcut = Self.isShortcut(event)
        // Not on auto-repeat. Holding a key down would otherwise fire the
        // click at the system's repeat rate, which is both unlike a real
        // keyboard — where a held key makes one sound — and, at ~30 Hz, a
        // machine-gun burst through eight voices. Not for shortcuts either:
        // ⌘S is about to be handled by the menu bar.
        if !event.isARepeat, !shortcut {
            struck.insert(event.keyCode)
            onKeyStruck?(event.keyCode)
        }
        return !shortcut
    }

    func keyUp(_ event: NSEvent) {
        // Only the key that was actually released. Clearing unconditionally
        // meant pressing A, then B, then releasing A unlit B while it was
        // still held — and the keyboard showed nothing pressed while a finger
        // was still down.
        held.remove(event.keyCode)
        onKeyPressed?(held.first)
        // A release sounds only for a press that did — decided at the press,
        // not guessed from the modifiers held at the release. Guessing sounded
        // a release no press had when ⌘ was let go before S, and silenced a
        // letter's release when ⌘ went down while the letter was still held.
        if struck.remove(event.keyCode) != nil {
            onKeyReleased?(event.keyCode)
        }
    }

    /// Forgets every key held, for when their releases will land somewhere
    /// else: focus moving to another view, or the window no longer being the
    /// one that takes keys. Left alone, the highlight stays lit on a key nobody
    /// is holding.
    func releaseAll() {
        held.removeAll()
        struck.removeAll()
        onKeyPressed?(nil)
    }

    // MARK: - Composition

    /// Whether a requested replacement range is one a surface can honour.
    ///
    /// Neither surface has an editable document behind it, only text being
    /// typed against, so the only span either can replace is the composition
    /// it is holding. Silently appending was the wrong answer: an input method
    /// asking to replace two characters got two *extra* ones, and a run's
    /// statistics counted keystrokes the user never made.
    func isReplaceable(_ range: NSRange, markedRange: NSRange) -> Bool {
        // `NSNotFound` is the documented "wherever the insertion point is".
        if range.location == NSNotFound { return true }
        // A zero-length range replaces nothing, which is an insertion however
        // it is located. Requiring it to sit exactly at the cursor rejected
        // every character after the first — the self-test caught it, because
        // AppKit's own committed-text path passes a plain `NSRange()`.
        if range.length == 0 { return true }
        return range == markedRange
    }

    /// Composition in progress. Held, not committed — the engine never sees a
    /// pre-composition keystroke.
    func mark(_ string: Any, selectedRange: NSRange) {
        markedText = Self.text(of: string)
        markedSelection = markedText.isEmpty ? NSRange(location: 0, length: 0) : selectedRange
    }

    /// Committed text. The surface checks the range first, *before* this
    /// clears the composition: the check compares against the composition's
    /// range, and clearing first made that `NSNotFound` — so an input method
    /// committing by naming the range it occupies was refused, and the text
    /// was lost.
    func insert(_ string: Any) {
        clearComposition()
        deliver(Self.text(of: string))
    }

    /// Ends the composition by *accepting* it.
    ///
    /// Apple's contract is that the marked text stops being marked, not that
    /// it disappears. Throwing it away lost text the user had already
    /// accepted — a committed syllable vanishing when the input method
    /// happened to unmark rather than insert. Cancelling is `discard`.
    func unmark() {
        let pending = markedText
        clearComposition()
        deliver(pending)
    }

    /// Ends the composition without committing it, and tells the input
    /// context so its candidate window goes away with it. For a surface being
    /// reset: kept across a reset, a half-typed syllable would commit into
    /// text that is no longer on screen. Answers whether there was one.
    @discardableResult
    func discard(from context: NSTextInputContext?) -> Bool {
        guard !markedText.isEmpty else { return false }
        clearComposition()
        context?.discardMarkedText()
        return true
    }

    private func clearComposition() {
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
    }

    /// Hands one committed string on, one code unit at a time.
    ///
    /// Both commit paths go through here, and that is the point rather than
    /// tidiness: `unmarkText` once had its own copy of this loop, and when the
    /// commit boundary was added to the other it was not added there — so a
    /// composition committed through unmarking went silent.
    private func deliver(_ text: String) {
        // One commit, however many code units it carries. The error tone needs
        // this boundary rather than a stopwatch: an input method committing
        // three wrong characters is one act by the typist and deserves one
        // sound, and no interval in milliseconds can tell that apart from
        // three deliberate keys typed quickly.
        onCommitBegan?()
        // One code unit at a time, because that is the engine's coordinate
        // system. Anything outside the basic plane is refused rather than
        // split: an emoji's two halves fed separately turned one character
        // into two `\u{FFFD}` replacements — two fabricated mistakes.
        for unit in Array(text.utf16) where !(0xD800...0xDFFF).contains(unit) {
            onCharacter?(String(utf16CodeUnits: [unit], count: 1))
        }
    }
}
