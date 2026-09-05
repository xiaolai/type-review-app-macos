import Foundation

/// A JSON value with ordered object keys, and a writer that reproduces
/// `JSON.stringify` byte for byte.
///
/// `JSONEncoder` cannot be used for this. The profile must round-trip between
/// the website and the app, which means matching the original's bytes, and two
/// things about those bytes are not negotiable:
///
/// 1. **Key order.** JavaScript objects iterate in insertion order, so the
///    serialized profile's keys appear in the order the original built them.
///    `JSONEncoder` offers no ordering guarantee at all for dictionaries.
/// 2. **Number formatting.** `JSON.stringify(1700000000000)` is
///    `1700000000000`, while Swift's `Double` description gives `1.7e+12`; and
///    `JSON.stringify(50)` is `50`, not `50.0`.
public indirect enum JSONValue {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    /// Ordered on purpose — see above.
    case object([(String, JSONValue)])

    /// Chooses the representation JavaScript would print for a Double: whole
    /// numbers inside the safe-integer range print without a fractional part.
    public static func fromDouble(_ value: Double) -> JSONValue {
        if value.rounded() == value, abs(value) <= 9_007_199_254_740_991 {
            return .integer(Int(value))
        }
        return .number(value)
    }
}

public enum JSONWriter {
    public static func stringify(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .integer(let i): out += String(i)
        case .number(let d): out += number(d)
        case .string(let s): out += quoted(s)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let entries):
            out += "{"
            for (index, entry) in entries.enumerated() {
                if index > 0 { out += "," }
                out += quoted(entry.0)
                out += ":"
                write(entry.1, into: &out)
            }
            out += "}"
        }
    }

    /// JavaScript's number formatting for the cases a profile contains.
    ///
    /// Swift's `description` already produces the shortest representation that
    /// round-trips, which is the same rule JavaScript uses, but it renders a
    /// whole number as `50.0` and reaches for exponent form earlier. Whole
    /// values are handled before this is called; the rest agree.
    private static func number(_ value: Double) -> String {
        if value.rounded() == value, abs(value) <= 9_007_199_254_740_991 {
            return String(Int(value))
        }
        return value.description
    }

    /// `JSON.stringify` escapes the same set, and emits `\u00xx` in lowercase
    /// hex for the remaining control characters.
    private static func quoted(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Orders object keys the way a JavaScript object does: integer-like keys
    /// first, ascending numerically, then the rest in insertion order.
    ///
    /// This is not pedantry. Bigram keys are two characters, and with numbers
    /// enabled a passage produces bigrams like `"12"` — which JavaScript
    /// hoists ahead of every letter pair regardless of when it was inserted.
    /// Miss this and profiles containing digits serialize differently in the
    /// two implementations.
    public static func jsObjectOrder(_ entries: [(String, JSONValue)]) -> [(String, JSONValue)] {
        var integerLike: [(index: Int, key: String, value: JSONValue)] = []
        var rest: [(String, JSONValue)] = []
        for entry in entries {
            if let index = canonicalArrayIndex(entry.0) {
                integerLike.append((index, entry.0, entry.1))
            } else {
                rest.append(entry)
            }
        }
        integerLike.sort { $0.index < $1.index }
        return integerLike.map { ($0.key, $0.value) } + rest
    }

    /// A key counts as an array index only if it is the *canonical* decimal
    /// form of a non-negative integer below 2³²−1: `"12"` qualifies, `"012"`
    /// and `"1.0"` and `"-1"` do not.
    private static func canonicalArrayIndex(_ key: String) -> Int? {
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if key.count > 1, key.first == "0" { return nil }
        guard let value = UInt32(key), value != UInt32.max else { return nil }
        return Int(value)
    }
}
