import Foundation
import NaturalLanguage

/// Whether a part of the source is story. Decides only where its tick box
/// starts; the parent has the final say in the review sheet.
public enum ChapterKind: String, Sendable, Equatable {
    /// Typed unless the parent unticks it.
    case story
    /// Front or back matter worth offering: a preface, an author's note.
    /// Listed, unticked.
    case optional
    /// Almost certainly not story: a cover, a contents page, an index.
    /// Listed, unticked, so a wrong guess can be undone.
    case skip
}

/// One part of a book as a format reader found it, before splitting.
public struct ChapterSource: Sendable, Equatable {
    public let title: String
    public let kind: ChapterKind
    /// Why it got that kind, in words the review sheet can show.
    public let reason: String
    public let blocks: [BookBlock]

    public init(title: String, kind: ChapterKind, reason: String, blocks: [BookBlock]) {
        self.title = title
        self.kind = kind
        self.reason = reason
        self.blocks = blocks
    }
}

/// One row of the review sheet.
public struct DraftChapter: Sendable, Equatable {
    public let title: String
    public let kind: ChapterKind
    public let reason: String
    public let sentences: [String]
    /// Whether it will be imported. Starts true for story only.
    public var included: Bool

    /// Words as typing speed counts them: characters ÷ 5.
    public var words: Int { sentences.reduce(0) { $0 + $1.utf16.count } / Int(charsPerWord) }
    public var firstLine: String { sentences.first ?? "" }
}

/// Something about a book the parent should know before importing it.
public enum BookWarning: Sendable, Equatable {
    /// The story text does not read as English. `language` is the
    /// recogniser's BCP 47 code.
    case notEnglish(language: String)
    /// Part of the book is in another script and was left out.
    case mixedLanguage(linesLeftOut: Int, charactersDropped: Int)
    /// Data tables were dropped from these many places.
    case tablesDropped(Int)
    /// Files inside the book that could not be read, by name.
    case unreadableFiles([String])

    /// The sentence the review sheet shows.
    public var message: String {
        switch self {
        case .notEnglish:
            return "This book doesn't look like English."
        case .mixedLanguage(let lines, let characters):
            return lines > 0
                ? "Part of this book is in another language; \(lines) lines were left out."
                : "Part of this book is in another language; \(characters) characters were left out."
        case .tablesDropped(let count):
            return count == 1 ? "1 table was left out." : "\(count) tables were left out."
        case .unreadableFiles(let names):
            return "Some parts could not be read: " + names.joined(separator: ", ")
        }
    }
}

/// A book ready for the review sheet: split, cleaned, not yet saved.
public struct BookDraft: Sendable, Equatable {
    public var title: String
    public var author: String
    public var chapters: [DraftChapter]
    public var warnings: [BookWarning]

    /// Characters ÷ 5 over the ticked chapters.
    public var includedWords: Int {
        chapters.filter(\.included).reduce(0) { $0 + $1.words }
    }

    public var includedSentences: Int {
        chapters.filter(\.included).reduce(0) { $0 + $1.sentences.count }
    }
}

/// Why a book cannot be imported. Each has its own message, because "could
/// not import" tells a parent nothing about what to do next.
public enum BookImportError: Error, Equatable, LocalizedError {
    case copyProtected
    case fixedLayout
    case picturesOnly
    case noText
    case unreadable(String)
    case tooLarge(String)
    case tooManyBooks
    case nothingIncluded

    public var errorDescription: String? {
        switch self {
        case .copyProtected: return "This book is copy-protected, so its text can't be read."
        case .fixedLayout: return "This is a picture-book layout, which can't be typed line by line."
        case .picturesOnly: return "This book's pages are pictures, so there is no text to type."
        case .noText: return "No story text was found in this book."
        case .unreadable(let reason): return "This file can't be read as a book: \(reason)."
        case .tooLarge(let limit): return "This book is too large: \(limit)."
        case .tooManyBooks: return "There are already \(maxBooks) books. Remove one to add another."
        case .nothingIncluded: return "No chapters are ticked."
        }
    }
}

/// How much of the story text the language check reads. Enough to decide,
/// little enough to stay quick on a long book.
private let languageSampleCharacters = 30_000

/// The recogniser's best guess for the story text as written.
///
/// As written, not as cleaned: cleaning removes other scripts, and a check
/// after it could not see them. `dc:language` is not consulted — on the books
/// measured it said English for 211 that were not.
func detectLanguage(_ sources: [ChapterSource]) -> String? {
    var sample = ""
    for source in sources where source.kind == .story {
        for block in source.blocks where block.kind == .paragraph || block.kind == .verse {
            sample += block.lines.joined(separator: " ") + " "
            if sample.count >= languageSampleCharacters { break }
        }
        if sample.count >= languageSampleCharacters { break }
    }
    guard !sample.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let recogniser = NLLanguageRecognizer()
    recogniser.processString(String(sample.prefix(languageSampleCharacters)))
    return recogniser.dominantLanguage?.rawValue
}

/// Splits every part, collects the warnings, and ticks the story.
///
/// Throws `noText` when no story part has anything to type, so a reader never
/// hands the review sheet an empty book.
public func makeDraft(
    title: String, author: String, sources: [ChapterSource], tablesDropped: Int = 0,
    unreadableFiles: [String] = [], imagesSeen: Int = 0
) throws -> BookDraft {
    var chapters: [DraftChapter] = []
    var total = SentenceSplit()
    for source in sources {
        let split = splitIntoSentences(source.blocks)
        guard !split.sentences.isEmpty else { continue }
        if source.kind == .story { total.absorb(split) }
        chapters.append(
            DraftChapter(
                title: source.title, kind: source.kind, reason: source.reason,
                sentences: split.sentences, included: source.kind == .story))
    }
    guard chapters.contains(where: { $0.kind == .story }) else {
        throw imagesSeen > 0 ? BookImportError.picturesOnly : BookImportError.noText
    }

    var warnings: [BookWarning] = []
    if let language = detectLanguage(sources), language != "en" {
        warnings.append(.notEnglish(language: language))
    }
    let dropRate = Double(total.droppedChars) / Double(max(total.rawCharacters, 1))
    if total.punctuationOnlyDropped > 0 || dropRate > 0.001 {
        warnings.append(
            .mixedLanguage(linesLeftOut: total.punctuationOnlyDropped, charactersDropped: total.droppedChars))
    }
    if tablesDropped > 0 { warnings.append(.tablesDropped(tablesDropped)) }
    if !unreadableFiles.isEmpty { warnings.append(.unreadableFiles(unreadableFiles)) }

    return BookDraft(title: title, author: author, chapters: chapters, warnings: warnings)
}

/// "About N sittings of 20 minutes at your typing speed".
///
/// `wpm` is the child's speed so far; before the first sitting there is none,
/// and 15 is assumed — a fair pace for a young typist, and a pessimistic
/// estimate is the kinder surprise.
public func estimatedSittings(words: Int, wpm: Double?, minutesPerSitting: Double = 20) -> Int {
    let speed = max(wpm ?? 15, 1)
    let minutes = Double(words) / speed
    return max(1, Int((minutes / minutesPerSitting).rounded(.up)))
}
