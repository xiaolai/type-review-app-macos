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
        struct FoldEntry: Decodable {
            let codePoint: Int
            let replacement: String
        }
        let sanitize: [Sanitize]
        let lengthScore: [Score]
        let picks: [Pick]
        let quoteCount: Int
        let firstQuotes: [Quote]
        let asciiFoldTable: [FoldEntry]
    }

    private func vector() throws -> Vector {
        guard let url = Bundle.module.url(forResource: "Vectors/corpus", withExtension: "json")
        else { throw VectorUnavailable(reason: "Vectors/corpus.json missing") }
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

    /// The fold table itself, entry for entry and in order.
    ///
    /// The sanitize case "every fold table entry" cannot do this, though both
    /// tables' comments said it did. Its input is the table as it stood when the
    /// vector was generated, so an entry added to either side afterwards is in
    /// no input and fails nothing. The website's table is in the vector, and
    /// this one has to equal it.
    func testTheFoldTableIsTheWebsites() throws {
        let website = try vector().asciiFoldTable
        let here = Set(asciiFoldTable.map { Int($0.0) })
        let there = Set(website.map(\.codePoint))
        XCTAssertEqual(here.subtracting(there).sorted(), [], "code points only in Sanitize.swift")
        XCTAssertEqual(there.subtracting(here).sorted(), [], "code points only in the website's sanitize.ts")
        XCTAssertEqual(asciiFoldTable.count, website.count, "the tables differ in length")
        for (index, entry) in asciiFoldTable.enumerated() where index < website.count {
            XCTAssertEqual(Int(entry.0), website[index].codePoint, "entry \(index) is a different code point")
            XCTAssertEqual(
                Array(entry.1.utf16), Array(website[index].replacement.utf16),
                "entry \(index), U+\(String(entry.0, radix: 16, uppercase: true)), folds differently")
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
