import XCTest

@testable import TypeReviewKit

/// §3.5: every rule has a case that triggers it, and each case names the
/// rule it expects, so a reordering that changes which rule decides shows up
/// as the wrong name rather than passing by luck.
final class EpubClassifyTests: XCTestCase {
    /// A chapter's worth of facts that no rule but the last would claim.
    private func facts(_ change: (inout SpineFacts) -> Void = { _ in }) -> SpineFacts {
        var facts = SpineFacts()
        facts.characters = 8_000
        facts.head = "The river ran fast and brown after the night of rain."
        facts.title = "The River"
        change(&facts)
        return facts
    }

    private func assertRule(
        _ expected: ClassificationRule, _ kind: ChapterKind, _ facts: SpineFacts,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let verdict = classifySpineItem(facts)
        XCTAssertEqual(verdict.rule, expected, file: file, line: line)
        XCTAssertEqual(verdict.kind, kind, "\(expected)", file: file, line: line)
        XCTAssertFalse(verdict.reason.isEmpty, file: file, line: line)
    }

    func testRule1NotLinear() {
        assertRule(.notLinear, .skip, facts { $0.linear = false; $0.bodyTypes = ["chapter"] })
    }

    func testRule2NavigationDocument() {
        assertRule(.navigationDocument, .skip, facts { $0.isNavigation = true })
    }

    func testRule3TaggedChapterBeatsAMisTag() {
        // The real case: every chapter tagged `acknowledgments` as well.
        assertRule(.taggedChapter, .story, facts { $0.bodyTypes = ["chapter", "acknowledgments"] })
        assertRule(.taggedChapter, .story, facts { $0.bodyTypes = ["doc-part"]; $0.title = "Index" })
    }

    func testRule4TaggedSkipAndOptional() {
        for type in ["cover", "titlepage", "copyright-page", "toc", "index", "colophon", "dedication", "acknowledgments",
            "appendix", "endnotes"]
        {
            assertRule(.taggedSkip, .skip, facts { $0.bodyTypes = [type] })
        }
        assertRule(.taggedSkip, .skip, facts { $0.landmarkTypes = ["cover"] })
        for type in ["preface", "foreword", "introduction", "afterword"] {
            assertRule(.taggedOptional, .optional, facts { $0.bodyTypes = [type] })
        }
        XCTAssertEqual(classifySpineItem(facts { $0.bodyTypes = ["epigraph"] }).reason, "marked as epigraph")
    }

    func testRule4PrologueAndEpilogueAreStory() {
        assertRule(.taggedStory, .story, facts { $0.bodyTypes = ["prologue"]; $0.characters = 100 })
        assertRule(.taggedStory, .story, facts { $0.bodyTypes = ["epilogue"] })
    }

    func testRule5Guide() {
        assertRule(.guideSkip, .skip, facts { $0.guideTypes = ["copyright-page"] })
        assertRule(.guideOptional, .optional, facts { $0.guideTypes = ["preface"] })
    }

    func testRule6GutenbergLicence() {
        assertRule(.gutenbergLicence, .skip, facts { $0.isGutenbergLicence = true })
        let licence = "The Project Gutenberg eBook. " + String(repeating: "x ", count: 100)
            + "START: FULL LICENSE"
        XCTAssertTrue(isGutenbergLicence(licence, characters: 5_000))
        XCTAssertFalse(isGutenbergLicence(licence, characters: 50_000), "a whole novel with the licence on the end")
        XCTAssertFalse(
            isGutenbergLicence(String(repeating: "y", count: 2_100) + licence, characters: 5_000),
            "the project named only far down")
    }

    func testRule7TaggedStory() {
        assertRule(.taggedStory, .story, facts { $0.landmarkTypes = ["bodymatter"]; $0.characters = 50 })
    }

    func testRule8Titles() {
        for title in ["Contents", "Table of Contents", "Copyright", "Acknowledgments", "About the Author", "Notes",
            "Index", "Title Page", "Also by Jane Doe", "Praise for The River", "An Invitation from the Publisher",
            "Excerpt from Book Two", "Reading Group Guide"]
        {
            assertRule(.titleSkip, .skip, facts { $0.title = title })
        }
        for title in ["Preface", "Foreword", "Author's Note", "Introduction to the Second Edition"] {
            assertRule(.titleOptional, .optional, facts { $0.title = title })
        }
        // Matched as a whole: these are stories.
        for title in ["Notes from Underground", "The Index Card", "Contents of the Box"] {
            assertRule(.defaultStory, .story, facts { $0.title = title })
        }
    }

    func testRule9Fallbacks() {
        assertRule(.tooShort, .skip, facts { $0.characters = 150 })
        assertRule(.mostlyLinks, .skip, facts { $0.characters = 600; $0.linkCharacters = 400 })
        assertRule(
            .publisherWords, .skip, facts { $0.characters = 900; $0.head = "Copyright 2020. All rights reserved." })
        // Publisher words in a long chapter are the story talking.
        assertRule(.defaultStory, .story, facts { $0.head = "She signed up for the newsletter." })
        XCTAssertEqual(
            classifySpineItem(facts { $0.characters = 600; $0.linkCharacters = 400 }).reason,
            "looks like a table of contents")
    }

    func testRule10BeforeTheBodyStart() {
        let story = classifySpineItem(facts())
        let verdicts = classifySequence([story, story, story], characters: [4_000, 8_000, 8_000], bodyStart: 1)
        XCTAssertEqual(verdicts.map(\.rule), [.beforeBodyStart, .defaultStory, .defaultStory])
        XCTAssertEqual(verdicts[0].kind, .optional)
    }

    func testRule11ShortPagesOutsideTheStory() {
        let story = classifySpineItem(facts())
        let tagged = classifySpineItem(facts { $0.bodyTypes = ["chapter"] })
        let verdicts = classifySequence(
            [story, story, story, story, story, story, story, tagged],
            characters: [900, 8_000, 9_000, 1_000, 8_500, 8_200, 700, 600], bodyStart: nil)
        XCTAssertEqual(
            verdicts.map(\.rule),
            [.shortPageBeforeStory, .defaultStory, .defaultStory, .defaultStory, .defaultStory, .defaultStory,
                .shortPageAfterStory, .taggedChapter],
            "a short page between chapters stays story, and a tagged one is never moved")
    }

    func testRule12EverythingElseIsStory() {
        assertRule(.defaultStory, .story, facts())
    }

    // MARK: Through the reader

    func testAMisTaggedChapterStaysStoryInABook() throws {
        var book = EpubBuilder()
        book.chapters = (1...3).map {
            BuiltChapter(
                "ch\($0).xhtml", "<h1>Acknowledgments</h1>" + storyParagraphs(5, seed: $0),
                bodyAttributes: "epub:type=\"chapter acknowledgments\"")
        }
        let draft = try book.draft()
        XCTAssertEqual(draft.chapters.map(\.kind), [.story, .story, .story])
        XCTAssertTrue(draft.chapters.allSatisfy(\.included))
    }

    func testTheUntaggedFixture() throws {
        let contents = try readEpubContents(at: try fixtureURL("untagged-hand-made"))
        assertSentenceInvariants(contents)
        let draft = try contents.draft()
        XCTAssertEqual(draft.title, "The Kite on the Hill")
        let byTitle = Dictionary(uniqueKeysWithValues: draft.chapters.map { ($0.title, $0) })
        // The cover is a picture and has nothing to list. The title page and
        // the contents have no heading, so they are named by position.
        XCTAssertEqual(
            draft.chapters.map(\.title), ["Section 2", "Section 3", "One", "Two", "Three", "Four", "About the Writer"])
        XCTAssertEqual(byTitle["Section 2"]?.reason, "too short to be a chapter")
        XCTAssertEqual(byTitle["Section 3"]?.kind, .skip)
        XCTAssertEqual(byTitle["Section 3"]?.reason, "looks like a table of contents")
        XCTAssertEqual(byTitle["Section 3"]?.included, false)
        XCTAssertEqual(byTitle["About the Writer"]?.kind, .optional)
        XCTAssertEqual(byTitle["About the Writer"]?.reason, "a short page after the story")
        for title in ["One", "Two", "Three", "Four"] {
            XCTAssertEqual(byTitle[title]?.kind, .story, title)
            XCTAssertEqual(byTitle[title]?.included, true, title)
        }
        XCTAssertFalse(byTitle["One"]?.sentences.contains { $0.hasPrefix("Chapter One") } ?? true)
        XCTAssertTrue(draft.warnings.isEmpty, "\(draft.warnings)")
    }

    func testTheGutenbergFixture() throws {
        let contents = try readEpubContents(at: try fixtureURL("peter-rabbit-gutenberg"))
        assertSentenceInvariants(contents)
        let draft = try contents.draft()
        XCTAssertEqual(draft.title, "The Tale of Peter Rabbit")
        let story = draft.chapters.filter(\.included).flatMap(\.sentences)
        XCTAssertGreaterThan(story.count, 50)
        XCTAssertFalse(story.contains { $0.contains("Project Gutenberg") }, "the licence was typed")
        XCTAssertTrue(story.contains { $0.contains("Flopsy") }, "\(story.prefix(5))")
        XCTAssertFalse(draft.warnings.contains { if case .notEnglish = $0 { return true } else { return false } })
    }

    func testTheStandardEbooksFixture() throws {
        let contents = try readEpubContents(at: try fixtureURL("wind-in-the-willows-standard-ebooks"))
        assertSentenceInvariants(contents)
        let draft = try contents.draft()
        XCTAssertEqual(draft.title, "The Wind in the Willows")
        XCTAssertEqual(draft.author, "Kenneth Grahame")
        let included = draft.chapters.filter(\.included)
        XCTAssertEqual(included.count, 3, "\(draft.chapters.map { ($0.title, $0.kind, $0.reason) })")
        XCTAssertTrue(included[0].sentences[0].hasPrefix("The Mole had been working very hard"), included[0].sentences[0])
        for chapter in draft.chapters where !chapter.included {
            XCTAssertEqual(chapter.kind, .skip, chapter.title)
        }
    }

    func testAFolderBookReadsLikeItsZip() throws {
        // Apple Books' shape: the same files, unpacked.
        let zip = try ZipArchive(contentsOf: try fixtureURL("untagged-hand-made"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("book-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in zip.names {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.read(name).write(to: url)
        }
        XCTAssertEqual(try readEpubBook(at: root), try readEpubBook(at: try fixtureURL("untagged-hand-made")))
    }
}
