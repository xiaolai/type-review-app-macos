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
    case ambiguousEnd

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
        case .ambiguousEnd: return "it ends in more directory records than any ZIP writer leaves"
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
    let flags: UInt16
    let method: UInt16
    let crc: UInt32
    let compressedSize: Int
    let size: Int
    let localOffset: Int
}

/// Where the central directory is, as the end record says.
private struct EndRecord {
    let total: Int
    let directoryOffset: Int
    let directorySize: Int
    /// Where the record itself starts.
    let position: Int
    /// Its comment ends exactly at the end of the file.
    let endsFile: Bool

    /// The directory ends where the record begins, as every writer lays it
    /// out.
    var isTight: Bool { directoryOffset + directorySize == position }
}

/// A ZIP read from memory, without extracting anything.
///
/// The central directory is the index; each entry is inflated with the
/// Compression framework, whose `COMPRESSION_ZLIB` is raw DEFLATE — what ZIP
/// stores — so there is no dependency. A deflated entry must end its stream
/// at exactly the size its header declares, and every entry is checked
/// against its CRC-32.
public final class ZipArchive: BookArchive {
    private let data: Data
    private let entries: [String: ZipEntry]
    public let names: [String]
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
        let first = data.le32(0)
        guard first == 0x0403_4b50 || first == 0x0605_4b50 else { throw ArchiveError.notZip }
        (entries, names) = try Self.index(data)
    }

    /// How many end-record candidates a file may hold. A real EPUB has one;
    /// a second is a signature that happens to sit in the last 64 KB. More
    /// than this is a file built to be read more than one way, and is
    /// refused rather than read the way that happens to come first.
    private static let maxEndCandidates = 8

    /// The directory that names the most files, of every candidate end
    /// record that parses.
    ///
    /// A forged record can sit in the archive's comment or inside an entry's
    /// stored bytes, and claim no entries — or a directory of its own. What
    /// it cannot do is take entries away from the real directory, so the
    /// reading that finds the most files is the one that hides none. Any
    /// rule by position alone is beaten by one of the two places: earliest
    /// first lost to a record in a stored entry, latest first to one in the
    /// comment. On a tie, a directory laid out the way writers lay it out
    /// wins, then one whose comment ends the file, then the one nearest the
    /// end. A candidate that fails to parse is passed over; when none parses,
    /// the failure of the likeliest is reported.
    private static func index(_ data: Data) throws -> ([String: ZipEntry], [String]) {
        let (candidates, sawZip64) = endRecords(data)
        guard candidates.count <= maxEndCandidates else { throw ArchiveError.ambiguousEnd }
        func rank(_ end: EndRecord) -> (Int, Int, Int) { (end.isTight ? 1 : 0, end.endsFile ? 1 : 0, end.position) }
        let ordered = candidates.sorted { rank($0) > rank($1) }
        var best: ([String: ZipEntry], [String])?
        var firstFailure: Error?
        for end in ordered {
            do {
                guard end.total <= maxArchiveEntries else { throw ArchiveError.tooManyEntries(end.total) }
                let parsed = try directory(data, end)
                if best == nil || parsed.1.count > best!.1.count { best = parsed }
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let best { return best }
        throw firstFailure ?? (sawZip64 ? ArchiveError.zip64 : ArchiveError.truncated)
    }

    /// Every end-of-central-directory candidate. The record may be followed
    /// by a comment of up to 65,535 bytes, and that comment may itself hold
    /// the signature. A candidate counts only when its comment fits the file
    /// and its directory lies before it.
    private static func endRecords(_ data: Data) -> (candidates: [EndRecord], sawZip64: Bool) {
        var sawZip64 = false
        var candidates: [EndRecord] = []
        var position = data.count - 22
        let floor = max(0, data.count - 22 - 65_535)
        while position >= floor {
            defer { position -= 1 }
            guard data.le32(position) == 0x0605_4b50 else { continue }
            let total = Int(data.le16(position + 10))
            let directorySize = Int(data.le32(position + 12))
            let directoryOffset = Int(data.le32(position + 16))
            let commentLength = Int(data.le16(position + 20))
            if total == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF
                || (position >= 20 && data.le32(position - 20) == 0x0706_4b50)
            {
                sawZip64 = true
                continue
            }
            guard position + 22 + commentLength <= data.count,
                directoryOffset + directorySize <= position,
                total == 0 || data.le32(directoryOffset) == 0x0201_4b50
            else { continue }
            candidates.append(
                EndRecord(
                    total: total, directoryOffset: directoryOffset, directorySize: directorySize,
                    position: position, endsFile: position + 22 + commentLength == data.count))
        }
        return (candidates, sawZip64)
    }

    /// The central directory's records, every one whole inside the range
    /// the end record declares.
    private static func directory(_ data: Data, _ end: EndRecord) throws -> ([String: ZipEntry], [String]) {
        var entries: [String: ZipEntry] = [:]
        var names: [String] = []
        let limit = end.directoryOffset + end.directorySize
        var cursor = end.directoryOffset
        for _ in 0..<end.total {
            guard cursor + 46 <= limit, data.le32(cursor) == 0x0201_4b50 else { throw ArchiveError.truncated }
            let compressedSize = data.le32(cursor + 20)
            let size = data.le32(cursor + 24)
            let nameLength = Int(data.le16(cursor + 28))
            let recordLength = 46 + nameLength + Int(data.le16(cursor + 30)) + Int(data.le16(cursor + 32))
            let localOffset = data.le32(cursor + 42)
            if compressedSize == 0xFFFF_FFFF || size == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ArchiveError.zip64
            }
            guard cursor + recordLength <= limit else { throw ArchiveError.truncated }
            let rawName = data.subdata(in: (data.startIndex + cursor + 46)..<(data.startIndex + cursor + 46 + nameLength))
            let name = String(data: rawName, encoding: .utf8) ?? String(decoding: rawName, as: UTF8.self)
            guard isSafeArchiveName(name) else { throw ArchiveError.unsafeName(name) }
            if !name.hasSuffix("/") {
                entries[name] = ZipEntry(
                    flags: data.le16(cursor + 8), method: data.le16(cursor + 10), crc: data.le32(cursor + 16),
                    compressedSize: Int(compressedSize), size: Int(size), localOffset: Int(localOffset))
                names.append(name)
            }
            cursor += recordLength
        }
        return (entries, names)
    }

    public func contains(_ name: String) -> Bool { entries[name] != nil }

    public func read(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw ArchiveError.missing(name) }
        if entry.flags & 1 != 0 { throw ArchiveError.encryptedEntry(name) }
        guard entry.size <= maxArchiveEntryBytes else { throw ArchiveError.entryTooLarge(name) }
        guard bytesRead + entry.size <= maxArchiveReadBytes else { throw ArchiveError.readLimitExceeded }
        let local = entry.localOffset
        guard local + 30 <= data.count, data.le32(local) == 0x0403_4b50 else { throw ArchiveError.truncated }
        let start = local + 30 + Int(data.le16(local + 26)) + Int(data.le16(local + 28))
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
            // Even an empty entry has a stream to end: two bytes, 03 00. No
            // writer was found leaving it out — the two empty deflated
            // entries among the EPUBs measured both carry it — so zero
            // bytes is a broken entry, refused like any other.
            guard let inflated = inflate(source, size: entry.size) else { throw ArchiveError.inflateFailed(name) }
            out = inflated
        default:
            throw ArchiveError.unsupportedMethod(entry.method, name)
        }
        guard crc32(out) == entry.crc else { throw ArchiveError.badChecksum(name) }
        bytesRead += out.count
        return out
    }
}

/// Raw DEFLATE inflated through a stream, or nil unless the stream ends
/// having written exactly `size` bytes. The buffer is sized from the header,
/// never from the stream, so a lie in the header cannot allocate more than
/// the entry limit allows; the one byte over is how a longer stream is
/// noticed, where a one-shot decode would fill the buffer and stop silently.
func inflate(_ source: Data, size: Int) -> Data? {
    guard !source.isEmpty else { return nil }
    var destination = Data(count: size + 1)
    var stream = compression_stream(
        dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
    else { return nil }
    defer { compression_stream_destroy(&stream) }
    let written: Int? = destination.withUnsafeMutableBytes { target in
        source.withUnsafeBytes { input in
            stream.dst_ptr = target.bindMemory(to: UInt8.self).baseAddress!
            stream.dst_size = size + 1
            stream.src_ptr = input.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = source.count
            while true {
                let before = (stream.src_size, stream.dst_size)
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                if status == COMPRESSION_STATUS_END { return size + 1 - stream.dst_size }
                // Still going with no room left, or with no progress made:
                // longer than declared, or cut short.
                guard status == COMPRESSION_STATUS_OK, stream.dst_size > 0,
                    (stream.src_size, stream.dst_size) != before
                else { return nil }
            }
        }
    }
    guard let written, written == size else { return nil }
    return destination.prefix(size)
}

extension Data {
    /// Little-endian integers at an offset from the start, zero past the end.
    fileprivate func le16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    fileprivate func le32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }
}

/// An EPUB kept as a folder, the way Apple Books keeps them.
///
/// The same limits as a ZIP. Every file is opened one path component at a
/// time from the root, refusing a symbolic link at each step, and read from
/// that descriptor with the limits counted against what was actually read —
/// so neither a link inside the folder nor a file swapped or grown after it
/// was checked can hand the importer more, or something from elsewhere.
public final class FolderArchive: BookArchive {
    /// The root, opened once. Every file is reached from this descriptor, so
    /// the folder — or a folder above it — renamed or replaced by a link
    /// after the archive was opened cannot send a read anywhere else.
    private let rootDescriptor: Int32
    public let names: [String]
    private var bytesRead = 0

    /// The root is resolved once, here: a link to an EPUB folder is how a
    /// book dragged out of Apple Books can arrive, so the root itself may be
    /// one. Nothing below it may.
    public init(root: URL) throws {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolved.path.hasSuffix("/") ? resolved.path : resolved.path + "/"
        rootDescriptor = try Self.openRoot(root)
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
                if found.count > maxArchiveEntries {
                    close(rootDescriptor)
                    throw ArchiveError.tooManyEntries(found.count)
                }
            }
        }
        names = found
    }

    deinit { close(rootDescriptor) }

    /// The root, resolved and then opened without following a link, and
    /// refused unless what was opened is what was resolved. Resolving and
    /// opening are two steps, and a folder on the way swapped for a link
    /// between them would otherwise be opened in its place.
    private static func openRoot(_ root: URL) throws -> Int32 {
        guard let real = realpath(root.path, nil) else { throw ArchiveError.missing(root.lastPathComponent) }
        let resolved = String(cString: real)
        free(real)
        let descriptor = Darwin.open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ArchiveError.missing(root.lastPathComponent) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0, String(cString: buffer) == resolved else {
            close(descriptor)
            throw ArchiveError.unsafeName(root.lastPathComponent)
        }
        return descriptor
    }

    /// A descriptor for a regular file under the root, reached without
    /// following a link. The caller closes it.
    private func open(_ name: String) throws -> Int32 {
        guard isSafeArchiveName(name) else { throw ArchiveError.unsafeName(name) }
        var directory = dup(rootDescriptor)
        guard directory >= 0 else { throw ArchiveError.missing(name) }
        let components = name.split(separator: "/").map(String.init).filter { $0 != "." }
        for (index, component) in components.enumerated() {
            let last = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? O_NONBLOCK : O_DIRECTORY)
            let next = openat(directory, component, flags)
            let failure = errno
            close(directory)
            guard next >= 0 else {
                throw failure == ELOOP || failure == ENOTDIR ? ArchiveError.unsafeName(name) : ArchiveError.missing(name)
            }
            directory = next
        }
        var status = stat()
        guard !components.isEmpty, fstat(directory, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            close(directory)
            throw ArchiveError.missing(name)
        }
        return directory
    }

    public func contains(_ name: String) -> Bool {
        guard let descriptor = try? open(name) else { return false }
        close(descriptor)
        return true
    }

    public func read(_ name: String) throws -> Data {
        let descriptor = try open(name)
        defer { close(descriptor) }
        // One byte past whichever limit is nearer, so going over either is seen.
        let allowance = min(maxArchiveEntryBytes, maxArchiveReadBytes - bytesRead)
        var data = Data(count: allowance + 1)
        var filled = 0
        while filled < data.count {
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress! + filled, buffer.count - filled)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ArchiveError.missing(name) }
            if count == 0 { break }
            filled += count
        }
        if filled > allowance {
            throw filled > maxArchiveEntryBytes ? ArchiveError.entryTooLarge(name) : ArchiveError.readLimitExceeded
        }
        data.count = filled
        bytesRead += filled
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
