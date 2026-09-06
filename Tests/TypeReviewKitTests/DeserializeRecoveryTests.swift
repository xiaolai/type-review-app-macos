import XCTest

@testable import TypeReviewKit

/// Round-trip failures the golden vectors cannot see.
///
/// The vectors pin the *verdict* for a fixed set of payloads, which is the
/// right contract for agreeing with the TypeScript engine. None of them holds
/// more than a handful of runs, and none contains a bigram whose key needs
/// escaping — so all three bugs below round-tripped a profile that was quietly
/// missing data, and every existing assertion still passed.
final class DeserializeRecoveryTests: XCTestCase {
    private func metrics() -> RunMetrics {
        RunMetrics(
            netWpm: 60, rawWpm: 62, accuracy: 97, consistency: 80, wpmStdDev: 4,
            wpmSeries: [60, 62], correctChars: 30, incorrectChars: 1, durationMs: 30_000)
    }

    private func result(index: Int, histogram: Histogram) -> RunResult {
        RunResult(
            index: index, mode: .benchmark, timestamp: 1_700_000_000_000 + Double(index),
            passageId: "p\(index)", text: "the quick brown fox", metrics: metrics(),
            histogram: histogram)
    }

    private func histogram(_ pairs: [(String, Int)]) -> Histogram {
        var histogram = Histogram()
        for (bigram, hits) in pairs {
            histogram[bigram] = BigramHit(hitCount: hits, missCount: 0, timeToType: 120)
        }
        return histogram
    }

    /// Key order is recovered from the raw text, and capping drops runs from
    /// the front. Reading the orders from index zero paired each retained run
    /// with a discarded run's keys, and `parseHistogram` — which skips a key
    /// the run does not have — then returned a histogram missing most of its
    /// entries, with nothing reported.
    func testCappedHistoryKeepsEachRetainedRunsOwnHistogram() throws {
        let overflow = maxResults + 2
        let results = (0..<overflow).map { index in
            // A key unique to this run, so a histogram borrowed from any other
            // run comes back empty rather than merely reordered.
            result(index: index, histogram: histogram([("k\(index % 9)", index % 7 + 1), ("th", 3)]))
        }
        let json = serializeProfileString(Profile(results: results))

        guard case .ok(let loaded) = deserializeProfile(json) else {
            return XCTFail("a profile of \(overflow) runs should load")
        }
        XCTAssertEqual(loaded.results.count, maxResults)
        for run in loaded.results {
            XCTAssertEqual(
                run.histogram.count, 2,
                "run \(run.index) lost histogram entries to another run's key order")
            XCTAssertEqual(run.histogram["th"]?.hitCount, 3, "run \(run.index)")
        }
    }

    /// `"` is in the punctuation alphabet, so a bigram key containing one is
    /// ordinary data. Recovering the key by searching backwards for the nearest
    /// quote landed inside the `\"` escape and produced the key `"`, which no
    /// histogram contains — so the entry was dropped on every load.
    func testBigramKeysNeedingEscapesSurviveARoundTrip() throws {
        let awkward = ["a\"", "\\b", "c\n", "d\t"]
        var pairs = awkward.enumerated().map { ($0.element, $0.offset + 1) }
        pairs.append(("th", 9))
        let json = serializeProfileString(
            Profile(results: [result(index: 0, histogram: histogram(pairs))]))

        guard case .ok(let loaded) = deserializeProfile(json),
            let run = loaded.results.first
        else { return XCTFail("the profile should load") }

        XCTAssertEqual(run.histogram.count, pairs.count)
        for (bigram, hits) in pairs {
            XCTAssertEqual(
                run.histogram[bigram]?.hitCount, hits,
                "bigram \(bigram.debugDescription) did not survive")
        }
        // Order is part of the format, so it must survive too.
        XCTAssertEqual(run.histogram.keys, pairs.map(\.0))
    }

    /// A finite integral version far outside `Int`'s range reached
    /// `Int(version)`, and that conversion traps: opening a tampered profile
    /// crashed the app instead of reporting corruption.
    func testAnAbsurdVersionIsCorruptRatherThanFatal() {
        for version in ["1e300", "-1e300", "9007199254740993"] {
            let json = """
                {"version":\(version),"settings":{"mode":"benchmark","targetWpm":50,\
                "adaptive":{"minAlphabetSize":6,"alphabetExpansion":0},"wordCount":30,\
                "testMode":"words","testDurationSec":30,"stopOnError":false,\
                "noBackspace":false,"passageLength":"any","includeNumbers":false,\
                "includePunctuation":false},"results":[]}
                """
            XCTAssertEqual(deserializeProfile(json).statusName, "corrupt", version)
        }
    }

    /// A v1 payload whose `results` is not an array is corrupt. Substituting an
    /// empty array during migration accepted it and discarded the history.
    func testMigrationDoesNotInventAnEmptyHistory() {
        let json = """
            {"version":1,"settings":{"mode":"benchmark","targetWpm":50,\
            "adaptive":{"minAlphabetSize":6,"alphabetExpansion":0},"wordCount":30,\
            "testMode":"words","testDurationSec":30,"stopOnError":false,\
            "noBackspace":false,"passageLength":"any","includeNumbers":false,\
            "includePunctuation":false},"results":"not an array"}
            """
        XCTAssertEqual(deserializeProfile(json).statusName, "corrupt")
    }

    /// Counts are whole numbers. `inRange` accepted a fractional one and
    /// `Int(_:)` then truncated it, so a tampered 5.9 loaded as 5.
    func testFractionalCharacterCountsAreRejected() {
        let json = """
            {"version":2,"settings":{"mode":"benchmark","targetWpm":50,\
            "adaptive":{"minAlphabetSize":6,"alphabetExpansion":0},"wordCount":30,\
            "testMode":"words","testDurationSec":30,"stopOnError":false,\
            "noBackspace":false,"passageLength":"any","includeNumbers":false,\
            "includePunctuation":false},"results":[{"index":0,"mode":"benchmark",\
            "timestamp":1700000000000,"passageId":"p","text":"the","metrics":\
            {"netWpm":60,"rawWpm":62,"accuracy":97,"consistency":80,"wpmStdDev":4,\
            "wpmSeries":[],"correctChars":5.9,"incorrectChars":0,"durationMs":30000},\
            "histogram":{}}]}
            """
        XCTAssertEqual(deserializeProfile(json).statusName, "corrupt")
    }

    /// `Double.description` renders a non-finite value `nan`/`inf`, neither of
    /// which is JSON. `JSON.stringify` writes `null`, and so must this — a
    /// profile that cannot be re-read is a profile that has been lost.
    func testNonFiniteNumbersSerializeAsNull() {
        let json = JSONWriter.stringify(
            .object([
                ("nan", .number(.nan)),
                ("inf", .number(.infinity)),
                ("negInf", .number(-.infinity)),
            ]))
        XCTAssertEqual(json, #"{"nan":null,"inf":null,"negInf":null}"#)
        XCTAssertNotNil(
            try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            "the writer must never emit text that is not JSON")
    }
}
