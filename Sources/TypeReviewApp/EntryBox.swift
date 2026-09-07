import TypeReviewKit

/// Somewhere for the corpus adapter to report its pick.
///
/// The adapter's callback is `@Sendable`, so it cannot capture a mutable local
/// or a view controller property directly. A tiny reference type is the
/// smallest thing that satisfies that without loosening the callback.
/// Two slots, not one. The adapter reports its pick *while* the session is
/// still deciding whether it can use it — `TextInput` construction can fail on
/// a passage the corpus was happy to hand over — so a single slot left the
/// screen crediting a passage that had been rejected while the session went on
/// showing the previous one.
final class EntryBox: @unchecked Sendable {
    /// The pick currently being offered to the session.
    var staged: CorpusEntry?
    /// The pick the session accepted, which is what the screen credits.
    private(set) var value: CorpusEntry?

    /// Promotes the staged pick. Called only after a run has actually started.
    func commit() { value = staged }
}
