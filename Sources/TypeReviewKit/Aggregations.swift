import Foundation

/// Statistics over completed runs.
///
/// Everything here is computed in **local calendar days**, which is what makes
/// it worth its own file. A day is not 86,400,000 milliseconds: across a
/// daylight-saving boundary it is 23 or 25 hours, so subtracting fixed
/// milliseconds lands on the wrong date twice a year. Calendar arithmetic is
/// used throughout, and the vectors are generated under two timezones — one
/// with DST and one without — to keep that honest.

public struct PerKeyStat: Sendable, Equatable {
    /// Times this character was the *second* key of a bigram, i.e. typed with
    /// a measurable interval.
    public let hits: Int
    public let misses: Int
    /// Hit-weighted mean inter-key time. 0 when untimed.
    public let avgMs: Double
    /// Errors as a fraction of attempts, 0...1.
    public let errorRate: Double
}

/// Per-character stats, reduced from the per-bigram histograms.
///
/// Each bigram contributes to its **second** character — that is the keystroke
/// whose timing the engine measures. `hitCount` counts every attempt including
/// typos, so total attempts is `hitCount`, not `hitCount + missCount`, which
/// would count the typos twice.
public func aggregatePerKey(_ results: [RunResult]) -> OrderedMap<PerKeyStat> {
    struct Accumulator: Sendable, Equatable {
        var hits = 0
        var misses = 0
        var weightedMs: Double = 0
    }
    var accumulator = OrderedMap<Accumulator>()
    for result in results {
        for (bigram, hit) in result.histogram {
            guard bigram.utf16.count >= 2 else { continue }
            let second = secondCharacter(of: bigram)
            guard !second.isEmpty else { continue }
            var entry = accumulator[second] ?? Accumulator()
            entry.hits += hit.hitCount
            entry.misses += hit.missCount
            entry.weightedMs += Double(hit.hitCount) * hit.timeToType
            accumulator[second] = entry
        }
    }
    var out = OrderedMap<PerKeyStat>()
    for (key, entry) in accumulator {
        out[key] = PerKeyStat(
            hits: entry.hits,
            misses: entry.misses,
            avgMs: entry.hits > 0 ? entry.weightedMs / Double(entry.hits) : 0,
            errorRate: entry.hits > 0 ? Double(entry.misses) / Double(entry.hits) : 0)
    }
    return out
}

/// Which finger a touch typist uses for a key, on a US QWERTY layout.
///
/// Ported from the website's `aggregations.ts`, values and order unchanged.
/// The per-key heatmap already carries this information; a reader has to
/// assemble "my right pinky is the slow one" out of it in their head, and this
/// is the assembly.
public enum Finger: String, Sendable, CaseIterable {
    case leftPinky = "left-pinky"
    case leftRing = "left-ring"
    case leftMiddle = "left-middle"
    case leftIndex = "left-index"
    case thumb
    case rightIndex = "right-index"
    case rightMiddle = "right-middle"
    case rightRing = "right-ring"
    case rightPinky = "right-pinky"

    /// The order the panel reads in: left hand outward-in, thumb, right hand
    /// in-outward. Not the declaration order of a set, which would put the
    /// thumb wherever it happened to be written.
    public static let display: [Finger] = [
        .leftPinky, .leftRing, .leftMiddle, .leftIndex, .thumb,
        .rightIndex, .rightMiddle, .rightRing, .rightPinky,
    ]

    public var label: String {
        switch self {
        case .leftPinky: return "L pinky"
        case .leftRing: return "L ring"
        case .leftMiddle: return "L middle"
        case .leftIndex: return "L index"
        case .thumb: return "thumb"
        case .rightIndex: return "R index"
        case .rightMiddle: return "R middle"
        case .rightRing: return "R ring"
        case .rightPinky: return "R pinky"
        }
    }

    /// Standard touch-typing assignment. Digits and the rarely-used keys are
    /// deliberately absent: a key with no finger is skipped rather than
    /// guessed at, which is why this is a lookup and not a computation.
    public static let map: [String: Finger] = [
        "q": .leftPinky, "a": .leftPinky, "z": .leftPinky,
        "w": .leftRing, "s": .leftRing, "x": .leftRing,
        "e": .leftMiddle, "d": .leftMiddle, "c": .leftMiddle,
        "r": .leftIndex, "f": .leftIndex, "v": .leftIndex,
        "t": .leftIndex, "g": .leftIndex, "b": .leftIndex,
        "y": .rightIndex, "h": .rightIndex, "n": .rightIndex,
        "u": .rightIndex, "j": .rightIndex, "m": .rightIndex,
        "i": .rightMiddle, "k": .rightMiddle, ",": .rightMiddle,
        "o": .rightRing, "l": .rightRing, ".": .rightRing,
        "p": .rightPinky, ";": .rightPinky, "/": .rightPinky, "'": .rightPinky,
        " ": .thumb,
    ]
}

public struct FingerStat: Sendable, Equatable {
    public let finger: Finger
    public let hits: Int
    public let avgMs: Double
    public let errorRate: Double
}

/// Per-key stats regrouped by the finger responsible for each key.
///
/// Built on `aggregatePerKey` rather than on the runs, exactly as the website
/// does — the same numbers, bucketed differently, so the two can never
/// disagree about a key while agreeing about its finger.
///
/// `hits` is total attempts including typos, so `misses / hits` is the rate.
/// The same note is on `aggregatePerKey`, and it is the arithmetic most easily
/// got wrong here: `misses / (hits + misses)` counts every typo twice.
public func aggregatePerFinger(_ perKey: OrderedMap<PerKeyStat>) -> [FingerStat] {
    struct Accumulator { var hits = 0; var misses = 0; var weightedMs = 0.0 }
    var acc: [Finger: Accumulator] = [:]
    for key in perKey.keys {
        guard let finger = Finger.map[key], let stat = perKey[key] else { continue }
        var current = acc[finger] ?? Accumulator()
        current.hits += stat.hits
        current.misses += stat.misses
        current.weightedMs += Double(stat.hits) * stat.avgMs
        acc[finger] = current
    }
    return Finger.display.compactMap { finger in
        guard let v = acc[finger], v.hits > 0 else { return nil }
        return FingerStat(
            finger: finger, hits: v.hits,
            avgMs: v.weightedMs / Double(v.hits),
            errorRate: Double(v.misses) / Double(v.hits))
    }
}

public struct BigramStat: Sendable, Equatable {
    public let bigram: String
    public let hits: Int
    public let misses: Int
    public let avgMs: Double
}

/// The slowest bigrams across runs, worst first.
///
/// Bigrams below `minHits` are dropped: one slow attempt at a rare pair is
/// noise, and telling someone to drill it would be advice built on a single
/// sample.
public func slowestBigrams(_ results: [RunResult], count: Int, minHits: Int = 5) -> [BigramStat] {
    struct Accumulator: Sendable, Equatable {
        var hits = 0
        var misses = 0
        var weightedMs: Double = 0
    }
    var accumulator = OrderedMap<Accumulator>()
    for result in results {
        for (bigram, hit) in result.histogram {
            var entry = accumulator[bigram] ?? Accumulator()
            entry.hits += hit.hitCount
            entry.misses += hit.missCount
            entry.weightedMs += Double(hit.hitCount) * hit.timeToType
            accumulator[bigram] = entry
        }
    }
    var list: [(index: Int, stat: BigramStat)] = []
    for (index, entry) in accumulator.entries.enumerated() where entry.value.hits >= minHits {
        list.append(
            (index,
             BigramStat(
                bigram: entry.key, hits: entry.value.hits, misses: entry.value.misses,
                avgMs: entry.value.weightedMs / Double(entry.value.hits))))
    }
    // Descending by time, ties keeping insertion order — the same stability
    // JavaScript's sort gives, so both implementations name the same bigrams.
    return list.sorted {
        $0.stat.avgMs == $1.stat.avgMs ? $0.index < $1.index : $0.stat.avgMs > $1.stat.avgMs
    }.prefix(count).map(\.stat)
}

/// The calendar day-level statistics are computed in.
///
/// Passed explicitly rather than read from a global: a statistic that silently
/// depends on the machine's timezone is not one the two implementations can be
/// held to agreeing on, and the tests pin it to the timezone each vector was
/// generated under.
public func localStatisticsCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
}

/// `YYYY-MM-DD` in local time. "A session on Monday" is a local idea.
public func dayKey(_ timestamp: Double, calendar: Calendar) -> String {
    let date = Date(timeIntervalSince1970: timestamp / 1000)
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
        format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

/// The day key `daysBack` calendar days before `anchor`.
///
/// Calendar subtraction, not `anchor - days * 86_400_000`: across a
/// daylight-saving change that arithmetic lands on the wrong date.
public func dayKeyBack(
    _ anchor: Double, _ daysBack: Int, calendar: Calendar
) -> String {
    let date = Date(timeIntervalSince1970: anchor / 1000)
    let shifted = calendar.date(byAdding: .day, value: -daysBack, to: date) ?? date
    return dayKey(shifted.timeIntervalSince1970 * 1000, calendar: calendar)
}

/// Sessions per local day.
public func dailyCounts(
    _ results: [RunResult], calendar: Calendar
) -> OrderedMap<Int> {
    var out = OrderedMap<Int>()
    for result in results {
        let key = dayKey(result.timestamp, calendar: calendar)
        out[key] = (out[key] ?? 0) + 1
    }
    return out
}

public struct StreakStat: Sendable, Equatable {
    /// Days in a row ending at the most recent qualifying day.
    public let current: Int
    /// The longest run of consecutive practice days ever.
    public let longest: Int
}

/// Current and longest streaks of consecutive practice days.
///
/// The current streak tolerates not having typed *yet today*: checking at 9am
/// after a twelve-day run that ended yesterday shows twelve, not zero. A full
/// day missed resets it.
public func streak(
    _ results: [RunResult], now: Double, calendar: Calendar
) -> StreakStat {
    guard !results.isEmpty else { return StreakStat(current: 0, longest: 0) }
    var days: Set<String> = []
    for result in results { days.insert(dayKey(result.timestamp, calendar: calendar)) }

    let sorted = days.sorted()
    var longest = 1
    var run = 1
    // The guard above proves `results` is non-empty, so `sorted` holds at
    // least one day and `1..<sorted.count` is either empty or valid. The
    // `max(_:1)` and the `where` clause defended against a case that cannot
    // reach here.
    for index in 1..<sorted.count {
        if addOneDay(sorted[index - 1], calendar: calendar) == sorted[index] {
            run += 1
            longest = max(longest, run)
        } else {
            run = 1
        }
    }

    let today = dayKey(now, calendar: calendar)
    let yesterday = dayKeyBack(now, 1, calendar: calendar)
    var cursor: String? = days.contains(today) ? today : (days.contains(yesterday) ? yesterday : nil)
    var current = 0
    while let day = cursor, days.contains(day) {
        current += 1
        cursor = subtractOneDay(day, calendar: calendar)
    }

    return StreakStat(current: current, longest: longest)
}

private func parseDayKey(_ key: String, calendar: Calendar) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var components = DateComponents()
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]
    return calendar.date(from: components)
}

private func addOneDay(_ key: String, calendar: Calendar) -> String {
    guard let date = parseDayKey(key, calendar: calendar),
        let next = calendar.date(byAdding: .day, value: 1, to: date)
    else { return key }
    return dayKey(next.timeIntervalSince1970 * 1000, calendar: calendar)
}

private func subtractOneDay(_ key: String, calendar: Calendar) -> String {
    guard let date = parseDayKey(key, calendar: calendar),
        let previous = calendar.date(byAdding: .day, value: -1, to: date)
    else { return key }
    return dayKey(previous.timeIntervalSince1970 * 1000, calendar: calendar)
}
