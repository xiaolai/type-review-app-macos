import XCTest

@testable import TypeReviewKit

/// The markdown stripper against the website's.
///
/// The reason this needs vectors rather than hand-written expectations: the
/// rules are individually obvious and their *order* is not. Swapping two of
/// them still produces readable English, so a hand-written test written from
/// the same misunderstanding as the code would pass. These outputs come from
/// running the TypeScript.
final class MarkdownVectorTests: XCTestCase {
    struct Case: Decodable {
        let name: String
        let input: String
        let output: String
    }

    func testMatchesTheWebsite() throws {
        guard let url = Bundle.module.url(forResource: "Vectors/library", withExtension: "json")
        else { throw XCTSkip("Vectors/library.json missing — see ARCHITECTURE.md — Regenerating a vector") }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(cases.count, 10, "vector file looks truncated")
        for testCase in cases {
            XCTAssertEqual(
                parseMarkdown(testCase.input), testCase.output,
                "markdown: \(testCase.name)")
        }
    }

    func testPlainTextIsSanitisedButNotStripped() {
        // A `.txt` file is prose already. Running the markdown rules over it
        // would eat asterisks and underscores the author meant literally.
        let raw = "a *literal* asterisk\u{0000} and  spaces"
        XCTAssertEqual(parseLibraryText(raw, kind: .txt), "a *literal* asterisk and spaces")
        XCTAssertEqual(parseLibraryText(raw, kind: .md), "a literal asterisk and spaces")
    }

    func testFileKindComesFromTheExtension() {
        XCTAssertEqual(LibraryFileKind(filename: "notes.MD"), .md)
        XCTAssertEqual(LibraryFileKind(filename: "notes.markdown"), .md)
        XCTAssertEqual(LibraryFileKind(filename: "notes.txt"), .txt)
        XCTAssertEqual(LibraryFileKind(filename: "md"), .txt)
    }
}

/// The library store's rules and its use as a corpus source.
final class UserCorpusTests: XCTestCase {
    func testTitleFallsBackToTheOpeningWords() throws {
        let passage = try makeUserPassage(
            id: "a", title: "   ", text: String(repeating: "x", count: 100), createdAt: 0)
        XCTAssertEqual(passage.title.count, 40)
    }

    func testEmptyTextIsRefused() {
        XCTAssertThrowsError(try makeUserPassage(id: "a", title: "t", text: "", createdAt: 0))
    }

    func testTextAndTitleAreCapped() throws {
        let passage = try makeUserPassage(
            id: "a", title: String(repeating: "t", count: 500),
            text: String(repeating: "x", count: maxUserPassageLength + 10), createdAt: 0)
        XCTAssertEqual(passage.text.count, maxUserPassageLength)
        XCTAssertEqual(passage.title.count, maxUserTitleLength)
    }

    func testAnEmptyLibraryNeverAnswers() {
        var rng = Mulberry32(seed: 1)
        let source = UserCorpusSource(passages: [])
        XCTAssertNil(source.pick(CorpusContext(wantedChars: 100), rng: &rng))
    }

    /// The point of the whole feature: a run on the Library channel types the
    /// user's own words, not generated ones.
    func testTheLibraryChannelServesTheUsersText() throws {
        let passage = try makeUserPassage(
            id: "u1", title: "Mine", text: "the quick brown fox jumps over the lazy dog",
            createdAt: 0)
        var rng = Mulberry32(seed: 7)
        let adapter = CorpusAdapter(channel: .user, library: [passage])
        let result = try adapter.adaptiveSource(
            filter: Filter(allowed: ["e", "t", "a"], focus: nil), wordCount: 9, rng: &rng)
        XCTAssertEqual(result.text, passage.text)
    }

    /// The alphabet filter is dropped only for an explicit pick. In `auto` the
    /// curriculum still rules, or an early learner is handed letters they have
    /// never been taught.
    func testAutoStillRespectsTheAlphabet() throws {
        let passage = try makeUserPassage(
            id: "u1", title: "Mine", text: "the quick brown fox jumps over the lazy dog",
            createdAt: 0)
        var rng = Mulberry32(seed: 7)
        let adapter = CorpusAdapter(channel: .auto, library: [passage])
        let result = try adapter.adaptiveSource(
            filter: Filter(allowed: ["e", "t", "a"], focus: nil), wordCount: 9, rng: &rng)
        XCTAssertNotEqual(result.text, passage.text)
    }
}
