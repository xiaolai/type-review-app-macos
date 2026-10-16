import Foundation

/// One book on the starter shelf, as `Resources/shelf/index.json` lists it.
///
/// The listing is the claim that the book may ship: where the text came from
/// and why it is free to. `ShelfTextTests` holds every book file to it.
public struct ShelfEntry: Sendable, Equatable, Decodable {
    public let id: String
    public let title: String
    public let author: String
    /// The edition the text was taken from.
    public let source: String
    public let license: String
    /// First publication, for the public-domain claim.
    public let published: Int
}

/// The public-domain books that ship with the app, split into sentences when
/// they were added (`make shelf`), so a child has something to type before a
/// parent has imported anything.
///
/// Pre-split rather than split on first use: a stored place must not move,
/// and `NLTokenizer`'s output can change between macOS versions. A shelf
/// book carries a stable id, `shelf-<name>`, so the place in it survives an
/// app update that ships the same text.
public enum BundledShelf {
    public static var books: [Book] { loaded.books }
    public static var entries: [ShelfEntry] { loaded.entries }
    /// Why a shelf file could not be read, for `--selftest`, the way
    /// `BundledCorpus.loadFailures` is.
    public static var loadFailures: [String] { loaded.failures }

    private static let loaded: (entries: [ShelfEntry], books: [Book], failures: [String]) = {
        guard let index = resourceBundle.url(forResource: "Resources/shelf/index", withExtension: "json")
        else { return ([], [], ["Resources/shelf/index.json: not in the bundle"]) }
        let entries: [ShelfEntry]
        do {
            entries = try JSONDecoder().decode([ShelfEntry].self, from: try Data(contentsOf: index))
        } catch {
            return ([], [], ["Resources/shelf/index.json: \(error)"])
        }
        var books: [Book] = []
        var failures: [String] = []
        for entry in entries {
            let name = "Resources/shelf/\(entry.id)"
            guard let url = resourceBundle.url(forResource: name, withExtension: "json") else {
                failures.append("\(name).json: not in the bundle")
                continue
            }
            do {
                let book = try decodeBook(try Data(contentsOf: url))
                guard book.id == entry.id else {
                    failures.append("\(name).json: holds \(book.id)")
                    continue
                }
                books.append(book)
            } catch {
                failures.append("\(name).json: \(error)")
            }
        }
        return (entries, books, failures)
    }()
}
