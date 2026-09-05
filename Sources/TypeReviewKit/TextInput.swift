import Foundation

/// Status of a single character position in the expected text.
public enum CharStatus: String, Codable, Sendable {
    case untyped, correct, incorrect
}

/// Result signal from committing a keystroke.
public enum Feedback: Sendable {
    case running, completed
}

/// One committed keystroke. The log is append-only — backspace never removes a
/// step, so a position that was mistyped, corrected and retyped contributes
/// every attempt to the adaptive statistics.
public struct Step: Sendable, Equatable {
    public let position: Int
    public let timeStamp: Double
    public let typed: String
    public let expected: String
    /// Milliseconds since the previous keystroke, uncapped. The per-key
    /// outlier filter needs the raw value to recognise pause- and
    /// paste-induced timings; `TextInput.elapsedMs` caps separately.
    public let timeToType: Double
    public let typo: Bool

    public init(
        position: Int, timeStamp: Double, typed: String, expected: String, timeToType: Double,
        typo: Bool
    ) {
        self.position = position
        self.timeStamp = timeStamp
        self.typed = typed
        self.expected = expected
        self.timeToType = timeToType
        self.typo = typo
    }
}

public struct TypingSnapshot: Sendable {
    public let expected: String
    public let statuses: [CharStatus]
    public let pos: Int
    public let completed: Bool
}

/// A gap larger than this between keystrokes is treated as time away from the
/// keyboard and excluded from elapsed-time aggregates. Without it a closed lid
/// or a coffee break inflates a run to hours and the saved WPM is nonsense.
public let pauseCapMs: Double = 12_000

/// The typing loop. Pure, no AppKit.
///
/// **Indexed by UTF-16 code unit, not by `Character`.** This is the single
/// most important difference from the obvious Swift version. Swift's
/// `Character` is a grapheme cluster, so `"e\u{301}fg"` is 3 Characters but 4
/// UTF-16 units; indexing by Character would shift every `Step.position` after
/// a combining mark, which changes the adjacency test in the bigram histogram
/// and therefore the keys written into saved profiles. The original engine
/// indexes by code unit and rejects non-BMP text outright, and this must do
/// exactly the same or profiles stop being portable between the two.
public final class TextInput {
    public let expected: String
    /// The expected text as code units, since that is the coordinate system.
    private let units: [UInt16]
    private let stopOnError: Bool
    private let noBackspace: Bool
    private var statuses: [CharStatus]
    private var stepLog: [Step] = []
    private var position = 0
    private var lastTimeStamp: Double?
    private var activeMs: Double = 0

    public enum InputError: Error, LocalizedError {
        case empty
        case nonBMP

        public var errorDescription: String? {
            switch self {
            case .empty: return "TextInput requires non-empty expected text"
            case .nonBMP:
                return "TextInput supports only Basic Multilingual Plane text (no surrogate pairs)"
            }
        }
    }

    public init(expected: String, stopOnError: Bool = false, noBackspace: Bool = false) throws {
        guard !expected.isEmpty else { throw InputError.empty }
        let units = Array(expected.utf16)
        // Surrogate halves mean a non-BMP character, which would take two
        // positions for one visible glyph. Refused at the boundary, exactly as
        // the original does, rather than silently desyncing the cursor.
        if units.contains(where: { (0xD800...0xDFFF).contains($0) }) {
            throw InputError.nonBMP
        }
        self.expected = expected
        self.units = units
        self.stopOnError = stopOnError
        self.noBackspace = noBackspace
        statuses = Array(repeating: .untyped, count: units.count)
        skipNonTypeable()
    }

    /// Newlines are not typeable through the app's input path — Enter is
    /// reserved for advancing — so the cursor steps over them. Skipped
    /// positions stay `.untyped` and produce no `Step`, keeping paragraph
    /// breaks out of the per-key statistics.
    private func skipNonTypeable() {
        let newline = UInt16(10)
        while position < units.count, units[position] == newline {
            position += 1
        }
    }

    public var pos: Int { position }
    public var steps: [Step] { stepLog }
    public var completed: Bool { position >= units.count }
    /// Milliseconds of *active* typing: inter-keystroke intervals, each capped.
    public var elapsedMs: Double { activeMs }

    public func count(_ status: CharStatus) -> Int {
        statuses.reduce(0) { $0 + ($1 == status ? 1 : 0) }
    }

    public func snapshot() -> TypingSnapshot {
        TypingSnapshot(
            expected: expected, statuses: statuses, pos: position, completed: completed)
    }

    /// One code unit as a string, for comparison and for the step log.
    private func character(at index: Int) -> String {
        String(utf16CodeUnits: [units[index]], count: 1)
    }

    @discardableResult
    public func appendChar(_ typed: String, timeStamp: Double) -> Feedback {
        if completed { return .completed }
        let expectedChar = character(at: position)
        let typo = typed != expectedChar
        let rawInterval = lastTimeStamp.map { timeStamp - $0 } ?? 0
        // Negative intervals (clock skew) floor to zero; long pauses cap, so a
        // single gap cannot drag the active-typing total into hours.
        activeMs += max(0, min(rawInterval, pauseCapMs))

        stepLog.append(
            Step(
                position: position, timeStamp: timeStamp, typed: typed, expected: expectedChar,
                timeToType: rawInterval, typo: typo))
        lastTimeStamp = timeStamp

        if typo, stopOnError {
            statuses[position] = .incorrect
            return .running
        }
        statuses[position] = typo ? .incorrect : .correct
        position += 1
        skipNonTypeable()
        return completed ? .completed : .running
    }

    /// Steps back one position, clearing its status, skipping back over
    /// newlines so a backspace at a paragraph start lands on the previous
    /// paragraph's last typeable character. A no-op at the start, and in
    /// confidence mode.
    public func backspace() {
        if noBackspace || position == 0 { return }
        position -= 1
        let newline = UInt16(10)
        while position > 0, units[position] == newline {
            position -= 1
        }
        statuses[position] = .untyped
    }

    public func reset() {
        statuses = Array(repeating: .untyped, count: units.count)
        stepLog.removeAll()
        position = 0
        lastTimeStamp = nil
        activeMs = 0
        skipNonTypeable()
    }
}
