import AppKit
import TypeReviewKit

/// Play: things fall, and typing them makes them burst.
///
/// The practice screen with gravity. The same ground, typing font, status
/// colours, caret and whitespace marks, drawn through `PassageInk`; the
/// practice screen's status bar, in the same place and set the same way; the
/// same keyboard drawer, driven the same way; the same sounds, routed by the
/// same switch in `AppDelegate`. Only motion is new.
///
/// The rules are `FallingGame`, in the Kit. This screen gives them time, keys
/// and a place to be seen, and never touches the profile.
@MainActor
final class PlayViewController: NSViewController {
    private let playfield = Playfield()
    private let scoreLabel = NSTextField(labelWithString: "0 pts")
    private let streakLabel = NSTextField(labelWithString: "0 in a row")
    private let livesLabel = NSTextField(labelWithString: "3 lives")
    private let modeIcon = NSImageView()
    private let hintLabel = NSTextField(labelWithString: "")

    private enum Hint {
        static let ready = "type to start · esc pauses"
        static let playing = "esc pauses · ⇥ new game"
        static let paused = "paused · any key carries on"
        static let over = "game over · ⏎ new game"
    }

    /// The drawer's keyboard while this screen shows, nil while it does not.
    weak var keyboard: KeyboardView? {
        didSet {
            keyboardIsStale = true
            pushKeyboard()
        }
    }
    /// The practice screen's three sound hooks, set by `AppDelegate` from the
    /// same switch, so one path sounds a key and never two.
    var onKeyStruck: ((UInt16) -> Void)?
    var onKeyReleased: ((UInt16) -> Void)?
    var onMistype: (() -> Void)?
    /// The lesson practice would plan next. Letters drops its letters.
    var planSource: () -> LessonPlan = { lessonPlan(for: Profile()) }

    /// The view that takes the keys when this screen is shown.
    var focusView: NSView { playfield }

    private(set) var mode = AppPreferences.playMode.value
    private(set) var gentle = !AppPreferences.playArcade.value
    private var art = PlayArt()
    private lazy var stage = PlayStage(world: playfield.world, art: art)
    private(set) lazy var game = makeGame()
    private var plan = lessonPlan(for: Profile())

    enum State { case ready, playing, paused, over }
    private(set) var state = State.ready
    /// After a burst the world holds still this long: the moment that makes a
    /// pop read as a hit rather than a disappearance.
    private var stopFor = 0.0
    private var lastExpected: String?
    private var keyboardIsStale = true

    private let speech = SpeechPlayer()
    private var speaksWords = false
    private var soundsMistypes = true
    private var soundedThisCommit = false
    private var lastMistypeSoundMs: Double?

    override func loadView() {
        let root = GroundedView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        root.wantsLayer = true
        styleReadouts()
        let status = makeStatusBar()
        for subview in [playfield, status] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        let inset = PracticeWindowMetrics.horizontalInset
        NSLayoutConstraint.activate([
            // The full width, and from the very top: things fall in from under
            // the title bar rather than appearing at a line 20 points down.
            playfield.topAnchor.constraint(equalTo: root.topAnchor),
            playfield.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            playfield.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            playfield.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            // The practice status bar's own insets.
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        view = root
    }

    /// `PracticeViewController.styleReadouts`, for three readouts.
    private func styleReadouts() {
        for label in [scoreLabel, streakLabel, livesLabel] {
            label.font = Theme.statFont
            label.textColor = Theme.secondaryText
        }
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = Theme.secondaryText
        modeIcon.contentTintColor = Theme.secondaryText
        modeIcon.imageScaling = .scaleProportionallyDown
        modeIcon.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// `PracticeViewController.makeStatusBar`, with the game's readouts.
    private func makeStatusBar() -> NSStackView {
        let metrics = NSStackView(views: [scoreLabel, streakLabel, livesLabel, modeIcon])
        metrics.spacing = 14
        metrics.alignment = .centerY
        let status = NSStackView(views: [metrics, hintLabel])
        status.spacing = 16
        status.alignment = .centerY
        status.distribution = .fill
        metrics.setContentCompressionResistancePriority(.required, for: .horizontal)
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.lineBreakMode = .byTruncatingTail
        return status
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        playfield.onCharacter = { [weak self] character in self?.type(character) }
        playfield.onCommitBegan = { [weak self] in self?.soundedThisCommit = false }
        playfield.onKeyPressed = { [weak self] code in self?.keyboard?.setPressed(code) }
        playfield.onKeyStruck = { [weak self] code in self?.onKeyStruck?(code) }
        playfield.onKeyReleased = { [weak self] code in self?.onKeyReleased?(code) }
        playfield.onPause = { [weak self] in self?.pause() }
        playfield.onRestart = { [weak self] in self?.newGame() }
        playfield.onConfirm = { [weak self] in
            if self?.state == .over { self?.newGame() }
        }
        playfield.onFocusLost = { [weak self] in self?.pause() }
        playfield.onFrame = { [weak self] dt in self?.advance(by: dt) }
        playfield.onDisplayChange = { [weak self] in self?.displayChanged() }
        // The voice follows the language of what is spoken, as it does for a
        // passage; everything Play says is English.
        speech.setPassage(PlayText.sentences.joined(separator: " "))
        applyTypingPreferences()
        newGame()
    }

    // MARK: - The game

    private func makeGame() -> FallingGame {
        let game = FallingGame(
            mode: mode, gentle: gentle, letters: plan.included, cell: art.cell(mode),
            seed: UInt32.random(in: .min ... .max))
        game.margin = Double(PracticeWindowMetrics.horizontalInset)
        return game
    }

    /// A fresh game, remembering the mode and rules it is given.
    func newGame(mode: PlayMode? = nil, gentle: Bool? = nil) {
        if let mode {
            self.mode = mode
            AppPreferences.playMode.value = mode
        }
        if let gentle {
            self.gentle = gentle
            AppPreferences.playArcade.value = !gentle
        }
        plan = planSource()
        stage.clear()
        game = makeGame()
        state = .ready
        stopFor = 0
        lastMistypeSoundMs = nil
        soundedThisCommit = false
        keyboardIsStale = true
        modeIcon.image = Theme.symbol(
            Self.symbol(for: self.mode), size: Theme.SymbolSize.statusBar,
            description: Self.label(for: self.mode))
        modeIcon.toolTip = Self.label(for: self.mode)
        refreshStatus()
        pushKeyboard()
    }

    func pause() {
        guard state == .playing else { return }
        state = .paused
        refreshStatus()
        pushKeyboard()
    }

    /// One step of time. The display link calls this once a frame; the
    /// self-test calls it directly, which is how a check drives the game
    /// without a screen.
    func advance(by dt: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let height = playfield.bounds.height
        game.field = PlaySize(width: Double(playfield.bounds.width), height: Double(height))
        switch state {
        case .playing:
            if stopFor > 0 {
                stopFor -= dt
            } else {
                apply(game.update(dt: dt))
                stage.step(dt, height: height)
            }
        case .over:
            stage.step(dt, height: height)
        case .ready, .paused:
            break
        }
        stage.sync(game, height: height)
        refreshStatus()
        pushKeyboard()
    }

    private func type(_ character: String) {
        switch state {
        case .ready, .paused:
            // The first key starts the game, or carries it on, and is not
            // itself scored: nothing was falling for it to be aimed at.
            state = .playing
            refreshStatus()
            pushKeyboard()
            return
        case .over:
            return
        case .playing:
            break
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(game.type(character))
        stage.sync(game, height: playfield.bounds.height)
        CATransaction.commit()
        refreshStatus()
        pushKeyboard()
    }

    private func apply(_ events: [PlayEvent]) {
        for event in events {
            switch event {
            case .wrong:
                soundMistype()
            case .burst(let id, let indices, let word):
                stage.burst(id, indices: indices, mode: mode)
                stopFor = mode == .letters ? 0.045 : 0.07
                speak(word)
            case .cleared(let id, let points):
                stage.pop(id, points: points)
            case .sentenceDone(let text):
                stage.shower(width: playfield.bounds.width, height: playfield.bounds.height)
                speak(text)
            case .landed:
                break
            case .lost(let id):
                stage.crumble(id, mode: mode)
            case .over:
                state = .over
            }
        }
    }

    /// The practice screen's two guards, for the practice screen's reasons:
    /// one tone per commit, and none faster than a held key would repeat.
    private func soundMistype() {
        guard soundsMistypes, !soundedThisCommit else { return }
        let now = Date().timeIntervalSince1970 * 1000
        guard mistypeMaySound(lastSoundedMs: lastMistypeSoundMs, nowMs: now) else { return }
        soundedThisCommit = true
        lastMistypeSoundMs = now
        onMistype?()
    }

    /// A finished word, said aloud when Speak Words is on — the practice
    /// screen's setting, for the practice screen's reason. On the next turn of
    /// the runloop, never on the keystroke's stack: `speakFinishedWord`
    /// measured what happens otherwise.
    private func speak(_ text: String) {
        guard speaksWords, !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.speaksWords else { return }
            self.speech.speak(word: text)
        }
    }

    // MARK: - Preferences and display

    /// Caret, whitespace marks, which keyboards may type, speech and the
    /// error tone: the practice screen's typing preferences, applied here too.
    func applyTypingPreferences() {
        playfield.latinInputOnly = AppPreferences.latinInputOnly.value
        speaksWords = AppPreferences.speakWords.value
        soundsMistypes = AppPreferences.mistypeSound.value
        if speaksWords { speech.prepare() }
        displayChanged()
    }

    private func displayChanged() {
        art.caret = AppPreferences.caretStyle.value
        art.showsWhitespace = AppPreferences.showWhitespace.value
        if let window = view.window {
            art.scale = window.backingScaleFactor
            if let space = window.colorSpace?.cgColorSpace { art.colorSpace = space }
        }
        art.appearance = playfield.effectiveAppearance
        stage.art = art
        stage.reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Status and keyboard

    private func refreshStatus() {
        set(scoreLabel, "\(game.score) pts")
        set(streakLabel, "\(game.streak) in a row")
        set(livesLabel, "\(game.lives) \(game.lives == 1 ? "life" : "lives")")
        if livesLabel.isHidden != gentle { livesLabel.isHidden = gentle }
        switch state {
        case .ready: set(hintLabel, Hint.ready)
        case .playing: set(hintLabel, Hint.playing)
        case .paused: set(hintLabel, Hint.paused)
        case .over: set(hintLabel, Hint.over)
        }
    }

    /// Only on a change: this is asked every frame, and a label handed its own
    /// value still invalidates its layout.
    private func set(_ label: NSTextField, _ text: String) {
        if label.stringValue != text { label.stringValue = text }
    }

    /// The next key, lit as the practice screen lights it. No heat: a heat map
    /// is for reading afterwards, and during a game it is noise. The lesson
    /// only in Letters, where its letters are what falls.
    private func pushKeyboard() {
        let expected = state == .playing ? game.expected?.lowercased() : nil
        guard expected != lastExpected || keyboardIsStale else { return }
        lastExpected = expected
        keyboardIsStale = false
        keyboard?.update(
            stats: OrderedMap(), plan: mode == .letters ? plan : nil, expected: expected,
            targetWpm: 35)
    }

    static func label(for mode: PlayMode) -> String {
        switch mode {
        case .letters: return "Letters"
        case .words: return "Words"
        case .sentences: return "Sentences"
        }
    }

    /// The status bar's mark for a mode, as `target` and `stopwatch` are for
    /// practice's two.
    static func symbol(for mode: PlayMode) -> String {
        switch mode {
        case .letters: return "character"
        case .words: return "textformat.abc"
        case .sentences: return "text.alignleft"
        }
    }

    // MARK: - For the self-test

    /// Pieces of bursts still in flight.
    var effectsInFlight: Int { stage.effectsInFlight }

    /// The image a falling item is showing.
    func image(forItem id: Int) -> CGImage? { stage.image(forItem: id) }

    /// An item drawn as if it were not the target: its letters and nothing
    /// else, for a check that must not count the caret as ink.
    func imageWithoutCaret(of item: FallingItem) -> CGImage? {
        art.image(of: item, mode: mode, target: false, wrong: false)
    }

    /// Commits text through the input client, the path AppKit uses.
    func typeThroughInput(_ text: String) {
        playfield.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}
