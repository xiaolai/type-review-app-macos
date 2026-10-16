import Foundation
import TypeReviewKit

// Adds one public-domain book to the starter shelf: reads a plain-text file
// the way Import does, keeps the parts the reader takes for story, and writes
// `Sources/TypeReviewKit/Resources/shelf/<id>.json` with its line in
// `index.json`. Run by `make shelf`; see the Makefile for the sources.
//
// It refuses a book that draws any warning — not English, characters lost to
// cleaning — because a shelf book ships to every user unreviewed, and
// `ShelfTextTests` would refuse it afterwards anyway.
//
//     make-shelf <id> <file.txt> <source URL> <year first published> <shelf dir>

struct Entry: Codable {
    let id: String
    let title: String
    let author: String
    let source: String
    let license: String
    let published: Int
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-shelf: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 6, let published = Int(arguments[4]) else {
    fail("usage: make-shelf <id> <file.txt> <source URL> <year first published> <shelf dir>")
}
let (id, file, source, shelf) = (arguments[1], arguments[2], arguments[3], URL(fileURLWithPath: arguments[5]))
guard id.hasPrefix("shelf-"), isValidBookId(id) else { fail("\(id): a shelf id is shelf-<name>") }
guard published < 1929 else { fail("\(published): only books first published before 1929 are on the shelf") }
guard let data = FileManager.default.contents(atPath: file), let text = decodeBookText(data) else {
    fail("\(file): cannot be read")
}

let draft: BookDraft
do { draft = try readPlainTextBook(text, fallbackTitle: id) } catch { fail("\(file): \(error)") }
guard draft.warnings.isEmpty else {
    fail("\(file): " + draft.warnings.map(\.message).joined(separator: "; "))
}
let book: Book
// importedAt 0, so the same text always writes the same bytes.
do { book = try makeBook(from: draft, id: id, importedAt: 0) } catch { fail("\(file): \(error)") }

do {
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    let indexURL = shelf.appendingPathComponent("index.json")
    // Empty only when there is no index yet. One that cannot be read or
    // decoded stops the run before either file is written, or adding a book
    // would write an index naming that book alone. Absence is what the read
    // reports, not `fileExists`, which also says no for a file it may not see.
    var entries: [Entry] = []
    let existing: Data?
    do {
        existing = try Data(contentsOf: indexURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        existing = nil
    }
    if let existing { entries = try JSONDecoder().decode([Entry].self, from: existing) }
    entries.removeAll { $0.id == id }
    entries.append(
        Entry(
            id: id, title: book.title, author: book.author, source: source,
            license: "Public domain", published: published))
    entries.sort { $0.id < $1.id }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let index = try encoder.encode(entries) + Data("\n".utf8)
    try encodeBook(book).write(to: shelf.appendingPathComponent("\(id).json"), options: .atomic)
    try index.write(to: indexURL, options: .atomic)
} catch {
    fail("writing \(id): \(error)")
}
let skipped = draft.chapters.filter { !$0.included }.map(\.title)
print(
    "\(id): \"\(book.title)\" by \(book.author) — \(book.chapters.count) chapters, "
        + "\(book.sentences.count) sentences; left out: \(skipped.isEmpty ? "nothing" : skipped.joined(separator: ", "))")
