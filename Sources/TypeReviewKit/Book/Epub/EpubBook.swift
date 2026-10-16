import Foundation

/// Reads an EPUB — a ZIP file, or the folder Apple Books keeps — into a draft
/// for the review sheet.
///
/// Every refusal is a `BookImportError` with its own message: copy-protected,
/// a picture-book layout, pages that are pictures, no text, or a file that is
/// broken in a named way.
public func readEpubBook(at url: URL) throws -> BookDraft {
    try readEpubContents(at: url).draft()
}

/// The same, from an archive already open. The tests build theirs in memory.
public func readEpubBook(_ archive: BookArchive, fallbackTitle: String) throws -> BookDraft {
    try readEpubContents(archive, fallbackTitle: fallbackTitle).draft()
}

/// An EPUB's parts before they are split into sentences: what the review
/// sheet's draft is made from, and what `make epub-corpus` measures, since
/// truncation and the raw blocks are gone once a draft exists.
public struct EpubContents: Sendable {
    public let title: String
    public let author: String
    public let sources: [ChapterSource]
    /// Data tables left out of story parts.
    public let tablesDropped: Int
    /// Reading-order files that could not be parsed, by name.
    public let unreadableFiles: [String]
    public let imagesSeen: Int

    public func draft() throws -> BookDraft {
        try makeDraft(
            title: title, author: author, sources: sources, tablesDropped: tablesDropped,
            unreadableFiles: unreadableFiles, imagesSeen: imagesSeen)
    }
}

public func readEpubContents(at url: URL) throws -> EpubContents {
    let archive: BookArchive
    do {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            archive = try FolderArchive(root: url)
        } else {
            archive = try ZipArchive(contentsOf: url)
        }
    } catch ArchiveError.tooLarge {
        throw BookImportError.tooLarge("larger than \(maxEpubBytes >> 20) MB")
    } catch let error as ArchiveError {
        throw BookImportError.unreadable(error.description)
    }
    let fallback = url.deletingPathExtension().lastPathComponent
    return try readEpubContents(archive, fallbackTitle: fallback)
}

public func readEpubContents(_ archive: BookArchive, fallbackTitle: String) throws -> EpubContents {
    let package: EpubPackage
    do {
        package = try readPackage(archive)
    } catch let error as EpubPackageError {
        throw BookImportError.unreadable(error.description)
    } catch let error as ArchiveError {
        throw BookImportError.unreadable(error.description)
    }
    if package.copyProtected { throw BookImportError.copyProtected }
    if package.fixedLayout { throw BookImportError.fixedLayout }

    let loaded = try loadSpineItems(package, from: archive)
    var items = loaded.items
    let sequenced = classifySequence(
        items.map(\.classification), characters: items.map(\.text.characters),
        bodyStart: bodyStartIndex(of: items, in: package))
    for index in items.indices { items[index].classification = sequenced[index] }

    // A data table left out of the story is worth a warning; one in an index
    // or the front matter is not.
    let tables = items.filter { $0.classification.kind == .story }.map(\.text.tablesDropped).reduce(0, +)
    let title = package.title.isEmpty ? fallbackTitle : package.title
    return EpubContents(
        title: title, author: package.creator, sources: chapterSources(items), tablesDropped: tables,
        unreadableFiles: loaded.unreadable, imagesSeen: loaded.images)
}

/// One readable spine file, classified on its own.
private struct ReadItem {
    /// Where it sits in the package's spine, counting the files that could
    /// not be read.
    let spineIndex: Int
    let path: String
    let text: ChapterText
    var classification: Classification
    let label: String
}

/// Parses and classifies every spine file. A file that does not parse is
/// named and left out; a read limit refuses the whole book.
private func loadSpineItems(
    _ package: EpubPackage, from archive: BookArchive
) throws -> (items: [ReadItem], unreadable: [String], images: Int) {
    var items: [ReadItem] = []
    var unreadable: [String] = []
    var images = 0
    for (spineIndex, spine) in package.spine.enumerated() {
        let document: XMLDocument
        do {
            document = try parseMarkup(try archive.read(spine.path))
        } catch let error as ArchiveError {
            // A limit is the book's problem, not one chapter's: a book that
            // inflates past the total is refused whole.
            if case .readLimitExceeded = error {
                throw BookImportError.tooLarge("its text inflates past \(maxArchiveReadBytes >> 20) MB")
            }
            unreadable.append(spine.path)
            continue
        } catch {
            unreadable.append(spine.path)
            continue
        }
        let text = chapterText(document)
        images += text.images
        let label = package.tableOfContentsLabels[spine.path] ?? ""
        items.append(
            ReadItem(
                spineIndex: spineIndex, path: spine.path, text: text,
                classification: classifySpineItem(spineFacts(spine, text: text, label: label, package: package)),
                label: label))
    }
    return (items, unreadable, images)
}

private func spineFacts(_ spine: SpineItem, text: ChapterText, label: String, package: EpubPackage) -> SpineFacts {
    let joined = text.blocks.flatMap(\.lines).joined(separator: " ")
    var facts = SpineFacts()
    facts.linear = spine.linear
    facts.isNavigation = spine.path == package.navigationPath || spine.path == package.ncxPath
    facts.bodyTypes = text.bodyTypes
    facts.landmarkTypes = package.landmarks[spine.path] ?? []
    facts.guideTypes = package.guide[spine.path] ?? []
    facts.characters = text.characters
    facts.linkCharacters = text.linkCharacters
    facts.head = String(joined.prefix(300))
    facts.isGutenbergLicence = isGutenbergLicence(joined, characters: text.characters)
    // The heading names the file even when an ornament or an epigraph
    // comes before it.
    facts.title = !label.isEmpty ? label
        : !text.firstHeading.isEmpty ? text.firstHeading : (text.blocks.first?.lines.first ?? "")
    return facts
}

/// The first readable item at or after where the book says its text begins.
/// Measured on spine positions, so a body-start file that could not be read
/// still marks the boundary for the files before it.
private func bodyStartIndex(of items: [ReadItem], in package: EpubPackage) -> Int? {
    guard let start = package.spine.firstIndex(where: { package.bodyStarts.contains($0.path) }) else { return nil }
    return items.firstIndex { $0.spineIndex >= start } ?? items.count
}

private func chapterSources(_ items: [ReadItem]) -> [ChapterSource] {
    items.enumerated().map { number, item in
        let blocks = repairBlocks(item.text.blocks, label: item.label).blocks
        let title = !item.label.isEmpty ? item.label
            : !item.text.firstHeading.isEmpty ? item.text.firstHeading : "Section \(number + 1)"
        return ChapterSource(
            title: title, kind: item.classification.kind, reason: item.classification.reason, blocks: blocks)
    }
}

/// A file that is Project Gutenberg's licence rather than the book: it names
/// the project near its top and carries the licence or the end marker, and is
/// not long enough to be the novel with a licence stuck on.
func isGutenbergLicence(_ text: String, characters: Int) -> Bool {
    guard characters < 40_000, let range = text.range(of: "Project Gutenberg", options: .caseInsensitive) else {
        return false
    }
    let nearTop = text.distance(from: text.startIndex, to: range.lowerBound) < 2_000
    let licence = text.range(of: "License", options: .caseInsensitive) != nil
        || text.range(of: "*** END OF", options: .caseInsensitive) != nil
    return nearTop && licence && !holdsWholeBook(text)
}

/// Project Gutenberg's markers, in the forms `repairBlocks` cuts on: with or
/// without the stars, "THE" or "THIS", and the older "End of Project
/// Gutenberg's …". The start marker takes the rest of its line, to the
/// closing stars when there are any.
private let gutenbergStart = try! NSRegularExpression(
    pattern: "START OF TH[A-Z]*\\s+PROJECT GUTENBERG(?:[^*]{0,200}\\*{3})?", options: [.caseInsensitive])
private let gutenbergEnd = try! NSRegularExpression(
    pattern: "(?:\\*{3}\\s*)?END OF (?:TH[A-Z]*\\s+)?PROJECT GUTENBERG", options: [.caseInsensitive])

/// A file with both of Project Gutenberg's markers and a story between them:
/// a short book in one file, whose header and licence `repairBlocks` cuts.
private func holdsWholeBook(_ text: String) -> Bool {
    let ns = text as NSString
    guard let start = gutenbergStart.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
        return false
    }
    let after = NSMaxRange(start.range)
    guard let end = gutenbergEnd.firstMatch(in: text, range: NSRange(location: after, length: ns.length - after))
    else { return false }
    let story = ns.substring(with: NSRange(location: after, length: end.range.location - after))
    return story.trimmingCharacters(in: .whitespacesAndNewlines).count >= 200
}
