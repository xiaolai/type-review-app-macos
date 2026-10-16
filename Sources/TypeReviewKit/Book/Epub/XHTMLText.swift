import Foundation

// MARK: - XML helpers

/// A package file — container, OPF, NCX, `encryption.xml` — as strict XML,
/// through the same guards as a chapter. See `parseDocument`.
func xmlDocument(_ data: Data) throws -> XMLDocument {
    try parseDocument(data, tidyFallback: false)
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
    /// The file declares entities or carries an internal DTD subset. No
    /// book needs either, and both are how a parser is attacked: an entity
    /// that expands a billion times, or one that reads a file off the disk.
    case entityDeclaration
    case unparseable
}

/// A reference to any name XML would accept — the Name production, with no
/// length cap — so no named reference reaches the parser unseen: each is
/// mapped to a number or refused.
private let namedEntity = try! NSRegularExpression(
    pattern: "&([:A-Z_a-z\\x{C0}-\\x{D6}\\x{D8}-\\x{F6}\\x{F8}-\\x{2FF}\\x{370}-\\x{37D}\\x{37F}-\\x{1FFF}"
        + "\\x{200C}-\\x{200D}\\x{2070}-\\x{218F}\\x{2C00}-\\x{2FEF}\\x{3001}-\\x{D7FF}\\x{F900}-\\x{FDCF}"
        + "\\x{FDF0}-\\x{FFFD}\\x{10000}-\\x{EFFFF}][-.0-9:A-Z_a-z\\x{B7}\\x{C0}-\\x{D6}\\x{D8}-\\x{F6}"
        + "\\x{F8}-\\x{37D}\\x{37F}-\\x{1FFF}\\x{200C}-\\x{200D}\\x{203F}-\\x{2040}\\x{2070}-\\x{218F}"
        + "\\x{2C00}-\\x{2FEF}\\x{3001}-\\x{D7FF}\\x{F900}-\\x{FDCF}\\x{FDF0}-\\x{FFFD}\\x{10000}-\\x{EFFFF}]*);")
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
    let out = NSMutableString()
    var last = 0
    let source = text as NSString
    for reference in references(in: text) {
        if xmlPredefinedEntities.contains(reference.name) { continue }
        guard let codePoint = htmlEntityCodePoints[reference.name] else {
            throw MarkupError.unknownEntity(reference.name)
        }
        out.append(source.substring(with: NSRange(location: last, length: reference.range.location - last)))
        out.append("&#\(codePoint);")
        last = NSMaxRange(reference.range)
    }
    out.append(source.substring(from: last))
    let result = out as String
    // The assertion, checked on the output rather than trusted from the loop.
    for reference in references(in: result) where !xmlPredefinedEntities.contains(reference.name) {
        throw MarkupError.unknownEntity(reference.name)
    }
    return result
}

/// Every named reference the parser would expand: those in comments, CDATA
/// sections and processing instructions are left alone, because the parser
/// reads them as written. `Use &nbsp; literally` in a CDATA section stays so.
private func references(in text: String) -> [(range: NSRange, name: String)] {
    let source = text as NSString
    let literal = literalRanges(text)
    var next = 0
    var out: [(range: NSRange, name: String)] = []
    for match in namedEntity.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        while next < literal.count, NSMaxRange(literal[next]) <= match.range.location { next += 1 }
        if next < literal.count, literal[next].location <= match.range.location { continue }
        out.append((match.range, source.substring(with: match.range(at: 1))))
    }
    return out
}

/// Where the parser expands no reference — comments, CDATA sections and
/// processing instructions — as UTF-16 ranges, in order.
///
/// Found by walking the markup, so a `<!--` inside a quoted attribute value
/// is not taken for a comment. One left open is not a range: the parser
/// refuses it, and whatever follows still gets the pre-pass.
func literalRanges(_ text: String) -> [NSRange] {
    let units = Array(text.utf16)
    let literals: [(open: [UInt16], close: [UInt16])] = [
        (Array("<!--".utf16), Array("-->".utf16)),
        (Array("<![CDATA[".utf16), Array("]]>".utf16)),
        (Array("<?".utf16), Array("?>".utf16)),
    ]
    func starts(_ prefix: [UInt16], at index: Int) -> Bool {
        index + prefix.count <= units.count && units[index..<index + prefix.count].elementsEqual(prefix)
    }
    /// The index just past the first `close` at or after `index`.
    func end(of close: [UInt16], from index: Int) -> Int? {
        var at = index
        while at + close.count <= units.count {
            if starts(close, at: at) { return at + close.count }
            at += 1
        }
        return nil
    }
    let lessThan = UInt16(UInt8(ascii: "<"))
    let greaterThan = UInt16(UInt8(ascii: ">"))
    let quotes: Set<UInt16> = [UInt16(UInt8(ascii: "\"")), UInt16(UInt8(ascii: "'"))]
    var ranges: [NSRange] = []
    var index = 0
    scan: while index < units.count {
        guard units[index] == lessThan else {
            index += 1
            continue
        }
        for literal in literals where starts(literal.open, at: index) {
            if let close = end(of: literal.close, from: index + literal.open.count) {
                ranges.append(NSRange(location: index, length: close - index))
                index = close
            } else {
                index += literal.open.count
            }
            continue scan
        }
        // A tag, or a declaration: to its `>`, past quoted values.
        index += 1
        var quote: UInt16?
        while index < units.count {
            let unit = units[index]
            index += 1
            if let open = quote {
                if unit == open { quote = nil }
            } else if quotes.contains(unit) {
                quote = unit
            } else if unit == greaterThan {
                break
            }
        }
    }
    return ranges
}

/// A chapter file as a tree: strict XML after the pre-pass, then tidied HTML
/// for files that are HTML rather than XHTML. Ten measured books needed the
/// fallback; nine had files that parsed neither way, and those throw.
func parseMarkup(_ data: Data) throws -> XMLDocument {
    try parseDocument(data, tidyFallback: true)
}

private let internalSubset = try! NSRegularExpression(pattern: "<!DOCTYPE[^>\\[]*\\[", options: [.caseInsensitive])
private let encodingDeclaration = try! NSRegularExpression(
    pattern: "^(\\s*<\\?xml[^>]*?encoding\\s*=\\s*)([\"'])([A-Za-z0-9._:-]+)\\2")

/// A markup file's bytes as text: UTF-8; UTF-16 by its byte-order mark or
/// its first `<`; the encoding its XML declaration names; Windows-1252.
///
/// Decoded here rather than by the parser so that the declaration check and
/// the entity pre-pass see every file, whatever its encoding. The XML
/// declaration is rewritten to say UTF-8, which is what the parser is given.
func decodeMarkup(_ data: Data) throws -> String {
    var text: String?
    let head = [UInt8](data.prefix(2))
    // UTF-16 first: without a mark, its NULs are valid UTF-8.
    if head.count == 2, (head[0] == 0xFF && head[1] == 0xFE) || (head[0] == 0xFE && head[1] == 0xFF) {
        text = String(data: data, encoding: .utf16)
    } else if head == [0x3C, 0x00] {
        text = String(data: data, encoding: .utf16LittleEndian)
    } else if head == [0x00, 0x3C] {
        text = String(data: data, encoding: .utf16BigEndian)
    } else if data.contains(0) {
        // UTF-32, or not text at all. No measured book used UTF-32, and a
        // NUL can end the parser's reading where this check's did not.
        throw MarkupError.unparseable
    } else if let utf8 = String(data: data, encoding: .utf8) {
        text = utf8
    } else {
        let start = String(decoding: data.prefix(256).map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
        let range = NSRange(location: 0, length: (start as NSString).length)
        if let match = encodingDeclaration.firstMatch(in: start, range: range) {
            let name = (start as NSString).substring(with: match.range(at: 3)) as CFString
            let encoding = CFStringConvertIANACharSetNameToEncoding(name)
            if encoding != kCFStringEncodingInvalidId {
                text = String(
                    data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)))
            }
        }
        if text == nil { text = String(data: data, encoding: .windowsCP1252) }
    }
    guard var decoded = text else { throw MarkupError.unparseable }
    if decoded.hasPrefix("\u{FEFF}") { decoded.removeFirst() }
    return encodingDeclaration.stringByReplacingMatches(
        in: decoded, range: NSRange(location: 0, length: (decoded as NSString).length), withTemplate: "$1$2UTF-8$2")
}

/// Refuses a file that declares entities or has an internal DTD subset.
///
/// The XHTML DTD named by its public identifier — the normal EPUB 2 header —
/// is allowed: it declares nothing in the file, and with external loading
/// off it is never read. Checked case-blind and anywhere in the file, a
/// comment included, so nothing the parser might honour is passed over.
func refuseEntityDeclarations(_ text: String) throws {
    if text.range(of: "<!ENTITY", options: .caseInsensitive) != nil || matches(internalSubset, text) {
        throw MarkupError.entityDeclaration
    }
}

/// The one place a document is parsed. Every file goes through all of it:
/// decoded, refused if it declares entities, the pre-pass, the kept spaces,
/// and a parser with external entities off — in the tidy fallback too.
func parseDocument(_ data: Data, tidyFallback: Bool) throws -> XMLDocument {
    let text = try decodeMarkup(data)
    try refuseEntityDeclarations(text)
    let fixed = Data(keepSpaces(try entityPrePass(text)).utf8)
    if let document = try? makeDocument(fixed, tidy: false) { return document }
    if tidyFallback, let document = try? makeDocument(fixed, tidy: true) { return document }
    throw MarkupError.unparseable
}

/// Never loads an external entity or DTD: an EPUB is untrusted input, and
/// nothing in one needs either. Whitespace is preserved, which `keepSpaces`
/// relies on.
func makeDocument(_ data: Data, tidy: Bool) throws -> XMLDocument {
    var options: XMLNode.Options = [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace]
    if tidy { options.insert(.documentTidyHTML) }
    return try XMLDocument(data: data, options: options)
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

/// The words of a class attribute, lower-cased: split at spaces, hyphens,
/// underscores, digits, and where lower case turns to upper, so
/// "poem-line2 stanzaFirst" is "poem", "line", "stanza", "first".
func classWords(_ classes: String) -> [String] {
    var words: [String] = []
    var current = ""
    var previousLower = false
    for character in classes {
        guard character.isLetter else {
            if !current.isEmpty { words.append(current) }
            current = ""
            previousLower = false
            continue
        }
        if character.isUppercase && previousLower {
            words.append(current)
            current = ""
        }
        current.append(character)
        previousLower = character.isLowercase
    }
    if !current.isEmpty { words.append(current) }
    return words.map { $0.lowercased() }
}

private let verseWords: Set<String> = [
    "poem", "poems", "poetry", "verse", "verses", "stanza", "stanzas", "song", "songs", "lyric", "lyrics",
    "linegroup", "linesgroup",
]

/// A class that names verse by one of its words — "poem", "stanza",
/// "line-group" — and not by letters inside another word: "reversed" and
/// "songbird" are not verse.
func isVerseClass(_ classes: String) -> Bool {
    let words = classWords(classes)
    if words.contains(where: verseWords.contains) { return true }
    return zip(words, words.dropFirst()).contains { verseWords.contains($0 + $1) }
}

/// Reads one chapter file into blocks, dropping everything §3.4 lists.
///
/// `readLayoutTables` is the second pass: a table holding most of a file's
/// text is page layout — PDF conversions set every page as one — and
/// dropping it emptied *Gödel, Escher, Bach* entirely on the first probe run.
///
/// "Most of a file's text" is measured by reading the file again with its
/// tables in, under the same rules, so text that is dropped either way — the
/// head, scripts, notes, hidden text — does not count toward the tables.
func chapterText(_ document: XMLDocument, readLayoutTables: Bool = false) -> ChapterText {
    let first = ChapterReader(readLayoutTables: readLayoutTables).read(document)
    guard !readLayoutTables, first.tablesDropped > 0 else { return first }
    var layout = ChapterReader(readLayoutTables: true).read(document)
    guard first.characters * 10 < layout.characters * 3 else { return first }
    layout.layoutTables = true
    return layout
}

/// The block being read: its lines, and where its characters came from.
private struct BlockBuffer {
    var lines: [String] = [""]
    var kind: BookBlockKind = .paragraph
    var characters = 0
    var linkCharacters = 0
    /// Characters inside an inline title: `<span epub:type="title">`.
    var titleCharacters = 0
    /// The same two counts line by line, so a title on the first lines of a
    /// paragraph can be told from the prose under it.
    var lineCharacters = [0]
    var lineTitleCharacters = [0]

    mutating func breakLine() {
        lines.append("")
        lineCharacters.append(0)
        lineTitleCharacters.append(0)
    }

    /// How many of the leading non-empty lines are nothing but an inline
    /// title: `<span epub:type="title">Chapter One</span><br/>It was…`.
    func titleLines(_ cleaned: [(text: String, characters: Int, title: Int)]) -> Int {
        cleaned.prefix { $0.characters > 0 && $0.title == $0.characters }.count
    }

    /// Nothing but a link: navigation.
    var isAllLink: Bool { characters > 0 && linkCharacters == characters }
    /// Nothing but an inline title: a heading.
    var isAllTitle: Bool { characters > 0 && titleCharacters == characters }
}

/// One walk of one chapter file. `chapterText` is its only user.
private final class ChapterReader {
    private let readLayoutTables: Bool
    private var x = ChapterText()
    private var block = BlockBuffer()
    private var inVerse = false
    private var eatSpace = false

    init(readLayoutTables: Bool) { self.readLayoutTables = readLayoutTables }

    func read(_ document: XMLDocument) -> ChapterText {
        if let root = document.rootElement() { walk(root, inLink: false, depth: 0, heading: false) }
        flush()
        return x
    }

    /// Adds text to the block being read, counting where it came from.
    private func append(_ text: String, inLink: Bool, title: Bool) {
        let last = block.lines.count - 1
        block.lines[last] += text
        let count = text.filter { !$0.isWhitespace }.count
        x.characters += count
        block.characters += count
        block.lineCharacters[last] += count
        if inLink {
            x.linkCharacters += count
            block.linkCharacters += count
        }
        if title {
            block.titleCharacters += count
            block.lineTitleCharacters[last] += count
        }
    }

    /// Ends the block being read, under the context it was read in.
    private func flush() {
        let finished = block
        block = BlockBuffer()
        let lines = zip(finished.lines, zip(finished.lineCharacters, finished.lineTitleCharacters))
            .map { (text: collapseWhitespace($0), characters: $1.0, title: $1.1) }
            .filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return }
        // A paragraph that is nothing but a link is navigation: "Contents",
        // "Start Reading", a note's way back.
        if finished.isAllLink && finished.kind != .heading {
            x.navigationParagraphs += 1
            return
        }
        // A paragraph that is nothing but an inline title is the chapter's
        // title: `<p><span epub:type="title">Chapter One</span></p>`.
        if finished.kind == .heading || finished.isAllTitle {
            addHeading(lines.map(\.text))
            return
        }
        // A title on the paragraph's first lines, broken from the prose
        // under it: the title is a heading, and the prose is still typed.
        let titled = finished.titleLines(lines)
        if titled > 0 {
            addHeading(lines.prefix(titled).map(\.text))
        }
        addBody(lines.dropFirst(titled).map(\.text))
    }

    private func addHeading(_ lines: [String]) {
        let title = lines.joined(separator: " ")
        if x.firstHeading.isEmpty { x.firstHeading = title }
        x.blocks.append(.heading(title))
    }

    /// A block's lines that are not a title, under the context they were
    /// read in.
    private func addBody(_ cleaned: [String]) {
        if cleaned.isEmpty {
            return
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

    /// Whether an element and everything in it is left out, counting it
    /// under what it is.
    private func isDropped(_ element: XMLElement, name: String, types: Set<String>, classes: String) -> Bool {
        guard let drop = dropKind(element, name: name, types: types, classes: classes, readLayoutTables: readLayoutTables)
        else { return false }
        switch drop {
        case .skipped: break
        case .image: x.images += 1
        case .table: x.tablesDropped += 1
        case .noteMarker: x.noteMarkers += 1
        case .noteBody: x.noteBodies += 1
        case .pageBreak: x.pageBreaks += 1
        case .hidden: x.hidden += 1
        }
        return true
    }

    private func walk(_ node: XMLNode, inLink: Bool, depth: Int, heading: Bool) {
        if node.kind == .text {
            var text = textOf(node)
            if eatSpace {
                // The space after a drop cap may be a text node of its own.
                text = String(text.drop(while: \.isWhitespace))
                if text.isEmpty { return }
                eatSpace = false
            }
            append(text, inLink: inLink, title: heading)
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

        if isDropped(element, name: name, types: types, classes: classes) { return }
        if name == "br" {
            block.breakLine()
            return
        }
        // A link's text is link text whether the link is the drop cap's own
        // element (`<a class="dropcap" href="x">Go</a>`) or holds it.
        let linkHere = inLink || (name == "a" && attribute(element, "href") != nil)
        if matches(dropCapClass, classes), case let letters = textOf(element), !letters.isEmpty, letters.count <= 2,
            letters.allSatisfy(\.isLetter)
        {
            // Sources write `<span class="dropcap">T</span> his`, with the
            // space after the span. It is the word's first letter, and it
            // counts like any other: inside a link, it is link text.
            append(letters, inLink: linkHere, title: heading)
            x.dropCaps += 1
            eatSpace = true
            return
        }
        if name == "hr" {
            flush()
            x.blocks.append(.sceneBreak)
            return
        }
        let isBlock = headingElements.contains(name) || blockElements.contains(name)
        // What came before a block is ended under its own context, before a
        // verse container can change it: prose above a poem stays prose.
        //
        // So does any element that turns verse on, block or not: an element
        // this reader does not know, `<details class="poem">`, read the
        // prose before it as verse.
        let wasVerse = inVerse
        let startsVerse = !inVerse && (!types.isDisjoint(with: verseTypes) || isVerseClass(classes))
        if isBlock || startsVerse { flush() }
        if startsVerse { inVerse = true }
        defer {
            // And verse read inside it ends as verse, before the context
            // goes back to prose.
            if startsVerse { flush() }
            inVerse = wasVerse
        }
        // A chapter's <header> or <hgroup> is title material: "Chapter 1"
        // above the h1 is a label, not a sentence. An inline title passes
        // that on to its text, and a paragraph holding only it is a heading.
        let isHeading = heading || headingElements.contains(name) || name == "header" || name == "hgroup"
            || !types.isDisjoint(with: titleTypes)
        if isBlock {
            if isHeading { block.kind = .heading }
            for child in element.children ?? [] {
                walk(child, inLink: inLink, depth: childDepth, heading: isHeading)
            }
            if isHeading { block.kind = .heading }
            flush()
            return
        }
        for child in element.children ?? [] {
            walk(child, inLink: linkHere, depth: childDepth, heading: isHeading)
        }
    }
}

/// A table that holds data rather than a page: one with a header cell, a
/// header row or a caption, or a grid of several short cells to a row.
///
/// A PDF conversion's page table has none of these — a cell or two to a row,
/// each holding a page or a column of text — so this never takes a page.
/// Tables nested inside are judged when the reader reaches them.
/// Why an element and everything in it is left out of a chapter's text.
enum DropKind {
    case skipped, image, table, noteMarker, noteBody, pageBreak, hidden
}

/// The reader's rules for what is left out, with no counting: the reader
/// counts what it drops, and `isDataTable` measures only what would be kept.
func dropKind(
    _ element: XMLElement, name: String, types: Set<String>, classes: String, readLayoutTables: Bool
) -> DropKind? {
    if skippedElements.contains(name) || name == "nav" { return .skipped }
    if name == "img" || name == "image" { return .image }
    // A table that says it holds data is left out even where tables are
    // layout: the fallback reads the page tables of a PDF conversion, not a
    // timetable that sits among them.
    if name == "table" && (!readLayoutTables || isDataTable(element)) { return .table }
    if !types.isDisjoint(with: noteMarkerTypes) { return .noteMarker }
    // By type or role, and by class: converters often mark notes by class
    // alone (`class="footnotes"`, `x13-BM-Endnotes`).
    if !types.isDisjoint(with: noteBodyTypes) || matches(noteClass, classes) { return .noteBody }
    if !types.isDisjoint(with: pageBreakTypes) { return .pageBreak }
    if attribute(element, "hidden") != nil || attribute(element, "aria-hidden") == "true" { return .hidden }
    let id = (attribute(element, "id") ?? "").lowercased()
    if id == "pg-header" || id == "pg-footer" || id == "pg-machine-header" { return .skipped }
    if name == "sup", isNoteMarker(textOf(element)) { return .noteMarker }
    if name == "a", (attribute(element, "href") ?? "").contains("#"), isNoteMarker(textOf(element)) {
        return .noteMarker
    }
    return nil
}

/// The text of a node the reader would keep: hidden text, scripts and notes
/// inside it are not counted.
private func keptText(_ node: XMLNode) -> String {
    if node.kind == .text { return textOf(node) }
    if let element = node as? XMLElement,
        dropKind(
            element, name: localName(element), types: structuralTypes(element),
            classes: attribute(element, "class") ?? "", readLayoutTables: true) != nil
    {
        return ""
    }
    return (node.children ?? []).map(keptText).joined()
}

func isDataTable(_ table: XMLElement) -> Bool {
    var header = false
    var rows = 0
    var cells: [Int] = []
    func visit(_ element: XMLElement) {
        let name = localName(element)
        if name == "table" && element !== table { return }
        if name == "th" || name == "thead" || name == "caption" { header = true }
        if name == "tr" { rows += 1 }
        // Measured on what would be kept: a hidden note in every cell made
        // a timetable's short cells look like a page's long ones.
        if name == "td" || name == "th" { cells.append(keptText(element).filter { !$0.isWhitespace }.count) }
        for case let child as XMLElement in element.children ?? [] { visit(child) }
    }
    visit(table)
    if header { return true }
    guard rows >= 2, cells.count >= rows * 2 else { return false }
    return cells.reduce(0, +) / cells.count < 40
}
