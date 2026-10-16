import XCTest

@testable import TypeReviewKit

/// §3.1: the archive reader, and every limit it enforces, each refused by
/// name.
final class EpubArchiveTests: XCTestCase {
    private func refusal(_ data: Data, reading name: String? = nil) -> ArchiveError? {
        do {
            let archive = try ZipArchive(data: data)
            if let name { _ = try archive.read(name) }
            return nil
        } catch let error as ArchiveError {
            return error
        } catch {
            XCTFail("not an ArchiveError: \(error)")
            return nil
        }
    }

    func testAStoredEntryReadsBack() throws {
        var writer = ZipWriter()
        writer.add("a.txt", "stored text")
        let archive = try ZipArchive(data: writer.build())
        XCTAssertEqual(archive.names, ["a.txt"])
        XCTAssertEqual(String(decoding: try archive.read("a.txt"), as: UTF8.self), "stored text")
    }

    func testADeflatedEntryReadsBack() throws {
        let text = String(repeating: "The kite rose over the hill. ", count: 200)
        var writer = ZipWriter()
        writer.add("text/a.xhtml", text, deflate: true)
        let data = writer.build()
        XCTAssertLessThan(data.count, text.utf8.count / 4, "the entry was not compressed")
        let archive = try ZipArchive(data: data)
        XCTAssertEqual(String(decoding: try archive.read("text/a.xhtml"), as: UTF8.self), text)
    }

    func testAnEmptyDeflatedEntryReadsAsEmpty() throws {
        var writer = ZipWriter()
        writer.entries.append(.init(name: "empty", data: Data(), method: 8, compressedSize: 0))
        XCTAssertEqual(try ZipArchive(data: writer.build()).read("empty"), Data())
    }

    func testAFolderReadsLikeAnArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-\(UUID().uuidString).epub")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: root.appendingPathComponent("OEBPS/a.xhtml"))
        try Data("mime".utf8).write(to: root.appendingPathComponent("mimetype"))
        // A link inside the folder to a file outside it is not part of the book.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("OEBPS/link.xhtml"), withDestinationURL: outside)

        let archive = try FolderArchive(root: root)
        XCTAssertEqual(Set(archive.names), ["mimetype", "OEBPS/a.xhtml"])
        XCTAssertEqual(try archive.read("OEBPS/a.xhtml"), Data("one".utf8))
        XCTAssertThrowsError(try archive.read("OEBPS/link.xhtml"))
        XCTAssertThrowsError(try archive.read("../" + outside.lastPathComponent)) {
            XCTAssertEqual($0 as? ArchiveError, .unsafeName("../" + outside.lastPathComponent))
        }
    }

    func testZip64IsRefused() {
        var writer = ZipWriter()
        writer.add("a.txt", "text")
        writer.entries[0].size = 0xFFFF_FFFF
        XCTAssertEqual(refusal(writer.build()), .zip64)

        var marker = ZipWriter()
        marker.add("a.txt", "text")
        marker.totalEntries = 0xFFFF
        XCTAssertEqual(refusal(marker.build()), .zip64)
    }

    func testAnUnknownMethodIsRefused() {
        var writer = ZipWriter()
        writer.add("a.txt", "text")
        writer.entries[0].method = 12  // bzip2
        XCTAssertEqual(refusal(writer.build(), reading: "a.txt"), .unsupportedMethod(12, "a.txt"))
    }

    func testAnEncryptedEntryIsRefused() {
        var writer = ZipWriter()
        writer.add("a.txt", "text")
        writer.entries[0].flags = 1
        XCTAssertEqual(refusal(writer.build(), reading: "a.txt"), .encryptedEntry("a.txt"))
    }

    func testAnOversizedEntryIsRefused() {
        var writer = ZipWriter()
        writer.add("big.xhtml", "small really")
        writer.entries[0].size = UInt32(maxArchiveEntryBytes + 1)
        XCTAssertEqual(refusal(writer.build(), reading: "big.xhtml"), .entryTooLarge("big.xhtml"))
    }

    func testAHighRatioIsRefused() {
        // Two megabytes of one letter deflates to about two kilobytes: a
        // thousand to one, ten times what text ever reaches.
        let bomb = Data(repeating: UInt8(ascii: "a"), count: 2 << 20)
        var writer = ZipWriter()
        writer.add("bomb.xhtml", data: bomb, deflate: true)
        XCTAssertEqual(refusal(writer.build(), reading: "bomb.xhtml"), .suspiciousRatio("bomb.xhtml"))
    }

    func testTheTotalReadIsBounded() throws {
        // One 15 MB entry, under the entry limit, read five times: together
        // past the archive's. Letters from a sixteen-letter alphabet deflate
        // about two to one, well inside the ratio limit.
        var chunk = Data(count: 15 << 20)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        chunk.withUnsafeMutableBytes { bytes in
            for index in bytes.indices {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes[index] = UInt8(ascii: "a") + UInt8(state & 15)
            }
        }
        var writer = ZipWriter()
        writer.add("part", data: chunk, deflate: true)
        let archive = try ZipArchive(data: writer.build())
        for _ in 0..<4 { _ = try archive.read("part") }
        XCTAssertThrowsError(try archive.read("part")) {
            XCTAssertEqual($0 as? ArchiveError, .readLimitExceeded)
        }
    }

    func testATraversalNameRefusesTheWholeArchive() {
        for name in ["../evil.xhtml", "OEBPS/../../evil", "/etc/passwd", "OEBPS\\evil"] {
            var writer = ZipWriter()
            writer.add("mimetype", "application/epub+zip")
            writer.add(name, "x")
            XCTAssertEqual(refusal(writer.build()), .unsafeName(name), name)
        }
    }

    func testATruncatedFileIsRefused() {
        var writer = ZipWriter()
        writer.add("a.txt", String(repeating: "text ", count: 100))
        let whole = writer.build()
        // Cut inside the central directory: the end record is gone.
        XCTAssertEqual(refusal(whole.prefix(whole.count - 30)), .truncated)
        // A directory that points past the end of the file.
        var lying = writer
        lying.directoryOffset = UInt32(whole.count + 100)
        XCTAssertEqual(refusal(lying.build()), .truncated)
        // An entry whose data runs past the end.
        var short = writer
        short.entries[0].compressedSize = 100_000
        short.entries[0].size = 100_000
        XCTAssertEqual(refusal(short.build(), reading: "a.txt"), .truncated)
    }

    func testABadChecksumIsRefused() {
        var writer = ZipWriter()
        writer.add("a.txt", "text", deflate: true)
        writer.entries[0].crc = 0xDEAD_BEEF
        XCTAssertEqual(refusal(writer.build(), reading: "a.txt"), .badChecksum("a.txt"))
    }

    func testANonZipIsRefused() {
        XCTAssertEqual(refusal(Data(repeating: 0x20, count: 100)), .notZip)
        XCTAssertEqual(refusal(Data("PK".utf8)), .notZip)
    }

    func testTheReaderMapsArchiveRefusalsToImportErrors() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).epub")
        try Data(repeating: 0x20, count: 100).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try readEpubBook(at: file)) {
            XCTAssertEqual($0 as? BookImportError, .unreadable(ArchiveError.notZip.description))
        }
    }

    func testCRC32MatchesTheKnownValue() {
        XCTAssertEqual(crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }
}
