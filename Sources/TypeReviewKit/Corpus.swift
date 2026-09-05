import Foundation

/// A pre-tagged unit of practice text.
public struct Passage: Sendable, Equatable {
    public let id: String
    public let text: String
    /// Per-letter counts within `text`, lowercased, letters only.
    public let keyHistogram: [String: Int]
    public let letterCount: Int
}

/// Which letters a lesson may use and which one to over-represent.
public struct Filter: Sendable, Equatable {
    /// In difficulty order, easiest first — the order is meaningful.
    public let allowed: [String]
    public let focus: String?

    public init(allowed: [String], focus: String?) {
        self.allowed = allowed
        self.focus = focus
    }
}

/// Counts letters, lowercased, ignoring spaces, digits and punctuation.
///
/// "Letter" here means the Unicode general category, matching JavaScript's
/// `\p{Letter}`. Swift's `Character.isLetter` is NOT the same predicate — it
/// returns true for U+0345 COMBINING GREEK YPOGEGRAMMENI, which JavaScript
/// excludes — so the categories are named explicitly.
public func analyzeText(_ text: String) -> (keyHistogram: [String: Int], letterCount: Int) {
    var histogram: [String: Int] = [:]
    var letterCount = 0
    for character in text {
        guard character.unicodeScalars.allSatisfy(isJSLetter) else { continue }
        let lower = character.lowercased()
        histogram[lower, default: 0] += 1
        letterCount += 1
    }
    return (histogram, letterCount)
}

private func isJSLetter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
        return true
    default:
        return false
    }
}

public func makePassage(id: String, text: String) throws -> Passage {
    guard !text.isEmpty else {
        throw CorpusError.emptyText
    }
    let analysis = analyzeText(text)
    return Passage(
        id: id, text: text, keyHistogram: analysis.keyHistogram,
        letterCount: analysis.letterCount)
}

public enum CorpusError: Error {
    case emptyText
    case emptyAlphabet
    case emptyWordList
}

/// The ~120 most common English words — the built-in benchmark list.
public let commonWords: [String] = [
    "the", "be", "to", "of", "and", "a", "in", "that", "have", "it", "for", "not", "on",
    "with", "he", "as", "you", "do", "at", "this", "but", "his", "by", "from", "they",
    "we", "say", "her", "she", "or", "an", "will", "my", "one", "all", "would", "there",
    "their", "what", "so", "up", "out", "if", "about", "who", "get", "which", "go", "me",
    "when", "make", "can", "like", "time", "no", "just", "him", "know", "take", "people",
    "into", "year", "your", "good", "some", "could", "them", "see", "other", "than",
    "then", "now", "look", "only", "come", "its", "over", "think", "also", "back", "after",
    "use", "two", "how", "our", "work", "first", "well", "way", "even", "new", "want",
    "because", "any", "these", "give", "day", "most", "us", "find", "thing", "many",
    "great", "little", "world", "still", "between", "life", "down", "should", "home",
    "around", "small", "place", "another", "again", "turn", "here", "move", "where"
]
