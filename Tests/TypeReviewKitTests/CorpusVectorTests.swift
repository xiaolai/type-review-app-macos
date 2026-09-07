import XCTest

@testable import TypeReviewKit

/// The corpus against the website's.
///
/// Two things are being held here. The sanitiser has to make the same text out
/// of the same input, or the two apps hand the user different passages from
/// identical data. And the picker has to consume the RNG the same way — the
/// count of draws matters as much as the arithmetic, because one extra draw
/// shifts every passage in the rest of the session.
final class CorpusVectorTests: XCTestCase {
    struct Vector: Decodable {
        struct Sanitize: Decodable {
            let name: String
            let input: String
            let preserveLayout: Bool?
            let text: String
            let droppedChars: Int
            let truncated: Bool
        }
        struct Score: Decodable {
            let entryLength: Int
            let wanted: Double
            let score: Double
        }
        struct Pick: Decodable {
            let seed: UInt32
            let wantedChars: Double
            let id: String?
            let length: Int
        }
        struct Quote: Decodable {
            let id: String
            let text: String
        }
        let sanitize: [Sanitize]
        let lengthScore: [Score]
        let picks: [Pick]
        let quoteCount: Int
        let firstQuotes: [Quote]
    }

    private func vector() throws -> Vector {
        guard let url = Bundle.module.url(forResource: "Vectors/corpus", withExtension: "json")
        else { throw XCTSkip("Vectors/corpus.json missing — see ARCHITECTURE.md — Regenerating a vector") }
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    func testSanitiserProducesTheSameText() throws {
        for testCase in try vector().sanitize {
            let result = sanitize(testCase.input, preserveLayout: testCase.preserveLayout ?? false)
            XCTAssertEqual(result.text, testCase.text, testCase.name)
            XCTAssertEqual(result.droppedChars, testCase.droppedChars, "dropped — \(testCase.name)")
            XCTAssertEqual(result.truncated, testCase.truncated, "truncated — \(testCase.name)")
        }
    }

    func testLengthScoreMatches() throws {
        for testCase in try vector().lengthScore {
            XCTAssertEqual(
                lengthScore(entryLength: testCase.entryLength, wantedChars: testCase.wanted),
                testCase.score, "score for \(testCase.entryLength)/\(testCase.wanted)")
        }
    }

    func testTheBundledQuotesAreTheSameBytes() throws {
        let vector = try vector()
        XCTAssertEqual(
            BundledCorpus.quotes.entries.count, vector.quoteCount,
            "the app ships a different number of quotes than the website")
        for expected in vector.firstQuotes {
            let entry = try XCTUnwrap(
                BundledCorpus.quotes.entries.first { $0.id == expected.id }, expected.id)
            // Compared after sanitising, because that is the text a typist
            // actually sees — identical source bytes that sanitise differently
            // would still be a divergence.
            XCTAssertEqual(entry.text, expected.text, "sanitised text for \(expected.id)")
        }
    }

    func testWeightedPickChoosesTheSameEntryForTheSameSeed() throws {
        // The strongest corpus assertion available: it depends on the entry
        // order in quotes.json, every weight, the sum, and the single RNG draw
        // the picker makes.
        for testCase in try vector().picks {
            var rng = Mulberry32(seed: testCase.seed)
            let entry = BundledCorpus.quotes.pick(
                CorpusContext(wantedChars: testCase.wantedChars), rng: &rng)
            XCTAssertEqual(
                entry?.id, testCase.id,
                "seed \(testCase.seed) wanting \(testCase.wantedChars) chars")
            XCTAssertEqual(entry?.text.utf16.count, testCase.length, "length for \(testCase.id ?? "?")")
        }
    }

    func testCodeKeepsItsIndentation() {
        // Code is sanitised with preserveLayout, because collapsing whitespace
        // would fold a Python snippet into one line and remove exactly the
        // keys that make code hard to type.
        XCTAssertFalse(BundledCorpus.code.entries.isEmpty, "code corpus did not load")
        let hasIndentation = BundledCorpus.code.entries.contains { $0.text.contains("\n ") }
        XCTAssertTrue(hasIndentation, "no code entry kept its indentation")
    }

    func testAlphabetFilteringIgnoresPunctuationButNotLetters() {
        let entry = makeEntry(id: "t", kind: .quote, text: "ab, cd.")
        XCTAssertTrue(fitsAlphabet(entry, ["a", "b", "c", "d"]), "punctuation must not lock a passage")
        XCTAssertFalse(fitsAlphabet(entry, ["a", "b", "c"]), "a missing letter must")
    }
}
