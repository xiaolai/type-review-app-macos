import Foundation

public let formatVersion = 2

public enum Mode: String, Sendable, Codable {
    case adaptive, benchmark
}

public enum TestMode: String, Sendable, Codable {
    case words, time
}

public enum PassageLength: String, Sendable, Codable {
    case any, short, medium, long
}

/// Settings that live inside the profile. Property order is the serialized key
/// order, and the serialized key order is part of the file format.
public struct ProfileSettings: Sendable, Equatable {
    public var mode: Mode
    public var targetWpm: Double
    public var adaptive: AdaptiveSettings
    public var wordCount: Double
    public var testMode: TestMode
    public var testDurationSec: Double
    public var stopOnError: Bool
    public var noBackspace: Bool
    public var passageLength: PassageLength
    public var includeNumbers: Bool
    public var includePunctuation: Bool

    public static let `default` = ProfileSettings(
        mode: .benchmark, targetWpm: 50, adaptive: AdaptiveSettings(minAlphabetSize: 6, alphabetExpansion: 0),
        wordCount: 30, testMode: .words, testDurationSec: 30, stopOnError: false,
        noBackspace: false, passageLength: .any, includeNumbers: false, includePunctuation: false)
}

public struct RunResult: Sendable, Equatable {
    public var index: Int
    public var mode: Mode
    public var timestamp: Double
    public var passageId: String
    public var text: String
    public var metrics: RunMetrics
    public var histogram: Histogram
}

public struct Profile: Sendable {
    public var settings: ProfileSettings
    public var results: [RunResult]

    public init(settings: ProfileSettings = .default, results: [RunResult] = []) {
        self.settings = settings
        self.results = results
    }
}

/// Serializes a profile to exactly the bytes the website writes.
///
/// Byte identity is a product requirement, not a purity exercise: a user
/// exports from the site and imports here, or the other way round, and the
/// receiving side validates with `hasOnlyAllowedKeys`, which rejects the whole
/// profile over a single unexpected key.
public func serializeProfile(_ profile: Profile) -> JSONValue {
    .object([
        ("version", .integer(formatVersion)),
        ("settings", serializeSettings(profile.settings)),
        ("results", .array(profile.results.map(serializeResult))),
    ])
}

public func serializeProfileString(_ profile: Profile) -> String {
    JSONWriter.stringify(serializeProfile(profile))
}

private func serializeSettings(_ settings: ProfileSettings) -> JSONValue {
    .object([
        ("mode", .string(settings.mode.rawValue)),
        ("targetWpm", JSONValue.fromDouble(settings.targetWpm)),
        // `adaptive` sits third because the original spreads the settings
        // object and JavaScript keeps a re-assigned key in its original
        // position. Moving it changes the bytes.
        (
            "adaptive",
            .object([
                ("minAlphabetSize", JSONValue.fromDouble(settings.adaptive.minAlphabetSize)),
                ("alphabetExpansion", JSONValue.fromDouble(settings.adaptive.alphabetExpansion)),
            ])
        ),
        ("wordCount", JSONValue.fromDouble(settings.wordCount)),
        ("testMode", .string(settings.testMode.rawValue)),
        ("testDurationSec", JSONValue.fromDouble(settings.testDurationSec)),
        ("stopOnError", .bool(settings.stopOnError)),
        ("noBackspace", .bool(settings.noBackspace)),
        ("passageLength", .string(settings.passageLength.rawValue)),
        ("includeNumbers", .bool(settings.includeNumbers)),
        ("includePunctuation", .bool(settings.includePunctuation)),
    ])
}

private func serializeResult(_ result: RunResult) -> JSONValue {
    .object([
        ("index", .integer(result.index)),
        ("mode", .string(result.mode.rawValue)),
        ("timestamp", JSONValue.fromDouble(result.timestamp)),
        ("passageId", .string(result.passageId)),
        ("text", .string(result.text)),
        ("metrics", serializeMetrics(result.metrics)),
        ("histogram", serializeHistogram(result.histogram)),
    ])
}

private func serializeMetrics(_ metrics: RunMetrics) -> JSONValue {
    .object([
        ("netWpm", JSONValue.fromDouble(metrics.netWpm)),
        ("rawWpm", JSONValue.fromDouble(metrics.rawWpm)),
        ("accuracy", JSONValue.fromDouble(metrics.accuracy)),
        ("consistency", JSONValue.fromDouble(metrics.consistency)),
        ("wpmStdDev", JSONValue.fromDouble(metrics.wpmStdDev)),
        ("wpmSeries", .array(metrics.wpmSeries.map(JSONValue.fromDouble))),
        ("correctChars", .integer(metrics.correctChars)),
        ("incorrectChars", .integer(metrics.incorrectChars)),
        ("durationMs", JSONValue.fromDouble(metrics.durationMs)),
    ])
}

/// The histogram becomes a plain object, so JavaScript's key ordering applies:
/// integer-like keys first. A digit bigram such as `"12"` is hoisted ahead of
/// every letter pair no matter when it was recorded.
private func serializeHistogram(_ histogram: Histogram) -> JSONValue {
    let entries: [(String, JSONValue)] = histogram.entries.map { key, hit in
        (
            key,
            .object([
                ("hitCount", .integer(hit.hitCount)),
                ("missCount", .integer(hit.missCount)),
                ("timeToType", JSONValue.fromDouble(hit.timeToType)),
            ])
        )
    }
    return .object(JSONWriter.jsObjectOrder(entries))
}
