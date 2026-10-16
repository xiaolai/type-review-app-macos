import Foundation

/// Which rule decided a spine item, named so a test can say which fired.
enum ClassificationRule: String, Sendable, Equatable {
    case notLinear
    case navigationDocument
    case taggedChapter
    case taggedSkip
    case taggedOptional
    case guideSkip
    case guideOptional
    case gutenbergLicence
    case taggedStory
    case titleSkip
    case titleOptional
    case tooShort
    case mostlyLinks
    case publisherWords
    case beforeBodyStart
    case shortPageBeforeStory
    case shortPageAfterStory
    case defaultStory
}

struct Classification: Sendable, Equatable {
    let kind: ChapterKind
    let rule: ClassificationRule
    /// What the review sheet says next to the tick box.
    let reason: String
}

/// What the rules look at for one spine item.
struct SpineFacts {
    var linear = true
    var isNavigation = false
    var bodyTypes = Set<String>()
    var landmarkTypes = Set<String>()
    var guideTypes = Set<String>()
    var characters = 0
    var linkCharacters = 0
    /// The first 300 characters of the item's text.
    var head = ""
    var isGutenbergLicence = false
    /// From the table of contents, or the file's first heading.
    var title = ""
}

private let chapterTypes: Set<String> = ["chapter", "doc-chapter", "part", "doc-part"]
private let skipTypes: Set<String> = [
    "cover", "titlepage", "halftitlepage", "halftitle", "title-page", "copyright-page", "copyright", "toc",
    "doc-toc", "index", "doc-index", "colophon", "doc-colophon", "imprint", "dedication", "doc-dedication",
    "epigraph", "doc-epigraph", "acknowledgments", "acknowledgements", "doc-acknowledgments", "loi", "lot",
    "other-credits", "doc-credits", "contributors", "seriespage", "frontispiece", "landmarks", "errata",
    "bibliography", "doc-bibliography", "glossary", "doc-glossary", "endnotes", "doc-endnotes", "rearnotes",
    "footnotes", "appendix", "doc-appendix", "ad", "advertisement", "teaser", "promo",
]
private let optionalTypes: Set<String> = [
    "preface", "foreword", "introduction", "afterword", "doc-preface", "doc-foreword", "doc-introduction",
    "doc-afterword", "conclusion", "doc-conclusion",
]
/// In a novel the prologue and epilogue are the story.
private let storyTypes: Set<String> = [
    "bodymatter", "chapter", "part", "doc-chapter", "doc-part", "text", "start", "volume", "division",
    "prologue", "epilogue", "doc-prologue", "doc-epilogue",
]
private let guideSkipTypes: Set<String> = [
    "cover", "title-page", "toc", "index", "glossary", "acknowledgements", "bibliography", "colophon",
    "copyright-page", "dedication", "epigraph", "loi", "lot", "notes", "other.ad", "other.backmatter",
]
private let guideOptionalTypes: Set<String> = ["foreword", "preface"]

/// Whole-title matches: "Notes" is back matter, "Notes from Underground" is
/// not. Then a prefix rule for titles that name a book after them.
private let skipTitle = try! NSRegularExpression(
    pattern: "(?i)^((table of )?contents|copyright( page)?|acknowledge?ments?|dedication|index|"
        + "(half[- ])?title( page)?|cover|bibliography|notes|endnotes|footnotes|glossary|credits|imprint|"
        + "colophon|maps?|newsletter|preview|coming soon|list of (illustrations|figures|tables|maps)|"
        + "(about|meet) the (author|authors|publisher|illustrator)s?)[\\s.:!]*$"
        + "|^(also by|(other )?books by|praise for|(an )?invitation from|by the same author|excerpt from|"
        + "sneak peek|a sneak peek|reading group|discussion (questions|guide)|if you enjoyed|keep reading|"
        + "don't miss)\\b")
private let optionalTitle = try! NSRegularExpression(
    pattern: "(?i)^(preface|foreword|introduction|afterword|author'?s note|a note (on|from)|note on the text|translator)")
private let publisherWords = try! NSRegularExpression(
    pattern: "(?i)copyright|all rights reserved|\\bisbn\\b|also by|published by|first published|printed in|"
        + "cataloging|library of congress|find us on|follow us|sign up|newsletter|we hope you enjoyed")

private func named(_ types: Set<String>) -> String {
    types.sorted().map { $0.replacingOccurrences(of: "doc-", with: "").replacingOccurrences(of: "-", with: " ") }
        .joined(separator: ", ")
}

/// Rules 1 to 9 of §3.5, for one item on its own. The first that matches
/// wins, and the order is measured, not arbitrary: a chapter tag comes before
/// the skip tags because publishers mis-tag — one real book called every
/// chapter `acknowledgments`.
func classifySpineItem(_ facts: SpineFacts) -> Classification {
    if !facts.linear {
        return Classification(kind: .skip, rule: .notLinear, reason: "not part of the reading order")
    }
    if facts.isNavigation {
        return Classification(kind: .skip, rule: .navigationDocument, reason: "the book's table of contents")
    }
    if !facts.bodyTypes.isDisjoint(with: chapterTypes) {
        return Classification(kind: .story, rule: .taggedChapter, reason: "marked as a chapter")
    }
    let tagged = facts.bodyTypes.union(facts.landmarkTypes)
    if !tagged.isDisjoint(with: skipTypes) {
        return Classification(
            kind: .skip, rule: .taggedSkip, reason: "marked as " + named(tagged.intersection(skipTypes)))
    }
    if !tagged.isDisjoint(with: optionalTypes) {
        return Classification(
            kind: .optional, rule: .taggedOptional, reason: "marked as " + named(tagged.intersection(optionalTypes)))
    }
    if !facts.guideTypes.isDisjoint(with: guideSkipTypes) {
        return Classification(
            kind: .skip, rule: .guideSkip,
            reason: "listed by the book as " + named(facts.guideTypes.intersection(guideSkipTypes)))
    }
    if !facts.guideTypes.isDisjoint(with: guideOptionalTypes) {
        return Classification(
            kind: .optional, rule: .guideOptional,
            reason: "listed by the book as " + named(facts.guideTypes.intersection(guideOptionalTypes)))
    }
    if facts.isGutenbergLicence {
        return Classification(kind: .skip, rule: .gutenbergLicence, reason: "Project Gutenberg's licence")
    }
    if !tagged.isDisjoint(with: storyTypes) {
        return Classification(kind: .story, rule: .taggedStory, reason: "marked as the story")
    }
    let title = facts.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if matches(skipTitle, title) {
        return Classification(kind: .skip, rule: .titleSkip, reason: "titled “\(title)”")
    }
    if matches(optionalTitle, title) {
        return Classification(kind: .optional, rule: .titleOptional, reason: "titled “\(title)”")
    }
    if facts.characters < 200 {
        return Classification(kind: .skip, rule: .tooShort, reason: "too short to be a chapter")
    }
    if facts.linkCharacters * 2 > facts.characters {
        return Classification(kind: .skip, rule: .mostlyLinks, reason: "looks like a table of contents")
    }
    if facts.characters < 3_000, matches(publisherWords, String(facts.head.prefix(300))) {
        return Classification(kind: .skip, rule: .publisherWords, reason: "looks like publisher matter")
    }
    return Classification(kind: .story, rule: .defaultStory, reason: "part of the story")
}

/// Rules 10 and 11, which need the whole spine: they only ever move an item
/// that no tag, title or fallback decided, and only from story to optional.
///
/// - `bodyStart`: the spine index where a landmark or guide entry says the
///   text begins. Untagged items before it are front matter.
/// - Short pages before the first long chapter or after the last — under a
///   quarter of the median chapter — are front and back matter nobody tagged:
///   "Find out more", "MEET THE AUTHORS", a list of the author's other books.
func classifySequence(_ verdicts: [Classification], characters: [Int], bodyStart: Int?) -> [Classification] {
    var out = verdicts
    if let bodyStart {
        for index in out.indices where index < bodyStart && out[index].rule == .defaultStory {
            out[index] = Classification(
                kind: .optional, rule: .beforeBodyStart, reason: "before where the book says the story starts")
        }
    }
    let story = out.indices.filter { out[$0].kind == .story }
    guard story.count >= 4 else { return out }
    let lengths = story.map { characters[$0] }.sorted()
    let median = lengths[lengths.count / 2]
    let long = story.filter { characters[$0] * 2 >= median }
    guard let first = long.first, let last = long.last else { return out }
    for index in story where out[index].rule == .defaultStory && characters[index] * 4 < median {
        if index < first {
            out[index] = Classification(
                kind: .optional, rule: .shortPageBeforeStory, reason: "a short page before the story")
        } else if index > last {
            out[index] = Classification(
                kind: .optional, rule: .shortPageAfterStory, reason: "a short page after the story")
        }
    }
    return out
}
