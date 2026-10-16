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
        let document = try makeDocument(Data(epub2File.utf8), tidy: false)
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

    func testThePrePassLeavesWhatTheParserReadsAsWritten() throws {
        XCTAssertEqual(
            try entityPrePass("<p><![CDATA[Use &nbsp; literally.]]> a&nbsp;b</p>"),
            "<p><![CDATA[Use &nbsp; literally.]]> a&#160;b</p>")
        XCTAssertEqual(
            try entityPrePass("<!-- &madeup; --><?pi &other;?><p>a&mdash;b</p>"),
            "<!-- &madeup; --><?pi &other;?><p>a&#8212;b</p>")
        // A comment opener inside an attribute value is not a comment, and
        // one left open protects nothing.
        XCTAssertThrowsError(try entityPrePass("<a title=\"<!--\">&madeup;</a> -->")) {
            XCTAssertEqual($0 as? MarkupError, .unknownEntity("madeup"))
        }
        XCTAssertThrowsError(try entityPrePass("<!-- open &madeup;")) {
            XCTAssertEqual($0 as? MarkupError, .unknownEntity("madeup"))
        }
        let text = try chapterOf("<!-- &madeup; --><p><![CDATA[Use &nbsp; literally.]]></p>")
        XCTAssertEqual(blockTexts(text), ["Use &nbsp; literally."])
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

    func testProseBeforeAPoemIsNotReadAsVerse() throws {
        let text = try chapterOf(
            "<div>A prose line<br/>wrapped by hand<div class=\"poem\"><p>The owl<br/>the cat</p></div></div>")
        XCTAssertEqual(text.blocks.map(\.kind), [.paragraph, .verse])
        XCTAssertEqual(text.blocks[0].lines, ["A prose line wrapped by hand"])
        XCTAssertEqual(text.blocks[1].lines, ["The owl", "the cat"])
    }

    func testAVerseClassIsAWordNotLettersInsideOne() throws {
        let text = try chapterOf(
            """
            <div class="reversed"><p>A prose line<br/>wrapped by hand</p></div>
            <div class="songbird"><p>Another prose line<br/>wrapped by hand</p></div>
            <div class="poemLine"><p>The owl<br/>the cat</p></div>
            <div class="line-group"><p>The pea<br/>green boat</p></div>
            """)
        XCTAssertEqual(text.blocks.map(\.kind), [.paragraph, .paragraph, .verse, .verse])
        XCTAssertEqual(classWords("poem-line2 stanzaFirst x_VERSE"), ["poem", "line", "stanza", "first", "x", "verse"])
    }

    func testAParagraphHoldingOnlyAnInlineTitleIsAHeading() throws {
        let text = try chapterOf(
            """
            <p><span epub:type="title">Chapter One</span></p>
            <p>He read <span epub:type="title">Moby Dick</span> twice.</p>
            """)
        XCTAssertEqual(text.firstHeading, "Chapter One")
        XCTAssertEqual(blockTexts(text), ["He read Moby Dick twice."])
    }

    func testTextDroppedAnywayDoesNotMakeADataTableLayout() throws {
        let hidden = String(repeating: "Hidden words that are never read. ", count: 60)
        let text = try chapterOf(
            "<p>" + String(repeating: "The story goes on. ", count: 5) + "</p>"
                + "<div hidden=\"hidden\">\(hidden)</div><script>\(hidden)</script>"
                + "<table><tr><td>Year</td><td>Event</td></tr></table>")
        XCTAssertEqual(text.tablesDropped, 1)
        XCTAssertFalse(text.layoutTables)
        XCTAssertFalse(blockTexts(text).joined().contains("Year"))
    }

    func testALinkedDropCapIsStillNavigation() throws {
        let text = try chapterOf(
            """
            <p><a href="ch2.xhtml"><span class="dropcap">S</span>tart Reading</a></p>
            <p><span class="dropcap">T</span>he story.</p>
            """)
        XCTAssertEqual(blockTexts(text), ["The story."])
        XCTAssertEqual(text.navigationParagraphs, 1)
    }

    func testProseBeforeAPoemInAnUnknownElementIsNotReadAsVerse() throws {
        let text = try chapterOf(
            "<div>A prose line<br/>wrapped by hand<details class=\"poem\"><p>The owl<br/>the cat</p></details>"
                + "and prose again<br/>after it</div>")
        XCTAssertEqual(text.blocks.map(\.kind), [.paragraph, .verse, .paragraph])
        XCTAssertEqual(text.blocks[0].lines, ["A prose line wrapped by hand"])
        XCTAssertEqual(text.blocks[2].lines, ["and prose again after it"])
    }

    func testVerseInAnInlineElementEndsAsVerse() throws {
        let text = try chapterOf("<p>Prose first.<span class=\"poem\">The owl<br/>the cat</span></p>")
        XCTAssertEqual(text.blocks.map(\.kind), [.paragraph, .verse])
        XCTAssertEqual(text.blocks[1].lines, ["The owl", "the cat"])
    }

    func testAnInlineTitleBrokenFromTheProseUnderItIsAHeading() throws {
        let text = try chapterOf(
            "<p><span epub:type=\"title\">Chapter One</span><br/>It was a cold day in the hills.</p>")
        XCTAssertEqual(text.firstHeading, "Chapter One")
        XCTAssertEqual(text.blocks.map(\.kind), [.heading, .paragraph])
        XCTAssertEqual(blockTexts(text), ["It was a cold day in the hills."])
    }

    func testADataTableAmongLayoutTablesIsStillDroppedAndCounted() throws {
        let page = (0..<6).map { "<tr><td><p>Row \($0) of the page. The fox ran across the field.</p></td></tr>" }
        let text = try chapterOf(
            "<p>Page 4</p><table>" + page.joined() + "</table>"
                + "<table><tr><th>Year</th><th>Event</th></tr><tr><td>1850</td><td>A thing</td></tr></table>"
                + "<table><tr><td>Mon</td><td>9</td><td>Tue</td></tr><tr><td>Wed</td><td>10</td><td>Thu</td></tr></table>")
        XCTAssertTrue(text.layoutTables)
        XCTAssertEqual(text.tablesDropped, 2)
        let all = blockTexts(text).joined(separator: " ")
        XCTAssertTrue(all.contains("The fox ran across the field."))
        XCTAssertFalse(all.contains("1850"))
        XCTAssertFalse(all.contains("Wed"))
    }

    func testTheDataTableRuleNeverTakesAPage() throws {
        let table = { (body: String) in
            try XCTUnwrap(try makeDocument(Data("<table>\(body)</table>".utf8), tidy: false).rootElement())
        }
        let page = (0..<6).map { "<tr><td>Row \($0) of the page. The fox ran across the field.</td></tr>" }.joined()
        let columns = "<tr><td>" + String(repeating: "Left column words. ", count: 10) + "</td><td>"
            + String(repeating: "Right column words. ", count: 10) + "</td></tr>"
        XCTAssertFalse(isDataTable(try table(page)))
        XCTAssertFalse(isDataTable(try table(columns + columns)))
        XCTAssertTrue(isDataTable(try table("<caption>Prices</caption><tr><td>a</td></tr>")))
    }

    func testHiddenTextInACellDoesNotMakeADataTableLookLikeAPage() throws {
        let table = { (body: String) in
            try XCTUnwrap(try makeDocument(Data("<table>\(body)</table>".utf8), tidy: false).rootElement())
        }
        let hidden = "<span hidden=\"hidden\">" + String(repeating: "padding words ", count: 10) + "</span>"
        let note = "<aside class=\"footnote\">" + String(repeating: "a long note ", count: 10) + "</aside>"
        let grid = (0..<3).map { "<tr><td>Mon\(hidden)</td><td>\($0)\(note)</td></tr>" }.joined()
        XCTAssertTrue(isDataTable(try table(grid)))
    }

    func testADropCapThatIsItselfALinkIsNavigation() throws {
        let text = try chapterOf(
            """
            <p><a class="dropcap" href="x.xhtml">Go</a></p>
            <p><span class="dropcap">T</span>he story.</p>
            """)
        XCTAssertEqual(blockTexts(text), ["The story."])
        XCTAssertEqual(text.navigationParagraphs, 1)
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
