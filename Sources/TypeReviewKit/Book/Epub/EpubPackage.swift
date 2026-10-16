import Foundation

/// Why a package could not be understood.
public enum EpubPackageError: Error, Equatable, CustomStringConvertible {
    case noContainer
    case noPackageFile
    case packageUnreadable
    case noSpine
    case hrefEscapes(String)

    public var description: String {
        switch self {
        case .noContainer: return "it has no META-INF/container.xml"
        case .noPackageFile: return "its container names no package file"
        case .packageUnreadable: return "its package file cannot be read"
        case .noSpine: return "it lists no reading order"
        case .hrefEscapes(let href): return "it points outside itself: \(href)"
        }
    }
}

struct ManifestItem {
    let id: String
    let path: String
    let mediaType: String
    let properties: Set<String>
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

/// Resolves an href against a folder inside the archive, dropping its
/// fragment and decoding percent escapes. An href that climbs out of the
/// archive, or names another scheme, is refused rather than clamped.
func resolveHref(_ href: String, base: String) throws -> String {
    var path = href
    if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
    path = path.removingPercentEncoding ?? path
    if path.isEmpty { return "" }
    if path.contains("://") || path.hasPrefix("mailto:") { throw EpubPackageError.hrefEscapes(href) }
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

func readPackage(_ archive: BookArchive) throws -> EpubPackage {
    guard archive.contains("META-INF/container.xml"),
        let containerData = try? archive.read("META-INF/container.xml"),
        let container = try? xmlDocument(containerData)
    else { throw EpubPackageError.noContainer }
    let rootfiles = descendants(container, named: "rootfile")
    guard
        let rootfile = rootfiles.first(where: { attribute($0, "media-type") == "application/oebps-package+xml" })
            ?? rootfiles.first,
        let packagePath = attribute(rootfile, "full-path"), isSafeArchiveName(packagePath)
    else { throw EpubPackageError.noPackageFile }
    guard let packageData = try? archive.read(packagePath), let opf = try? xmlDocument(packageData) else {
        throw EpubPackageError.packageUnreadable
    }
    let base = folder(of: packagePath)

    var package = EpubPackage()
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

    var items: [String: ManifestItem] = [:]
    for element in descendants(opf, named: "item") {
        guard let id = attribute(element, "id"), let href = attribute(element, "href") else { continue }
        // EPUB 3 allows remote resources — a web font, a stylesheet. They are
        // never read, so they are passed over; a *relative* href that climbs
        // out of the archive is what is refused.
        if href.contains("://") { continue }
        let path = try resolveHref(href, base: base)
        let properties = Set((attribute(element, "properties") ?? "").split(separator: " ").map(String.init))
        let item = ManifestItem(
            id: id, path: path, mediaType: attribute(element, "media-type") ?? "", properties: properties)
        items[id] = item
        if properties.contains("nav") { package.navigationPath = path }
    }
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
    guard !package.spine.isEmpty else { throw EpubPackageError.noSpine }

    for reference in descendants(opf, named: "reference") {
        guard let type = attribute(reference, "type"), let href = attribute(reference, "href"),
            let path = try? resolveHref(href, base: base)
        else { continue }
        let kind = type.lowercased()
        package.guide[path, default: []].insert(kind)
        if kind == "text" || kind == "start" { package.bodyStarts.insert(path) }
    }

    // EPUB 3 navigation: chapter names and landmarks. Never typed.
    if let navigation = package.navigationPath, let data = try? archive.read(navigation),
        let document = try? parseMarkup(data)
    {
        let navigationBase = folder(of: navigation)
        for nav in descendants(document, named: "nav") {
            let types = structuralTypes(nav)
            for link in descendants(nav, named: "a") {
                guard let href = attribute(link, "href"), let path = try? resolveHref(href, base: navigationBase)
                else { continue }
                if types.contains("landmarks") {
                    for type in structuralTypes(link) {
                        package.landmarks[path, default: []].insert(type)
                        if ["bodymatter", "text", "start"].contains(type) { package.bodyStarts.insert(path) }
                    }
                } else if types.contains("toc"), package.tableOfContentsLabels[path] == nil {
                    package.tableOfContentsLabels[path] = trimmedText(link)
                }
            }
        }
    }
    // EPUB 2 navigation, for the names the EPUB 3 nav did not give.
    if let ncx = package.ncxPath, let data = try? archive.read(ncx), let document = try? xmlDocument(data) {
        let ncxBase = folder(of: ncx)
        for point in descendants(document, named: "navpoint") {
            guard let content = descendants(point, named: "content").first, let source = attribute(content, "src"),
                let path = try? resolveHref(source, base: ncxBase), package.tableOfContentsLabels[path] == nil
            else { continue }
            package.tableOfContentsLabels[path] = trimmedText(descendants(point, named: "text").first)
        }
    }

    // Protection. Apple's FairPlay leaves `sinf.xml`, Adobe's `rights.xml`.
    // `encryption.xml` alone is not enough to refuse: only an encrypted
    // reading-order document makes the text unreadable.
    if archive.contains("META-INF/sinf.xml") || archive.contains("META-INF/rights.xml") {
        package.copyProtected = true
    }
    if let data = try? archive.read("META-INF/encryption.xml"), let document = try? xmlDocument(data) {
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
    return package
}
