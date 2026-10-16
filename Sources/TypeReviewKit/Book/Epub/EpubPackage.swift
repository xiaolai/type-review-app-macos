import Foundation

/// Why a package could not be understood.
public enum EpubPackageError: Error, Equatable, CustomStringConvertible {
    case noContainer
    case noPackageFile
    case packageUnreadable
    case noSpine
    case hrefEscapes(String)
    case unsafeMarkup(String)

    public var description: String {
        switch self {
        case .noContainer: return "it has no META-INF/container.xml"
        case .noPackageFile: return "its container names no package file"
        case .packageUnreadable: return "its package file cannot be read"
        case .noSpine: return "it lists no reading order"
        case .hrefEscapes(let href): return "it points outside itself: \(href)"
        case .unsafeMarkup(let path): return "\(path) declares entities, which no book needs"
        }
    }
}

struct ManifestItem {
    let path: String
    let mediaType: String
}

struct SpineItem {
    let path: String
    let linear: Bool
}

/// What an EPUB's package says about the book, before any chapter is read.
struct EpubPackage {
    var title = ""
    var creator = ""
    /// As the package states it. Not trusted: on the books measured it said
    /// English for 211 that were not, so the language check reads the text.
    var declaredLanguage = ""
    var fixedLayout = false
    var spine: [SpineItem] = []
    var navigationPath: String?
    var ncxPath: String?
    /// EPUB 2 `<guide>` reference types, by file.
    var guide: [String: Set<String>] = [:]
    /// EPUB 3 nav `landmarks` types, by file.
    var landmarks: [String: Set<String>] = [:]
    /// What the table of contents calls each file.
    var tableOfContentsLabels: [String: String] = [:]
    /// Files where the text proper begins, by landmark or guide.
    var bodyStarts: Set<String> = []
    var copyProtected = false
}

/// A reference that names something outside the archive: any scheme —
/// `http:`, `data:`, `file:`, `mailto:` — or a network path starting `//`.
/// A URI scheme cannot be percent-encoded, so this reads the href as written.
func isExternalReference(_ href: String) -> Bool {
    if href.hasPrefix("//") { return true }
    guard let colon = href.firstIndex(of: ":") else { return false }
    let scheme = href[..<colon]
    guard let first = scheme.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first) else {
        return false
    }
    return scheme.unicodeScalars.allSatisfy {
        $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0))
    }
}

/// Resolves an href against a folder inside the archive, dropping its
/// fragment and decoding percent escapes. An href that climbs out of the
/// archive, or names another scheme, is refused rather than clamped.
func resolveHref(_ href: String, base: String) throws -> String {
    if isExternalReference(href) { throw EpubPackageError.hrefEscapes(href) }
    var path = href
    if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
    path = path.removingPercentEncoding ?? path
    if path.isEmpty { return "" }
    var parts: [Substring] = path.hasPrefix("/") ? [] : base.split(separator: "/")
    for component in path.split(separator: "/") {
        if component == "." { continue }
        if component == ".." {
            guard !parts.isEmpty else { throw EpubPackageError.hrefEscapes(href) }
            parts.removeLast()
        } else {
            parts.append(component)
        }
    }
    return parts.joined(separator: "/")
}

func folder(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
}

/// The two font-obfuscation algorithms. They use `encryption.xml` too, and
/// they are not DRM: twelve measured books carry them over perfectly readable
/// text, and refusing those would refuse good books.
private let fontObfuscation: Set<String> = [
    "http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC",
]

private func trimmedText(_ element: XMLElement?) -> String {
    collapseWhitespace(element?.stringValue ?? "")
}

/// Archive failures that say the book is built to exhaust the reader, not
/// that one file is damaged. These refuse the book wherever they happen.
private func isResourceLimit(_ error: ArchiveError) -> Bool {
    switch error {
    case .readLimitExceeded, .entryTooLarge, .suspiciousRatio: return true
    default: return false
    }
}

/// A package-level file as a tree, or nil when it is missing or does not
/// parse. One that declares entities refuses the whole book: these files
/// decide what the book is, and such a file is built to attack a parser.
/// A file that cannot be read is nil too, unless it hit a resource limit or
/// `required` is set — for a file whose absence would hide something, such
/// as the encryption list.
private func packageDocument(
    _ archive: BookArchive, _ path: String, markup: Bool = false, required: Bool = false
) throws -> XMLDocument? {
    guard archive.contains(path) else { return nil }
    let data: Data
    do {
        data = try archive.read(path)
    } catch let error as ArchiveError where !required && !isResourceLimit(error) {
        return nil
    }
    do {
        return markup ? try parseMarkup(data) : try xmlDocument(data)
    } catch MarkupError.entityDeclaration {
        throw EpubPackageError.unsafeMarkup(path)
    } catch {
        return nil
    }
}

func readPackage(_ archive: BookArchive) throws -> EpubPackage {
    guard let container = try packageDocument(archive, "META-INF/container.xml") else {
        throw EpubPackageError.noContainer
    }
    let rootfiles = descendants(container, named: "rootfile")
    guard
        let rootfile = rootfiles.first(where: { attribute($0, "media-type") == "application/oebps-package+xml" })
            ?? rootfiles.first,
        let packagePath = attribute(rootfile, "full-path"), isSafeArchiveName(packagePath)
    else { throw EpubPackageError.noPackageFile }
    guard let opf = try packageDocument(archive, packagePath) else { throw EpubPackageError.packageUnreadable }
    let base = folder(of: packagePath)

    var package = EpubPackage()
    readMetadata(opf, into: &package)
    let items = try readManifest(opf, base: base, into: &package)
    readSpine(opf, items: items, into: &package)
    guard !package.spine.isEmpty else { throw EpubPackageError.noSpine }
    readGuide(opf, base: base, into: &package)
    if let navigation = package.navigationPath, let document = try packageDocument(archive, navigation, markup: true) {
        readNavigation(document, base: folder(of: navigation), into: &package)
    }
    if let ncx = package.ncxPath, let document = try packageDocument(archive, ncx) {
        readNCX(document, base: folder(of: ncx), into: &package)
    }
    try readProtection(archive, into: &package)
    return package
}

private func readMetadata(_ opf: XMLDocument, into package: inout EpubPackage) {
    package.title = trimmedText(descendants(opf, named: "title").first)
    package.creator = trimmedText(descendants(opf, named: "creator").first)
    package.declaredLanguage = trimmedText(descendants(opf, named: "language").first)
    for meta in descendants(opf, named: "meta") {
        let content = attribute(meta, "content")
        if attribute(meta, "property") == "rendition:layout", trimmedText(meta) == "pre-paginated" {
            package.fixedLayout = true
        }
        // Kindle's and Apple's spellings of the same thing.
        if attribute(meta, "name") == "fixed-layout", content == "true" { package.fixedLayout = true }
        if attribute(meta, "name") == "book-type", content == "comic" { package.fixedLayout = true }
    }
}

/// The manifest's items by id. Notes the EPUB 3 navigation document.
private func readManifest(
    _ opf: XMLDocument, base: String, into package: inout EpubPackage
) throws -> [String: ManifestItem] {
    var items: [String: ManifestItem] = [:]
    for element in descendants(opf, named: "item") {
        guard let id = attribute(element, "id"), let href = attribute(element, "href") else { continue }
        // EPUB 3 allows remote resources — a web font, a stylesheet. They are
        // never read, so they are passed over; a *relative* href that climbs
        // out of the archive is what is refused.
        if isExternalReference(href) { continue }
        let path = try resolveHref(href, base: base)
        items[id] = ManifestItem(path: path, mediaType: attribute(element, "media-type") ?? "")
        let properties = (attribute(element, "properties") ?? "").split(separator: " ")
        if properties.contains("nav") { package.navigationPath = path }
    }
    return items
}

private func readSpine(_ opf: XMLDocument, items: [String: ManifestItem], into package: inout EpubPackage) {
    if let spine = descendants(opf, named: "spine").first {
        if let toc = attribute(spine, "toc"), let item = items[toc] { package.ncxPath = item.path }
        for reference in descendants(spine, named: "itemref") {
            guard let id = attribute(reference, "idref"), let item = items[id] else { continue }
            package.spine.append(SpineItem(path: item.path, linear: attribute(reference, "linear") != "no"))
        }
    }
    if package.ncxPath == nil {
        package.ncxPath = items.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" })?.path
    }
}

/// EPUB 2 `<guide>` references.
private func readGuide(_ opf: XMLDocument, base: String, into package: inout EpubPackage) {
    for reference in descendants(opf, named: "reference") {
        guard let type = attribute(reference, "type"), let href = attribute(reference, "href"),
            let path = try? resolveHref(href, base: base)
        else { continue }
        let kind = type.lowercased()
        package.guide[path, default: []].insert(kind)
        if kind == "text" || kind == "start" { package.bodyStarts.insert(path) }
    }
}

/// EPUB 3 navigation: chapter names and landmarks. Never typed.
private func readNavigation(_ document: XMLDocument, base: String, into package: inout EpubPackage) {
    for nav in descendants(document, named: "nav") {
        let types = structuralTypes(nav)
        let isLandmarks = types.contains("landmarks")
        guard isLandmarks || types.contains("toc") else { continue }
        for link in descendants(nav, named: "a") {
            guard let href = attribute(link, "href"), let path = try? resolveHref(href, base: base) else { continue }
            if isLandmarks {
                addLandmark(structuralTypes(link), path: path, into: &package)
            } else if package.tableOfContentsLabels[path] == nil {
                package.tableOfContentsLabels[path] = trimmedText(link)
            }
        }
    }
}

private func addLandmark(_ types: Set<String>, path: String, into package: inout EpubPackage) {
    guard !types.isEmpty else { return }
    package.landmarks[path, default: []].formUnion(types)
    if !types.isDisjoint(with: ["bodymatter", "text", "start"]) { package.bodyStarts.insert(path) }
}

/// EPUB 2 navigation, for the names the EPUB 3 nav did not give.
private func readNCX(_ document: XMLDocument, base: String, into package: inout EpubPackage) {
    for point in descendants(document, named: "navpoint") {
        guard let content = descendants(point, named: "content").first, let source = attribute(content, "src"),
            let path = try? resolveHref(source, base: base), package.tableOfContentsLabels[path] == nil
        else { continue }
        package.tableOfContentsLabels[path] = trimmedText(descendants(point, named: "text").first)
    }
}

/// Protection. Apple's FairPlay leaves `sinf.xml`, Adobe's `rights.xml`.
/// `encryption.xml` alone is not enough to refuse: only an encrypted
/// reading-order document makes the text unreadable. It is read as
/// required, because an encryption list that silently failed to read would
/// let a protected book through as readable.
private func readProtection(_ archive: BookArchive, into package: inout EpubPackage) throws {
    if archive.contains("META-INF/sinf.xml") || archive.contains("META-INF/rights.xml") {
        package.copyProtected = true
    }
    guard let document = try packageDocument(archive, "META-INF/encryption.xml", required: true) else { return }
    let spinePaths = Set(package.spine.map(\.path))
    for encrypted in descendants(document, named: "encrypteddata") {
        let algorithm = descendants(encrypted, named: "encryptionmethod").first
            .flatMap { attribute($0, "algorithm") } ?? ""
        guard !fontObfuscation.contains(algorithm) else { continue }
        let uri = descendants(encrypted, named: "cipherreference").first.flatMap { attribute($0, "uri") } ?? ""
        if let path = try? resolveHref(uri, base: ""), spinePaths.contains(path) {
            package.copyProtected = true
        }
    }
}
