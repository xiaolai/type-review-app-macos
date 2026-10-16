import XCTest

@testable import TypeReviewKit

/// The stored book, its index and its progress: written by this app, read back
/// strictly, and refused rather than half-loaded.
final class BookModelTests: XCTestCase {
    private func sampleBook() -> Book {
        Book(
            id: "b-1", title: "The Cottage", author: "Anon", importedAt: 1_760_000_000_000,
            chapters: [BookChapter(title: "One", start: 0), BookChapter(title: "Two", start: 2)],
            sentences: ["It rained.", "It poured.", "Then the sun came out."])
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testABookRoundTrips() throws {
        let book = sampleBook()
        XCTAssertEqual(try decodeBook(try encodeBook(book)), book)
    }

    func testTheIndexAndProgressRoundTrip() throws {
        let index = [sampleBook().summary]
        XCTAssertEqual(try decodeBookIndex(try encodeBookIndex(index)), index)
        let progress = BookProgress(sentence: 2, lastRead: 1_760_000_000_500)
        XCTAssertEqual(try decodeBookProgress(try encodeBookProgress(progress)), progress)
    }

    func testEncodingIsStable() throws {
        XCTAssertEqual(try encodeBook(sampleBook()), try encodeBook(sampleBook()))
    }

    func testChapterOfASentence() {
        let book = sampleBook()
        XCTAssertEqual(book.chapterIndex(ofSentence: 0), 0)
        XCTAssertEqual(book.chapterIndex(ofSentence: 1), 0)
        XCTAssertEqual(book.chapterIndex(ofSentence: 2), 1)
        XCTAssertEqual(book.chapterIndex(ofSentence: 99), 1)
    }

    private func mutated(_ change: (inout [String: Any]) -> Void) -> Data {
        var object = try! JSONSerialization.jsonObject(with: try! encodeBook(sampleBook())) as! [String: Any]
        change(&object)
        return json(object)
    }

    func testABookThisAppWouldNotHaveWrittenIsRefused() {
        let cases: [(String, Data)] = [
            ("another format version", mutated { $0["formatVersion"] = 2 }),
            ("an id that names a path", mutated { $0["id"] = "../profile" }),
            ("no sentences", mutated { $0["sentences"] = [String]() }),
            ("an empty sentence", mutated { $0["sentences"] = ["a", "", "b"] }),
            ("a sentence over the cap", mutated { $0["sentences"] = [String(repeating: "a", count: 301), "b", "c"] }),
            ("chapters out of order", mutated { $0["chapters"] = [["title": "a", "start": 0], ["title": "b", "start": 0]] }),
            ("a first chapter not at 0", mutated { $0["chapters"] = [["title": "a", "start": 1]] }),
            ("a chapter past the end", mutated { $0["chapters"] = [["title": "a", "start": 0], ["title": "b", "start": 3]] }),
            ("a boolean for a number", mutated { $0["importedAt"] = true }),
            ("not an object", json([1, 2, 3])),
        ]
        for (name, data) in cases {
            XCTAssertThrowsError(try decodeBook(data), name)
        }
    }

    func testAnIndexWithARepeatedIdIsRefused() throws {
        let entry = sampleBook().summary
        XCTAssertThrowsError(try decodeBookIndex(try encodeBookIndex([entry, entry])))
    }

    func testProgressIsRefusedWhenMalformed() {
        XCTAssertThrowsError(try decodeBookProgress(json(["sentence": -1, "lastRead": 0])))
        XCTAssertThrowsError(try decodeBookProgress(json(["sentence": 1.5, "lastRead": 0])))
        XCTAssertThrowsError(try decodeBookProgress(json(["lastRead": 0])))
    }

    private func draft(_ chapters: [DraftChapter]) -> BookDraft {
        BookDraft(title: "  A Book  ", author: "", chapters: chapters, warnings: [])
    }

    func testMakingABookKeepsOnlyTheTickedChapters() throws {
        let book = try makeBook(
            from: draft([
                DraftChapter(title: "Contents", kind: .skip, reason: "", sentences: ["One. Two."], included: false),
                DraftChapter(title: "One", kind: .story, reason: "", sentences: ["a.", "b."], included: true),
                DraftChapter(title: "Two", kind: .story, reason: "", sentences: ["c."], included: true),
            ]), id: "b-2", importedAt: 1)
        XCTAssertEqual(book.title, "A Book")
        XCTAssertEqual(book.sentences, ["a.", "b.", "c."])
        XCTAssertEqual(book.chapters, [BookChapter(title: "One", start: 0), BookChapter(title: "Two", start: 2)])
        XCTAssertEqual(try decodeBook(try encodeBook(book)), book)
    }

    func testALongChapterTitleIsCutSoTheBookStillOpens() throws {
        let long = String(repeating: "A very long chapter title ", count: 20)
        let book = try makeBook(
            from: draft([DraftChapter(title: long, kind: .story, reason: "", sentences: ["a."], included: true)]),
            id: "b-3", importedAt: 1)
        XCTAssertLessThanOrEqual(book.chapters[0].title.utf16.count, 200)
        XCTAssertEqual(try decodeBook(try encodeBook(book)), book)
    }

    func testMakingABookChecksItsLimitsWithAMessage() {
        XCTAssertThrowsError(
            try makeBook(
                from: draft([DraftChapter(title: "a", kind: .story, reason: "", sentences: ["a."], included: false)]),
                id: "b", importedAt: 1)
        ) { XCTAssertEqual($0 as? BookImportError, .nothingIncluded) }

        let many = Array(repeating: "a.", count: maxBookSentences + 1)
        XCTAssertThrowsError(
            try makeBook(
                from: draft([DraftChapter(title: "a", kind: .story, reason: "", sentences: many, included: true)]),
                id: "b", importedAt: 1)
        ) { error in
            guard case .tooLarge = error as? BookImportError else { return XCTFail("\(error)") }
            XCTAssertNotNil((error as? BookImportError)?.errorDescription)
        }

        let long = Array(repeating: String(repeating: "a", count: 300), count: maxBookCharacters / 300 + 1)
        XCTAssertThrowsError(
            try makeBook(
                from: draft([DraftChapter(title: "a", kind: .story, reason: "", sentences: long, included: true)]),
                id: "b", importedAt: 1))
    }

    func testBookIds() {
        XCTAssertTrue(isValidBookId("5F1C2D3E-AAAA-4BBB-8CCC-000000000001"))
        XCTAssertTrue(isValidBookId("shelf-wizard-of-oz"))
        for bad in ["", "../x", "a/b", "a b", "é", String(repeating: "a", count: 65)] {
            XCTAssertFalse(isValidBookId(bad), bad)
        }
    }
}
