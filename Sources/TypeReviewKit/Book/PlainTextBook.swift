import Foundation

/// The largest plain-text file read as a book. A novel in plain text is a
/// few megabytes at most; this bounds what one dropped file can cost.
public let maxPlainTextBookBytes = 16 << 20

/// Decodes a text file as a book's text.
///
/// UTF-8 first, with or without a byte-order mark, then UTF-16 when a mark
/// says so. Older Project Gutenberg files are often Latin-1 or Windows-1252,
/// and refusing them would refuse half the public-domain shelf, so a file
/// that is not UTF-8 is read as Windows-1252 — which assigns a character to
/// nearly every byte, so this can only fail on a handful of undefined ones.
public func decodeBookText(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(3))
    if bytes.count >= 2, (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return String(data: data, encoding: .utf16)
    }
    if let text = String(data: data, encoding: .utf8) {
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
    return String(data: data, encoding: .windowsCP1252)
}

private let illustrationMarker = try! NSRegularExpression(pattern: "^\\[(illustration|picture|image)[^\\]]*\\]$", options: [.caseInsensitive])

/// `_took a watch_`: how Project Gutenberg's plain text marks italics. Kept
/// as written, every one is two underscores a child has to find and type.
/// The closing mark may sit inside a word — Alice's King says
/// "_Un_important" — but the opening one starts a word, so `snake_case`
/// is left alone.
private let underscoreEmphasis = try! NSRegularExpression(
    pattern: "(?<![A-Za-z0-9_])_([^_\\s][^_\\n]*?)_")

/// A paragraph's text with italics markers taken off.
func removingEmphasisMarks(_ text: String) -> String {
    guard text.contains("_") else { return text }
    return underscoreEmphasis.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
}

/// The book's text between Project Gutenberg's own markers, and the title and
/// author its header names, when it has one.
func stripGutenberg(_ lines: [Substring]) -> (body: ArraySlice<Substring>, title: String?, author: String?) {
    var start = 0
    var end = lines.count
    var title: String?
    var author: String?
    for (index, line) in lines.enumerated() {
        let upper = line.uppercased()
        if upper.contains("PROJECT GUTENBERG") || upper.contains("PROJECT GUTENBERG'S") {
            if upper.contains("*** START OF") || upper.contains("***START OF") {
                start = index + 1
            } else if upper.contains("*** END OF") || upper.contains("***END OF")
                || upper.hasPrefix("END OF THE PROJECT GUTENBERG") || upper.hasPrefix("END OF PROJECT GUTENBERG")
            {
                end = index
                break
            }
        }
        if index < 60, start == 0 {
            if line.hasPrefix("Title:") {
                title = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Author:") {
                author = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
            }
        }
    }
    if start >= end { start = 0 }
    return (lines[start..<end], title, author)
}

/// A plain-text book read from a file, with the byte limit enforced on what
/// is actually read rather than on what the file's size said.
///
/// One open file, read to at most one byte past the limit: asking for the
/// size first and then reading the whole file let a file that grew in
/// between — or whose size could not be asked — be read without a bound.
public func readPlainTextBook(at url: URL) throws -> BookDraft {
    let data: Data
    do {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        data = try handle.read(upToCount: maxPlainTextBookBytes + 1) ?? Data()
    } catch {
        throw BookImportError.unreadable(error.localizedDescription)
    }
    guard data.count <= maxPlainTextBookBytes else {
        throw BookImportError.tooLarge("over \(maxPlainTextBookBytes >> 20) MB of text")
    }
    guard let text = decodeBookText(data) else {
        throw BookImportError.unreadable("the text encoding is not one this app reads")
    }
    return try readPlainTextBook(text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
}

/// Paragraphs, each kept as its lines so a contents list can be seen for what
/// it is before the lines are joined.
private func collectParagraphs(_ body: ArraySlice<Substring>) -> [[String]] {
    var paragraphs: [[String]] = []
    var current: [String] = []
    for line in body {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if !current.isEmpty { paragraphs.append(current) }
            current = []
        } else {
            current.append(trimmed)
        }
    }
    if !current.isEmpty { paragraphs.append(current) }
    return paragraphs
}

private struct PendingChapter {
    var title: String
    var blocks: [BookBlock] = []
    var front: Bool
}

/// A paragraph's printed lines as one line of text.
private func paragraphText(_ lines: some Sequence<String>) -> String {
    // The glue depends on how the text so far ends, which a short line can
    // share with the line before it: "word-" then "-" ends "--", a dash.
    var pieces: [String] = []
    var tail = ""
    for line in lines {
        if !pieces.isEmpty {
            let glue = wrapGlue(after: tail)
            pieces.append(glue)
            tail += glue
        }
        pieces.append(line)
        tail = String((tail + line).suffix(2))
    }
    return removingEmphasisMarks(pieces.joined())
}

/// The paragraphs sorted into chapters by their headings. The first chapter
/// is what comes before any heading.
private func findChapters(in paragraphs: [[String]]) -> [PendingChapter] {
    var chapters = [PendingChapter(title: "Beginning", front: true)]
    var lastWasHeading = false
    // Whether chapters are numbered ("Chapter I", "XII"). In a book that
    // numbers them, a line in capitals on its own is a title only straight
    // after a number; anywhere else it is text. Oz has "LET DOROTHY GO TO THE
    // CITY OF EMERALDS" written on a slate mid-chapter, and Alice prints
    // "THE MILLENNIUM FULCRUM EDITION 3.0" above its contents: both became
    // chapters. A book with no numbers at all may title its chapters in
    // capitals alone, and there the rule still applies — and a Prologue does
    // not number anything, so it does not turn the rule off.
    let numbersChapters = paragraphs.contains { $0.count <= 3 && isNumberedChapterHeading($0[0]) }
    for lines in paragraphs {
        // A contents list: several lines, most of them chapter headings.
        if lines.count >= 3, lines.filter(isChapterHeading).count * 2 > lines.count {
            lastWasHeading = false
            continue
        }
        // "[Illustration]", "[Illustration: Dorothy and Toto]": where a
        // picture was in the printed book.
        if lines.count <= 3, matches(illustrationMarker, lines.joined(separator: " ")) {
            continue
        }
        // A heading, and the title printed under it: "Chapter I" then
        // "The Cyclone", one paragraph of two short lines. A line under the
        // heading that reads as prose is the chapter's first sentence.
        if lines.count <= 3, isChapterHeading(lines[0]) {
            // A title line the next line continues in lower case is prose:
            // "Mary and I" / "went home."
            var titleLines = 1
            while titleLines < lines.count, isTitleLine(lines[titleLines]),
                titleLines + 1 == lines.count || !startsLowercase(lines[titleLines + 1])
            {
                titleLines += 1
            }
            chapters.append(PendingChapter(title: lines.prefix(titleLines).joined(separator: " "), front: false))
            lastWasHeading = titleLines == lines.count
            if titleLines < lines.count {
                chapters[chapters.count - 1].blocks.append(.paragraph(paragraphText(lines.dropFirst(titleLines))))
            }
            continue
        }
        if lines.count == 1, let line = lines.first {
            if isCapitalTitle(line), lastWasHeading || !numbersChapters {
                if lastWasHeading, var chapter = chapters.popLast() {
                    // "CHAPTER I." then "THE CYCLONE": one title.
                    chapter.title += " " + line
                    chapters.append(chapter)
                } else {
                    chapters.append(PendingChapter(title: line, front: false))
                }
                lastWasHeading = true
                continue
            }
        }
        lastWasHeading = false
        chapters[chapters.count - 1].blocks.append(.paragraph(paragraphText(lines)))
    }
    return chapters
}

/// A plain-text book: paragraphs separated by blank lines, line wrapping
/// joined, chapters found by their headings.
///
/// Text before the first chapter heading is front matter — a title page, a
/// contents list, a preface — and is offered unticked. A book with no headings
/// at all is one chapter of story.
public func readPlainTextBook(_ text: String, fallbackTitle: String) throws -> BookDraft {
    let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let all = normalised.split(separator: "\n", omittingEmptySubsequences: false)
    let (body, gutenbergTitle, gutenbergAuthor) = stripGutenberg(all)

    let chapters = findChapters(in: collectParagraphs(body))
    let hasChapters = chapters.count > 1
    var sources: [ChapterSource] = []
    for chapter in chapters {
        let (blocks, _) = repairBlocks(chapter.blocks, findLabels: false)
        if chapter.front {
            sources.append(
                ChapterSource(
                    title: hasChapters ? "Before the first chapter" : fallbackTitle,
                    kind: hasChapters ? .optional : .story,
                    reason: hasChapters ? "before the first chapter heading" : "the whole text",
                    blocks: blocks))
        } else {
            sources.append(
                ChapterSource(title: chapter.title, kind: .story, reason: "chapter heading", blocks: blocks))
        }
    }
    return try makeDraft(
        title: gutenbergTitle ?? fallbackTitle, author: gutenbergAuthor ?? "", sources: sources)
}
