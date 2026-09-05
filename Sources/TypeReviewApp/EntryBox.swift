import TypeReviewKit

/// Somewhere for the corpus adapter to report its pick.
///
/// The adapter's callback is `@Sendable`, so it cannot capture a mutable local
/// or a view controller property directly. A tiny reference type is the
/// smallest thing that satisfies that without loosening the callback.
final class EntryBox: @unchecked Sendable {
    var value: CorpusEntry?
}
