import Foundation

/// The longest passage the app will hand a typist in one run.
public let maxPassageChars = 5_000

public struct SanitizeResult: Sendable, Equatable {
    public let text: String
    /// Code units dropped because they have no ASCII form, or are control
    /// characters. An accent taken off its letter is a conversion rather than a
    /// drop, and is not counted.
    public let droppedChars: Int
    public let truncated: Bool
}

/// Cleans arbitrary text into something typeable on an English keyboard.
///
/// Four jobs. The text is brought into ASCII, because this is English typing
/// practice and a letter the keyboard cannot produce is a mistake the typist is
/// made to commit: accents come off their letters, typographic quotes and dashes
/// become the keys that stand for them, and `asciiFoldTable` covers the letters
/// and symbols decomposition leaves whole. Whatever still has no ASCII form —
/// Chinese, Cyrillic, Greek, emoji — is dropped and counted, as control
/// characters are. Whitespace is normalised so a paragraph break survives as
/// `\n\n` and every other run collapses to a single space — a passage wrapped at
/// 72 columns in its source file should not make the typist press space at the
/// same places. And the result is capped, cutting at a word or paragraph
/// boundary rather than mid-word.
///
/// Mirrored by the website's `sanitize.ts` and pinned to it by the corpus
/// vectors. The fold table and the order of the steps are both part of what
/// has to match.
public func sanitize(_ input: String, preserveLayout: Bool = false) -> SanitizeResult {
    var dropped = 0
    // Compatibility decomposition before anything is judged, so the loop sees a
    // letter and its accent separately, three dots rather than an ellipsis, and
    // a plain space rather than a non-breaking one.
    let decomposed = input.decomposedStringWithCompatibilityMapping
    var kept: [UInt16] = []
    kept.reserveCapacity(decomposed.utf16.count)

    for unit in decomposed.utf16 {
        // Whitespace survives this pass; normalisation below decides its fate.
        if unit == 0x09 || unit == 0x0A || unit == 0x0B || unit == 0x0C || unit == 0x0D
            || unit == 0x20
        {
            kept.append(unit)
            continue
        }
        if unit < 0x20 || unit == 0x7F {
            dropped += 1
            continue
        }
        if unit < 0x7F {
            kept.append(unit)
            continue
        }
        // The accent decomposition split off its letter. Removing it is the
        // conversion to a plain letter, not the loss of a character, so it is not
        // counted: "cafe" typed from "café" has nothing missing to report.
        if (0x0300...0x036F).contains(unit) { continue }
        if let replacement = asciiFold[unit] {
            kept.append(contentsOf: replacement)
            continue
        }
        // No ASCII form. Surrogate halves land here too, which is why they no
        // longer need a branch of their own.
        dropped += 1
    }

    var text = String(utf16CodeUnits: kept, count: kept.count)
    // Line endings to LF first, so the run-collapsing below counts newlines
    // rather than carriage returns.
    text = text.replacingOccurrences(of: "\r\n", with: "\n")
    text = text.replacingOccurrences(of: "\r", with: "\n")

    if !preserveLayout {
        text = collapseWhitespaceRuns(text)
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)

    var truncated = false
    if text.utf16.count > maxPassageChars {
        truncated = true
        var units = Array(text.utf16.prefix(maxPassageChars))
        // Prefer a boundary near the cap so the cut does not land mid-word;
        // 80% is far enough back to always find one in prose and close enough
        // that the passage keeps its intended length.
        let newline = units.lastIndex(of: 0x0A)
        let space = units.lastIndex(of: 0x20)
        if let boundary = [newline, space].compactMap({ $0 }).max(),
            boundary > Int(Double(maxPassageChars) * 0.8)
        {
            units = Array(units.prefix(boundary))
        }
        text = String(utf16CodeUnits: units, count: units.count)
    }

    return SanitizeResult(text: text, droppedChars: dropped, truncated: truncated)
}

/// Collapses every whitespace run to `\n\n` if it spans a blank line, or a
/// single space otherwise.
private func collapseWhitespaceRuns(_ text: String) -> String {
    var out: [UInt16] = []
    var run: [UInt16] = []
    let whitespace: Set<UInt16> = [0x20, 0x09, 0x0B, 0x0C, 0x0A]

    func flush() {
        guard !run.isEmpty else { return }
        let newlines = run.filter { $0 == 0x0A }.count
        if newlines >= 2 {
            out.append(0x0A)
            out.append(0x0A)
        } else {
            out.append(0x20)
        }
        run.removeAll()
    }

    for unit in text.utf16 {
        if whitespace.contains(unit) {
            run.append(unit)
        } else {
            flush()
            out.append(unit)
        }
    }
    flush()
    return String(utf16CodeUnits: out, count: out.count)
}

/// What decomposition cannot reach, by hand.
///
/// NFKD already does most of the work: it splits an accented letter into the
/// letter and its accent, turns an ellipsis into three dots, a trademark sign
/// into TM, a ligature into its letters, a non-breaking space into a space, and
/// a vulgar fraction into digits either side of a fraction slash. These are the
/// characters it leaves whole, because Unicode gives them no compatibility
/// decomposition.
///
/// Mirrored line for line in the website's `ASCII_FOLD_TABLE`, and a vector case
/// runs every entry through both implementations, so a line added to one side
/// and not the other fails the suite.
let asciiFoldTable: [(UInt16, String)] = [
    // Quotation marks and apostrophes, including guillemets and primes.
    (0x2018, "'"),  // LEFT SINGLE QUOTATION MARK
    (0x2019, "'"),  // RIGHT SINGLE QUOTATION MARK
    (0x201A, "'"),  // SINGLE LOW-9 QUOTATION MARK
    (0x201B, "'"),  // SINGLE HIGH-REVERSED-9 QUOTATION MARK
    (0x2032, "'"),  // PRIME
    (0x2035, "'"),  // REVERSED PRIME
    (0x2039, "'"),  // SINGLE LEFT-POINTING ANGLE QUOTATION MARK
    (0x203A, "'"),  // SINGLE RIGHT-POINTING ANGLE QUOTATION MARK
    (0x201C, "\""),  // LEFT DOUBLE QUOTATION MARK
    (0x201D, "\""),  // RIGHT DOUBLE QUOTATION MARK
    (0x201E, "\""),  // DOUBLE LOW-9 QUOTATION MARK
    (0x201F, "\""),  // DOUBLE HIGH-REVERSED-9 QUOTATION MARK
    (0x00AB, "\""),  // LEFT-POINTING DOUBLE ANGLE QUOTATION MARK
    (0x00BB, "\""),  // RIGHT-POINTING DOUBLE ANGLE QUOTATION MARK
    // Dashes, minus and bullets. One hyphen each, so a passage keeps its length.
    (0x2010, "-"),  // HYPHEN
    (0x2012, "-"),  // FIGURE DASH
    (0x2013, "-"),  // EN DASH
    (0x2014, "-"),  // EM DASH
    (0x2015, "-"),  // HORIZONTAL BAR
    (0x2212, "-"),  // MINUS SIGN
    (0x2043, "-"),  // HYPHEN BULLET
    (0x2022, "-"),  // BULLET
    (0x2023, "-"),  // TRIANGULAR BULLET
    (0x25E6, "-"),  // WHITE BULLET
    (0x00B7, "-"),  // MIDDLE DOT
    // Slashes, including the one NFKD puts inside a vulgar fraction.
    (0x2044, "/"),  // FRACTION SLASH
    (0x2215, "/"),  // DIVISION SLASH
    // Line and paragraph separators, as a word processor pastes them.
    (0x2028, "\n"),  // LINE SEPARATOR
    (0x2029, "\n\n"),  // PARAGRAPH SEPARATOR
    // Letters that are not an ASCII letter with an accent, so NFKD leaves them whole.
    (0x00DF, "ss"),  // LATIN SMALL LETTER SHARP S
    (0x00E6, "ae"),  // LATIN SMALL LETTER AE
    (0x00C6, "AE"),  // LATIN CAPITAL LETTER AE
    (0x0153, "oe"),  // LATIN SMALL LIGATURE OE
    (0x0152, "OE"),  // LATIN CAPITAL LIGATURE OE
    (0x00F8, "o"),  // LATIN SMALL LETTER O WITH STROKE
    (0x00D8, "O"),  // LATIN CAPITAL LETTER O WITH STROKE
    (0x0142, "l"),  // LATIN SMALL LETTER L WITH STROKE
    (0x0141, "L"),  // LATIN CAPITAL LETTER L WITH STROKE
    (0x0111, "d"),  // LATIN SMALL LETTER D WITH STROKE
    (0x0110, "D"),  // LATIN CAPITAL LETTER D WITH STROKE
    (0x00F0, "d"),  // LATIN SMALL LETTER ETH
    (0x00D0, "D"),  // LATIN CAPITAL LETTER ETH
    (0x00FE, "th"),  // LATIN SMALL LETTER THORN
    (0x00DE, "Th"),  // LATIN CAPITAL LETTER THORN
    (0x0131, "i"),  // LATIN SMALL LETTER DOTLESS I
    // Symbols common enough in prose to be worth spelling out.
    (0x00A9, "(c)"),  // COPYRIGHT SIGN
    (0x00AE, "(R)"),  // REGISTERED SIGN
    (0x20AC, "EUR"),  // EURO SIGN
    (0x00A3, "GBP"),  // POUND SIGN
    (0x00A5, "JPY"),  // YEN SIGN
    (0x00A2, "c"),  // CENT SIGN
    (0x00B0, "deg"),  // DEGREE SIGN
    (0x00D7, "x"),  // MULTIPLICATION SIGN
    (0x00F7, "/"),  // DIVISION SIGN
    (0x00B1, "+/-"),  // PLUS-MINUS SIGN
]

/// The table, keyed for the loop. `uniqueKeysWithValues` traps on a repeated
/// code point, which is the loud failure a duplicate line deserves.
let asciiFold: [UInt16: [UInt16]] = Dictionary(
    uniqueKeysWithValues: asciiFoldTable.map { ($0.0, Array($0.1.utf16)) })
