import AppKit
import TypeReviewKit

/// Play: things fall, and typing them makes them burst.
///
/// The practice screen with gravity. The same ground, typing font, status
/// colours, caret and whitespace marks, drawn through `PassageInk`; the
/// practice screen's status bar, built by the same `StatusBar`; the same keys,
/// through the same `KeyInput`; the same keyboard drawer, driven the same way;
/// the same sounds, routed by the same switch in `AppDelegate` and gated by
/// the same `MistypeGate`. Only motion is new.
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
        // Typing, not any key: only a character reaches the game, so Esc,
        // Return and the arrows leave it paused.
        static let paused = "paused · type to carry on"
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
    /// The lesson practice would plan next, or nil when practice has no
    /// profile to plan from. Letters drops its letters.
    var planSource: () -> LessonPlan? = { nil }
    /// Keystroke clock for the error tone's guard. Injectable, as practice's
    /// is, so the two screens' guards run on the same time.
    var clock: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    /// Whether a wrong key asks for the error tone. The Mistype Sound setting,
    /// applied by `applyTypingPreferences`; the self-test sets it directly, so
    /// it can hear the tone's wiring whatever the user chose without writing
    /// over their choice.
    var soundsMistypes = true

    /// The view that takes the keys when this screen is shown.
    var focusView: NSView { playfield }

    private(set) var mode = AppPreferences.playMode.value
    private(set) var gentle = !AppPreferences.playArcade.value
    private var art = PlayArt()
    private lazy var stage = PlayStage(world: playfield.world, art: art)
    private(set) lazy var game = makeGame()
    /// The lesson this game was planned from. What Letters drops, and what the
    /// keyboard shows while it does.
    private(set) var plan = PlayViewController.firstLesson

    /// What Letters drops when practice has no lesson to offer — it could not
    /// start, and says so on its own screen. The first lesson, which is where
    /// a typist with no history begins anyway.
    private static let firstLesson = lessonPlan(for: Profile())

    enum State { case ready, playing, paused, over }
    private(set) var state = State.ready
    /// After a burst the world holds still this long: the moment that makes a
    /// pop read as a hit rather than a disappearance.
    private var stopFor = 0.0
    private var lastExpected: String?
    private var keyboardIsStale = true

    private let speech = SpeechPlayer()
    private var speaksWords = false
    /// Moves on whenever what was queued to be said stops being wanted — a
    /// new game, or leaving the screen — so a word queued for a game that is
    /// gone is dropped rather than said over the next one.
    private var speechEpoch = 0
    private var mistypeGate = MistypeGate()
    /// Held for the controller's life, which is the app's.
    private var motionObserver: NSObjectProtocol?

    override func loadView() {
        // A plain view: the window's ground belongs to `MainScreenController`.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        root.wantsLayer = true
        let status = StatusBar.make(
            readouts: [scoreLabel, streakLabel, livesLabel], mode: modeIcon, hint: hintLabel)
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

    override func viewDidLoad() {
        super.viewDidLoad()
        playfield.onCharacter = { [weak self] character in self?.type(character) }
        playfield.onCommitBegan = { [weak self] in self?.mistypeGate.beginCommit() }
        playfield.onKeyPressed = { [weak self] code in self?.keyboard?.setPressed(code) }
        playfield.onKeyStruck = { [weak self] code in self?.onKeyStruck?(code) }
        playfield.onKeyReleased = { [weak self] code in self?.onKeyReleased?(code) }
        playfield.onPause = { [weak self] in self?.pause() }
        playfield.onRestart = { [weak self] in self?.newGame() }
        playfield.onConfirm = { [weak self] in
            if self?.state == .over { self?.newGame() }
        }
        playfield.onFocusLost = { [weak self] in self?.pause() }
        playfield.onFrame = { [weak self] dt in
            guard let self, !self.holdsTime else { return }
            self.advance(by: dt)
        }
        playfield.onDisplayChange = { [weak self] in self?.displayChanged() }
        playfield.caretIndex = { [weak self] in self?.game.target?.typed ?? 0 }
        playfield.caretRect = { [weak self] in
            guard let self else { return nil }
            return self.stage.caretRect(in: self.game)
        }
        playfield.onCompositionChanged = { [weak self] text in
            guard let self else { return }
            self.stage.showComposition(text, in: self.game)
        }
        // Reduce Motion can change while a game is on screen, and nothing else
        // this screen hears about would carry it.
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayChanged() }
        }
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
            seed: nextSeed())
        game.margin = Double(PracticeWindowMetrics.horizontalInset)
        return game
    }

    /// A fresh game in the mode and rules given, or the current ones.
    ///
    /// What it is given is remembered for the next launch unless `remember` is
    /// false — the self-test's case, which must leave the user's choices as it
    /// found them.
    func newGame(mode: PlayMode? = nil, gentle: Bool? = nil, remember: Bool = true) {
        if let mode {
            self.mode = mode
            if remember { AppPreferences.playMode.value = mode }
        }
        if let gentle {
            self.gentle = gentle
            if remember { AppPreferences.playArcade.value = !gentle }
        }
        // Before the old game goes: a half-typed character belongs to it.
        playfield.discardComposition()
        silence()
        plan = planSource() ?? Self.firstLesson
        stage.clear()
        game = makeGame()
        state = .ready
        stopFor = 0
        mistypeGate.reset()
        keyboardIsStale = true
        modeIcon.image = Theme.symbol(
            self.mode.symbol, size: Theme.SymbolSize.statusBar, description: self.mode.label)
        modeIcon.toolTip = self.mode.label
        refreshStatus()
        pushKeyboard()
    }

    func pause() {
        guard state == .playing else { return }
        state = .paused
        refreshStatus()
        pushKeyboard()
    }

    /// The screen is going: the game waits, and nothing it queued is said over
    /// the screen that replaces it.
    func leave() {
        pause()
        silence()
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
            // A burst's stop takes only the time it has left, and the rest of
            // the frame runs. Dropping the whole frame made every stop up to a
            // frame longer than it says, and lost that time from the game.
            var running = dt
            if stopFor > 0 {
                let held = min(stopFor, dt)
                stopFor -= held
                running -= held
            }
            if stopFor <= 0 {
                apply(game.update(dt: running))
                stage.step(running, height: height)
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

    /// The practice screen's gate, for the practice screen's reasons: one tone
    /// per commit, and none faster than a held key would repeat.
    private func soundMistype() {
        guard soundsMistypes, mistypeGate.admit(nowMs: clock()) else { return }
        onMistype?()
    }

    /// A finished word, said aloud when Speak Words is on — the practice
    /// screen's setting, for the practice screen's reason. On the next turn of
    /// the runloop, never on the keystroke's stack: `speakFinishedWord`
    /// measured what happens otherwise.
    private func speak(_ text: String) {
        guard speaksWords, !text.isEmpty else { return }
        let epoch = speechEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.speaksWords, self.speechEpoch == epoch else { return }
            self.speech.speak(word: text)
        }
    }

    /// Drops what is queued to be said and stops what is being said.
    private func silence() {
        speechEpoch += 1
        speech.stop()
    }

    // MARK: - Preferences and display

    /// Whitespace marks, which keyboards may type, speech and the error tone:
    /// the practice screen's typing preferences, applied here too. Not the
    /// caret — Play draws its own, and `PlayArt.caret` says why.
    func applyTypingPreferences() {
        playfield.latinInputOnly = AppPreferences.latinInputOnly.value
        speaksWords = AppPreferences.speakWords.value
        soundsMistypes = AppPreferences.mistypeSound.value
        if speaksWords { speech.prepare() }
        displayChanged()
    }

    private func displayChanged() {
        art.showsWhitespace = AppPreferences.showWhitespace.value
        // `viewIfLoaded`: preferences are applied before this screen is ever
        // shown, and asking an unloaded controller for its view loads it.
        if let window = viewIfLoaded?.window {
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
        let expected = state == .playing ? game.expected : nil
        guard expected != lastExpected || keyboardIsStale else { return }
        lastExpected = expected
        keyboardIsStale = false
        keyboard?.showWithoutHeat(plan: mode == .letters ? plan : nil, expected: expected)
    }

    // MARK: - For the self-test and the screenshots

    /// Holds the game still whatever the display link says, so `--screenshots`
    /// can stage a moment and have it stay put while AppKit draws it.
    var holdsTime = false
    /// The seed for the next game: random, unless `--screenshots` fixes it.
    var nextSeed: () -> UInt32 = { .random(in: .min ... .max) }

    /// Seeds the effects, so a staged burst sprays the same way every run.
    func seedEffects(_ seed: UInt64) { stage.spray = Spray(seed: seed) }

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

    /// Starts a composition through the input client, as a dead key does.
    func markThroughInput(_ text: String) {
        playfield.setMarkedText(
            text, selectedRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Whether the input client is holding a composition.
    var hasComposition: Bool { playfield.hasMarkedText() }

    /// Whether a composition is drawn on the field.
    var showsComposition: Bool { stage.showsComposition }

    /// Where an input method would put its candidate window, on screen.
    func candidateRect() -> NSRect {
        playfield.firstRect(forCharacterRange: playfield.markedRange(), actualRange: nil)
    }
}
