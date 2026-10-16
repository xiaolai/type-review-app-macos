import XCTest

@testable import TypeReviewKit

/// The reading log, and how book typing is counted in the statistics without
/// entering the profile.
final class ReadingLogTests: XCTestCase {
    private func sentence(
        book: String = "b-1", chapter: Int = 0, correct: Int = 20, ms: Double = 10_000,
        histogram: Histogram = Histogram(), sitting: Bool = false
    ) -> SentenceRecord {
        let metrics = RunMetrics(
            netWpm: 0, rawWpm: 0, accuracy: 100, consistency: 0, wpmStdDev: 0, wpmSeries: [],
            correctChars: correct, incorrectChars: 1, durationMs: ms)
        return SentenceRecord(
            bookId: book, chapter: chapter, metrics: metrics, keystrokes: correct + 1, errors: 1,
            histogram: histogram, startsSitting: sitting)
    }

    private func histogram(_ pairs: [(String, Int, Double)]) -> Histogram {
        var out = Histogram()
        for (bigram, hits, ms) in pairs { out[bigram] = BigramHit(hitCount: hits, missCount: 0, timeToType: ms) }
        return out
    }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    func testRecordingAddsUpADay() {
        var log = ReadingLog()
        log.record(sentence(sitting: true), on: "2026-05-01")
        log.record(sentence(chapter: 1), on: "2026-05-01")
        log.recordHeard(bookId: "b-1", on: "2026-05-01")
        let tally = log.days["2026-05-01"]!["b-1"]!
        XCTAssertEqual(tally.sentences, 2)
        XCTAssertEqual(tally.correctChars, 40)
        XCTAssertEqual(tally.activeMs, 20_000)
        XCTAssertEqual(tally.sittings, 1)
        XCTAssertEqual(tally.sentencesHeard, 1)
        XCTAssertEqual(tally.chapters[1], ChapterTally(activeMs: 10_000, correctChars: 20))
    }

    func testHistogramsMergeWithHitWeightedTimes() {
        let merged = mergeHistogram(histogram([("ab", 1, 100)]), histogram([("ab", 3, 200), ("bc", 1, 50)]))
        XCTAssertEqual(merged["ab"], BigramHit(hitCount: 4, missCount: 0, timeToType: 175))
        XCTAssertEqual(merged["bc"]?.hitCount, 1)
    }

    func testTheLogRoundTrips() throws {
        var log = ReadingLog()
        log.record(sentence(histogram: histogram([("th", 2, 120)]), sitting: true), on: "2026-05-01")
        log.record(sentence(book: "b-2", chapter: 3), on: "2026-05-02")
        XCTAssertEqual(try decodeReadingLog(try encodeReadingLog(log)), log)
    }

    func testMalformedEntriesAreDroppedAndTheRestKept() throws {
        let good = try JSONSerialization.jsonObject(with: try encodeReadingLog({
            var log = ReadingLog()
            log.record(sentence(sitting: true), on: "2026-05-01")
            return log
        }())) as! [String: Any]
        var object = good
        object["not-a-day"] = ["b-1": good["2026-05-01"]!]
        object["2026-05-02"] = ["../x": (good["2026-05-01"] as! [String: Any])["b-1"]!, "b-3": ["sentences": -1]]
        let log = try decodeReadingLog(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(Set(log.days.keys), ["2026-05-01"])
        XCTAssertThrowsError(try decodeReadingLog(Data("[1]".utf8)))
    }

    func testADamagedLogCannotAskForRunsByTheMillion() throws {
        let good = try JSONSerialization.jsonObject(with: try encodeReadingLog({
            var log = ReadingLog()
            log.record(sentence(sitting: true), on: "2026-05-01")
            return log
        }())) as! [String: Any]
        var tally = (good["2026-05-01"] as! [String: Any])["b-1"] as! [String: Any]
        tally["sentences"] = 1_000_000_000_000
        tally["sittings"] = 1_000_000_000_000
        let object: [String: Any] = ["2026-05-01": ["b-1": tally]]
        let log = try decodeReadingLog(JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(log.isEmpty, "more sittings than a day can hold is a file this app did not write")
        XCTAssertLessThan(readingRuns(log, calendar: calendar("Europe/London")).count, 10)

        var many = ReadingLog()
        for _ in 0..<(maxReadingSittingsPerDay + 5) { many.record(sentence(sitting: true), on: "2026-05-02") }
        XCTAssertEqual(many.days["2026-05-02"]!["b-1"]!.sittings, maxReadingSittingsPerDay)
        XCTAssertEqual(try decodeReadingLog(try encodeReadingLog(many)), many, "a log this app wrote reads back")
    }

    func testTheSittingCeilingsHoldAcrossBooksAndDays() throws {
        let good = try JSONSerialization.jsonObject(with: try encodeReadingLog({
            var log = ReadingLog()
            log.record(sentence(sitting: true), on: "2026-05-01")
            return log
        }())) as! [String: Any]
        var tally = (good["2026-05-01"] as! [String: Any])["b-1"] as! [String: Any]
        tally["sentences"] = maxReadingSittingsPerDay
        tally["sittings"] = maxReadingSittingsPerDay
        var object: [String: Any] = ["2026-05-01": ["b-1": tally, "b-2": tally, "b-3": tally]]
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        for offset in 1...600 {
            object[formatter.string(from: start.addingTimeInterval(Double(offset) * 86_400))] = ["b-1": tally]
        }
        let log = try decodeReadingLog(JSONSerialization.data(withJSONObject: object))
        let perDay = log.days.values.map { sittingRuns($0).values.reduce(0, +) }
        XCTAssertLessThanOrEqual(perDay.max() ?? 0, maxReadingSittingsPerDay + 2, "one run more per extra book")
        XCTAssertLessThanOrEqual(perDay.reduce(0, +), maxReadingSittings)
        XCTAssertNotNil(log.days[formatter.string(from: start.addingTimeInterval(600 * 86_400))], "the newest are kept")
        XCTAssertLessThanOrEqual(readingRuns(log, calendar: calendar("Europe/London")).count, maxReadingSittings)
    }

    func testADayTheAppWroteReadsBackWhole() throws {
        var log = ReadingLog()
        for _ in 0..<maxReadingSittingsPerDay { log.record(sentence(sitting: true), on: "2026-05-02") }
        log.record(sentence(book: "b-2", sitting: true), on: "2026-05-02")
        XCTAssertEqual(try decodeReadingLog(try encodeReadingLog(log)), log, "the second book's totals survive")
        let runs = readingRuns(log, calendar: calendar("Europe/London"))
        XCTAssertEqual(runs.count, maxReadingSittingsPerDay + 1, "the first book's sittings, and one for the second")
    }

    func testDaysOfListeningOnlyAreBoundedToo() throws {
        var heard = ReadingLog()
        heard.recordHeard(bookId: "b-1", on: "2026-05-01")
        let tally = (try JSONSerialization.jsonObject(with: try encodeReadingLog(heard)) as! [String: Any])["2026-05-01"]!
        let start = Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        var object: [String: Any] = [:]
        for offset in 0..<(maxReadingSittings + 500) {
            object[formatter.string(from: start.addingTimeInterval(Double(offset) * 86_400))] = tally
        }
        let log = try decodeReadingLog(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(log.days.count, maxReadingSittings, "each day costs one, newest kept")
    }

    func testADayNamingTooManyBooksIsCut() throws {
        let good = try JSONSerialization.jsonObject(with: try encodeReadingLog({
            var log = ReadingLog()
            log.record(sentence(sitting: true), on: "2026-05-01")
            return log
        }())) as! [String: Any]
        let tally = (good["2026-05-01"] as! [String: Any])["b-1"] as! [String: Any]
        var row: [String: Any] = [:]
        for index in 0..<(maxReadingBooksPerDay * 3) { row["b-\(index)"] = tally }
        let log = try decodeReadingLog(JSONSerialization.data(withJSONObject: ["2026-05-01": row]))
        XCTAssertEqual(log.days["2026-05-01"]?.count, maxReadingBooksPerDay)
    }

    func testALongLightHistoryIsKeptWhole() throws {
        var log = ReadingLog()
        let start = Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        for offset in 0..<5_000 {
            log.record(sentence(sitting: true), on: formatter.string(from: start.addingTimeInterval(Double(offset) * 86_400)))
        }
        XCTAssertEqual(try decodeReadingLog(try encodeReadingLog(log)).days.count, 5_000, "over thirteen years, one a day")
    }

    func testOnlyRealDatesAreKept() throws {
        XCTAssertTrue(isCalendarDayKey("2024-02-29"))
        for bad in ["2026-02-31", "2026-13-01", "2026-00-10", "0000-01-01", "2026-2-1"] {
            XCTAssertFalse(isCalendarDayKey(bad), bad)
        }
        let good = try JSONSerialization.jsonObject(with: try encodeReadingLog({
            var log = ReadingLog()
            log.record(sentence(sitting: true), on: "2026-05-01")
            return log
        }())) as! [String: Any]
        let object: [String: Any] = ["2026-02-31": good["2026-05-01"]!, "2026-05-01": good["2026-05-01"]!]
        XCTAssertEqual(Set(try decodeReadingLog(JSONSerialization.data(withJSONObject: object)).days.keys), ["2026-05-01"])
    }

    func testOldDaysKeepTheirTotalsButNotTheirBigrams() {
        var log = ReadingLog()
        for day in 1...5 {
            log.record(
                sentence(histogram: histogram([("ab", 1, 100)]), sitting: true), on: String(format: "2026-05-%02d", day))
        }
        log.pruneHistograms(keeping: 2)
        XCTAssertTrue(log.days["2026-05-01"]!["b-1"]!.histogram.isEmpty)
        XCTAssertEqual(log.days["2026-05-01"]!["b-1"]!.sentences, 1, "totals stay for the streak")
        XCTAssertFalse(log.days["2026-05-05"]!["b-1"]!.histogram.isEmpty)
    }

    func testRemovingABookForgetsIt() {
        var log = ReadingLog()
        log.record(sentence(book: "b-1"), on: "2026-05-01")
        log.record(sentence(book: "b-2"), on: "2026-05-01")
        log.record(sentence(book: "b-1"), on: "2026-05-02")
        log.remove(bookId: "b-1")
        XCTAssertEqual(Set(log.days.keys), ["2026-05-01"])
        XCTAssertEqual(Set(log.days["2026-05-01"]!.keys), ["b-2"])
    }

    // MARK: - Counting in the statistics

    func testADayWithOnlyBookTypingExtendsTheStreak() {
        let cal = calendar("Europe/London")
        var log = ReadingLog()
        log.record(sentence(sitting: true), on: "2026-05-02")
        log.record(sentence(sitting: true), on: "2026-05-03")
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 3, hour: 20))!.timeIntervalSince1970 * 1000
        let runs = combinedRuns(practice: [], reading: log, calendar: cal)
        XCTAssertEqual(streak(runs, now: now, calendar: cal), StreakStat(current: 2, longest: 2))
    }

    func testSittingsCountAsSessionsAndCharactersAddUp() {
        let cal = calendar("Europe/London")
        var log = ReadingLog()
        log.record(sentence(correct: 30, sitting: true), on: "2026-05-02")
        log.record(sentence(correct: 30, sitting: true), on: "2026-05-02")
        log.record(sentence(correct: 30), on: "2026-05-02")
        let runs = readingRuns(log, calendar: cal)
        XCTAssertEqual(dailyCounts(runs, calendar: cal)["2026-05-02"], 2, "two sittings")
        XCTAssertEqual(charactersPerDay(runs, calendar: cal)["2026-05-02"], 93, "90 correct and 3 wrong")
    }

    func testBookBigramsAddIntoTheKeyTable() {
        let cal = calendar("Europe/London")
        var log = ReadingLog()
        log.record(sentence(histogram: histogram([("th", 4, 150)]), sitting: true), on: "2026-05-02")
        let perKey = aggregatePerKey(combinedRuns(practice: [], reading: log, calendar: cal))
        XCTAssertEqual(perKey["h"]?.hits, 4)
        XCTAssertEqual(perKey["h"]?.avgMs, 150)
    }

    func testDaysLandOnTheirDateAcrossDaylightSavingChanges() {
        // New York changes its clocks on these two days in 2026. A timestamp
        // at midnight would land on the wrong date in one of them; noon lands
        // right in both.
        let cal = calendar("America/New_York")
        var log = ReadingLog()
        for day in ["2026-03-08", "2026-11-01", "2026-11-02"] { log.record(sentence(sitting: true), on: day) }
        let days = Set(readingRuns(log, calendar: cal).map { dayKey($0.timestamp, calendar: cal) })
        XCTAssertEqual(days, ["2026-03-08", "2026-11-01", "2026-11-02"])
    }

    func testSentencesEitherSideOfMidnightAreTwoDays() {
        let cal = calendar("America/New_York")
        let before = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 59))!
        let after = before.addingTimeInterval(120)
        var log = ReadingLog()
        log.record(sentence(sitting: true), on: dayKey(before.timeIntervalSince1970 * 1000, calendar: cal))
        log.record(sentence(), on: dayKey(after.timeIntervalSince1970 * 1000, calendar: cal))
        XCTAssertEqual(log.days.keys.sorted(), ["2026-11-01", "2026-11-02"])
        XCTAssertEqual(readingMinutesPerDay(log)["2026-11-01"], 1)
        XCTAssertEqual(readingMinutesPerDay(log)["2026-11-02"], 1)
    }

    func testTotalsSpeedsAndEstimates() {
        var log = ReadingLog()
        // 100 correct characters in one minute is 20 wpm.
        log.record(sentence(chapter: 0, correct: 100, ms: 60_000, sitting: true), on: "2026-05-01")
        log.record(sentence(chapter: 1, correct: 50, ms: 60_000), on: "2026-05-02")
        let totals = bookTotals(log, bookId: "b-1")
        XCTAssertEqual(totals.sentences, 2)
        XCTAssertEqual(totals.wpm, 15)
        XCTAssertEqual(readingWpm(log), 15)
        let speeds = chapterSpeeds(log, bookId: "b-1")
        XCTAssertEqual(speeds.map(\.chapter), [0, 1])
        XCTAssertEqual(speeds.map(\.wpm), [20, 10])

        // 150 characters over two sentences is 75 a sentence, at 15 wpm: four
        // more sentences are 300 characters, 60 words, four minutes.
        XCTAssertEqual(estimatedMinutesLeft(sentencesLeft: 4, totals: totals), 4)
        XCTAssertNil(estimatedMinutesLeft(sentencesLeft: 4, totals: BookTotals()))
    }
}
