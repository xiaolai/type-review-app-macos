import XCTest

@testable import TypeReviewKit

/// The adaptive layer against the TypeScript engine.
///
/// This is the part of the port where being wrong is quietest. The planner
/// decides which letter unlocks next and which bigrams a user is told to
/// drill; both depend on traversal order of a container that JavaScript
/// iterates by insertion and Swift iterates by hash — differently on every
/// launch.
final class PlannerVectorTests: XCTestCase {
    private func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        guard let url = Bundle.module.url(forResource: "Vectors/\(name)", withExtension: "json")
        else { throw XCTSkip("Vectors/\(name).json missing — run `pnpm emit:vectors`") }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    // MARK: - Histogram

    struct HistogramVector: Decodable {
        struct Entry: Decodable {
            let bigram: String
            let hitCount: Int
            let missCount: Int
            let timeToType: Double
        }
        let text: String
        let entries: [Entry]
    }

    private func cleanSteps(_ text: String, interval: Double = 150) -> [Step] {
        Array(text.utf16).enumerated().map { index, unit in
            let character = String(utf16CodeUnits: [unit], count: 1)
            return Step(
                position: index, timeStamp: Double(index + 1) * interval, typed: character,
                expected: character, timeToType: index == 0 ? 0 : interval, typo: false)
        }
    }

    func testHistogramMatches() throws {
        let cases = try load("histogram", as: [HistogramVector].self)
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            let histogram = histogramFromSteps(cleanSteps(testCase.text))
            // The vector is sorted by bigram; sort ours the same way to compare
            // content. Order itself is asserted by the planner vectors, where
            // it actually changes an outcome.
            let actual = histogram.entries
                .map { (bigram: $0.key, hit: $0.value) }
                .sorted { $0.bigram < $1.bigram }
            let expected = testCase.entries.sorted { $0.bigram < $1.bigram }
            XCTAssertEqual(actual.count, expected.count, "bigram count for \"\(testCase.text)\"")
            for (actualEntry, expectedEntry) in zip(actual, expected) {
                XCTAssertEqual(actualEntry.bigram, expectedEntry.bigram)
                XCTAssertEqual(actualEntry.hit.hitCount, expectedEntry.hitCount)
                XCTAssertEqual(actualEntry.hit.missCount, expectedEntry.missCount)
                XCTAssertEqual(actualEntry.hit.timeToType, expectedEntry.timeToType)
            }
        }
    }

    // MARK: - Planner

    struct PlannerVector: Decodable {
        struct Run: Decodable {
            let text: String
            let intervals: [Double]
        }
        struct Settings: Decodable {
            let minAlphabetSize: Double
            let alphabetExpansion: Double
        }
        struct HistogramEntry: Decodable {
            let bigram: String
        }
        struct StatsEntry: Decodable {
            let bigram: String
            let hitCount: Int
            let missCount: Int
            let timeToType: Double?
            let bestTimeToType: Double?
        }
        struct KeyStatsEntry: Decodable {
            let letter: String
            let hitCount: Int
            let missCount: Int
            let timeToType: Double?
            let bestTimeToType: Double?
        }
        struct Key: Decodable {
            let letter: String
            let included: Bool
            let forced: Bool
            let focused: Bool
            let confidence: Double?
            let bestConfidence: Double?
        }
        struct Weak: Decodable {
            let bigram: String
            let confidence: Double
        }
        struct Plan: Decodable {
            let included: [String]
            let focus: String?
            let keys: [Key]
            let weakBigrams: [Weak]
        }
        let name: String
        let targetWpm: Double
        let settings: Settings
        let runs: [Run]
        let histograms: [[HistogramEntry]]
        let bigramStats: [StatsEntry]
        let keyStats: [KeyStatsEntry]
        let plan: Plan
    }

    /// Reproduces the generator's cycling interval pattern.
    private func steps(_ text: String, intervals: [Double]) -> [Step] {
        var clock: Double = 0
        return Array(text.utf16).enumerated().map { index, unit in
            let interval = intervals[index % intervals.count]
            clock += interval
            let character = String(utf16CodeUnits: [unit], count: 1)
            return Step(
                position: index, timeStamp: clock, typed: character, expected: character,
                timeToType: index == 0 ? 0 : interval, typo: false)
        }
    }

    private func histograms(for testCase: PlannerVector) -> [Histogram] {
        testCase.runs.map { histogramFromSteps(steps($0.text, intervals: $0.intervals)) }
    }

    func testHistogramInsertionOrderIsFirstAppearance() throws {
        // Order is not cosmetic here: it is what the float sums below and the
        // tie-break further down follow.
        for testCase in try load("planner-synthetic", as: [PlannerVector].self) {
            for (actual, expected) in zip(histograms(for: testCase), testCase.histograms) {
                XCTAssertEqual(
                    actual.keys, expected.map(\.bigram),
                    "bigram order for \(testCase.name)")
            }
        }
    }

    func testBigramStatsMatchIncludingEmaAndPersonalBest() throws {
        for testCase in try load("planner-synthetic", as: [PlannerVector].self) {
            let stats = buildBigramStatsMap(histograms(for: testCase))
            XCTAssertEqual(
                stats.keys, testCase.bigramStats.map(\.bigram), "stats order for \(testCase.name)")
            for expected in testCase.bigramStats {
                let actual = try XCTUnwrap(stats[expected.bigram])
                XCTAssertEqual(actual.hitCount, expected.hitCount, expected.bigram)
                XCTAssertEqual(actual.missCount, expected.missCount, expected.bigram)
                XCTAssertEqual(actual.timeToType, expected.timeToType, "ema \(expected.bigram)")
                XCTAssertEqual(
                    actual.bestTimeToType, expected.bestTimeToType, "best \(expected.bigram)")
            }
        }
    }

    func testDerivedKeyStatsMatchToTheLastBit() throws {
        // Hit-weighted float sums over a traversal order. If the ordered map
        // were a plain Dictionary this would pass or fail depending on the
        // launch, which is worse than failing outright.
        for testCase in try load("planner-synthetic", as: [PlannerVector].self) {
            let stats = deriveKeyStats(
                letters: defaultAlphabet,
                bigramStats: buildBigramStatsMap(histograms(for: testCase)))
            for expected in testCase.keyStats {
                let actual = try XCTUnwrap(stats[expected.letter])
                XCTAssertEqual(actual.hitCount, expected.hitCount, expected.letter)
                XCTAssertEqual(actual.missCount, expected.missCount, expected.letter)
                XCTAssertEqual(actual.timeToType, expected.timeToType, "time \(expected.letter)")
                XCTAssertEqual(
                    actual.bestTimeToType, expected.bestTimeToType, "best \(expected.letter)")
            }
        }
    }

    func testPlanMatches() throws {
        for testCase in try load("planner-synthetic", as: [PlannerVector].self) {
            let plan = planLesson(
                letters: defaultAlphabet,
                bigramStats: buildBigramStatsMap(histograms(for: testCase)),
                target: Target(targetSpeed: testCase.targetWpm),
                settings: AdaptiveSettings(
                    minAlphabetSize: testCase.settings.minAlphabetSize,
                    alphabetExpansion: testCase.settings.alphabetExpansion))

            XCTAssertEqual(plan.included, testCase.plan.included, "included for \(testCase.name)")
            XCTAssertEqual(plan.focus, testCase.plan.focus, "focus for \(testCase.name)")
            XCTAssertEqual(plan.keys.count, testCase.plan.keys.count)
            for (actual, expected) in zip(plan.keys, testCase.plan.keys) {
                XCTAssertEqual(actual.letter, expected.letter)
                XCTAssertEqual(actual.included, expected.included, "included \(expected.letter)")
                XCTAssertEqual(actual.forced, expected.forced, "forced \(expected.letter)")
                XCTAssertEqual(actual.focused, expected.focused, "focused \(expected.letter)")
                XCTAssertEqual(actual.confidence, expected.confidence, "conf \(expected.letter)")
                XCTAssertEqual(
                    actual.bestConfidence, expected.bestConfidence, "best \(expected.letter)")
            }
        }
    }

    func testWeakBigramTiesKeepInsertionOrder() throws {
        // The scenario that exists for this: several bigrams share a
        // confidence exactly, so only a stable order picks the same three the
        // website would. An unstable sort passes every other assertion here.
        var checkedATie = false
        for testCase in try load("planner-synthetic", as: [PlannerVector].self) {
            let plan = planLesson(
                letters: defaultAlphabet,
                bigramStats: buildBigramStatsMap(histograms(for: testCase)),
                target: Target(targetSpeed: testCase.targetWpm),
                settings: AdaptiveSettings(
                    minAlphabetSize: testCase.settings.minAlphabetSize,
                    alphabetExpansion: testCase.settings.alphabetExpansion))

            XCTAssertEqual(
                plan.weakBigrams.map(\.bigram), testCase.plan.weakBigrams.map(\.bigram),
                "weak bigrams for \(testCase.name)")
            XCTAssertEqual(
                plan.weakBigrams.map(\.confidence), testCase.plan.weakBigrams.map(\.confidence))

            let confidences = testCase.plan.weakBigrams.map(\.confidence)
            if Set(confidences).count < confidences.count { checkedATie = true }
        }
        XCTAssertTrue(checkedATie, "no tied confidences in the vectors — the ordering is untested")
    }
}

// MARK: - Generators

extension PlannerVectorTests {
    struct GeneratorVectors: Decodable {
        struct Pseudo: Decodable {
            let seed: UInt32
            let text: String
        }
        struct Plain: Decodable {
            let seed: UInt32
            let text: String
            let withPunctuation: String
        }
        let pseudoWords: [Pseudo]
        let plainWords: [Plain]
    }

    /// The generators are where an RNG divergence becomes visible as words.
    /// They also pin the *order* of draws: moving one `rng()` call changes
    /// every word after it while the code still reads correctly.
    func testGeneratedTextMatchesCharacterForCharacter() throws {
        let vectors = try load("generators", as: GeneratorVectors.self)

        for testCase in vectors.pseudoWords {
            var rng = Mulberry32(seed: testCase.seed)
            let passage = try generatePseudoWords(
                filter: Filter(allowed: ["a", "s", "d", "f", "j", "k", "l"], focus: "f"),
                options: PseudoWordOptions(wordCount: 12),
                rng: &rng)
            XCTAssertEqual(passage.text, testCase.text, "pseudo-words for seed \(testCase.seed)")
        }

        for testCase in vectors.plainWords {
            var plain = Mulberry32(seed: testCase.seed)
            let passage = try generatePlainWords(
                options: PlainWordsOptions(wordCount: 12), rng: &plain)
            XCTAssertEqual(passage.text, testCase.text, "plain words for seed \(testCase.seed)")

            var punctuated = Mulberry32(seed: testCase.seed)
            let decorated = try generatePlainWords(
                options: PlainWordsOptions(
                    wordCount: 12, includeNumbers: true, includePunctuation: true),
                rng: &punctuated)
            XCTAssertEqual(
                decorated.text, testCase.withPunctuation,
                "punctuated words for seed \(testCase.seed)")
        }
    }
}
