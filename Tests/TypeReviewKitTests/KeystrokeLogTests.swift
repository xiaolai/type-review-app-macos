import XCTest

@testable import TypeReviewKit

/// The keystroke log, which is read back from a file the app does not control.
final class KeystrokeLogTests: XCTestCase {
    func testAddingAccumulatesPerDayAndIgnoresNonPositiveCounts() {
        var log = KeystrokeLog()
        log.add(10, on: "2026-05-01")
        log.add(5, on: "2026-05-01")
        log.add(7, on: "2026-05-02")
        log.add(0, on: "2026-05-03")
        log.add(-4, on: "2026-05-03")

        XCTAssertEqual(log.days["2026-05-01"], 15)
        XCTAssertEqual(log.days["2026-05-02"], 7)
        XCTAssertNil(log.days["2026-05-03"], "a day with nothing to add should not appear")
        XCTAssertEqual(log.total, 22)
    }

    func testAddingSaturatesRatherThanTrapping() {
        var log = KeystrokeLog(days: ["2026-05-01": Int.max - 1])
        log.add(1_000, on: "2026-05-01")
        // The value is nonsense either way; the point is that a tampered file
        // cannot crash a background flush.
        XCTAssertGreaterThan(log.days["2026-05-01"] ?? 0, 0)
    }

    func testPruneKeepsTheNewestDays() {
        var log = KeystrokeLog()
        for day in 1...40 { log.add(day, on: String(format: "2026-05-%02d", day)) }
        log.prune(keeping: 10)

        XCTAssertEqual(log.days.count, 10)
        XCTAssertNil(log.days["2026-05-30"], "an older day should have gone")
        XCTAssertEqual(log.days["2026-05-31"], 31, "the newest days should remain")
        XCTAssertEqual(log.days["2026-05-40"], 40)
    }

    func testPruneDoesNothingWhenUnderTheLimit() {
        var log = KeystrokeLog(days: ["2026-05-01": 1, "2026-05-02": 2])
        log.prune(keeping: 10)
        XCTAssertEqual(log.days.count, 2)
    }

    func testDayKeyShapeIsCheckedExactly() {
        XCTAssertTrue(isKeystrokeDayKey("2026-05-01"))
        for bad in [
            "2026-5-01", "2026-05-1", "26-05-01", "2026-05-011", "2026/05/01", "2026-05-0a",
            "", "totals", "2026-05-01 ",
        ] {
            XCTAssertFalse(isKeystrokeDayKey(bad), bad)
        }
    }

    // MARK: - Reading a file the app did not write

    private func decode(_ json: String) throws -> KeystrokeLog {
        try decodeKeystrokeLog(Data(json.utf8))
    }

    func testARoundTripPreservesTheCounts() throws {
        var log = KeystrokeLog()
        log.add(120, on: "2026-05-01")
        log.add(3, on: "2026-05-02")
        let reloaded = try decodeKeystrokeLog(encodeKeystrokeLog(log))
        XCTAssertEqual(reloaded, log)
    }

    func testEntriesItCannotVouchForAreDroppedRatherThanFailingTheLoad() throws {
        let log = try decode(
            """
            {"2026-05-01": 10, "yesterday": 5, "2026-05-02": "many", "2026-05-03": -3,
             "2026-05-04": 2.5, "2026-05-05": null, "2026-05-06": 7}
            """)
        // The good days survive; nothing else does. Losing a year of counts to
        // one bad line would be the worse failure.
        XCTAssertEqual(log.days, ["2026-05-01": 10, "2026-05-06": 7])
    }

    func testAFractionalCountIsRejectedRatherThanTruncated() throws {
        // `as? Int` on an NSNumber holding 2.5 succeeds and yields 2, so this
        // fails only if the integer-ness is checked before the conversion.
        let log = try decode("{\"2026-05-01\": 2.5, \"2026-05-02\": 4.0}")
        XCTAssertNil(log.days["2026-05-01"])
        XCTAssertEqual(log.days["2026-05-02"], 4, "a whole number written as 4.0 is still whole")
    }

    func testAPayloadThatIsNotAnObjectThrows() {
        for json in ["[1,2,3]", "\"hello\"", "42", "", "{"] {
            XCTAssertThrowsError(try decode(json), json)
        }
    }

    func testAnOversizedFileIsPrunedRatherThanRejected() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        var cursor = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)) ?? Date()
        var oversized: [String: Int] = [:]
        for index in 0..<(maxKeystrokeDays + 50) {
            oversized[dayKey(cursor.timeIntervalSince1970 * 1000, calendar: calendar)] = index + 1
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }

        let log = try decodeKeystrokeLog(
            JSONSerialization.data(withJSONObject: oversized))

        XCTAssertEqual(log.days.count, maxKeystrokeDays)
        let sorted = oversized.keys.sorted()
        XCTAssertNil(log.days[sorted.first ?? ""], "the oldest day should have been pruned")
        XCTAssertNotNil(log.days[sorted.last ?? ""], "the newest day should survive")
    }

    func testCountsByDayComeOutChronological() {
        var log = KeystrokeLog()
        log.add(3, on: "2026-05-09")
        log.add(1, on: "2026-05-01")
        log.add(2, on: "2026-05-10")
        let counts = log.countsByDay()
        XCTAssertEqual(counts.keys, ["2026-05-01", "2026-05-09", "2026-05-10"])
        XCTAssertEqual(counts["2026-05-10"], 2)
    }
}
