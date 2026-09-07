import AppKit
import Foundation

/// Checks the password-manager list in `AppPreferences.swift` against primary
/// sources, and says what has drifted.
///
/// Run with `make password-managers`. It reports; it does not rewrite. A
/// generator would be worse here for two reasons. The list is security
/// relevant, so every addition deserves a human look — and a generator that
/// silently produced an empty list because an API changed its shape would
/// leave a green build over no protection at all. A checker that cannot reach
/// its sources says so.
///
/// ## Where the evidence comes from
///
/// Two machine-readable sources, both of which state a bundle identifier
/// outright rather than describing it:
///
/// - the Mac App Store's lookup API, which returns `bundleId` per app;
/// - the Homebrew cask API, whose `quit:` and `zap trash:` stanzas name the
///   identifier so the uninstaller can find it.
///
/// Neither knows about Apple's own applications or the system's
/// authentication agents, so those are confirmed a third way: by asking this
/// Mac whether the identifier resolves to something installed.
///
/// ## The check that matters most
///
/// Not "is anything missing" but "is anything in the list unconfirmed". A
/// wrong identifier does not fail — it never matches, and goes on looking like
/// coverage. This list carried `com.lastpass.LastPass` for exactly that
/// reason; the real one is `com.lastpass.lastpassmacdesktop`.

// MARK: - What to look for

/// A manager, named the way a person would, with whatever handles the sources
/// know it by. Names are hand-maintained here because a name is stable and
/// checkable by eye; identifiers are not, which is the whole point of this
/// tool.
struct Manager {
    let name: String
    /// Homebrew cask token, when it has one.
    var cask: String?
    /// What to search the App Store for, when it is there.
    var appStore: String?
}

let managers: [Manager] = [
    Manager(name: "1Password", cask: "1password", appStore: "1Password"),
    Manager(name: "Bitwarden", cask: "bitwarden", appStore: "Bitwarden"),
    Manager(name: "LastPass", cask: "lastpass", appStore: "LastPass"),
    Manager(name: "Dashlane", cask: nil, appStore: "Dashlane"),
    Manager(name: "Keeper", cask: "keeper-password-manager", appStore: "Keeper password manager"),
    Manager(name: "NordPass", cask: "nordpass", appStore: "NordPass"),
    Manager(name: "Enpass", cask: "enpass", appStore: "Enpass"),
    Manager(name: "KeePassXC", cask: "keepassxc", appStore: nil),
    Manager(name: "MacPass", cask: "macpass", appStore: nil),
    Manager(name: "KeeWeb", cask: "keeweb", appStore: nil),
    Manager(name: "Strongbox", cask: nil, appStore: "Strongbox password"),
    Manager(name: "KeePassium", cask: nil, appStore: "KeePassium"),
    Manager(name: "Proton Pass", cask: "proton-pass", appStore: nil),
    Manager(name: "Buttercup", cask: "buttercup", appStore: nil),
    Manager(name: "RoboForm", cask: "roboform", appStore: "RoboForm"),
    Manager(name: "Secrets", cask: nil, appStore: "Secrets password manager"),
    Manager(name: "mSecure", cask: nil, appStore: "mSecure"),
    Manager(name: "SafeInCloud", cask: "safeincloud-password-manager", appStore: "SafeInCloud"),
    Manager(name: "Codebook", cask: nil, appStore: "Codebook password"),
    Manager(name: "pwSafe", cask: nil, appStore: "pwSafe"),
    Manager(name: "Passwarden", cask: nil, appStore: "Passwarden"),
    Manager(name: "2Stable Passwords", cask: nil, appStore: "2Stable password"),
    Manager(name: "Step Two", cask: nil, appStore: "Step Two authenticator"),
]

// MARK: - Fetching

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("password-managers: \(message)\n".utf8))
    exit(1)
}

/// Synchronous by design: this is a script, and the ceremony of an async main
/// buys nothing when the whole job is a few dozen sequential requests.
func fetch(_ url: URL) -> Data? {
    var result: Data?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: url) { data, _, _ in
        result = data
        done.signal()
    }.resume()
    // Long enough for a slow network, short enough that a hung request does
    // not hang the check.
    _ = done.wait(timeout: .now() + 30)
    return result
}

/// Whether a candidate string is plausibly an *application's* bundle identifier.
///
/// A cask blob is full of strings with exactly the identifier shape: download
/// hosts (`www.roboform.com`), version tags (`v2.28.1`), analytics caches
/// (`com.crashlytics.data`), app groups, launcher and updater helpers, and the
/// credential-provider extension that lives *inside* a manager rather than
/// being it. The first version of this filter let all of them through and
/// buried the two candidates that mattered under fifty lines that did not.
///
/// Judged by components, not substrings — the whole difference between
/// `com.sibersystems.RoboForm.RoboFormService` and a real identifier is in the
/// last one. A hostname is the clearest case: it carries the same words as a
/// bundle identifier in the opposite order, so the test is which end the
/// top-level domain is on.
func isPlausibleAppIdentifier(_ candidate: String) -> Bool {
    let parts = candidate.split(separator: ".").map(String.init)
    // Organisation plus product, reverse-DNS: three components is the floor,
    // and two is what a stripped filename leaves behind.
    guard parts.count >= 3, let first = parts.first?.lowercased(),
        let last = parts.last?.lowercased()
    else { return false }

    let topLevel: Set<String> = ["com", "org", "net", "io", "app", "dev", "co", "me", "sh", "info"]
    if topLevel.contains(last) { return false }
    // A download's filename: `KeeWeb-1.18.7.mac.arm64.dmg`. Both halves are
    // needed — the extension test alone misses `v2.28.1`, and the version test
    // alone misses `MacPass-0.8.2.zip`, whose last component is a word.
    let fileTypes: Set<String> = ["dmg", "zip", "pkg", "tar", "gz", "xz", "exe", "appimage", "sig", "asc"]
    if fileTypes.contains(last) { return false }
    if last.allSatisfy(\.isNumber) { return false }
    if candidate.range(of: "-[0-9]+\\.[0-9]", options: .regularExpression) != nil { return false }
    // `2BUA8C4S2C.com.1password` — an app group, not an application.
    if candidate.range(of: "^[A-Z0-9]{9,10}\\.", options: .regularExpression) != nil { return false }
    if first == "group" || candidate.hasPrefix("com.apple.") { return false }

    // Things that ship alongside an application and take no typing.
    let notAnApp: Set<String> = [
        "helper", "launcher", "service", "agent", "daemon", "updater", "uninstaller",
        "installer", "extension", "provider", "data", "json", "cli", "shipit",
        "crashreporter", "safari", "app", "support",
    ]
    if notAnApp.contains(last) { return false }
    return !notAnApp.contains { last.count > $0.count && last.hasSuffix($0) }
}

/// Every plausible bundle identifier anywhere in a JSON blob.
///
/// Deliberately loose about *where* it looks. The cask schema puts identifiers
/// under `quit:`, under `launchctl:`, and inside `zap trash:` paths, and it has
/// moved them before; a precise reader of one shape would go quietly blind when
/// the shape changed.
///
/// Suffixes are stripped rather than used to reject, and that took a run to get
/// right. The first version discarded anything ending in `.plist` — which is
/// how a cask writes `~/Library/Preferences/net.antelle.keeweb.plist`, so
/// KeeWeb and Buttercup were reported missing while sitting in the list.
func identifiers(in text: String) -> Set<String> {
    let pattern = "[A-Za-z][A-Za-z0-9-]*(?:\\.[A-Za-z0-9_-]+){2,}"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    // What an identifier collects on its way into a preferences folder or a
    // saved-state directory.
    let trailing = [".plist", ".savedState", ".sfl", ".sfl2", ".sfl3", ".binarycookies", ".lockfile"]
    var found: Set<String> = []
    for match in regex.matches(in: text, range: range) {
        guard let r = Range(match.range, in: text) else { continue }
        var candidate = String(text[r])
        for suffix in trailing where candidate.hasSuffix(suffix) {
            candidate = String(candidate.dropLast(suffix.count))
        }
        if isPlausibleAppIdentifier(candidate) { found.insert(candidate) }
    }
    return found
}

func caskIdentifiers(_ token: String) -> Set<String>? {
    guard let url = URL(string: "https://formulae.brew.sh/api/cask/\(token).json"),
        let data = fetch(url), let text = String(data: data, encoding: .utf8)
    else { return nil }
    guard text.contains("\"token\"") else { return nil }  // 404 body
    return identifiers(in: text)
}

/// App Store hits, kept only when the result is plausibly the manager that was
/// searched for.
///
/// The search is a fuzzy one: asking for "Dashlane" returns Amazon Prime Video
/// several places down, and accepting every hit filled the report with fifty
/// lines of unrelated software. A report that has to be sifted is a report
/// nobody runs twice. Requiring the manager's name to appear in the app's title
/// or its seller's is crude, and it is the difference between a usable answer
/// and a haystack.
func appStoreIdentifiers(_ term: String, matching name: String) -> Set<String>? {
    var components = URLComponents(string: "https://itunes.apple.com/search")!
    components.queryItems = [
        .init(name: "term", value: term), .init(name: "entity", value: "macSoftware"),
        .init(name: "limit", value: "8"), .init(name: "country", value: "us"),
    ]
    guard let url = components.url, let data = fetch(url),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let results = json["results"] as? [[String: Any]]
    else { return nil }
    // Every word of the name, rather than the name as one string. 2Stable's
    // app is called "Passwords" and the vendor is "2Stable", so the two words
    // are present but in the other order and with the seller between them —
    // and matching the joined string reported a real manager as missing.
    let words = name.lowercased().split(separator: " ").map { $0.replacingOccurrences(of: " ", with: "") }
    return Set(
        results.compactMap { result -> String? in
            guard let id = result["bundleId"] as? String else { return nil }
            let haystack = [result["trackName"] as? String, result["sellerName"] as? String]
                .compactMap { $0 }.joined().replacingOccurrences(of: " ", with: "").lowercased()
            // Or the identifier itself. 2Stable ships as "Password Manager" by
            // "UNSTABLE, SL" — no visible string contains "2stable passwords",
            // and requiring one reported a manager that is right there in the
            // store as having no evidence at all. `com.2stable.passwords` says
            // it plainly. A vendor rarely puts a rival's name in their own
            // identifier, so this stays as discriminating as the title test.
            let flattened = id.replacingOccurrences(of: ".", with: "").lowercased()
            return words.allSatisfy(haystack.contains) || words.allSatisfy(flattened.contains)
                ? id : nil
        })
}

/// Identifiers that no live source will ever confirm, and the reason each one
/// is in the list anyway.
///
/// Without this the unconfirmed section permanently names half a dozen entries
/// that are known-good — and a warning that is always on is one nobody reads,
/// which would cost exactly the check this tool exists for. Anything not
/// listed here and not found by a source is genuinely unexplained.
///
/// Adding an entry is a claim that someone looked. Say what they found.
let verifiedByHand: [String: String] = [
    "com.apple.keychainaccess": "Apple, ships with macOS",
    "com.apple.Passwords": "Apple, ships with macOS 15+",
    "com.apple.LocalAuthentication.UIAgent": "the Touch-ID-or-password sheet",
    "com.apple.SecurityAgent": "the authentication dialog",
    "com.apple.loginwindow": "the login and unlock screen",
    "com.agilebits.onepassword-osx": "1Password 6, kept for old installs",
    "com.callpod.keepermac": "Keeper's earlier Mac app",
    "com.callpod.keepermac.lite": "Keeper's earlier Mac app, free tier",
    "com.agilebits.onepassword7": "1Password 7, kept for old installs",
    "com.lastpass.LastPass": "LastPass container named by the Homebrew cask",
]

// MARK: - The list as it stands

let listPath = "Sources/TypeReviewApp/AppPreferences.swift"
guard let source = try? String(contentsOfFile: listPath, encoding: .utf8),
    let start = source.range(of: "static let protectedApps: [String] = ["),
    let end = source.range(of: "\n    ]", range: start.upperBound..<source.endIndex)
else { die("could not find protectedApps in \(listPath)") }

let listed = identifiers(in: String(source[start.upperBound..<end.lowerBound]))
    .union(
        // `identifiers(in:)` drops Apple's on purpose — they are noise in a
        // vendor blob and signal here.
        String(source[start.upperBound..<end.lowerBound])
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let open = line.firstIndex(of: "\""),
                    let close = line.lastIndex(of: "\""), open < close
                else { return nil }
                return String(line[line.index(after: open)..<close])
            }
            .filter { $0.hasPrefix("com.apple.") })

// MARK: - Compare

print("Checking \(listed.count) identifiers against \(managers.count) known managers.\n")

var evidence: [String: [String]] = [:]  // identifier -> where it was seen
var unreachable: [String] = []

for manager in managers {
    var seen: Set<String> = []
    if let cask = manager.cask {
        if let ids = caskIdentifiers(cask) {
            for id in ids { evidence[id, default: []].append("homebrew:\(cask)") }
            seen.formUnion(ids)
        } else {
            unreachable.append("\(manager.name) (homebrew cask \(cask))")
        }
    }
    if let term = manager.appStore {
        if let ids = appStoreIdentifiers(term, matching: manager.name) {
            for id in ids { evidence[id, default: []].append("appstore") }
            seen.formUnion(ids)
        } else {
            unreachable.append("\(manager.name) (App Store search)")
        }
    }
    let covered = seen.filter { id in listed.contains { $0.caseInsensitiveCompare(id) == .orderedSame } }
    let status = covered.isEmpty ? (seen.isEmpty ? "no evidence found" : "NOT COVERED") : "covered"
    print("  \(manager.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(status)")
}

print("\n--- In the list but confirmed by nothing ---")
var unconfirmed = 0
var shown = 0
for id in listed.sorted() {
    let sources = evidence.keys.first { $0.caseInsensitiveCompare(id) == .orderedSame }
        .flatMap { evidence[$0] }
    if sources != nil { continue }
    shown += 1
    // Entries somebody already looked into. Reported, because a line nobody
    // can see is a line nobody rechecks — but quietly, so the loud verdict
    // below stays worth reading.
    if let reason = verifiedByHand[id] {
        print("  \(id.padding(toLength: 44, withPad: " ", startingAt: 0)) checked by hand — \(reason)")
        continue
    }
    // Apple's applications and the system's agents appear in neither source.
    // Ask this Mac instead; when the app is not installed there is nothing to
    // confirm it with, and that is worth saying rather than hiding.
    let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    let onDisk = installed ? "confirmed on this Mac" : "UNCONFIRMED — check by hand"
    print("  \(id.padding(toLength: 44, withPad: " ", startingAt: 0)) \(onDisk)")
    if !installed { unconfirmed += 1 }
}
if shown == 0 { print("  (none)") }

print("\n--- Found by a source, not in the list ---")
var missing: [String] = []
for (id, sources) in evidence.sorted(by: { $0.key < $1.key }) {
    guard !listed.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { continue }
    // Browser add-ons ride along in both sources under names the component
    // test cannot catch; everything else is filtered in `identifiers(in:)`.
    let addOn = ["safari", "extension", "keeperfill"]
    if addOn.contains(where: { id.lowercased().contains($0) }) { continue }
    missing.append(id)
    print("  \(id.padding(toLength: 44, withPad: " ", startingAt: 0)) \(Set(sources).sorted().joined(separator: ", "))")
}
if missing.isEmpty { print("  (none)") }

if !unreachable.isEmpty {
    print("\n--- Sources that could not be reached ---")
    for item in unreachable { print("  \(item)") }
    print("  A source that cannot be read is not a source that agrees.")
}

if !missing.isEmpty {
    print("\n--- Paste-ready, after checking each one is really a password manager ---")
    for id in missing { print("        \"\(id)\",") }
}

let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
print("\nChecked \(today). Nothing was written; the list is edited by hand on purpose.")
exit(missing.isEmpty && unconfirmed == 0 && unreachable.isEmpty ? 0 : 2)
