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

    /// Keystroke clock. Injectable for the same reason the engine's is: a
    /// test that types a passage in two milliseconds produces a run at 750,000
    /// wpm, which is not a measurement of anything.
    var clock: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    private var session: Session?
    private var store: ProfileFileStore?
    private var pendingSaveError: String?

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

        for subview in [header, typingView, resultsView, footer] {
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
                lessThanOrEqualTo: footer.topAnchor, constant: -24),

            resultsView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 32),
            resultsView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            resultsView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            resultsView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        typingView.onCharacter = { [weak self] character in self?.type(character) }
        typingView.onBackspace = { [weak self] in try? self?.session?.backspace(); self?.refresh() }
        typingView.onRestart = { [weak self] in self?.startFreshRun() }
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
            session = try Session(profile: profile)
            refresh(resetPassage: true)
        } catch {
            hintLabel.stringValue = "could not start: \(error.localizedDescription)"
        }
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
            hintLabel.stringValue = pendingSaveError ?? "⇥ new text · ⏎ next run"
            view.window?.makeFirstResponder(typingView)
        } else {
            typingView.update(statuses: snapshot.typing.statuses, cursor: snapshot.typing.pos)
        }
        wpmLabel.stringValue = String(format: "%.0f wpm", snapshot.liveMetrics.netWpm)
        accuracyLabel.stringValue = String(format: "%.0f%%", snapshot.liveMetrics.accuracy)
        modeLabel.stringValue = snapshot.mode.rawValue
    }
}
