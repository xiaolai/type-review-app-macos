import XCTest

@testable import TypeReviewKit

/// The word-boundary rule, driven through the real typing engine.
///
/// Every case here types against a `TextInput` rather than hand-building a
/// status array, because the thing being tested is arithmetic in `TextInput`'s
/// coordinate system — UTF-16 code units, with the cursor stepping over
/// newlines by itself. A test that invented its own positions would agree with
/// itself and with nothing else.
final class SpokenWordTests: XCTestCase {
    /// Types a passage and records what would have been spoken.
    ///
    /// Holds the tracker as well as the engine, so the deduplication rule —
    /// one utterance per (run, character range) — is exercised by the same
    /// script that exercises the boundary rule.
    private final class Typist {
        let input: TextInput
        var tracker = SpokenWordTracker()
        private(set) var spoken: [SpokenWord] = []
        private var tick: Double = 0

        init(_ text: String, stopOnError: Bool = false) throws {
            input = try TextInput(expected: text, stopOnError: stopOnError)
        }

        var words: [String] { spoken.map(\.text) }

        /// One keystroke, whatever it is.
        func type(_ character: String) {
            let before = input.pos
            tick += 100
            input.appendChar(character, timeStamp: tick)
            record(from: before)
        }

        /// The character the passage wants next. The cursor never rests on a
        /// newline — `TextInput` steps over those — so this always types
        /// something typeable.
        func typeExpected() {
            let units = Array(input.expected.utf16)
            guard input.pos < units.count else { return }
            type(String(utf16CodeUnits: [units[input.pos]], count: 1))
        }

        /// The whole passage, typed correctly.
        func typeAll() {
            while !input.completed { typeExpected() }
        }

        /// Backspace, run through the tracker too: a backwards move must never
        /// produce an utterance, and asserting that here costs nothing.
        func backspace() {
            let before = input.pos
            input.backspace()
            record(from: before)
        }

        private func record(from before: Int) {
            let snapshot = input.snapshot()
            guard
                let word = tracker.wordToSpeak(
                    expected: snapshot.expected, statuses: snapshot.statuses,
                    oldPos: before, newPos: snapshot.pos)
            else { return }
            spoken.append(word)
        }
    }

    // MARK: - The plain cases

    func testTwoWordsTypedStraightThroughFireInOrder() throws {
        let typist = try Typist("cat dog")
        typist.typeAll()
        XCTAssertEqual(typist.words, ["cat", "dog"])
        XCTAssertEqual(typist.spoken.map(\.range), [0..<3, 4..<7])
    }

    /// The last word of a passage has no trailing space to announce it, so the
    /// end of the text has to count as a boundary of its own.
    func testTheFinalWordFiresWithoutATrailingSpace() throws {
        let typist = try Typist("hello")
        typist.typeAll()
        XCTAssertEqual(typist.words, ["hello"])
        XCTAssertEqual(typist.spoken.first?.range, 0..<5)
    }

    func testARepeatedWordFiresOncePerOccurrence() throws {
        let typist = try Typist("cat cat")
        typist.typeAll()
        XCTAssertEqual(typist.words, ["cat", "cat"])
        XCTAssertEqual(typist.spoken.map(\.range), [0..<3, 4..<7])
    }

    // MARK: - Deduplication

    /// Retyping the last letter crosses the same boundary a second time. The
    /// value being offered is "the word you just finished", and finishing it
    /// twice is one event, not two.
    func testRetypingTheLastLetterDoesNotSpeakTwice() throws {
        let typist = try Typist("cat")
        typist.typeAll()
        typist.backspace()
        typist.type("t")
        XCTAssertEqual(typist.words, ["cat"])
    }

    // MARK: - Ranges under combining marks

    /// `"e\u{301}lan"` is four Characters and five code units. A range computed
    /// in Characters would address the wrong entries in `statuses` — which is
    /// exactly the bug `TextInput`'s own comment warns about.
    func testRangesLandOnTheRightStatusesAfterACombiningMark() throws {
        let passage = "e\u{301}lan cat"
        let typist = try Typist(passage)
        typist.typeAll()
        XCTAssertEqual(typist.words, ["e\u{301}lan", "cat"])
        XCTAssertEqual(typist.spoken.map(\.range), [0..<5, 6..<9])

        // The range is a slice of the code units, not of the Characters.
        let units = Array(passage.utf16)
        for word in typist.spoken {
            let slice = Array(units[word.range])
            XCTAssertEqual(String(utf16CodeUnits: slice, count: slice.count), word.text)
        }
    }

    /// The range has to address the right *statuses*, which producing the right
    /// text does not prove.
    ///
    /// `"e\u{301}lan"` is 4 Characters and 5 code units, so the final `n` is
    /// Character 3 and unit 4. A range computed in Characters would be `0..<4`,
    /// would find the four correct statuses in front of the mistake, and would
    /// speak a word that was typed wrongly.
    func testAMistakeAfterACombiningMarkIsSeenAtTheRightOffset() throws {
        let typist = try Typist("e\u{301}lan cat")
        typist.type("e")
        typist.type("\u{301}")
        typist.type("l")
        typist.type("a")
        typist.type("x")
        XCTAssertEqual(typist.words, [], "the mistake sits at code unit 4, inside the word")
    }

    // MARK: - Separators

    func testNewlinesDoNotProduceAToken() throws {
        let typist = try Typist("cat\n\ndog")
        typist.typeAll()
        XCTAssertEqual(typist.words, ["cat", "dog"])
        XCTAssertEqual(typist.spoken.map(\.range), [0..<3, 5..<8])
    }

    // MARK: - Shape

    func testAnInteriorCommaSkipsTheToken() throws {
        let typist = try Typist("hello,world")
        typist.typeAll()
        XCTAssertEqual(typist.words, [])
    }

    func testAnApostropheAndAHyphenAreSpokenWhole() throws {
        let typist = try Typist("don't well-known")
        typist.typeAll()
        XCTAssertEqual(typist.words, ["don't", "well-known"])
    }

    /// The typographic apostrophe is the same character doing the same job, and
    /// it is what pasted prose actually contains.
    func testTheTypographicApostropheCounts() throws {
        let typist = try Typist("don\u{2019}t")
        typist.typeAll()
        XCTAssertEqual(typist.words, ["don\u{2019}t"])
    }

    /// Trailing punctuation is trimmed, and the utterance fires when the last
    /// *letter* is passed rather than waiting for the mark.
    func testTrailingPunctuationIsTrimmedAndDoesNotDelayTheWord() throws {
        let typist = try Typist("cat!")
        typist.type("c")
        typist.type("a")
        typist.type("t")
        XCTAssertEqual(typist.words, ["cat"], "the word should be spoken at the t")
        XCTAssertEqual(typist.spoken.first?.range, 0..<3)
        typist.type("!")
        XCTAssertEqual(typist.words, ["cat"], "the mark must not fire a second utterance")
    }

    func testSurroundingQuotesAreTrimmed() throws {
        let typist = try Typist("\"cat\"")
        typist.typeAll()
        XCTAssertEqual(typist.words, ["cat"])
        XCTAssertEqual(typist.spoken.first?.range, 1..<4)
    }

    func testDigitsAndDashesProduceNoToken() throws {
        let numbers = try Typist("1863")
        numbers.typeAll()
        XCTAssertEqual(numbers.words, [])

        let dash = try Typist("\u{2014}")
        dash.typeAll()
        XCTAssertEqual(dash.words, [])
    }

    /// `42nd` is one of the tokens the spell checker accepts and this rule must
    /// not: a digit anywhere in the token disqualifies it, rather than being
    /// trimmed off the front to leave `nd`.
    func testADigitInsideATokenDisqualifiesIt() throws {
        let typist = try Typist("42nd")
        typist.typeAll()
        XCTAssertEqual(typist.words, [])
    }

    // MARK: - Length

    /// A run of text with no whitespace in it is not a word, however many
    /// letters it holds.
    ///
    /// Two things go wrong without a bound, and the second is the worse one.
    /// The scan around the cursor is the length of the token, so every
    /// keystroke in a 5,000-unit passage with no spaces — Chinese prose, a
    /// pasted base64 blob — costs the whole passage. And the one token that
    /// eventually finishes gets read aloud in its entirety.
    func testATokenLongerThanAnyWordIsNotSpoken() throws {
        let long = String(repeating: "a", count: maxSpokenTokenUnits + 1)
        let typist = try Typist(long)
        typist.typeAll()
        XCTAssertEqual(typist.words, [])
    }

    func testATokenExactlyAtTheBoundIsStillSpoken() throws {
        let word = String(repeating: "a", count: maxSpokenTokenUnits)
        let typist = try Typist(word)
        typist.typeAll()
        XCTAssertEqual(typist.words, [word])
    }

    /// The bound is a number, not whatever the source happens to say.
    ///
    /// Every other length case here is written in terms of
    /// `maxSpokenTokenUnits`, so they would all follow it down to ten and go on
    /// passing while every long word stopped being spoken. This is the one that
    /// notices.
    func testTheTokenBoundIsSixtyFourUnits() {
        XCTAssertEqual(maxSpokenTokenUnits, 64)
    }

    /// And a real word at the far end of the range, spelled out rather than
    /// generated: the longest word in a major dictionary, at 63 letters.
    func testTheLongestRealWordIsStillSpoken() throws {
        let word = "Rindfleischetikettierungsüberwachungsaufgabenübertragungsgesetz"
        XCTAssertEqual(word.utf16.count, 63, "the fixture is not the word it claims to be")
        let typist = try Typist(word)
        typist.typeAll()
        XCTAssertEqual(typist.words, [word])
    }

    /// And a token that is too long must not take its neighbours down with it.
    func testAWordAfterAnOverlongTokenStillFires() throws {
        let typist = try Typist(String(repeating: "a", count: maxSpokenTokenUnits + 1) + " cat")
        typist.typeAll()
        XCTAssertEqual(typist.words, ["cat"])
    }

    // MARK: - Correctness

    func testAWordCorrectedBeforeTheBoundaryStillFires() throws {
        let typist = try Typist("cat")
        typist.type("c")
        typist.type("a")
        typist.type("x")
        XCTAssertEqual(typist.words, [], "a wrong letter at the boundary is silent")
        typist.backspace()
        typist.type("t")
        XCTAssertEqual(typist.words, ["cat"])
    }

    func testAWordStillWrongAtTheBoundaryDoesNotFire() throws {
        let typist = try Typist("cat dog")
        typist.type("c")
        typist.type("a")
        typist.type("x")
        typist.type(" ")
        XCTAssertEqual(typist.words, [])
    }

    /// The mistake in the middle, the boundary letter right.
    ///
    /// Every other wrong-letter case here mistypes the *last* letter, so an
    /// implementation that checked only the status under the cursor would pass
    /// all of them. This is the one that fails.
    func testAWrongLetterInsideTheWordIsNotRescuedByACorrectEnding() throws {
        let typist = try Typist("cat dog")
        typist.type("c")
        typist.type("x")
        typist.type("t")
        XCTAssertEqual(typist.words, [], "c-x-t is not `cat`")
    }

    /// Stop-on-error is the mode the correct-now rule exists for.
    ///
    /// The cursor does not move past a mistake, so the word is finished by the
    /// keystroke that finally gets it right — and under a first-time-right rule
    /// the child who mistyped one letter would hear nothing at all, which is
    /// silence exactly where the teaching moment is.
    func testStopOnErrorSpeaksTheWordOnceItIsFinallyRight() throws {
        let typist = try Typist("cat", stopOnError: true)
        typist.type("c")
        typist.type("a")
        typist.type("x")
        XCTAssertEqual(typist.words, [], "the cursor has not moved and the letter is wrong")
        typist.type("t")
        XCTAssertEqual(typist.words, ["cat"])
    }

    // MARK: - The tracker's own contract

    func testStartingAPassageForgetsWhatWasSpoken() throws {
        var tracker = SpokenWordTracker()
        let input = try TextInput(expected: "cat")
        input.appendChar("c", timeStamp: 0)
        input.appendChar("a", timeStamp: 1)
        input.appendChar("t", timeStamp: 2)
        let snapshot = input.snapshot()

        XCTAssertNotNil(
            tracker.wordToSpeak(
                expected: snapshot.expected, statuses: snapshot.statuses, oldPos: 2, newPos: 3))
        XCTAssertNil(
            tracker.wordToSpeak(
                expected: snapshot.expected, statuses: snapshot.statuses, oldPos: 2, newPos: 3),
            "the same range must not be spoken twice in one run")

        tracker.startPassage()
        XCTAssertNotNil(
            tracker.wordToSpeak(
                expected: snapshot.expected, statuses: snapshot.statuses, oldPos: 2, newPos: 3),
            "a new run starts with nothing spoken")
    }

    /// A backwards or standing cursor has finished nothing. Guarded here rather
    /// than left to the callers, because there are three of them.
    func testACursorThatDidNotAdvanceFindsNothing() throws {
        let input = try TextInput(expected: "cat")
        input.appendChar("c", timeStamp: 0)
        input.appendChar("a", timeStamp: 1)
        input.appendChar("t", timeStamp: 2)
        let snapshot = input.snapshot()
        XCTAssertNil(
            wordJustFinished(
                expected: snapshot.expected, statuses: snapshot.statuses, oldPos: 3, newPos: 3))
        XCTAssertNil(
            wordJustFinished(
                expected: snapshot.expected, statuses: snapshot.statuses, oldPos: 3, newPos: 2))
    }

    /// The statuses describe the passage. Handed a pair that cannot be talking
    /// about the same text, the answer is "no word" rather than a guess or a
    /// crash — silence is this feature's safe direction.
    func testAMismatchedStatusArrayIsRefused() {
        XCTAssertNil(
            wordJustFinished(expected: "cat", statuses: [.correct, .correct], oldPos: 2, newPos: 3))
    }
}
