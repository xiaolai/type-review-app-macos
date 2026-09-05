import Foundation

/// Each completed run moves a bigram's estimate 10% toward the new sample.
public let emaAlpha: Double = 0.1

/// Exponential moving average — smooths run-to-run noise while still tracking
/// real improvement.
public struct EmaFilter {
    private let alpha: Double
    private(set) public var value: Double?

    public init(alpha: Double) {
        precondition(alpha.isFinite && alpha > 0 && alpha <= 1, "EMA alpha must be in (0, 1]")
        self.alpha = alpha
    }

    @discardableResult
    public mutating func add(_ sample: Double) -> Double {
        let next = value.map { $0 + alpha * (sample - $0) } ?? sample
        value = next
        return next
    }
}

public struct BigramSample: Sendable, Equatable {
    public let runIndex: Int
    public let hitCount: Int
    public let missCount: Int
    public let timeToType: Double
}

/// A bigram's accumulated stats across every run so far.
public struct BigramStats: Sendable, Equatable {
    public let bigram: String
    public let samples: [BigramSample]
    public let hitCount: Int
    public let missCount: Int
    /// EMA of per-run timings. nil until the bigram has a timed sample.
    public let timeToType: Double?
    /// Lowest EMA ever observed — the bigram's personal best.
    public let bestTimeToType: Double?
}

/// Per-letter view derived from bigram stats.
public struct KeyStats: Sendable, Equatable {
    public let letter: String
    public let hitCount: Int
    public let missCount: Int
    public let timeToType: Double?
    public let bestTimeToType: Double?
}

/// Replays run histograms, oldest first, into per-bigram accumulated stats.
///
/// Order matters twice: the EMA depends on run order, and the resulting map's
/// insertion order — first appearance across all runs — is what every
/// downstream float sum and tie-break follows.
public func buildBigramStatsMap(_ runs: [Histogram]) -> OrderedMap<BigramStats> {
    var samples: [String: [BigramSample]] = [:]
    var filters: [String: EmaFilter] = [:]
    var totals: [String: (hit: Int, miss: Int)] = [:]
    var best: [String: Double] = [:]
    // First-appearance order, tracked explicitly rather than left to a
    // Dictionary, whose order would change between launches.
    var seen: [String] = []
    var seenSet: Set<String> = []

    for (runIndex, histogram) in runs.enumerated() {
        for (bigram, hit) in histogram {
            if seenSet.insert(bigram).inserted { seen.append(bigram) }
            samples[bigram, default: []].append(
                BigramSample(
                    runIndex: runIndex, hitCount: hit.hitCount, missCount: hit.missCount,
                    timeToType: hit.timeToType))
            var total = totals[bigram] ?? (0, 0)
            total.hit += hit.hitCount
            total.miss += hit.missCount
            totals[bigram] = total

            if hit.timeToType > 0 {
                var filter = filters[bigram] ?? EmaFilter(alpha: emaAlpha)
                let filtered = filter.add(hit.timeToType)
                filters[bigram] = filter
                if best[bigram] == nil || filtered < best[bigram]! {
                    best[bigram] = filtered
                }
            }
        }
    }

    var result = OrderedMap<BigramStats>()
    for bigram in seen {
        let total = totals[bigram] ?? (0, 0)
        result[bigram] = BigramStats(
            bigram: bigram,
            samples: samples[bigram] ?? [],
            hitCount: total.hit,
            missCount: total.miss,
            timeToType: filters[bigram]?.value,
            bestTimeToType: best[bigram])
    }
    return result
}

/// Projects bigram stats onto a per-letter view, weighted by hit count.
///
/// A letter's timing is the hit-weighted average over every bigram whose
/// *second* character is that letter, because that bigram's timing is the
/// time to type this letter given the previous one.
///
/// The traversal order of `bigramStats` is load-bearing: these are floating
/// point sums, and a different order gives a different answer in the last
/// bits. Iterating an unordered Dictionary here would make the result differ
/// between launches of the same binary.
public func deriveKeyStats(
    letters: [String], bigramStats: OrderedMap<BigramStats>
) -> OrderedMap<KeyStats> {
    var result = OrderedMap<KeyStats>()
    for letter in letters {
        var hitCount = 0
        var missCount = 0
        var timedHits = 0
        var timedSum: Double = 0
        var bestHits = 0
        var bestSum: Double = 0

        for stats in bigramStats.values {
            guard secondCharacter(of: stats.bigram) == letter else { continue }
            hitCount += stats.hitCount
            missCount += stats.missCount
            if let timeToType = stats.timeToType {
                timedHits += stats.hitCount
                timedSum += timeToType * Double(stats.hitCount)
            }
            if let bestTimeToType = stats.bestTimeToType {
                bestHits += stats.hitCount
                bestSum += bestTimeToType * Double(stats.hitCount)
            }
        }

        result[letter] = KeyStats(
            letter: letter,
            hitCount: hitCount,
            missCount: missCount,
            timeToType: timedHits > 0 ? timedSum / Double(timedHits) : nil,
            bestTimeToType: bestHits > 0 ? bestSum / Double(bestHits) : nil)
    }
    return result
}

/// Bigrams are two UTF-16 code units, matching the engine's coordinate system.
func firstCharacter(of bigram: String) -> String {
    let units = Array(bigram.utf16)
    guard let first = units.first else { return "" }
    return String(utf16CodeUnits: [first], count: 1)
}

func secondCharacter(of bigram: String) -> String {
    let units = Array(bigram.utf16)
    guard units.count > 1 else { return "" }
    return String(utf16CodeUnits: [units[1]], count: 1)
}
