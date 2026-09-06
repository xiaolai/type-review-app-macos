import Foundation

/// One passage the user added to their library.
///
/// The stored schema is deliberately tiny — id, title, text, timestamp. The
/// alphabet and length the picker needs are derived at load time so they can
/// never drift from the text they describe.
public struct UserPassage: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let text: String
    /// Milliseconds since the epoch, matching the web store's `Date.now()`.
    public let createdAt: Double

    public init(id: String, title: String, text: String, createdAt: Double) {
        self.id = id
        self.title = title
        self.text = text
        self.createdAt = createdAt
    }
}

/// Defensive bounds, matching the web store's. Not physical limits — a guard
/// against one pasted novel making the library unopenable.
public let maxUserPassages = 200
public let maxUserPassageLength = 50_000
public let maxUserTitleLength = 200

public enum UserPassageError: Error, Equatable {
    case empty
    case full
}

/// Normalises a candidate passage the way the web store's `add` does:
/// trims and caps the title, caps the text, and falls back to the opening
/// words as a title when none was given — a library row with a blank name is
/// a row the user cannot identify.
public func makeUserPassage(
    id: String, title: String, text: String, createdAt: Double
) throws -> UserPassage {
    // UTF-16 units, not Characters. Every other length in this engine is
    // counted in code units — it is the coordinate system the web store shares
    // — and `String.prefix` counts grapheme clusters, so text built from
    // combining marks kept more units than the advertised cap and the two
    // implementations disagreed about where the same paste was truncated.
    let cleanText = prefixByCodeUnits(text, maxUserPassageLength)
    guard !cleanText.isEmpty else { throw UserPassageError.empty }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanTitle = prefixByCodeUnits(trimmed, maxUserTitleLength)
    return UserPassage(
        id: id,
        title: cleanTitle.isEmpty ? prefixByCodeUnits(cleanText, 40) : cleanTitle,
        text: cleanText,
        createdAt: createdAt)
}

/// The first `count` UTF-16 code units of `string`, matching JavaScript's
/// `String.prototype.slice`.
private func prefixByCodeUnits(_ string: String, _ count: Int) -> String {
    let units = Array(string.utf16)
    guard units.count > count else { return string }
    return String(utf16CodeUnits: Array(units.prefix(count)), count: count)
}

/// The library as a corpus source.
///
/// Built fresh from the current passage list on every pick, so adding or
/// deleting in the Library window takes effect on the very next run rather
/// than at the next launch.
public struct UserCorpusSource: CorpusSource, Sendable {
    public let entries: [CorpusEntry]

    public init(passages: [UserPassage]) {
        entries = passages.map { passage in
            makeEntry(
                id: passage.id, kind: .user, text: passage.text,
                attribution: CorpusAttribution(
                    title: passage.title.isEmpty ? nil : passage.title,
                    author: nil, url: nil, license: "user-uploaded"))
        }
    }

    public func pick(_ context: CorpusContext, rng: inout Mulberry32) -> CorpusEntry? {
        let candidates = context.filter.map { filter in
            entries.filter { fitsAlphabet($0, filter) }
        } ?? entries
        return pickWeightedByLength(candidates, wantedChars: context.wantedChars, rng: &rng)
    }
}
