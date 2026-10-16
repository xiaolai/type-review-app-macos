import Foundation

// What both readers call a heading. One policy, because the plain-text reader
// and `repairBlocks` each had their own, and a line one of them kept as prose
// the other then took for a title and removed from the text.

private let numberWords =
    "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|"
    + "sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
private let ordinalWords =
    "first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|last"
/// A Roman numeral that is well formed, so "mild" and "did" are not one.
private let roman = "(?=[ivxlcdm])m{0,3}(?:cm|cd|d?c{0,3})(?:xc|xl|l?x{0,3})(?:ix|iv|v?i{0,3})"
/// What follows "Chapter": "4", "IV", "Two", "Twenty-one", "the First".
private let identifier =
    "(?:\\d{1,4}|\(roman)|(?:\(numberWords))(?:-(?:\(numberWords)))?|(?:the\\s+)?(?:\(ordinalWords)))"

/// "Chapter IV", then whatever follows. Group 1 is what follows; group 2 is
/// the mark that separates it, when there is one.
private let numberedHeading = try! NSRegularExpression(
    pattern: "^(?:chapter|book|part|volume)\\s+\(identifier)\\b(\\s*([.:\\-\\u2013\\u2014])?\\s*[^\\n]{0,70})$",
    options: [.caseInsensitive])
private let sectionLabel = try! NSRegularExpression(
    pattern: "^(?:prologue|epilogue)(?:\\s*[.:\\-\\u2013\\u2014]\\s*[^\\n]{0,70}|\\.)?$", options: [.caseInsensitive])
private let romanAlone = try! NSRegularExpression(pattern: "^\(roman)\\.?$", options: [.caseInsensitive])

/// How a line reads as a chapter heading.
enum HeadingShape {
    /// The label and its number, or a title set off by a mark: "Chapter 4.",
    /// "XII", "Chapter I. The Cyclone". Nothing else is shaped like that.
    case complete
    /// A title run on after the number with only a space: "Chapter Two The
    /// Cyclone". Also how the first printed line of "Book One Was the Best /
    /// of all the summers" reads, so what follows it decides.
    case runOn
}

/// "CHAPTER IV", "Chapter 4. The Cyclone", "BOOK TWO", a Roman numeral alone.
///
/// The word must be followed by what numbers it: "Part of me wanted to leave."
/// is a sentence. A title run on after the number with only a space between
/// must be cased as a title, or "Book one was the best." would be one.
func numberedHeadingShape(_ line: String) -> HeadingShape? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
    if matches(romanAlone, trimmed) { return .complete }
    let ns = trimmed as NSString
    guard let match = numberedHeading.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length))
    else { return nil }
    let rest = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    if rest.isEmpty || match.range(at: 2).location != NSNotFound { return .complete }
    return isTitleCased(rest) || isCapitalTitle(rest) ? .runOn : nil
}

func isNumberedChapterHeading(_ line: String) -> Bool { numberedHeadingShape(line) != nil }

/// A numbered heading's shape, or `.complete` for "Prologue" and "Epilogue".
func chapterHeadingShape(_ line: String) -> HeadingShape? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if let shape = numberedHeadingShape(trimmed) { return shape }
    return trimmed.count <= 80 && matches(sectionLabel, trimmed) ? .complete : nil
}

/// Words a title leaves in lower case.
private let minorWords: Set<String> = [
    "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "nor", "of", "on", "or", "the", "to",
    "with",
]

/// Every word but the minor ones capitalised: "Who Stole the Tarts?", "The
/// Boy Who Lived". Prose never is — "I saw Mary." has "saw".
func isTitleCased(_ text: String) -> Bool {
    let words = text.split(separator: " ").map { word in String(word.drop { !$0.isLetter && !$0.isNumber }) }
        .filter { !$0.isEmpty }
    guard !words.isEmpty else { return false }
    return words.enumerated().allSatisfy { index, word in
        word.first?.isUppercase == true || word.first?.isNumber == true
            || (index > 0 && minorWords.contains(word.lowercased()))
    }
}

/// A numbered heading, or "Prologue" and "Epilogue", which name a part of a
/// book without numbering it.
func isChapterHeading(_ line: String) -> Bool { chapterHeadingShape(line) != nil }

/// A short line in capitals: a chapter's title under its number, or a title
/// standing alone.
func isCapitalTitle(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count <= 60 else { return false }
    let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
    guard letters.count >= 3, letters.allSatisfy({ !CharacterSet.lowercaseLetters.contains($0) }) else {
        return false
    }
    // "HELP!" alone is somebody shouting, not a title. A title may end in a
    // full stop, which is why that one mark is not counted.
    return !(trimmed.hasSuffix("!") || trimmed.hasSuffix("?"))
}

/// A line printed under a chapter's number as its title: "The Cyclone",
/// "Who Stole the Tarts?", "DOWN THE RABBIT-HOLE". Whether it ends like a
/// sentence decides nothing: "I saw Mary." does, and a wrapped line of prose
/// does not; neither is cased as a title.
func isTitleLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }
    return isTitleCased(trimmed) || isCapitalTitle(trimmed)
}

/// Two printed lines of one paragraph, joined. A word broken across them keeps
/// its hyphen and loses the space; a dash ("--") is not a broken word.
func joinWrapped(_ before: String, _ after: String) -> String {
    before + wrapGlue(after: before) + after
}

func wrapGlue(after before: String) -> String {
    before.hasSuffix("-") && !before.hasSuffix("--") ? "" : " "
}
