import Foundation

/// Defensive caps on persisted shape — tampered storage cannot exhaust
/// resources on load.
public let maxResults = 500
/// A histogram holds one entry per distinct adjacent character pair, so it
/// grows with passage length: a 5,000-character upload yields around 490. This
/// ceiling sits above anything the app itself produces.
public let maxHistogramEntries = 5_000
public let maxKeyCount = 1_000_000
public let maxTimeToTypeMs: Double = 60_000
public let maxDurationMs: Double = 24 * 60 * 60 * 1000
public let maxTextLength = 100_000
public let maxPassageIdLength = 256

/// Outcome of a profile load. The three "no profile" cases are genuinely
/// different and the user is told which one happened.
public enum LoadResult: Equatable {
    case ok(Profile)
    /// Never saved — a clean first run.
    case absent
    /// Data was present but unreadable.
    case corrupt(reason: String)
    /// A marker says data existed but storage was wiped. Unreachable in a
    /// native host, where the profile is a file; kept so the two
    /// implementations describe the same states.
    case evicted

    // Equality is synthesised, which means `.ok` compares the profiles it
    // carries. The hand-written version returned true for any two `.ok` cases,
    // so two loads of entirely different data compared equal — a public
    // conformance that quietly answered the wrong question.

    public var statusName: String {
        switch self {
        case .ok: return "ok"
        case .absent: return "absent"
        case .corrupt: return "corrupt"
        case .evicted: return "evicted"
        }
    }
}

private let allowedProfileKeys: Set<String> = ["version", "settings", "results"]
private let allowedResultKeys: Set<String> = [
    "index", "mode", "timestamp", "passageId", "text", "metrics", "histogram",
]
private let allowedMetricsKeys: Set<String> = [
    "netWpm", "wpmStdDev", "wpmSeries", "rawWpm", "accuracy", "consistency", "correctChars",
    "incorrectChars", "durationMs",
]
private let allowedSettingsKeys: Set<String> = [
    "mode", "targetWpm", "wordCount", "testMode", "testDurationSec", "stopOnError", "noBackspace",
    "passageLength", "adaptive", "includeNumbers", "includePunctuation",
]
/// Keys the current format no longer knows but earlier versions did. Dropped
/// silently so an existing profile upgrades instead of being called corrupt.
private let legacySettingsKeys: Set<String> = ["funbox"]
private let allowedAdaptiveKeys: Set<String> = ["minAlphabetSize", "alphabetExpansion"]

/// Bounds the storage boundary enforces. Wider than what a control may
/// produce: a value the UI would never emit can still be legal on disk.
public enum SettingsBounds {
    public static let targetWpm = (lo: 1.0, hi: 500.0, integer: false)
    public static let wordCount = (lo: 1.0, hi: 1000.0, integer: true)
    public static let testDurationSec = (lo: 5.0, hi: 600.0, integer: true)
    public static let minAlphabetSize = (lo: 1.0, hi: 64.0, integer: true)
    public static let alphabetExpansion = (lo: 0.0, hi: 1.0, integer: false)
}

private func inBound(_ value: Any?, _ bound: (lo: Double, hi: Double, integer: Bool)) -> Double? {
    guard let number = finiteNumber(value) else { return nil }
    if bound.integer, number.rounded() != number { return nil }
    guard number >= bound.lo, number <= bound.hi else { return nil }
    return number
}

/// JSONSerialization hands back NSNumber, which reports booleans as numbers.
/// Accepting `true` where a number belongs would be a quiet widening of the
/// format, so booleans are excluded explicitly.
///
/// A JSON `null` needs no exclusion of its own and must not be given one:
/// `NSNull` is not an `NSNumber`, so the cast below already rejects it. The
/// `!(number is NSNull)` this used to carry was a cast between unrelated types
/// that the compiler could prove always fails — a check that read like a guard
/// and tested nothing.
private func finiteNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber else { return nil }
    if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    let double = number.doubleValue
    return double.isFinite ? double : nil
}

private func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        return nil
    }
    return number.boolValue
}

private func nonNegativeInteger(_ value: Any?, max: Double) -> Int? {
    guard let number = finiteNumber(value), number.rounded() == number, number >= 0,
        number <= max
    else { return nil }
    return Int(number)
}

private func inRange(_ value: Any?, _ lo: Double, _ hi: Double) -> Double? {
    guard let number = finiteNumber(value), number >= lo, number <= hi else { return nil }
    return number
}

private func hasOnlyAllowedKeys(_ raw: [String: Any], _ allowed: Set<String>) -> Bool {
    raw.keys.allSatisfy { allowed.contains($0) }
}

/// Validates unknown data as `ProfileSettings`.
///
/// The same checks run on the way in from storage and on the way in from a
/// settings UI — one definition of valid settings, with no trusted-caller
/// bypass. Absent optional fields default; present-but-wrong-typed fields are
/// rejected.
public func validateSettings(_ raw: Any?) -> ProfileSettings? {
    guard let raw = raw as? [String: Any] else { return nil }
    for key in raw.keys
    where !allowedSettingsKeys.contains(key) && !legacySettingsKeys.contains(key) {
        return nil
    }
    guard let adaptiveRaw = raw["adaptive"] as? [String: Any],
        hasOnlyAllowedKeys(adaptiveRaw, allowedAdaptiveKeys)
    else { return nil }
    guard let modeString = raw["mode"] as? String, let mode = Mode(rawValue: modeString) else {
        return nil
    }
    guard let stopOnError = boolean(raw["stopOnError"]) else { return nil }

    // Optional for forward compatibility with payloads an older migrator
    // produced: absent is fine, present-but-wrong is not.
    func optionalBool(_ key: String) -> Bool?? {
        guard raw[key] != nil else { return .some(nil) }
        guard let value = boolean(raw[key]) else { return nil }
        return .some(value)
    }
    guard let includeNumbers = optionalBool("includeNumbers"),
        let includePunctuation = optionalBool("includePunctuation"),
        let noBackspace = optionalBool("noBackspace")
    else { return nil }

    var testMode = TestMode.words
    if let rawTestMode = raw["testMode"] {
        guard let string = rawTestMode as? String, let parsed = TestMode(rawValue: string) else {
            return nil
        }
        testMode = parsed
    }
    var testDurationSec: Double = 30
    if raw["testDurationSec"] != nil {
        guard let value = inBound(raw["testDurationSec"], SettingsBounds.testDurationSec) else {
            return nil
        }
        testDurationSec = value
    }
    var passageLength = PassageLength.any
    if let rawLength = raw["passageLength"] {
        guard let string = rawLength as? String, let parsed = PassageLength(rawValue: string) else {
            return nil
        }
        passageLength = parsed
    }

    guard let targetWpm = inBound(raw["targetWpm"], SettingsBounds.targetWpm),
        let wordCount = inBound(raw["wordCount"], SettingsBounds.wordCount),
        let minAlphabetSize = inBound(adaptiveRaw["minAlphabetSize"], SettingsBounds.minAlphabetSize),
        let alphabetExpansion = inBound(
            adaptiveRaw["alphabetExpansion"], SettingsBounds.alphabetExpansion)
    else { return nil }

    return ProfileSettings(
        mode: mode,
        targetWpm: targetWpm,
        adaptive: AdaptiveSettings(
            minAlphabetSize: minAlphabetSize, alphabetExpansion: alphabetExpansion),
        wordCount: wordCount,
        testMode: testMode,
        testDurationSec: testDurationSec,
        stopOnError: stopOnError,
        noBackspace: noBackspace ?? false,
        passageLength: passageLength,
        includeNumbers: includeNumbers ?? false,
        includePunctuation: includePunctuation ?? false)
}

private func parseMetrics(_ raw: Any?) -> RunMetrics? {
    guard let raw = raw as? [String: Any], hasOnlyAllowedKeys(raw, allowedMetricsKeys) else {
        return nil
    }
    var wpmSeries: [Double] = []
    if let rawSeries = raw["wpmSeries"] {
        guard let array = rawSeries as? [Any] else { return nil }
        // Capped before walking, so a tampered megabyte-long array cannot burn
        // time on samples that would be discarded anyway.
        for sample in array.prefix(1000) {
            guard let value = finiteNumber(sample) else { return nil }
            wpmSeries.append(value)
        }
    }

    guard let netWpm = inRange(raw["netWpm"], 0, 1000),
        let rawWpm = inRange(raw["rawWpm"], 0, 1000),
        let accuracy = inRange(raw["accuracy"], 0, 100),
        let consistency = inRange(raw["consistency"], 0, 100),
        // Whole numbers, not merely in range: these are counts, and `inRange`
        // accepted a fractional 5.7 that `Int(_:)` then silently truncated to 5.
        let correctChars = nonNegativeInteger(raw["correctChars"], max: Double(maxTextLength)),
        let incorrectChars = nonNegativeInteger(raw["incorrectChars"], max: Double(maxTextLength)),
        let durationMs = finiteNumber(raw["durationMs"])
    else { return nil }
    let wpmStdDev = finiteNumber(raw["wpmStdDev"]) ?? 0
    guard wpmStdDev >= 0, wpmStdDev <= 1000 else { return nil }

    return RunMetrics(
        netWpm: netWpm, rawWpm: rawWpm, accuracy: accuracy, consistency: consistency,
        wpmStdDev: wpmStdDev, wpmSeries: wpmSeries, correctChars: correctChars,
        incorrectChars: incorrectChars, durationMs: durationMs)
}

/// Parses a run's histogram, with two failure modes handled deliberately
/// differently.
///
/// A structurally invalid entry means tampering or truncation, and returns nil
/// so the whole load fails loud. *Too many* entries is a quantity problem, and
/// rejecting it would cost the user every run they have ever done — so it
/// degrades to an empty histogram and the adaptive picture rebuilds from later
/// runs. The count is checked before any entry is validated, so an oversized
/// payload still cannot make load do unbounded work.
private func parseHistogram(_ raw: Any?, keyOrder: [String]) -> Histogram? {
    guard let raw = raw as? [String: Any] else { return nil }
    if raw.count > maxHistogramEntries { return Histogram() }

    var histogram = Histogram()
    for key in keyOrder {
        guard let hitRaw = raw[key] else { continue }
        let units = Array(key.utf16)
        // Keys are two BMP code units. A surrogate half means the engine's
        // coordinate system was violated somewhere upstream.
        guard units.count == 2, !units.contains(where: { (0xD800...0xDFFF).contains($0) })
        else { return nil }
        guard let hit = hitRaw as? [String: Any],
            let hitCount = nonNegativeInteger(hit["hitCount"], max: Double(maxKeyCount)),
            let missCount = nonNegativeInteger(hit["missCount"], max: Double(maxKeyCount)),
            missCount <= hitCount,
            let timeToType = inRange(hit["timeToType"], 0, maxTimeToTypeMs)
        else { return nil }
        histogram[key] = BigramHit(
            hitCount: hitCount, missCount: missCount, timeToType: timeToType)
    }
    return histogram
}

private func parseResult(_ raw: Any?, keyOrder: [String]) -> RunResult? {
    guard let raw = raw as? [String: Any], hasOnlyAllowedKeys(raw, allowedResultKeys) else {
        return nil
    }
    guard let modeString = raw["mode"] as? String, let mode = Mode(rawValue: modeString),
        let index = nonNegativeInteger(raw["index"], max: 9_007_199_254_740_991),
        let timestamp = finiteNumber(raw["timestamp"]),
        let passageId = raw["passageId"] as? String, !passageId.isEmpty,
        passageId.utf16.count <= maxPassageIdLength,
        let text = raw["text"] as? String, !text.isEmpty, text.utf16.count <= maxTextLength,
        let metrics = parseMetrics(raw["metrics"]),
        inRange(metrics.durationMs, 0, maxDurationMs) != nil,
        let histogram = parseHistogram(raw["histogram"], keyOrder: keyOrder)
    else { return nil }

    return RunResult(
        index: index, mode: mode, timestamp: timestamp, passageId: passageId, text: text,
        metrics: metrics, histogram: histogram)
}

/// Reconstructs a profile from stored JSON.
///
/// `keyOrders` supplies each result's histogram key order, which
/// `JSONSerialization` discards — insertion order is what the EMA replay and
/// the serialized bytes depend on, so it is recovered from the raw text by the
/// caller rather than invented here.
public func deserializeProfile(_ json: String) -> LoadResult {
    guard let data = json.data(using: .utf8),
        let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return .corrupt(reason: "not valid JSON") }
    return deserializeProfile(raw, keyOrders: histogramKeyOrders(in: json))
}

public func deserializeProfile(_ raw: Any?, keyOrders: [[String]] = []) -> LoadResult {
    if raw == nil || raw is NSNull { return .absent }
    guard let object = raw as? [String: Any] else { return .corrupt(reason: "not an object") }
    guard hasOnlyAllowedKeys(object, allowedProfileKeys) else {
        return .corrupt(reason: "unknown top-level keys")
    }

    // Bounded *before* the conversion, not after. `Int(_: Double)` traps on a
    // value outside Int's range, and a tampered file holding a finite integral
    // 1e300 is exactly such a value — the load crashed the app rather than
    // reporting corruption. A format version is a small positive number, so
    // anything outside the range this build can name is corrupt by definition.
    guard let rawVersion = finiteNumber(object["version"]), rawVersion.rounded() == rawVersion,
        rawVersion >= 1, rawVersion <= Double(formatVersion)
    else {
        return .corrupt(reason: "version \(object["version"] ?? "undefined") cannot be migrated to \(formatVersion)")
    }
    let version = Int(rawVersion)
    var migrated = object
    if version < formatVersion {
        guard let upgraded = migrate(migrated, from: version) else {
            return .corrupt(reason: "version \(version) cannot be migrated to \(formatVersion)")
        }
        migrated = upgraded
    }

    guard let settings = validateSettings(migrated["settings"]) else {
        return .corrupt(reason: "invalid settings")
    }
    guard let rawResults = migrated["results"] as? [Any] else {
        return .corrupt(reason: "results not an array")
    }
    // Cap untrusted history so tampering cannot make startup do unbounded
    // work. The most recent entries are the ones kept.
    let dropped = max(0, rawResults.count - maxResults)
    let capped = dropped > 0 ? Array(rawResults.suffix(maxResults)) : rawResults

    var results: [RunResult] = []
    for (index, rawResult) in capped.enumerated() {
        // `keyOrders` was recovered from the whole document, so it is indexed
        // by position in `rawResults`. Capping drops from the front, and
        // reading the orders from zero paired every retained run with a
        // discarded run's key order — `parseHistogram` then found none of
        // those keys and silently returned a near-empty histogram.
        let orderIndex = dropped + index
        let order = orderIndex < keyOrders.count ? keyOrders[orderIndex] : []
        guard let result = parseResult(rawResult, keyOrder: order) else {
            return .corrupt(reason: "invalid result entry")
        }
        results.append(result)
    }
    return .ok(Profile(settings: settings, results: results))
}

/// v1 → v2: per-letter histograms became per-bigram. There is no faithful way
/// to reconstruct bigram timings from letter data, so the histograms are
/// dropped and the adaptive engine relearns over the next few runs. Run counts
/// and metrics survive — only the adaptive picture resets.
private func migrate(_ raw: [String: Any], from version: Int) -> [String: Any]? {
    var current = raw
    var cursor = version
    while cursor < formatVersion {
        guard cursor == 1 else { return nil }
        var next = current
        // A v1 file whose `results` is missing or not an array is corrupt, and
        // substituting an empty array here made it load as a valid profile
        // with no history — the user's runs discarded rather than reported.
        // Passing the bad value through unchanged lets the validation below
        // reject it, which is the answer that tells them something is wrong.
        if let results = current["results"] as? [Any] {
            next["results"] = results.map { entry -> Any in
                guard var object = entry as? [String: Any] else { return entry }
                object["histogram"] = [String: Any]()
                return object
            }
        }
        next["version"] = 2
        current = next
        cursor += 1
    }
    return current
}

/// Recovers each result's histogram key order from the raw JSON text, since
/// `JSONSerialization` returns an unordered dictionary and the order is part
/// of the format.
///
/// A scanner rather than a substring search, because the substrings are not
/// safe to search for. Bigram keys are two arbitrary code units and `"` is in
/// the punctuation alphabet, so a real key serializes as `"a\"":{…}` — and
/// looking backwards for the nearest `"` from a `":{` landed inside the escape
/// and recovered the key `"` instead of `a"`. `parseHistogram` then found no
/// such key and dropped the entry, silently losing that bigram's history. The
/// old end-of-object search for `}}` was the same class of guess.
///
/// So: walk the text once, honouring string escapes and brace depth, and read
/// the keys at depth 1 of each `"histogram"` object in document order.
func histogramKeyOrders(in json: String) -> [[String]] {
    // UTF-16 units throughout: that is the engine's coordinate system, and it
    // is the only representation in which a `😀` pair reassembles
    // into one character. Decoding each escape to a Unicode scalar instead
    // fails on the first half of every pair — and a pair is legal inside a
    // passage's `text`, so failing there would abandon the scan and leave
    // every later histogram without an order.
    let units = Array(json.utf16)
    let quote: UInt16 = 0x22
    let backslash: UInt16 = 0x5C
    let colon: UInt16 = 0x3A
    let openBrace: UInt16 = 0x7B
    let closeBrace: UInt16 = 0x7D
    let openBracket: UInt16 = 0x5B
    let closeBracket: UInt16 = 0x5D

    /// Reads one JSON string whose opening quote is at `index`. Returns its
    /// unescaped contents — matching the key `JSONSerialization` produces —
    /// and the index just past the closing quote.
    func readString(from index: Int) -> (value: String, next: Int)? {
        guard index < units.count, units[index] == quote else { return nil }
        var value: [UInt16] = []
        var cursor = index + 1
        while cursor < units.count {
            let unit = units[cursor]
            if unit == backslash {
                guard cursor + 1 < units.count else { return nil }
                switch units[cursor + 1] {
                case 0x6E: value.append(0x0A)  // \n
                case 0x72: value.append(0x0D)  // \r
                case 0x74: value.append(0x09)  // \t
                case 0x62: value.append(0x08)  // \b
                case 0x66: value.append(0x0C)  // \f
                case 0x75:  // \uXXXX
                    guard cursor + 5 < units.count else { return nil }
                    let digits = String(
                        utf16CodeUnits: Array(units[(cursor + 2)...(cursor + 5)]), count: 4)
                    guard let unit = UInt16(digits, radix: 16) else { return nil }
                    value.append(unit)
                    cursor += 6
                    continue
                case let escaped: value.append(escaped)  // \" \\ \/ and the rest
                }
                cursor += 2
                continue
            }
            if unit == quote {
                return (String(utf16CodeUnits: value, count: value.count), cursor + 1)
            }
            value.append(unit)
            cursor += 1
        }
        return nil
    }

    /// Skips insignificant whitespace, which `JSON.stringify` never emits but
    /// a hand-edited profile may.
    func skipSpace(from index: Int) -> Int {
        var cursor = index
        while cursor < units.count, units[cursor] == 0x20 || units[cursor] == 0x09
            || units[cursor] == 0x0A || units[cursor] == 0x0D
        {
            cursor += 1
        }
        return cursor
    }

    var orders: [[String]] = []
    var index = 0
    while index < units.count {
        // Every string is consumed whole, so a `"histogram":{` occurring inside
        // a passage's own text cannot be mistaken for the real key.
        guard units[index] == quote else {
            index += 1
            continue
        }
        guard let marker = readString(from: index) else { break }
        index = marker.next
        guard marker.value == "histogram" else { continue }

        var cursor = skipSpace(from: index)
        guard cursor < units.count, units[cursor] == colon else { continue }
        cursor = skipSpace(from: cursor + 1)
        guard cursor < units.count, units[cursor] == openBrace else { continue }

        // Depth 1 is the histogram object itself, where every string is a
        // bigram key; its values are objects, so nothing else appears there.
        var keys: [String] = []
        var depth = 1
        cursor += 1
        while cursor < units.count, depth > 0 {
            let unit = units[cursor]
            if unit == quote {
                guard let entry = readString(from: cursor) else { return orders }
                if depth == 1 { keys.append(entry.value) }
                cursor = entry.next
                continue
            }
            if unit == openBrace || unit == openBracket { depth += 1 }
            if unit == closeBrace || unit == closeBracket { depth -= 1 }
            cursor += 1
        }
        orders.append(keys)
        index = cursor
    }
    return orders
}
