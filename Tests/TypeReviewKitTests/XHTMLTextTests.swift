import XCTest

@testable import TypeReviewKit

/// §3.4: one case for every row of the drop table, and the entity pre-pass.
final class XHTMLTextTests: XCTestCase {
    // MARK: Entities

    /// The normal EPUB 2 header: the XHTML 1.1 DTD, and HTML entities in the
    /// text. Without the pre-pass the parser deletes the entities silently,
    /// and "Tom&nbsp;Sawyer&mdash;then" reads "TomSawyerthen".
    private let epub2File = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter</title></head>
        <body>
        <p>Tom&nbsp;Sawyer&mdash;then Huck&rsquo;s turn &amp; mine.</p>
        </body>
        </html>
        """

    func testTheEntityPrePassKeepsWordsApartInAnEpub2File() throws {
        let text = chapterText(try parseMarkup(Data(epub2File.utf8)))
        XCTAssertEqual(blockTexts(text), ["Tom Sawyer\u{2014}then Huck\u{2019}s turn & mine."])
        XCTAssertFalse(blockTexts(text)[0].contains("TomSawyer"), "words were glued: the pre-pass did not run")
    }

    /// Why the pre-pass exists: the same file, parsed without it, loses the
    /// entities without an error. If this ever starts failing, Foundation's
    /// parser changed and the comment on `entityPrePass` needs revisiting —
    /// the pre-pass is still right either way.
    func testWithoutThePrePassTheParserDeletesEntitiesSilently() throws {
        let document = try xmlDocument(Data(epub2File.utf8))
        let text = chapterText(document)
        XCTAssertTrue(blockTexts(text).first?.contains("TomSawyerthen") ?? false, "\(blockTexts(text))")
    }

    func testThePrePassWritesNumericReferencesAndLeavesTheXMLFive() throws {
        XCTAssertEqual(try entityPrePass("a&nbsp;b&mdash;c&amp;d&lt;e"), "a&#160;b&#8212;c&amp;d&lt;e")
        XCTAssertEqual(htmlEntityCodePoints.count, 248)
        for name in ["amp", "lt", "gt", "quot", "apos"] { XCTAssertNil(htmlEntityCodePoints[name], name) }
    }

    func testAnUnknownEntityIsRefusedByName() {
        XCTAssertThrowsError(try entityPrePass("a &notathing; b")) {
            XCTAssertEqual($0 as? MarkupError, .unknownEntity("notathing"))
        }
    }

    func testHTMLThatIsNotXMLFallsBackToTidy() throws {
        let html = "<html><body><p>One paragraph<p>Another paragraph<br>with a break</body></html>"
        let text = chapterText(try parseMarkup(Data(html.utf8)))
        XCTAssertEqual(blockTexts(text), ["One paragraph", "Another paragraph with a break"])
    }

    // MARK: The block model

    func testInlineElementsJoinWithoutAddedSpace() throws {
        let text = try chapterOf("<p><i>Un</i>believable, <b>she</b> <em>said</em>.</p>")
        XCTAssertEqual(blockTexts(text), ["Unbelievable, she said."])
    }

    func testANestedFootnotesSectionDoesNotMarkTheFile() throws {
        let text = try chapterOf(
            """
            <section epub:type="chapter"><p>The story.</p>
            <section epub:type="footnotes"><p>1. A note.</p></section></section>
            """)
        XCTAssertEqual(text.bodyTypes, ["chapter"])
        XCTAssertEqual(blockTexts(text), ["The story."])
    }

    // MARK: One case per row of the drop table

    func testFootnoteMarkersAreDropped() throws {
        let text = try chapterOf(
            """
            <p>One<a epub:type="noteref" href="#n1">1</a> two<sup>2</sup> three<a href="#n3">[iv]</a> \
            four<sup>*</sup> five<a href="notes.xhtml#n5">†</a> six<a role="doc-noteref" href="#n6">a</a>.</p>
            """)
        XCTAssertEqual(blockTexts(text), ["One two three four five six."])
        XCTAssertEqual(text.noteMarkers, 6)
    }

    func testFootnoteBodiesAreDroppedByTypeRoleAndClass() throws {
        let text = try chapterOf(
            """
            <p>The story goes on.</p>
            <aside epub:type="footnote"><p>A typed note.</p></aside>
            <div role="doc-endnote"><p>A note by role.</p></div>
            <div class="footnotes"><p>A note by class.</p></div>
            <div class="x13-BM-Endnotes"><p>A converter's note.</p></div>
            <div class="notebook"><p>Not a note: the word is inside another.</p></div>
            """)
        XCTAssertEqual(blockTexts(text), ["The story goes on.", "Not a note: the word is inside another."])
        XCTAssertEqual(text.noteBodies, 4)
    }

    func testPageBreaksAreDropped() throws {
        let text = try chapterOf(
            "<p>Before the turn<span epub:type=\"pagebreak\" title=\"12\">12</span> of the page.</p>"
                + "<div role=\"doc-pagebreak\">13</div>")
        XCTAssertEqual(blockTexts(text), ["Before the turn of the page."])
        XCTAssertEqual(text.pageBreaks, 2)
    }

    func testAParagraphThatIsAllLinksIsNavigation() throws {
        let text = try chapterOf(
            """
            <p><a href="toc.xhtml">Contents</a></p>
            <p><a href="ch2.xhtml">Start Reading</a></p>
            <p>A sentence with <a href="x.xhtml">a link</a> in it.</p>
            <p><a id="anchor"/>Text after a bare anchor.</p>
            """)
        XCTAssertEqual(blockTexts(text), ["A sentence with a link in it.", "Text after a bare anchor."])
        XCTAssertEqual(text.navigationParagraphs, 2)
    }

    func testImagesAndFiguresAreDropped() throws {
        let text = try chapterOf(
            """
            <figure><img src="a.png" alt="A drawing of a cat"/><figcaption>The cat, drawn.</figcaption></figure>
            <svg xmlns="http://www.w3.org/2000/svg"><text>svg words</text></svg>
            <p>The cat sat by the fire.</p>
            """)
        XCTAssertEqual(blockTexts(text), ["The cat sat by the fire."])
        XCTAssertEqual(text.images, 1)
    }

    func testADataTableIsDroppedAndCounted() throws {
        let text = try chapterOf(
            "<p>" + String(repeating: "The long story goes on and on. ", count: 10) + "</p>"
                + "<table><tr><td>Year</td><td>Event</td></tr><tr><td>1850</td><td>A thing</td></tr></table>")
        XCTAssertEqual(text.tablesDropped, 1)
        XCTAssertFalse(text.layoutTables)
        XCTAssertFalse(blockTexts(text).joined().contains("Year"))
    }

    func testCodeAndMarkupThatIsNotTextAreDropped() throws {
        let text = try chapterOf(
            """
            <style>p { color: red }</style>
            <script>var x = 1;</script>
            <math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>
            <nav><ol><li><a href="a.xhtml">A chapter</a></li></ol></nav>
            <p>Only this.</p>
            """)
        XCTAssertEqual(blockTexts(text), ["Only this."])
    }

    func testHiddenTextIsDropped() throws {
        let text = try chapterOf(
            "<p hidden=\"hidden\">Hidden.</p><p aria-hidden=\"true\">Also hidden.</p><p>Shown.</p>")
        XCTAssertEqual(blockTexts(text), ["Shown."])
        XCTAssertEqual(text.hidden, 2)
    }

    func testScenesBreakOnRulesAndOrnaments() throws {
        let text = try chapterOf(
            "<p>One.</p><hr/><p>Two.</p><p>* * *</p><p>Three.</p><p>~</p><p>Four.</p><p>O</p>")
        XCTAssertEqual(
            text.blocks.map(\.kind),
            [.paragraph, .sceneBreak, .paragraph, .sceneBreak, .paragraph, .sceneBreak, .paragraph, .paragraph])
    }

    func testHeadingsAreTitlesNotText() throws {
        let text = try chapterOf(
            """
            <header><p>Chapter 1</p><h2>The Boy Who Lived</h2></header>
            <p epub:type="subtitle">In which a boy lives</p>
            <h3>A smaller heading</h3>
            <p>Mr. Dursley was a big man.</p>
            """)
        XCTAssertEqual(text.firstHeading, "Chapter 1")
        XCTAssertEqual(
            text.blocks.filter { $0.kind == .heading }.map { $0.lines.joined() },
            ["Chapter 1", "The Boy Who Lived", "In which a boy lives", "A smaller heading"])
        XCTAssertEqual(blockTexts(text), ["Mr. Dursley was a big man."])
    }

    func testADropCapJoinsItsWord() throws {
        let text = try chapterOf(
            """
            <p><span class="dropcap">T</span> his was the start.</p>
            <p><span class="initial">O</span>nce there was a fox.</p>
            <p><span class="dropcap">W</span> <span class="smallcaps">hen</span> the sun rose.</p>
            """)
        XCTAssertEqual(
            blockTexts(text),
            ["This was the start.", "Once there was a fox.", "When the sun rose."])
        XCTAssertEqual(text.dropCaps, 3)
    }

    func testVerseKeepsItsLinesOnlyWhereTheMarkupSaysVerse() throws {
        let text = try chapterOf(
            """
            <div class="poem"><p>The owl and the cat<br/>went to sea</p></div>
            <p>A prose line<br/>wrapped by hand</p>
            """)
        XCTAssertEqual(text.blocks.map(\.kind), [.verse, .paragraph])
        XCTAssertEqual(text.blocks[0].lines, ["The owl and the cat", "went to sea"])
        XCTAssertEqual(text.blocks[1].lines, ["A prose line wrapped by hand"])
    }
}
