@preconcurrency import AVFoundation
import NaturalLanguage

/// Reads a finished word aloud.
///
/// **Nothing expensive happens on the keystroke path.** `AVSpeechSynthesizer`
/// is asynchronous once it has been asked to speak, but building one is not:
/// the first construction reaches out to the system speech service, and a
/// voice lookup walks every installed voice. Both are done ahead of time —
/// `prepare()` is called when a passage arrives and when the setting changes,
/// never from inside a keystroke — so `speak(word:)` is a string, an utterance
/// and an enqueue.
///
/// **A new word waits for the current one to finish, then replaces whatever
/// was queued behind it.** The plan accepted clipping here — "the word I just
/// finished", not completeness — and that was wrong, for a reason only using it
/// shows: the part an immediate interrupt cuts is the *end* of the word, and in
/// English the end of the word is the plural. `cats` came out as `cat`. A
/// feature for a child learning to read cannot teach them the wrong word.
///
/// `.word` rather than `.immediate` costs nothing and fixes it. Stopping at a
/// word boundary lets the utterance in progress complete, and because every
/// utterance here is one word, "the current word" and "the whole utterance" are
/// the same thing. The queue is still flushed, so a third word replaces a
/// second one that had not started — the backlog stays at one, and what you
/// eventually hear is still the most recent word you finished.
@MainActor
final class SpeechPlayer: NSObject {
    /// The passage on screen and the voice for its language.
    ///
    /// Detected once per passage rather than per word, and deliberately: a
    /// token like `chat` is a word in two languages, and a single token cannot
    /// resolve which.
    private var passage: String = ""
    private var voice: AVSpeechSynthesisVoice?
    private var voiceIsResolved = false
    /// The voice preference the cached voice was resolved against.
    ///
    /// So that changing the choice in Settings takes effect on the next word
    /// rather than the next passage, without anything having to tell this
    /// object that it changed. The alternative was plumbing the changed
    /// preference key through two callers, and a cache that notices its own
    /// input moved cannot be left out of step by a caller that forgets.
    private var resolvedChoice: String?

    /// Built once, on first use — but `prepare()` is what arranges for that
    /// first use to happen off the typing path. Reaching it from `speak` would
    /// build it there, which is the one thing this class exists to avoid;
    /// refusing to build it there would be worse still, because the feature
    /// would go silent with nothing to say why.
    private var builtSynthesizer: AVSpeechSynthesizer?
    private var synthesizer: AVSpeechSynthesizer {
        if let builtSynthesizer { return builtSynthesizer }
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        builtSynthesizer = synthesizer
        return synthesizer
    }
    /// A deferred `prepare()` already in flight, so a burst of them queues one
    /// block rather than one each.
    ///
    /// Separate from "the synthesizer exists" and from "the voice is
    /// resolved", and that separation is the whole point: one flag covering
    /// all three made `prepare()` a no-op after the first passage, so every
    /// later passage kept the *first* one's voice — a French quote read in
    /// English, once per launch, silently.
    private var isPreparing = false
    /// Voices can be downloaded or removed in System Settings while this app is
    /// running, and the cache above would otherwise hold a resolution made
    /// against a list that no longer exists — a voice the user just installed
    /// staying unavailable until the next passage, or a removed one still
    /// selected. Cheap to watch, and it only ever costs one re-resolution.
    private var voicesObserver: NSObjectProtocol?

    /// How many times a passage's language has been resolved.
    ///
    /// Read by `--speechbench`, which asserts it lands once per passage rather
    /// than once per launch or once per word. §6 says the language is detected
    /// per passage — a token like `chat` is a word in two languages — and that
    /// is the kind of claim that stays true only while something checks it.
    private(set) var voiceResolutions = 0

    /// Utterances actually handed to the synthesizer for a finished word.
    ///
    /// Counted here rather than at the call site, and the difference is the
    /// point: the caller's count says a word passed the gate and the word rule,
    /// which is one suppression short of proof that anything was asked to
    /// speak. `--speechbench` needs the stronger claim.
    private(set) var wordsSpoken = 0

    /// When an utterance began speaking, and how long the last one lasted.
    ///
    /// **Duration, not a count.** Counting cancellations cannot see this
    /// defect: measured against the real framework, an utterance cut off by
    /// `stopSpeaking(at: .immediate)` is reported through `didFinish` like any
    /// other, and only its *length* gives it away — 267ms of a 607ms `cats`,
    /// which is "ca" with the plural missing. `--speechbench` interrupts a word
    /// on purpose and checks how much of it survived.
    private var utteranceStartedAt: Date?
    /// Fired when a word begins, so a caller can interrupt it while it is
    /// genuinely in flight rather than guessing at the latency.
    var onWordStarted: (() -> Void)?
    /// Fired when one ends, with how many milliseconds it was audible.
    var onWordEnded: ((Int) -> Void)?

    override init() {
        super.init()
        voicesObserver = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Registered with `queue: .main`, so this runs on the main thread —
            // the same reasoning `KeyboardDrawer`'s observers state for using
            // `assumeIsolated` rather than hopping to a later turn.
            MainActor.assumeIsolated { self?.voiceIsResolved = false }
        }
    }

    // MARK: - Ahead of the typing

    /// The passage now on screen. Cheap on purpose: it stores the text and
    /// forgets the old voice, leaving the new one to be resolved by whoever
    /// gets there first — `prepare()` normally, and the first thing to speak
    /// if preparation was somehow missed.
    func setPassage(_ text: String) {
        stop()
        passage = text
        voice = nil
        voiceIsResolved = false
    }

    /// Builds the synthesizer and resolves the voice, off the caller's stack.
    ///
    /// Deferred by one runloop turn rather than run inline. The callers are a
    /// run starting and a preference changing — neither is a keystroke, but
    /// both are moments the user is waiting on, and the first construction of
    /// a synthesizer is not free.
    func prepare() {
        guard !isPreparing else { return }
        isPreparing = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isPreparing = false
            _ = synthesizer
            resolveVoice()
        }
    }

    // MARK: - Speaking

    /// One finished word. The only method reached from the typing path.
    func speak(word: String) {
        // A no-op after the first word of a passage. Here as well as in
        // `prepare()` because the right voice matters more than the runloop
        // turn it saves: if preparation were ever missed, this is the
        // difference between a French quote read in French and one read in
        // whatever the machine defaults to, which nobody would report as a bug.
        resolveVoice()
        // `.word`, not `.immediate`. See the note at the top of the file: an
        // immediate stop cuts the end off the word being spoken, and the end of
        // an English word is where its plural lives.
        synthesizer.stopSpeaking(at: .word)
        synthesizer.speak(utterance(word))
        wordsSpoken += 1
    }

    /// Silences everything. Safe to call when nothing is speaking.
    func stop() {
        // The built one, not the accessor: reaching through the accessor would
        // construct a synthesizer on the way past just to ask it to be quiet,
        // which is exactly the work `prepare()` exists to keep off other
        // people's stacks — and `stop()` runs at the start of every run.
        builtSynthesizer?.stopSpeaking(at: .immediate)
    }

    /// Speech rides the app's existing sound volume, so one slider governs
    /// everything audible. Read per utterance rather than cached: it is one
    /// `UserDefaults` lookup against an utterance that is about to be
    /// synthesised, and a stale volume is a slider that does nothing.
    private func utterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.volume = Float(AppPreferences.soundVolume.value)
        return utterance
    }

    // MARK: - The voice

    /// The voice for the passage's language, resolved once.
    ///
    /// A prefix of the text rather than all of it: language identification
    /// settles long before a paragraph is out, and this runs on the main
    /// thread.
    private func resolveVoice() {
        let choice = AppPreferences.speechVoice.value
        guard !voiceIsResolved || choice != resolvedChoice else { return }
        voiceIsResolved = true
        resolvedChoice = choice
        voiceResolutions += 1
        voice = nil
        // A voice the user picked outranks the one the text implies. They said
        // something more specific than a language detector can infer.
        //
        // An identifier this machine no longer has — a voice removed in System
        // Settings — falls through to automatic rather than to silence.
        if !choice.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: choice) {
            voice = chosen
            return
        }
        guard !passage.isEmpty else { return }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(passage.prefix(400)))
        guard let language = recognizer.dominantLanguage else { return }
        voice = Self.voice(for: language.rawValue)
    }

    /// Says which voice is in effect, in that voice.
    ///
    /// The voice's own name, because it is a word in that voice's language and
    /// it identifies what was just picked. A fixed English sentence would be
    /// the wrong language for most of the list.
    func preview() {
        // No invalidation needed: `resolveVoice` compares the preference
        // against what it last resolved, so the choice just made is picked up
        // here for free.
        resolveVoice()
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance(voice?.name ?? "Automatic"))
    }

    /// The best installed voice for a language tag, or nil for the system
    /// default.
    ///
    /// Three steps, because the two vocabularies do not line up.
    /// `NLLanguageRecognizer` answers with a language — `en`, `zh-Hans` — and
    /// the voice list is keyed by locale — `en-GB`, `zh-CN`. An exact match is
    /// tried first, then any voice in the same language, then the script
    /// subtag is dropped so `zh-Hans` can still find `zh-CN`.
    private static func voice(for tag: String) -> AVSpeechSynthesisVoice? {
        if let exact = AVSpeechSynthesisVoice(language: tag) { return exact }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let match = voices.first(where: { $0.language.hasPrefix(tag + "-") }) { return match }
        guard let base = tag.split(separator: "-").first.map(String.init), base != tag else {
            return nil
        }
        return voices.first { $0.language == base || $0.language.hasPrefix(base + "-") }
    }
}

/// The English voices, grouped by locale for a menu.
///
/// English only, deliberately. A stock machine carries 180 voices across 49
/// languages, and a picker offering all of them asks somebody choosing a voice
/// for their child to scroll past Bokmål to find one. Automatic still follows
/// whatever language the passage is in — this list is for the case where a
/// person wants a particular voice, and that case is English here.
///
/// Grouped by locale rather than listed flat, because `en-GB` and `en-AU` are
/// the distinction that actually matters when picking one, and within a locale
/// the better-sounding voices come first: `.premium` and `.enhanced` are
/// downloads the user went and fetched, and burying them under a dozen
/// alphabetically-earlier defaults would hide the ones they chose.
enum SpeechVoices {
    struct Voice: Equatable {
        let name: String
        let identifier: String
    }

    struct Group: Equatable {
        let language: String
        let voices: [Voice]
    }

    static func grouped() -> [Group] {
        var byLocale: [String: [AVSpeechSynthesisVoice]] = [:]
        for voice in AVSpeechSynthesisVoice.speechVoices() where isEnglish(voice.language) {
            byLocale[voice.language, default: []].append(voice)
        }
        return
            byLocale
            .map { (code: $0.key, voices: $0.value) }
            .sorted { displayName($0.code) < displayName($1.code) }
            .map { entry in
                Group(
                    language: displayName(entry.code),
                    voices: entry.voices
                        // Quality first, then name. `.premium` and `.enhanced`
                        // are downloads the user chose to make; putting them
                        // under a dozen alphabetically-earlier default voices
                        // would hide the ones they went and fetched.
                        .sorted {
                            $0.quality.rawValue == $1.quality.rawValue
                                ? $0.name < $1.name
                                : $0.quality.rawValue > $1.quality.rawValue
                        }
                        .map { Voice(name: $0.name, identifier: $0.identifier) })
            }
    }

    /// `en`, `en-US`, `en-GB` — and not `enm` or anything else that merely
    /// starts with those two letters.
    private static func isEnglish(_ code: String) -> Bool {
        code == "en" || code.hasPrefix("en-")
    }

    private static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

extension SpeechPlayer: AVSpeechSynthesizerDelegate {
    /// `nonisolated`, and it carries nothing across the hop at all.
    ///
    /// Not the utterance, which is not `Sendable`, and not its identity either:
    /// an `ObjectIdentifier` is an address, and the object it names can be
    /// released and its address reused before the hop lands. Nothing here needs
    /// to know *which* utterance ended — only how long it lasted, and that is
    /// timed on the main actor from `utteranceStartedAt`, which is where the
    /// duration that tells a whole word from a clipped one comes from.
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.utteranceBegan() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.utteranceEnded() }
    }

    /// A cancelled utterance ends too, and is reported for the same reason.
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.utteranceEnded() }
    }

    private func utteranceBegan() {
        utteranceStartedAt = Date()
        onWordStarted?()
    }

    private func utteranceEnded() {
        guard let startedAt = utteranceStartedAt else { return }
        utteranceStartedAt = nil
        onWordEnded?(Int(Date().timeIntervalSince(startedAt) * 1000))
    }
}
