import Foundation

/// Markdown to plain reading text.
///
/// Not a parser — a stripper. For typing practice the wanted thing is the
/// prose a reader sees, not the markup, and a full parser would be a
/// dependency and a lot of behaviour for a job that is a dozen substitutions.
///
/// **Rule order is the whole subtlety.** Images must go before links, or
/// `![alt](url)` becomes the word "alt" — text the document never contained.
/// Emphasis must run after the per-line markers, or a list bullet is mistaken
/// for an italic. Getting the order wrong produces output that looks fine and
/// is quietly missing or inventing words, which is why the vectors cover each
/// rule and the interactions between them.
public func parseMarkdown(_ input: String) -> String {
    var text = input

    // Fenced code: dropped whole. Typing a code fence means typing its
    // language tag and backticks, which is not prose practice.
    text = replace(text, pattern: "```[\\s\\S]*?```", with: " ")
    text = replace(text, pattern: "~~~[\\s\\S]*?~~~", with: " ")

    // Images BEFORE links. Alt text is metadata, not reading text.
    text = replace(text, pattern: "!\\[[^\\]]*\\]\\([^)]*\\)", with: " ")
    text = replace(text, pattern: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1")

    text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        var stripped = replace(String(line), pattern: "^\\s{0,3}>+\\s?", with: "")
        stripped = replace(stripped, pattern: "^\\s*[-*+]\\s+", with: "")
        stripped = replace(stripped, pattern: "^\\s{0,3}#{1,6}\\s+", with: "")
        // A horizontal rule carries no reading text at all.
        if matches(stripped, pattern: "^\\s*([-*_])\\1{2,}\\s*$") { return "" }
        return stripped
    }.joined(separator: "\n")

    text = replace(text, pattern: "(\\*\\*|__)(.*?)\\1", with: "$2")
    text = replace(text, pattern: "(\\*|_)(.*?)\\1", with: "$2")
    text = replace(text, pattern: "~~(.*?)~~", with: "$1")
    // Inline code keeps its contents: `map()` is worth typing.
    text = replace(text, pattern: "`+([^`]+)`+", with: "$1")
    text = replace(text, pattern: "<[^>]+>", with: "")

    return sanitize(text).text
}

private func replace(_ input: String, pattern: String, with template: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
    return regex.stringByReplacingMatches(
        in: input, range: NSRange(input.startIndex..., in: input), withTemplate: template)
}

private func matches(_ input: String, pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    return regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil
}

/// What kind of file the user handed us.
public enum LibraryFileKind: String, Sendable {
    case txt, md

    public init(filename: String) {
        self = filename.lowercased().hasSuffix(".md") || filename.lowercased().hasSuffix(".markdown")
            ? .md : .txt
    }
}

/// Turns an uploaded file's contents into practice text.
public func parseLibraryText(_ raw: String, kind: LibraryFileKind) -> String {
    switch kind {
    case .md: return parseMarkdown(raw)
    case .txt: return sanitize(raw).text
    }
}
