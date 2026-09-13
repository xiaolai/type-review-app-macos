import XCTest

@testable import TypeReviewKit

/// What the cleaner reports, and what it does at the cap.
///
/// The corpus vectors pin both to the website, which proves the two agree.
/// These prove what they agree on is right: a count someone can check against
/// what they pasted, and a cap that cleaning the result a second time does not
/// move. Text is compared as UTF-16, because `String` equality is canonical
/// equivalence and would pass a decomposed accent for a composed one.
final class SanitizeCountAndCapTests: XCTestCase {
    func testARemovedCharacterCountsOnceHoweverManyCodeUnitsItTakes() {
        // An emoji is two UTF-16 code units, and a Hangul syllable decomposes
        // into three jamo. Each is one character to the person who pasted it.
        let result = sanitize("a\u{1F600}b\u{D55C}c")
        XCTAssertEqual(Array(result.text.utf16), Array("abc".utf16))
        XCTAssertEqual(result.droppedChars, 2)
    }

    func testATruncatedPassageEndsWithoutWhitespace() {
        // The last boundary before the cap is the second newline of a paragraph
        // break, and the cut used to keep the first.
        let words = String(repeating: "word ", count: 900).trimmingCharacters(in: .whitespaces)
        let prose = sanitize(words + "\n\n" + String(repeating: "x", count: 1000))
        XCTAssertTrue(prose.truncated)
        XCTAssertEqual(Array(prose.text.utf16), Array(words.utf16))
        // With layout kept, the last boundary can sit inside indentation.
        let code = sanitize(
            String(repeating: "x", count: 4100) + "\n    " + String(repeating: "y", count: 1000),
            preserveLayout: true)
        XCTAssertTrue(code.truncated)
        XCTAssertEqual(Array(code.text.utf16), Array(String(repeating: "x", count: 4100).utf16))
    }

    func testCleaningCleanedTextChangesNothing() {
        let inputs = [
            String(repeating: "word ", count: 900).trimmingCharacters(in: .whitespaces)
                + "\n\n" + String(repeating: "x", count: 1000),
            String(repeating: "x", count: 4100) + "\n    " + String(repeating: "y", count: 1000),
            String(repeating: "word ", count: 2000),
            "  caf\u{E9} \u{201C}quoted\u{201D} \u{2014} a\u{A0}b\t\n\n\nc  ",
            "a\u{1F600}b\u{D55C}c\u{07}",
            String(repeating: "  x", count: 2500),
        ]
        for preserveLayout in [false, true] {
            for input in inputs {
                let once = sanitize(input, preserveLayout: preserveLayout)
                let twice = sanitize(once.text, preserveLayout: preserveLayout)
                let label = "preserveLayout=\(preserveLayout), input starting \(input.prefix(12).debugDescription)"
                XCTAssertEqual(Array(twice.text.utf16), Array(once.text.utf16), label)
                XCTAssertEqual(twice.droppedChars, 0, label)
                XCTAssertFalse(twice.truncated, label)
            }
        }
    }
}
