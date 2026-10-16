import Compression
import Foundation

/// The largest EPUB read. 24 of 2,293 distinct files on the Mac this was
/// measured on exceed it, every one illustrated or scanned — books with
/// pages of pictures and little text to type.
public let maxEpubBytes = 64 << 20
/// Entries in one archive. Bounds central-directory parsing; one real file
/// exceeded it.
let maxArchiveEntries = 10_000
/// One entry, inflated. No novel's chapter comes close.
let maxArchiveEntryBytes = 16 << 20
/// Every entry read from one archive, inflated: the zip-bomb bound.
let maxArchiveReadBytes = 64 << 20
/// The highest compression ratio accepted for an entry over a megabyte. Text
/// compresses three to five times; a hundred times is a file built to inflate.
let maxArchiveRatio = 100.0

/// Why an archive could not be read, by name. A broken book is reported as
/// what is wrong with it, because "could not open" leaves a parent nothing to do.
public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    case tooLarge(Int)
    case notZip
    case truncated
    case zip64
    case tooManyEntries(Int)
    case encryptedEntry(String)
    case unsupportedMethod(UInt16, String)
    case entryTooLarge(String)
    case suspiciousRatio(String)
    case unsafeName(String)
    case inflateFailed(String)
    case badChecksum(String)
    case missing(String)
    case readLimitExceeded

    public var description: String {
        switch self {
        case .tooLarge: return "it is larger than \(maxEpubBytes >> 20) MB"
        case .notZip: return "it is not a ZIP archive"
        case .truncated: return "the file is cut short"
        case .zip64: return "it uses ZIP64, which no EPUB needs"
        case .tooManyEntries(let count): return "it holds \(count) files, more than \(maxArchiveEntries)"
        case .encryptedEntry(let name): return "\(name) is encrypted"
        case .unsupportedMethod(let method, let name): return "\(name) uses compression method \(method)"
        case .entryTooLarge(let name): return "\(name) is larger than \(maxArchiveEntryBytes >> 20) MB"
        case .suspiciousRatio(let name): return "\(name) inflates more than \(Int(maxArchiveRatio)) times"
        case .unsafeName(let name): return "it names a file outside itself: \(name)"
        case .inflateFailed(let name): return "\(name) does not inflate"
        case .badChecksum(let name): return "\(name) fails its checksum"
        case .missing(let name): return "\(name) is missing"
        case .readLimitExceeded: return "its text inflates past \(maxArchiveReadBytes >> 20) MB"
        }
    }
}

/// An EPUB's files, whichever shape it arrived in.
///
/// Two shapes, and both are common. Apple Books keeps every EPUB in its
/// iCloud folder as a *directory* named `*.epub`; 376 of the books on the
/// measured Mac were stored that way, and a parent dragging one out of Apple
/// Books hands the app a folder. Everything else is a ZIP file.
public protocol BookArchive: AnyObject {
    /// Every file, as a path relative to the archive's root.
    var names: [String] { get }
    func contains(_ name: String) -> Bool
    /// One file's bytes, under the limits above. Reading counts against the
    /// archive's total, so a book cannot inflate past it piece by piece.
    func read(_ name: String) throws -> Data
}

/// A name that stays inside the archive: no `..`, no leading `/`, no `\`.
/// Nothing is ever extracted to disk, but a hostile name is a hostile file.
func isSafeArchiveName(_ name: String) -> Bool {
    guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
    return !name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
}

struct ZipEntry {
    let name: String
    let flags: UInt16
    let method: UInt16
    let crc: UInt32
    let compressedSize: Int
    let size: Int
    let localOffset: Int
}

/// A ZIP read from memory, without extracting anything.
///
/// The central directory is the index; each entry is inflated with the
/// Compression framework, whose `COMPRESSION_ZLIB` is raw DEFLATE — what ZIP
/// stores — so there is no dependency. Every inflated entry is checked
/// against its CRC-32, because a decoder that fills its buffer silently
/// truncates a longer stream and a checksum is what notices.
public final class ZipArchive: BookArchive {
    private let data: Data
    private var entries: [String: ZipEntry] = [:]
    public private(set) var names: [String] = []
    private var bytesRead = 0

    public convenience init(contentsOf url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxEpubBytes else { throw ArchiveError.tooLarge(size) }
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            throw ArchiveError.missing(url.lastPathComponent)
        }
        try self.init(data: data)
    }

    public init(data: Data) throws {
        self.data = data
        guard data.count <= maxEpubBytes else { throw ArchiveError.tooLarge(data.count) }
        guard data.count >= 22 else { throw ArchiveError.notZip }
        let first = u32(0)
        guard first == 0x0403_4b50 || first == 0x0605_4b50 else { throw ArchiveError.notZip }

        // The end-of-central-directory record, searched for from the end: it
        // may be followed by a comment of up to 65,535 bytes.
        var eocd = -1
        var position = data.count - 22
        let floor = max(0, data.count - 22 - 65_535)
        while position >= floor {
            if u32(position) == 0x0605_4b50 {
                eocd = position
                break
            }
            position -= 1
        }
        guard eocd >= 0 else { throw ArchiveError.truncated }
        let total = Int(u16(eocd + 10))
        let directorySize = Int(u32(eocd + 12))
        let directoryOffset = Int(u32(eocd + 16))
        if total == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw ArchiveError.zip64
        }
        if eocd >= 20 && u32(eocd - 20) == 0x0706_4b50 { throw ArchiveError.zip64 }
        guard total <= maxArchiveEntries else { throw ArchiveError.tooManyEntries(total) }
        guard directoryOffset + directorySize <= data.count else { throw ArchiveError.truncated }

        var cursor = directoryOffset
        for _ in 0..<total {
            guard cursor + 46 <= data.count, u32(cursor) == 0x0201_4b50 else { throw ArchiveError.truncated }
            let flags = u16(cursor + 8)
            let method = u16(cursor + 10)
            let crc = u32(cursor + 16)
            let compressedSize = u32(cursor + 20)
            let size = u32(cursor + 24)
            let nameLength = Int(u16(cursor + 28))
            let extraLength = Int(u16(cursor + 30))
            let commentLength = Int(u16(cursor + 32))
            let localOffset = u32(cursor + 42)
            if compressedSize == 0xFFFF_FFFF || size == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ArchiveError.zip64
            }
            guard cursor + 46 + nameLength <= data.count else { throw ArchiveError.truncated }
            let rawName = data.subdata(in: (data.startIndex + cursor + 46)..<(data.startIndex + cursor + 46 + nameLength))
            let name = String(data: rawName, encoding: .utf8) ?? String(decoding: rawName, as: UTF8.self)
            guard isSafeArchiveName(name) else { throw ArchiveError.unsafeName(name) }
            if !name.hasSuffix("/") {
                entries[name] = ZipEntry(
                    name: name, flags: flags, method: method, crc: crc, compressedSize: Int(compressedSize),
                    size: Int(size), localOffset: Int(localOffset))
                names.append(name)
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
    }

    public func contains(_ name: String) -> Bool { entries[name] != nil }

    public func read(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw ArchiveError.missing(name) }
        if entry.flags & 1 != 0 { throw ArchiveError.encryptedEntry(name) }
        guard entry.size <= maxArchiveEntryBytes else { throw ArchiveError.entryTooLarge(name) }
        guard bytesRead + entry.size <= maxArchiveReadBytes else { throw ArchiveError.readLimitExceeded }
        let local = entry.localOffset
        guard local + 30 <= data.count, u32(local) == 0x0403_4b50 else { throw ArchiveError.truncated }
        let start = local + 30 + Int(u16(local + 26)) + Int(u16(local + 28))
        guard start + entry.compressedSize <= data.count else { throw ArchiveError.truncated }
        let ratio = Double(entry.size) / Double(max(entry.compressedSize, 1))
        if entry.size > 1 << 20 && ratio > maxArchiveRatio { throw ArchiveError.suspiciousRatio(name) }
        let source = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))

        let out: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw ArchiveError.inflateFailed(name) }
            out = source
        case 8:
            if entry.size == 0 {
                out = Data()
                break
            }
            // Nothing to inflate from, and an empty buffer has no address.
            guard entry.compressedSize > 0 else { throw ArchiveError.inflateFailed(name) }
            // Sized from the header, never from the stream, so a lie in the
            // header cannot allocate more than the entry limit allows.
            var destination = Data(count: entry.size)
            let written = destination.withUnsafeMutableBytes { target in
                source.withUnsafeBytes { input in
                    compression_decode_buffer(
                        target.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                        input.bindMemory(to: UInt8.self).baseAddress!, entry.compressedSize, nil,
                        COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw ArchiveError.inflateFailed(name) }
            out = destination
        default:
            throw ArchiveError.unsupportedMethod(entry.method, name)
        }
        guard crc32(out) == entry.crc else { throw ArchiveError.badChecksum(name) }
        bytesRead += out.count
        return out
    }

    private func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }
}

/// An EPUB kept as a folder, the way Apple Books keeps them.
///
/// The same limits as a ZIP. Paths are resolved and must stay under the
/// root, so a symbolic link inside the folder cannot hand the importer a file
/// from elsewhere on the disk.
public final class FolderArchive: BookArchive {
    private let root: URL
    private let rootPath: String
    public let names: [String]
    private var bytesRead = 0

    public init(root: URL) throws {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        self.root = resolved
        rootPath = resolved.path.hasSuffix("/") ? resolved.path : resolved.path + "/"
        var found: [String] = []
        if let enumerator = FileManager.default.enumerator(
            at: resolved, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [])
        {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath) else { continue }
                found.append(String(path.dropFirst(rootPath.count)))
                if found.count > maxArchiveEntries { throw ArchiveError.tooManyEntries(found.count) }
            }
        }
        names = found
    }

    private func location(_ name: String) throws -> URL {
        guard isSafeArchiveName(name) else { throw ArchiveError.unsafeName(name) }
        let url = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(rootPath) else { throw ArchiveError.unsafeName(name) }
        return url
    }

    public func contains(_ name: String) -> Bool {
        guard let url = try? location(name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func read(_ name: String) throws -> Data {
        let url = try location(name)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxArchiveEntryBytes else { throw ArchiveError.entryTooLarge(name) }
        guard bytesRead + size <= maxArchiveReadBytes else { throw ArchiveError.readLimitExceeded }
        guard let data = try? Data(contentsOf: url) else { throw ArchiveError.missing(name) }
        bytesRead += data.count
        return data
    }
}

private let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
    var value = UInt32(index)
    for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    return value
}

/// CRC-32 as ZIP computes it.
func crc32(_ data: Data) -> UInt32 {
    var value: UInt32 = 0xFFFF_FFFF
    data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        for byte in bytes { value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
    }
    return value ^ 0xFFFF_FFFF
}
