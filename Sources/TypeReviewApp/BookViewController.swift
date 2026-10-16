import AppKit
import TypeReviewKit

/// The Book screen: a whole book, typed one sentence at a time.
///
/// The sentence being typed sits in the same `TypingView` Practice uses, with
/// the two before it above, dimmed, and the one after it below — enough of the
/// story on screen to read it as a story rather than as a list of lines.
///
/// **Nothing here reaches the profile.** Each sentence is a `Session` run, and
/// a session records every finished run into its own profile — so this one
/// runs over a scratch profile that is never saved. What a sentence leaves
/// behind goes to `BookStore`: the place, after every sentence, and the
/// reading log, which the statistics merge in. The profile is pinned to the
/// website byte for byte and capped at 500 runs, and a novel would push every
/// practice run out of it within days.
///
/// **Enter and Tab throw nothing away.** On Practice they start a new run; here
/// that would discard a half-typed sentence for no reason, so they are wired to
/// nothing. A finished sentence moves on by itself.
@MainActor
final class BookViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let placeLabel = NSTextField(labelWithString: "")
    private let previousLabel = NSTextField(wrappingLabelWithString: "")
    private let typingView = TypingView()
    private let nextLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyButton = NSButton(title: "Choose a Book…", target: nil, action: nil)
    private let wpmLabel = NSTextField(labelWithString: "0 wpm")
    private let accuracyLabel = NSTextField(labelWithString: "100%")
    private let modeIcon = NSImageView()
    private let hintLabel = NSTextField(labelWithString: "")

    private enum Hint {
        static let typing = "⌘R hear the sentence · ⇧⌘R hear the word"
    }

    /// The shelf. Nil when its folder could not be opened, which the screen
    /// says instead of pretending to keep a place it cannot write.
    var store: BookStore?
    /// The practice settings in force — stop on error, no backspace — read at
    /// each sentence so a change in Settings applies to the next one.
    var settings: () -> ProfileSettings = { .default }
    /// The keyboard's heat, from the merged history. Read when a book opens.
    var keyStats: () -> OrderedMap<PerKeyStat> = { OrderedMap() }
    /// Opens the Books sheet. The empty screen's button, and nothing else here.
    var onShowBooks: () -> Void = {}

    var onKeyStruck: ((UInt16) -> Void)?
    var onMistype: (() -> Void)?
    var onKeyReleased: ((UInt16) -> Void)?
    weak var keyboard: KeyboardView? {
        didSet { refresh() }
    }

    /// Keystroke clock, injectable as Practice's is, so a check can type at a
    /// human cadence.
    var clock: () -> Double = { Date().timeIntervalSince1970 * 1000 }

    private(set) var book: Book?
    /// The sentence on screen. Equal to the sentence count once the book is
    /// finished.
    private(set) var sentence = 0
    private var session: Session?
    private var lastTyping: TypingSnapshot?
    /// When the last sentence was finished, for telling a sitting from a
    /// pause. Nil until one is finished in this launch.
    private var lastFinishedAt: Double?
    private var heardThisSentence = false
    private var stats = OrderedMap<PerKeyStat>()
    private var pendingError: String?

    private let speech = SpeechPlayer()
    private var tracker = SpokenWordTracker()
    private var passageGeneration = 0
    private var speaksWords = false
    private var soundsMistypes = true
    private var mistypeGate = MistypeGate()

    /// A gap longer than this between two sentences starts a new sitting.
    /// Long enough for a drink of water, short enough that coming back after
    /// dinner counts as coming back.
    static let sittingGapMs: Double = 10 * 60_000

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        root.wantsLayer = true
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        placeLabel.font = Theme.statFont
        placeLabel.textColor = Theme.secondaryText
        placeLabel.lineBreakMode = .byTruncatingTail
        for label in [previousLabel, nextLabel] {
            label.font = Self.contextFont
            label.textColor = Theme.pending
            label.isSelectable = false
            label.maximumNumberOfLines = 3
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        emptyLabel.alignment = .center
        emptyLabel.textColor = Theme.secondaryText
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyButton.target = self
        emptyButton.action = #selector(showBooksPressed)
        emptyButton.bezelStyle = .push
        modeIcon.image = Theme.symbol("book", size: Theme.SymbolSize.statusBar, description: "Book")
        modeIcon.toolTip = "Book"
        let status = StatusBar.make(
            readouts: [wpmLabel, accuracyLabel], mode: modeIcon, hint: hintLabel)
        install(status: status, in: root)
        view = root
    }

    /// The dimmed sentences around the one being typed: the passage's face, a
    /// size down, so they read as the same page.
    private static var contextFont: NSFont {
        let base = Theme.typingFont
        return NSFont(descriptor: base.fontDescriptor, size: max(12, base.pointSize * 0.72)) ?? base
    }

    private func install(status: NSStackView, in root: NSView) {
        let header = NSStackView(views: [titleLabel, placeLabel])
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .firstBaseline
        placeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let empty = NSStackView(views: [emptyLabel, emptyButton])
        empty.orientation = .vertical
        empty.spacing = 14
        empty.identifier = .init("bookEmpty")
        for subview in [header, previousLabel, typingView, nextLabel, empty, status] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        let inset = PracticeWindowMetrics.horizontalInset
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -inset),

            previousLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            previousLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            previousLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),

            typingView.topAnchor.constraint(equalTo: previousLabel.bottomAnchor, constant: 10),
            typingView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            typingView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),

            nextLabel.topAnchor.constraint(equalTo: typingView.bottomAnchor, constant: 10),
            nextLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            nextLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            nextLabel.bottomAnchor.constraint(lessThanOrEqualTo: status.topAnchor, constant: -16),

            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -16),
            empty.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -2 * inset),

            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        emptyView = empty
    }

    private var emptyView: NSView?

    override func viewDidLoad() {
        super.viewDidLoad()
        typingView.onCharacter = { [weak self] character in self?.type(character) }
        typingView.onCommitBegan = { [weak self] in self?.mistypeGate.beginCommit() }
        typingView.onBackspace = { [weak self] in
            try? self?.session?.backspace()
            self?.refresh()
        }
        // Enter and Tab: nothing. See the note on the class.
        typingView.onRestart = {}
        typingView.onConfirm = {}
        typingView.onKeyPressed = { [weak self] code in self?.keyboard?.setPressed(code) }
        typingView.onKeyStruck = { [weak self] code in self?.onKeyStruck?(code) }
        typingView.onKeyReleased = { [weak self] code in self?.onKeyReleased?(code) }
        applyTypingPreferences()
        openLastBook()
    }

    var focusView: NSView { book == nil ? view : typingView }

    // MARK: - Opening

    /// The book read last, so the screen opens where the child left off.
    private func openLastBook() {
        guard let store else {
            showEmpty("The books folder could not be opened, so no place could be kept.")
            return
        }
        if let id = AppPreferences.lastBook.value, store.books.contains(where: { $0.id == id }) {
            open(id)
        } else if store.indexIsUnreadable {
            showEmpty(BookStoreError.unreadable(store.indexURL.lastPathComponent).errorDescription ?? "")
        } else {
            showEmpty(nil)
        }
    }

    /// Opens a book at its saved place.
    func open(_ id: String) {
        guard let store else { return }
        do {
            let book = try store.book(id)
            self.book = book
            remember(id)
            pendingError = nil
            if case .unreadable = store.progress(id) {
                pendingError = BookStoreError.unreadable(store.progressURL(id).lastPathComponent)
                    .errorDescription
            }
            stats = keyStats()
            show(sentence: store.startingSentence(book))
        } catch {
            book = nil
            showEmpty(error.localizedDescription)
        }
    }

    /// Which book to open next launch. Never written by a check: a check's
    /// books live in a scratch folder, and the id would name a book the user
    /// does not have.
    private func remember(_ id: String?) {
        guard !Diagnostics.isRunningCheck else { return }
        AppPreferences.lastBook.value = id
    }

    /// The shelf changed underneath: a book removed, or the first one added.
    func shelfChanged() {
        guard let store else { return }
        if let book, !store.books.contains(where: { $0.id == book.id }) {
            self.book = nil
            remember(nil)
        }
        if book == nil { openLastBook() }
    }

    private func showEmpty(_ message: String?) {
        book = nil
        session = nil
        emptyLabel.stringValue = message ?? "No book yet.\nImport a book, or start one from the shelf."
        setPageHidden(true)
        titleLabel.stringValue = ""
        placeLabel.stringValue = ""
        hintLabel.stringValue = ""
    }

    private func setPageHidden(_ hidden: Bool) {
        for view in [previousLabel, typingView, nextLabel] as [NSView] { view.isHidden = hidden }
        emptyView?.isHidden = !hidden
    }

    // MARK: - Sentences

    private func show(sentence index: Int) {
        guard let book else { return }
        sentence = index
        heardThisSentence = false
        setPageHidden(false)
        titleLabel.stringValue = book.author.isEmpty ? book.title : "\(book.title) · \(book.author)"
        let chapter = book.chapterIndex(ofSentence: index)
        let percent = Int((Double(index) / Double(max(1, book.sentences.count)) * 100).rounded(.down))
        let chapterTitle = book.chapters[chapter].title
        placeLabel.stringValue =
            (chapterTitle.isEmpty ? "" : "\(chapterTitle) · ")
            + "chapter \(chapter + 1) of \(book.chapters.count) · \(percent)%"
        previousLabel.stringValue = book.sentences[max(0, index - 2)..<min(index, book.sentences.count)]
            .joined(separator: " ")
        guard index < book.sentences.count else {
            finishBook()
            return
        }
        nextLabel.stringValue = index + 1 < book.sentences.count ? book.sentences[index + 1] : ""
        do {
            let session = try self.session ?? Session(profile: Profile(settings: settings()))
            session.stageSettings(settings())
            try session.startWithText(book.sentences[index], passageId: passageId(index))
            self.session = session
        } catch {
            hintLabel.stringValue = "could not start the sentence: \(error.localizedDescription)"
            return
        }
        refresh(resetPassage: true)
        guard AppPreferences.readSentencesFirst.value else { return }
        // On the next turn, not here. This runs inside the keystroke that
        // finished the last sentence, and Practice measured what speech on
        // that stack costs: an input stream that desyncs. A sentence that
        // has been replaced by then is not read.
        let generation = passageGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.passageGeneration == generation else { return }
            self.speakSentence()
        }
    }

    private func passageId(_ index: Int) -> String { "book:\(book?.id ?? ""):\(index)" }

    private func finishBook() {
        session = nil
        lastTyping = nil
        typingView.isHidden = true
        nextLabel.stringValue = ""
        placeLabel.stringValue = "100%"
        emptyLabel.stringValue = "The end.\nThat was the whole book, every sentence of it."
        emptyView?.isHidden = false
        hintLabel.stringValue = pendingError ?? ""
    }

    private func type(_ character: String) {
        guard let session, let book, sentence < book.sentences.count else { return }
        let cursorBefore = lastTyping?.pos ?? 0
        // The space typed out of habit after the last full stop. Sentences
        // are typed one at a time, so the space between them is never asked
        // for, and scoring it as a mistake would mark every sentence's first
        // key wrong for a child who is typing correctly.
        if cursorBefore == 0, character == " ", lastTyping?.expected.hasPrefix(" ") == false { return }
        do {
            let feedback = try session.input(character, timeStamp: clock())
            refresh()
            speakFinishedWord(after: cursorBefore)
            soundMistype(at: cursorBefore)
            if feedback == .completed { finishSentence(session) }
        } catch {
            hintLabel.stringValue = "input failed: \(error.localizedDescription)"
        }
    }

    /// Records the sentence, saves the place, and moves on.
    private func finishSentence(_ session: Session) {
        guard let book, let store, let result = session.profile.results.last else { return }
        let now = clock()
        let startsSitting = lastFinishedAt.map { now - $0 > Self.sittingGapMs } ?? true
        lastFinishedAt = now
        store.record(
            SentenceRecord(
                bookId: book.id, chapter: book.chapterIndex(ofSentence: sentence),
                metrics: result.metrics, keystrokes: session.keystrokes, errors: session.typos,
                histogram: result.histogram, startsSitting: startsSitting))
        do {
            try store.saveProgress(sentence + 1, for: book.id)
            pendingError = nil
        } catch {
            pendingError = "place not saved: \(error.localizedDescription)"
        }
        NotificationCenter.default.post(name: PracticeViewController.runCompleted, object: nil)
        show(sentence: sentence + 1)
    }

    // MARK: - Speech

    /// Speak Sentence: the sentence on screen, read aloud. Counted in the
    /// reading log once per sentence, so a parent can see whether the child is
    /// reading or listening.
    func speakSentence() {
        guard let book, sentence < book.sentences.count else { return }
        speech.speak(sentence: book.sentences[sentence])
        noteHeard()
    }

    /// Speak Word: the word at the cursor.
    func speakWord() {
        guard let typing = lastTyping, let word = word(in: typing.expected, atUTF16Offset: typing.pos)
        else { return }
        speech.speak(word: word)
    }

    private func noteHeard() {
        guard let book, !heardThisSentence else { return }
        heardThisSentence = true
        store?.recordHeard(bookId: book.id)
    }

    var canSpeak: Bool { book.map { sentence < $0.sentences.count } ?? false }

    /// Sentences actually handed to the synthesizer, for `--speechbench`.
    var spokenSentenceCount: Int { speech.sentencesSpoken }
    var spokenWordCount: Int { speech.wordsSpoken }
    /// Told when an utterance begins, so `--speechbench` can see the
    /// sentence was actually heard rather than merely handed over.
    var onUtteranceStarted: (() -> Void)? {
        get { speech.onWordStarted }
        set { speech.onWordStarted = newValue }
    }

    private func speakFinishedWord(after cursorBefore: Int) {
        guard speaksWords, let typing = lastTyping,
            let word = tracker.wordToSpeak(
                expected: typing.expected, statuses: typing.statuses,
                oldPos: cursorBefore, newPos: typing.pos)
        else { return }
        // Off the keystroke's stack, for the reason Practice gives.
        let text = word.text
        let generation = passageGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.passageGeneration == generation, self.speaksWords else { return }
            self.speech.speak(word: text)
        }
    }

    private func soundMistype(at cursorBefore: Int) {
        guard soundsMistypes, let typing = lastTyping,
            mistypeJustHappened(statuses: typing.statuses, at: cursorBefore),
            mistypeGate.admit(nowMs: clock())
        else { return }
        onMistype?()
    }

    /// Leaving the screen: nothing more is said.
    func leave() { speech.stop() }

    func applyTypingPreferences() {
        typingView.caretStyle = AppPreferences.caretStyle.value
        typingView.showsWhitespace = AppPreferences.showWhitespace.value
        typingView.latinInputOnly = AppPreferences.latinInputOnly.value
        speaksWords = AppPreferences.speakWords.value
        soundsMistypes = AppPreferences.mistypeSound.value
        if speaksWords || AppPreferences.readSentencesFirst.value { speech.prepare() }
    }

    // MARK: - Drawing

    private func refresh(resetPassage: Bool = false) {
        guard let session, let snapshot = try? session.snapshot() else { return }
        lastTyping = snapshot.typing
        if resetPassage {
            mistypeGate.reset()
            passageGeneration += 1
            tracker.startPassage()
            speech.setPassage(snapshot.typing.expected)
            if speaksWords || AppPreferences.readSentencesFirst.value { speech.prepare() }
            typingView.setPassage(
                snapshot.typing.expected, statuses: snapshot.typing.statuses,
                cursor: snapshot.typing.pos)
            keyboard?.setPressed(nil)
            hintLabel.stringValue = pendingError ?? Hint.typing
            if view.window?.firstResponder !== typingView, view.superview != nil {
                view.window?.makeFirstResponder(typingView)
            }
        } else {
            typingView.update(statuses: snapshot.typing.statuses, cursor: snapshot.typing.pos)
        }
        let units = snapshot.typing.expected.utf16
        let next = units.index(units.startIndex, offsetBy: snapshot.typing.pos, limitedBy: units.endIndex)
            .flatMap { $0 == units.endIndex ? nil : String(utf16CodeUnits: [units[$0]], count: 1) }
        keyboard?.update(stats: stats, plan: nil, expected: next, targetWpm: settings().targetWpm)
        wpmLabel.stringValue = String(format: "%.0f wpm", snapshot.liveMetrics.netWpm)
        accuracyLabel.stringValue = String(format: "%.0f%%", snapshot.liveMetrics.accuracy)
    }

    @objc private func showBooksPressed() { onShowBooks() }

    // MARK: - Probes, for `--selftest`

    /// Types through the input client, the path AppKit commits text by.
    func typeThroughInput(_ text: String) {
        for unit in text.utf16 {
            typingView.insertText(String(utf16CodeUnits: [unit], count: 1), replacementRange: NSRange())
        }
    }

    var currentSentenceText: String? { lastTyping?.expected }
    var pageText: (previous: String, next: String, place: String) {
        (previousLabel.stringValue, nextLabel.stringValue, placeLabel.stringValue)
    }
    var hint: String { hintLabel.stringValue }
    var isShowingEmpty: Bool { emptyView?.isHidden == false }
    /// Enter and Tab, as the typing surface hands them on.
    func pressEnterAndTab() {
        typingView.onConfirm?()
        typingView.onRestart?()
    }
    var cursor: Int { lastTyping?.pos ?? -1 }
}
