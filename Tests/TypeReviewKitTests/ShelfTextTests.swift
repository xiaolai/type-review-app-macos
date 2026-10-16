import NaturalLanguage
import XCTest

@testable import TypeReviewKit

/// The starter shelf: the books that ship with the app, held to the corpus
/// rules every other bundled text is held to.
///
/// Its own gate, because `EnglishTextTests` names `quotes.json` and
/// `EarlyTextTests` names `early.json`: a third corpus inherits neither and
/// would ship unread. A shelf book goes to every user without a parent
/// reviewing it, so nothing the review sheet would have caught may be in it.
final class ShelfTextTests: XCTestCase {
    private func books() throws -> [Book] {
        XCTAssertEqual(BundledShelf.loadFailures, [], "the shelf did not load cleanly")
        let books = BundledShelf.books
        XCTAssertGreaterThanOrEqual(books.count, 2, "the shelf looks empty")
        XCTAssertEqual(books.map(\.id), BundledShelf.entries.map(\.id), "a listed book is missing")
        return books
    }

    /// Every file in the folder is listed, so a book cannot ship by being
    /// copied in without the claim that it may.
    func testEveryShelfFileIsListed() throws {
        let folder = try XCTUnwrap(resourceBundle.url(forResource: "Resources/shelf", withExtension: nil))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") && $0 != "index.json" }.sorted()
        XCTAssertEqual(files, BundledShelf.entries.map { "\($0.id).json" }.sorted())
    }

    /// Public domain, by the claim and by its date: published before 1929 is
    /// public domain in the United States, and these authors died long
    /// enough ago for the rest of the world. A book whose term varies by
    /// country — Peter Pan carries a perpetual royalty in the United
    /// Kingdom — is not on the shelf.
    func testEveryBookIsPublicDomain() throws {
        for entry in BundledShelf.entries {
            XCTAssertEqual(entry.license, "Public domain", entry.id)
            XCTAssertLessThan(entry.published, 1929, entry.id)
            XCTAssertTrue(entry.source.hasPrefix("https://www.gutenberg.org/ebooks/"), entry.id)
            XCTAssertTrue(entry.id.hasPrefix("shelf-") && isValidBookId(entry.id), entry.id)
        }
        let books = try books()
        for (book, entry) in zip(books, BundledShelf.entries) {
            XCTAssertEqual(book.title, entry.title, entry.id)
            XCTAssertEqual(book.author, entry.author, entry.id)
        }
    }

    /// A chapter at a time: one sentence is too short to call, and a whole
    /// book carries a stray passage in another language without noticing it.
    func testEveryChapterIsEnglish() throws {
        let recognizer = NLLanguageRecognizer()
        for book in try books() {
            for (index, chapter) in book.chapters.enumerated() {
                let end = index + 1 < book.chapters.count ? book.chapters[index + 1].start : book.sentences.count
                recognizer.reset()
                recognizer.processString(book.sentences[chapter.start..<end].joined(separator: " "))
                XCTAssertEqual(recognizer.dominantLanguage, .english, "\(book.id): \(chapter.title)")
            }
        }
    }

    /// Typeable as stored: ASCII, nothing for cleaning to take, no empty or
    /// oversized unit, no italics underscores, no heading typed as a
    /// sentence.
    func testEverySentenceIsTypeableAsStored() throws {
        for book in try books() {
            for sentence in book.sentences {
                XCTAssertTrue(sentence.utf16.allSatisfy { $0 >= 0x20 && $0 < 0x7F }, "\(book.id): \(sentence)")
                let cleaned = sanitize(sentence)
                XCTAssertEqual(cleaned.text, sentence, "\(book.id): cleaning changes \(sentence)")
                XCTAssertEqual(cleaned.droppedChars, 0, "\(book.id): \(sentence)")
                XCTAssertFalse(sentence.isEmpty, book.id)
                XCTAssertLessThanOrEqual(sentence.utf16.count, maxBookSentenceChars, "\(book.id): \(sentence)")
                XCTAssertFalse(sentence.contains("_"), "\(book.id): \(sentence)")
                XCTAssertFalse(isChapterHeading(sentence), "\(book.id): a heading typed: \(sentence)")
                XCTAssertFalse(sentence.localizedCaseInsensitiveContains("gutenberg"), "\(book.id): \(sentence)")
            }
        }
    }

    /// The files are what `make shelf` writes, byte for byte, so a hand edit
    /// shows up as a difference rather than as a book that half-loads.
    func testTheFilesAreAsTheEncoderWritesThem() throws {
        for book in try books() {
            let url = try XCTUnwrap(resourceBundle.url(forResource: "Resources/shelf/\(book.id)", withExtension: "json"))
            XCTAssertEqual(try Data(contentsOf: url), try encodeBook(book), book.id)
            XCTAssertEqual(book.importedAt, 0, "\(book.id): written with a clock")
        }
    }
}
