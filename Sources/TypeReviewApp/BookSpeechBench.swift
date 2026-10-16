import AppKit
import TypeReviewKit

extension Diagnostics {
    /// How long a sentence may take to begin speaking before the bench calls
    /// it silent. Generous: the first utterance of a launch builds the
    /// synthesizer.
    fileprivate static let sentenceStartSeconds: Double = 8

    /// The Book screen's sentence speech, for `--speechbench`: offered,
    /// spoken, and never on the typing path.
    ///
    /// On a Book screen of its own, over a scratch shelf, so the bench writes
    /// nothing into the user's books or reading log. Read Each Sentence First
    /// is switched on in the argument domain, never on disk.
    ///
    /// Each sentence must be heard to begin — a start callback of its own,
    /// awaited with a deadline — so one sentence heard cannot vouch for two.
    ///
    /// Answers a line for the report, or a failure.
    static func checkSentenceSpeech(then finish: @escaping (Result<String, CheckFailure>) -> Void) {
        let bench: SentenceBench
        do { bench = try SentenceBench() } catch {
            return finish(.failure(error))
        }
        bench.run { result in
            bench.tearDown()
            finish(result)
        }
    }
}

/// The scratch Book screen `checkSentenceSpeech` drives, and everything it
/// must put back.
@MainActor
private final class SentenceBench {
    typealias CheckFailure = Diagnostics.CheckFailure

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TypeReviewSpeechBench-\(UUID().uuidString)", isDirectory: true)
    private let argumentsBefore = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    private let store: BookStore
    private let shelfBook: Book
    private let book = BookViewController()
    /// What to call when the next utterance begins.
    private var onStart: (() -> Void)?

    /// Sets up the shelf and the preferences. Anything that fails here has
    /// already been put back.
    init() throws(CheckFailure) {
        store = BookStore(profileDirectory: directory)
        guard let first = BundledShelf.books.first else {
            try? FileManager.default.removeItem(at: directory)
            throw CheckFailure(message: "there is no shelf book to read from")
        }
        shelfBook = first
        do { try store.add(first) } catch {
            try? FileManager.default.removeItem(at: directory)
            throw CheckFailure(message: "the scratch shelf refused a book: \(error)")
        }
        var arguments = argumentsBefore
        arguments[AppPreferences.readSentencesFirst.key] = true
        arguments[AppPreferences.speakWords.key] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        book.store = store
        var clock: Double = 0
        book.clock = {
            clock += 150
            return clock
        }
        book.onUtteranceStarted = { [weak self] in
            guard let self else { return }
            let waiting = self.onStart
            self.onStart = nil
            waiting?()
        }
        _ = book.view
    }

    func tearDown() {
        book.leave()
        book.onUtteranceStarted = nil
        UserDefaults.standard.setVolatileDomain(argumentsBefore, forName: UserDefaults.argumentDomain)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Calls `then` when the next utterance begins, or fails after the
    /// deadline. Whichever comes first wins; the other is ignored.
    private func awaitStart(_ what: String, then: @escaping (Result<Void, CheckFailure>) -> Void) {
        var settled = false
        onStart = {
            guard !settled else { return }
            settled = true
            then(.success(()))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Diagnostics.sentenceStartSeconds) { [weak self] in
            guard !settled else { return }
            settled = true
            self?.onStart = nil
            then(.failure(CheckFailure(message: "\(what) was handed over and never began speaking")))
        }
    }

    func run(_ finish: @escaping (Result<String, CheckFailure>) -> Void) {
        book.open(shelfBook.id)
        // Offered: there is a sentence, so Hear Sentence has something to say.
        guard book.canSpeak, let sentence = book.currentSentenceText else {
            return finish(.failure(CheckFailure(message: "the Book screen offered no sentence to hear")))
        }
        // Not on the typing path: the sentence arriving asks for nothing on
        // the stack that showed it.
        guard book.spokenSentenceCount == 0 else {
            return finish(.failure(CheckFailure(message: "a sentence was spoken on the stack that opened the book")))
        }
        awaitStart("the first sentence") { [self] first in
            if case .failure(let failure) = first { return finish(.failure(failure)) }
            guard book.spokenSentenceCount == 1 else {
                return finish(.failure(CheckFailure(
                    message: "with Read Each Sentence First on, \(book.spokenSentenceCount) sentences were read")))
            }
            let slowest = type(sentence)
            guard book.sentence == 1, book.spokenSentenceCount == 1 else {
                return finish(.failure(CheckFailure(
                    message: "typing a sentence spoke \(book.spokenSentenceCount - 1) sentences on the keystroke path")))
            }
            // Spoken: the next sentence is read on the next turn, and begins
            // speaking itself.
            awaitStart("the second sentence") { [self] second in
                if case .failure(let failure) = second { return finish(.failure(failure)) }
                guard book.spokenSentenceCount == 2 else {
                    return finish(.failure(CheckFailure(message: "the next sentence was not read when it arrived")))
                }
                guard bookTotals(store.reading, bookId: shelfBook.id).sentencesHeard == 2 else {
                    return finish(.failure(CheckFailure(message: "the reading log did not count the sentences heard")))
                }
                finish(
                    .success(
                        String(
                            format: "2 sentences read as they arrived, each heard to begin, "
                                + "none on the keystroke path (slowest key %.0fµs)", slowest)))
            }
        }
    }

    /// Types a sentence through the input client, and answers the slowest
    /// keystroke in microseconds.
    private func type(_ sentence: String) -> Double {
        var slowest = 0.0
        for unit in sentence.utf16 {
            let before = DispatchTime.now().uptimeNanoseconds
            book.typeThroughInput(String(utf16CodeUnits: [unit], count: 1))
            slowest = max(slowest, Double(DispatchTime.now().uptimeNanoseconds - before) / 1000)
        }
        return slowest
    }
}
