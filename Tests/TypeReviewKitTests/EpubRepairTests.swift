import XCTest

@testable import TypeReviewKit

/// §2.1 and the sentence merges of §2, through the whole EPUB reader: each
/// case is a built book, and each checks the sentences a child would type.
final class EpubRepairTests: XCTestCase {
    /// The sentences of a one-chapter book, with enough ordinary story after
    /// the case to be a chapter.
    private func sentences(_ body: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        var book = EpubBuilder()
        book.chapters = [BuiltChapter("ch1.xhtml", body + "\n" + storyParagraphs(3))]
        assertSentenceInvariants(try book.contents(), file: file, line: line)
        let draft = try book.draft()
        XCTAssertEqual(draft.chapters.count, 1, file: file, line: line)
        return draft.chapters.first?.sentences ?? []
    }

    func testMojibakeWithAnOrphanClosingQuoteIsRepaired() throws {
        // “Hello,” she said, “it’s late.” — decoded as Windows-1252 upstream,
        // with the closing quote's third byte dropped by the converter.
        let found = try sentences("<p>â€œHello,â€ she said, â€œitâ€™s late.â€</p><p>Café au lait, said nobody.</p>")
        XCTAssertEqual(found[0], "\"Hello,\" she said, \"it's late.\"")
        XCTAssertEqual(found[1], "Cafe au lait, said nobody.")
        XCTAssertFalse(found.joined().contains("aEUR"), "\(found)")
    }

    func testAFileWithOneLinePerParagraphIsJoined() throws {
        let lines = [
            "The rain had stopped by the time the", "children reached the bridge, and the river", "was higher than they had",
            "ever seen it.", "Nobody spoke for a while;", "then Sam threw a stick into", "the water and watched it go.",
            "It spun twice and was gone", "under the arch, carried off", "towards the sea.",
        ]
        let found = try sentences(lines.map { "<p>\($0)</p>" }.joined(separator: "\n"))
        XCTAssertEqual(
            Array(found.prefix(3)),
            [
                "The rain had stopped by the time the children reached the bridge, and the river was higher than they had ever seen it.",
                "Nobody spoke for a while; then Sam threw a stick into the water and watched it go.",
                "It spun twice and was gone under the arch, carried off towards the sea.",
            ])
    }

    func testASpeechTagAfterAQuestionStaysWithTheQuotation() throws {
        let found = try sentences("<p>\u{201C}Owen?\u{201D} I say. He does not turn round.</p>")
        XCTAssertEqual(Array(found.prefix(2)), ["\"Owen?\" I say.", "He does not turn round."])
    }

    func testMrAtTheEndOfALineJoinsTheNext() throws {
        let found = try sentences("<p>At the gate they met Mr.</p><p>Brown, who was carrying a lamp.</p>")
        XCTAssertEqual(found[0], "At the gate they met Mr. Brown, who was carrying a lamp.")
    }

    func testADropCapWithASpaceAfterItIsOneWord() throws {
        let found = try sentences("<p><span class=\"dropcap\">T</span> he wind blew all night.</p>")
        XCTAssertEqual(found[0], "The wind blew all night.")
    }

    func testALabelParagraphBecomesATitle() throws {
        var book = EpubBuilder()
        book.chapters = [
            BuiltChapter(
                "ch1.xhtml", "<p>Chapter 1</p>\n<p>THE BOY WHO LIVED</p>\n<p>23</p>\n" + storyParagraphs(3))
        ]
        let draft = try book.draft()
        let found = draft.chapters[0].sentences
        XCTAssertFalse(found.contains("Chapter 1"), "\(found.prefix(3))")
        XCTAssertFalse(found.contains("THE BOY WHO LIVED"), "\(found.prefix(3))")
        XCTAssertFalse(found.contains("23"), "\(found.prefix(3))")
        XCTAssertTrue(found[0].hasPrefix("The river ran fast"), found[0])
    }

    func testALayoutTableIsReadAsText() throws {
        // A PDF conversion: the whole page set as one table, with a little
        // text outside it.
        let rows = (0..<6).map { "<tr><td><p>Row \($0) of the page. The fox ran across the field.</p></td></tr>" }
        var book = EpubBuilder()
        book.chapters = [
            BuiltChapter("ch1.xhtml", "<p>Page 4</p><table>" + rows.joined() + "</table>"),
            BuiltChapter("ch2.xhtml", storyParagraphs(3)),
        ]
        let contents = try book.contents()
        XCTAssertEqual(contents.tablesDropped, 0, "a layout table is not a dropped table")
        let draft = try contents.draft()
        XCTAssertTrue(draft.chapters[0].sentences.contains("The fox ran across the field."), "\(draft.chapters[0].sentences)")
        XCTAssertFalse(draft.warnings.contains { if case .tablesDropped = $0 { return true } else { return false } })
    }

    func testGutenbergMatterInsideAChapterIsCut() throws {
        let found = try sentences(
            """
            <p>The Project Gutenberg eBook of A Test, by Somebody.</p>
            <p>*** START OF THE PROJECT GUTENBERG EBOOK A TEST ***</p>
            <p>Here the book begins.</p>
            """)
        XCTAssertEqual(found.first, "Here the book begins.")
    }
}
