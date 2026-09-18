import NaturalLanguage
import XCTest

@testable import TypeReviewKit

/// What Play drops is held to the practice corpus's rules: English as written,
/// ASCII, and nothing that cleaning would change. Lower case too, because the
/// game is for people still finding the keys, and a capital is a second key.
final class PlayTextTests: XCTestCase {
    private var everything: [String] { PlayText.words + PlayText.sentences }

    func testEveryTextIsLowerCaseLettersSpacesAndFullStops() {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz .")
        for text in everything {
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.allSatisfy(allowed.contains), "\"\(text)\" has a character outside a-z, space and .")
            XCTAssertEqual(text, text.trimmingCharacters(in: .whitespaces), "\"\(text)\" has space at an end")
            XCTAssertFalse(text.contains("  "), "\"\(text)\" has a double space")
        }
    }

    func testWordsAreSingleWords() {
        for word in PlayText.words {
            XCTAssertTrue(word.allSatisfy(\.isLetter), "\"\(word)\" is not one word")
        }
        XCTAssertEqual(Set(PlayText.words).count, PlayText.words.count, "a word is listed twice")
    }

    func testCleaningChangesNothing() {
        for text in everything {
            let cleaned = sanitize(text)
            XCTAssertEqual(cleaned.text, text)
            XCTAssertEqual(cleaned.droppedChars, 0)
        }
    }

    /// One sentence at a time, and sentences only.
    ///
    /// Judged together they prove nothing: all of Play's text with three
    /// German sentences mixed in still reads as English at 0.998. One at a
    /// time, a French, Spanish, German, Italian or Dutch sentence of this
    /// length is named correctly — measured. Six lower-case words is near what
    /// the recogniser can call, though: "the cat sat on the mat." read as
    /// Turkish, and was rephrased rather than excused. A lone word is too
    /// little to call at all, and the letter rule above confines the words.
    func testEverySentenceIsEnglish() {
        let recognizer = NLLanguageRecognizer()
        for sentence in PlayText.sentences {
            recognizer.reset()
            recognizer.processString(sentence)
            XCTAssertEqual(
                recognizer.dominantLanguage, .english,
                "\"\(sentence)\" reads as \(recognizer.dominantLanguage?.rawValue ?? "unknown")")
        }
    }
}
