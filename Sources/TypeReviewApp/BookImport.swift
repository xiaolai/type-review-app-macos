import Foundation
import TypeReviewKit

/// Reads a chosen file into a draft for the review sheet. Off the main
/// thread: a long novel takes seconds to split.
enum BookImport {
    /// The largest plain-text file read at all. Three million characters is
    /// the book limit; four bytes each covers any encoding a book arrives in.
    static let maxTextBytes = maxBookCharacters * 4

    static func draft(from url: URL) throws -> BookDraft {
        if url.pathExtension.lowercased() == "epub" { return try readEpubBook(at: url) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? Int, size > maxTextBytes {
            throw BookImportError.tooLarge("over \(maxTextBytes / 1_000_000) MB of text")
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw BookImportError.unreadable(error.localizedDescription)
        }
        guard let text = decodeBookText(data) else {
            throw BookImportError.unreadable("the text encoding is not one this app reads")
        }
        return try readPlainTextBook(text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }
}
