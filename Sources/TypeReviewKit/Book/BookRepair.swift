import Foundation

/// What `repairBlocks` changed in one file, for the import report and tests.
public struct RepairReport: Sendable, Equatable {
    public var mojibakeBlocks = 0
    public var joinedParagraphs = 0
    public var lineMode = false
    public var labelsMadeHeadings = 0
    public var numberParagraphsDropped = 0
    public var gutenbergCuts = 0

    public init() {}
}

// MARK: - Mojibake

/// Windows-1252's characters in 0x80...0x9F, by the byte they stand for.
private let windows1252: [UInt32: UInt8] = [
    0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87,
    0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91,
    0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98,
    0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
]

/// Undoes UTF-8 that was decoded as Windows-1252 somewhere upstream: "â€™"
/// for "’", which cleaning would then fold to "aEURTM".
///
/// One run at a time — a lead byte and the continuation bytes it needs — so
/// genuine characters in the same paragraph are left alone. Measured on an
/// omnibus where a whole-paragraph round trip failed because a real curly
/// quote sat next to the broken ones. A run that does not decode stays as it
/// was. An orphan "â€" is "”": that character is E2 80 9D, and 0x9D has no
/// Windows-1252 character, so a converter that went through 1252 dropped it.
///
/// Nil when there was nothing to repair.
public func repairMojibake(_ text: String) -> String? {
    // A run can only start at a lead byte read as Latin-1, so text without
    // one has nothing to repair. Checking a few lead bytes by name missed
    // "Å“" and "â‚¬", which the decoder below handles.
    guard text.unicodeScalars.contains(where: { (0xC2...0xF4).contains($0.value) }) else { return nil }
    func byte(_ scalar: Unicode.Scalar) -> UInt8? {
        if let mapped = windows1252[scalar.value] { return mapped }
        return scalar.value < 256 ? UInt8(scalar.value) : nil
    }
    let scalars = Array(text.unicodeScalars)
    var out = String.UnicodeScalarView()
    var changed = false
    var index = 0
    while index < scalars.count {
        let scalar = scalars[index]
        if (0xC2...0xF4).contains(scalar.value) {
            let needed = scalar.value >= 0xF0 ? 3 : scalar.value >= 0xE0 ? 2 : 1
            var bytes = [UInt8(scalar.value)]
            var next = index + 1
            while next < scalars.count, bytes.count <= needed, let value = byte(scalars[next]),
                (0x80...0xBF).contains(value)
            {
                bytes.append(value)
                next += 1
            }
            if bytes.count == needed + 1, let decoded = String(bytes: bytes, encoding: .utf8) {
                out.append(contentsOf: decoded.unicodeScalars)
                changed = true
                index = next
                continue
            }
            if bytes == [0xE2, 0x80] {
                out.append("\u{201D}")
                changed = true
                index = next
                continue
            }
        }
        out.append(scalar)
        index += 1
    }
    return changed ? String(out) : nil
}

// MARK: - Paragraph structure

/// Ends like the end of a sentence, looking past closing quotes and brackets.
///
/// `;`, `:` and a dash do not count: a printed line ends on them in the
/// middle of a sentence all the time, and counting them left a line-per-
/// paragraph book in fragments.
func endsSentence(_ text: String) -> Bool {
    var trimmed = Substring(text.trimmingCharacters(in: .whitespaces))
    while let last = trimmed.last, "\"'”’)]»*".contains(last) { trimmed = trimmed.dropLast() }
    guard let last = trimmed.last, ".!?…".contains(last) else { return false }
    return !endsWithAbbreviation(String(trimmed))
}

private let numberOnly = try! NSRegularExpression(pattern: "^[\\[(]?\\d{1,4}[\\])]?\\.?$")

private func containsGutenberg(_ text: String) -> Bool {
    text.range(of: "PROJECT GUTENBERG", options: .caseInsensitive) != nil
}

/// Repairs one file's blocks before they are split into sentences.
///
/// - `label` is what the table of contents calls the file, if anything. A
///   short paragraph at the top that says exactly that is its title.
/// - `findLabels` is false when the reader has already decided what is a
///   heading. The plain-text reader has: it keeps "LET DOROTHY GO TO THE
///   CITY OF EMERALDS" as prose on purpose, and taking a second guess here
///   removed it.
public func repairBlocks(
    _ input: [BookBlock], label: String = "", findLabels: Bool = true
) -> (blocks: [BookBlock], report: RepairReport) {
    var report = RepairReport()
    var blocks = repairEncoding(input, &report)
    cutGutenbergMatter(&blocks, &report)
    dropNumberParagraphs(&blocks, &report)
    if findLabels { markLeadingLabels(&blocks, label: label, &report) }
    return (joinBrokenParagraphs(blocks, &report), report)
}

private func repairEncoding(_ blocks: [BookBlock], _ report: inout RepairReport) -> [BookBlock] {
    blocks.map { block -> BookBlock in
        let fixed = block.lines.map(repairMojibake)
        guard fixed.contains(where: { $0 != nil }) else { return block }
        report.mojibakeBlocks += 1
        return BookBlock(kind: block.kind, lines: zip(block.lines, fixed).map { $1 ?? $0 })
    }
}

/// Project Gutenberg's own matter, when it sits inside a chapter file.
private func cutGutenbergMatter(_ blocks: inout [BookBlock], _ report: inout RepairReport) {
    if let start = blocks.lastIndex(where: {
        let text = $0.lines.joined(separator: " ")
        return containsGutenberg(text) && text.range(of: "START OF TH", options: .caseInsensitive) != nil
    }) {
        blocks.removeFirst(start + 1)
        report.gutenbergCuts += 1
    }
    if let end = blocks.firstIndex(where: {
        let text = $0.lines.joined(separator: " ")
        return containsGutenberg(text)
            && (text.range(of: "END OF TH", options: .caseInsensitive) != nil || text.hasPrefix("End of"))
    }) {
        blocks.removeSubrange(end...)
        report.gutenbergCuts += 1
    }
}

/// Paragraphs that are only a number: page numbers, or a chapter's number.
private func dropNumberParagraphs(_ blocks: inout [BookBlock], _ report: inout RepairReport) {
    blocks.removeAll { block in
        guard block.kind == .paragraph,
            matches(numberOnly, block.lines[0].trimmingCharacters(in: .whitespaces))
        else { return false }
        report.numberParagraphsDropped += 1
        return true
    }
}

/// A short label at the top of a file is a title, not a sentence. What counts
/// as one is the plain-text reader's policy, so a line it kept as prose —
/// "HELP!", "Part of me wanted to leave." — is not removed here.
private func markLeadingLabels(_ blocks: inout [BookBlock], label: String, _ report: inout RepairReport) {
    var looked = 0
    for index in blocks.indices where looked < 3 {
        if blocks[index].kind == .heading { continue }
        looked += 1
        guard blocks[index].kind == .paragraph else { continue }
        let text = blocks[index].lines[0].trimmingCharacters(in: .whitespaces)
        guard text.count <= 60 else { break }
        let tocLabel = !label.isEmpty && text.caseInsensitiveCompare(label) == .orderedSame
        let shape = chapterHeadingShape(text)
        // A label is its own paragraph. A run-on title or a line in capitals
        // that the next paragraph continues in lower case is a printed line of
        // prose: "Book One Was the Best" / "of all the summers". "Chapter 1"
        // stays a label whatever follows it.
        let continues = blocks[(index + 1)...].first(where: { $0.kind == .paragraph }).map {
            startsLowercase($0.lines[0].trimmingCharacters(in: .whitespaces))
        } ?? false
        let isLabel = tocLabel || shape == .complete || (!continues && (shape == .runOn || isCapitalTitle(text)))
        guard isLabel else { break }
        blocks[index] = .heading(text)
        report.labelsMadeHeadings += 1
    }
}

/// A paragraph that starts lower case continues the one before it: the
/// source put each printed line in a paragraph of its own. When most of a
/// file's paragraphs end mid-sentence, the whole file is like that, and a
/// paragraph joins its predecessor until one ends a sentence.
///
/// The pieces of one paragraph are gathered and joined once: joining as it
/// went copied the paragraph so far for every line, which a long run of
/// fragments made quadratic.
private func joinBrokenParagraphs(_ blocks: [BookBlock], _ report: inout RepairReport) -> [BookBlock] {
    let paragraphs = blocks.filter { $0.kind == .paragraph }.map { $0.lines[0] }
    let open = paragraphs.filter { !endsSentence($0) }.count
    report.lineMode = paragraphs.count >= 10 && open * 10 > paragraphs.count * 4
    var out: [BookBlock] = []
    var pieces: [String] = []
    func flush() {
        guard !pieces.isEmpty else { return }
        out.append(.paragraph(pieces.joined()))
        pieces = []
    }
    for block in blocks {
        guard block.kind == .paragraph else {
            flush()
            out.append(block)
            continue
        }
        let after = block.lines[0].trimmingCharacters(in: .whitespaces)
        if let before = pieces.last,
            endsWithAbbreviation(before) || startsLowercase(after) || (report.lineMode && !endsSentence(before))
        {
            pieces.append(wrapGlue(after: before))
            pieces.append(after)
            report.joinedParagraphs += 1
            continue
        }
        flush()
        pieces = [after]
    }
    flush()
    return out
}
