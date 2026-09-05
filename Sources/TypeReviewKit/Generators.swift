import Foundation

/// Text generators. Both consume the RNG in a fixed order, and that order is
/// as much a part of the contract as the output: draw a number in a different
/// place and every subsequent word changes, even though the code still "looks
/// right". The generator vectors pin the exact strings for fixed seeds.

/// Slices a prefix of `id` the way JavaScript does — by UTF-16 code unit, not
/// by Character. `"pseudo:…".slice(0, 64)` cuts at unit 64, and cutting at
/// character 64 would give a different id for any text with a combining mark.
private func jsPrefix(_ string: String, _ count: Int) -> String {
    let units = Array(string.utf16)
    guard units.count > count else { return string }
    return String(utf16CodeUnits: Array(units.prefix(count)), count: count)
}

public struct PseudoWordOptions {
    public var wordCount: Int = 30
    public var minWordLength: Int = 2
    public var maxWordLength: Int = 7
    /// Probability a generated word is seeded with the focus letter.
    public var focusBias: Double = 0.7

    public init(
        wordCount: Int = 30, minWordLength: Int = 2, maxWordLength: Int = 7,
        focusBias: Double = 0.7
    ) {
        self.wordCount = wordCount
        self.minWordLength = minWordLength
        self.maxWordLength = maxWordLength
        self.focusBias = focusBias
    }
}

/// Pseudo-random words from `filter.allowed`, over-representing the focus
/// letter. Works at any alphabet size, including the six-letter early lessons
/// where no real sentence could exist.
public func generatePseudoWords(
    filter: Filter, options: PseudoWordOptions = PseudoWordOptions(), rng: inout Mulberry32
) throws -> Passage {
    let letters = filter.allowed
    guard !letters.isEmpty else { throw CorpusError.emptyAlphabet }
    let wordCount = max(1, options.wordCount)
    let minLen = max(1, options.minWordLength)
    let maxLen = max(minLen, options.maxWordLength)

    let seedFocus = filter.focus.flatMap { letters.contains($0) ? $0 : nil }

    var words: [String] = []
    for _ in 0..<wordCount {
        let length = minLen + Int((rng.next() * Double(maxLen - minLen + 1)).rounded(.down))
        var chars: [String] = []
        for _ in 0..<length {
            chars.append(letters[Int((rng.next() * Double(letters.count)).rounded(.down))])
        }
        // Seeded into most words so the lesson actually drills the letter. The
        // bias draw happens even when there is no focus letter in JavaScript?
        // No — it is guarded, and the guard must be reproduced exactly or the
        // stream desynchronises for every later word.
        if let seedFocus, rng.next() < options.focusBias {
            chars[Int((rng.next() * Double(chars.count)).rounded(.down))] = seedFocus
        }
        words.append(chars.joined())
    }

    let text = words.joined(separator: " ")
    return try makePassage(id: jsPrefix("pseudo:" + text, 64), text: text)
}

public struct PlainWordsOptions {
    public var wordCount: Int = 30
    public var includeNumbers: Bool = false
    public var includePunctuation: Bool = false
    public var wordList: [String]?

    public init(
        wordCount: Int = 30, includeNumbers: Bool = false, includePunctuation: Bool = false,
        wordList: [String]? = nil
    ) {
        self.wordCount = wordCount
        self.includeNumbers = includeNumbers
        self.includePunctuation = includePunctuation
        self.wordList = wordList
    }
}

private let trailingPunctuation = [".", ",", ";", ":", "!", "?"]

/// 1–4 digits, leading digit non-zero so "0123" cannot happen.
private func randomDigits(_ rng: inout Mulberry32) -> String {
    let length = 1 + Int((rng.next() * 4).rounded(.down))
    var result = String(1 + Int((rng.next() * 9).rounded(.down)))
    for _ in 1..<max(length, 1) {
        result += String(Int((rng.next() * 10).rounded(.down)))
    }
    return result
}

/// A benchmark passage of randomly chosen words — no adaptive filtering.
public func generatePlainWords(
    options: PlainWordsOptions = PlainWordsOptions(), rng: inout Mulberry32
) throws -> Passage {
    let list = options.wordList ?? commonWords
    guard !list.isEmpty else { throw CorpusError.emptyWordList }
    let wordCount = max(1, options.wordCount)

    var tokens: [String] = []
    var capitaliseNext = options.includePunctuation
    for _ in 0..<wordCount {
        // ~15% of tokens become a digit string. Numbers take no trailing
        // punctuation and no capital, and the `continue` means the word draw
        // below does not happen — reproducing that skip is what keeps the
        // stream aligned.
        if options.includeNumbers, rng.next() < 0.15 {
            tokens.append(randomDigits(&rng))
            continue
        }
        var token = list[Int((rng.next() * Double(list.count)).rounded(.down))]
        if options.includePunctuation {
            if capitaliseNext {
                token = token.prefix(1).uppercased() + token.dropFirst()
                capitaliseNext = false
            }
            if rng.next() < 0.2 {
                let mark = trailingPunctuation[
                    Int((rng.next() * Double(trailingPunctuation.count)).rounded(.down))]
                token += mark
                if mark == "." || mark == "!" || mark == "?" { capitaliseNext = true }
            }
        }
        tokens.append(token)
    }

    let text = tokens.joined(separator: " ")
    return try makePassage(id: jsPrefix("plain:" + text, 64), text: text)
}
