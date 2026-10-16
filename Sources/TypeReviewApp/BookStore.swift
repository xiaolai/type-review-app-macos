import AppKit
import TypeReviewKit

/// The books on this Mac, the place in each, and the reading log.
///
/// Files the user owns, beside the profile and never inside it. The profile is
/// pinned to the website byte for byte, and its 500-run cap would push all
/// other history out within days of a child typing a novel.
///
///     books/index.json          what is on the shelf
///     books/<id>.json           one book, split into sentences at import
///     books/<id>.progress.json  the next sentence to type
///     reading.json              book typing per day, for the statistics
///
/// Every write goes through `writeDurably`, and a file that exists and cannot
/// be read is never written over — the rule `LibraryStore` follows, for the
/// same reason: an unreadable file may still be recoverable by hand, and this
/// app must not be what destroys it.
@MainActor
final class BookStore {
    /// `books/`.
    let directory: URL
    var indexURL: URL { directory.appendingPathComponent("index.json") }
    let readingURL: URL

    private(set) var books: [BookSummary] = []
    /// `index.json` exists and could not be read. Nothing can be added or
    /// removed until it is moved or repaired.
    private(set) var indexIsUnreadable = false
    /// `reading.json` exists and could not be read. Sentences are still
    /// counted in memory, and the file is left alone.
    private(set) var readingIsUnreadable = false
    private(set) var reading = ReadingLog()
    private var readingIsDirty = false
    /// Progress files that exist and could not be read, by book id.
    private var unreadableProgress: Set<String> = []
    /// The one book open, so a sentence does not cost a file read.
    private var cached: Book?

    private let calendar: Calendar
    private let now: () -> Date
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// How often a dirty reading log reaches disk: the keystroke counter's
    /// interval, for its reasons. Progress is written after every sentence;
    /// this is only the minutes and the key data.
    private static let flushInterval: TimeInterval = 60

    init(
        profileDirectory: URL, calendar: Calendar = localStatisticsCalendar(),
        now: @escaping () -> Date = { Date() }
    ) {
        directory = profileDirectory.appendingPathComponent("books", isDirectory: true)
        readingURL = profileDirectory.appendingPathComponent("reading.json")
        self.calendar = calendar
        self.now = now
        loadIndex()
        loadReading()
    }

    /// Beside the profile, so `--selftest`'s redirect covers these files too.
    static func standard() throws -> BookStore {
        BookStore(profileDirectory: try ProfileFileStore.standard().directory)
    }

    func bookURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
    func progressURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).progress.json") }

    // MARK: - Reading

    private func loadIndex() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        guard let data = try? Data(contentsOf: indexURL), let decoded = try? decodeBookIndex(data),
            decoded.count <= maxBooks
        else {
            indexIsUnreadable = true
            return
        }
        books = decoded
    }

    private func loadReading() {
        guard FileManager.default.fileExists(atPath: readingURL.path) else { return }
        guard let data = try? Data(contentsOf: readingURL), let decoded = try? decodeReadingLog(data)
        else {
            readingIsUnreadable = true
            return
        }
        reading = decoded
    }

    /// One book, read strictly. A book this app would not have written is
    /// refused whole rather than half-shown.
    func book(_ id: String) throws -> Book {
        if let cached, cached.id == id { return cached }
        guard books.contains(where: { $0.id == id }) else { throw BookStoreError.notOnShelf }
        let data: Data
        do { data = try Data(contentsOf: bookURL(id)) } catch {
            throw BookStoreError.unreadable(bookURL(id).lastPathComponent)
        }
        let book: Book
        do { book = try decodeBook(data) } catch {
            throw BookStoreError.unreadable(bookURL(id).lastPathComponent)
        }
        guard book.id == id else { throw BookStoreError.unreadable(bookURL(id).lastPathComponent) }
        cached = book
        return book
    }

    enum ProgressRead: Equatable {
        case absent
        case ok(BookProgress)
        case unreadable
    }

    func progress(_ id: String) -> ProgressRead {
        let url = progressURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url), let decoded = try? decodeBookProgress(data) else {
            unreadableProgress.insert(id)
            return .unreadable
        }
        return .ok(decoded)
    }

    /// Where to start: the saved sentence, or the first. A place past the end
    /// — a book shortened by hand — is the end.
    func startingSentence(_ book: Book) -> Int {
        guard case .ok(let saved) = progress(book.id) else { return 0 }
        return min(saved.sentence, book.sentences.count)
    }

    /// Every book with its next sentence, for the Statistics window.
    func shelf() -> [(summary: BookSummary, sentence: Int)] {
        books.map { book in
            guard case .ok(let saved) = progress(book.id) else { return (book, 0) }
            return (book, min(saved.sentence, book.sentenceCount))
        }
    }

    // MARK: - Writing

    /// Saves the next sentence to type. One integer, so retrying is safe.
    func saveProgress(_ sentence: Int, for id: String) throws {
        guard !unreadableProgress.contains(id) else {
            throw BookStoreError.unreadable(progressURL(id).lastPathComponent)
        }
        let progress = BookProgress(sentence: sentence, lastRead: now().timeIntervalSince1970 * 1000)
        try writeDurably(try encodeBookProgress(progress), to: progressURL(id), in: directory)
    }

    /// Makes a book from a reviewed draft and puts it on the shelf.
    @discardableResult
    func add(_ draft: BookDraft) throws -> Book {
        let book = try makeBook(
            from: draft, id: UUID().uuidString, importedAt: now().timeIntervalSince1970 * 1000)
        try add(book)
        return book
    }

    /// The book's file first, then the index that names it. A crash between
    /// the two leaves a file nobody lists, which costs disk and nothing else;
    /// the other order would list a book with no file.
    func add(_ book: Book) throws {
        guard !indexIsUnreadable else { throw BookStoreError.unreadable(indexURL.lastPathComponent) }
        guard books.count < maxBooks else { throw BookImportError.tooManyBooks }
        guard !books.contains(where: { $0.id == book.id }) else { throw BookStoreError.alreadyOnShelf }
        try writeDurably(try encodeBook(book), to: bookURL(book.id), in: directory)
        do {
            try commit(books + [book.summary])
        } catch {
            try? FileManager.default.removeItem(at: bookURL(book.id))
            throw error
        }
    }

    /// Takes a book off the shelf, with its place and its days in the log.
    func remove(_ id: String) throws {
        guard !indexIsUnreadable else { throw BookStoreError.unreadable(indexURL.lastPathComponent) }
        try commit(books.filter { $0.id != id })
        for url in [bookURL(id), progressURL(id)] { try? FileManager.default.removeItem(at: url) }
        unreadableProgress.remove(id)
        if cached?.id == id { cached = nil }
        reading.remove(bookId: id)
        readingIsDirty = true
        flushReading()
    }

    /// Persists a candidate index and adopts it only once the write is done,
    /// as `LibraryStore` does.
    private func commit(_ candidate: [BookSummary]) throws {
        try writeDurably(try encodeBookIndex(candidate), to: indexURL, in: directory)
        books = candidate
    }

    // MARK: - The reading log

    /// The day a sentence finished on, in the calendar the statistics use.
    func today() -> String { dayKey(now().timeIntervalSince1970 * 1000, calendar: calendar) }

    func record(_ sentence: SentenceRecord) {
        reading.record(sentence, on: today())
        readingIsDirty = true
    }

    func recordHeard(bookId: String) {
        reading.recordHeard(bookId: bookId, on: today())
        readingIsDirty = true
    }

    func flushReading() {
        guard readingIsDirty, !readingIsUnreadable else { return }
        reading.pruneHistograms()
        guard let data = try? encodeReadingLog(reading),
            (try? writeDurably(data, to: readingURL, in: readingURL.deletingLastPathComponent())) != nil
        else { return }
        readingIsDirty = false
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.flushReading() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let flush: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.flushReading() }
        }
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        // Quitting and sleeping, the two ordinary ways a minute goes missing.
        observers = [
            (
                app,
                app.addObserver(
                    forName: NSApplication.willTerminateNotification, object: nil, queue: .main,
                    using: flush)
            ),
            (
                workspace,
                workspace.addObserver(
                    forName: NSWorkspace.willSleepNotification, object: nil, queue: .main,
                    using: flush)
            ),
        ]
    }

    func stop() {
        flushReading()
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }
}

enum BookStoreError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case notOnShelf
    case alreadyOnShelf

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "\(name) could not be read and will not be overwritten — move or repair it first"
        case .notOnShelf: return "That book is no longer on the shelf."
        case .alreadyOnShelf: return "That book is already on the shelf."
        }
    }
}
