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

    /// Another running copy of *this same build*, if there is one.
    ///
    /// Distinct from `runningSibling`, which is the other channel. Two copies
    /// of one build is a defect; two channels is a choice.
    static var duplicate: NSRunningApplication? {
        guard let mine = Bundle.main.bundleIdentifier else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == mine && $0 != NSRunningApplication.current
        }
    }

    /// Hands over to a copy that is already running, and says whether it did.
    ///
    /// `LSMultipleInstancesProhibited` covers this for anything LaunchServices
    /// launches — `open`, the Dock, Spotlight — and measured, it does: `open
    /// -n` yields one process with the key and two without. It does not cover
    /// running the executable inside the bundle directly, which bypasses
    /// LaunchServices entirely and was measured at two.
    ///
    /// That path is mostly a developer's, but the symptom is not: two
    /// processes mean two event taps and every keystroke heard twice, with
    /// nothing on screen to explain it. Whether a login-item launch and a
    /// manual one can collide the same way has not been ruled out, and this
    /// closes it either way.
    ///
    /// Activate-and-exit rather than an error, because that is exactly what
    /// `open` already does for the same build. Nothing new to understand.
    static func deferToRunningCopy() -> Bool {
        guard let existing = duplicate else { return false }
        // Not "someone else is there, so I go". Two copies started together
        // each see the other and each would leave, which is worse than the
        // duplication it prevents. The same total order the channels use
        // settles it: the newer process defers, and with no usable dates the
        // lower process identifier stays — arbitrary, and decided identically
        // on both sides, which is the only property that matters.
        let mine = NSRunningApplication.current.launchDate
        let theirs = existing.launchDate
        let iAmNewer: Bool
        if let mine, let theirs, mine != theirs {
            iAmNewer = mine > theirs
        } else {
            iAmNewer = ProcessInfo.processInfo.processIdentifier > existing.processIdentifier
        }
        guard iAmNewer else { return false }
        // #9: activation can fail, and reporting success either way would exit
        // this copy while nothing came forward — the app would look as though
        // it simply refused to open. Staying is the safe direction: a second
        // copy that keeps running is visible and fixable; one that vanishes is
        // neither.
        guard existing.activate() else { return false }
        return true
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
        if let theirs = other.launchDate,
            let mine = NSRunningApplication.current.launchDate,
            mine != theirs
        {
            return mine > theirs
        }
        // No usable dates, or the same instant. Yielding here was the first
        // answer and it was wrong in the worst way: `launchDate` is nil for a
        // process not started through LaunchServices, and *both* copies would
        // then read nil, both yield, and the machine go silent — precisely the
        // outcome the tie-break exists to prevent, reached by the path meant
        // to be the safe one. Identifier order is arbitrary and, unlike
        // yielding, it is a total order: exactly one side of any pair loses.
        return (Bundle.main.bundleIdentifier ?? "") > (sibling ?? "")
    }

    static var runningSibling: NSRunningApplication? {
        guard let sibling else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == sibling
        }
    }
}
