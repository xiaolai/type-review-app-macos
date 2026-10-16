import Foundation

/// The stored book format. A file of another version is refused, not guessed at.
public let bookFormatVersion = 1
/// How many books the shelf holds.
public let maxBooks = 50
/// The largest book, in characters of cleaned text. *Outlander*, about
/// 300,000 words, is under half of it.
public let maxBookCharacters = 3_000_000
public let maxBookSentences = 100_000
let maxBookTitleLength = 200

/// Where a chapter begins in the book's one list of sentences.
public struct BookChapter: Sendable, Equatable {
    public let title: String
    /// Index of the chapter's first sentence.
    public let start: Int

    public init(title: String, start: Int) {
        self.title = title
        self.start = start
    }
}

/// A book as imported: split once, at import, and never again.
///
/// Splitting is fixed here rather than redone on load because `NLTokenizer`
/// can split differently after a macOS update, and the child's place is a
/// sentence index. One flat list keeps that place a single integer.
public struct Book: Sendable, Equatable {
    public let id: String
    public let title: String
    public let author: String
    public let importedAt: Double
    public let chapters: [BookChapter]
    public let sentences: [String]

    public init(
        id: String, title: String, author: String, importedAt: Double, chapters: [BookChapter],
        sentences: [String]
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.importedAt = importedAt
        self.chapters = chapters
        self.sentences = sentences
    }

    /// The chapter holding a sentence. The last chapter whose start is at or
    /// before it; chapters are validated to start at 0 and to increase.
    public func chapterIndex(ofSentence sentence: Int) -> Int {
        var low = 0
        var high = chapters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if chapters[mid].start <= sentence { low = mid } else { high = mid - 1 }
        }
        return low
    }

    public var characterCount: Int { sentences.reduce(0) { $0 + $1.utf16.count } }

    public var summary: BookSummary {
        BookSummary(
            id: id, title: title, author: author, sentenceCount: sentences.count, importedAt: importedAt)
    }
}

/// One row of the shelf's index: enough to list a book without loading it.
public struct BookSummary: Sendable, Equatable {
    public let id: String
    public let title: String
    public let author: String
    public let sentenceCount: Int
    public let importedAt: Double

    public init(id: String, title: String, author: String, sentenceCount: Int, importedAt: Double) {
        self.id = id
        self.title = title
        self.author = author
        self.sentenceCount = sentenceCount
        self.importedAt = importedAt
    }
}

/// Where the child is in a book: the next sentence to type.
public struct BookProgress: Sendable, Equatable {
    public let sentence: Int
    public let lastRead: Double

    public init(sentence: Int, lastRead: Double) {
        self.sentence = sentence
        self.lastRead = lastRead
    }
}

/// Builds the book the parent ticked.
///
/// Limits are checked here, at import, with a message — not at load time,
/// where the only thing left to do with an oversized book is fail to open it.
public func makeBook(from draft: BookDraft, id: String, importedAt: Double) throws -> Book {
    var chapters: [BookChapter] = []
    var sentences: [String] = []
    for chapter in draft.chapters where chapter.included && !chapter.sentences.isEmpty {
        // Cut to the length the codec accepts: a longer title saved fine and
        // then refused the book every time it was opened.
        let title = prefixByCodeUnits(chapter.title.trimmingCharacters(in: .whitespacesAndNewlines), maxBookTitleLength)
        chapters.append(BookChapter(title: title, start: sentences.count))
        sentences += chapter.sentences
    }
    guard !sentences.isEmpty else { throw BookImportError.nothingIncluded }
    guard sentences.count <= maxBookSentences else {
        throw BookImportError.tooLarge("more than \(maxBookSentences) sentences")
    }
    let title = prefixByCodeUnits(
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines), maxBookTitleLength)
    let author = prefixByCodeUnits(
        draft.author.trimmingCharacters(in: .whitespacesAndNewlines), maxBookTitleLength)
    let book = Book(
        id: id, title: title.isEmpty ? "Untitled" : title, author: author, importedAt: importedAt,
        chapters: chapters, sentences: sentences)
    guard book.characterCount <= maxBookCharacters else {
        throw BookImportError.tooLarge("more than \(maxBookCharacters) characters")
    }
    return book
}

// MARK: - Codecs

public enum BookCodecError: Error, Equatable, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        }
    }
}

/// A book id: letters, digits and `-`, at most 64. Ids name files, so
/// anything that could reach outside the folder is refused on the way in.
public func isValidBookId(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 64
        && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
}

private func object(_ data: Data) throws -> [String: Any] {
    guard let value = try? JSONSerialization.jsonObject(with: data), let object = value as? [String: Any] else {
        throw BookCodecError.invalid("not a JSON object")
    }
    return object
}

private func string(_ object: [String: Any], _ key: String, max: Int = maxBookTitleLength) throws -> String {
    guard let value = object[key] as? String, value.utf16.count <= max else {
        throw BookCodecError.invalid("\(key) is missing or too long")
    }
    return value
}

private func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue == number.doubleValue.rounded(), number.doubleValue >= 0,
        number.doubleValue <= 1e15
    else { return nil }
    return number.intValue
}

private func timestamp(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, number.doubleValue >= 0
    else { return nil }
    return number.doubleValue
}

private func encode(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

public func encodeBook(_ book: Book) throws -> Data {
    try encode([
        "formatVersion": bookFormatVersion,
        "id": book.id,
        "title": book.title,
        "author": book.author,
        "importedAt": book.importedAt,
        "chapters": book.chapters.map { ["title": $0.title, "start": $0.start] as [String: Any] },
        "sentences": book.sentences,
    ] as [String: Any])
}

/// Reads a stored book, refusing anything this app would not have written.
///
/// Strict, unlike the reading log: a book is the child's place in a story,
/// and a book that loaded half-right would put them somewhere they never
/// were. A file that fails here is left alone on disk and reported.
public func decodeBook(_ data: Data) throws -> Book {
    let object = try object(data)
    guard integer(object["formatVersion"]) == bookFormatVersion else {
        throw BookCodecError.invalid("format version is not \(bookFormatVersion)")
    }
    let id = try string(object, "id", max: 64)
    guard isValidBookId(id) else { throw BookCodecError.invalid("id is not valid") }
    let title = try string(object, "title")
    let author = try string(object, "author")
    guard let importedAt = timestamp(object["importedAt"]) else {
        throw BookCodecError.invalid("importedAt is missing")
    }
    guard let rawSentences = object["sentences"] as? [Any], !rawSentences.isEmpty,
        rawSentences.count <= maxBookSentences
    else { throw BookCodecError.invalid("sentences are missing or too many") }
    var sentences: [String] = []
    sentences.reserveCapacity(rawSentences.count)
    var characters = 0
    for raw in rawSentences {
        guard let sentence = raw as? String, !sentence.isEmpty, sentence.utf16.count <= maxBookSentenceChars
        else { throw BookCodecError.invalid("a sentence is empty or too long") }
        characters += sentence.utf16.count
        sentences.append(sentence)
    }
    guard characters <= maxBookCharacters else { throw BookCodecError.invalid("too many characters") }
    guard let rawChapters = object["chapters"] as? [Any], !rawChapters.isEmpty else {
        throw BookCodecError.invalid("chapters are missing")
    }
    var chapters: [BookChapter] = []
    for raw in rawChapters {
        guard let entry = raw as? [String: Any], let start = integer(entry["start"]),
            let title = entry["title"] as? String, title.utf16.count <= maxBookTitleLength
        else { throw BookCodecError.invalid("a chapter is malformed") }
        // Starts at 0 and strictly increasing, inside the book: what
        // `chapterIndex(ofSentence:)` relies on.
        let expectedFloor = chapters.last.map { $0.start + 1 } ?? 0
        guard start < sentences.count, chapters.isEmpty ? start == 0 : start >= expectedFloor else {
            throw BookCodecError.invalid("chapter starts are out of order")
        }
        chapters.append(BookChapter(title: title, start: start))
    }
    return Book(
        id: id, title: title, author: author, importedAt: importedAt, chapters: chapters,
        sentences: sentences)
}

public func encodeBookIndex(_ books: [BookSummary]) throws -> Data {
    try encode([
        "formatVersion": bookFormatVersion,
        "books": books.map {
            [
                "id": $0.id, "title": $0.title, "author": $0.author,
                "sentenceCount": $0.sentenceCount, "importedAt": $0.importedAt,
            ] as [String: Any]
        },
    ] as [String: Any])
}

public func decodeBookIndex(_ data: Data) throws -> [BookSummary] {
    let object = try object(data)
    guard integer(object["formatVersion"]) == bookFormatVersion else {
        throw BookCodecError.invalid("format version is not \(bookFormatVersion)")
    }
    guard let rawBooks = object["books"] as? [Any], rawBooks.count <= maxBooks else {
        throw BookCodecError.invalid("books are missing or too many")
    }
    var books: [BookSummary] = []
    var seen = Set<String>()
    for raw in rawBooks {
        guard let entry = raw as? [String: Any] else { throw BookCodecError.invalid("an entry is malformed") }
        let id = try string(entry, "id", max: 64)
        guard isValidBookId(id), seen.insert(id).inserted else {
            throw BookCodecError.invalid("an id is invalid or repeated")
        }
        guard let count = integer(entry["sentenceCount"]), count > 0, count <= maxBookSentences,
            let importedAt = timestamp(entry["importedAt"])
        else { throw BookCodecError.invalid("an entry is malformed") }
        books.append(
            BookSummary(
                id: id, title: try string(entry, "title"), author: try string(entry, "author"),
                sentenceCount: count, importedAt: importedAt))
    }
    return books
}

public func encodeBookProgress(_ progress: BookProgress) throws -> Data {
    try encode(["sentence": progress.sentence, "lastRead": progress.lastRead] as [String: Any])
}

public func decodeBookProgress(_ data: Data) throws -> BookProgress {
    let object = try object(data)
    guard let sentence = integer(object["sentence"]), sentence <= maxBookSentences,
        let lastRead = timestamp(object["lastRead"])
    else { throw BookCodecError.invalid("progress is malformed") }
    return BookProgress(sentence: sentence, lastRead: lastRead)
}
