import XCTest

@testable import TypeReviewKit

/// Plain-text books: a Project Gutenberg file trimmed to two chapters, and
/// text with no headings at all.
final class PlainTextBookTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/text"),
            let data = try? Data(contentsOf: url), let text = decodeBookText(data)
        else { throw VectorUnavailable(reason: "fixture \(name).txt is missing or unreadable") }
        return text
    }

    func testAGutenbergTextKeepsOnlyTheBookAndFindsItsChapters() throws {
        let draft = try readPlainTextBook(try fixture("wizard-of-oz-gutenberg"), fallbackTitle: "oz")
        XCTAssertEqual(draft.title, "The Wonderful Wizard of Oz", "from the Gutenberg header")
        XCTAssertEqual(draft.author, "L. Frank Baum")

        let story = draft.chapters.filter { $0.kind == .story }
        XCTAssertEqual(story.map(\.title), ["Chapter I The Cyclone", "Chapter II The Council with the Munchkins"])
        XCTAssertTrue(story.allSatisfy(\.included))
        XCTAssertTrue(
            story[0].sentences[0].hasPrefix("Dorothy lived in the midst of the great Kansas prairies"),
            story[0].sentences[0])

        // The front matter — title, dedication, contents, introduction — is
        // offered, unticked.
        let front = draft.chapters.filter { $0.kind != .story }
        XCTAssertEqual(front.count, 1)
        XCTAssertFalse(front[0].included)

        let all = draft.chapters.flatMap(\.sentences)
        for sentence in all {
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains("Gutenberg"), "licence text: \(sentence)")
            XCTAssertFalse(sentence.contains("[Illustration"), "an illustration marker: \(sentence)")
            XCTAssertFalse(sentence.hasPrefix("Chapter "), "a heading typed: \(sentence)")
            XCTAssertLessThanOrEqual(sentence.utf16.count, maxBookSentenceChars)
            XCTAssertFalse(sentence.isEmpty)
        }
        // "farmer's", from a curly apostrophe: folded, and nothing reported lost.
        XCTAssertTrue(all.contains { $0.contains("farmer's wife") })
        XCTAssertFalse(draft.warnings.contains { if case .mixedLanguage = $0 { return true } else { return false } })
        XCTAssertFalse(draft.warnings.contains { if case .notEnglish = $0 { return true } else { return false } })
    }

    func testTextWithNoHeadingsIsOneChapterOfStory() throws {
        let text = """
            Once upon a time there was a little cottage
            at the edge of a wood.

            In it lived an old man and his cat. They were
            very happy together.
            """
        let draft = try readPlainTextBook(text, fallbackTitle: "The Cottage")
        XCTAssertEqual(draft.title, "The Cottage")
        XCTAssertEqual(draft.chapters.count, 1)
        XCTAssertEqual(draft.chapters[0].kind, .story)
        XCTAssertEqual(
            draft.chapters[0].sentences,
            [
                "Once upon a time there was a little cottage at the edge of a wood.",
                "In it lived an old man and his cat.", "They were very happy together.",
            ])
    }

    func testChapterHeadingsInTheirCommonShapes() {
        for heading in ["CHAPTER IV", "Chapter 4.", "BOOK TWO", "XII", "Part One", "Prologue"] {
            XCTAssertTrue(isChapterHeading(heading), heading)
        }
        for line in ["The chapter was over.", "Bookshelves lined the walls and every one was full of dust."] {
            XCTAssertFalse(isChapterHeading(line), line)
        }
    }

    func testAContentsListIsNotTyped() throws {
        let text = """
            Contents

            Chapter I. The Cyclone
            Chapter II. The Council
            Chapter III. The Scarecrow

            Chapter I

            The wind blew hard.
            """
        let draft = try readPlainTextBook(text, fallbackTitle: "x")
        let typed = draft.chapters.filter(\.included).flatMap(\.sentences)
        XCTAssertEqual(typed, ["The wind blew hard."])
    }

    func testCapitalsAwayFromAChapterNumberAreText() throws {
        // Alice's edition line above its contents, and the words Oz has
        // written on a slate in the middle of a chapter.
        let text = """
            THE MILLENNIUM FULCRUM EDITION 3.0

            CHAPTER I.
            THE CYCLONE

            At once the cap changed to a slate, on which was written:

            "LET DOROTHY GO TO THE CITY OF EMERALDS"

            The little old woman took the slate from her nose.
            """
        let draft = try readPlainTextBook(text, fallbackTitle: "x")
        let story = draft.chapters.filter { $0.kind == .story }
        XCTAssertEqual(story.map(\.title), ["CHAPTER I. THE CYCLONE"], "the number's title, and nothing else")
        XCTAssertTrue(story[0].sentences.contains("\"LET DOROTHY GO TO THE CITY OF EMERALDS\""), "\(story[0].sentences)")
        XCTAssertFalse(draft.chapters.filter(\.included).flatMap(\.sentences).contains { $0.contains("FULCRUM") })
    }

    func testItalicUnderscoresAreNotTyped() {
        XCTAssertEqual(
            removingEmphasisMarks("the Rabbit actually _took a watch out of its waistcoat-pocket_, and _then_ ran"),
            "the Rabbit actually took a watch out of its waistcoat-pocket, and then ran")
        XCTAssertEqual(removingEmphasisMarks("\"_Un_important, your Majesty\""), "\"Unimportant, your Majesty\"")
        XCTAssertEqual(removingEmphasisMarks("a snake_case name stays"), "a snake_case name stays")
        XCTAssertEqual(removingEmphasisMarks("one _lonely mark"), "one _lonely mark")
    }

    func testABookTitledOnlyInCapitalsStillFindsItsChapters() throws {
        let text = """
            THE FIRST DAY

            The sun came up over the hill.

            THE SECOND DAY

            It rained all day long.
            """
        let draft = try readPlainTextBook(text, fallbackTitle: "x")
        XCTAssertEqual(draft.chapters.filter { $0.kind == .story }.map(\.title), ["THE FIRST DAY", "THE SECOND DAY"])
    }

    func testANonEnglishTextIsWarnedAbout() throws {
        let text = """
            Il était une fois une petite maison au bord d'un bois. Un vieil homme y vivait avec son chat, et ils étaient très heureux ensemble.
            """
        let draft = try readPlainTextBook(text, fallbackTitle: "x")
        XCTAssertTrue(draft.warnings.contains(.notEnglish(language: "fr")), "\(draft.warnings)")
    }

    func testAnEmptyTextIsRefused() {
        XCTAssertThrowsError(try readPlainTextBook("\n\n   \n", fallbackTitle: "x")) { error in
            XCTAssertEqual(error as? BookImportError, .noText)
        }
    }

    func testDecodingAcceptsAByteOrderMarkAndOlderEncodings() {
        XCTAssertEqual(decodeBookText(Data([0xEF, 0xBB, 0xBF, 0x61])), "a")
        XCTAssertEqual(decodeBookText(Data([0x63, 0x61, 0x66, 0xE9])), "caf\u{00E9}", "Windows-1252")
    }

    func testTheEstimateUsesFifteenWordsAMinuteBeforeTheFirstSitting() {
        XCTAssertEqual(estimatedSittings(words: 3_000, wpm: nil), 10)
        XCTAssertEqual(estimatedSittings(words: 3_000, wpm: 30), 5)
        XCTAssertEqual(estimatedSittings(words: 0, wpm: 30), 1)
    }
}
