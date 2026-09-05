import Foundation

/// One bigram's aggregate from a single run.
///
/// A bigram is the *transition* between two consecutive expected characters,
/// and its timing is the time taken to produce the second given the first —
/// which is where typing speed actually bottlenecks. `qu` is fast for
/// everyone; `pl` and `mn` are personal.
public struct BigramHit: Sendable, Equatable, Codable {
    public var hitCount: Int
    public var missCount: Int
    /// Mean ms to type the second character. 0 when no timed hits.
    public var timeToType: Double
}

/// A run's per-bigram breakdown, in first-appearance order.
public typealias Histogram = OrderedMap<BigramHit>

/// A correct keystroke faster than this is an outlier for timing purposes.
private let minPlausibleMs: Double = 40
/// A correct keystroke slower than this is an outlier.
private let maxPlausibleMs: Double = 12_000

/// Aggregates a run's keystroke log into per-bigram counts and mean timings.
///
/// The first step contributes to no bigram — the first character of a passage
/// has no predecessor, and folding it into a synthetic pair would add the
/// warm-up effect to real data.
///
/// Outlier timings still count as hits but are excluded from the average, so a
/// paste or a pause cannot move the speed estimate while still recording that
/// the bigram was practised.
public func histogramFromSteps(_ steps: [Step]) -> Histogram {
    var histogram = Histogram()
    guard steps.count >= 2 else { return histogram }

    // Accumulators kept in the same insertion order as the output.
    var accumulator = OrderedMap<(hit: Int, miss: Int, timeSum: Double, timeCount: Int)>()

    for index in 1..<steps.count {
        let previous = steps[index - 1]
        let current = steps[index]
        // Bigrams span *adjacent* positions only. After a backspace or a
        // stop-on-error retry two consecutive steps can share a position or
        // move backwards, which would otherwise pair non-neighbouring
        // characters.
        guard current.position == previous.position + 1 else { continue }
        let bigram = previous.expected + current.expected

        var entry = accumulator[bigram] ?? (0, 0, 0, 0)
        entry.hit += 1
        if current.typo {
            entry.miss += 1
        } else if current.timeToType >= minPlausibleMs, current.timeToType <= maxPlausibleMs {
            entry.timeSum += current.timeToType
            entry.timeCount += 1
        }
        accumulator[bigram] = entry
    }

    for (bigram, entry) in accumulator {
        histogram[bigram] = BigramHit(
            hitCount: entry.hit,
            missCount: entry.miss,
            timeToType: entry.timeCount > 0
                ? JSMath.round(entry.timeSum / Double(entry.timeCount)) : 0)
    }
    return histogram
}
