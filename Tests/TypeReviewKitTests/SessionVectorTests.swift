import XCTest

@testable import TypeReviewKit

/// `Session` end to end against the TypeScript engine.
///
/// This is the test that exercises everything at once: the planner picks an
/// alphabet from history, the generator draws words from a shared RNG stream,
/// the typing loop records steps, the histogram feeds the next plan, and the
/// whole thing serializes. A divergence anywhere shows up here as different
/// words on screen.
final class SessionVectorTests: XCTestCase {
    private func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        guard let url = Bundle.module.url(forResource: "Vectors/\(name)", withExtension: "json")
        else { throw XCTSkip("Vectors/\(name).json missing — run `pnpm emit:vectors`") }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    struct PlannerVector: Decodable {
        struct Run: Decodable {
            let run: Int
            /// Each run is typed at a different cadence, so the per-bigram
            /// EMA — and therefore the unlock progression — depends on history
            /// being replayed oldest-first.
            let interval: Double
            let text: String
            let included: [String]?
            let focus: String?
        }
        struct KeyStat: Decodable {
            let letter: String
            let hitCount: Int
            let missCount: Int
            let timeToType: Double?
            let bestTimeToType: Double?
        }
        let note: String
        let runs: [Run]
        /// Derived from the final profile. These are EMAs, so they encode the
        /// ORDER history was replayed in — unlike the plan, which in this
        /// scenario stays the same either way because every timing clears the
        /// mastery threshold comfortably.
        let keyStats: [KeyStat]
    }

    /// Types a passage cleanly at a fixed cadence, exactly as the generator did.
    private func type(_ session: Session, text: String, interval: Double) throws {
        var clock: Double = 0
        for unit in Array(text.utf16) {
            clock += interval
            try session.input(String(utf16CodeUnits: [unit], count: 1), timeStamp: clock)
        }
    }

    func testSixConsecutiveAdaptiveRunsMatch() throws {
        let vector = try load("planner", as: PlannerVector.self)
        var settings = ProfileSettings.default
        settings.mode = .adaptive

        // Same seed, same clock, same everything the generator used. The RNG is
        // shared across runs, so run 4's words depend on every draw before it.
        let session = try Session(
            profile: Profile(settings: settings),
            now: { 1_700_000_000_000 },
            rng: Mulberry32(seed: 7))

        for expected in vector.runs {
            let snapshot = try session.snapshot()
            XCTAssertEqual(snapshot.typing.expected, expected.text, "run \(expected.run) text")
            try type(session, text: expected.text, interval: expected.interval)

            let plan = try session.snapshot().plan
            XCTAssertEqual(plan?.included, expected.included, "run \(expected.run) alphabet")
            XCTAssertEqual(plan?.focus, expected.focus, "run \(expected.run) focus")

            try session.start()
        }

        // The order-sensitive assertion. The six plans above would still match
        // if history were replayed newest-first; these numbers would not.
        let derived = deriveKeyStats(
            letters: defaultAlphabet,
            bigramStats: buildBigramStatsMap(session.profile.results.map(\.histogram)))
        for expected in vector.keyStats {
            let actual = try XCTUnwrap(derived[expected.letter], expected.letter)
            XCTAssertEqual(actual.hitCount, expected.hitCount, "hits for \(expected.letter)")
            XCTAssertEqual(actual.missCount, expected.missCount, "misses for \(expected.letter)")
            XCTAssertEqual(
                actual.timeToType, expected.timeToType, "ema for \(expected.letter)")
            XCTAssertEqual(
                actual.bestTimeToType, expected.bestTimeToType, "best for \(expected.letter)")
        }
    }

    struct ProfileVector: Decodable {
        let json: String
    }

    /// The whole stack, ending in bytes: run a benchmark exactly as the
    /// generator did and serialize the resulting profile. Everything has to be
    /// right for this to pass — the word draws, the timings, the metrics, the
    /// histogram and its insertion order, the key order of every object.
    func testACompletedBenchmarkRunSerializesToTheSameBytes() throws {
        let vector = try load("profile", as: ProfileVector.self)
        let session = try Session(
            profile: Profile(),
            now: { 1_700_000_000_000 },
            rng: Mulberry32(seed: 3))

        let text = try session.snapshot().typing.expected
        try type(session, text: text, interval: 130)

        let actual = serializeProfileString(session.profile)
        if actual != vector.json {
            let actualChars = Array(actual)
            let expectedChars = Array(vector.json)
            let offset = zip(actualChars, expectedChars).enumerated()
                .first { $0.element.0 != $0.element.1 }?.offset
                ?? min(actualChars.count, expectedChars.count)
            let window = max(0, offset - 50)..<min(actualChars.count, offset + 50)
            let siteWindow = max(0, offset - 50)..<min(expectedChars.count, offset + 50)
            XCTFail(
                """
                a completed run serializes differently at offset \(offset)
                  ours: …\(String(actualChars[window]))…
                  site: …\(String(expectedChars[siteWindow]))…
                """)
        }
    }

    func testTimeModeEndsOnTheClockAndRecordsExactlyOnce() throws {
        // The latch that stops a time-mode run recording a result on every
        // keystroke after the timer expires: TextInput.completed tracks the
        // cursor, not the clock, so without it the profile fills with
        // duplicates of one run.
        var settings = ProfileSettings.default
        settings.testMode = .time
        settings.testDurationSec = 1

        let session = try Session(
            profile: Profile(settings: settings), now: { 1_700_000_000_000 },
            rng: Mulberry32(seed: 11))
        let text = try session.snapshot().typing.expected

        var clock: Double = 0
        var completions = 0
        for unit in Array(text.utf16).prefix(60) {
            clock += 100
            if try session.input(String(utf16CodeUnits: [unit], count: 1), timeStamp: clock)
                == .completed
            {
                completions += 1
            }
        }
        XCTAssertGreaterThan(completions, 1, "further input keeps reporting completed")
        XCTAssertEqual(session.profile.results.count, 1, "but only one result is recorded")
    }

    func testHistoryStaysCappedWhileIndicesStayMonotonic() throws {
        var profile = Profile()
        let metrics = RunMetrics(
            netWpm: 0, rawWpm: 0, accuracy: 100, consistency: 0, wpmStdDev: 0, wpmSeries: [],
            correctChars: 0, incorrectChars: 0, durationMs: 0)
        profile.results = (0..<maxHistory).map {
            RunResult(
                index: $0, mode: .benchmark, timestamp: 0, passageId: "p", text: "t",
                metrics: metrics, histogram: Histogram())
        }

        let session = try Session(
            profile: profile, now: { 1_700_000_000_000 }, rng: Mulberry32(seed: 5))
        let text = try session.snapshot().typing.expected
        try type(session, text: text, interval: 120)

        XCTAssertEqual(session.profile.results.count, maxHistory, "the cap holds")
        XCTAssertEqual(
            session.profile.results.last?.index, maxHistory,
            "the index keeps counting past the trim, so identifiers are never reused")
        XCTAssertEqual(session.profile.results.first?.index, 1, "the oldest run was dropped")
    }
}
