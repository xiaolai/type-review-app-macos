import XCTest

@testable import TypeReviewKit

/// §3.3: the container, the package, the reading order, the two kinds of
/// navigation, and the refusals.
final class EpubPackageTests: XCTestCase {
    private func chapters(_ count: Int) -> [BuiltChapter] {
        (1...count).map { BuiltChapter("ch\($0).xhtml", "<h1>Chapter \($0)</h1>\n" + storyParagraphs(6, seed: $0)) }
    }

    private func importError(_ book: EpubBuilder) -> BookImportError? {
        do {
            _ = try book.draft()
            return nil
        } catch {
            return error as? BookImportError
        }
    }

    func testAnEpub2BookReadsWithItsNcxNamesAndGuide() throws {
        var book = EpubBuilder()
        book.version = "2.0"
        book.chapters = [BuiltChapter("cover.xhtml", "<div><img src=\"c.jpg\" alt=\"\"/></div>")] + chapters(3)
        book.manifest = "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
        book.guide = """
            <guide><reference type="cover" href="cover.xhtml"/><reference type="text" href="ch1.xhtml"/></guide>
            """
        book.extraFiles = [
            (
                "OEBPS/toc.ncx",
                Data(
                    """
                    <?xml version="1.0"?>
                    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
                    <navPoint id="a"><navLabel><text>The First Part</text></navLabel><content src="ch1.xhtml"/></navPoint>
                    <navPoint id="b"><navLabel><text>The Second Part</text></navLabel><content src="ch2.xhtml#top"/></navPoint>
                    </navMap></ncx>
                    """.utf8)
            )
        ]
        let package = try readPackage(try book.archive())
        XCTAssertEqual(package.title, "A Built Book")
        XCTAssertEqual(package.creator, "A. Tester")
        XCTAssertEqual(package.ncxPath, "OEBPS/toc.ncx")
        XCTAssertNil(package.navigationPath)
        XCTAssertEqual(package.spine.map(\.path), ["OEBPS/cover.xhtml", "OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml", "OEBPS/ch3.xhtml"])
        XCTAssertEqual(package.tableOfContentsLabels["OEBPS/ch2.xhtml"], "The Second Part")
        XCTAssertEqual(package.guide["OEBPS/cover.xhtml"], ["cover"])
        XCTAssertEqual(package.bodyStarts, ["OEBPS/ch1.xhtml"])

        let draft = try book.draft()
        XCTAssertEqual(draft.chapters.map(\.title), ["The First Part", "The Second Part", "Chapter 3"])
        XCTAssertTrue(draft.chapters.allSatisfy { $0.kind == .story && $0.included })
        assertSentenceInvariants(try book.contents())
    }

    func testAnEpub3BookReadsItsNavigationAndLandmarks() throws {
        var book = EpubBuilder()
        book.chapters = [BuiltChapter("intro.xhtml", storyParagraphs(2))] + chapters(3)
        book.navigation = """
            <nav epub:type="toc"><ol>
            <li><a href="ch1.xhtml">One</a></li><li><a href="ch2.xhtml">Two</a></li><li><a href="ch3.xhtml">Three</a></li>
            </ol></nav>
            <nav epub:type="landmarks"><ol>
            <li><a epub:type="bodymatter" href="ch1.xhtml">Start</a></li>
            <li><a epub:type="preface" href="intro.xhtml">Preface</a></li>
            </ol></nav>
            """
        let package = try readPackage(try book.archive())
        XCTAssertEqual(package.navigationPath, "OEBPS/nav.xhtml")
        XCTAssertEqual(package.tableOfContentsLabels["OEBPS/ch3.xhtml"], "Three")
        XCTAssertEqual(package.landmarks["OEBPS/intro.xhtml"], ["preface"])
        XCTAssertEqual(package.bodyStarts, ["OEBPS/ch1.xhtml"])

        let draft = try book.draft()
        XCTAssertEqual(draft.chapters.map(\.title), ["Section 1", "One", "Two", "Three"])
        XCTAssertEqual(draft.chapters.map(\.kind), [.optional, .story, .story, .story])
        XCTAssertEqual(draft.chapters[0].reason, "marked as preface")
        XCTAssertFalse(draft.chapters[0].included)
        assertSentenceInvariants(try book.contents())
    }

    func testABookWithDRMIsRefused() {
        let encryption = Data(
            """
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
            <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/ch1.xhtml"/></enc:CipherData></enc:EncryptedData>
            </encryption>
            """.utf8)
        var book = EpubBuilder()
        book.chapters = chapters(2)
        book.extraFiles = [("META-INF/encryption.xml", encryption)]
        XCTAssertEqual(importError(book), .copyProtected)

        // Apple's FairPlay leaves its own file, whatever the text looks like.
        var fairPlay = EpubBuilder()
        fairPlay.chapters = chapters(2)
        fairPlay.extraFiles = [("META-INF/sinf.xml", Data("<sinf/>".utf8))]
        XCTAssertEqual(importError(fairPlay), .copyProtected)
    }

    func testAnObfuscatedFontStillImports() throws {
        let encryption = Data(
            """
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
            <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/serif.otf"/></enc:CipherData></enc:EncryptedData>
            </encryption>
            """.utf8)
        var book = EpubBuilder()
        book.chapters = chapters(2)
        book.extraFiles = [
            ("META-INF/encryption.xml", encryption), ("OEBPS/fonts/serif.otf", Data(repeating: 7, count: 64)),
        ]
        let draft = try book.draft()
        XCTAssertEqual(draft.chapters.count, 2)
        XCTAssertGreaterThan(draft.includedSentences, 10)
    }

    func testAFixedLayoutBookIsRefused() {
        var book = EpubBuilder()
        book.chapters = chapters(2)
        book.metadata = "<meta property=\"rendition:layout\">pre-paginated</meta>"
        XCTAssertEqual(importError(book), .fixedLayout)

        var kindle = EpubBuilder()
        kindle.chapters = chapters(2)
        kindle.metadata = "<meta name=\"fixed-layout\" content=\"true\"/>"
        XCTAssertEqual(importError(kindle), .fixedLayout)
    }

    func testABookOfPicturesIsRefusedAsPictures() {
        var book = EpubBuilder()
        book.chapters = (1...4).map { BuiltChapter("page\($0).xhtml", "<div><img src=\"p\($0).jpg\" alt=\"\"/></div>") }
        XCTAssertEqual(importError(book), .picturesOnly)

        var empty = EpubBuilder()
        empty.chapters = [BuiltChapter("blank.xhtml", "<div></div>")]
        XCTAssertEqual(importError(empty), .noText)
    }

    func testALyingLanguageIsCaughtFromTheText() throws {
        let french = """
            <p>Le matin, la petite fille descendit au bord de la rivière avec son panier et ses bottes rouges.</p>
            <p>Elle chercha longtemps le bateau de bois que son frère avait perdu pendant la tempête de la nuit.</p>
            <p>Les canards la regardaient sans bouger, et le vent froid faisait trembler les feuilles des arbres.</p>
            <p>Enfin elle le trouva dans les roseaux, couché sur le côté, avec sa petite voile toute mouillée.</p>
            """
        var book = EpubBuilder()
        book.language = "en"
        book.chapters = (1...2).map { BuiltChapter("ch\($0).xhtml", "<h1>Chapitre \($0)</h1>" + french) }
        XCTAssertEqual(try readPackage(try book.archive()).declaredLanguage, "en")
        let draft = try book.draft()
        XCTAssertTrue(draft.warnings.contains(.notEnglish(language: "fr")), "\(draft.warnings)")
    }

    func testAnUnreadableChapterIsNamedAndTheRestImports() throws {
        var book = EpubBuilder()
        book.chapters = chapters(2) + [BuiltChapter("broken.xhtml", "", raw: "<p>&madeup; text</p>")]
        let draft = try book.draft()
        XCTAssertEqual(draft.chapters.count, 2)
        XCTAssertTrue(draft.warnings.contains(.unreadableFiles(["OEBPS/broken.xhtml"])), "\(draft.warnings)")
    }

    func testAPackageThatPointsOutsideItselfIsRefused() {
        var book = EpubBuilder()
        book.chapters = chapters(1)
        book.manifest = "<item id=\"x\" href=\"../../outside.xhtml\" media-type=\"application/xhtml+xml\"/>"
        XCTAssertEqual(importError(book), .unreadable(EpubPackageError.hrefEscapes("../../outside.xhtml").description))
    }

    func testARemoteResourceInTheManifestIsPassedOver() throws {
        var book = EpubBuilder()
        book.chapters = chapters(1)
        book.manifest = """
            <item id="f1" href="//fonts.example.com/serif.woff" media-type="font/woff"/>
            <item id="f2" href="data:font/woff;base64,AAAA" media-type="font/woff"/>
            """
        XCTAssertEqual(try readPackage(try book.archive()).spine.count, 1)
    }

    func testAnEncryptionListThatCannotBeReadRefusesTheBook() throws {
        var book = EpubBuilder()
        book.chapters = chapters(2)
        book.extraFiles = [("META-INF/encryption.xml", Data("<encryption/>".utf8))]
        var writer = book.zip()
        let index = try XCTUnwrap(writer.entries.firstIndex { $0.name == "META-INF/encryption.xml" })
        writer.entries[index].crc = 0xDEAD_BEEF
        // Read and dropped, it would have let a protected book through.
        XCTAssertThrowsError(try readEpubBook(try ZipArchive(data: writer.build()), fallbackTitle: "x")) {
            XCTAssertEqual(
                $0 as? BookImportError, .unreadable(ArchiveError.badChecksum("META-INF/encryption.xml").description))
        }
    }

    func testADamagedNavigationFileStillImportsTheBook() throws {
        var book = EpubBuilder()
        book.chapters = chapters(2)
        book.navigation = "<nav epub:type=\"toc\"><ol><li><a href=\"ch1.xhtml\">One</a></li></ol></nav>"
        var writer = book.zip()
        let index = try XCTUnwrap(writer.entries.firstIndex { $0.name == "OEBPS/nav.xhtml" })
        writer.entries[index].crc = 0xDEAD_BEEF
        let package = try readPackage(try ZipArchive(data: writer.build()))
        XCTAssertEqual(package.spine.count, 2)
        XCTAssertTrue(package.tableOfContentsLabels.isEmpty)
    }

    func testAMissingContainerIsRefusedByName() {
        var writer = ZipWriter()
        writer.add("mimetype", "application/epub+zip")
        XCTAssertThrowsError(try readEpubBook(try ZipArchive(data: writer.build()), fallbackTitle: "x")) {
            XCTAssertEqual($0 as? BookImportError, .unreadable(EpubPackageError.noContainer.description))
        }
    }

    func testHrefsResolveAndRefuseToClimbOut() throws {
        XCTAssertEqual(try resolveHref("../text/a%20b.xhtml#p3", base: "OEBPS/nav"), "OEBPS/text/a b.xhtml")
        XCTAssertEqual(try resolveHref("./c.xhtml", base: "OEBPS"), "OEBPS/c.xhtml")
        XCTAssertThrowsError(try resolveHref("../../x", base: "OEBPS"))
        XCTAssertThrowsError(try resolveHref("http://example.com/x", base: ""))
        for href in ["data:text/html,x", "file:ch.xhtml", "//host/ch.xhtml", "mailto:a@b.c", "urn:isbn:1"] {
            XCTAssertThrowsError(try resolveHref(href, base: "OEBPS"), href)
        }
        XCTAssertEqual(try resolveHref("a:b/c.xhtml".replacingOccurrences(of: ":", with: "%3A"), base: ""), "a:b/c.xhtml")
    }
}
