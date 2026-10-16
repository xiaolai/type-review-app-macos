import Compression
import Foundation
import XCTest

@testable import TypeReviewKit

/// Writes ZIP files in memory, stored or deflated, with every header field
/// open to a lie — which is how the refusals are tested without a binary
/// fixture for each.
struct ZipWriter {
    struct Entry {
        var name: String
        var data: Data
        var deflate = false
        /// Overrides, applied to both headers.
        var method: UInt16?
        var flags: UInt16 = 0
        var crc: UInt32?
        var size: UInt32?
        var compressedSize: UInt32?
    }

    var entries: [Entry] = []
    /// Overrides for the end-of-central-directory record.
    var totalEntries: UInt16?
    var directoryOffset: UInt32?

    mutating func add(_ name: String, _ text: String, deflate: Bool = false) {
        entries.append(Entry(name: name, data: Data(text.utf8), deflate: deflate))
    }

    mutating func add(_ name: String, data: Data, deflate: Bool = false) {
        entries.append(Entry(name: name, data: data, deflate: deflate))
    }

    func build() -> Data {
        var out = Data()
        var directory = Data()
        for entry in entries {
            let payload = entry.deflate ? rawDeflate(entry.data) : entry.data
            let method = entry.method ?? (entry.deflate ? 8 : 0)
            let crc = entry.crc ?? crc32(entry.data)
            let size = entry.size ?? UInt32(entry.data.count)
            let compressed = entry.compressedSize ?? UInt32(payload.count)
            let name = Data(entry.name.utf8)
            let offset = UInt32(out.count)

            out.append(le32(0x0403_4b50))
            out.append(le16(20))
            out.append(le16(entry.flags))
            out.append(le16(method))
            out.append(le32(0))  // time and date
            out.append(le32(crc))
            out.append(le32(compressed))
            out.append(le32(size))
            out.append(le16(UInt16(name.count)))
            out.append(le16(0))
            out.append(name)
            out.append(payload)

            directory.append(le32(0x0201_4b50))
            directory.append(le16(20))
            directory.append(le16(20))
            directory.append(le16(entry.flags))
            directory.append(le16(method))
            directory.append(le32(0))
            directory.append(le32(crc))
            directory.append(le32(compressed))
            directory.append(le32(size))
            directory.append(le16(UInt16(name.count)))
            directory.append(le16(0))  // extra
            directory.append(le16(0))  // comment
            directory.append(le16(0))  // disk
            directory.append(le16(0))  // internal attributes
            directory.append(le32(0))  // external attributes
            directory.append(le32(offset))
            directory.append(name)
        }
        let directoryStart = UInt32(out.count)
        out.append(directory)
        out.append(le32(0x0605_4b50))
        out.append(le16(0))
        out.append(le16(0))
        out.append(le16(totalEntries ?? UInt16(entries.count)))
        out.append(le16(totalEntries ?? UInt16(entries.count)))
        out.append(le32(UInt32(directory.count)))
        out.append(le32(directoryOffset ?? directoryStart))
        out.append(le16(0))
        return out
    }

    private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

/// Raw DEFLATE, which is what ZIP stores and what `COMPRESSION_ZLIB` writes.
func rawDeflate(_ data: Data) -> Data {
    let capacity = data.count + 1024
    var out = Data(count: capacity)
    let written = out.withUnsafeMutableBytes { target in
        data.withUnsafeBytes { source in
            compression_encode_buffer(
                target.bindMemory(to: UInt8.self).baseAddress!, capacity,
                source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
    }
    precondition(written > 0, "deflate wrote nothing")
    return out.prefix(written)
}

// MARK: - Books

/// One spine file of a built EPUB.
struct BuiltChapter {
    var name: String
    var body: String
    var bodyAttributes = ""
    var linear = true
    /// The whole file, when the test needs a header the builder would not write.
    var raw: String?

    init(_ name: String, _ body: String, bodyAttributes: String = "", linear: Bool = true, raw: String? = nil) {
        self.name = name
        self.body = body
        self.bodyAttributes = bodyAttributes
        self.linear = linear
        self.raw = raw
    }

    var file: String {
        raw ?? """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>\(name)</title></head>
            <body\(bodyAttributes.isEmpty ? "" : " " + bodyAttributes)>
            \(body)
            </body>
            </html>
            """
    }
}

/// Builds an EPUB in memory: the container, a package naming the chapters
/// in order, and whatever else the test adds.
struct EpubBuilder {
    var title = "A Built Book"
    var creator = "A. Tester"
    var language = "en"
    var version = "3.0"
    var chapters: [BuiltChapter] = []
    /// Extra lines inside `<metadata>`.
    var metadata = ""
    /// Extra lines inside `<manifest>`.
    var manifest = ""
    /// A `<guide>` block, EPUB 2.
    var guide = ""
    /// The EPUB 3 navigation document's body, when there is one.
    var navigation: String?
    var extraFiles: [(String, Data)] = []
    var deflate = true

    func zip() -> ZipWriter {
        var writer = ZipWriter()
        writer.add("mimetype", "application/epub+zip")
        writer.add(
            "META-INF/container.xml",
            """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """, deflate: deflate)
        var items = ""
        var spine = ""
        for (index, chapter) in chapters.enumerated() {
            items += "<item id=\"c\(index)\" href=\"\(chapter.name)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"c\(index)\"\(chapter.linear ? "" : " linear=\"no\"")/>\n"
            writer.add("OEBPS/\(chapter.name)", chapter.file, deflate: deflate)
        }
        if let navigation {
            items += "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
            writer.add(
                "OEBPS/nav.xhtml",
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
                <head><title>Navigation</title></head><body>\(navigation)</body></html>
                """, deflate: deflate)
        }
        writer.add(
            "OEBPS/content.opf",
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="\(version)" unique-identifier="id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title><dc:creator>\(creator)</dc:creator><dc:language>\(language)</dc:language>
            <dc:identifier id="id">urn:uuid:test</dc:identifier>
            \(metadata)
            </metadata>
            <manifest>
            \(items)\(manifest)
            </manifest>
            <spine>
            \(spine)</spine>
            \(guide)
            </package>
            """, deflate: deflate)
        for (name, data) in extraFiles { writer.add(name, data: data, deflate: deflate) }
        return writer
    }

    func archive() throws -> ZipArchive { try ZipArchive(data: zip().build()) }

    func draft() throws -> BookDraft { try readEpubBook(try archive(), fallbackTitle: "fallback") }

    func contents() throws -> EpubContents { try readEpubContents(try archive(), fallbackTitle: "fallback") }
}

/// Original prose, long enough for a chapter: none of it is from a book.
func storyParagraphs(_ count: Int, seed: Int = 0) -> String {
    let sentences = [
        "The river ran fast and brown after the night of rain.",
        "Ada walked along the bank with her hands in her pockets, counting the ducks.",
        "At the bend she found a small wooden boat caught in the reeds.",
        "It had a red sail and a name painted on its side in careful white letters.",
        "She pulled it free and turned it over to let the water run out.",
        "Somebody had made it with great care, and somebody would be missing it.",
        "She decided to carry it to the village and ask at the shop.",
        "The shopkeeper looked at the boat for a long time before he spoke.",
        "He said that his brother had made boats like this when they were young.",
        "They walked together to the old house by the mill to find out more.",
    ]
    var paragraphs: [String] = []
    for index in 0..<count {
        let start = (index * 3 + seed) % sentences.count
        let picked = (0..<4).map { sentences[(start + $0) % sentences.count] }
        paragraphs.append("<p>" + picked.joined(separator: " ") + "</p>")
    }
    return paragraphs.joined(separator: "\n")
}

/// Parses one chapter body the way the reader does.
func chapterOf(_ body: String, bodyAttributes: String = "") throws -> ChapterText {
    let file = BuiltChapter("c.xhtml", body, bodyAttributes: bodyAttributes).file
    return chapterText(try parseMarkup(Data(file.utf8)))
}

/// The paragraph and verse text of a chapter, one string per block.
func blockTexts(_ text: ChapterText) -> [String] {
    text.blocks.filter { $0.kind == .paragraph || $0.kind == .verse }.map { $0.lines.joined(separator: " / ") }
}

/// The invariants every fixture must hold, whatever else it tests.
func assertSentenceInvariants(
    _ contents: EpubContents, file: StaticString = #filePath, line: UInt = #line
) {
    for source in contents.sources {
        let split = splitIntoSentences(source.blocks)
        XCTAssertEqual(split.truncatedPieces, 0, "\(source.title): text was cut", file: file, line: line)
        for sentence in split.sentences {
            XCTAssertFalse(
                sentence.trimmingCharacters(in: .whitespaces).isEmpty, "\(source.title): an empty unit",
                file: file, line: line)
            XCTAssertLessThanOrEqual(
                sentence.utf16.count, maxBookSentenceChars, "\(source.title): \(sentence.prefix(60))…",
                file: file, line: line)
        }
    }
}

func fixtureURL(_ name: String) throws -> URL {
    try XCTUnwrap(
        Bundle.module.url(forResource: "Fixtures/epub/\(name)", withExtension: "epub"),
        "Fixtures/epub/\(name).epub is not in the test bundle")
}
