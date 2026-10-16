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
        // The two-byte stream a deflater writes for nothing: 03 00.
        var writer = ZipWriter()
        writer.entries.append(.init(name: "empty", data: Data([0x03, 0x00]), method: 8, crc: 0, size: 0))
        XCTAssertEqual(try ZipArchive(data: writer.build()).read("empty"), Data())
    }

    func testADeflatedEntryWithNoStreamAtAllIsRefused() {
        var writer = ZipWriter()
        writer.entries.append(.init(name: "empty", data: Data(), method: 8, compressedSize: 0))
        XCTAssertEqual(refusal(writer.build(), reading: "empty"), .inflateFailed("empty"))
    }

    func testAForgedEndRecordThatFailsToParseIsPassedOver() throws {
        var writer = ZipWriter()
        writer.add("a.txt", "the real entry")
        var data = writer.build()
        // Bytes after the archive, ending in a forged record that ends the
        // file exactly — so it is tried before the real one — and claims one
        // entry at the real directory, in a size too small to hold it.
        let directoryOffset = UInt32(data.count - 22 - 51)
        var fake = Data([0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 1, 0, 1, 0])
        fake.append(contentsOf: [10, 0, 0, 0])
        fake.append(contentsOf: withUnsafeBytes(of: directoryOffset.littleEndian, Array.init))
        fake.append(contentsOf: [0, 0])
        data.append(fake)
        let archive = try ZipArchive(data: data)
        XCTAssertEqual(archive.names, ["a.txt"])
        XCTAssertEqual(String(decoding: try archive.read("a.txt"), as: UTF8.self), "the real entry")
    }

    func testAForgedEmptyEndRecordDoesNotHideTheEntries() throws {
        var writer = ZipWriter()
        writer.add("a.txt", "the real entry")
        // A forged record claiming no entries, whose own comment ends the file.
        writer.comment = Data("note ".utf8) + Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
        let archive = try ZipArchive(data: writer.build())
        XCTAssertEqual(archive.names, ["a.txt"])
    }

    func testAForgedEmptyEndRecordInsideAnEntryDoesNotHideTheEntries() throws {
        // A stored entry whose bytes are an end record claiming no entries,
        // with a comment length that runs it exactly to the end of the file.
        func build(commentLength: UInt16) -> Data {
            var writer = ZipWriter()
            writer.add("a.txt", "the real entry")
            var forged = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 16))
            forged.append(contentsOf: withUnsafeBytes(of: commentLength.littleEndian, Array.init))
            writer.add("b.bin", data: forged)
            return writer.build()
        }
        let draft = build(commentLength: 0)
        let signature = Data([0x50, 0x4B, 0x05, 0x06])
        let forgedAt = try XCTUnwrap(draft.range(of: signature)).lowerBound
        let data = build(commentLength: UInt16(draft.count - (forgedAt + 22)))
        XCTAssertEqual(data.count, draft.count)
        let archive = try ZipArchive(data: data)
        XCTAssertEqual(Set(archive.names), ["a.txt", "b.bin"])
        XCTAssertEqual(String(decoding: try archive.read("a.txt"), as: UTF8.self), "the real entry")
    }

    func testAnArchiveCommentIsReadPast() throws {
        var writer = ZipWriter()
        writer.add("a.txt", "the real entry")
        writer.comment = Data("Made by a writer that leaves a comment.".utf8)
        XCTAssertEqual(try ZipArchive(data: writer.build()).names, ["a.txt"])
    }

    func testACommentHoldingManyEndRecordsIsReadPast() throws {
        var writer = ZipWriter()
        writer.add("a.txt", "the real entry")
        let forged = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
        writer.comment = (0..<500).reduce(Data()) { data, _ in data + forged }
        let archive = try ZipArchive(data: writer.build())
        XCTAssertEqual(archive.names, ["a.txt"])
        XCTAssertEqual(String(decoding: try archive.read("a.txt"), as: UTF8.self), "the real entry")
    }

    func testAForgedDirectoryRepeatingOneNameDoesNotOutcountTheRealOne() throws {
        // A stored entry holding a directory of three records for "a.txt",
        // and an end record for it whose comment runs to the end of the file.
        var real = ZipWriter()
        real.add("a.txt", "the real entry")
        let single = real.build()
        let recordStart = try XCTUnwrap(single.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        let endStart = try XCTUnwrap(single.range(of: Data([0x50, 0x4B, 0x05, 0x06]))).lowerBound
        let record = single.subdata(in: recordStart..<endStart)
        func build(commentLength: UInt16, payloadOffset: UInt32) -> Data {
            var writer = ZipWriter()
            writer.add("a.txt", "the real entry")
            var payload = record + record + record
            var end = Data([0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 3, 0, 3, 0])
            end.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).littleEndian, Array.init))
            end.append(contentsOf: withUnsafeBytes(of: payloadOffset.littleEndian, Array.init))
            end.append(contentsOf: withUnsafeBytes(of: commentLength.littleEndian, Array.init))
            payload.append(end)
            writer.add("b.bin", data: payload)
            return writer.build()
        }
        let draft = build(commentLength: 0, payloadOffset: 0)
        let payloadAt = try XCTUnwrap(draft.range(of: record + record)).lowerBound
        let forgedEnd = payloadAt + record.count * 3
        let data = build(commentLength: UInt16(draft.count - (forgedEnd + 22)), payloadOffset: UInt32(payloadAt))
        XCTAssertEqual(data.count, draft.count)
        let archive = try ZipArchive(data: data)
        XCTAssertEqual(Set(archive.names), ["a.txt", "b.bin"])
    }

    /// An end record of no entries at `position`, tight against an empty
    /// directory there, whose comment runs to `fileEnd`.
    private func consistentEmptyEnd(at position: Int, fileEnd: Int) -> Data {
        var end = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 12))
        end.append(contentsOf: withUnsafeBytes(of: UInt32(position).littleEndian, Array.init))
        end.append(contentsOf: withUnsafeBytes(of: UInt16(fileEnd - position - 22).littleEndian, Array.init))
        return end
    }

    func testAFileEndingInManyConsistentIndexesIsRefused() throws {
        // Nine forged records in the comment, each laid out exactly as a real
        // one is: no parse cap can be trusted to reach the real record, and a
        // real EPUB has one, so the file is refused rather than guessed at.
        func build(_ comment: Data) -> Data {
            var writer = ZipWriter()
            writer.add("a.txt", "the real entry")
            writer.comment = comment
            return writer.build()
        }
        let placeholder = Data(count: 9 * 22)
        let count = build(placeholder).count
        let commentStart = count - placeholder.count
        let comment = (0..<9).reduce(Data()) { data, index in
            data + consistentEmptyEnd(at: commentStart + index * 22, fileEnd: count)
        }
        XCTAssertEqual(refusal(build(comment)), .ambiguousEnd(10))
    }

    func testTightForgeriesBeforeAnAppendedByteAreAllReadOrRefused() throws {
        // A byte after the archive takes the real record off the end of the
        // file, so no record is consistent and the tight ones are the tier
        // read. Capped, eight tight forgeries pushed the real one out.
        func build(forgeries: Int) throws -> Data {
            func archive(_ comment: Data) -> Data {
                var writer = ZipWriter()
                writer.add("a.txt", "the real entry")
                writer.comment = comment
                return writer.build()
            }
            let placeholder = Data(count: forgeries * 22)
            let count = archive(placeholder).count
            let commentStart = count - placeholder.count
            let comment = (0..<forgeries).reduce(Data()) { data, index in
                data + consistentEmptyEnd(at: commentStart + index * 22, fileEnd: count)
            }
            return archive(comment) + Data([0])
        }
        XCTAssertEqual(try ZipArchive(data: build(forgeries: 7)).names, ["a.txt"])
        XCTAssertEqual(refusal(try build(forgeries: 8)), .ambiguousEnd(9))
    }

    func testAnEmptyForgeryEndingTheFileDoesNotOutrankARealRecordBeforeIt() throws {
        // The real record is followed by a byte; a forged empty one in the
        // comment claims that byte as its own comment, so it alone ends the
        // file. It names nothing, and the real directory is read.
        var writer = ZipWriter()
        writer.add("a.txt", "the real entry")
        writer.add("b.bin", "more")
        let placeholder = Data(count: 22)
        writer.comment = placeholder
        let count = writer.build().count
        writer.comment = consistentEmptyEnd(at: count - 22, fileEnd: count + 1)
        let data = writer.build() + Data([0])
        XCTAssertEqual(try ZipArchive(data: data).names.sorted(), ["a.txt", "b.bin"])
    }

    func testInconsistentForgedIndexesNamingMoreFilesDoNotHideTheRealOne() throws {
        // Eight forged directories in the comment, each naming three files
        // the real one does not, each with an end record tight against it but
        // not ending the file — a byte after the last keeps even that one off
        // the end. The real record is the only consistent one; ranked by
        // layout alone, all eight came first and their three names won.
        var single = ZipWriter()
        single.add("a.txt", "the real entry")
        let built = single.build()
        let recordStart = try XCTUnwrap(built.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        let endStart = try XCTUnwrap(built.range(of: Data([0x50, 0x4B, 0x05, 0x06]))).lowerBound
        let record = built.subdata(in: recordStart..<endStart)
        func renamed(_ name: String) -> Data {
            var copy = record
            copy.replaceSubrange((copy.startIndex + 46)..<(copy.startIndex + 51), with: Data(name.utf8))
            return copy
        }
        let directory = renamed("c.txt") + renamed("d.txt") + renamed("e.txt")
        func build(_ comment: Data) -> Data {
            var writer = ZipWriter()
            writer.add("a.txt", "the real entry")
            writer.comment = comment
            return writer.build()
        }
        let unit = directory.count + 22
        let placeholder = Data(count: 8 * unit + 1)
        let commentStart = build(placeholder).count - placeholder.count
        let comment = (0..<8).reduce(Data()) { data, index in
            let directoryAt = commentStart + index * unit
            var end = Data([0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 3, 0, 3, 0])
            end.append(contentsOf: withUnsafeBytes(of: UInt32(directory.count).littleEndian, Array.init))
            end.append(contentsOf: withUnsafeBytes(of: UInt32(directoryAt).littleEndian, Array.init))
            end.append(contentsOf: [0, 0])
            return data + directory + end
        } + Data([0x20])
        let archive = try ZipArchive(data: build(comment))
        XCTAssertEqual(archive.names, ["a.txt"])
        XCTAssertEqual(String(decoding: try archive.read("a.txt"), as: UTF8.self), "the real entry")
    }

    func testAFolderReachedThroughALinkToItIsRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linked-\(UUID().uuidString).epub")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("mime".utf8).write(to: root.appendingPathComponent("mimetype"))
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString).epub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }
        let archive = try FolderArchive(root: link)
        XCTAssertEqual(archive.names, ["mimetype"])
        XCTAssertEqual(try archive.read("mimetype"), Data("mime".utf8))
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

    func testAnEndSignatureInsideTheCommentIsPassedOver() throws {
        var writer = ZipWriter()
        writer.add("a.txt", "the real entry")
        // A fake end record in the comment, nearer the end than the real one,
        // claiming one entry at offset zero with a comment far too long.
        var fake = Data([0x50, 0x4B, 0x05, 0x06])
        fake.append(Data(repeating: 0, count: 6))
        fake.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF])
        writer.comment = Data("note ".utf8) + fake
        let archive = try ZipArchive(data: writer.build())
        XCTAssertEqual(archive.names, ["a.txt"])
        XCTAssertEqual(String(decoding: try archive.read("a.txt"), as: UTF8.self), "the real entry")
    }

    func testARecordRunningPastTheDeclaredDirectoryIsRefused() {
        var writer = ZipWriter()
        writer.add("a.txt", "text")
        writer.directorySize = 40  // shorter than the one 51-byte record
        XCTAssertEqual(refusal(writer.build()), .truncated)
    }

    func testAStreamLongerThanItsHeaderSaysIsRefused() {
        // The header claims the first five bytes, with their checksum: a
        // one-shot decode filled five bytes, matched, and passed.
        let text = String(repeating: "The kite rose over the hill. ", count: 20)
        var writer = ZipWriter()
        writer.add("a.xhtml", text, deflate: true)
        writer.entries[0].size = 5
        writer.entries[0].crc = crc32(Data(text.utf8.prefix(5)))
        XCTAssertEqual(refusal(writer.build(), reading: "a.xhtml"), .inflateFailed("a.xhtml"))
    }

    func testAStreamCutShortIsRefused() {
        let text = String(repeating: "The kite rose over the hill. ", count: 20)
        let stream = rawDeflate(Data(text.utf8))
        var writer = ZipWriter()
        writer.entries.append(.init(name: "a.xhtml", data: stream.prefix(stream.count / 2), method: 8))
        writer.entries[0].size = UInt32(text.utf8.count)
        writer.entries[0].crc = crc32(Data(text.utf8))
        XCTAssertEqual(refusal(writer.build(), reading: "a.xhtml"), .inflateFailed("a.xhtml"))
    }

    func testAFolderRefusesALinkEvenToAFileInsideIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-\(UUID().uuidString).epub")
        let text = root.appendingPathComponent("OEBPS/text")
        try FileManager.default.createDirectory(at: text, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: text.appendingPathComponent("a.xhtml"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("OEBPS/b.xhtml"), withDestinationURL: text.appendingPathComponent("a.xhtml"))
        // A linked folder, as a middle component.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: text)

        let archive = try FolderArchive(root: root)
        XCTAssertEqual(try archive.read("OEBPS/text/a.xhtml"), Data("one".utf8))
        XCTAssertTrue(archive.contains("OEBPS/text/a.xhtml"))
        for name in ["OEBPS/b.xhtml", "linked/a.xhtml"] {
            XCTAssertFalse(archive.contains(name), name)
            XCTAssertThrowsError(try archive.read(name), name) {
                XCTAssertEqual($0 as? ArchiveError, .unsafeName(name))
            }
        }
        XCTAssertFalse(archive.contains("OEBPS/text"), "a folder is not a file")
        XCTAssertThrowsError(try archive.read("OEBPS/none.xhtml")) {
            XCTAssertEqual($0 as? ArchiveError, .missing("OEBPS/none.xhtml"))
        }
    }

    func testAFolderBoundsWhatItReadsNotWhatItWasTold() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-\(UUID().uuidString).epub")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("big.xhtml")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(maxArchiveEntryBytes + 1))
        try handle.close()
        let small = root.appendingPathComponent("small.xhtml")
        try Data(count: 15 << 20).write(to: small)

        let archive = try FolderArchive(root: root)
        XCTAssertThrowsError(try archive.read("big.xhtml")) {
            XCTAssertEqual($0 as? ArchiveError, .entryTooLarge("big.xhtml"))
        }
        for _ in 0..<4 { _ = try archive.read("small.xhtml") }
        XCTAssertThrowsError(try archive.read("small.xhtml")) {
            XCTAssertEqual($0 as? ArchiveError, .readLimitExceeded)
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
