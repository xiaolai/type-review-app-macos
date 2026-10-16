import CryptoKit
import Darwin
import Foundation
import TypeReviewKit

// `make epub-corpus`: the EPUB reader run over every EPUB on this Mac, as a
// local gate. The books are private and mostly copyrighted, so this never
// runs in CI, prints only numbers and the paths of failing books, and writes
// nothing anywhere.
//
// Usage: EpubCorpus [path ...]. With no paths, Spotlight lists the EPUBs.
//
// Exits 1 when any unit is empty or over `maxBookSentenceChars`, any piece
// was cut by cleaning, or English books start more than 3 units in 1,000
// with a lower-case letter where a sentence began.

/// A file iCloud has not downloaded. Reading it would download it, which is
/// slow, uses the network, and fills the disk.
let datalessFlag: UInt32 = 0x4000_0000

func isDataless(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    return info.st_flags & datalessFlag != 0
}

func spotlightEpubs() throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    process.arguments = ["kMDItemFSName == \"*.epub\"c"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "mdfind", code: Int(process.terminationStatus))
    }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}

/// What one book is, for skipping and de-duplicating, read without
/// downloading anything.
enum Input {
    case file(String)
    case folder(String)
    case dataless(String)
}

/// The regular files of a folder EPUB, relative and sorted: the files
/// `FolderArchive` reads, so links inside the folder are left out here too.
///
/// Nil when any part of the folder could not be listed or looked at: a
/// listing with a file missing from it would hash as some other book.
func folderFiles(_ path: String) -> [String]? {
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    var failed = false
    guard
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, errorHandler: { _, _ in
                failed = true
                return true
            })
    else { return nil }
    let prefix = root.standardizedFileURL.path + "/"
    var names: [String] = []
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
            failed = true
            continue
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(prefix) else {
            failed = true
            continue
        }
        names.append(String(full.dropFirst(prefix.count)))
    }
    return failed ? nil : names.sorted()
}

/// Classifies the file a path finally names: a link is followed first, so a
/// link to a file still in iCloud is seen as one, and the book is read and
/// hashed at its real location.
func classify(_ listed: String) -> Input? {
    let path = (listed as NSString).resolvingSymlinksInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
    if isDataless(path) { return .dataless(path) }
    guard isDirectory.boolValue else { return .file(path) }
    // A folder whose files are still in iCloud. One that cannot be listed is
    // still a book: hashing it fails and reports it, and the reader says
    // what is wrong with it, where dropping it here said nothing.
    guard let names = folderFiles(path) else { return .folder(path) }
    if names.contains(where: { isDataless(path + "/" + $0) }) { return .dataless(path) }
    return .folder(path)
}

struct UnreadableForHashing: Error {
    let path: String
}

/// SHA-256 of a file, or of a folder's names and contents in order. Throws
/// when any part cannot be read: a hash of what happened to be readable
/// could match another book and hide this one as its duplicate.
func digest(_ input: Input) throws(UnreadableForHashing) -> String {
    func contents(_ path: String) throws(UnreadableForHashing) -> Data {
        do { return try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) } catch {
            throw UnreadableForHashing(path: path)
        }
    }
    var hasher = SHA256()
    switch input {
    case .file(let path):
        hasher.update(data: try contents(path))
    case .folder(let path):
        guard let names = folderFiles(path) else { throw UnreadableForHashing(path: path) }
        for name in names {
            hasher.update(data: Data(name.utf8))
            hasher.update(data: try contents(path + "/" + name))
        }
    case .dataless(let path):
        throw UnreadableForHashing(path: path)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

struct Tally {
    var books = 0
    var imported = 0
    var refused: [String: Int] = [:]
    var english = 0
    var units = 0
    var englishUnits = 0
    var englishLowercaseStarts = 0
    var empty = 0
    var overCap = 0
    var truncated = 0
    var failing: [String] = []
    var seconds = 0.0

    mutating func absorb(_ other: Tally) {
        books += other.books
        imported += other.imported
        for (key, count) in other.refused { refused[key, default: 0] += count }
        english += other.english
        units += other.units
        englishUnits += other.englishUnits
        englishLowercaseStarts += other.englishLowercaseStarts
        empty += other.empty
        overCap += other.overCap
        truncated += other.truncated
        failing += other.failing
        seconds = max(seconds, other.seconds)
    }
}

func endsSentence(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]} "))
    guard let last = trimmed.last else { return false }
    return ".!?".contains(last)
}

/// The report's name for why a book was refused.
func refusalKey(_ error: Error) -> String {
    guard let error = error as? BookImportError else { return "unexpected error" }
    switch error {
    case .copyProtected: return "copy-protected"
    case .fixedLayout: return "fixed layout"
    case .picturesOnly: return "pictures only"
    case .noText: return "no text"
    case .unreadable: return "unreadable"
    case .tooLarge: return "too large"
    case .tooManyBooks, .nothingIncluded: return "other"
    }
}

/// Counts one story block's units into `tally`, and answers whether any of
/// them breaks a rule. `split` is the block's own split, the one the draft
/// was made from.
func measureBlock(_ block: BookBlock, _ split: SentenceSplit, isEnglish: Bool, into tally: inout Tally) -> Bool {
    var bad = split.truncatedPieces > 0
    tally.truncated += split.truncatedPieces
    var previousEnded = true
    for unit in split.sentences {
        tally.units += 1
        if unit.trimmingCharacters(in: .whitespaces).isEmpty {
            tally.empty += 1
            bad = true
        }
        if unit.utf16.count > maxBookSentenceChars {
            tally.overCap += 1
            bad = true
        }
        if isEnglish && block.kind == .paragraph {
            tally.englishUnits += 1
            // A piece of a long sentence cut at the cap starts where the
            // sentence did not, so only a unit after an ended sentence counts.
            if previousEnded, let first = unit.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) {
                tally.englishLowercaseStarts += 1
            }
        }
        previousEnded = endsSentence(unit)
    }
    return bad
}

func measure(_ path: String) -> Tally {
    var tally = Tally()
    tally.books = 1
    let contents: EpubContents
    let splits: [[SentenceSplit]]
    let draft: BookDraft
    do {
        contents = try readEpubContents(at: URL(fileURLWithPath: path))
        // Split once, block by block: the draft is made from these, and the
        // gate measures the same splits rather than making them again.
        splits = contents.sources.map { splitBlocks($0.blocks) }
        draft = try makeDraft(
            title: contents.title, author: contents.author, sources: contents.sources, blockSplits: splits,
            tablesDropped: contents.tablesDropped, unreadableFiles: contents.unreadableFiles,
            imagesSeen: contents.imagesSeen)
    } catch {
        tally.refused[refusalKey(error)] = 1
        return tally
    }
    tally.imported = 1
    let isEnglish = !draft.warnings.contains { if case .notEnglish = $0 { return true } else { return false } }
    if isEnglish { tally.english = 1 }
    var bad = false
    for (source, blockSplits) in zip(contents.sources, splits) where source.kind == .story {
        for (block, split) in zip(source.blocks, blockSplits)
        where measureBlock(block, split, isEnglish: isEnglish, into: &tally) {
            bad = true
        }
    }
    if bad { tally.failing.append(path) }
    return tally
}

final class Shared: @unchecked Sendable {
    private let lock = NSLock()
    private var tally = Tally()
    private var done = 0

    func add(_ other: Tally, of total: Int) {
        lock.lock()
        tally.absorb(other)
        done += 1
        if done % 100 == 0 { FileHandle.standardError.write(Data("\(done)/\(total)\n".utf8)) }
        lock.unlock()
    }

    var result: Tally {
        lock.lock()
        defer { lock.unlock() }
        return tally
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let paths: [String]
do {
    paths = arguments.isEmpty ? try spotlightEpubs() : arguments
} catch {
    FileHandle.standardError.write(Data("mdfind failed: \(error)\n".utf8))
    exit(2)
}

var seen = Set<String>()
var books: [String] = []
var dataless = 0
var duplicates = 0
var nested = 0
var unhashable: [String] = []
let started = Date()
// Folder EPUBs contain their own files, and Spotlight lists any `.epub`
// beneath one too; only the outermost is a book.
var folders = Set<String>()
func inside(_ folders: Set<String>, _ path: String) -> Bool {
    var parent = (path as NSString).deletingLastPathComponent
    while parent.count > 1 {
        if folders.contains(parent) { return true }
        parent = (parent as NSString).deletingLastPathComponent
    }
    return false
}
// Sorted, so a folder is seen before anything inside it.
for path in paths.sorted() {
    if inside(folders, path) {
        nested += 1
        continue
    }
    guard let input = classify(path) else { continue }
    switch input {
    case .dataless:
        dataless += 1
    case .file(let file), .folder(let file):
        if case .folder = input { folders.insert(file) }
        do {
            if seen.insert(try digest(input)).inserted { books.append(file) } else { duplicates += 1 }
        } catch {
            // Never taken for a duplicate, and never dropped: the reader
            // gets it, and says what is wrong with it.
            unhashable.append(error.path)
            books.append(file)
        }
    }
}

let shared = Shared()
let list = books
DispatchQueue.concurrentPerform(iterations: list.count) { index in
    let began = Date()
    var tally = autoreleasepool { measure(list[index]) }
    tally.seconds = Date().timeIntervalSince(began)
    shared.add(tally, of: list.count)
}
let tally = shared.result
let perThousand = tally.englishUnits == 0 ? 0 : Double(tally.englishLowercaseStarts) * 1000 / Double(tally.englishUnits)

print("listed            \(paths.count)")
print("not downloaded    \(dataless)")
print("duplicates        \(duplicates)")
print("inside a folder   \(nested)")
print("unhashable        \(unhashable.count)")
for path in unhashable.sorted().prefix(20) { print("  \(path)") }
print("books read        \(tally.books)")
print("imported          \(tally.imported)")
for (reason, count) in tally.refused.sorted(by: { $0.key < $1.key }) {
    print("refused           \(count) \(reason)")
}
print("English books     \(tally.english)")
print("story units       \(tally.units)")
print("empty units       \(tally.empty)")
print("units over \(maxBookSentenceChars)    \(tally.overCap)")
print("pieces truncated  \(tally.truncated)")
print(String(format: "lower-case starts %d of %d English units, %.2f per 1,000", tally.englishLowercaseStarts,
    tally.englishUnits, perThousand))
print(String(format: "slowest book      %.1f s", tally.seconds))
print(String(format: "wall time         %.0f s", Date().timeIntervalSince(started)))

var failed = false
if tally.empty > 0 || tally.overCap > 0 || tally.truncated > 0 {
    failed = true
    print("FAIL: empty, oversized or truncated units in \(tally.failing.count) books:")
    for path in tally.failing.sorted().prefix(20) { print("  \(path)") }
}
if perThousand > 3 {
    failed = true
    print(String(format: "FAIL: %.2f lower-case starts per 1,000 English units, more than 3", perThousand))
}
// A gate that refused every book has measured nothing, and must not pass.
if tally.imported == 0 || tally.units == 0 {
    failed = true
    print("FAIL: \(tally.books) books read, \(tally.imported) imported, \(tally.units) story units measured")
}
print(failed ? "EPUB CORPUS FAILED" : "EPUB CORPUS OK")
exit(failed ? 1 : 0)
