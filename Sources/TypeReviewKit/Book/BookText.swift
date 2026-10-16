import Foundation
import NaturalLanguage

/// The longest unit a book is typed in. A sentence longer than this is split
/// at its strongest break, so one keystroke run never asks a child to hold
/// more than a few lines.
public let maxBookSentenceChars = 300

/// How long a raw sentence may be before it is cut at spaces on its way to
/// `sanitize`. Comfortably under `maxPassageChars`, so the cap there — which
/// throws away whatever follows it — can never fire on book text.
let maxRawSentenceUnits = 4_000

/// What a format reader hands the shared pipeline.
public enum BookBlockKind: String, Sendable, Equatable {
    /// A chapter or section title. Shown, never typed.
    case heading
    /// Prose, one line.
    case paragraph
    /// Lines the markup says are verse. Each line is its own unit.
    case verse
    /// A scene break. A pause on screen, never typed.
    case sceneBreak
}

public struct BookBlock: Sendable, Equatable {
    public let kind: BookBlockKind
    /// One line for everything but verse.
    public let lines: [String]

    public init(kind: BookBlockKind, lines: [String]) {
        self.kind = kind
        self.lines = lines
    }

    public static func paragraph(_ text: String) -> BookBlock { BookBlock(kind: .paragraph, lines: [text]) }
    public static func heading(_ text: String) -> BookBlock { BookBlock(kind: .heading, lines: [text]) }
    public static let sceneBreak = BookBlock(kind: .sceneBreak, lines: [])
}

/// What splitting a run of blocks produced, and what it had to throw away.
public struct SentenceSplit: Sendable, Equatable {
    /// Cleaned units, in order. Never empty strings, never longer than
    /// `maxBookSentenceChars` UTF-16 units, never without a letter or digit.
    public var sentences: [String] = []
    /// Characters `sanitize` dropped because they have no ASCII form.
    public var droppedChars = 0
    /// Invisible formatting characters removed before cleaning. Not counted
    /// as lost: nobody could have typed them.
    public var invisibleRemoved = 0
    /// Units that had letters as written and none once cleaned: what is left
    /// of a line in another script. A unit with no letter even as written —
    /// a `*  *  *` ornament, a stray `..."` — is dropped without being
    /// counted, because nothing was lost from it.
    public var punctuationOnlyDropped = 0
    /// Pieces `sanitize` truncated. Always zero; kept so tests can say so.
    public var truncatedPieces = 0
    /// Characters of story text as written, before cleaning.
    public var rawCharacters = 0

    public init() {}

    mutating func absorb(_ other: SentenceSplit) {
        sentences += other.sentences
        droppedChars += other.droppedChars
        invisibleRemoved += other.invisibleRemoved
        punctuationOnlyDropped += other.punctuationOnlyDropped
        truncatedPieces += other.truncatedPieces
        rawCharacters += other.rawCharacters
    }
}

// MARK: - Invisible formatting

/// Characters that format text without being part of it.
///
/// None of these is in `asciiFoldTable`, so `sanitize` would drop each one
/// and count it as a lost character — and an EPUB full of soft hyphens would
/// report thousands of characters removed that nobody was ever shown. The
/// fold table is pinned to the website and is not the place to change that.
private let invisibleScalars: Set<UInt32> = [
    0x00AD,  // soft hyphen
    0x034F,  // combining grapheme joiner
    0x180E,  // Mongolian vowel separator
    0x200B, 0x200C, 0x200D, 0x200E, 0x200F,  // zero-width space, joiners, direction marks
    0x2060,  // word joiner
    0xFEFF,  // zero-width no-break space, or a stray byte-order mark
]

/// The text without invisible formatting, and how many characters went.
public func stripInvisibleFormatting(_ text: String) -> (text: String, removed: Int) {
    var removed = 0
    var out = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if invisibleScalars.contains(scalar.value) {
            removed += 1
        } else {
            out.append(scalar)
        }
    }
    return (String(out), removed)
}

// MARK: - Splitting

/// Splits prose into raw sentences with `NLTokenizer`.
///
/// Raw, because the tokenizer reads curly quotes and dashes better than the
/// ASCII they fold to, and the merges below need to see which way a
/// quotation mark faces.
func rawSentences(_ text: String) -> [String] {
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    var out: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        let piece = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        if !piece.isEmpty { out.append(piece) }
        return true
    }
    return out
}

func startsLowercase(_ text: String) -> Bool {
    guard let first = text.unicodeScalars.first else { return false }
    return CharacterSet.lowercaseLetters.contains(first)
}

/// Opening quotation marks not yet closed. Curly quotes say which way they
/// face; straight double quotes count by parity.
func unclosedQuotes(_ text: String) -> Int {
    var curly = 0
    var straight = 0
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x201C: curly += 1
        case 0x201D: curly -= 1
        case 0x22: straight += 1
        default: break
        }
    }
    return max(curly, 0) + straight % 2
}

private let abbreviationAtEnd = try! NSRegularExpression(
    pattern: "\\b(Mr|Mrs|Ms|Dr|St|Mt|Jr|Sr|Prof|Capt|Col|Gen|Lt|Rev|Sgt|Hon)\\.$")

/// Ends in a title such as `Mr.`, which `NLTokenizer` can take for the end of
/// a sentence when the name is on the next printed line.
func endsWithAbbreviation(_ text: String) -> Bool {
    matches(abbreviationAtEnd, text)
}

private let speechVerb = try! NSRegularExpression(
    pattern: "(?i)\\b(said|says|say|asked|asks|ask|replied|replies|cried|cries|shouted|shouts|"
        + "whispered|whispers|yelled|yells|called|calls|answered|answers|added|adds|demanded|"
        + "demands|exclaimed|exclaims|muttered|mutters|murmured|murmurs|snapped|snaps|screamed|"
        + "screams|growled|growls|insisted|insists|repeated|repeats|continued|continues|offered|"
        + "suggested|admitted|agreed|lied|laughed|breathed|gasped|protested|pleaded|warned|"
        + "wondered|ventured|interrupted|retorted|groaned|hissed|roared|bellowed|stammered|"
        + "squeaked|sobbed|sighed|sighs|told|tells|began|begins|went on)\\b")
private let closesQuotation = try! NSRegularExpression(pattern: "[?!,\\u2014-][\"\\u201D'\\u2019]$")

/// `"Where?" Sam asked.` — the tag that `NLTokenizer` splits off after the
/// question mark is not a sentence of its own.
func isDialogueTag(_ text: String, after previous: String) -> Bool {
    guard matches(closesQuotation, previous) else { return false }
    let words = text.split(separator: " ").count
    return words <= 8 && !text.contains("\"") && !text.contains("\u{201C}") && matches(speechVerb, text)
}

func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
    expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
}

/// Joins the pieces `NLTokenizer` gets wrong in fiction back together.
///
/// Four repairs, each measured on real novels: a piece starting lower case
/// continues the one before it ("said Ron."); a short speech-verb piece after
/// a closing `?"` is that quotation's tag; a piece ending `Mr.` runs on; and
/// while a quotation is open the next piece joins it, as long as the result
/// still fits in one unit.
func mergeSentencePieces(_ pieces: [String]) -> [String] {
    var units: [String] = []
    for piece in pieces {
        guard let previous = units.last else {
            units.append(piece)
            continue
        }
        let joined = previous + " " + piece
        if startsLowercase(piece) || endsWithAbbreviation(previous) || isDialogueTag(piece, after: previous) {
            units[units.count - 1] = joined
        } else if unclosedQuotes(previous) > 0, joined.utf16.count <= maxBookSentenceChars {
            units[units.count - 1] = joined
        } else {
            units.append(piece)
        }
    }
    return units
}

/// Cuts raw text at spaces so that no piece reaches `sanitize`'s cap.
func cutForCleaning(_ text: String) -> [String] {
    guard text.utf16.count > maxRawSentenceUnits else { return [text] }
    var out: [String] = []
    var rest = Substring(text)
    while rest.utf16.count > maxRawSentenceUnits {
        let limit = rest.utf16.index(rest.startIndex, offsetBy: maxRawSentenceUnits)
        let cut = rest[..<limit].lastIndex(of: " ") ?? limit
        let head = rest[..<cut]
        if !head.isEmpty { out.append(String(head)) }
        rest = rest[cut...].drop(while: { $0 == " " })
    }
    if !rest.isEmpty { out.append(String(rest)) }
    return out
}

/// Splits a cleaned unit longer than `maxBookSentenceChars` at its strongest
/// break: `;` or `:`, then a spaced or doubled dash, then `,`, then between
/// words, and only as a last resort mid-word. Every piece fits.
public func splitLongSentence(_ text: String) -> [String] {
    var out: [String] = []
    var rest = text
    while rest.utf16.count > maxBookSentenceChars {
        let units = Array(rest.utf16)
        let limit = maxBookSentenceChars - 1
        var cut = -1
        outer: for breaks in [[0x3B, 0x3A], [0x2D], [0x2C], [0x20]] as [[UInt16]] {
            var index = limit
            while index > limit / 3 {
                let unit = units[index]
                if breaks.contains(unit) {
                    // A hyphen is a break only as " - " or "--", which is what
                    // a dash folds to; inside a word it is part of the word.
                    let isDash = unit != 0x2D || units[index - 1] == 0x20 || units[index - 1] == 0x2D
                    if isDash { cut = index; break outer }
                }
                index -= 1
            }
        }
        let headEnd = cut >= 0 ? cut + 1 : limit
        let head = String(utf16CodeUnits: Array(units[..<headEnd]), count: headEnd)
            .trimmingCharacters(in: .whitespaces)
        let tail = String(utf16CodeUnits: Array(units[headEnd...]), count: units.count - headEnd)
            .trimmingCharacters(in: .whitespaces)
        if !head.isEmpty { out.append(head) }
        rest = tail
    }
    if !rest.isEmpty { out.append(rest) }
    return out
}

private func hasLetterOrDigit(_ text: String) -> Bool {
    text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
}

/// Cleans one raw unit and adds what survives to `split`.
private func addCleaned(_ raw: String, to split: inout SentenceSplit) {
    for piece in cutForCleaning(raw) {
        let cleaned = sanitize(piece)
        split.droppedChars += cleaned.droppedChars
        if cleaned.truncated { split.truncatedPieces += 1 }
        guard !cleaned.text.isEmpty else { continue }
        guard hasLetterOrDigit(cleaned.text) else {
            // Counted only when cleaning took the letters. Alice's
            // `*  *  *` lines were reported as "part of this book is in
            // another language", which sends a parent looking for a
            // language that is not there.
            if hasLetterOrDigit(piece) { split.punctuationOnlyDropped += 1 }
            continue
        }
        split.sentences += splitLongSentence(cleaned.text)
    }
}

/// Turns blocks into typeable units.
///
/// Headings and scene breaks produce nothing. Each paragraph is split into
/// sentences on its raw text, the pieces are merged back where the tokenizer
/// went wrong, and only then is each unit cleaned — `sanitize` cuts at 5,000
/// characters, and must never meet a whole chapter. Verse keeps its lines.
public func splitIntoSentences(_ blocks: [BookBlock]) -> SentenceSplit {
    var split = SentenceSplit()
    for block in blocks {
        switch block.kind {
        case .heading, .sceneBreak:
            continue
        case .verse:
            for line in block.lines {
                let (visible, removed) = stripInvisibleFormatting(line)
                split.invisibleRemoved += removed
                split.rawCharacters += visible.count
                addCleaned(visible, to: &split)
            }
        case .paragraph:
            let (visible, removed) = stripInvisibleFormatting(block.lines.joined(separator: " "))
            split.invisibleRemoved += removed
            split.rawCharacters += visible.count
            for unit in mergeSentencePieces(rawSentences(visible)) {
                addCleaned(unit, to: &split)
            }
        }
    }
    return split
}
