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

private let chapterHeading = try! NSRegularExpression(
    pattern: "^(chapter|book|part|volume|prologue|epilogue)\\b[^\\n]{0,80}$|^[ivxlcdm]{1,8}\\.?$",
    options: [.caseInsensitive])

/// "CHAPTER IV", "Chapter 4.", "BOOK TWO", a Roman numeral alone.
func isChapterHeading(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }
    return matches(chapterHeading, trimmed)
}

/// A short line in capitals: a chapter's title under its number, or a title
/// standing alone.
func isCapitalTitle(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count <= 60 else { return false }
    let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
    guard letters.count >= 3, letters.allSatisfy({ !CharacterSet.lowercaseLetters.contains($0) }) else {
        return false
    }
    // "HELP!" alone is somebody shouting, not a title. A title may end in a
    // full stop, which is why that one mark is not counted.
    return !(trimmed.hasSuffix("!") || trimmed.hasSuffix("?"))
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

    // Paragraphs, each kept as its lines so a contents list can be seen for
    // what it is before the lines are joined.
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

    struct Pending {
        var title: String
        var blocks: [BookBlock] = []
        var front: Bool
    }
    var chapters: [Pending] = [Pending(title: "Beginning", front: true)]
    var lastWasHeading = false
    for lines in paragraphs {
        // A contents list: several lines, most of them chapter headings.
        if lines.count >= 3, lines.filter(isChapterHeading).count * 2 > lines.count {
            lastWasHeading = false
            continue
        }
        if lines.count == 1, let line = lines.first {
            if isChapterHeading(line) {
                chapters.append(Pending(title: line, front: false))
                lastWasHeading = true
                continue
            }
            if isCapitalTitle(line) {
                if lastWasHeading, var chapter = chapters.popLast() {
                    // "CHAPTER I." then "THE CYCLONE": one title.
                    chapter.title += " " + line
                    chapters.append(chapter)
                } else {
                    chapters.append(Pending(title: line, front: false))
                }
                lastWasHeading = true
                continue
            }
        }
        lastWasHeading = false
        chapters[chapters.count - 1].blocks.append(.paragraph(lines.joined(separator: " ")))
    }

    let hasChapters = chapters.count > 1
    var sources: [ChapterSource] = []
    for chapter in chapters {
        let (blocks, _) = repairBlocks(chapter.blocks, label: chapter.title)
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
