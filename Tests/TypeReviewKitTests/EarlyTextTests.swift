import NaturalLanguage
import XCTest

@testable import TypeReviewKit

/// The beginner material, held to the same rules as the quotes and to one of
/// its own.
///
/// `EnglishTextTests` cannot do this job: `rawQuotes()` names
/// `Resources/quotes.json`, so a second corpus file inherits none of its
/// checks and would ship unread. The rules are repeated here against
/// `early.json` rather than the quotes gate being widened, because the two
/// corpora answer to different people — an adult's quote may be any English
/// prose, a child's passage may not.
final class EarlyTextTests: XCTestCase {
    private func isASCII(_ text: String) -> Bool {
        text.utf16.allSatisfy { $0 < 0x80 }
    }

    /// The file as it is written, before cleaning has touched it.
    private func rawEarly() throws -> [RawStaticEntry] {
        struct QuotesFile: Decodable { let entries: [RawStaticEntry] }
        let url = try XCTUnwrap(
            resourceBundle.url(forResource: "Resources/early", withExtension: "json"),
            "Resources/early.json is not in the bundle")
        let entries = try JSONDecoder().decode(QuotesFile.self, from: Data(contentsOf: url)).entries
        XCTAssertGreaterThan(entries.count, 20, "early.json looks truncated")
        return entries
    }

    func testTheEarlyCorpusLoads() throws {
        XCTAssertEqual(
            BundledCorpus.early.entries.count, try rawEarly().count,
            "early.json holds entries the loader dropped")
        XCTAssertFalse(
            BundledCorpus.loadFailures.contains { $0.contains("early") },
            "the loader reported a failure: \(BundledCorpus.loadFailures)")
    }

    /// One passage at a time, which is the only way this question can be
    /// asked. Judged together, a corpus carries its own weight and a stray
    /// sentence in another language disappears into it.
    func testEveryEarlyPassageIsEnglish() throws {
        let recognizer = NLLanguageRecognizer()
        for entry in try rawEarly() {
            recognizer.reset()
            recognizer.processString(entry.text)
            XCTAssertEqual(
                recognizer.dominantLanguage, .english,
                "\(entry.id) reads as \(recognizer.dominantLanguage?.rawValue ?? "unknown"): \(entry.text)")
        }
    }

    func testNoEarlyPassageLosesACharacterToCleaning() throws {
        for entry in try rawEarly() {
            let cleaned = sanitize(entry.text)
            XCTAssertTrue(isASCII(cleaned.text), "\(entry.id) is not ASCII once cleaned")
            XCTAssertEqual(
                cleaned.droppedChars, 0,
                "\(entry.id) loses \(cleaned.droppedChars) characters to cleaning")
        }
    }

    /// Children's material is public domain material. The listing is public
    /// and App Review has asked about third-party text before; a fair-use
    /// quotation is a defensible thing to put in front of an adult and a
    /// needless risk to put in front of a child.
    func testEveryEarlyPassageIsPublicDomain() throws {
        for entry in try rawEarly() {
            XCTAssertEqual(entry.license, "public domain", "\(entry.id) is \(entry.license)")
        }
    }

    // MARK: - the graded words

    /// The promise the staging makes: a word never needs a letter the child
    /// has not been introduced to. Without this the stages are a comment.
    ///
    /// Driven from `EarlyWords.stages`, so a fifth stage is covered the moment
    /// it is added rather than when somebody remembers to extend this list.
    func testEveryStageKeepsToItsOwnAlphabet() {
        XCTAssertEqual(EarlyWords.stages.count, EarlyWords.alphabets.count)
        for (index, stage) in EarlyWords.stages.enumerated() {
            let allowed = Set(EarlyWords.alphabets[index])
            XCTAssertFalse(stage.words.isEmpty, "stage \(index + 1) is empty")
            XCTAssertFalse(stage.added.isEmpty, "stage \(index + 1) introduces no letter")
            for word in stage.words {
                let letters = Set(word.map(String.init))
                XCTAssertTrue(
                    letters.isSubset(of: allowed),
                    "stage \(index + 1) word \"\(word)\" needs \(letters.subtracting(allowed).sorted())")
            }
        }
    }

    /// Stage one is the whole claim. Frequency order spells 5 decodable words
    /// from its first six letters and the home row 3; the phonics order spells
    /// 25, and stage one carries early sight words on top of those. If this
    /// count ever drops, the staging has lost its point and the number in
    /// `EarlyWords` has become untrue.
    func testStageOneSpellsEnoughRealWords() throws {
        let stageOne = try XCTUnwrap(EarlyWords.stages.first)
        XCTAssertGreaterThanOrEqual(stageOne.words.count, 25)
    }

    /// Every letter a stage introduces is one a word in that stage or a later
    /// one actually uses. An introduced letter nobody types is a letter whose
    /// confidence never moves.
    func testEveryIntroducedLetterIsUsed() {
        let used = Set(EarlyWords.all.joined().map(String.init))
        for (index, stage) in EarlyWords.stages.enumerated() {
            for letter in stage.added.map(String.init) {
                XCTAssertTrue(
                    used.contains(letter),
                    "stage \(index + 1) introduces \"\(letter)\" and no word uses it")
            }
        }
    }

    func testTheWordsAreTypeableLowercaseLetters() {
        for word in EarlyWords.all {
            XCTAssertFalse(word.isEmpty)
            XCTAssertEqual(word, word.lowercased(), "\"\(word)\" is not lower case")
            XCTAssertTrue(
                word.allSatisfy { $0.isASCII && $0.isLetter }, "\"\(word)\" is not plain letters")
            let cleaned = sanitize(word)
            XCTAssertEqual(cleaned.droppedChars, 0, "\"\(word)\" loses characters to cleaning")
        }
    }

    func testAllIsEveryStage() {
        XCTAssertEqual(EarlyWords.all.count, EarlyWords.stages.reduce(0) { $0 + $1.words.count })
        XCTAssertEqual(Set(EarlyWords.all).count, EarlyWords.all.count, "a word is repeated")
    }
}
