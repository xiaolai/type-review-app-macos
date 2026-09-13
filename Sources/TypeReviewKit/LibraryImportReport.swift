import Foundation

/// What adding to the Library did, in the words the Library window shows.
///
/// In the Kit rather than the window so it can be tested without one. This line
/// is the only place a typist learns that cleaning removed part of what they
/// added, and it once went missing whenever any file in the batch failed,
/// without a test anywhere noticing.
public enum LibraryImportReport {
    /// What cleaning did to the text, when it did anything worth saying.
    public static func cleaningNote(truncated: Bool, dropped: Int) -> String {
        var parts: [String] = []
        // `maxPassageChars`, which is what `sanitize` actually enforces.
        // `maxUserPassageLength` is the *file* read cap and is ten times
        // larger, so the note used to name a limit nothing had applied.
        if truncated { parts.append("truncated to the \(maxPassageChars)-character cap") }
        if dropped > 0 { parts.append("\(dropped) unusable characters removed") }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }

    /// The status line for a batch of files, or nil when there is nothing to say.
    ///
    /// Both halves when a batch had both. Failures used to replace the whole
    /// line, so adding three files of which one failed reported only the
    /// failure: not that two went in, and not what cleaning removed from them.
    public static func batchStatus(
        added: Int, truncated: Bool, dropped: Int, failures: [String], libraryCount: Int
    ) -> String? {
        var parts: [String] = []
        if added > 0 {
            parts.append(
                "added \(added)\(cleaningNote(truncated: truncated, dropped: dropped)) · \(libraryCount) in library")
        }
        // Named rather than counted: "2 files failed" is not actionable.
        parts.append(contentsOf: failures)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
