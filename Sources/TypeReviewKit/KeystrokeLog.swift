import Foundation

/// How many days of keystroke counts are kept.
///
/// A little over a year, so the longest grid the app can draw always has data
/// behind it and the file still stops growing. Unlike the practice history
/// this accumulates one entry per day whether or not the user practises, so
/// without a ceiling it grows forever on its own.
public let maxKeystrokeDays = 400

/// A per-day count of keys pressed, and nothing else.
///
/// Deliberately the coarsest shape that can draw the grid. No times, no key
/// codes, no application names — an hourly breakdown or a per-app split would
/// be a record of what someone was doing and when, which is a different thing
/// from a total and is not what was asked for. What cannot be stored cannot
/// leak, and this is stored on disk in a file the user can delete.
public struct KeystrokeLog: Sendable, Equatable {
    /// Local day key (`YYYY-MM-DD`) to keys pressed on that day.
    public private(set) var days: [String: Int]

    public init(days: [String: Int] = [:]) {
        self.days = days
    }

    public var isEmpty: Bool { days.isEmpty }
    public var total: Int { days.values.reduce(0, +) }

    /// Adds to one day's total, saturating rather than overflowing.
    ///
    /// A count cannot legitimately approach `Int.max`, but this is fed from a
    /// file the app does not control, and an overflow trap in a background
    /// flush would crash the app on somebody's tampered JSON.
    public mutating func add(_ count: Int, on day: String) {
        guard count > 0 else { return }
        let (sum, overflowed) = (days[day] ?? 0).addingReportingOverflow(count)
        // `partialValue` wraps, which turns a tampered count negative and
        // makes every total below it nonsense in a new direction. Clamping is
        // the saturating behaviour the comment above claims.
        days[day] = overflowed ? Int.max : sum
    }

    /// Drops the oldest days beyond the ceiling.
    ///
    /// By key order, which is chronological because the keys are `YYYY-MM-DD`
    /// — no date parsing, and no dependence on a calendar the caller might not
    /// have passed the same way twice.
    public mutating func prune(keeping limit: Int = maxKeystrokeDays) {
        guard days.count > limit, limit >= 0 else { return }
        for key in days.keys.sorted().prefix(days.count - limit) {
            days.removeValue(forKey: key)
        }
    }

    /// The counts a calendar grid wants, in chronological order.
    public func countsByDay() -> OrderedMap<Int> {
        var out = OrderedMap<Int>()
        for key in days.keys.sorted() { out[key] = days[key] }
        return out
    }
}

/// A day key the log will accept: exactly `YYYY-MM-DD`, all digits.
///
/// The log is read from a file, so its keys are untrusted input. A key of any
/// other shape sorts unpredictably against real ones, which would make
/// `prune` drop the wrong days — the one operation here that destroys data.
public func isKeystrokeDayKey(_ key: String) -> Bool {
    let units = Array(key.utf8)
    guard units.count == 10 else { return false }
    for (index, unit) in units.enumerated() {
        let isDash = index == 4 || index == 7
        if isDash {
            if unit != UInt8(ascii: "-") { return false }
        } else if unit < UInt8(ascii: "0") || unit > UInt8(ascii: "9") {
            return false
        }
    }
    return true
}

public enum KeystrokeLogError: Error, Equatable {
    case notAnObject
}

/// Parses the stored log, discarding entries it cannot vouch for.
///
/// Malformed *entries* are dropped rather than failing the load, because the
/// consequence of strictness here is losing a year of counts over one bad
/// line, and a keystroke total is not load-bearing the way a profile is. A
/// payload that is not an object at all is a different matter and throws —
/// that is a file this app did not write.
///
/// Too many entries is not corruption either; it prunes, for the same reason
/// the profile's histogram degrades rather than rejecting.
public func decodeKeystrokeLog(_ data: Data) throws -> KeystrokeLog {
    let raw = try? JSONSerialization.jsonObject(with: data)
    guard let object = raw as? [String: Any] else { throw KeystrokeLogError.notAnObject }

    var log = KeystrokeLog()
    for (key, value) in object {
        guard isKeystrokeDayKey(key) else { continue }
        // `as? Int` on an NSNumber holding 3.7 succeeds and truncates, so the
        // integer-ness is checked before the conversion rather than after.
        guard let number = value as? NSNumber,
            Double(number.doubleValue) == number.doubleValue.rounded(),
            number.doubleValue >= 0, number.doubleValue <= Double(Int.max)
        else { continue }
        log.add(number.intValue, on: key)
    }
    log.prune()
    return log
}

/// Serialises the log with sorted keys, so an unchanged day produces an
/// unchanged file and a diff of the store shows only what actually moved.
public func encodeKeystrokeLog(_ log: KeystrokeLog) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: log.days, options: [.sortedKeys, .prettyPrinted])
}
