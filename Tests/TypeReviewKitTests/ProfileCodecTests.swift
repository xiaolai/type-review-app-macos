import XCTest

@testable import TypeReviewKit

/// The profile codec, against the exact bytes the website writes.
///
/// This is the only test in the suite whose failure is a *product* failure
/// rather than a numerical one: a user exports from the site and imports here,
/// and the receiving side validates with a check that rejects the entire
/// profile over one unexpected key. Approximate agreement is no agreement.
final class ProfileCodecTests: XCTestCase {
    struct ProfileVector: Decodable {
        let note: String
        /// The exact string `JSON.stringify(serializeProfile(profile))` produced.
        let json: String
        let pretty: Pretty

        struct Pretty: Decodable {
            let version: Int
            let settings: Settings
            let results: [Result]

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
                let adaptive: Adaptive
                struct Adaptive: Decodable {
                    let minAlphabetSize: Double
                    let alphabetExpansion: Double
                }
            }

            struct Result: Decodable {
                let index: Int
                let mode: String
                let timestamp: Double
                let passageId: String
                let text: String
                let metrics: Metrics
                let histogram: [String: Hit]

                struct Metrics: Decodable {
                    let netWpm: Double
                    let rawWpm: Double
                    let accuracy: Double
                    let consistency: Double
                    let wpmStdDev: Double
                    let wpmSeries: [Double]
                    let correctChars: Int
                    let incorrectChars: Int
                    let durationMs: Double
                }
                struct Hit: Decodable {
                    let hitCount: Int
                    let missCount: Int
                    let timeToType: Double
                }
            }
        }
    }

    private func vector() throws -> ProfileVector {
        guard let url = Bundle.module.url(forResource: "Vectors/profile", withExtension: "json")
        else { throw VectorUnavailable(reason: "Vectors/profile.json missing") }
        return try JSONDecoder().decode(ProfileVector.self, from: Data(contentsOf: url))
    }

    /// Rebuilds the vector's profile natively, then compares the serialized
    /// bytes. Histogram key order comes from the vector's own JSON, because
    /// insertion order is exactly what is being asserted.
    private func rebuild(from vector: ProfileVector) throws -> Profile {
        let pretty = vector.pretty
        let settings = ProfileSettings(
            mode: Mode(rawValue: pretty.settings.mode)!,
            targetWpm: pretty.settings.targetWpm,
            adaptive: AdaptiveSettings(
                minAlphabetSize: pretty.settings.adaptive.minAlphabetSize,
                alphabetExpansion: pretty.settings.adaptive.alphabetExpansion),
            wordCount: pretty.settings.wordCount,
            testMode: TestMode(rawValue: pretty.settings.testMode)!,
            testDurationSec: pretty.settings.testDurationSec,
            stopOnError: pretty.settings.stopOnError,
            noBackspace: pretty.settings.noBackspace,
            passageLength: PassageLength(rawValue: pretty.settings.passageLength)!,
            includeNumbers: pretty.settings.includeNumbers,
            includePunctuation: pretty.settings.includePunctuation)

        let results = try pretty.results.map { result -> RunResult in
            var histogram = Histogram()
            for key in try histogramKeyOrder(in: vector.json, resultIndex: result.index) {
                guard let hit = result.histogram[key] else { continue }
                histogram[key] = BigramHit(
                    hitCount: hit.hitCount, missCount: hit.missCount, timeToType: hit.timeToType)
            }
            return RunResult(
                index: result.index,
                mode: Mode(rawValue: result.mode)!,
                timestamp: result.timestamp,
                passageId: result.passageId,
                text: result.text,
                metrics: RunMetrics(
                    netWpm: result.metrics.netWpm, rawWpm: result.metrics.rawWpm,
                    accuracy: result.metrics.accuracy, consistency: result.metrics.consistency,
                    wpmStdDev: result.metrics.wpmStdDev, wpmSeries: result.metrics.wpmSeries,
                    correctChars: result.metrics.correctChars,
                    incorrectChars: result.metrics.incorrectChars,
                    durationMs: result.metrics.durationMs),
                histogram: histogram)
        }
        return Profile(settings: settings, results: results)
    }

    /// Pulls the histogram's key order straight out of the reference JSON.
    private func histogramKeyOrder(in json: String, resultIndex: Int) throws -> [String] {
        guard let start = json.range(of: "\"histogram\":{") else { return [] }
        let tail = json[start.upperBound...]
        guard let end = tail.range(of: "}}") else { return [] }
        let body = tail[..<end.lowerBound]
        // Keys are the strings immediately preceding a `:{`.
        var keys: [String] = []
        var index = body.startIndex
        while let quote = body[index...].range(of: "\":{") {
            let keyEnd = quote.lowerBound
            guard let keyStart = body[..<keyEnd].range(of: "\"", options: .backwards)
            else { break }
            keys.append(String(body[body.index(after: keyStart.lowerBound)..<keyEnd]))
            index = quote.upperBound
        }
        return keys
    }

    func testSerializedProfileIsByteIdenticalToTheWebsite() throws {
        let vector = try vector()
        let profile = try rebuild(from: vector)
        let actual = serializeProfileString(profile)

        if actual != vector.json {
            // Point at the first divergence rather than dumping 4 kB twice.
            let actualChars = Array(actual)
            let expectedChars = Array(vector.json)
            let firstDifference = zip(actualChars, expectedChars).enumerated()
                .first { $0.element.0 != $0.element.1 }?.offset
                ?? min(actualChars.count, expectedChars.count)
            let window = max(0, firstDifference - 40)..<min(actualChars.count, firstDifference + 40)
            XCTFail(
                """
                serialized bytes diverge at offset \(firstDifference)
                  ours: …\(String(actualChars[window]))…
                  site: …\(String(expectedChars[min(window.lowerBound, expectedChars.count)..<min(window.upperBound, expectedChars.count)]))…
                """)
        }
        XCTAssertEqual(actual.count, vector.json.count, "byte length")
    }

    func testNumbersPrintTheWayJavaScriptPrintsThem() {
        // A timestamp is the case that catches a naive encoder: Swift's Double
        // description gives 1.7e+12 where JSON.stringify gives the digits.
        XCTAssertEqual(JSONWriter.stringify(.fromDouble(1_700_000_000_000)), "1700000000000")
        XCTAssertEqual(JSONWriter.stringify(.fromDouble(50)), "50")
        XCTAssertEqual(JSONWriter.stringify(.fromDouble(0)), "0")
        XCTAssertEqual(JSONWriter.stringify(.fromDouble(97.56)), "97.56")
        XCTAssertEqual(JSONWriter.stringify(.fromDouble(0.1 + 0.2)), "0.30000000000000004")
    }

    func testDigitBigramsAreHoistedTheWayJavaScriptObjectsHoistThem() {
        // With numbers enabled a passage produces bigrams like "12", and a
        // JavaScript object puts integer-like keys first in ascending order
        // regardless of insertion. Miss this and every profile containing
        // digits serializes differently in the two implementations.
        var histogram = Histogram()
        for key in ["zz", "12", "aa", "7", "01"] {
            histogram[key] = BigramHit(hitCount: 1, missCount: 0, timeToType: 100)
        }
        let profile = Profile(
            settings: .default,
            results: [
                RunResult(
                    index: 0, mode: .benchmark, timestamp: 1, passageId: "p", text: "t",
                    metrics: RunMetrics(
                        netWpm: 0, rawWpm: 0, accuracy: 100, consistency: 0, wpmStdDev: 0,
                        wpmSeries: [], correctChars: 0, incorrectChars: 0, durationMs: 0),
                    histogram: histogram)
            ])
        let json = serializeProfileString(profile)
        let order = ["7", "12", "zz", "aa", "01"]
        let positions = order.map { json.range(of: "\"\($0)\":{")?.lowerBound }
        XCTAssertFalse(positions.contains(where: { $0 == nil }), "all keys present")
        for (earlier, later) in zip(positions, positions.dropFirst()) {
            XCTAssertLessThan(earlier!, later!, "expected order \(order)")
        }
    }
}
