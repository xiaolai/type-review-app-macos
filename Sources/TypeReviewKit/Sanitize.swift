import Foundation

/// The longest passage the app will hand a typist in one run.
public let maxPassageChars = 5_000

public struct SanitizeResult: Sendable, Equatable {
    public let text: String
    /// Code units dropped — control characters and surrogate halves.
    public let droppedChars: Int
    public let truncated: Bool
}

/// Cleans arbitrary text into something typeable.
///
/// Three jobs. Control characters and surrogate halves are dropped, because
/// the engine indexes by UTF-16 code unit and refuses non-BMP text outright.
/// Whitespace is normalised so a paragraph break survives as `\n\n` and every
/// other run collapses to a single space — a passage wrapped at 72 columns in
/// its source file should not make the typist press space at the same places.
/// And the result is capped, cutting at a word or paragraph boundary rather
/// than mid-word.
public func sanitize(_ input: String, preserveLayout: Bool = false) -> SanitizeResult {
    var dropped = 0
    var kept: [UInt16] = []
    kept.reserveCapacity(input.utf16.count)

    for unit in input.utf16 {
        if (0xD800...0xDFFF).contains(unit) {
            dropped += 1
            continue
        }
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
        kept.append(unit)
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
