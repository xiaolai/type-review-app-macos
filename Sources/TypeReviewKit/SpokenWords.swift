
/// A word the typist has just finished, ready to be read aloud.
public struct SpokenWord: Sendable, Equatable {
    /// Trimmed, exactly as it should be spoken.
    public let text: String
    /// Where it sits in the expected passage, in UTF-16 code units.
    public let range: Range<Int>

    public init(text: String, range: Range<Int>) {
        self.text = text
        self.range = range
    }
}

/// The word the cursor has just finished, if any.
///
/// **Indexed by UTF-16 code unit**, for the reason `TextInput` gives: Swift's
/// `Character` is a grapheme cluster, so `"e\u{301}fg"` is 3 Characters and 4
/// code units, and a range computed in Characters would address the wrong
/// entries in `statuses` after any combining mark.
///
/// A word is finished when the cursor passes the last code unit of its
/// *trimmed* extent — so `cat!` is spoken at the `t` rather than held back
/// until the `!`. It is offered only when every unit of that extent is
/// `.correct` right now: a letter that was mistyped and then put right still
/// counts, because with stop-on-error enabled the alternative is silence
/// exactly where the teaching moment is.
///
/// Nothing here knows about speech, provenance or settings. It splits, trims,
/// applies the shape rule, and answers with a range.
///
/// Answers `nil` when `statuses` cannot be describing `expected` — a caller
/// that has them out of step gets silence rather than a guess or a crash,
/// which is this feature's safe direction.
public func wordJustFinished(
    expected: String, statuses: [CharStatus], oldPos: Int, newPos: Int
) -> SpokenWord? {
    let units = expected.utf16
    let count = units.count
    guard statuses.count == count, oldPos >= 0, newPos > oldPos, newPos <= count else {
        return nil
    }

    // Backwards from the new cursor: the word just finished is the last one
    // whose end was passed. In practice the cursor moves one unit per
    // keystroke, and further only when `TextInput` steps over newlines — which
    // are separators, so no whole word can be jumped.
    var end = newPos
    var endIndex = units.index(units.startIndex, offsetBy: newPos)
    while end > oldPos {
        if let word = word(endingAt: end, endIndex: endIndex, units: units, statuses: statuses) {
            return word
        }
        end -= 1
        endIndex = units.index(before: endIndex)
    }
    return nil
}

/// The word whose trimmed extent ends exactly at `end`, if there is one.
///
/// Scoped to the token around the cursor rather than to the passage. The
/// question is about one position, and answering it by tokenising five
/// thousand code units on every keystroke would put the cost of the passage's
/// length onto the typing path.
private func word(
    endingAt end: Int, endIndex: String.UTF16View.Index, units: String.UTF16View,
    statuses: [CharStatus]
) -> SpokenWord? {
    guard end > 0 else { return nil }
    // The unit the cursor just passed has to belong to a token at all.
    guard !isSeparator(units[units.index(before: endIndex)]) else { return nil }

    // Backwards to the token's start, and no further than a word can be.
    var start = end - 1
    var startIndex = units.index(before: endIndex)
    while start > 0 {
        let previous = units.index(before: startIndex)
        if isSeparator(units[previous]) { break }
        guard end - start < maxSpokenTokenUnits else { return nil }
        startIndex = previous
        start -= 1
    }

    // Forwards to the token's stop, under the same bound.
    var stop = end
    var stopIndex = endIndex
    while stopIndex != units.endIndex, !isSeparator(units[stopIndex]) {
        guard stop - start < maxSpokenTokenUnits else { return nil }
        stopIndex = units.index(after: stopIndex)
        stop += 1
    }

    // The raw token, now bounded by `maxSpokenTokenUnits` rather than by the
    // passage — which is what keeps the work per keystroke constant.
    var token: [UInt16] = []
    token.reserveCapacity(stop - start)
    var walk = startIndex
    while walk != stopIndex {
        token.append(units[walk])
        walk = units.index(after: walk)
    }

    // Punctuation and symbols come off both ends: quotes, brackets, the full
    // stop that ends a sentence. Digits do not, so `42nd` keeps its digits and
    // is refused below rather than trimmed down to `nd`.
    var low = 0
    var high = token.count
    while low < high, isTrimmable(token[low]) { low += 1 }
    while high > low, isTrimmable(token[high - 1]) { high -= 1 }
    guard low < high, start + high == end, isWordShaped(token[low..<high]) else { return nil }

    let range = (start + low)..<end
    for position in range where statuses[position] != .correct { return nil }
    let spoken = Array(token[low..<high])
    return SpokenWord(
        text: String(utf16CodeUnits: spoken, count: spoken.count), range: range)
}

/// Whether a trimmed token is shaped like a word.
///
/// Letters, the marks that belong to them, and the two joiners that live
/// *inside* an English word. Anything else — a digit, a comma, a slash — means
/// this was never a word, so `hello,world` and `42nd` are both refused rather
/// than salvaged into `hello` and `nd`.
///
/// At least one letter, or a token of nothing but combining marks would
/// qualify. Its own function because it is the one step here that carries no
/// offset arithmetic: everything else in `word(endingAt:)` is index work whose
/// invariants are easier to check when they sit together.
private func isWordShaped(_ token: ArraySlice<UInt16>) -> Bool {
    var hasLetter = false
    for unit in token {
        if isLetter(unit) {
            hasLetter = true
        } else if !isCombiningMark(unit), !isJoiner(unit) {
            return false
        }
    }
    return hasLetter
}

/// The longest token this will consider a word, in UTF-16 code units.
///
/// A bound on work as much as on vocabulary. The scan around the cursor is the
/// length of the token it lands in, so without this a passage with no
/// whitespace in it — Chinese prose, a pasted base64 blob — costs its whole
/// length on every keystroke, and the single token it eventually finishes is
/// then read aloud in full. `sanitize` caps a passage at 5,000 units, so that
/// is the size of the hole.
///
/// It bounds the *token scan*, which is what was unbounded. It does not claim
/// anything about `String.UTF16View`'s own index arithmetic, which builds its
/// breadcrumbs once per string and is not this function's to control.
///
/// 64 clears every real word: the 45-letter English record and the 63-letter
/// German one both fit.
public let maxSpokenTokenUnits = 64

/// Speaks each finished word once per run.
///
/// The rule is one utterance per (run, character range). Without it, a
/// backspace over the last letter and a retype crosses the same boundary
/// again — the same word finished twice, which is one event and not two.
/// `"cat cat"` still fires twice, because the two occupy different ranges.
public struct SpokenWordTracker {
    private var spoken: Set<Range<Int>> = []

    public init() {}

    /// Forgets the run. Called when a new passage arrives, which is what makes
    /// the deduplication per-run rather than for ever.
    public mutating func startPassage() {
        spoken.removeAll()
    }

    /// The word to read aloud for this keystroke, if any.
    public mutating func wordToSpeak(
        expected: String, statuses: [CharStatus], oldPos: Int, newPos: Int
    ) -> SpokenWord? {
        guard
            let word = wordJustFinished(
                expected: expected, statuses: statuses, oldPos: oldPos, newPos: newPos)
        else { return nil }
        guard spoken.insert(word.range).inserted else { return nil }
        return word
    }
}

// MARK: - Character classes
//
// One UTF-16 unit is one Unicode scalar here: `TextInput` refuses surrogate
// pairs outright, so the range arithmetic stays in the Basic Multilingual
// Plane. A surrogate half reaching this from somewhere else answers false to
// every question below, which disqualifies its token — the safe direction.

private func scalar(_ unit: UInt16) -> Unicode.Scalar? {
    Unicode.Scalar(unit)
}

/// Token boundaries. Every whitespace, not only the space: the passage
/// sanitiser leaves `\n\n` at paragraph breaks, and pasted text can carry a
/// non-breaking space.
private func isSeparator(_ unit: UInt16) -> Bool {
    guard let scalar = scalar(unit) else { return false }
    return scalar.properties.isWhitespace
}

private func isTrimmable(_ unit: UInt16) -> Bool {
    guard let scalar = scalar(unit) else { return false }
    switch scalar.properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
        .initialPunctuation, .finalPunctuation, .otherPunctuation,
        .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
        return true
    default:
        return false
    }
}

private func isLetter(_ unit: UInt16) -> Bool {
    guard let scalar = scalar(unit) else { return false }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
        return true
    default:
        return false
    }
}

/// The accent on a decomposed `é`. Part of the word it sits on, and not a
/// letter in its own right — so it is allowed through the shape rule without
/// being enough to make a token a word.
private func isCombiningMark(_ unit: UInt16) -> Bool {
    guard let scalar = scalar(unit) else { return false }
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark:
        return true
    default:
        return false
    }
}

/// The apostrophe and the hyphen, the two marks that live *inside* an English
/// word. Both spellings of the apostrophe: U+2019 is the same character doing
/// the same job, and it is what pasted prose actually contains.
private func isJoiner(_ unit: UInt16) -> Bool {
    unit == 0x0027 || unit == 0x2019 || unit == 0x002D
}
