import AppKit
import TypeReviewKit

extension Diagnostics {
    /// How long Hear Passage or Hear Word may take to begin before the bench
    /// calls it silent. The synthesizer is already built by the rounds.
    fileprivate static let hearStartSeconds: Double = 8

    /// Practice ▸ Hear Passage and Hear Word, for `--speechbench`: on a quote
    /// each is heard to begin, the word cutting off the passage; on a
    /// generated drill neither is offered and neither says anything. First, a
    /// burst of finished words leaves no backlog.
    ///
    /// Runs while the bench's Quotes channel is still in the argument domain,
    /// and switches to the generated channel there too, so the user's own
    /// source is never touched — the bench's `restore` puts the domain back.
    ///
    /// Answers a line for the report, or a failure.
    static func checkPracticeHearing(
        _ practice: PracticeViewController,
        then finish: @escaping (Result<String, CheckFailure>) -> Void
    ) {
        func fail(_ message: String) {
            practice.onWordStarted = nil
            finish(.failure(CheckFailure(message: message)))
        }
        // Each utterance must be heard to begin, with a deadline of its own,
        // so the sentence cannot vouch for the word.
        func awaitStart(
            of what: String, within seconds: Double = hearStartSeconds, _ speak: () -> Void,
            then next: @escaping () -> Void
        ) {
            var started = false
            practice.onWordStarted = { started = true }
            speak()
            let deadline = Date().addingTimeInterval(seconds)
            func poll() {
                if started { return next() }
                guard Date() < deadline else {
                    return fail("\(what) was handed over and did not begin within \(seconds)s")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
            poll()
        }

        // The menus answer for the screen showing, so Practice is shown —
        // not remembered, so the user's own screen comes back next launch.
        (NSApp.delegate as? AppDelegate)?.show(.practice, remember: false)
        practice.startFreshRun()
        DispatchQueue.main.async {
            guard practice.passageIsSpeakable, practice.canHear else {
                return fail("a Quotes passage was not offered to Hear Passage")
            }
            guard menuItems(#selector(AppDelegate.speakSentence(_:))).first?.title == "Hear Passage" else {
                return fail("on Practice the first of the two is not titled Hear Passage")
            }
            guard hearMenusOffered() == true else {
                return fail("Practice ▸ Hear Passage or Hear Word is missing, hidden or greyed out on a quote")
            }
            checkNoBacklog(practice, fail: fail) {
            let sentencesBefore = practice.spokenSentenceCount
            awaitStart(of: "Hear Passage", { practice.hearSentence() }) {
                guard practice.spokenSentenceCount == sentencesBefore + 1 else {
                    return fail("Hear Passage handed over \(practice.spokenSentenceCount - sentencesBefore) passages")
                }
                // The whole passage, not the sentence at the cursor: that read
                // only the last sentence once a run was over.
                guard practice.lastSentenceHeard == practice.currentPassage else {
                    return fail("Hear Passage read part of the passage, not all of it")
                }
                let wordsBefore = practice.spokenWordCount
                // Asked while the sentence is still being read, and given a
                // second: a cut-off begins within milliseconds, and the
                // shortest quote takes about two seconds to read, so a word
                // that waited for the sentence to end fails here.
                awaitStart(of: "Hear Word", within: 1, { practice.hearWord() }) {
                    guard practice.spokenWordCount == wordsBefore + 1 else {
                        return fail("Hear Word handed over \(practice.spokenWordCount - wordsBefore) words")
                    }
                    practice.onWordStarted = nil
                    checkDrillIsRefused(practice, then: finish)
                }
            }
            }
        }
    }

    /// Five finished words in one burst reach the synthesizer as two: the one
    /// speaking, and the newest. The rest are replaced while they wait.
    ///
    /// Without the player's own hold this was five. `stopSpeaking(at: .word)`
    /// was trusted to flush the queue and does not, so a fast typist heard
    /// every word, further and further behind.
    private static func checkNoBacklog(
        _ practice: PracticeViewController, fail: @escaping (String) -> Void,
        then next: @escaping () -> Void
    ) {
        let before = practice.spokenWordCount
        for word in ["elephants", "giraffes", "crocodiles", "kangaroos", "hippos"] {
            practice.speakWord(word)
        }
        let deadline = Date().addingTimeInterval(hearStartSeconds * 2)
        func poll() {
            guard practice.isSpeechBusy else {
                let handed = practice.spokenWordCount - before
                guard handed == 2 else {
                    return fail("five words in a burst were handed over as \(handed), not 2")
                }
                return next()
            }
            guard Date() < deadline else { return fail("a burst of five words never finished") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
    }

    /// Whether Hear Passage and Hear Word are both shown and enabled, both
    /// greyed out, or neither — nil for a mixed or missing pair, which cannot
    /// pass for either.
    private static func hearMenusOffered() -> Bool? {
        let items = menuItems(#selector(AppDelegate.speakSentence(_:)))
            + menuItems(#selector(AppDelegate.speakWord(_:)))
        guard items.count == 2, items.allSatisfy({ !$0.isHidden }) else { return nil }
        if items.allSatisfy(\.isEnabled) { return true }
        if items.allSatisfy({ !$0.isEnabled }) { return false }
        return nil
    }

    /// The other half: a generated drill offers neither, and asking anyway
    /// says nothing.
    private static func checkDrillIsRefused(
        _ practice: PracticeViewController,
        then finish: @escaping (Result<String, CheckFailure>) -> Void
    ) {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["CorpusChannel"] = CorpusChannel.generated.rawValue
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        practice.applyTypingPreferences()
        // Replaces the quote, which also stops whatever it was still saying.
        practice.startFreshRun()
        DispatchQueue.main.async {
            let (sentences, words) = (practice.spokenSentenceCount, practice.spokenWordCount)
            guard !practice.canHear, hearMenusOffered() == false else {
                return finish(.failure(CheckFailure(message: "a generated drill was offered to Hear Passage")))
            }
            practice.hearSentence()
            practice.hearWord()
            guard practice.spokenSentenceCount == sentences, practice.spokenWordCount == words else {
                return finish(.failure(CheckFailure(message: "asked anyway, a generated drill was read aloud")))
            }
            finish(.success("a quote's whole passage and a word each heard to begin; a drill offered neither"))
        }
    }
}
