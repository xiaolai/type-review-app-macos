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
        let slowestBigrams: [Slow]
        let histograms: [[String: Hit]]
        let runTimestamps: [Double]
    }

    private func vector(_ name: String) throws -> (Vector, Calendar) {
        guard let url = Bundle.module.url(forResource: "Vectors/\(name)", withExtension: "json")
        else { throw XCTSkip("Vectors/\(name).json missing — run `pnpm emit:vectors`") }
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        guard let zone = TimeZone(identifier: vector.timeZone) else {
            throw XCTSkip("unknown timezone \(vector.timeZone)")
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
        let metrics = RunMetrics(
            netWpm: 50, rawWpm: 52, accuracy: 96, consistency: 90, wpmStdDev: 3, wpmSeries: [50],
            correctChars: 10, incorrectChars: 1, durationMs: 12_000)
        return vector.histograms.enumerated().map { index, raw in
            var histogram = Histogram()
            // Insertion order follows the vector's own JSON ordering, which is
            // what the weighted sums and the tie-break below depend on.
            for key in raw.keys.sorted(by: { orderIndex(of: $0) < orderIndex(of: $1) }) {
                let hit = raw[key]!
                histogram[key] = BigramHit(
                    hitCount: hit.hitCount, missCount: hit.missCount, timeToType: hit.timeToType)
            }
            return RunResult(
                index: index, mode: .benchmark, timestamp: vector.runTimestamps[index],
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

    func testPerKeyAndSlowestBigramsMatch() throws {
        try eachVector { vector, _, name in
            let results = runs(vector)
            let perKey = aggregatePerKey(results)
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
        }
    }

    func testDailyCountsMatch() throws {
        try eachVector { vector, calendar, name in
            let counts = dailyCounts(runs(vector), calendar: calendar)
            for expected in vector.dailyCounts {
                XCTAssertEqual(counts[expected.key], expected.count, "\(name): \(expected.key)")
            }
        }
    }
}
