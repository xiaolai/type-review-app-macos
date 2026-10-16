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

func classify(_ path: String) -> Input? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
    if isDataless(path) { return .dataless(path) }
    guard isDirectory.boolValue else { return .file(path) }
    // A folder EPUB inside another one, or a folder whose files are still
    // in iCloud.
    guard let enumerator = FileManager.default.enumerator(atPath: path) else { return nil }
    for case let name as String in enumerator where isDataless(path + "/" + name) { return .dataless(path) }
    return .folder(path)
}

/// SHA-256 of a file, or of a folder's names and contents in order.
func digest(_ input: Input) -> String? {
    var hasher = SHA256()
    switch input {
    case .file(let path):
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        hasher.update(data: data)
    case .folder(let path):
        guard let names = FileManager.default.enumerator(atPath: path)?.allObjects as? [String] else { return nil }
        for name in names.sorted() {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path + "/" + name, isDirectory: &isDirectory)
            if isDirectory.boolValue { continue }
            hasher.update(data: Data(name.utf8))
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path + "/" + name), options: .alwaysMapped) {
                hasher.update(data: data)
            }
        }
    case .dataless:
        return nil
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

func measure(_ path: String) -> Tally {
    var tally = Tally()
    tally.books = 1
    let contents: EpubContents
    let draft: BookDraft
    do {
        contents = try readEpubContents(at: URL(fileURLWithPath: path))
        draft = try contents.draft()
    } catch let error as BookImportError {
        let key: String
        switch error {
        case .copyProtected: key = "copy-protected"
        case .fixedLayout: key = "fixed layout"
        case .picturesOnly: key = "pictures only"
        case .noText: key = "no text"
        case .unreadable: key = "unreadable"
        case .tooLarge: key = "too large"
        case .tooManyBooks, .nothingIncluded: key = "other"
        }
        tally.refused[key] = 1
        return tally
    } catch {
        tally.refused["unexpected error"] = 1
        return tally
    }
    tally.imported = 1
    let isEnglish = !draft.warnings.contains { if case .notEnglish = $0 { return true } else { return false } }
    if isEnglish { tally.english = 1 }
    var bad = false
    for source in contents.sources where source.kind == .story {
        for block in source.blocks {
            let split = splitIntoSentences([block])
            tally.truncated += split.truncatedPieces
            if split.truncatedPieces > 0 { bad = true }
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
                    // A piece of a long sentence cut at the cap starts where
                    // the sentence did not, so only a unit after an ended
                    // sentence counts.
                    if previousEnded, let first = unit.unicodeScalars.first,
                        CharacterSet.lowercaseLetters.contains(first)
                    {
                        tally.englishLowercaseStarts += 1
                    }
                }
                previousEnded = endsSentence(unit)
            }
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
        guard let hash = digest(input) else { continue }
        if seen.insert(hash).inserted { books.append(file) } else { duplicates += 1 }
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
if tally.books == 0 {
    failed = true
    print("FAIL: no books were read")
}
print(failed ? "EPUB CORPUS FAILED" : "EPUB CORPUS OK")
exit(failed ? 1 : 0)
