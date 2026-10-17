import XCTest

@testable import TypeReviewKit

/// What the Book screen asks of `Session`: a sentence run that keeps the
/// book's passage id, and a count of typos that survives correction.
final class BookSessionTests: XCTestCase {
    func testABookSentenceKeepsItsIdAndMaySpeak() throws {
        let session = try Session(profile: Profile())
        try session.startWithText("It rained.", passageId: "book:b-1:7")
        XCTAssertEqual(try session.snapshot().passageId, "book:b-1:7")
        XCTAssertTrue(passageMayBeSpoken(channel: .user, passageId: "book:b-1:7"))

        try session.startWithText("It rained.")
        XCTAssertTrue(try session.snapshot().passageId.hasPrefix("custom:"), "no id keeps the website's")
    }

    func testTyposCountMistakesThatWereCorrected() throws {
        let session = try Session(profile: Profile())
        try session.startWithText("ab", passageId: "book:b-1:0")
        var clock: Double = 0
        func type(_ character: String) throws {
            clock += 150
            try session.input(character, timeStamp: clock)
        }
        try type("x")
        try session.backspace()
        try type("a")
        try type("b")
        XCTAssertEqual(session.typos, 1)
        XCTAssertEqual(session.keystrokes, 3)
        XCTAssertEqual(session.profile.results.last?.metrics.incorrectChars, 0, "the statuses forget it")
    }
}

/// Speak Word's choice of word.
final class WordAtCursorTests: XCTestCase {
    func testTheWordAroundTheCursor() {
        let sentence = "\"Don't go,\" said Toto."
        XCTAssertEqual(word(in: sentence, atUTF16Offset: 0), "Don't", "an opening quote reads the word after it")
        XCTAssertEqual(word(in: sentence, atUTF16Offset: 3), "Don't")
        XCTAssertEqual(word(in: sentence, atUTF16Offset: 7), "go")
        XCTAssertEqual(word(in: sentence, atUTF16Offset: 10), "said", "between words, the next")
        XCTAssertEqual(word(in: sentence, atUTF16Offset: 22), "Toto", "past the end, the last")
        XCTAssertEqual(word(in: sentence, atUTF16Offset: 500), "Toto")
        XCTAssertNil(word(in: "...", atUTF16Offset: 1))
        XCTAssertNil(word(in: "", atUTF16Offset: 0))
    }

    func testAQuoteAloneIsNeverTheWord() {
        let sentence = "'Go,' said Toto."
        XCTAssertEqual(word(in: sentence, atUTF16Offset: 3), "said", "on the comma")
        XCTAssertEqual(word(in: sentence, atUTF16Offset: 4), "said", "on the closing quote")
        XCTAssertEqual(word(in: "Toto's '", atUTF16Offset: 7), "Toto's", "a quote after the last word")
        XCTAssertEqual(word(in: "the dogs' tails", atUTF16Offset: 8), "dogs", "a plural's apostrophe is its word's")
        XCTAssertEqual(word(in: "'dogs'' tails", atUTF16Offset: 6), "dogs", "a run of apostrophes")
    }
}

