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
            try checkEpubReview()
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

    /// An EPUB 2 book with no tags at all — the shape of the
    /// `untagged-hand-made` fixture, trimmed — as the folder Apple Books
    /// keeps, so the check reads the folder path as well.
    private static let untaggedBook: [(path: String, text: String)] = [
        ("META-INF/container.xml", #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """#),
        ("OEBPS/content.opf", #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>The Kite on the Hill</dc:title>
                <dc:creator>A. N. Example</dc:creator>
                <dc:language>en</dc:language>
                <dc:identifier id="bookid">urn:uuid:5f0c2a4e-0000-4000-8000-000000000001</dc:identifier>
              </metadata>
              <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="p1" href="page1.html" media-type="application/xhtml+xml"/>
                <item id="p2" href="page2.html" media-type="application/xhtml+xml"/>
                <item id="p3" href="page3.html" media-type="application/xhtml+xml"/>
                <item id="p4" href="page4.html" media-type="application/xhtml+xml"/>
                <item id="p5" href="page5.html" media-type="application/xhtml+xml"/>
                <item id="p6" href="page6.html" media-type="application/xhtml+xml"/>
                <item id="p7" href="page7.html" media-type="application/xhtml+xml"/>
                <item id="p8" href="page8.html" media-type="application/xhtml+xml"/>
              </manifest>
              <spine toc="ncx">
                <itemref idref="p1"/>
                <itemref idref="p2"/>
                <itemref idref="p3"/>
                <itemref idref="p4"/>
                <itemref idref="p5"/>
                <itemref idref="p6"/>
                <itemref idref="p7"/>
                <itemref idref="p8"/>
              </spine>
            </package>
            """#),
        ("OEBPS/page1.html", #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Cover</title></head>
            <body>
            <div><img src="cover.png" alt="The Kite on the Hill"/></div>
            </body>
            </html>
            """#),
        ("OEBPS/page2.html", #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>The Kite on the Hill</title></head>
            <body>
            <p>The Kite on the Hill</p>
            <p>A. N. Example</p>
            </body>
            </html>
            """#),
        ("OEBPS/page3.html", #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>The Kite on the Hill</title></head>
            <body>
            <p>The chapters</p>
            <ul>
            <li>1. <a href="page4.html">Chapter One: The Red Kite and the Long String Wound on a Stick</a></li>
            <li>2. <a href="page5.html">Chapter Two: The Wind Comes Over the Hill at Last</a></li>
            <li>3. <a href="page6.html">Chapter Three: Up Into the Tall Old Oak Tree by the Field</a></li>
            <li>4. <a href="page7.html">Chapter Four: Home Again Before the Rain Falls on the Village</a></li>
            <li>5. <a href="page8.html">About the Writer of This Little Book</a></li>
            </ul>
            </body>
            </html>
            """#),
        ("OEBPS/page4.html", #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter One</title></head>
            <body>
            <h2>Chapter One: The Red Kite and the Long String</h2>
            <p>Nell found the kite in the shed behind the house, under a box of old garden tools. It was red, with a long tail made of knotted ribbons, and the paper was only a little torn at one corner.</p>
            <p>She carried it into the kitchen and laid it on the table. Her grandfather looked up from his newspaper and smiled. "That was your mother's kite," he said. "She flew it on the hill every summer when she was your age."</p>
            </body>
            </html>
            """#),
        ("OEBPS/page5.html", #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter Two</title></head>
            <body>
            <h2>Chapter Two: The Wind Comes Over the Hill</h2>
            <p>The next morning was bright and cold. Nell ate her porridge quickly, pulled on her boots, and ran out of the gate with the kite held high above her head so that the tail would not drag in the mud.</p>
            <p>The hill was steeper than it looked from the house. Halfway up she had to stop and catch her breath, and when she turned round she could see the whole village below her: the church, the shop, the bridge, and the thin grey line of smoke rising from her grandfather's chimney.</p>
            </body>
            </html>
            """#),
        ("OEBPS/page6.html", #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter Three</title></head>
            <body>
            <h2>Chapter Three: Up Into the Tall Old Oak Tree</h2>
            <p>For a long time the kite flew well. Then the wind changed. It swung round from the west and came in short, rough bursts, and the kite began to swoop from side to side like a bird that could not decide where to go.</p>
            <p>Nell wound in the string as fast as she could, but it was no use. One hard gust tore the kite sideways, and it dropped into the branches of the old oak tree at the edge of the field and stuck there, its tail fluttering.</p>
            </body>
            </html>
            """#),
        ("OEBPS/page7.html", #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter Four</title></head>
            <body>
            <h2>Chapter Four: Home Again Before the Rain Falls</h2>
            <p>The boy's name was Tom, and his dog was called Biscuit. They walked down the hill together, Nell holding the kite and Tom holding the string, while Biscuit ran ahead and barked at the sheep.</p>
            <p>Dark clouds were gathering over the far side of the valley. By the time they reached the bridge the first drops of rain were falling, fat and cold, and they began to run.</p>
            </body>
            </html>
            """#),
        ("OEBPS/page8.html", #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>About the Writer</title></head>
            <body>
            <h2>About the Writer</h2>
            <p>A. N. Example lives in a small town by the sea and has flown kites on the same windy hill for many years. This is the first of several little stories written for children who like the outdoors, and for the grown-ups who read with them on rainy days.</p>
            </body>
            </html>
            """#),
        ("OEBPS/toc.ncx", #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <head><meta name="dtb:uid" content="urn:uuid:5f0c2a4e-0000-4000-8000-000000000001"/></head>
              <docTitle><text>The Kite on the Hill</text></docTitle>
              <navMap>
                <navPoint id="n1" playOrder="1"><navLabel><text>Start</text></navLabel><content src="page1.html"/></navPoint>
                <navPoint id="n4" playOrder="2"><navLabel><text>One</text></navLabel><content src="page4.html"/></navPoint>
                <navPoint id="n5" playOrder="3"><navLabel><text>Two</text></navLabel><content src="page5.html"/></navPoint>
                <navPoint id="n6" playOrder="4"><navLabel><text>Three</text></navLabel><content src="page6.html"/></navPoint>
                <navPoint id="n7" playOrder="5"><navLabel><text>Four</text></navLabel><content src="page7.html"/></navPoint>
              </navMap>
            </ncx>
            """#),
        ("mimetype", #"""
            application/epub+zip
            """#),
    ]

    /// An EPUB with no tags, read through Import's own path from a folder:
    /// the contents page is listed, unticked, with the reason, and the
    /// chapters are ticked story.
    private static func checkEpubReview() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeReviewBookCheck-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("The Kite on the Hill.epub", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, text) in untaggedBook {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let draft = try BookImport.draft(from: folder)
        let review = BookReviewController(draft: draft, wpm: nil)
        _ = review.window
        guard draft.title == "The Kite on the Hill", review.tableRowCount == draft.chapters.count else {
            throw CheckFailure(message: "the EPUB read as \"\(draft.title)\" with \(review.tableRowCount) rows")
        }
        guard let contents = draft.chapters.first(where: { $0.reason == "looks like a table of contents" }),
            !contents.included, contents.kind == .skip
        else {
            throw CheckFailure(
                message: "the untagged EPUB's contents page was not offered unticked: "
                    + draft.chapters.map { "\($0.title) \($0.kind) \($0.included) \($0.reason)" }
                    .joined(separator: "; "))
        }
        let story = draft.chapters.filter { $0.kind == .story }
        guard story.count >= 4, story.allSatisfy(\.included), review.warnings.isEmpty else {
            throw CheckFailure(message: "the untagged EPUB's chapters were not all ticked story")
        }
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
