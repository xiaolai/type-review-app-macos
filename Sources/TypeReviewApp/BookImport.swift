import Foundation
import TypeReviewKit

/// Reads a chosen file into a draft for the review sheet. Off the main
/// thread: a long novel takes seconds to split. The limits are the Kit's.
enum BookImport {
    static func draft(from url: URL) throws -> BookDraft {
        url.pathExtension.lowercased() == "epub" ? try readEpubBook(at: url) : try readPlainTextBook(at: url)
    }
}
