import Foundation

// MARK: - XML helpers

/// Parses XML with external entities off: an EPUB is untrusted input, and
/// nothing in one needs a DTD loaded. Whitespace is preserved, or the space
/// between `<i>word</i> <b>next</b>` is dropped and the two words join.
func xmlDocument(_ data: Data) throws -> XMLDocument {
    try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace])
}

func localName(_ node: XMLNode) -> String { (node.localName ?? node.name ?? "").lowercased() }

/// Every element under `node` with this local name, in document order.
func descendants(_ node: XMLNode, named name: String) -> [XMLElement] {
    var out: [XMLElement] = []
    func visit(_ current: XMLNode) {
        if let element = current as? XMLElement, localName(element) == name { out.append(element) }
        for child in current.children ?? [] { visit(child) }
    }
    visit(node)
    return out
}

/// An attribute by local name, whatever its prefix.
func attribute(_ element: XMLElement, _ name: String) -> String? {
    for item in element.attributes ?? [] where localName(item) == name { return item.stringValue }
    return nil
}

/// `epub:type` tokens and ARIA roles, lower-cased, prefixes removed.
///
/// Only a *prefixed* attribute named `type` counts, so `<style type=…>` and
/// `<link type=…>` are not mistaken for one.
func structuralTypes(_ element: XMLElement) -> Set<String> {
    var types = Set<String>()
    for item in element.attributes ?? [] where localName(item) == "type" && (item.name ?? "").contains(":") {
        for token in (item.stringValue ?? "").split(whereSeparator: \.isWhitespace) {
            types.insert(String(token.split(separator: ":").last ?? token).lowercased())
        }
    }
    if let role = attribute(element, "role") {
        for token in role.split(whereSeparator: \.isWhitespace) { types.insert(token.lowercased()) }
    }
    return types
}

/// Runs of whitespace as one space, trimmed. A no-break space counts, and
/// so does the stand-in `keepSpaces` writes.
func collapseWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace || $0 == keptSpace }).joined(separator: " ")
}

/// What `keepSpaces` puts where a space between two tags was: a character
/// from the private-use area, which no book text should hold and cleaning
/// would drop if one did.
let keptSpace: Character = "\u{E000}"

private let spaceBetweenTags = try! NSRegularExpression(pattern: ">[ \\t\\r\\n]+<")

/// Keeps the space between two inline elements.
///
/// `XMLDocument` with `.nodePreserveWhitespace` keeps a whitespace-only text
/// node in the tree — `xmlString` writes it back — but `children` does not
/// return it, so `<b>she</b> <em>said</em>` walks as "shesaid". The space
/// is swapped for a character that is not whitespace before parsing, and the
/// walk turns it back into a space.
///
/// Only inside the root element: text before or after it is not
/// well-formed, and the space after `<?xml …?>` would become some.
func keepSpaces(_ text: String) -> String {
    let source = text as NSString
    let rootStart = source.range(of: "<[A-Za-z]", options: .regularExpression)
    let rootEnd = source.range(of: "</", options: .backwards)
    guard rootStart.location != NSNotFound, rootEnd.location != NSNotFound, rootEnd.location > rootStart.location
    else { return text }
    return spaceBetweenTags.stringByReplacingMatches(
        in: text, range: NSRange(location: rootStart.location, length: rootEnd.location + 1 - rootStart.location),
        withTemplate: ">\u{E000}<")
}

/// A node's text, with kept spaces as spaces.
func textOf(_ node: XMLNode) -> String {
    (node.stringValue ?? "").replacingOccurrences(of: String(keptSpace), with: " ")
}

// MARK: - Entities

/// Why a chapter file could not be read.
public enum MarkupError: Error, Equatable {
    /// An entity the pre-pass does not know. Named, so it can be added.
    case unknownEntity(String)
    case unparseable
}

private let namedEntity = try! NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]{0,31});")
private let xmlPredefinedEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

/// Replaces HTML named entities with numeric references before parsing.
///
/// Needed, and for a worse reason than a parse error. EPUB 2 files use
/// `&nbsp;`, `&mdash;`, `&rsquo;`. XML declares none of them, and when the
/// file names the XHTML DTD — the normal EPUB 2 header — the parser does not
/// fail on them: it deletes them, without a word. `a&nbsp;b&mdash;c` parses
/// as `abc`. That glued words together and lost dashes and apostrophes in 353
/// of 2,664 books measured. As numeric references they parse as themselves.
///
/// Then the assertion: if any named entity other than XML's five remains, the
/// document is refused by name rather than handed to the parser, so the
/// silent path cannot be reached at all.
///
/// The table is generated:
/// `python3 -I -c 'from html.entities import name2codepoint'`, minus the five.
func entityPrePass(_ text: String) throws -> String {
    let source = text as NSString
    let out = NSMutableString()
    var last = 0
    for match in namedEntity.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        let name = source.substring(with: match.range(at: 1))
        if xmlPredefinedEntities.contains(name) { continue }
        guard let codePoint = htmlEntityCodePoints[name] else { throw MarkupError.unknownEntity(name) }
        out.append(source.substring(with: NSRange(location: last, length: match.range.location - last)))
        out.append("&#\(codePoint);")
        last = match.range.location + match.range.length
    }
    out.append(source.substring(from: last))
    let result = out as String
    // The assertion, checked on the output rather than trusted from the loop.
    for match in namedEntity.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length)) {
        let name = (result as NSString).substring(with: match.range(at: 1))
        if !xmlPredefinedEntities.contains(name) { throw MarkupError.unknownEntity(name) }
    }
    return result
}

/// A chapter file as a tree: strict XML after the pre-pass, then tidied HTML
/// for files that are HTML rather than XHTML. Ten measured books needed the
/// fallback; nine had files that parsed neither way, and those throw.
func parseMarkup(_ data: Data) throws -> XMLDocument {
    guard let text = String(data: data, encoding: .utf8) else {
        // Not UTF-8: let the parser honour the declared encoding. Two
        // measured books; no pre-pass is possible without decoding first.
        if let document = try? xmlDocument(data) { return document }
        if let document = try? XMLDocument(data: data, options: [.documentTidyHTML, .nodePreserveWhitespace]) {
            return document
        }
        throw MarkupError.unparseable
    }
    let fixed = Data(keepSpaces(try entityPrePass(text)).utf8)
    if let document = try? xmlDocument(fixed) { return document }
    if let document = try? XMLDocument(data: fixed, options: [.documentTidyHTML, .nodePreserveWhitespace]) {
        return document
    }
    throw MarkupError.unparseable
}

// MARK: - Blocks

/// What one chapter file yielded, and what was taken out of it.
struct ChapterText {
    var blocks: [BookBlock] = []
    /// Types on the body and its top-level containers: what the file is.
    var bodyTypes = Set<String>()
    /// Non-space characters of text, and how many of them sat inside links.
    var characters = 0
    var linkCharacters = 0
    var firstHeading = ""
    var images = 0
    /// Data tables left out. Layout tables are read, and not counted.
    var tablesDropped = 0
    var layoutTables = false
    var noteMarkers = 0
    var noteBodies = 0
    var pageBreaks = 0
    var navigationParagraphs = 0
    var dropCaps = 0
    var hidden = 0
}

private let skippedElements: Set<String> = [
    "script", "style", "head", "title", "math", "svg", "noscript", "object", "audio", "video", "iframe",
    "figcaption", "template", "button", "select", "textarea",
]
private let blockElements: Set<String> = [
    "p", "div", "li", "blockquote", "section", "article", "header", "footer", "main", "aside", "dt", "dd", "pre",
    "tr", "td", "th", "ul", "ol", "dl", "body", "center", "address", "figure", "hgroup",
]
private let headingElements: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
private let noteMarkerTypes: Set<String> = [
    "noteref", "doc-noteref", "biblioref", "doc-biblioref", "glossref", "doc-glossref",
]
private let noteBodyTypes: Set<String> = [
    "footnote", "endnote", "rearnote", "note", "footnotes", "endnotes", "rearnotes", "doc-footnote", "doc-endnote",
    "doc-endnotes", "doc-footnotes", "doc-backlink", "backlink",
]
private let pageBreakTypes: Set<String> = ["pagebreak", "doc-pagebreak", "page-list", "doc-pagelist"]
private let titleTypes: Set<String> = ["title", "subtitle", "label", "ordinal", "bridgehead"]
private let verseTypes: Set<String> = ["poem", "verse", "song", "lyrics", "hymn"]
private let noteMarker = try! NSRegularExpression(
    pattern: "^\\s*[\\[(]?\\s*(\\d{1,4}|[*†‡§]+|[ivxlc]{1,6})\\s*[\\])]?\\s*$")
private let sceneBreakText = try! NSRegularExpression(pattern: "^[\\s*·•#~—–\\-_.oO◊❧☙⁂✻✽❦]+$")
private let verseClass = try! NSRegularExpression(pattern: "(?i)poem|verse|stanza|song|lyric|poetry|lines?-?group")
private let noteClass = try! NSRegularExpression(
    pattern: "(?i)(^|[^a-z])(foot|end|side)-?notes?([^a-z]|$)|footnote-content")
private let dropCapClass = try! NSRegularExpression(pattern: "(?i)drop|initial|first-?letter|big-?cap|lettrine")

func isNoteMarker(_ text: String) -> Bool { matches(noteMarker, text) }

/// A line of asterisks, dots or a dingbat: a scene break, not a sentence.
func isSceneBreakText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.count <= 40 else { return false }
    // "o" alone, or "O", is a word in verse ("O Captain"), not an ornament.
    if trimmed.count < 3 && trimmed.allSatisfy({ $0 == "o" || $0 == "O" || $0 == " " }) { return false }
    return matches(sceneBreakText, trimmed)
}

/// Reads one chapter file into blocks, dropping everything §3.4 lists.
///
/// `readLayoutTables` is the second pass: a table holding most of a file's
/// text is page layout — PDF conversions set every page as one — and
/// dropping it emptied *Gödel, Escher, Bach* entirely on the first probe run.
func chapterText(_ document: XMLDocument, readLayoutTables: Bool = false) -> ChapterText {
    var x = ChapterText()
    var lines: [String] = [""]
    var kind: BookBlockKind = .paragraph
    var inVerse = false
    var blockCharacters = 0
    var blockLinkCharacters = 0
    var eatSpace = false

    func flush() {
        let cleaned = lines.map(collapseWhitespace).filter { !$0.isEmpty }
        lines = [""]
        let allLink = blockCharacters > 0 && blockLinkCharacters == blockCharacters
        blockCharacters = 0
        blockLinkCharacters = 0
        defer { kind = .paragraph }
        guard !cleaned.isEmpty else { return }
        // A paragraph that is nothing but a link is navigation: "Contents",
        // "Start Reading", a note's way back.
        if allLink && kind != .heading {
            x.navigationParagraphs += 1
            return
        }
        if kind == .heading {
            let title = cleaned.joined(separator: " ")
            if x.firstHeading.isEmpty { x.firstHeading = title }
            x.blocks.append(.heading(title))
        } else if cleaned.count == 1, isSceneBreakText(cleaned[0]) {
            x.blocks.append(.sceneBreak)
        } else if inVerse {
            // Line breaks are kept only where the markup says verse. The
            // first rule — two or more short lines — turned every hard-wrapped
            // prose paragraph into verse.
            x.blocks.append(BookBlock(kind: .verse, lines: cleaned))
        } else {
            x.blocks.append(.paragraph(cleaned.joined(separator: " ")))
        }
    }

    func walk(_ node: XMLNode, inLink: Bool, depth: Int, heading: Bool) {
        if node.kind == .text {
            var text = textOf(node)
            if eatSpace {
                // The space after a drop cap may be a text node of its own.
                text = String(text.drop(while: \.isWhitespace))
                if text.isEmpty { return }
                eatSpace = false
            }
            lines[lines.count - 1] += text
            let count = text.filter { !$0.isWhitespace }.count
            x.characters += count
            blockCharacters += count
            if inLink {
                x.linkCharacters += count
                blockLinkCharacters += count
            }
            return
        }
        guard let element = node as? XMLElement else {
            for child in node.children ?? [] { walk(child, inLink: inLink, depth: depth, heading: heading) }
            return
        }
        let name = localName(element)
        let types = structuralTypes(element)
        let classes = attribute(element, "class") ?? ""
        // Only the body and its top-level containers say what the file is. A
        // footnotes section nested inside a chapter skipped the whole chapter
        // on the first probe run.
        if name == "body" || (depth == 1 && ["section", "article", "div", "main"].contains(name)) {
            x.bodyTypes.formUnion(types)
        }
        let childDepth = name == "body" ? 1 : (depth >= 1 ? depth + 1 : depth)

        if skippedElements.contains(name) || name == "nav" { return }
        if name == "img" || name == "image" {
            x.images += 1
            return
        }
        if name == "table" && !readLayoutTables {
            x.tablesDropped += 1
            return
        }
        if !types.isDisjoint(with: noteMarkerTypes) {
            x.noteMarkers += 1
            return
        }
        // By type or role, and by class: converters often mark notes by class
        // alone (`class="footnotes"`, `x13-BM-Endnotes`).
        if !types.isDisjoint(with: noteBodyTypes) || matches(noteClass, classes) {
            x.noteBodies += 1
            return
        }
        if !types.isDisjoint(with: pageBreakTypes) {
            x.pageBreaks += 1
            return
        }
        if attribute(element, "hidden") != nil || attribute(element, "aria-hidden") == "true" {
            x.hidden += 1
            return
        }
        let id = (attribute(element, "id") ?? "").lowercased()
        if id == "pg-header" || id == "pg-footer" || id == "pg-machine-header" { return }
        if name == "sup", isNoteMarker(textOf(element)) {
            x.noteMarkers += 1
            return
        }
        if name == "a", (attribute(element, "href") ?? "").contains("#"), isNoteMarker(textOf(element)) {
            x.noteMarkers += 1
            return
        }
        if name == "br" {
            lines.append("")
            return
        }
        if matches(dropCapClass, classes), case let letters = textOf(element), !letters.isEmpty, letters.count <= 2,
            letters.allSatisfy(\.isLetter)
        {
            // Sources write `<span class="dropcap">T</span> his`, with the
            // space after the span. It is the word's first letter.
            lines[lines.count - 1] += letters
            x.characters += letters.count
            blockCharacters += letters.count
            x.dropCaps += 1
            eatSpace = true
            return
        }
        if name == "hr" {
            flush()
            x.blocks.append(.sceneBreak)
            return
        }
        let verse = !types.isDisjoint(with: verseTypes) || matches(verseClass, classes)
        let wasVerse = inVerse
        if verse { inVerse = true }
        defer { inVerse = wasVerse }
        // A chapter's <header> or <hgroup> is title material: "Chapter 1"
        // above the h1 is a label, not a sentence.
        let isHeading = heading || headingElements.contains(name) || name == "header" || name == "hgroup"
            || !types.isDisjoint(with: titleTypes)
        if headingElements.contains(name) || blockElements.contains(name) {
            flush()
            if isHeading { kind = .heading }
            for child in element.children ?? [] {
                walk(child, inLink: inLink, depth: childDepth, heading: isHeading)
            }
            if isHeading { kind = .heading }
            flush()
            return
        }
        for child in element.children ?? [] {
            walk(child, inLink: inLink || (name == "a" && attribute(element, "href") != nil), depth: childDepth,
                 heading: heading)
        }
    }

    if let root = document.rootElement() { walk(root, inLink: false, depth: 0, heading: false) }
    flush()
    if !readLayoutTables && x.tablesDropped > 0 {
        let total = document.rootElement().map(textOf)?.filter { !$0.isWhitespace }.count ?? 0
        if total > 0 && x.characters * 10 < total * 3 {
            var layout = chapterText(document, readLayoutTables: true)
            layout.layoutTables = true
            return layout
        }
    }
    return x
}
