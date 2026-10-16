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

    struct Item {
        let path: String
        let text: ChapterText
        var classification: Classification
        let label: String
    }
    var items: [Item] = []
    var unreadable: [String] = []
    var images = 0
    for spine in package.spine {
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
        let joined = text.blocks.flatMap(\.lines).joined(separator: " ")
        let label = package.tableOfContentsLabels[spine.path] ?? ""
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
        facts.title = label.isEmpty ? (text.blocks.first?.lines.first ?? "") : label
        items.append(
            Item(path: spine.path, text: text, classification: classifySpineItem(facts), label: label))
    }

    let bodyStart = package.spine.firstIndex { package.bodyStarts.contains($0.path) }
        .flatMap { start in items.firstIndex { $0.path == package.spine[start].path } }
    let sequenced = classifySequence(
        items.map(\.classification), characters: items.map(\.text.characters), bodyStart: bodyStart)
    for index in items.indices { items[index].classification = sequenced[index] }

    // A data table left out of the story is worth a warning; one in an index
    // or the front matter is not.
    let tables = items.filter { $0.classification.kind == .story }.map(\.text.tablesDropped).reduce(0, +)
    var sources: [ChapterSource] = []
    for (number, item) in items.enumerated() {
        let blocks = repairBlocks(item.text.blocks, label: item.label).blocks
        let title = !item.label.isEmpty ? item.label
            : !item.text.firstHeading.isEmpty ? item.text.firstHeading : "Section \(number + 1)"
        sources.append(
            ChapterSource(
                title: title, kind: item.classification.kind, reason: item.classification.reason, blocks: blocks))
    }
    let title = package.title.isEmpty ? fallbackTitle : package.title
    return EpubContents(
        title: title, author: package.creator, sources: sources, tablesDropped: tables,
        unreadableFiles: unreadable, imagesSeen: images)
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
    return nearTop && licence
}
