import XCTest

@testable import TypeReviewKit

/// Statistics against the website, in two timezones.
///
/// Day-level statistics are the one part of the engine whose answer depends on
/// where the machine is. So each vector records the timezone it was generated
/// under and the test reproduces it — including one zone with daylight saving,
/// where a "day" is 23 or 25 hours twice a year and subtracting fixed
/// milliseconds lands on the wrong date.
final class AggregationVectorTests: XCTestCase {
    struct Vector: Decodable {
        struct DayKey: Decodable {
            let timestamp: Double
            let key: String
        }
        struct DayBack: Decodable {
            let anchor: Double
            let daysBack: Int
            let key: String
        }
        struct Streak: Decodable {
            let name: String
            let timestamps: [Double]
            let now: Double
            let current: Int
            let longest: Int
        }
        struct DailyCount: Decodable {
            let key: String
            let count: Int
        }
        struct PerKey: Decodable {
            let key: String
            let hits: Int
            let misses: Int
            let avgMs: Double
            let errorRate: Double
        }
        struct Slow: Decodable {
            let bigram: String
            let hits: Int
            let misses: Int
            let avgMs: Double
        }
        struct Hit: Decodable {
            let hitCount: Int
            let missCount: Int
            let timeToType: Double
        }
        let timeZone: String
        let dayKeys: [DayKey]
        let dayKeyBack: [DayBack]
        let streaks: [Streak]
        let dailyCounts: [DailyCount]
        let perKey: [PerKey]
        let perFinger: [FingerRow]
        let slowestBigrams: [Slow]
        let histograms: [[String: Hit]]
        let runTimestamps: [Double]
    }

    private func vector(_ name: String) throws -> (Vector, Calendar) {
        guard let url = Bundle.module.url(forResource: "Vectors/\(name)", withExtension: "json")
        else { throw VectorUnavailable(reason: "Vectors/\(name).json missing") }
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        guard let zone = TimeZone(identifier: vector.timeZone) else {
            // Also not a skip. The vector names an IANA zone that every macOS
            // carries; failing to resolve it means the vector is wrong or the
            // system is, and both deserve to be seen rather than stepped over.
            throw VectorUnavailable(reason: "unknown timezone \(vector.timeZone)")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return (vector, calendar)
    }

    /// Both files, so every assertion runs under a DST zone as well as a
    /// fixed-offset one.
    private func eachVector(_ body: (Vector, Calendar, String) throws -> Void) throws {
        for name in ["aggregations", "aggregations-dst"] {
            let (vector, calendar) = try vector(name)
            try body(vector, calendar, name)
        }
    }

    private func runs(_ vector: Vector) -> [RunResult] {
        // Paired by position, so a fixture with more histograms than
        // timestamps would trap here rather than say what was wrong with it,
        // and a fixture with more timestamps would drop them in silence.
        // Asserted *and* paired safely. `XCTAssertEqual` records a failure and
        // keeps going, so on its own it would have reported the mismatch and
        // then trapped on the very indexing it was warning about — the report
        // buried under a crash. `zip` stops at the shorter of the two.
        XCTAssertEqual(
            vector.histograms.count, vector.runTimestamps.count,
            "vector has \(vector.histograms.count) histograms and "
                + "\(vector.runTimestamps.count) timestamps")
        let metrics = RunMetrics(
            netWpm: 50, rawWpm: 52, accuracy: 96, consistency: 90, wpmStdDev: 3, wpmSeries: [50],
            correctChars: 10, incorrectChars: 1, durationMs: 12_000)
        return zip(vector.histograms, vector.runTimestamps).enumerated().map { index, pair in
            let (raw, timestamp) = pair
            var histogram = Histogram()
            // Insertion order follows the vector's own JSON ordering, which is
            // what the weighted sums and the tie-break below depend on.
            for key in raw.keys.sorted(by: { orderIndex(of: $0) < orderIndex(of: $1) }) {
                let hit = raw[key]!
                histogram[key] = BigramHit(
                    hitCount: hit.hitCount, missCount: hit.missCount, timeToType: hit.timeToType)
            }
            return RunResult(
                index: index, mode: .benchmark, timestamp: timestamp,
                passageId: "p", text: "sample", metrics: metrics, histogram: histogram)
        }
    }

    /// The emitter writes bigrams in first-appearance order; these fixtures are
    /// small and fixed, so the order is spelled out rather than parsed.
    private func orderIndex(of bigram: String) -> Int {
        ["th": 0, "he": 1, "er": 2][bigram] ?? 99
    }

    func testDayKeysMatchInEveryTimezone() throws {
        try eachVector { vector, calendar, name in
            for testCase in vector.dayKeys {
                XCTAssertEqual(
                    dayKey(testCase.timestamp, calendar: calendar), testCase.key,
                    "\(name): \(testCase.timestamp)")
            }
        }
    }

    func testDayArithmeticSurvivesDaylightSaving() throws {
        try eachVector { vector, calendar, name in
            for testCase in vector.dayKeyBack {
                XCTAssertEqual(
                    dayKeyBack(testCase.anchor, testCase.daysBack, calendar: calendar),
                    testCase.key, "\(name): \(testCase.daysBack) days back")
            }
        }
    }

    func testStreaksMatch() throws {
        try eachVector { vector, calendar, name in
            let metrics = RunMetrics(
                netWpm: 0, rawWpm: 0, accuracy: 100, consistency: 0, wpmStdDev: 0, wpmSeries: [],
                correctChars: 0, incorrectChars: 0, durationMs: 0)
            for testCase in vector.streaks {
                let results = testCase.timestamps.enumerated().map { index, timestamp in
                    RunResult(
                        index: index, mode: .benchmark, timestamp: timestamp, passageId: "p",
                        text: "t", metrics: metrics, histogram: Histogram())
                }
                let actual = streak(results, now: testCase.now, calendar: calendar)
                XCTAssertEqual(
                    actual.current, testCase.current, "\(name): current — \(testCase.name)")
                XCTAssertEqual(
                    actual.longest, testCase.longest, "\(name): longest — \(testCase.name)")
            }
        }
    }

    struct FingerRow: Decodable {
        let finger: String
        let hits: Int
        let avgMs: Double
        let errorRate: Double
    }

    /// The website's own output over the same histograms, recorded by running
    /// its `aggregatePerFinger` — not values worked out by hand here, which
    /// would only pin this port to whatever this port already believes.
    func testPerFingerMatches() throws {
        try eachVector { vector, _, name in
            let actual = aggregatePerFinger(aggregatePerKey(runs(vector)))
            XCTAssertEqual(
                actual.count, vector.perFinger.count, "\(name): number of fingers reported")
            for (actual, expected) in zip(actual, vector.perFinger) {
                XCTAssertEqual(
                    actual.finger.rawValue, expected.finger, "\(name): order and identity")
                XCTAssertEqual(actual.hits, expected.hits, "\(name) hits \(expected.finger)")
                XCTAssertEqual(actual.avgMs, expected.avgMs, "\(name) avgMs \(expected.finger)")
                XCTAssertEqual(
                    actual.errorRate, expected.errorRate, "\(name) errorRate \(expected.finger)")
            }
        }
    }

    func testPerKeyAndSlowestBigramsMatch() throws {
        try eachVector { vector, _, name in
            let results = runs(vector)
            let perKey = aggregatePerKey(results)
            // The count as well as the contents. Walking only the expected
            // entries meant a key this side invented — or one it should have
            // dropped and did not — passed unnoticed, which is the half of
            // conformance that checking values cannot reach.
            XCTAssertEqual(perKey.keys.count, vector.perKey.count, "\(name): number of keys")
            for expected in vector.perKey {
                let actual = try XCTUnwrap(perKey[expected.key], "\(name): \(expected.key)")
                XCTAssertEqual(actual.hits, expected.hits, "\(name) hits \(expected.key)")
                XCTAssertEqual(actual.misses, expected.misses, "\(name) misses \(expected.key)")
                XCTAssertEqual(actual.avgMs, expected.avgMs, "\(name) avgMs \(expected.key)")
                XCTAssertEqual(
                    actual.errorRate, expected.errorRate, "\(name) errorRate \(expected.key)")
            }

            let slow = slowestBigrams(results, count: 5, minHits: 5)
            XCTAssertEqual(
                slow.map(\.bigram), vector.slowestBigrams.map(\.bigram), "\(name): slowest order")
            XCTAssertEqual(slow.map(\.avgMs), vector.slowestBigrams.map(\.avgMs), name)
            // Decoded from the vector and, until now, never compared. Two
            // fields the website emits that this side was free to get wrong.
            XCTAssertEqual(slow.map(\.hits), vector.slowestBigrams.map(\.hits), "\(name): hits")
            XCTAssertEqual(
                slow.map(\.misses), vector.slowestBigrams.map(\.misses), "\(name): misses")
        }
    }

    func testDailyCountsMatch() throws {
        try eachVector { vector, calendar, name in
            let counts = dailyCounts(runs(vector), calendar: calendar)
            XCTAssertEqual(counts.count, vector.dailyCounts.count, "\(name): number of days")
            for expected in vector.dailyCounts {
                XCTAssertEqual(counts[expected.key], expected.count, "\(name): \(expected.key)")
            }
        }
    }
}
