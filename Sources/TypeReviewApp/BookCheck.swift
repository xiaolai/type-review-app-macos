import AppKit
import TypeReviewKit

extension Diagnostics {
    /// The Book screen, driven through the real window by `--selftest`.
    ///
    /// What the Kit's tests cannot see: the files on disk, the rule that an
    /// unreadable one is never written over, the review sheet's rows and
    /// totals, three sentences typed through the input client, the place
    /// saved after each and found again, Enter and Tab throwing nothing away,
    /// the reading log reaching disk and the Statistics window, and — checked
    /// by the caller — the profile left alone.
    ///
    /// Everything it writes is in the self-test's scratch folder, and speech
    /// is pinned off for the duration, so it makes no sound.
    static func checkBook(
        book: BookViewController, store: BookStore?, screens: MainScreenController,
        show: (MainScreen) -> Void
    ) -> Result<String, CheckFailure> {
        guard let window = screens.view.window else {
            return .failure(CheckFailure(message: "the screens are in no window"))
        }
        guard let store else {
            return .failure(CheckFailure(message: "the books folder could not be opened"))
        }
        let argumentsBefore = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var quiet = argumentsBefore
        quiet[AppPreferences.readSentencesFirst.key] = false
        quiet[AppPreferences.speakWords.key] = false
        UserDefaults.standard.setVolatileDomain(quiet, forName: UserDefaults.argumentDomain)
        let clockBefore = book.clock
        defer {
            UserDefaults.standard.setVolatileDomain(argumentsBefore, forName: UserDefaults.argumentDomain)
            book.clock = clockBefore
            book.applyTypingPreferences()
            show(.practice)
        }
        do {
            try checkUnreadableFilesAreLeftAlone()
            try checkShelf()
            let draft = try checkReview()
            let added = try store.add(draft)
            try checkBookScreen(book: book, window: window, show: show)
            let typed = try checkTypingThreeSentences(book: book, store: store, added: added)
            try checkStatistics(store: store, added: added)
            try checkRemove(store: store, book: book, added: added)
            return .success(typed)
        } catch let failure as CheckFailure {
            return .failure(failure)
        } catch {
            return .failure(CheckFailure(message: "book: \(error.localizedDescription)"))
        }
    }

    /// A small book with two chapters, five sentences in all.
    private static let checkText = """
        Chapter 1

        The hen sat in the sun. The dog ran to the barn. Then it began to rain.

        Chapter 2

        The hen went in. The dog went in too.
        """

    /// The index, the place, the reading log and the keystroke counts: each
    /// one, unreadable, is left exactly as it was.
    private static func checkUnreadableFilesAreLeftAlone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeReviewBookCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = directory.appendingPathComponent("books", isDirectory: true)
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        let files = [
            books.appendingPathComponent("index.json"),
            books.appendingPathComponent("b-1.progress.json"),
            directory.appendingPathComponent("reading.json"),
            directory.appendingPathComponent("keystrokes.json"),
        ]
        for file in files { try garbage.write(to: file) }

        let store = BookStore(profileDirectory: directory)
        guard store.indexIsUnreadable, store.readingIsUnreadable, store.books.isEmpty else {
            throw CheckFailure(message: "an unreadable index or reading log was not noticed")
        }
        let draft = try readPlainTextBook(checkText, fallbackTitle: "check")
        guard (try? store.add(draft)) == nil else {
            throw CheckFailure(message: "a book was added over an unreadable index")
        }
        guard store.progress("b-1") == .unreadable, (try? store.saveProgress(1, for: "b-1")) == nil else {
            throw CheckFailure(message: "a place was saved over an unreadable progress file")
        }
        store.recordHeard(bookId: "b-1")
        store.flushReading()
        let counter = KeystrokeCounter(directory: directory)
        counter.record()
        counter.flush()
        for file in files where (try? Data(contentsOf: file)) != garbage {
            throw CheckFailure(message: "\(file.lastPathComponent) was unreadable and was written over")
        }
    }

    /// The starter shelf loaded, every book in it.
    private static func checkShelf() throws {
        guard BundledShelf.loadFailures.isEmpty else {
            throw CheckFailure(message: "shelf: " + BundledShelf.loadFailures.joined(separator: "; "))
        }
        guard BundledShelf.books.count >= 2, BundledShelf.books.count == BundledShelf.entries.count else {
            throw CheckFailure(
                message: "the starter shelf holds \(BundledShelf.books.count) books "
                    + "of the \(BundledShelf.entries.count) it lists")
        }
    }

    /// The review sheet: a row per part, totals that follow the ticks.
    private static func checkReview() throws -> BookDraft {
        let draft = try readPlainTextBook(checkText, fallbackTitle: "check")
        let review = BookReviewController(draft: draft, wpm: nil)
        _ = review.window
        guard review.tableRowCount == draft.chapters.count, draft.chapters.count == 2 else {
            throw CheckFailure(
                message: "the review sheet shows \(review.tableRowCount) rows for \(draft.chapters.count) parts")
        }
        let words = draft.includedWords
        guard review.totals.contains("2 of 2 parts"), review.totals.contains("\(words) words"),
            review.totals.contains("about 1 sitting")
        else {
            throw CheckFailure(message: "the review totals read \"\(review.totals)\"")
        }
        review.setIncluded(false, row: 1)
        guard review.totals.contains("1 of 2 parts"), review.draft.includedWords < words else {
            throw CheckFailure(message: "unticking a part left the totals at \"\(review.totals)\"")
        }
        review.setIncluded(false, row: 0)
        guard !review.isImportEnabled else {
            throw CheckFailure(message: "Import was offered with nothing ticked")
        }
        review.setIncluded(true, row: 0)
        review.setIncluded(true, row: 1)
        return review.draft
    }

    private static let bookToolbar: [String] = {
        let space = NSToolbarItem.Identifier.flexibleSpace.rawValue
        return ["books", "speakSentence", space, "screen", space, "keyboard", "library", "stats"]
    }()

    /// The switch, the toolbar and the menus follow the screen.
    private static func checkBookScreen(
        book: BookViewController, window: NSWindow, show: (MainScreen) -> Void
    ) throws {
        show(.book)
        window.contentView?.layoutSubtreeIfNeeded()
        guard book.view.window === window else {
            throw CheckFailure(message: "switching to Book did not put it in the window")
        }
        let items = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        guard items == bookToolbar else {
            throw CheckFailure(message: "on Book the toolbar shows \(items)")
        }
        let segments = (window.toolbar?.items.first { $0.itemIdentifier.rawValue == "screen" }?.view
            as? NSSegmentedControl)
        guard segments?.segmentCount == MainScreen.allCases.count,
            segments?.selectedSegment == MainScreen.allCases.firstIndex(of: .book)
        else {
            throw CheckFailure(message: "the screen switch does not show Book selected")
        }
    }

    /// The menu items for one action, enabled as the menu bar would decide.
    private static func menuItems(_ action: Selector) -> [NSMenuItem] {
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let found = NSApp.mainMenu.map(items)?.filter { $0.action == action } ?? []
        for menu in Set(found.compactMap(\.menu)) { menu.update() }
        return found
    }

    /// Three sentences, the place after each, and Enter and Tab harmless.
    private static func checkTypingThreeSentences(
        book: BookViewController, store: BookStore, added: Book
    ) throws -> String {
        var synthetic: Double = 0
        book.clock = {
            synthetic += 150
            return synthetic
        }
        book.open(added.id)
        guard book.book?.id == added.id, book.sentence == 0,
            book.currentSentenceText == added.sentences[0]
        else {
            throw CheckFailure(message: "opening the new book did not show its first sentence")
        }
        let hear = menuItems(#selector(AppDelegate.speakSentence(_:)))
        guard hear.count == 1, hear[0].isEnabled, !hear[0].isHidden else {
            throw CheckFailure(message: "Book ▸ Hear Sentence is missing, hidden or greyed out")
        }
        guard menuItems(#selector(AppDelegate.chooseSource(_:))).allSatisfy({ !$0.isEnabled }) else {
            throw CheckFailure(message: "View ▸ Source is not greyed out on Book")
        }
        guard book.pageText.next == added.sentences[1], book.pageText.place.contains("chapter 1 of 2") else {
            throw CheckFailure(message: "the page reads \(book.pageText)")
        }
        // The habitual space after the last full stop is not a mistake.
        book.typeThroughInput(" ")
        guard book.cursor == 0 else {
            throw CheckFailure(message: "a space before the sentence moved the cursor to \(book.cursor)")
        }
        for index in 0..<3 {
            book.typeThroughInput(added.sentences[index])
            guard book.sentence == index + 1 else {
                throw CheckFailure(message: "typing sentence \(index + 1) left the screen on \(book.sentence)")
            }
            guard case .ok(let saved) = BookStore(profileDirectory: store.directory.deletingLastPathComponent())
                .progress(added.id), saved.sentence == index + 1
            else {
                throw CheckFailure(message: "the place was not saved after sentence \(index + 1)")
            }
        }
        guard book.pageText.previous == added.sentences[1...2].joined(separator: " "),
            book.pageText.place.contains("chapter 2 of 2")
        else {
            throw CheckFailure(message: "after three sentences the page reads \(book.pageText)")
        }
        // Two characters into the fourth, then Enter and Tab.
        let fourth = Array(added.sentences[3])
        book.typeThroughInput(String(fourth[0...1]))
        book.pressEnterAndTab()
        guard book.cursor == 2, book.sentence == 3 else {
            throw CheckFailure(message: "Enter and Tab moved the cursor to \(book.cursor) on sentence \(book.sentence)")
        }
        // Continue at the saved place: opened again, it is the fourth.
        book.open(added.id)
        guard book.sentence == 3, book.cursor == 0 else {
            throw CheckFailure(message: "reopening the book started at sentence \(book.sentence)")
        }
        return "3 sentences of \"\(added.title)\" typed and kept"
    }

    /// The reading log on disk, and in Statistics.
    private static func checkStatistics(store: BookStore, added: Book) throws {
        store.flushReading()
        let reread = BookStore(profileDirectory: store.directory.deletingLastPathComponent())
        let totals = bookTotals(reread.reading, bookId: added.id)
        guard !reread.readingIsUnreadable, totals.sentences == 3, totals.activeMs > 0,
            totals.correctChars == added.sentences[0..<3].reduce(0, { $0 + $1.utf16.count })
        else {
            throw CheckFailure(message: "the reading log on disk holds \(totals)")
        }
        let stats = StatsViewController()
        stats.history = { [] }
        stats.reading = { reread.reading }
        stats.shelf = { reread.shelf() }
        _ = stats.view
        stats.refresh()
        guard stats.bookLines.count == 1, stats.bookLines[0].hasPrefix("\(added.title) — 60%"),
            stats.bookLines[0].contains("3 sentences")
        else {
            throw CheckFailure(message: "Statistics' Books section reads \(stats.bookLines)")
        }
        // A day with only book typing is a practised day.
        guard stats.calendarState.hidden == false, stats.calendarState.cells > 0 else {
            throw CheckFailure(message: "book typing alone did not show the practice grid")
        }
        let before = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = before
        arguments[AppPreferences.statsMetric.key] = AppPreferences.StatsMetric.bookMinutes.rawValue
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        stats.refresh()
        UserDefaults.standard.setVolatileDomain(before, forName: UserDefaults.argumentDomain)
        guard stats.calendarSummary.hasSuffix("minutes reading") else {
            throw CheckFailure(message: "the minutes grid describes itself as \"\(stats.calendarSummary)\"")
        }
    }

    /// Removing takes the book, its place and its days.
    private static func checkRemove(store: BookStore, book: BookViewController, added: Book) throws {
        try store.remove(added.id)
        book.shelfChanged()
        let gone = [store.bookURL(added.id), store.progressURL(added.id)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard store.books.isEmpty, gone.isEmpty, bookTotals(store.reading, bookId: added.id).sentences == 0,
            book.book == nil, book.isShowingEmpty
        else {
            throw CheckFailure(message: "removing the book left \(gone.map(\.lastPathComponent)) behind")
        }
    }
}
