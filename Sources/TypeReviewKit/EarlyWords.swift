/// The words a child types first, in the order a child is taught them.
///
/// The order is the point, and it was measured rather than inherited. English
/// frequency order — what `defaultAlphabet` uses, and what an adult wants —
/// opens with e, t, a, o, i, n, and those six letters spell 5 decodable words
/// out of a reference list of short consonant-vowel-consonant words. The home
/// row spells 3 of them and never uses f or j at all, so two of its six
/// letters could not be practised. The synthetic-phonics order below spells
/// 25, which is why schools teach it and why stage one here can be real words
/// instead of drill noise.
///
/// The 5, 3 and 25 are counts against one fixed reference list of short
/// consonant-vowel-consonant words, measured in September 2026; they describe
/// the three letter *orders*, not this file. Stage one also carries early
/// sight words, which are not all decodable. No number here counts anything in
/// `stages`, and none states how the two compare, so editing the collection
/// cannot make a sentence above false — which is the only reason it is safe to
/// write numbers in a comment at all.
///
/// `EarlyTextTests` holds every stage to its own alphabet, so a word can never
/// quietly need a letter the child has not met.
public enum EarlyWords {
    /// One teaching stage: the letters it introduces, and the words that
    /// become spellable once they are known.
    public struct Stage: Sendable, Equatable {
        /// The letters this stage adds, in teaching order.
        public let added: String
        public let words: [String]

        public init(added: String, words: [String]) {
            self.added = added
            self.words = words
        }
    }

    /// Every stage, in teaching order.
    ///
    /// One collection rather than four properties, because `all` and
    /// `alphabets` are derived from it: a fifth stage is a single edit here,
    /// and cannot be added to the curriculum while being left out of the word
    /// list or the alphabets — which is exactly what four parallel constants
    /// allowed, silently.
    public static let stages: [Stage] = [
        // The first six. `sat`, `sit`, `pin`, `tap`, `nap` — words from day one.
        Stage(
            added: "satpin",
            words: [
                "a", "an", "ant", "ants", "as", "at", "in", "is", "it", "its", "nap", "nip",
                "paint", "pan", "pants", "pat", "pin", "pit", "saints", "sat", "sip", "sit",
                "snap", "spin", "spit", "stain", "tan", "tap", "tin", "tip"
            ]),
        // Adds the rest of the common consonants and the second vowel.
        Stage(
            added: "ckehrmd",
            words: [
                "can", "cap", "car", "cast", "cat", "cream", "dark", "desk", "dream", "had",
                "ham", "hand", "has", "hat", "hen", "her", "here", "him", "his", "hit",
                "mad", "made", "make", "man", "map", "market", "mat", "men", "met", "nest",
                "ran", "rat", "red", "rest", "rim", "rip", "strike"
            ]),
        // Adds the remaining vowels, so most short English words are reachable.
        Stage(
            added: "goulfb",
            words: [
                "about", "back", "bag", "bed", "before", "better", "big", "book", "bun",
                "bus", "but", "dog", "double", "fish", "flag", "for", "four", "from",
                "full", "fun", "go", "gold", "good", "got", "left", "leg", "log", "look",
                "lot", "order", "under"
            ]),
        // The rare letters last, because almost nothing early needs them.
        Stage(
            added: "jzwvyxq",
            words: [
                "box", "explore", "fix", "fox", "jacket", "jam", "jump", "just", "puzzle",
                "quick", "quiet", "van", "very", "was", "water", "way", "went", "wet",
                "window", "winter", "with", "yellow", "yes", "you", "your", "zip", "zoo"
            ]),
    ]

    /// Every stage's words, in teaching order.
    public static let all: [String] = stages.flatMap(\.words)

    /// The letters available by the end of each stage, cumulative.
    public static let alphabets: [[String]] = {
        var letters: [String] = []
        return stages.map { stage in
            letters += stage.added.map(String.init)
            return letters
        }
    }()
}
