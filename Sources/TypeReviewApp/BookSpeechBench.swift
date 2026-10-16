import AppKit
import TypeReviewKit

extension Diagnostics {
    /// The Book screen's sentence speech, for `--speechbench`: offered,
    /// spoken, and never on the typing path.
    ///
    /// On a Book screen of its own, over a scratch shelf, so the bench writes
    /// nothing into the user's books or reading log. Read Each Sentence First
    /// is switched on in the argument domain, never on disk.
    ///
    /// Answers a line for the report, or a failure.
    static func checkSentenceSpeech(then finish: @escaping (Result<String, CheckFailure>) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeReviewSpeechBench-\(UUID().uuidString)", isDirectory: true)
        let store = BookStore(profileDirectory: directory)
        guard let shelfBook = BundledShelf.books.first else {
            return finish(.failure(CheckFailure(message: "there is no shelf book to read from")))
        }
        do { try store.add(shelfBook) } catch {
            return finish(.failure(CheckFailure(message: "the scratch shelf refused a book: \(error)")))
        }
        let argumentsBefore = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = argumentsBefore
        arguments[AppPreferences.readSentencesFirst.key] = true
        arguments[AppPreferences.speakWords.key] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        let book = BookViewController()
        book.store = store
        var clock: Double = 0
        book.clock = {
            clock += 150
            return clock
        }
        var started = 0
        book.onUtteranceStarted = { started += 1 }
        _ = book.view
        func done(_ result: Result<String, CheckFailure>) {
            book.leave()
            book.onUtteranceStarted = nil
            UserDefaults.standard.setVolatileDomain(argumentsBefore, forName: UserDefaults.argumentDomain)
            try? FileManager.default.removeItem(at: directory)
            finish(result)
        }

        book.open(shelfBook.id)
        // Offered: there is a sentence, so Hear Sentence has something to say.
        guard book.canSpeak, let sentence = book.currentSentenceText else {
            return done(.failure(CheckFailure(message: "the Book screen offered no sentence to hear")))
        }
        // Not on the typing path: the sentence arriving asks for nothing on
        // the stack that showed it, and typing it asks for nothing at all.
        guard book.spokenSentenceCount == 0 else {
            return done(.failure(CheckFailure(message: "a sentence was spoken on the stack that opened the book")))
        }
        DispatchQueue.main.async {
            guard book.spokenSentenceCount == 1 else {
                return done(.failure(CheckFailure(
                    message: "with Read Each Sentence First on, \(book.spokenSentenceCount) sentences were read")))
            }
            var slowest = 0.0
            for unit in sentence.utf16 {
                let before = DispatchTime.now().uptimeNanoseconds
                book.typeThroughInput(String(utf16CodeUnits: [unit], count: 1))
                slowest = max(slowest, Double(DispatchTime.now().uptimeNanoseconds - before) / 1000)
            }
            guard book.sentence == 1, book.spokenSentenceCount == 1 else {
                return done(.failure(CheckFailure(
                    message: "typing a sentence spoke \(book.spokenSentenceCount - 1) sentences on the keystroke path")))
            }
            // Spoken: the next sentence is read on the next turn, and is heard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard book.spokenSentenceCount == 2 else {
                    return done(.failure(CheckFailure(message: "the next sentence was not read when it arrived")))
                }
                guard started >= 1 else {
                    return done(.failure(CheckFailure(message: "a sentence was handed over and never began speaking")))
                }
                guard bookTotals(store.reading, bookId: shelfBook.id).sentencesHeard == 2 else {
                    return done(.failure(CheckFailure(message: "the reading log did not count the sentences heard")))
                }
                done(
                    .success(
                        String(
                            format: "2 sentences read as they arrived, %d utterance(s) heard, "
                                + "none on the keystroke path (slowest key %.0fµs)",
                            started, slowest)))
            }
        }
    }
}
