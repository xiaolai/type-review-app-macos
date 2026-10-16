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
        for heading in ["Chapter I. The Cyclone", "Chapter I. The Cyclone.", "Book the First", "Chapter Twenty-one",
            "Prologue: The Boy", "Epilogue."]
        {
            XCTAssertTrue(isChapterHeading(heading), heading)
        }
        for line in [
            "The chapter was over.", "Bookshelves lined the walls and every one was full of dust.",
            "Part of the garden was hidden behind the wall.", "Book one was the best.", "Part mild, part wild.",
            "Prologues bore him.", "Mild.",
        ] {
            XCTAssertFalse(isChapterHeading(line), line)
        }
    }

    func testAHeadingFollowedByProseKeepsTheProse() throws {
        let text = """
            Chapter 1
            It was cold.
            The wind blew.

            Nothing else happened that day at all.
            """
        let draft = try readPlainTextBook(text, fallbackTitle: "t")
        let chapter = try XCTUnwrap(draft.chapters.first { $0.kind == .story })
        XCTAssertEqual(chapter.title, "Chapter 1")
        XCTAssertEqual(chapter.sentences.prefix(2), ["It was cold.", "The wind blew."])
    }

    func testASentenceUnderTheHeadingIsNotItsTitle() throws {
        for line in ["I saw Mary.", "It was a dark and", "Mary and I\nwent home."] {
            let text = "Chapter 1\n\(line)\n\nThe end came soon enough for all of them."
            let draft = try readPlainTextBook(text, fallbackTitle: "t")
            XCTAssertEqual(draft.chapters.first { $0.kind == .story }?.title, "Chapter 1", line)
        }
    }

    func testCapitalProseAtTheTopOfAChapterIsKept() throws {
        let text = """
            Chapter 1

            It was written on the slate in big letters, and she read it aloud.

            Chapter 2

            LET DOROTHY GO
            TO THE CITY.

            Then she went.
            """
        let draft = try readPlainTextBook(text, fallbackTitle: "t")
        let second = try XCTUnwrap(draft.chapters.last)
        XCTAssertEqual(second.sentences.first, "LET DOROTHY GO TO THE CITY.")
    }

    func testATitleUnderTheHeadingIsPartOfIt() throws {
        let text = """
            CHAPTER XI.
            Who Stole the Tarts?

            The King and Queen of Hearts were seated on their throne when they arrived.
            """
        let draft = try readPlainTextBook(text, fallbackTitle: "t")
        XCTAssertEqual(draft.chapters.first { $0.kind == .story }?.title, "CHAPTER XI. Who Stole the Tarts?")
    }

    func testAPrologueDoesNotStopCapitalTitlesFromBeingChapters() throws {
        let text = """
            Prologue

            It started long ago, before anyone remembers.

            THE FIRST DAY

            The sun rose over the hills and the birds sang.

            THE SECOND DAY

            The rain came and nobody went outside at all.
            """
        let draft = try readPlainTextBook(text, fallbackTitle: "t")
        XCTAssertEqual(draft.chapters.map(\.title), ["Prologue", "THE FIRST DAY", "THE SECOND DAY"])
    }

    func testAWordBrokenAcrossWrappedLinesIsRejoined() throws {
        let draft = try readPlainTextBook("It was a well-\nknown story, told by every one.", fallbackTitle: "t")
        XCTAssertEqual(draft.chapters[0].sentences, ["It was a well-known story, told by every one."])
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

    func testAFileOverTheLimitIsRefusedByWhatIsRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = folder.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: maxPlainTextBookBytes + 1).write(to: big)
        XCTAssertThrowsError(try readPlainTextBook(at: big)) { error in
            guard case .tooLarge = error as? BookImportError else { return XCTFail("\(error)") }
        }
        let small = folder.appendingPathComponent("The Cottage.txt")
        try Data("It rained. Then the sun came out.".utf8).write(to: small)
        XCTAssertEqual(try readPlainTextBook(at: small).title, "The Cottage")
        XCTAssertThrowsError(try readPlainTextBook(at: folder.appendingPathComponent("missing.txt")))
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

    func testSplittingBlockByBlockIsSplittingThePart() throws {
        let blocks: [BookBlock] = [
            .heading("Chapter One"), .paragraph("It was cold. \u{201C}Where?\u{201D} she asked. It began."),
            BookBlock(kind: .verse, lines: ["Twinkle, twinkle, little bat!", "How I wonder"]), .sceneBreak,
            .paragraph("caf\u{00E9} and \u{4F60}\u{597D} " + String(repeating: "word ", count: 90)),
        ]
        let whole = splitIntoSentences(blocks)
        let pieces = splitBlocks(blocks)
        XCTAssertEqual(pieces.count, blocks.count)
        XCTAssertEqual(pieces.flatMap(\.sentences), whole.sentences)
        XCTAssertEqual(pieces.map(\.droppedChars).reduce(0, +), whole.droppedChars)
        XCTAssertEqual(pieces.map(\.rawCharacters).reduce(0, +), whole.rawCharacters)
        let sources = [ChapterSource(title: "One", kind: .story, reason: "", blocks: blocks)]
        XCTAssertEqual(
            try makeDraft(title: "t", author: "", sources: sources, blockSplits: sources.map { splitBlocks($0.blocks) }),
            try makeDraft(title: "t", author: "", sources: sources))
    }

    func testTheEstimateSurvivesNonsenseInput() {
        XCTAssertEqual(estimatedSittings(words: 3_000, wpm: .nan), 10)
        XCTAssertEqual(estimatedSittings(words: 3_000, wpm: .infinity), 10)
        XCTAssertEqual(estimatedSittings(words: 3_000, wpm: nil, minutesPerSitting: 0), 10)
        XCTAssertEqual(estimatedSittings(words: -5, wpm: 30), 1)
        XCTAssertEqual(estimatedSittings(words: Int.max, wpm: 1, minutesPerSitting: .leastNonzeroMagnitude), Int(Int32.max))
    }

    func testAStoryChapterThatCleaningEmptiesIsStillReportedAsLoss() throws {
        let draft = try makeDraft(
            title: "t", author: "", sources: [
                ChapterSource(title: "One", kind: .story, reason: "", blocks: [.paragraph("A plain sentence to type.")]),
                ChapterSource(title: "Two", kind: .story, reason: "", blocks: [.paragraph("\u{4E00}\u{4E8C}\u{4E09}\u{56DB}\u{4E94}")]),
            ])
        XCTAssertEqual(draft.chapters.count, 1)
        XCTAssertTrue(draft.warnings.contains { if case .mixedLanguage = $0 { return true } else { return false } })
    }
}
