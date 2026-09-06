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

    init(directory: URL) {
        self.directory = directory
        passages = LibraryStore.read(fileURL)
    }

    static func standard() throws -> LibraryStore {
        try LibraryStore(directory: ProfileFileStore.standard().directory)
    }

    /// A library that cannot be parsed is treated as empty rather than fatal:
    /// practice text is replaceable, and refusing to launch over it would be
    /// the worse failure. The file is left on disk untouched so the user can
    /// still recover it by hand.
    private static func read(_ url: URL) -> [UserPassage] {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([UserPassage].self, from: data)
        else { return [] }
        return decoded
    }

    func add(title: String, text: String) throws {
        guard passages.count < maxUserPassages else { throw UserPassageError.full }
        let passage = try makeUserPassage(
            id: UUID().uuidString, title: title, text: text,
            createdAt: Date().timeIntervalSince1970 * 1000)
        passages.append(passage)
        try save()
    }

    func delete(id: String) throws {
        passages.removeAll { $0.id == id }
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temp = directory.appendingPathComponent("library.json.\(UUID().uuidString).tmp")
        try encoder.encode(passages).write(to: temp)
        let handle = try FileHandle(forWritingTo: temp)
        _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
        try handle.close()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: fileURL)
        }
    }
}
