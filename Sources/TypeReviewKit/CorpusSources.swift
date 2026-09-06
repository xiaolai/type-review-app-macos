import Foundation

/// Where a passage came from.
public enum SourceKind: String, Sendable, Codable {
    case quote, code, difficult, drills, user
}

public struct CorpusAttribution: Sendable, Equatable, Codable {
    public let title: String?
    public let author: String?
    public let url: String?
    public let license: String
}

public struct CorpusEntry: Sendable, Equatable {
    public let id: String
    public let kind: SourceKind
    public let text: String
    /// Distinct characters, precomputed so alphabet filtering stays cheap.
    public let alphabet: Set<String>
    public let length: Int
    public let attribution: CorpusAttribution?
}

public struct CorpusContext {
    /// Letters the lesson may use. nil means no filtering.
    public let filter: Set<String>?
    public let wantedChars: Double

    public init(filter: Set<String>? = nil, wantedChars: Double) {
        self.filter = filter
        self.wantedChars = wantedChars
    }
}

public func makeEntry(
    id: String, kind: SourceKind, text: String, attribution: CorpusAttribution? = nil
) -> CorpusEntry {
    var alphabet: Set<String> = []
    for character in text.lowercased() {
        alphabet.insert(String(character))
    }
    return CorpusEntry(
        id: id, kind: kind, text: text, alphabet: alphabet, length: text.utf16.count,
        attribution: attribution)
}

/// Whether every *letter* in the entry is unlocked. Digits and punctuation are
/// ignored: a lesson on six letters should still be allowed a comma.
public func fitsAlphabet(_ entry: CorpusEntry, _ filter: Set<String>) -> Bool {
    for character in entry.alphabet {
        guard let scalar = character.unicodeScalars.first else { continue }
        let isLetter: Bool
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            isLetter = true
        default:
            isLetter = false
        }
        if isLetter, !filter.contains(character) { return false }
    }
    return true
}

/// How well an entry's length matches what was asked for, 0...1.
///
/// A triangular kernel peaking at an exact match, falling to zero at half and
/// triple the wanted length. Entries outside that band score zero and are
/// effectively skipped — a two-line quote is a poor answer to a request for a
/// five-minute passage, and vice versa.
public func lengthScore(entryLength: Int, wantedChars: Double) -> Double {
    guard wantedChars > 0 else { return 0 }
    let ratio = Double(entryLength) / wantedChars
    if ratio < 0.5 || ratio > 3 { return 0 }
    if ratio <= 1 { return 2 * ratio - 1 }
    return (3 - ratio) / 2
}

/// Picks an entry at random, weighted by how well its length fits.
///
/// Exactly one RNG draw, taken after the weights are summed. The draw *count*
/// is part of the contract: taking one more or one fewer here shifts every
/// later passage in the session, which is why the vectors pin the picks for
/// fixed seeds rather than only the weights.
public func pickWeightedByLength(
    _ candidates: [CorpusEntry], wantedChars: Double, rng: inout Mulberry32
) -> CorpusEntry? {
    guard !candidates.isEmpty else { return nil }
    // The floor keeps a badly-fitting entry pickable rather than impossible:
    // with a narrow corpus, every entry scoring zero would otherwise mean no
    // passage at all.
    let weights = candidates.map {
        max(0.01, lengthScore(entryLength: $0.length, wantedChars: wantedChars))
    }
    let total = weights.reduce(0, +)
    var pick = rng.next() * total
    for (index, weight) in weights.enumerated() {
        pick -= weight
        if pick <= 0 { return candidates[index] }
    }
    return candidates.last
}

/// A source of practice text.
public protocol CorpusSource {
    func pick(_ context: CorpusContext, rng: inout Mulberry32) -> CorpusEntry?
}

/// A fixed list of entries — the shipped quotes and code snippets.
public struct StaticCorpusSource: CorpusSource, Sendable {
    public let entries: [CorpusEntry]

    public init(raw: [RawStaticEntry], kind: SourceKind, preserveLayout: Bool = false) {
        entries = raw.compactMap { entry in
            let clean = sanitize(entry.text, preserveLayout: preserveLayout)
            guard !clean.text.isEmpty else { return nil }
            return makeEntry(
                id: entry.id, kind: kind, text: clean.text,
                attribution: CorpusAttribution(
                    title: entry.title, author: entry.author, url: entry.url,
                    license: entry.license))
        }
    }

    public func pick(_ context: CorpusContext, rng: inout Mulberry32) -> CorpusEntry? {
        let candidates = context.filter.map { filter in
            entries.filter { fitsAlphabet($0, filter) }
        } ?? entries
        return pickWeightedByLength(candidates, wantedChars: context.wantedChars, rng: &rng)
    }
}

public struct RawStaticEntry: Decodable {
    public let id: String
    public let text: String
    public let title: String?
    /// Repurposed as the language label for code entries.
    public let author: String?
    public let url: String?
    public let license: String
}

/// The corpus that ships inside the app.
public enum BundledCorpus {
    private struct QuotesFile: Decodable {
        let entries: [RawStaticEntry]
    }

    public static let quotes: StaticCorpusSource = {
        guard let url = Bundle.module.url(forResource: "Resources/quotes", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(QuotesFile.self, from: data)
        else { return StaticCorpusSource(raw: [], kind: .quote) }
        return StaticCorpusSource(raw: file.entries, kind: .quote)
    }()

    /// Code keeps its indentation, so `preserveLayout` is on: collapsing the
    /// whitespace would turn a Python snippet into one unreadable line and
    /// remove exactly the keys that make code hard to type.
    public static let code: StaticCorpusSource = {
        guard let directory = Bundle.module.url(forResource: "Resources/code", withExtension: nil),
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return StaticCorpusSource(raw: [], kind: .code, preserveLayout: true) }
        let raw = files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            .compactMap { url -> RawStaticEntry? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(RawStaticEntry.self, from: data)
            }
        return StaticCorpusSource(raw: raw, kind: .code, preserveLayout: true)
    }()
}


/// Which corpus a run draws from.
public enum CorpusChannel: String, Sendable, CaseIterable {
    case auto, quotes, code, user, generated

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .user: return "Library"
        case .quotes: return "Quotes"
        case .code: return "Code"
        case .generated: return "Generated"
        }
    }
}

/// Bridges the corpus to the shape `Session` expects.
///
/// Falls back to the generators whenever the corpus cannot answer — an
/// alphabet with six letters unlocked has no real sentence available, and a
/// timed run needs more text than any quote holds. A practice run must always
/// be able to start, so "no passage" is never an outcome.
public struct CorpusAdapter {
    public let channel: CorpusChannel
    /// Fired whenever a real entry is chosen, so the UI can credit it.
    public var onEntryPicked: (@Sendable (CorpusEntry?) -> Void)?

    /// The user's library, read at construction. The adapter is rebuilt for
    /// every pick, so this is always the current list.
    public let library: [UserPassage]

    public init(
        channel: CorpusChannel, library: [UserPassage] = [],
        onEntryPicked: (@Sendable (CorpusEntry?) -> Void)? = nil
    ) {
        self.channel = channel
        self.library = library
        self.onEntryPicked = onEntryPicked
    }

    /// The user's own uploads come first in `auto`: someone who took the
    /// trouble to add a document wants to type that document.
    private func sources() -> [any CorpusSource] {
        switch channel {
        case .quotes: return [BundledCorpus.quotes]
        case .code: return [BundledCorpus.code]
        case .user: return [UserCorpusSource(passages: library)]
        case .auto: return [UserCorpusSource(passages: library), BundledCorpus.quotes, BundledCorpus.code]
        case .generated: return []
        }
    }

    /// ~5.5 characters per word — five letters and a space, the English
    /// average the whole app sizes passages with.
    private func wantedChars(_ wordCount: Int) -> Double { Double(wordCount) * 5.5 }

    public func adaptiveSource(
        filter: Filter, wordCount: Int, rng: inout Mulberry32
    ) throws -> Passage {
        // An explicitly chosen channel ignores the alphabet filter. Otherwise
        // a user in the early curriculum who picks "Code" or "Library" gets
        // pseudo-words instead: every real passage uses letters their
        // alphabet has not unlocked yet, so the channel silently never
        // answers. Honouring the request beats honouring the curriculum.
        let context = CorpusContext(
            filter: channel == .auto ? Set(filter.allowed) : nil,
            wantedChars: wantedChars(wordCount))
        for source in sources() {
            if let entry = source.pick(context, rng: &rng) {
                onEntryPicked?(entry)
                return try makePassage(id: entry.id, text: entry.text)
            }
        }
        onEntryPicked?(nil)
        return try generatePseudoWords(
            filter: filter, options: PseudoWordOptions(wordCount: wordCount), rng: &rng)
    }

    public func benchmarkSource(
        wordCount: Int, settings: ProfileSettings, rng: inout Mulberry32
    ) throws -> Passage {
        // Numbers, punctuation and timed runs go to the generator: a curated
        // quote cannot be assumed to contain the requested symbol density, and
        // a 200-character quote leaves a 60-second test with nothing to type
        // after the first ten seconds.
        let useGenerator =
            settings.includeNumbers || settings.includePunctuation || settings.testMode == .time
        if !useGenerator {
            let context = CorpusContext(wantedChars: wantedChars(wordCount))
            for source in sources() {
                if let entry = source.pick(context, rng: &rng) {
                    onEntryPicked?(entry)
                    return try makePassage(id: entry.id, text: entry.text)
                }
            }
        }
        onEntryPicked?(nil)
        return try generatePlainWords(
            options: PlainWordsOptions(
                wordCount: wordCount, includeNumbers: settings.includeNumbers,
                includePunctuation: settings.includePunctuation),
            rng: &rng)
    }
}
