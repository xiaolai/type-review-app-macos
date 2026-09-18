import AppKit
import TypeReviewKit

/// The status bar both screens put along the bottom: readouts, a mark for the
/// mode, and a hint.
///
/// A status bar, along the bottom, where a status bar goes. The readouts change
/// on every keystroke and are read by glancing; putting them above the passage
/// made the first line of text the second thing on the screen. They are
/// readouts, not headings, so they are set in the secondary colour at the stat
/// size. The hint takes the slack and truncates; the numbers never move.
@MainActor
enum StatusBar {
    static func make(readouts: [NSTextField], mode: NSImageView, hint: NSTextField) -> NSStackView {
        for label in readouts {
            label.font = Theme.statFont
            label.textColor = Theme.secondaryText
        }
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = Theme.secondaryText
        mode.contentTintColor = Theme.secondaryText
        mode.imageScaling = .scaleProportionallyDown
        mode.setContentHuggingPriority(.required, for: .horizontal)

        let metrics = NSStackView(views: readouts + [mode])
        metrics.spacing = 14
        metrics.alignment = .centerY
        let status = NSStackView(views: [metrics, hint])
        status.spacing = 16
        status.alignment = .centerY
        status.distribution = .fill
        metrics.setContentCompressionResistancePriority(.required, for: .horizontal)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.lineBreakMode = .byTruncatingTail
        return status
    }
}

/// When the wrong-key tone may play, for both screens that take typing.
///
/// One sound per commit, then a clock for the held-key case — two separate
/// rules because they answer two separate questions, and the stopwatch alone
/// answered neither correctly.
struct MistypeGate {
    /// Whether this commit has already sounded. Cleared when one begins.
    private var soundedThisCommit = false
    /// When the last tone played, so a held-down wrong key does not
    /// machine-gun.
    ///
    /// An auto-repeat guard and nothing else. It used to be described as the
    /// defence against an input-method commit, which it never was: no interval
    /// in milliseconds can tell three characters committed at once from three
    /// keys typed quickly. The commit latch handles commits; what is left for
    /// a clock is a key held down, which `keyDown` filters for the click but
    /// cannot filter here, because a repeat still produces characters.
    private var lastSoundedMs: Double?

    mutating func beginCommit() { soundedThisCommit = false }

    /// For a new run or a new game: the tone's history belongs to the old
    /// one. Left standing, the first mistake of a restart lands inside the
    /// previous run's guard window and is swallowed.
    mutating func reset() {
        soundedThisCommit = false
        lastSoundedMs = nil
    }

    /// Whether the tone may play now, recording that it did if so.
    mutating func admit(nowMs: Double) -> Bool {
        guard !soundedThisCommit, mistypeMaySound(lastSoundedMs: lastSoundedMs, nowMs: nowMs)
        else { return false }
        soundedThisCommit = true
        lastSoundedMs = nowMs
        return true
    }
}
