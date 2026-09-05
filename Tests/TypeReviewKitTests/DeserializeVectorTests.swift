import XCTest

@testable import TypeReviewKit

/// The rejection surface, against the website's own answers.
///
/// A validator port drifts by being too permissive, and too permissive fails
/// silently: a tampered or half-written profile loads, and the damage surfaces
/// later as impossible metrics or a curriculum built on nonsense. So every
/// case pins the exact outcome, including which reason a corrupt payload gives.
final class DeserializeVectorTests: XCTestCase {
    struct Case: Decodable {
        let name: String
        /// The payload as JSON text, so the Swift side parses the same bytes.
        let input: String
        let status: String
        let reason: String?
        let settings: Settings?
        let resultCount: Int?
        let histogramSizes: [Int]?

        struct Settings: Decodable {
            let mode: String
            let targetWpm: Double
            let wordCount: Double
            let testMode: String
            let testDurationSec: Double
            let stopOnError: Bool
            let noBackspace: Bool
            let passageLength: String
            let includeNumbers: Bool
            let includePunctuation: Bool
        }
    }

    private func cases() throws -> [Case] {
        guard let url = Bundle.module.url(forResource: "Vectors/deserialize", withExtension: "json")
        else { throw XCTSkip("Vectors/deserialize.json missing — run `pnpm emit:vectors`") }
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testEveryPayloadGetsTheSameVerdict() throws {
        let cases = try cases()
        XCTAssertGreaterThan(cases.count, 25, "the vector should cover the rejection surface")

        for testCase in cases {
            let result = deserializeProfile(testCase.input)
            XCTAssertEqual(
                result.statusName, testCase.status,
                "\(testCase.name): expected \(testCase.status), got \(result.statusName)")

            if case .corrupt(let reason) = result, let expected = testCase.reason {
                // The reason is user-visible: it decides which banner appears,
                // and whether the user is told their data was tampered with or
                // simply belongs to a newer build.
                //
                // One documented divergence. JavaScript's JSON.parse accepts an
                // unpaired surrogate, because a JS string may hold one;
                // Foundation refuses the text outright, because a Swift String
                // may not. Both verdicts are "corrupt" — they differ only in
                // how far the payload got first, and rejecting earlier is not
                // a weaker answer.
                if reason == "not valid JSON", expected != "not valid JSON" {
                    XCTAssertTrue(
                        testCase.name.contains("surrogate"),
                        "\(testCase.name): parsing failed for an undocumented reason")
                } else {
                    XCTAssertEqual(reason, expected, "reason for \(testCase.name)")
                }
            }

            if case .ok(let profile) = result {
                if let expected = testCase.settings {
                    XCTAssertEqual(profile.settings.mode.rawValue, expected.mode, testCase.name)
                    XCTAssertEqual(profile.settings.targetWpm, expected.targetWpm, testCase.name)
                    XCTAssertEqual(profile.settings.wordCount, expected.wordCount, testCase.name)
                    XCTAssertEqual(
                        profile.settings.testMode.rawValue, expected.testMode, testCase.name)
                    XCTAssertEqual(
                        profile.settings.testDurationSec, expected.testDurationSec, testCase.name)
                    XCTAssertEqual(
                        profile.settings.stopOnError, expected.stopOnError, testCase.name)
                    XCTAssertEqual(
                        profile.settings.noBackspace, expected.noBackspace, testCase.name)
                    XCTAssertEqual(
                        profile.settings.passageLength.rawValue, expected.passageLength,
                        testCase.name)
                    XCTAssertEqual(
                        profile.settings.includeNumbers, expected.includeNumbers, testCase.name)
                    XCTAssertEqual(
                        profile.settings.includePunctuation, expected.includePunctuation,
                        testCase.name)
                }
                XCTAssertEqual(profile.results.count, testCase.resultCount, testCase.name)
                XCTAssertEqual(
                    profile.results.map(\.histogram.count), testCase.histogramSizes, testCase.name)
            }
        }
    }

    func testAnOverCapHistogramCostsOneRunsDetailNotTheWholeProfile() throws {
        // The failure this exists to prevent: the website once escalated an
        // over-cap histogram to "corrupt" for the ENTIRE profile, so one long
        // run discarded a 500-run history on the next load.
        let testCase = try XCTUnwrap(
            cases().first { $0.name.contains("over-cap") }, "vector case missing")
        guard case .ok(let profile) = deserializeProfile(testCase.input) else {
            return XCTFail("an over-cap histogram must not discard the profile")
        }
        XCTAssertEqual(profile.results.count, 1, "the run survives")
        XCTAssertEqual(profile.results.first?.histogram.count, 0, "only its histogram is dropped")
        XCTAssertGreaterThan(profile.results.first?.metrics.netWpm ?? 0, 0, "metrics survive")
    }

    func testRoundTripPreservesTheExactBytes() throws {
        // Load then save must be byte-stable, or a profile drifts every time
        // the app opens it — including the histogram's key order, which
        // JSONSerialization discards and which has to be recovered from the
        // raw text.
        let testCase = try XCTUnwrap(cases().first { $0.name == "a complete run" })
        guard case .ok(let profile) = deserializeProfile(testCase.input) else {
            return XCTFail("the reference profile should load")
        }
        XCTAssertEqual(serializeProfileString(profile), testCase.input)
    }
}
