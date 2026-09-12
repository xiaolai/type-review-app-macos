
/// Whether the keystroke that just landed was wrong, and whether it may sound.
///
/// Split out for the same reason `SpokenWords` is: the engine must not grow a
/// new signal for it. `Feedback` answers only running-or-completed, and
/// `Session` is pinned to the website by the golden vectors, so a field added
/// here to carry "that was a typo" would have to be added there too and mean
/// the same thing forever. The information is already in the snapshot. This
/// reads it.
///
/// Nothing here knows about audio, settings or packs. It answers a question
/// about two integers and an array, which is what makes it testable without a
/// window, an audio device or a run loop.

/// Whether the character just typed was wrong.
///
/// `position` is where the cursor sat *before* the keystroke, which is the
/// index the engine just wrote to. That one index answers both modes, and
/// deliberately:
///
/// - With stop-on-error off the cursor advanced, and the index it left behind
///   holds the verdict.
/// - With stop-on-error on the cursor did not move, and the index it is still
///   sitting on holds the same verdict.
///
/// So the caller does not have to know which mode is running, and cannot get
/// it wrong when the setting changes under it.
///
/// A corrected character reads `.correct` and is silent, which is the right
/// answer: the sound belongs to the mistake, not to the position that once
/// held one.
///
/// Answers `false` rather than trapping when the index is outside the array —
/// a caller holding a stale cursor gets silence rather than a crash, the same
/// safe direction `wordJustFinished` takes.
public func mistypeJustHappened(statuses: [CharStatus], at position: Int) -> Bool {
    guard position >= 0, position < statuses.count else { return false }
    return statuses[position] == .incorrect
}

/// The shortest gap between two error sounds, in milliseconds.
///
/// An auto-repeat guard, and only that. A held-down key still produces
/// characters at the system repeat rate — `keyDown` filters repeats out of the
/// click, but the commit path never sees that flag — so a wrong key leaned on
/// would fire this at roughly 30 Hz.
///
/// It used to be described as the defence against an input-method commit. It
/// was never capable of that: a commit is a number of characters, not a
/// duration, so any threshold both swallows real mistakes typed faster than it
/// and lets through a commit slower than it. The commit boundary is carried
/// explicitly instead, from `TypingView.onCommitBegan`.
///
/// The cost of keeping a clock as well is stated rather than hidden: two
/// deliberate wrong keys less than 60 ms apart sound once. That is above 200
/// words per minute of sustained error, and the alternative is a machine gun
/// on a stuck key.
public let mistypeMinimumGapMs: Double = 60

/// Whether an error sound may be played now, given when the last one was.
///
/// `nil` means none has played in this run, which always may. The caller
/// clears it when a passage is installed, so the first mistake of a new run
/// never lands inside the previous run's window.
public func mistypeMaySound(
    lastSoundedMs: Double?, nowMs: Double, minimumGapMs: Double = mistypeMinimumGapMs
) -> Bool {
    guard let lastSoundedMs else { return true }
    // A clock that went backwards is treated as a fresh start rather than as a
    // licence to machine-gun: the alternative is a negative interval passing
    // every comparison it is given.
    if nowMs < lastSoundedMs { return true }
    return nowMs - lastSoundedMs >= minimumGapMs
}
