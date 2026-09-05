import AppKit
import TypeReviewKit

/// The practice screen: a header of live numbers, the typing surface, and a
/// footer hint. Owns the `Session` and the store.
final class PracticeViewController: NSViewController {
    private let typingView = TypingView()
    private let wpmLabel = NSTextField(labelWithString: "0 wpm")
    private let accuracyLabel = NSTextField(labelWithString: "100%")
    private let modeLabel = NSTextField(labelWithString: "benchmark")
    private let hintLabel = NSTextField(labelWithString: "⇥ new text · ⏎ next run")
    private let resultsView = ResultsView()
    private let keyboardView = KeyboardView()
    /// The adapter reports its pick from a `@Sendable` closure, so the value
    /// lands in a reference box rather than being captured mutably.
    private let entryBox = EntryBox()
    private var keyboardHeight: NSLayoutConstraint?

    /// Keystroke clock. Injectable for the same reason the engine's is: a
    /// test that types a passage in two milliseconds produces a run at 750,000
    /// wpm, which is not a measurement of anything.
    var clock: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    private var session: Session?
    private var store: ProfileFileStore?
    private var pendingSaveError: String?
    private var currentEntry: CorpusEntry?
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

        for label in [wpmLabel, accuracyLabel, modeLabel] {
            label.font = Theme.statFont
            label.textColor = Theme.secondaryText
        }
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = Theme.secondaryText
        let header = NSStackView(views: [wpmLabel, accuracyLabel, modeLabel])
        header.spacing = 18
        let footer = NSStackView(views: [hintLabel])
        footer.spacing = 18
        // Results occupy the same space as the passage rather than a separate
        // screen: after a run the number you want is where your eyes already
        // are, and Enter starts the next one without moving anything.
        resultsView.isHidden = true

        for subview in [header, typingView, resultsView, keyboardView, footer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -32),

            typingView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 32),
            typingView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            typingView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            typingView.bottomAnchor.constraint(
                lessThanOrEqualTo: keyboardView.topAnchor, constant: -24),

            resultsView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 32),
            resultsView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            resultsView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            resultsView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

            keyboardView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            keyboardView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            keyboardView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),


            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        // Sized from the geometry rather than a guessed constant, so the
        // bottom row is never clipped and an ISO or JIS keyboard — which has
        // an extra key per row, making every key narrower and the whole
        // keyboard shorter — still fits exactly.
        keyboardHeight = keyboardView.heightAnchor.constraint(equalToConstant: 200)
        keyboardHeight?.isActive = true
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width - 64
        keyboardHeight?.constant = keyboardView.height(forWidth: width)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        typingView.onCharacter = { [weak self] character in self?.type(character) }
        typingView.onBackspace = { [weak self] in try? self?.session?.backspace(); self?.refresh() }
        typingView.onRestart = { [weak self] in self?.startFreshRun() }
        typingView.onKeyPressed = { [weak self] code in self?.keyboardView.setPressed(code) }
        typingView.onConfirm = { [weak self] in self?.startFreshRun() }
        start()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(typingView)
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
                // profile is not overwritten by the next save.
                profile = Profile()
                pendingSaveError = "profile unreadable (\(reason)) — not overwriting it"
            case .evicted:
                profile = Profile()
            }
            session = try Session(
                profile: profile,
                adaptiveSource: { [unowned self] filter, wordCount, _, rng in
                    try adapter().adaptiveSource(filter: filter, wordCount: wordCount, rng: &rng)
                },
                benchmarkSource: { [unowned self] wordCount, settings, rng in
                    try adapter().benchmarkSource(
                        wordCount: wordCount, settings: settings, rng: &rng)
                })
            refresh(resetPassage: true)
        } catch {
            hintLabel.stringValue = "could not start: \(error.localizedDescription)"
        }
    }

    /// Rebuilt per pick so a channel change takes effect on the next run
    /// without rebuilding the session.
    private func adapter() -> CorpusAdapter {
        let box = entryBox
        return CorpusAdapter(channel: channel) { entry in box.value = entry }
    }

    private func type(_ character: String) {
        guard let session else { return }
        do {
            let feedback = try session.input(character, timeStamp: clock())
            refresh()
            if feedback == .completed { finish() }
        } catch {
            hintLabel.stringValue = "input failed: \(error.localizedDescription)"
        }
    }

    /// Credits the passage's source when there is one to credit.
    private func attribution() -> String {
        guard let entry = entryBox.value, let attribution = entry.attribution else { return "" }
        let parts = [attribution.title, attribution.author].compactMap { $0 }
        let name = parts.isEmpty ? entry.id : parts.joined(separator: " — ")
        return "\(name) · \(attribution.license)"
    }

    private func finish() {
        guard let session, let store, let result = session.profile.results.last else { return }
        resultsView.show(result: result, history: session.profile.results)
        typingView.isHidden = true
        resultsView.isHidden = false
        hintLabel.stringValue = "⏎ next run · ⇥ new text"
        do {
            try store.save(session.profile)
            pendingSaveError = nil
        } catch {
            // Surfaced rather than swallowed: a failed save is the one error
            // in this app that costs the user something.
            pendingSaveError = "could not save: \(error.localizedDescription)"
            hintLabel.stringValue = pendingSaveError!
        }
    }

    /// The passage on screen. Used by `--selftest`, which drives the real
    /// input path rather than reaching into the session.
    /// Runs recorded in memory. `--selftest` compares this against what
    /// reached disk, so a save failure is distinguishable from a run that
    /// never completed.
    var runCount: Int { session?.profile.results.count ?? -1 }

    /// Every recorded run, for the statistics window.
    var history: [RunResult] { session?.profile.results ?? [] }

    var currentSettings: ProfileSettings { session?.profile.settings ?? .default }

    func setKeyboardVisible(_ visible: Bool) {
        keyboardView.isHidden = !visible
    }

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
            try? session.updateSettings(validated)
            refresh(resetPassage: true)
        } else {
            session.stageSettings(validated)
        }
        try? store?.save(session.profile)
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
        try? session?.start()
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
            keyboardView.setPressed(nil)
            let credit = attribution()
            hintLabel.stringValue = pendingSaveError
                ?? (credit.isEmpty ? "⇥ new text · ⏎ next run" : credit)
            view.window?.makeFirstResponder(typingView)
        } else {
            typingView.update(statuses: snapshot.typing.statuses, cursor: snapshot.typing.pos)
        }
        // The keyboard highlights the character the passage wants next, and
        // tints every key by how that key is actually going.
        let next = snapshot.typing.pos < snapshot.typing.expected.utf16.count
            ? String(
                utf16CodeUnits: [Array(snapshot.typing.expected.utf16)[snapshot.typing.pos]],
                count: 1)
            : nil
        keyboardView.update(
            stats: aggregatePerKey(session.profile.results), expected: next?.lowercased(),
            targetWpm: session.profile.settings.targetWpm)
        wpmLabel.stringValue = String(format: "%.0f wpm", snapshot.liveMetrics.netWpm)
        accuracyLabel.stringValue = String(format: "%.0f%%", snapshot.liveMetrics.accuracy)
        modeLabel.stringValue = snapshot.mode.rawValue
    }
}
