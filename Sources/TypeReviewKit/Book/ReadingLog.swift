import Foundation

/// Bigrams kept per day per book. The same ceiling a run's histogram has on
/// load, so a merged history is no larger per entry than a practice one.
let maxReadingHistogramEntries = 5_000
/// Days whose bigram detail is kept. Older days keep their totals — the
/// streak and the calendar need those for good — and drop the histogram,
/// which is what would otherwise make the file grow without bound.
public let maxReadingHistogramDays = 400

/// One chapter's share of a day: what typing speed by chapter is drawn from.
public struct ChapterTally: Sendable, Equatable {
    public var activeMs: Double = 0
    public var correctChars = 0

    public init(activeMs: Double = 0, correctChars: Int = 0) {
        self.activeMs = activeMs
        self.correctChars = correctChars
    }
}

/// One book's typing on one local day.
public struct ReadingTally: Sendable, Equatable {
    /// Active typing time: pauses over 12 s count as 12 s, as in a run.
    public var activeMs: Double = 0
    public var sentences = 0
    public var correctChars = 0
    public var incorrectChars = 0
    public var keystrokes = 0
    public var errors = 0
    /// Separate times the child sat down to this book. What "Sessions"
    /// counts, the way practice counts runs.
    public var sittings = 0
    /// Sentences the child asked to hear. A parent can tell reading from
    /// listening by comparing this with `sentences`.
    public var sentencesHeard = 0
    public var histogram = Histogram()
    /// Keyed by chapter index.
    public var chapters: [Int: ChapterTally] = [:]

    public init() {}
}

/// What one typed sentence adds to the log.
public struct SentenceRecord: Sendable, Equatable {
    public let bookId: String
    public let chapter: Int
    public let metrics: RunMetrics
    public let keystrokes: Int
    public let errors: Int
    public let histogram: Histogram
    /// The first sentence after a break: a new sitting.
    public let startsSitting: Bool

    public init(
        bookId: String, chapter: Int, metrics: RunMetrics, keystrokes: Int, errors: Int,
        histogram: Histogram, startsSitting: Bool
    ) {
        self.bookId = bookId
        self.chapter = chapter
        self.metrics = metrics
        self.keystrokes = keystrokes
        self.errors = errors
        self.histogram = histogram
        self.startsSitting = startsSitting
    }
}

/// Book typing per local day, per book. Kept beside the profile, never in it.
public struct ReadingLog: Sendable, Equatable {
    /// Day key (`YYYY-MM-DD`) to book id to that day's tally.
    public private(set) var days: [String: [String: ReadingTally]]

    public init(days: [String: [String: ReadingTally]] = [:]) {
        self.days = days
    }

    public var isEmpty: Bool { days.isEmpty }

    public mutating func record(_ sentence: SentenceRecord, on day: String) {
        var tally = days[day]?[sentence.bookId] ?? ReadingTally()
        tally.activeMs += sentence.metrics.durationMs
        tally.sentences += 1
        tally.correctChars += sentence.metrics.correctChars
        tally.incorrectChars += sentence.metrics.incorrectChars
        tally.keystrokes += sentence.keystrokes
        tally.errors += sentence.errors
        if sentence.startsSitting || tally.sittings == 0 { tally.sittings += 1 }
        tally.histogram = mergeHistogram(tally.histogram, sentence.histogram)
        var chapter = tally.chapters[sentence.chapter] ?? ChapterTally()
        chapter.activeMs += sentence.metrics.durationMs
        chapter.correctChars += sentence.metrics.correctChars
        tally.chapters[sentence.chapter] = chapter
        days[day, default: [:]][sentence.bookId] = tally
    }

    public mutating func recordHeard(bookId: String, on day: String) {
        var tally = days[day]?[bookId] ?? ReadingTally()
        tally.sentencesHeard += 1
        days[day, default: [:]][bookId] = tally
    }

    /// Drops the bigram detail of days beyond the newest `limit`.
    public mutating func pruneHistograms(keeping limit: Int = maxReadingHistogramDays) {
        guard days.count > limit, limit >= 0 else { return }
        for key in days.keys.sorted().prefix(days.count - limit) {
            for book in days[key]!.keys { days[key]![book]!.histogram = Histogram() }
        }
    }

    /// Forgets a removed book.
    public mutating func remove(bookId: String) {
        for key in Array(days.keys) {
            days[key]!.removeValue(forKey: bookId)
            if days[key]!.isEmpty { days.removeValue(forKey: key) }
        }
    }

    /// Every day's tally for one book, oldest first.
    public func tallies(forBook bookId: String) -> [(day: String, tally: ReadingTally)] {
        days.keys.sorted().compactMap { day in days[day]?[bookId].map { (day, $0) } }
    }
}

/// Two histograms as one: counts added, mean times weighted by hits.
func mergeHistogram(_ base: Histogram, _ addition: Histogram) -> Histogram {
    var out = base
    for (bigram, hit) in addition {
        if var existing = out[bigram] {
            let hits = existing.hitCount + hit.hitCount
            existing.timeToType = hits > 0
                ? (existing.timeToType * Double(existing.hitCount) + hit.timeToType * Double(hit.hitCount))
                    / Double(hits)
                : 0
            existing.hitCount = hits
            existing.missCount += hit.missCount
            out[bigram] = existing
        } else if out.count < maxReadingHistogramEntries {
            out[bigram] = hit
        }
    }
    return out
}

// MARK: - Codec

public enum ReadingLogError: Error, Equatable {
    case notAnObject
}

private func count(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue == number.doubleValue.rounded(), number.doubleValue >= 0,
        number.doubleValue <= 1e12
    else { return nil }
    return number.intValue
}

private func milliseconds(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 1e12
    else { return nil }
    return number.doubleValue
}

private func decodeTally(_ raw: Any) -> ReadingTally? {
    guard let entry = raw as? [String: Any],
        let activeMs = milliseconds(entry["activeMs"]), let sentences = count(entry["sentences"]),
        let correct = count(entry["correctChars"]), let incorrect = count(entry["incorrectChars"]),
        let keystrokes = count(entry["keystrokes"]), let errors = count(entry["errors"]),
        let sittings = count(entry["sittings"]), let heard = count(entry["sentencesHeard"])
    else { return nil }
    var tally = ReadingTally()
    tally.activeMs = activeMs
    tally.sentences = sentences
    tally.correctChars = correct
    tally.incorrectChars = incorrect
    tally.keystrokes = keystrokes
    tally.errors = errors
    tally.sittings = sittings
    tally.sentencesHeard = heard
    // Malformed detail is dropped entry by entry; the totals above are what
    // the streak and calendar need, and they survive a bad bigram.
    if let histogram = entry["histogram"] as? [String: Any] {
        for key in histogram.keys.sorted() {
            guard tally.histogram.count < maxReadingHistogramEntries,
                key.utf16.count >= 2, key.utf16.count <= 8,
                let triple = histogram[key] as? [Any], triple.count == 3,
                let hits = count(triple[0]), let misses = count(triple[1]),
                let ms = milliseconds(triple[2])
            else { continue }
            tally.histogram[key] = BigramHit(hitCount: hits, missCount: misses, timeToType: ms)
        }
    }
    if let chapters = entry["chapters"] as? [String: Any] {
        for (key, value) in chapters {
            guard let index = Int(key), index >= 0, index < maxBookSentences,
                let pair = value as? [Any], pair.count == 2,
                let ms = milliseconds(pair[0]), let chars = count(pair[1])
            else { continue }
            tally.chapters[index] = ChapterTally(activeMs: ms, correctChars: chars)
        }
    }
    return tally
}

/// Parses the stored log, discarding entries it cannot vouch for.
///
/// Tolerant for the reason the keystroke log is: losing months of reading
/// history over one bad line is worse than losing the line. A payload that is
/// not an object at all is a file this app did not write, and throws.
public func decodeReadingLog(_ data: Data) throws -> ReadingLog {
    guard let raw = try? JSONSerialization.jsonObject(with: data), let object = raw as? [String: Any] else {
        throw ReadingLogError.notAnObject
    }
    var days: [String: [String: ReadingTally]] = [:]
    for (day, value) in object {
        guard isKeystrokeDayKey(day), let books = value as? [String: Any] else { continue }
        var row: [String: ReadingTally] = [:]
        for (book, entry) in books where isValidBookId(book) {
            if let tally = decodeTally(entry) { row[book] = tally }
        }
        if !row.isEmpty { days[day] = row }
    }
    var log = ReadingLog(days: days)
    log.pruneHistograms()
    return log
}

/// Sorted keys, so an unchanged day writes unchanged bytes.
public func encodeReadingLog(_ log: ReadingLog) throws -> Data {
    var object: [String: Any] = [:]
    for (day, books) in log.days {
        var row: [String: Any] = [:]
        for (book, tally) in books {
            var histogram: [String: Any] = [:]
            for (bigram, hit) in tally.histogram {
                histogram[bigram] = [hit.hitCount, hit.missCount, hit.timeToType]
            }
            var chapters: [String: Any] = [:]
            for (index, chapter) in tally.chapters {
                chapters[String(index)] = [chapter.activeMs, chapter.correctChars]
            }
            row[book] = [
                "activeMs": tally.activeMs, "sentences": tally.sentences,
                "correctChars": tally.correctChars, "incorrectChars": tally.incorrectChars,
                "keystrokes": tally.keystrokes, "errors": tally.errors, "sittings": tally.sittings,
                "sentencesHeard": tally.sentencesHeard, "histogram": histogram, "chapters": chapters,
            ] as [String: Any]
        }
        object[day] = row
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

// MARK: - Counting book typing in the statistics

/// Noon on a day, local time: a timestamp that lands on that day under any
/// daylight-saving change, which midnight does not.
private func noon(of day: String, calendar: Calendar) -> Double? {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var components = DateComponents()
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]
    components.hour = 12
    return calendar.date(from: components).map { $0.timeIntervalSince1970 * 1000 }
}

/// The reading log as runs, so the statistics count book typing through the
/// same functions they count practice with.
///
/// `streak`, `dailyCounts`, `charactersPerDay` and `aggregatePerKey` are
/// pinned to the website by the aggregation vectors and stay untouched; this
/// turns each day's book typing into the inputs they already take. One run
/// per sitting, so "Sessions" counts sittings. The first carries the day's
/// characters, time and bigrams; the others carry nothing but their day.
///
/// These runs are never stored. They exist for the length of a statistics
/// calculation and are not a profile's.
public func readingRuns(_ log: ReadingLog, calendar: Calendar) -> [RunResult] {
    var runs: [RunResult] = []
    var index = -1
    for day in log.days.keys.sorted() {
        guard let timestamp = noon(of: day, calendar: calendar), let books = log.days[day] else { continue }
        for book in books.keys.sorted() {
            let tally = books[book]!
            guard tally.sentences > 0 else { continue }
            for sitting in 0..<max(tally.sittings, 1) {
                let first = sitting == 0
                let minutes = tally.activeMs / msPerMinute
                let metrics = RunMetrics(
                    netWpm: first && minutes > 0 ? Double(tally.correctChars) / charsPerWord / minutes : 0,
                    rawWpm: first && minutes > 0 ? Double(tally.keystrokes) / charsPerWord / minutes : 0,
                    accuracy: first && tally.keystrokes > 0
                        ? Double(tally.keystrokes - tally.errors) / Double(tally.keystrokes) * 100 : 100,
                    consistency: 0, wpmStdDev: 0, wpmSeries: [],
                    correctChars: first ? tally.correctChars : 0,
                    incorrectChars: first ? tally.incorrectChars : 0,
                    durationMs: first ? tally.activeMs : 0)
                runs.append(
                    RunResult(
                        index: index, mode: .adaptive, timestamp: timestamp, passageId: "book:\(book)",
                        text: "", metrics: metrics, histogram: first ? tally.histogram : Histogram()))
                index -= 1
            }
        }
    }
    return runs
}

/// Practice and book typing together, for the statistics that count both.
public func combinedRuns(practice: [RunResult], reading: ReadingLog, calendar: Calendar) -> [RunResult] {
    practice + readingRuns(reading, calendar: calendar)
}

/// Minutes of book typing per local day, for the calendar's fourth metric.
/// Rounded up, so a day with any typing never draws as empty.
public func readingMinutesPerDay(_ log: ReadingLog) -> OrderedMap<Int> {
    var out = OrderedMap<Int>()
    for day in log.days.keys.sorted() {
        let ms = log.days[day]!.values.reduce(0) { $0 + $1.activeMs }
        if ms > 0 { out[day] = Int((ms / msPerMinute).rounded(.up)) }
    }
    return out
}

/// One book's totals over every day.
public struct BookTotals: Sendable, Equatable {
    public var activeMs: Double = 0
    public var sentences = 0
    public var correctChars = 0
    public var sentencesHeard = 0

    /// Net words per minute, or nil before any typing.
    public var wpm: Double? {
        activeMs > 0 ? Double(correctChars) / charsPerWord / (activeMs / msPerMinute) : nil
    }
}

public func bookTotals(_ log: ReadingLog, bookId: String) -> BookTotals {
    var totals = BookTotals()
    for (_, tally) in log.tallies(forBook: bookId) {
        totals.activeMs += tally.activeMs
        totals.sentences += tally.sentences
        totals.correctChars += tally.correctChars
        totals.sentencesHeard += tally.sentencesHeard
    }
    return totals
}

/// The child's speed over every book, for the import estimate. Nil before
/// the first sentence.
public func readingWpm(_ log: ReadingLog) -> Double? {
    var ms = 0.0
    var chars = 0
    for books in log.days.values {
        for tally in books.values {
            ms += tally.activeMs
            chars += tally.correctChars
        }
    }
    return ms > 0 ? Double(chars) / charsPerWord / (ms / msPerMinute) : nil
}

/// Typing speed in each chapter typed so far, in chapter order.
public func chapterSpeeds(_ log: ReadingLog, bookId: String) -> [(chapter: Int, wpm: Double)] {
    var totals: [Int: ChapterTally] = [:]
    for (_, tally) in log.tallies(forBook: bookId) {
        for (index, chapter) in tally.chapters {
            var sum = totals[index] ?? ChapterTally()
            sum.activeMs += chapter.activeMs
            sum.correctChars += chapter.correctChars
            totals[index] = sum
        }
    }
    return totals.keys.sorted().compactMap { index in
        let chapter = totals[index]!
        guard chapter.activeMs > 0 else { return nil }
        return (index, Double(chapter.correctChars) / charsPerWord / (chapter.activeMs / msPerMinute))
    }
}

/// Minutes of typing still ahead in a book at a given speed, or nil without one.
public func estimatedMinutesLeft(book: Book, from sentence: Int, wpm: Double?) -> Double? {
    guard let wpm, wpm > 0 else { return nil }
    let remaining = book.sentences.dropFirst(min(sentence, book.sentences.count))
        .reduce(0) { $0 + $1.utf16.count }
    return Double(remaining) / charsPerWord / wpm
}
