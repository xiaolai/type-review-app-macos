import XCTest

@testable import TypeReviewKit

/// What a hostile EPUB can do to an XML parser, and that none of it works:
/// entity expansion, external entities, and references the pre-pass might
/// not see.
final class EpubParserSafetyTests: XCTestCase {
    private func xhtml(_ doctype: String, _ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        \(doctype)
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head>
        <body>\(body)</body></html>
        """
    }

    private let billionLaughs = """
        <!DOCTYPE html [
        <!ENTITY lol "lol">
        <!ENTITY lol1 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
        <!ENTITY lol2 "&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;">
        <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
        <!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">
        <!ENTITY lol5 "&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;">
        <!ENTITY lol6 "&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;">
        <!ENTITY lol7 "&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;">
        <!ENTITY lol8 "&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;">
        <!ENTITY lol9 "&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;">
        ]>
        """

    /// A file outside the book, holding text that must never reach a draft.
    private func secretFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString).txt")
        try Data("TOPSECRETWORDS".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func book(with chapter: String) -> EpubBuilder {
        var book = EpubBuilder()
        book.chapters = [
            BuiltChapter("ch1.xhtml", "<h1>One</h1>" + storyParagraphs(4)),
            BuiltChapter("hostile.xhtml", "", raw: chapter),
        ]
        return book
    }

    // MARK: Entity expansion

    func testABillionLaughsChapterIsRefusedAndExpandsNothing() throws {
        let chapter = xhtml(billionLaughs, "<p>&lol9;</p>")
        XCTAssertThrowsError(try parseMarkup(Data(chapter.utf8))) {
            XCTAssertEqual($0 as? MarkupError, .entityDeclaration)
        }
        let draft = try book(with: chapter).draft()
        XCTAssertTrue(draft.warnings.contains(.unreadableFiles(["OEBPS/hostile.xhtml"])), "\(draft.warnings)")
        XCTAssertFalse(draft.chapters.flatMap(\.sentences).contains { $0.contains("lol") })
    }

    func testABillionLaughsPackageRefusesTheBook() throws {
        var writer = EpubBuilder().zip()
        let index = try XCTUnwrap(writer.entries.firstIndex { $0.name == "OEBPS/content.opf" })
        let opf = String(decoding: writer.entries[index].data, as: UTF8.self)
            .replacingOccurrences(of: "<package", with: billionLaughs.replacingOccurrences(of: "html", with: "package") + "\n<package")
        writer.entries[index] = .init(name: "OEBPS/content.opf", data: Data(opf.utf8))
        XCTAssertThrowsError(try readEpubBook(try ZipArchive(data: writer.build()), fallbackTitle: "x")) {
            XCTAssertEqual(
                $0 as? BookImportError, .unreadable(EpubPackageError.unsafeMarkup("OEBPS/content.opf").description))
        }
    }

    func testDeclarationsAreFoundHoweverTheyAreWritten() {
        for doctype in [
            "<!DOCTYPE html [ ]>", "<!doctype html [<!entity x \"y\">]>", "<!DOCTYPE html SYSTEM \"x.dtd\" [\n]>",
            "<!-- <!ENTITY x \"y\"> -->",
        ] {
            XCTAssertThrowsError(try parseMarkup(Data(xhtml(doctype, "<p>text</p>").utf8)), doctype) {
                XCTAssertEqual($0 as? MarkupError, .entityDeclaration, doctype)
            }
        }
    }

    func testTheXHTMLDoctypeAloneIsAllowed() throws {
        let file = xhtml(
            "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">",
            "<p>Plain&nbsp;text.</p>")
        XCTAssertEqual(blockTexts(chapterText(try parseMarkup(Data(file.utf8)))), ["Plain text."])
    }

    // MARK: External entities

    func testASystemEntityDoesNotReadAFile() throws {
        let secret = try secretFile()
        let chapter = xhtml("<!DOCTYPE html [<!ENTITY leak SYSTEM \"\(secret.absoluteString)\">]>", "<p>A &leak; B</p>")
        let draft = try book(with: chapter).draft()
        XCTAssertFalse(draft.chapters.flatMap(\.sentences).contains { $0.contains("TOPSECRET") })
        XCTAssertTrue(draft.warnings.contains(.unreadableFiles(["OEBPS/hostile.xhtml"])), "\(draft.warnings)")
    }

    /// The parser itself, below the declaration check: with an external
    /// entity handed straight to it, strict and tidy alike, the file's text
    /// never appears. This is what fails if the option is dropped.
    func testTheParserNeverLoadsAnExternalEntity() throws {
        let secret = try secretFile()
        let file = xhtml("<!DOCTYPE html [<!ENTITY leak SYSTEM \"\(secret.absoluteString)\">]>", "<p>A &leak; B</p>")
        var parsed = 0
        for tidy in [false, true] {
            guard let document = try? makeDocument(Data(file.utf8), tidy: tidy) else { continue }
            parsed += 1
            XCTAssertFalse(document.xmlString.contains("TOPSECRET"), "tidy: \(tidy)")
            XCTAssertFalse(textOf(document).contains("TOPSECRET"), "tidy: \(tidy)")
        }
        // A parser that refused both would pass the loop without testing it.
        XCTAssertGreaterThan(parsed, 0, "neither parse ran, so nothing was tested")
    }

    func testOnlyOneCallSiteBuildsADocument() throws {
        // `makeDocument` is the one place the options are set. A second
        // `XMLDocument(` in the Kit could forget them.
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TypeReviewKit")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var sites: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("XMLDocument(") || line.contains("XMLParser(") {
                sites.append("\(url.lastPathComponent):\(number + 1)")
            }
        }
        XCTAssertEqual(sites.count, 1, "\(sites)")
        XCTAssertTrue(sites.first?.hasPrefix("XHTMLText.swift") ?? false, "\(sites)")
    }

    // MARK: References the pre-pass must see

    func testEveryNamedReferenceIsMappedOrRefused() {
        let long = String(repeating: "x", count: 40)
        for name in [long, "café", "a.b-c", "x:y", "_under"] {
            XCTAssertThrowsError(try entityPrePass("a &\(name); b"), name) {
                XCTAssertEqual($0 as? MarkupError, .unknownEntity(name), name)
            }
        }
    }

    func testANonUTF8ChapterGetsThePrePassAndTheCheck() throws {
        let latin = xhtml("", "<p>Caf\u{E9}&nbsp;au&mdash;lait.</p>")
            .replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"ISO-8859-1\"")
        let data = try XCTUnwrap(latin.data(using: .isoLatin1))
        XCTAssertNil(String(data: data, encoding: .utf8), "the fixture must not be UTF-8")
        XCTAssertEqual(blockTexts(chapterText(try parseMarkup(data))), ["Caf\u{E9} au\u{2014}lait."])

        let hostile = xhtml(billionLaughs, "<p>Caf\u{E9} &lol9;</p>")
            .replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"ISO-8859-1\"")
        XCTAssertThrowsError(try parseMarkup(try XCTUnwrap(hostile.data(using: .isoLatin1)))) {
            XCTAssertEqual($0 as? MarkupError, .entityDeclaration)
        }
    }

    func testAUTF16ChapterGetsTheCheck() throws {
        let hostile = xhtml(billionLaughs, "<p>&lol9;</p>").replacingOccurrences(of: "UTF-8", with: "UTF-16")
        for encoding: String.Encoding in [.utf16, .utf16LittleEndian, .utf16BigEndian] {
            let data = try XCTUnwrap(hostile.data(using: encoding))
            XCTAssertThrowsError(try parseMarkup(data), "\(encoding)") {
                XCTAssertEqual($0 as? MarkupError, .entityDeclaration, "\(encoding)")
            }
        }
        let fine = xhtml("", "<p>Hello&nbsp;there.</p>").replacingOccurrences(of: "UTF-8", with: "UTF-16")
        XCTAssertEqual(
            blockTexts(chapterText(try parseMarkup(try XCTUnwrap(fine.data(using: .utf16LittleEndian))))),
            ["Hello there."])
    }

    func testANulByteIsRefused() {
        var data = Data(xhtml("", "<p>text</p>").utf8)
        data.insert(0, at: 60)
        XCTAssertThrowsError(try parseMarkup(data)) { XCTAssertEqual($0 as? MarkupError, .unparseable) }
    }
}
