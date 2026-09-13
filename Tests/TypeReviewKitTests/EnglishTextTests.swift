import NaturalLanguage
import XCTest

@testable import TypeReviewKit

/// The practice text is English, and typeable on an English keyboard.
///
/// Two claims that fail separately, which is why neither test stands in for
/// the other. A French quote is perfectly good ASCII — "Il faut cultiver notre
/// jardin." has no accent in it — so an ASCII check alone kept seven of the
/// twenty-one non-English quotes this corpus used to ship. And English text can
/// carry a character no key produces, which only the cleaning rule answers.
final class EnglishTextTests: XCTestCase {
    private func isASCII(_ text: String) -> Bool {
        text.utf16.allSatisfy { $0 < 0x80 }
    }

    private func hex(_ value: UInt32) -> String {
        "U+" + String(value, radix: 16, uppercase: true)
    }

    /// The rule itself, stated over every character in the basic plane rather
    /// than over examples. In chunks, because the passage cap would otherwise
    /// cut the input off after the first few thousand.
    func testNoCharacterSurvivesCleaningOutsideASCII() {
        var start: UInt32 = 0x80
        while start <= 0xFFFF {
            var chunk = String.UnicodeScalarView()
            for value in start..<min(start + 500, 0x10000) where !(0xD800...0xDFFF).contains(value) {
                guard let scalar = Unicode.Scalar(value) else { continue }
                chunk.append(scalar)
                chunk.append(" ")
            }
            let cleaned = sanitize(String(chunk)).text
            XCTAssertTrue(isASCII(cleaned), "a character from \(hex(start)) survived cleaning")
            start += 500
        }
    }

    /// Every fold entry is reachable and lands on ASCII.
    ///
    /// An entry for a character NFKD already decomposes can never run, because
    /// decomposition happens first. That is a table which looks like coverage
    /// and is not, so it fails here rather than sitting there.
    func testEveryFoldEntryIsReachableAndASCII() {
        for (point, replacement) in asciiFoldTable {
            guard let scalar = Unicode.Scalar(point) else {
                XCTFail("\(hex(UInt32(point))) is not a scalar")
                continue
            }
            let character = String(scalar)
            // As UTF-16, not as `String`. Swift's `==` is canonical equivalence,
            // under which a decomposed é equals a composed one, so an entry for a
            // character that decomposes passed this check while being exactly
            // the dead entry it exists to catch.
            XCTAssertEqual(
                Array(character.decomposedStringWithCompatibilityMapping.utf16), Array(character.utf16),
                "\(hex(UInt32(point))) decomposes, so its fold entry can never be reached")
            XCTAssertTrue(isASCII(replacement), "\(hex(UInt32(point))) folds to non-ASCII")
        }
    }

    func testEveryBundledPassageIsASCII() {
        let passages = BundledCorpus.quotes.entries + BundledCorpus.code.entries
        XCTAssertGreaterThan(passages.count, 100, "the bundled corpus did not load")
        for entry in passages {
            XCTAssertTrue(isASCII(entry.text), "\(entry.id) is not ASCII once cleaned")
        }
    }

    /// The quotes as the file holds them, before cleaning has touched them.
    private func rawQuotes() throws -> [RawStaticEntry] {
        struct QuotesFile: Decodable { let entries: [RawStaticEntry] }
        let url = try XCTUnwrap(
            resourceBundle.url(forResource: "Resources/quotes", withExtension: "json"),
            "Resources/quotes.json is not in the bundle")
        let entries = try JSONDecoder().decode(QuotesFile.self, from: Data(contentsOf: url)).entries
        XCTAssertGreaterThan(entries.count, 100, "quotes.json looks truncated")
        return entries
    }

    /// The check the ASCII rule cannot make. Uses the same recogniser the app
    /// picks a speech voice with, so a quote that fails here is also one that
    /// would have been read aloud in the wrong language.
    ///
    /// On the text as written, not as cleaned. Cleaning is what hides a wrong
    /// language: it removes Cyrillic, Greek and Chinese outright, so a Russian
    /// quote became an empty passage that loading then dropped unseen, and a
    /// quote half in Chinese was judged on its English half.
    func testEveryBundledQuoteIsEnglishAsWritten() throws {
        let recognizer = NLLanguageRecognizer()
        for entry in try rawQuotes() {
            recognizer.reset()
            recognizer.processString(entry.text)
            XCTAssertEqual(
                recognizer.dominantLanguage, .english,
                "\(entry.id) reads as \(recognizer.dominantLanguage?.rawValue ?? "unknown"): \(entry.text)")
        }
    }

    /// Every quote in the file is served, and cleaning took nothing from any of
    /// them. Cleaning is a net for pasted text, not what makes this corpus
    /// English: a quote it has to cut, or cuts away entirely, should not be in
    /// the file, and one cut to nothing used to vanish at load along with every
    /// check that looked at loaded quotes.
    func testNoBundledQuoteLosesACharacterToCleaning() throws {
        let raw = try rawQuotes()
        XCTAssertEqual(
            BundledCorpus.quotes.entries.count, raw.count,
            "quotes.json holds \(raw.count) quotes and \(BundledCorpus.quotes.entries.count) were loaded")
        for entry in raw {
            let cleaned = sanitize(entry.text)
            XCTAssertEqual(
                cleaned.droppedChars, 0, "\(entry.id) loses \(cleaned.droppedChars) characters to cleaning")
        }
    }
}
