import XCTest

@testable import TypeReviewKit

/// The writer-fits-reader invariant: whatever a legitimate run can *produce*
/// must be something storage will *accept*.
///
/// `maxHistogramEntries` is a defensive cap on a value this app writes itself,
/// and nothing in the type system holds the two together — the cap is a guess
/// about the writer unless something measures the writer. The TypeScript
/// engine shipped that same constant at 256, a number real prose passes at
/// around 900 characters, and its deserializer escalated the over-cap
/// histogram to a corrupt verdict for the whole profile. One long run
/// therefore discarded a 500-run history on the next load.
///
/// This side has always had the right number. Nothing asserted it, which is
/// the only difference that matters: a correct constant with no test is one
/// edit away from the same bug, and the failure is silent until a user's
/// history is already gone.
final class HistogramCapacityTests: XCTestCase {
    /// Steps for a clean, error-free run over `text`, one per UTF-16 code
    /// unit — the engine's coordinate system, so the bigram count here is the
    /// one a real run produces rather than a grapheme approximation of it.
    private func cleanSteps(_ text: String) -> [Step] {
        Array(text.utf16).enumerated().map { index, unit in
            let character = String(utf16CodeUnits: [unit], count: 1)
            return Step(
                position: index, timeStamp: Double(index + 1) * 150, typed: character,
                expected: character, timeToType: 150, typo: false)
        }
    }

    /// Deterministic prose of `chars` UTF-16 units, built from the shipped
    /// quote corpus. Real text with real variety is the point: a synthetic
    /// string repeated to length saturates its own bigram set early and would
    /// hide the very thing this pins.
    private func prose(_ chars: Int) -> String {
        let texts = BundledCorpus.quotes.entries.map(\.text)
        XCTAssertFalse(texts.isEmpty, "the shipped quote corpus failed to load")
        var text = ""
        var index = 0
        while text.utf16.count < chars, !texts.isEmpty {
            text += texts[index % texts.count] + " "
            index += 1
        }
        return String(decoding: Array(text.utf16.prefix(chars)), as: UTF16.self)
    }

    func testTheLongestPassageTheCorpusCanServeFitsTheCap() throws {
        let size = histogramFromSteps(cleanSteps(prose(maxPassageChars))).count
        // The TypeScript engine's original ceiling. Asserting the count clears
        // it keeps this test failing if the cap is ever lowered to match.
        XCTAssertGreaterThan(size, 256, "a 5,000-character passage should exceed the old ceiling")
        XCTAssertLessThanOrEqual(size, maxHistogramEntries)
    }

    func testTheGeneratorAtTheWidestSettingsStorageAllowsFitsTheCap() throws {
        for includePunctuation in [false, true] {
            var rng = Mulberry32(seed: 20_260_903)
            let passage = try generatePlainWords(
                options: PlainWordsOptions(
                    wordCount: Int(SettingsBounds.wordCount.hi),
                    includeNumbers: includePunctuation,
                    includePunctuation: includePunctuation),
                rng: &rng)
            let size = histogramFromSteps(cleanSteps(passage.text)).count
            XCTAssertLessThanOrEqual(
                size, maxHistogramEntries, "punctuation: \(includePunctuation)")
        }
    }

    func testAProseRunsHistogramSurvivesASaveLoadRoundTrip() throws {
        let text = prose(1_200)
        let written = histogramFromSteps(cleanSteps(text))
        XCTAssertGreaterThan(written.count, 256, "the fixture should exceed the old ceiling")

        let run = RunResult(
            index: 0, mode: .benchmark, timestamp: 1_700_000_000_000, passageId: "p0", text: text,
            metrics: RunMetrics(
                netWpm: 60, rawWpm: 62, accuracy: 97, consistency: 80, wpmStdDev: 4,
                wpmSeries: [60, 62], correctChars: 30, incorrectChars: 1, durationMs: 30_000),
            histogram: written)

        guard case .ok(let loaded) = deserializeProfile(
            serializeProfileString(Profile(results: [run]))),
            let reloaded = loaded.results.first
        else { return XCTFail("a profile holding one prose run should load") }
        XCTAssertEqual(loaded.results.count, 1)
        // Count before contents. The failure this test exists to catch degrades
        // the histogram to empty, and comparing whole maps in that case prints
        // all 400-odd bigrams — burying the one number that explains it.
        XCTAssertEqual(reloaded.histogram.count, written.count)
        XCTAssertEqual(reloaded.histogram, written)
    }
}
