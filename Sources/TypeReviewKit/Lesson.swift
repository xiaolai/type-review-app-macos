import Foundation

/// Converts a target speed into per-character timing and confidence ratios.
public struct Target {
    public let targetSpeed: Double
    /// Target milliseconds per character.
    public let timePerChar: Double

    public init(targetSpeed: Double) {
        precondition(targetSpeed.isFinite && targetSpeed > 0, "targetSpeed must be positive")
        self.targetSpeed = targetSpeed
        timePerChar = msPerMinute / (targetSpeed * charsPerWord)
    }

    /// targetTime / actualTime. 1 is exactly on target, above is faster. nil
    /// when there is no timing data — which is not the same as slow, and the
    /// planner treats the two differently.
    public func confidence(_ timeToType: Double?) -> Double? {
        guard let timeToType, timeToType > 0 else { return nil }
        return timePerChar / timeToType
    }
}

/// English letters in rough frequency order — common letters are learned first.
public let defaultAlphabet: [String] = [
    "e", "t", "a", "o", "i", "n", "s", "r", "h", "l", "d", "c", "u",
    "m", "f", "p", "g", "w", "y", "b", "v", "k", "x", "j", "q", "z",
]

public struct AdaptiveSettings: Sendable, Equatable {
    /// Smallest alphabet a guided lesson ever uses.
    public var minAlphabetSize: Double
    /// How far past the minimum the alphabet may expand, 0...1.
    public var alphabetExpansion: Double

    public init(minAlphabetSize: Double = 6, alphabetExpansion: Double = 0) {
        self.minAlphabetSize = minAlphabetSize
        self.alphabetExpansion = alphabetExpansion
    }
}

public struct LessonKey: Sendable, Equatable {
    public let letter: String
    public let included: Bool
    /// Freshly unlocked to fill the alphabet — generators must surface it.
    public let forced: Bool
    /// The single weakest included letter.
    public let focused: Bool
    public let confidence: Double?
    public let bestConfidence: Double?
}

public struct WeakBigram: Sendable, Equatable {
    public let bigram: String
    public let confidence: Double
}

public struct LessonPlan: Sendable, Equatable {
    public let included: [String]
    public let focus: String?
    public let keys: [LessonKey]
    public let weakBigrams: [WeakBigram]
}

private func clamp(_ n: Double, _ lo: Double, _ hi: Double) -> Double {
    min(hi, max(lo, n))
}

/// Decides which letters the next lesson covers and which one to drill hardest.
///
/// Two axes, deliberately different: unlocking uses *best-ever* confidence so
/// the curriculum never backslides, while focus uses *current* confidence so
/// each lesson drills present weakness rather than a stale historical low.
public func planLesson(
    letters: [String],
    bigramStats: OrderedMap<BigramStats>,
    target: Target,
    settings: AdaptiveSettings = AdaptiveSettings()
) -> LessonPlan {
    let count = Double(letters.count)
    let minSize = clamp(JSMath.round(settings.minAlphabetSize), min(1, count), count)
    let expansion = clamp(settings.alphabetExpansion, 0, 1)
    let maxSize = clamp(minSize + JSMath.round((count - minSize) * expansion), minSize, count)

    let stats = deriveKeyStats(letters: letters, bigramStats: bigramStats)
    func confidenceOf(_ letter: String) -> Double? { target.confidence(stats[letter]?.timeToType) }
    func bestConfidenceOf(_ letter: String) -> Double? {
        target.confidence(stats[letter]?.bestTimeToType)
    }
    func mastered(_ confidence: Double?) -> Bool {
        guard let confidence else { return false }
        return confidence >= 1
    }

    var included: [String] = []
    var forced: Set<String> = []

    for letter in letters {
        if Double(included.count) < minSize {
            included.append(letter)
            continue
        }
        if Double(included.count) < maxSize {
            included.append(letter)
            forced.insert(letter)
            continue
        }
        if mastered(bestConfidenceOf(letter)) {
            included.append(letter)
            continue
        }
        if included.allSatisfy({ mastered(bestConfidenceOf($0)) }) {
            included.append(letter)
            forced.insert(letter)
            continue
        }
        // Letters are in difficulty order: once one fails to unlock, so will
        // every letter after it.
        break
    }

    let includedSet = Set(included)

    // The weakest included letter still below target. Unmeasured letters sort
    // as weakest, so a freshly unlocked one is drilled first.
    var focus: String?
    var focusScore = Double.infinity
    for letter in included {
        let confidence = confidenceOf(letter)
        if let confidence, confidence >= 1 { continue }
        let score = confidence ?? -.infinity
        if score < focusScore {
            focusScore = score
            focus = letter
        }
    }

    let keys = letters.map { letter in
        LessonKey(
            letter: letter,
            included: includedSet.contains(letter),
            forced: forced.contains(letter),
            focused: letter == focus,
            confidence: confidenceOf(letter),
            bestConfidence: bestConfidenceOf(letter))
    }

    // Weakest bigrams whose both characters are included. Never-timed bigrams
    // are skipped: weakness cannot be claimed without measurement.
    var weak: [WeakBigram] = []
    for stats in bigramStats.values {
        guard stats.bigram.utf16.count == 2 else { continue }
        guard includedSet.contains(firstCharacter(of: stats.bigram)),
            includedSet.contains(secondCharacter(of: stats.bigram))
        else { continue }
        guard let confidence = target.confidence(stats.timeToType), confidence < 1 else { continue }
        weak.append(WeakBigram(bigram: stats.bigram, confidence: confidence))
    }
    // STABLE sort, and the stability is the point. Ties are ordinary — any two
    // bigrams typed at the same speed tie — and JavaScript's sort keeps
    // insertion order for them, which decides which three the user is told to
    // drill. Swift's `sorted` gives no such guarantee, so the index is carried
    // into the comparison to make the order total.
    let ranked = weak.enumerated().sorted { left, right in
        left.element.confidence == right.element.confidence
            ? left.offset < right.offset
            : left.element.confidence < right.element.confidence
    }.map(\.element)

    return LessonPlan(
        included: included, focus: focus, keys: keys, weakBigrams: Array(ranked.prefix(3)))
}
