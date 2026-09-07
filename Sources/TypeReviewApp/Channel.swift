import AppKit

/// Which of the two builds this is, and where the other one would be.
///
/// The app ships through two channels — the Mac App Store and a Homebrew cask
/// — signed with different certificates, so they carry different bundle
/// identifiers. That is not a preference: a grant in Privacy is bound to the
/// code's designated requirement, and the two signatures do not share one, so
/// the system was always going to see two applications. Naming them apart is
/// what makes them addressable rather than merely different.
///
/// It is also what makes this file possible. With one identifier the two
/// installs would be indistinguishable, and nothing here could be written.
enum Channel {
    /// The App Store build takes the plain identifier, because a store
    /// identifier is bound to the product record and cannot be changed
    /// afterwards without becoming a different product. The direct one can be
    /// renamed for nothing, so it carries the suffix.
    static let appStore = "review.type.app"
    static let direct = "review.type.app.direct"

    /// The other install's identifier, or nil when this is neither — a build
    /// run straight out of Xcode, say. Neither means no sibling to look for,
    /// which is the right answer rather than a guess at one.
    static var sibling: String? {
        switch Bundle.main.bundleIdentifier {
        case appStore: return direct
        case direct: return appStore
        default: return nil
        }
    }

    /// Whether this copy should stay quiet because the other one is already
    /// doing the job.
    ///
    /// The question worth asking is not "is the other one installed" — two
    /// copies on disk cost nothing. It is which of two *listening* copies
    /// should stop, because two taps mean every keystroke sounds twice, and
    /// that is the symptom someone meets long before they think about bundle
    /// identifiers.
    ///
    /// The rule has to give both copies the same answer, and the obvious one
    /// does not. "Whichever finds the other already there stands down" is not
    /// symmetric: each receives the other's launch notification, each
    /// concludes it should yield, and the machine goes silent — worse than the
    /// doubling it was meant to fix.
    ///
    /// Launch order is symmetric, and it is also what a person expects: the
    /// copy that was already running keeps the sound. Both sides compare the
    /// same two dates and reach opposite conclusions, which is exactly what is
    /// needed.
    static var shouldYieldToSibling: Bool {
        guard let other = runningSibling else { return false }
        guard let theirs = other.launchDate,
            let mine = NSRunningApplication.current.launchDate
        else {
            // No dates to compare. Yield: one copy sounding is a working app,
            // and two is a broken-sounding one.
            return true
        }
        if mine != theirs { return mine > theirs }
        // Launched in the same instant, which is not realistic and is still
        // cheaper to settle than to leave to chance. Any total order will do
        // as long as both copies compute it identically.
        return (Bundle.main.bundleIdentifier ?? "") > (sibling ?? "")
    }

    static var runningSibling: NSRunningApplication? {
        guard let sibling else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == sibling
        }
    }
}
