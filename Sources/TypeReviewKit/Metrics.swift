import Foundation

public let msPerMinute: Double = 60_000
/// The standard "word" length every WPM convention shares.
public let charsPerWord: Double = 5

/// One second of a run.
public struct SecondBin: Sendable, Equatable, Codable {
    /// 1-based second index within the run.
    public let second: Int
    public let chars: Int
    public let errors: Int
    /// Instantaneous raw WPM implied by this second's keystroke count.
    public let rawWpm: Double
}

/// Hard cap on per-second bins — 15 minutes. Defends against a tab-freeze
/// resume producing thousands of empty bins.
private let maxBins = 15 * 60

/// Groups keystrokes into 1-second buckets from the first keystroke.
///
/// Empty seconds inside a run are kept as zero-char bins so the consistency
/// calculation sees pauses. The final bucket may be partial — an accepted
/// approximation in the original, and reproduced here rather than improved,
/// because changing it would change every score users have already seen.
///
/// Bucketing walks the same pause-capped clock as `TextInput.elapsedMs`: a gap
/// beyond the cap contributes exactly the cap, never more.
public func binBySecond(_ steps: [Step]) -> [SecondBin] {
    guard !steps.isEmpty else { return [] }
    var buckets: [Int: (chars: Int, errors: Int)] = [:]
    var maxIndex = 0
    var activeMs: Double = 0
    var previous: Double?

    for step in steps {
        if let previous {
            activeMs += max(0, min(step.timeStamp - previous, pauseCapMs))
        }
        previous = step.timeStamp
        let rawIndex = Int((activeMs / 1000).rounded(.down))
        let index = max(0, min(rawIndex, maxBins - 1))
        maxIndex = max(maxIndex, index)
        var bucket = buckets[index] ?? (0, 0)
        bucket.chars += 1
        if step.typo { bucket.errors += 1 }
        buckets[index] = bucket
    }

    return (0...maxIndex).map { index in
        let bucket = buckets[index] ?? (0, 0)
        return SecondBin(
            second: index + 1, chars: bucket.chars, errors: bucket.errors,
            rawWpm: Stats.roundTo2(Double(bucket.chars) * (msPerMinute / 1000) / charsPerWord))
    }
}

public struct RunMetrics: Sendable, Equatable {
    /// WPM counting only correctly-typed final characters.
    public let netWpm: Double
    /// WPM counting every keystroke regardless of correctness.
    public let rawWpm: Double
    /// Percentage of keystrokes that were correct, 0-100.
    public let accuracy: Double
    /// Evenness of typing speed across the run, 0-100.
    public let consistency: Double
    /// Standard deviation of per-second raw WPM, one decimal place.
    public let wpmStdDev: Double
    /// The per-second series consistency and wpmStdDev are computed from.
    public let wpmSeries: [Double]
    public let correctChars: Int
    public let incorrectChars: Int
    public let durationMs: Double
}

/// Consistency from the per-second binning.
public func computeConsistency(_ steps: [Step]) -> Double {
    let perSecond = binBySecond(steps).map(\.rawWpm)
    let m = Stats.mean(perSecond)
    guard !perSecond.isEmpty, m > 0 else { return 0 }
    return Stats.roundTo2(Stats.kogasa(Stats.stdDev(perSecond) / m))
}

/// The ± figure on the results screen. Raw WPM rather than net, so it stays a
/// pure measure of speed variance and does not fold accuracy into the spread.
public func computeWpmStdDev(_ steps: [Step]) -> Double {
    let perSecond = binBySecond(steps).map(\.rawWpm)
    guard perSecond.count >= 2 else { return 0 }
    return JSMath.round(Stats.stdDev(perSecond) * 10) / 10
}

public func computeRunMetrics(
    steps: [Step], statuses: [CharStatus], durationMs: Double
) -> RunMetrics {
    var correctChars = 0
    var incorrectChars = 0
    for status in statuses {
        if status == .correct { correctChars += 1 } else if status == .incorrect {
            incorrectChars += 1
        }
    }
    let correctSteps = steps.reduce(0) { $0 + ($1.typo ? 0 : 1) }

    let minutes = durationMs / msPerMinute
    let netWpm = minutes > 0 ? Stats.roundTo2(Double(correctChars) / charsPerWord / minutes) : 0
    let rawWpm = minutes > 0 ? Stats.roundTo2(Double(steps.count) / charsPerWord / minutes) : 0
    let accuracy =
        steps.isEmpty
        ? 100 : Stats.roundTo2(Double(correctSteps) / Double(steps.count) * 100)

    return RunMetrics(
        netWpm: netWpm,
        rawWpm: rawWpm,
        accuracy: accuracy,
        consistency: computeConsistency(steps),
        wpmStdDev: computeWpmStdDev(steps),
        wpmSeries: binBySecond(steps).map(\.rawWpm),
        correctChars: correctChars,
        incorrectChars: incorrectChars,
        durationMs: durationMs)
}
