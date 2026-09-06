import Foundation
import TypeReviewKit

/// The user's library, as a file they own.
///
/// The website keeps this in IndexedDB, which the browser may evict. Here it
/// is one JSON file next to the profile — the user can back it up, copy it to
/// another Mac, or read it in a text editor, and nothing reclaims it.
///
/// Written through the same temp-file-plus-fullsync dance as the profile: a
/// crash mid-save must not be able to replace a library with a truncated one.
final class LibraryStore {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("library.json") }

    private(set) var passages: [UserPassage] = []
    /// True when a file exists at `fileURL` but could not be read as a
    /// library. The passages are empty either way, and *that* was the problem:
    /// an unreadable library and a first launch looked identical, so the next
    /// add or delete wrote a one-entry file over text the user still had, and
    /// could still have recovered by hand. The same rule the profile follows —
    /// do not overwrite data that exists and merely cannot be parsed.
    private(set) var isUnreadable = false

    init(directory: URL) {
        self.directory = directory
        switch LibraryStore.read(fileURL) {
        case .absent:
            passages = []
        case .ok(let decoded):
            passages = decoded
        case .unreadable:
            passages = []
            isUnreadable = true
        }
    }

    static func standard() throws -> LibraryStore {
        try LibraryStore(directory: ProfileFileStore.standard().directory)
    }

    private enum Read {
        case absent
        case ok([UserPassage])
        case unreadable
    }

    /// A library that cannot be parsed still launches the app: practice text is
    /// replaceable, and refusing to start over it would be the worse failure.
    /// The file is left on disk untouched, and `isUnreadable` keeps it that way.
    private static func read(_ url: URL) -> Read {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([UserPassage].self, from: data)
        else { return .unreadable }
        // Decoding proves the shape, not the invariants `add` enforces. A
        // hand-edited or truncated file can decode into passages that are
        // longer than the cap, empty, or share an id — none of which the rest
        // of the app is written to survive.
        var seen: Set<String> = []
        for passage in decoded {
            guard passage.text.utf16.count <= maxUserPassageLength, !passage.text.isEmpty,
                passage.title.utf16.count <= maxUserTitleLength, seen.insert(passage.id).inserted
            else { return .unreadable }
        }
        guard decoded.count <= maxUserPassages else { return .unreadable }
        return .ok(decoded)
    }

    // Both mutations persist a *candidate* list and adopt it only once the
    // write has succeeded. Mutating `passages` first meant a failed save left
    // memory disagreeing with disk: the Library window showed the new passage,
    // and the next successful delete quietly committed the addition that had
    // already been reported as failed.

    func add(title: String, text: String) throws {
        guard passages.count < maxUserPassages else { throw UserPassageError.full }
        let passage = try makeUserPassage(
            id: UUID().uuidString, title: title, text: text,
            createdAt: Date().timeIntervalSince1970 * 1000)
        try commit(passages + [passage])
    }

    func delete(id: String) throws {
        try commit(passages.filter { $0.id != id })
    }

    private func commit(_ candidate: [UserPassage]) throws {
        guard !isUnreadable else { throw LibraryStoreError.unreadableFile(fileURL) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeDurably(try encoder.encode(candidate), to: fileURL, in: directory)
        passages = candidate
    }
}

enum LibraryStoreError: Error, LocalizedError {
    case unreadableFile(URL)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let url):
            return "library.json could not be read and will not be overwritten — "
                + "move or repair \(url.path) first"
        }
    }
}
