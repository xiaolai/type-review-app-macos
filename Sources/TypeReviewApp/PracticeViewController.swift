import AppKit
import TypeReviewKit

/// The practice screen: the typing surface, and a status bar of live numbers
/// along the bottom. Owns the `Session` and the store.
final class PracticeViewController: NSViewController {
    private let typingView = TypingView()
    private let wpmLabel = NSTextField(labelWithString: "0 wpm")
    private let accuracyLabel = NSTextField(labelWithString: "100%")
    /// The mode as a symbol rather than the word. Two states that never change
    /// mid-run do not need a word each time they are read, and the status bar
    /// is a place for glanceable state — the tooltip carries the name for
    /// anyone who wants it, and the accessibility description carries it for
    /// VoiceOver, so nothing is lost by not spelling it out.
    private let modeIcon = NSImageView()
    /// The two shortcuts, written once. Three copies of this string drifted
    /// into two different orderings.
    private enum Hint {
        static let practising = "⇥ new text · ⏎ next run"
        static let finished = "⏎ next run · ⇥ new text"
    }
    private let hintLabel = NSTextField(labelWithString: Hint.practising)
    private let resultsView = ResultsView()
    /// The on-screen keyboard. It lives in the drawer below the window, so
    /// this controller only drives it.
    ///
    /// Pushed to on assignment rather than only on the next keystroke. The
    /// drawer is built after the window, and building the window is what loads
    /// this view and starts the first run — so the run's own refresh happened
    /// while this was still nil, and the keyboard came up blank: no heat, no
    /// lesson, no next key, until the user typed a character and triggered the
    /// second refresh. Catching up here means the wiring order stops mattering.
    weak var keyboard: KeyboardView? {
        didSet { refresh() }
    }
    /// The adapter reports its pick from a `@Sendable` closure, so the value
    /// lands in a reference box rather than being captured mutably.
    private let entryBox = EntryBox()
    /// What a keystroke on the typing surface should sound like.
    ///
    /// A closure rather than a player of this screen's own. Sound is no longer
    /// a property of the practice window — it can be heard in every app, from
    /// a monitor that has nothing to do with this view — and two players would
    /// mean two audio engines and, when both paths were live, two clicks per
    /// key. The app owns the one player and decides which path feeds it.
    var onKeyStruck: ((UInt16) -> Void)?

    /// Keystroke clock. Injectable for the same reason the engine's is: a
    /// test that types a passage in two milliseconds produces a run at 750,000
    /// wpm, which is not a measurement of anything.
    var clock: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    private var session: Session?
    private var store: ProfileFileStore?
    /// The user's library. Held here because the corpus adapter needs it on
    /// every pick, and read live so an addition applies to the next run.
    var library: LibraryStore { openedLibrary.store }
    /// True when the library could not be opened where it belongs and is
    /// running against a scratch directory instead. The old fallback wrote
    /// `library.json` straight into the shared temporary directory and said
    /// nothing, so the Library window looked durable while the system was free
    /// to delete everything in it — and any other process writing the same
    /// filename would have been reading the user's passages.
    var libraryIsEphemeral: Bool { openedLibrary.ephemeral }
    private let openedLibrary = PracticeViewController.openLibrary()

    private static func openLibrary() -> (store: LibraryStore, ephemeral: Bool) {
        if let store = try? LibraryStore.standard() { return (store, false) }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeReviewUnsavedLibrary", isDirectory: true)
        return (LibraryStore(directory: scratch), true)
    }
    private var pendingSaveError: String?
    /// Set when the profile on disk could not be read. While it is true the
    /// store is never written to: the file may still be recoverable by hand,
    /// and the promise made to the user in that banner is that this app will
    /// not be the thing that destroys it.
    private var profileIsReadOnly = false
    /// Which corpus runs draw from. Remembered across launches.
    var channel: CorpusChannel {
        get {
            CorpusChannel(rawValue: UserDefaults.standard.string(forKey: "CorpusChannel") ?? "")
                ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "CorpusChannel")
            startFreshRun()
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        root.wantsLayer = true
        styleReadouts()
        let status = makeStatusBar()
        // Results occupy the same space as the passage rather than a separate
        // screen: after a run the number you want is where your eyes already
        // are, and Enter starts the next one without moving anything.
        resultsView.isHidden = true
        install(status: status, in: root)
        view = root
    }

    /// The live numbers and the hint line. Readouts, not headings, so they are
    /// set in the secondary colour at the stat size.
    private func styleReadouts() {
        for label in [wpmLabel, accuracyLabel] {
            label.font = Theme.statFont
            label.textColor = Theme.secondaryText
        }
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = Theme.secondaryText
        modeIcon.contentTintColor = Theme.secondaryText
        modeIcon.imageScaling = .scaleProportionallyDown
        modeIcon.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// A status bar, along the bottom, where a status bar goes.
    ///
    /// These change on every keystroke and are read by glancing; putting them
    /// above the passage made the first line of text the second thing on the
    /// screen. The trailing half is the same label that carries the
    /// attribution and any save error, so the credit for a passage sits on the
    /// same line as the numbers rather than on a line of its own.
    private func makeStatusBar() -> NSStackView {
        let metrics = NSStackView(views: [wpmLabel, accuracyLabel, modeIcon])
        metrics.spacing = 14
        metrics.alignment = .centerY
        let status = NSStackView(views: [metrics, hintLabel])
        status.spacing = 16
        status.alignment = .centerY
        status.distribution = .fill
        // The hint takes the slack and truncates; the numbers never move.
        metrics.setContentCompressionResistancePriority(.required, for: .horizontal)
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.lineBreakMode = .byTruncatingTail
        return status
    }

    private func install(status: NSStackView, in root: NSView) {
        for subview in [typingView, resultsView, status] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            typingView.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            typingView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: PracticeWindowMetrics.horizontalInset),
            typingView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -PracticeWindowMetrics.horizontalInset),
            typingView.bottomAnchor.constraint(
                lessThanOrEqualTo: status.topAnchor, constant: -24),

            resultsView.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            resultsView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: PracticeWindowMetrics.horizontalInset),
            resultsView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -PracticeWindowMetrics.horizontalInset),
            resultsView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: PracticeWindowMetrics.horizontalInset),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -PracticeWindowMetrics.horizontalInset),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
    }

    /// The symbol for a mode, with the word kept in the tooltip and the
    /// accessibility description.
    ///
    /// `target` for adaptive, because that is what the planner does — it aims
    /// each lesson at the keys currently costing the most; `stopwatch` for
    /// benchmark, because a benchmark is a measured run against a clock. Both
    /// are compact round marks that stay legible beside 13-point digits, which
    /// `wand.and.stars` did not: at this size its sparkles collapsed into a
    /// smudge.
    ///
    /// Configured explicitly rather than left at the symbol's natural size,
    /// which drew noticeably smaller and lighter than the numbers next to it.
    private func applyMode(_ mode: Mode) {
        let name = mode == .adaptive ? "target" : "stopwatch"
        modeIcon.image = Theme.symbol(
            name, size: Theme.SymbolSize.statusBar, description: mode.rawValue)
        modeIcon.toolTip = mode.rawValue
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        typingView.onCharacter = { [weak self] character in self?.type(character) }
        typingView.onBackspace = { [weak self] in try? self?.session?.backspace(); self?.refresh() }
        typingView.onRestart = { [weak self] in self?.startFreshRun() }
        typingView.onKeyPressed = { [weak self] code in self?.keyboard?.setPressed(code) }
        typingView.onKeyStruck = { [weak self] code in self?.onKeyStruck?(code) }
        applyTypingPreferences()
        typingView.onConfirm = { [weak self] in self?.startFreshRun() }
        start()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(typingView)
    }

    /// Shown whenever there is no more urgent message. A successful profile
    /// save clears `pendingSaveError`, and the library being unwritable is not
    /// something that stops being true when a different file writes.
    private var libraryWarning: String? {
        libraryIsEphemeral ? "library folder unavailable — added text will not be kept" : nil
    }

    private func start() {
        do {
            let store = try ProfileFileStore.standard()
            self.store = store
            let profile: Profile
            switch store.load() {
            case .ok(let loaded):
                profile = loaded
            case .absent:
                profile = Profile()
            case .corrupt(let reason):
                // Never silently start fresh over data that exists: the file
                // stays untouched and the user is told, so a recoverable
                // profile is not overwritten by the next save. The flag is what
                // makes that true — the message alone was a promise the next
                // completed run then broke.
                profile = Profile()
                profileIsReadOnly = true
                pendingSaveError = "profile unreadable (\(reason)) — not overwriting it"
            case .evicted:
                profile = Profile()
            }
            session = try Session(
                profile: profile,
                adaptiveSource: { [unowned self] filter, wordCount, passageLength, rng in
                    // The third argument used to be discarded, which is what
                    // made Short, Medium and Long do nothing at all.
                    try adapter().adaptiveSource(
                        filter: filter, wordCount: wordCount, passageLength: passageLength,
                        rng: &rng)
                },
                benchmarkSource: { [unowned self] wordCount, settings, rng in
                    try adapter().benchmarkSource(
                        wordCount: wordCount, settings: settings, rng: &rng)
                })
            entryBox.commit()
            refresh(resetPassage: true)
        } catch {
            hintLabel.stringValue = "could not start: \(error.localizedDescription)"
        }
    }

    /// Rebuilt per pick so a channel change takes effect on the next run
    /// without rebuilding the session.
    private func adapter() -> CorpusAdapter {
        let box = entryBox
        return CorpusAdapter(channel: channel, library: library.passages) { entry in
            box.staged = entry
        }
    }

    private func type(_ character: String) {
        guard let session, !hasFinished else { return }
        do {
            let feedback = try session.input(character, timeStamp: clock())
            refresh()
            // Latched. `Session.input` goes on answering `.completed` for
            // every further keystroke, and a single multi-character commit
            // from an input method delivers several — so the results screen
            // was rebuilt and the same profile saved synchronously once per
            // surplus character.
            if feedback == .completed {
                hasFinished = true
                finish()
            }
        } catch {
            hintLabel.stringValue = "input failed: \(error.localizedDescription)"
        }
    }

    /// True between a run completing and the next one starting.
    private var hasFinished = false

    /// Per-key statistics, cached against the number of runs they were built
    /// from.
    ///
    /// This walked the entire saved history on every keystroke *and* every
    /// backspace, on the main thread, to redraw a keyboard whose input only
    /// changes when a run finishes. The cost grew with the profile: the more
    /// someone practises, the slower their typing surface gets.
    private var cachedPerKey: (count: Int, stats: OrderedMap<PerKeyStat>)?

    private func perKeyStats(for results: [RunResult]) -> OrderedMap<PerKeyStat> {
        if let cachedPerKey, cachedPerKey.count == results.count { return cachedPerKey.stats }
        let stats = aggregatePerKey(results)
        cachedPerKey = (results.count, stats)
        return stats
    }

    /// Credits the passage's source when there is one to credit.
    private func attribution() -> String {
        guard let entry = entryBox.value, let attribution = entry.attribution else { return "" }
        let parts = [attribution.title, attribution.author].compactMap { $0 }
        let name = parts.isEmpty ? entry.id : parts.joined(separator: " — ")
        return "\(name) · \(attribution.license)"
    }

    /// Posted when a run finishes, so a Statistics window that is already open
    /// can bring itself up to date.
    static let runCompleted = Notification.Name("TypeRunCompleted")

    private func finish() {
        guard let session, let result = session.profile.results.last else { return }
        defer { NotificationCenter.default.post(name: Self.runCompleted, object: nil) }
        resultsView.show(result: result, history: session.profile.results)
        typingView.isHidden = true
        resultsView.isHidden = false
        hintLabel.stringValue = Hint.finished
        if let message = persist(session.profile) ?? libraryWarning {
            hintLabel.stringValue = message
        }
    }

    /// Saves the profile unless the file on disk is one we promised not to
    /// touch. Returns a message to show the user, or nil when the save went
    /// through.
    @discardableResult
    private func persist(_ profile: Profile) -> String? {
        guard !profileIsReadOnly else { return pendingSaveError }
        guard let store else { return nil }
        do {
            try store.save(profile)
            pendingSaveError = nil
            return nil
        } catch {
            // Surfaced rather than swallowed: a failed save is the one error
            // in this app that costs the user something.
            pendingSaveError = "could not save: \(error.localizedDescription)"
            return pendingSaveError
        }
    }

    /// The passage on screen. Used by `--selftest`, which drives the real
    /// Runs recorded in memory. `--selftest` compares this against what
    /// reached disk, so a save failure is distinguishable from a run that
    /// never completed.
    var runCount: Int { session?.profile.results.count ?? -1 }

    /// Every recorded run, for the statistics window.
    var history: [RunResult] { session?.profile.results ?? [] }

    var currentSettings: ProfileSettings { session?.profile.settings ?? .default }

    /// Applies settings from the Settings window. Returns false when the
    /// engine refuses them.
    ///
    /// Mid-run changes are staged rather than applied: `updateSettings` starts
    /// a new run, which would throw away a paragraph the user is halfway
    /// through. Before the first keystroke a restart is what they expect —
    /// the new word count should be visible immediately.
    @discardableResult
    func applySettings(_ next: ProfileSettings) -> Bool {
        guard let session, let validated = validateSettings(encodeForValidation(next)) else {
            return false
        }
        if session.keystrokes == 0 {
            // `updateSettings` assigns before it restarts, and the restart can
            // fail — so a rejected value stayed installed, was read back by
            // the Settings window as if it had been accepted, and could be
            // saved by the next successful write. Put back on failure.
            let previous = session.profile.settings
            do {
                try session.updateSettings(validated)
                entryBox.commit()
            } catch {
                try? session.updateSettings(previous)
                hintLabel.stringValue = "could not apply: \(error.localizedDescription)"
                return false
            }
            refresh(resetPassage: true)
        } else {
            session.stageSettings(validated)
        }
        // Applied but unsaved is not the same as rejected, and the window is
        // told which it was. Returning false here made it re-read and display
        // the *old* value, which was untrue — the setting was live, it just
        // had not reached the disk. The message says so; the control keeps
        // what the user chose.
        if let message = persist(session.profile) {
            hintLabel.stringValue = message
        }
        return true
    }

    /// Round-trips through the serializer so the settings take the same path
    /// into the validator that a stored profile does. Anything the validator
    /// would reject on load is therefore rejected here, at the moment the user
    /// can see which control caused it.
    private func encodeForValidation(_ settings: ProfileSettings) -> Any? {
        let json = JSONWriter.stringify(serializeProfile(Profile(settings: settings)))
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["settings"]
    }

    var currentPassage: String {
        (try? session?.snapshot().typing.expected) ?? ""
    }

    func startFreshRun() {
        // A session that never started can still start later — the library
        // passage that broke it may have been deleted, or the profile
        // repaired. Without this, one bad startup meant "New Text" did
        // nothing until the app was relaunched.
        guard let session else { return start() }
        do {
            try session.start()
            entryBox.commit()
        } catch {
            // Reported, and the screen left alone. `try?` here swallowed a
            // failure to source text — a library passage containing an emoji
            // fails `TextInput` — while `refresh(resetPassage:)` went ahead
            // and presented the *previous* run as if it were the new one.
            hintLabel.stringValue = "could not start a new run: \(error.localizedDescription)"
            return
        }
        hasFinished = false
        refresh(resetPassage: true)
    }

    private func refresh(resetPassage: Bool = false) {
        guard let session, let snapshot = try? session.snapshot() else { return }
        if resetPassage {
            typingView.setPassage(
                snapshot.typing.expected, statuses: snapshot.typing.statuses,
                cursor: snapshot.typing.pos)
            typingView.isHidden = false
            resultsView.isHidden = true
            keyboard?.setPressed(nil)
            let credit = attribution()
            hintLabel.stringValue = pendingSaveError ?? libraryWarning
                ?? (credit.isEmpty ? Hint.practising : credit)
            view.window?.makeFirstResponder(typingView)
        } else {
            typingView.update(statuses: snapshot.typing.statuses, cursor: snapshot.typing.pos)
        }
        // The keyboard highlights the character the passage wants next, and
        // tints every key by how that key is actually going.
        // Indexed, not materialised. Building the passage's whole UTF-16
        // array to read one unit ran on every keystroke, and a long library
        // passage made that a full allocation each time.
        let units = snapshot.typing.expected.utf16
        let next = units.index(units.startIndex, offsetBy: snapshot.typing.pos, limitedBy: units.endIndex)
            .flatMap { $0 == units.endIndex ? nil : String(utf16CodeUnits: [units[$0]], count: 1) }
        keyboard?.update(
            stats: perKeyStats(for: session.profile.results), plan: snapshot.plan,
            expected: next?.lowercased(), targetWpm: session.profile.settings.targetWpm)
        wpmLabel.stringValue = String(format: "%.0f wpm", snapshot.liveMetrics.netWpm)
        accuracyLabel.stringValue = String(format: "%.0f%%", snapshot.liveMetrics.accuracy)
        applyMode(snapshot.mode)
    }
}

extension PracticeViewController {
    /// Pushes the stored sound preferences into the player. Called at load and
    /// again whenever the Settings window changes them, so a pack or volume
    /// picked mid-run takes effect on the very next keystroke rather than at
    /// Caret shape and whitespace marks. Both are pure presentation — the
    /// view redraws and nothing about the run changes — so they apply live
    /// rather than at the next passage.
    func applyTypingPreferences() {
        typingView.caretStyle = AppPreferences.caretStyle.value
        typingView.showsWhitespace = AppPreferences.showWhitespace.value
    }
}
