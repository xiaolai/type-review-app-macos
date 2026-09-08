import XCTest

@testable import TypeReviewKit

/// The practice calendar's grid model.
///
/// The intensity curve is the part worth pinning: it is the difference between
/// a grid that shows a quiet fortnight and one that reports it as no practice
/// at all, and it is invisible in any screenshot taken on a week with even
/// usage.
final class PracticeCalendarTests: XCTestCase {
    /// A fixed-offset calendar. The statistics calendar is the machine's, and
    /// a test that inherits it passes or fails depending on where it runs.
    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    /// Midnight UTC on 2026-03-15, in milliseconds.
    private let anchor: Double = 1_773_532_800_000

    private func run(
        daysBack: Int, calendar: Calendar, index: Int = 0, correct: Int = 30,
        incorrect: Int = 1
    ) -> RunResult {
        let key = dayKeyBack(anchor, daysBack, calendar: calendar)
        let parts = key.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
        // Midday, so a timestamp cannot drift across a day boundary through
        // rounding and quietly land the run on the day next door.
        components.hour = 12
        let date = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        return RunResult(
            index: index, mode: .benchmark, timestamp: date.timeIntervalSince1970 * 1000,
            passageId: "p\(index)", text: "the quick brown fox",
            metrics: RunMetrics(
                netWpm: 60, rawWpm: 62, accuracy: 97, consistency: 80, wpmStdDev: 4,
                wpmSeries: [60], correctChars: correct, incorrectChars: incorrect,
                durationMs: 30_000),
            histogram: Histogram())
    }

    func testTheWindowIsTheRequestedLengthOldestFirstAndEndsToday() {
        let calendar = utc()
        let grid = practiceCalendar([], now: anchor, days: 60, calendar: calendar)

        XCTAssertEqual(grid.count, 60)
        XCTAssertEqual(grid.first?.key, dayKeyBack(anchor, 59, calendar: calendar))
        XCTAssertEqual(grid.last?.key, dayKey(anchor, calendar: calendar))
        XCTAssertEqual(grid.map(\.key), grid.map(\.key).sorted(), "days should run oldest first")
        XCTAssertEqual(grid.filter(\.isToday).count, 1, "exactly one cell is today")
        XCTAssertEqual(grid.last?.isToday, true)
    }

    func testAnEmptyHistoryIsSixtyEmptyDaysRatherThanNothing() {
        let grid = practiceCalendar([], now: anchor, days: 60, calendar: utc())
        XCTAssertEqual(grid.count, 60)
        XCTAssertTrue(grid.allSatisfy { $0.count == 0 && $0.intensity == 0 })
    }

    func testIntensityFloorsAtAQuarterSoOneSessionIsVisible() {
        let calendar = utc()
        // Twenty sessions today, one a week ago. Scaled linearly the quiet day
        // would draw at 5%, which reads as an empty cell.
        var results = (0..<20).map { run(daysBack: 0, calendar: calendar, index: $0) }
        results.append(run(daysBack: 7, calendar: calendar, index: 99))

        let grid = practiceCalendar(results, now: anchor, days: 60, calendar: calendar)
        let quiet = grid.first { $0.key == dayKeyBack(anchor, 7, calendar: calendar) }
        let busy = grid.first { $0.isToday }

        XCTAssertEqual(quiet?.count, 1)
        XCTAssertEqual(quiet?.intensity ?? 0, 0.25 + (1.0 / 20.0) * 0.75, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(quiet?.intensity ?? 0, 0.25)
        XCTAssertEqual(busy?.intensity ?? 0, 1.0, accuracy: 1e-12, "the busiest day saturates")
    }

    func testTheScaleIgnoresDaysOutsideTheWindow() {
        let calendar = utc()
        // A huge day well outside a 30-day window, and a modest one inside it.
        var results = (0..<50).map { run(daysBack: 200, calendar: calendar, index: $0) }
        results.append(run(daysBack: 3, calendar: calendar, index: 99))

        let grid = practiceCalendar(results, now: anchor, days: 30, calendar: calendar)
        let visible = grid.first { $0.key == dayKeyBack(anchor, 3, calendar: calendar) }

        // Scaled against the invisible 50-session day this would be 0.265 and
        // read as almost nothing; scoped to the window it is the maximum.
        XCTAssertEqual(visible?.intensity ?? 0, 1.0, accuracy: 1e-12)
        XCTAssertFalse(
            grid.contains { $0.key == dayKeyBack(anchor, 200, calendar: calendar) },
            "a day outside the window should not be a cell")
    }

    func testSessionsOnOneDayAreCounted() {
        let calendar = utc()
        let results = (0..<3).map { run(daysBack: 2, calendar: calendar, index: $0) }
        let grid = practiceCalendar(results, now: anchor, days: 60, calendar: calendar)
        XCTAssertEqual(grid.first { $0.key == dayKeyBack(anchor, 2, calendar: calendar) }?.count, 3)
        XCTAssertEqual(grid.reduce(0) { $0 + $1.count }, 3, "no run counted twice")
    }

    func testTheWindowHoldsDistinctDaysAcrossADaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // 00:30, four days after the US spring-forward on 2026-03-08 — and the
        // half-hour matters. Subtracting 86,400,000 ms four times from 00:30
        // EDT lands at 23:30 EST on the day *before* the intended one, so the
        // window skips 2026-03-08 entirely and reaches a day further back than
        // asked. Anchored at midday the same arithmetic is indistinguishable
        // from the calendar's, because a one-hour shift never crosses
        // midnight — which is why this test is written at 00:30 and would be
        // worthless at noon.
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 3, 12)
        (components.hour, components.minute) = (0, 30)
        let date = try XCTUnwrap(calendar.date(from: components))
        let now = date.timeIntervalSince1970 * 1000

        let grid = practiceCalendar([], now: now, days: 10, calendar: calendar)
        XCTAssertEqual(Set(grid.map(\.key)).count, 10, "every cell should be a distinct date")
        XCTAssertEqual(grid.map(\.key), grid.map(\.key).sorted())
        XCTAssertEqual(grid.map(\.key).first, "2026-03-03", "the window should span exactly 10 days")
        XCTAssertTrue(
            grid.map(\.key).contains("2026-03-08"),
            "the spring-forward day is missing — the window walked in fixed 24h steps")
    }

    func testAZeroLengthWindowIsEmptyRatherThanACrash() {
        XCTAssertTrue(practiceCalendar([], now: anchor, days: 0, calendar: utc()).isEmpty)
    }

    // MARK: - Characters

    func testCharactersPerDaySumsCorrectAndIncorrectAcrossRuns() {
        let calendar = utc()
        let results = [
            run(daysBack: 1, calendar: calendar, index: 0, correct: 100, incorrect: 5),
            run(daysBack: 1, calendar: calendar, index: 1, correct: 200, incorrect: 10),
            run(daysBack: 4, calendar: calendar, index: 2, correct: 50, incorrect: 0),
        ]
        let counts = charactersPerDay(results, calendar: calendar)
        XCTAssertEqual(counts[dayKeyBack(anchor, 1, calendar: calendar)], 315)
        XCTAssertEqual(counts[dayKeyBack(anchor, 4, calendar: calendar)], 50)
        // Mistyped characters count as typed. They were pressed, and a day
        // spent fighting a hard passage is not a day of less practice.
        XCTAssertNotEqual(counts[dayKeyBack(anchor, 1, calendar: calendar)], 300)
    }

    func testCharactersAndSessionsRankDaysDifferently() {
        let calendar = utc()
        // Three short runs one day, one long run another. By sessions the
        // first day wins 3-1; by characters the second wins 600-90. A grid
        // that showed the same shape for both would mean the metric switch
        // does nothing.
        var results = (0..<3).map {
            run(daysBack: 5, calendar: calendar, index: $0, correct: 30, incorrect: 0)
        }
        results.append(run(daysBack: 2, calendar: calendar, index: 9, correct: 600, incorrect: 0))

        let bySession = practiceCalendar(results, now: anchor, days: 10, calendar: calendar)
        let byCharacter = practiceCalendar(
            countsByDay: charactersPerDay(results, calendar: calendar), now: anchor, days: 10,
            calendar: calendar)

        let busyDay = dayKeyBack(anchor, 5, calendar: calendar)
        let longDay = dayKeyBack(anchor, 2, calendar: calendar)

        XCTAssertEqual(bySession.first { $0.key == busyDay }?.intensity ?? 0, 1.0, accuracy: 1e-12)
        XCTAssertLessThan(
            bySession.first { $0.key == longDay }?.intensity ?? 0,
            bySession.first { $0.key == busyDay }?.intensity ?? 0)

        XCTAssertEqual(
            byCharacter.first { $0.key == longDay }?.intensity ?? 0, 1.0, accuracy: 1e-12)
        XCTAssertLessThan(
            byCharacter.first { $0.key == busyDay }?.intensity ?? 0,
            byCharacter.first { $0.key == longDay }?.intensity ?? 0)
    }

    func testTheSharedGridAppliesTheSameRulesToACountsMap() {
        let calendar = utc()
        var counts = OrderedMap<Int>()
        counts[dayKey(anchor, calendar: calendar)] = 1_000
        counts[dayKeyBack(anchor, 3, calendar: calendar)] = 1

        let grid = practiceCalendar(
            countsByDay: counts, now: anchor, days: 30, calendar: calendar)

        XCTAssertEqual(grid.count, 30)
        // The visibility floor has to reach the counts entry point too — one
        // character against a thousand is 0.1% and would draw as unpractised.
        let quiet = grid.first { $0.key == dayKeyBack(anchor, 3, calendar: calendar) }
        XCTAssertGreaterThanOrEqual(quiet?.intensity ?? 0, 0.25)
        XCTAssertEqual(grid.first { $0.isToday }?.intensity ?? 0, 1.0, accuracy: 1e-12)
    }
}
