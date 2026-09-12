import AVFoundation
import AppKit
import TypeReviewKit

/// The app's two end-to-end checks, run from the command line.
///
/// Extracted from `AppDelegate`, where they were the largest thing in the file
/// by some margin — a 175-line integration test and a 40-line audio check
/// living inside the object that also builds menus, owns windows and routes
/// keystrokes. Nothing here is delegate state: the self-test needs the
/// practice controller and the sound check needs nothing at all, so both are
/// static and take what they use.
///
/// They stay in the app target rather than moving to `TypeReviewKit`, and
/// deliberately: what they check is whether the *app* is wired to the engine,
/// which is exactly the question no unit test can answer.
@MainActor
enum Diagnostics {
    /// The command-line checks, named once.
    ///
    /// Read by `main.swift` before the app is configured, by the launch path
    /// that decides whether to come to the front, and by the mutual-exclusion
    /// check. Three copies of this list is three chances for a new check to be
    /// forgotten by one of them.
    static let flags = ["--soundcheck", "--selftest", "--speechbench"]

    /// Whether this launch is a check rather than somebody opening the app.
    ///
    /// **A check does not take the screen.** These run beside whatever the
    /// person at the keyboard is actually doing — often in a loop, while
    /// developing the very thing being checked — and an app that activates
    /// itself and steals focus once per run makes the machine unusable for as
    /// long as the loop lasts. Nothing any of them measures needs the app to be
    /// frontmost: the self-test types through `insertText` rather than through
    /// key events, and renders the view with `cacheDisplay`, which does not
    /// require the window to be on screen.
    static var isRunningCheck: Bool {
        CommandLine.arguments.contains(where: flags.contains)
    }

    /// Proves every pack can actually produce sound in the built app.
    ///
    /// The unit tests cover the synthesis arithmetic, and they would pass just
    /// as happily if `typewriter.m4a` never made it into the bundle — the
    /// sample pack would simply go quiet, which looks exactly like a pack the
    /// user has not selected. This runs against the real app: real bundle,
    /// real decode, real slicing.
    static func runSoundCheck() {
        // A real `await`, not a nested run loop. Spinning `RunLoop.main`
        // inside a main-queue block keeps the main actor occupied, so the
        // decode task's hop back to it never runs and the wait always times
        // out — the check reported "no buffer" for a recording that was simply
        // never given the chance to arrive.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            let player = KeySoundPlayer()
            var failures: [String] = []
            for pack in KeySoundPack.all {
                player.setPack(pack)
                player.setVolume(1)
                // The recorded pack decodes off the main actor now, so it is
                // not ready the instant it is selected. Waited for rather than
                // slept past a fixed guess: the load reports its own failure,
                // and a check that gave up early would say "no buffer" for a
                // recording that was merely still arriving.
                if case .sample = pack.kind {
                    await waitForSample(player)
                    if let reason = player.loadFailure {
                        failures.append("\(pack.name): \(reason)")
                        continue
                    }
                }
                if case .silent = pack.kind {
                    if player.renderedPeak(for: .standard) != nil {
                        failures.append("\(pack.name): the off pack produced audio")
                    }
                    continue
                }
                for category in SoundCategory.allCases {
                    guard let peak = player.renderedPeak(for: category) else {
                        failures.append("\(pack.name)/\(category.rawValue): no buffer")
                        continue
                    }
                    guard peak > 0.001 else {
                        failures.append(
                            "\(pack.name)/\(category.rawValue): silent (peak \(peak))")
                        continue
                    }
                    print("SOUNDCHECK \(pack.name)/\(category.rawValue) peak \(peak)")
                }
            }
            // The one voice no pack describes, and therefore the one the loop
            // above cannot reach. A tone that renders silence looks exactly
            // like a feature that works: every wiring check passes, the hook
            // fires, and nothing is heard.
            if let peak = player.renderedMistypePeak() {
                if peak > 0.001 {
                    print("SOUNDCHECK mistype peak \(peak)")
                } else {
                    failures.append("mistype: silent (peak \(peak))")
                }
            } else {
                failures.append("mistype: no buffer")
            }
            if failures.isEmpty {
                print("SOUNDCHECK OK: every pack produces audio, and the mistype tone does too")
                exit(0)
            }
            for failure in failures { print("SOUNDCHECK FAIL: \(failure)") }
            exit(1)
        }
    }

    /// Waits for the recorded pack to finish decoding, or for it to say why it
    /// cannot.
    private static func waitForSample(_ player: KeySoundPlayer) async {
        let deadline = Date().addingTimeInterval(10)
        while player.renderedPeak(for: .standard) == nil, player.loadFailure == nil,
            Date() < deadline
        {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Times the keystroke path with word speech off and then on.
    ///
    /// §6 of the speech plan makes an asynchronous promise: nothing on the
    /// keystroke path waits on speech — no synthesizer construction, no voice
    /// lookup, no dictionary call. That promise is the kind that holds on the
    /// day it is written and quietly stops holding when somebody moves a line,
    /// so it is measured rather than asserted.
    ///
    /// Through `insertText`, the same entry point AppKit uses, so what is
    /// timed is the path a real keystroke takes.
    static func runSpeechBench(practice: PracticeViewController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let view = practice.view.subviews.compactMap({ $0 as? TypingView }).first else {
                print("SPEECHBENCH FAIL: no typing surface")
                exit(1)
            }
            // The benchmark's settings go in the *argument* domain, which sits
            // above the persistent one in `UserDefaults`' search order and is
            // never written to disk. So the user's real Speak Words and source
            // channel are not touched at all, and there is nothing to put back
            // — not on the timeout, not on Ctrl-C, not on a crash. The previous
            // arrangement wrote the real preferences and restored them on the
            // two programmed exits, which left somebody's channel switched to
            // Quotes if they interrupted the run.
            //
            // Overlaid on whatever is already there, not written over it:
            // `setVolatileDomain` *replaces* a domain's contents, and the
            // argument domain is where a real `-SpeechVoice …` on the command
            // line lands — so replacing it wholesale discarded the override the
            // person running the benchmark had just asked for.
            let argumentsBefore = UserDefaults.standard.volatileDomain(
                forName: UserDefaults.argumentDomain)
            var benchArguments = argumentsBefore
            benchArguments["CorpusChannel"] = CorpusChannel.quotes.rawValue
            benchArguments[AppPreferences.speakWords.key] = false
            UserDefaults.standard.setVolatileDomain(
                benchArguments, forName: UserDefaults.argumentDomain)
            // The newest run's index, not how many runs there are. History is
            // trimmed at `maxHistory`, so past the cap a recorded run replaces
            // an older one and the *count* does not move — an assertion that
            // subtracted counts would pass over a real write. The index is
            // monotonic and never reused.
            let indexBefore = practice.history.map(\.index).max() ?? -1
            // These are the user's real settings, so putting them back is not
            // tidiness. Registered here rather than at the top level so the
            // timeout can restore them too: leaving somebody's source channel
            // switched to Quotes because a benchmark hung is a side effect
            // they would never connect to running one.
            let restore = {
                UserDefaults.standard.setVolatileDomain(
                    argumentsBefore, forName: UserDefaults.argumentDomain)
                practice.applyTypingPreferences()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                restore()
                print("SPEECHBENCH FAIL: timed out")
                exit(2)
            }
            // Quotes, because the provenance gate refuses a generated drill —
            // and `auto` in an early curriculum serves exactly that. Left on
            // `auto` the measurement would compare silence against silence and
            // report a pass.
            //
            // Not sufficient on its own: a profile in benchmark mode with
            // numbers, punctuation or a timed test is served generated text
            // whatever the channel says. The rounds count what the gate
            // actually accepted, so that case is named rather than reported as
            // a failure of the code.
            practice.applyTypingPreferences()

            let utterancesFrom = practice.spokenWordCount
            runRound(
                practice, view, startedAt: Date(), round: 0, state: BenchState(),
                restore: restore
            ) { state in
                // The rounds' utterances, counted before the clipping check
                // speaks a word of its own. Read afterwards, its two
                // `speakWord` calls satisfied the "speech reached the
                // synthesizer" assertion by themselves — so the rounds could
                // have produced nothing and the check would still have passed.
                //
                // One turn first, so the last round's queued handoffs land.
                DispatchQueue.main.async {
                    let roundUtterances = practice.spokenWordCount - utterancesFrom
                    // The clipping check speaks, so it runs before the settings
                    // go back — and it needs real time, because what it
                    // measures is whether an utterance was allowed to finish.
                    checkNothingIsClipped(practice) { clip in
                        restore()
                        report(
                            state: state, clip: clip,
                            utterances: roundUtterances,
                            runsRecorded: (practice.history.map(\.index).max() ?? -1)
                                - indexBefore)
                    }
                }
            }
        }
    }

    /// What the rounds accumulate.
    private struct BenchState {
        var silent: [Double] = []
        var speaking: [Double] = []
        var passages = 0
        var speakable = 0
        /// Words *offered* to the player during the off passes. Any at all
        /// means the setting is not doing what the measurement assumes.
        ///
        /// Offers rather than utterances, because only an offer can be pinned
        /// to a pass: it happens inside the keystroke, while the utterance is
        /// enqueued a runloop turn later — deliberately, so that speech cannot
        /// run inside the typing. The utterances are checked separately, in
        /// total, once the queue has drained.
        var silentWords = 0
        /// And during the on passes.
        var spokenWords = 0
        /// Voices resolved at all, whenever they were resolved.
        ///
        /// Separate from `lateResolutions`, and both are needed. Late ones
        /// catch work on the keystroke path; this catches the other failure —
        /// resolving once for the whole session and reusing that voice for
        /// every later passage, which is silent, wrong, and produces no late
        /// lookups whatsoever.
        var resolutions = 0
        /// Voices resolved *while keystrokes were being timed*.
        ///
        /// The number §6 is actually about. It should be zero: a passage
        /// arrives, `prepare()` resolves its voice on the next turn of the
        /// runloop, and the typist reaches the first word long after that.
        var lateResolutions = 0
    }

    /// Practice, Appearance, Sound, General, Data, About.
    ///
    /// Named once rather than written into both the check and its message,
    /// which is how the first version of this reported "built 6 panes, expected
    /// 6" — a failure message that argued with itself.
    private static let expectedSettingsPanes = 6

    /// Flips Speak Words for the benchmark without touching what is on disk.
    private static func setBenchSpeech(_ on: Bool) {
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[AppPreferences.speakWords.key] = on
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    /// How many passages each mode is measured over. A single quote is about a
    /// hundred keystrokes, which is too few to read a tail from.
    private static let benchPasses = 12

    /// How long the whole measurement may take before it gives up.
    ///
    /// Checked between rounds rather than only by the watchdog, which sits on
    /// the same main queue the measurement uses. This does not survive a call
    /// that blocks for ever — nothing on this queue does — but it turns
    /// "unusably slow" into a bounded failure with a number attached.
    private static let benchDeadlineSeconds: Double = 120

    /// One interleaved round: the same measurement with speech off, then on.
    ///
    /// Chained through the main queue rather than run in a loop, and that is
    /// the measurement rather than a matter of style. `prepare()` defers the
    /// synthesizer and the voice by one turn of the runloop — which is how a
    /// real passage has both ready long before the typist reaches its first
    /// word — and a synchronous loop never yields, so it would time the
    /// fallback path on every passage and never the one that actually runs.
    ///
    /// Interleaved, not one mode after the other: each round draws a fresh
    /// passage and the machine drifts under load, so two consecutive blocks
    /// would compare different workloads on a differently-warmed machine and
    /// call the difference speech.
    private static func runRound(
        _ practice: PracticeViewController, _ view: TypingView, startedAt: Date,
        round: Int, state: BenchState, restore: @escaping () -> Void,
        finish: @escaping (BenchState) -> Void
    ) {
        guard round < benchPasses else { return finish(state) }
        guard Date().timeIntervalSince(startedAt) < benchDeadlineSeconds else {
            // Through `restore` like every other way out of here. These are the
            // user's real settings, and an exit that skipped this would leave
            // their source channel switched to Quotes with nothing to connect
            // it to.
            restore()
            print(
                "SPEECHBENCH FAIL: gave up after "
                    + String(format: "%.0fs", benchDeadlineSeconds))
            exit(2)
        }

        setBenchSpeech(false)
        // Applied here rather than waited for: the volatile write posts no
        // notification, and the pass below would otherwise measure the state
        // this line is trying to leave.
        practice.applyTypingPreferences()
        practice.startFreshRun()
        DispatchQueue.main.async {
            let silentWordsBefore = practice.wordsOffered
            let off = typePassage(practice, view)
            let silentWords = practice.wordsOffered - silentWordsBefore

            setBenchSpeech(true)
            practice.applyTypingPreferences()
            practice.startFreshRun()
            let speakable = practice.passageIsSpeakable
            // Before the hop that runs `prepare()`, so the window covers this
            // passage's resolution and nothing that was already in flight.
            let resolutionsBefore = practice.voiceResolutions
            DispatchQueue.main.async {
                // Read after the turn, not before it: everything `prepare()`
                // was going to do has happened by now, so anything resolved
                // from here on was resolved on the keystroke path.
                let voicesBefore = practice.voiceResolutions
                let spokenWordsBefore = practice.wordsOffered
                let on = typePassage(practice, view)
                // One turn before the next round replaces the passage, so the
                // words this pass queued are actually spoken.
                //
                // Speech is handed off a runloop turn after the keystroke, and
                // a word whose passage has already been replaced is dropped —
                // correctly, since it is no longer the word on screen. But this
                // loop types a whole passage without yielding, so *every* word
                // it queued was still pending when the next round started, and
                // all of them were dropped: 356 words offered and 29 spoken.
                // The measurement has to let them land.
                DispatchQueue.main.async {
                var next = state
                next.silent += off.samples
                next.speaking += on.samples
                next.passages += on.typed ? 1 : 0
                next.speakable += speakable ? 1 : 0
                next.silentWords += silentWords
                next.spokenWords += practice.wordsOffered - spokenWordsBefore
                next.lateResolutions += practice.voiceResolutions - voicesBefore
                next.resolutions += practice.voiceResolutions - resolutionsBefore
                runRound(
                    practice, view, startedAt: startedAt, round: round + 1,
                    state: next, restore: restore, finish: finish)
                }
            }
        }
    }

    /// One passage, typed through the real input path and timed per keystroke.
    private static func typePassage(
        _ practice: PracticeViewController, _ view: TypingView
    ) -> (samples: [Double], typed: Bool) {
        // Newlines are not typed: `TextInput` steps over them by itself, so
        // sending one would be scored against the wrong character and every
        // word after it would be wrong — and silent.
        let units = Array(practice.currentPassage.utf16).filter { $0 != 0x0A }
        guard units.count > 1 else { return ([], false) }
        var samples: [Double] = []
        samples.reserveCapacity(units.count - 1)
        // All but the last. Finishing a run records a result and saves the
        // profile, and a benchmark has no business writing to it.
        //
        // The clock cannot finish one either: a timed benchmark needs ten
        // seconds of active typing at the shortest the settings allow, and a
        // passage here accumulates tens of milliseconds. `runsRecorded` is the
        // loud backstop if that ever stops being true.
        for unit in units.dropLast() {
            let text = String(utf16CodeUnits: [unit], count: 1)
            let start = DispatchTime.now().uptimeNanoseconds
            view.insertText(text, replacementRange: NSRange())
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000)
        }
        return (samples, true)
    }

    /// Interrupts a word on purpose, and measures how much of it survived.
    ///
    /// This is the check the plural bug needed, and the only shape of check
    /// that can see it. Every other number here is blind: the word rule
    /// produces `cats`, the player is handed `cats`, the synthesizer is asked
    /// for `cats`, and what leaves the speaker is `ca` — because the next word
    /// cut it off partway through.
    ///
    /// **Counting cancellations does not work.** Measured against the real
    /// framework, an utterance stopped with `.immediate` is reported through
    /// `didFinish` exactly like one that ran to the end. The first version of
    /// this check counted starts against finishes, found them equal under both
    /// policies, and passed against the very bug it was written for. Only the
    /// duration tells them apart: 267ms of a 607ms `cats` against 597ms.
    ///
    /// The interrupt is fired from `onWordStarted` rather than after a fixed
    /// delay, because a word can only be clipped while it is genuinely in
    /// flight — and an interrupt that lands before the utterance begins clips
    /// nothing and passes.
    private static let clipInterruptSeconds: Double = 0.25

    /// How much longer than the interrupt the word has to keep going.
    ///
    /// Relative, not an absolute floor: a faster voice says the same word in
    /// less time, and a fixed 450ms would start failing on one. A word cut off
    /// at the interrupt lasts about as long as the interrupt; a word left alone
    /// runs well past it.
    private static let clipSurvivalFactor: Double = 1.4

    private static func checkNothingIsClipped(
        _ practice: PracticeViewController,
        then finish: @escaping ((audibleMs: Int, interruptedAfter: Double?)?) -> Void
    ) {
        // The timing rounds just spoke four hundred words and the last of them
        // is still in flight. Without this pause its ending lands on the
        // callbacks below and is measured instead — a stale duration of
        // effectively zero, which fails the check under every policy. That is
        // how this check first came to fail against its own fix.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var audible: Int?
            var started = 0
            var startedAt: Date?
            var interruptedAfter: Double?
            practice.onWordStarted = {
                started += 1
                guard started == 1 else { return }
                startedAt = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + clipInterruptSeconds) {
                    // When it *actually* fired, not when it was scheduled to.
                    // A main queue busy with the tail of the timed rounds can
                    // deliver this late, and measuring survival against the
                    // scheduled 250ms would then let a word cut off at 400ms
                    // clear a 350ms bar and pass.
                    interruptedAfter = startedAt.map { Date().timeIntervalSince($0) }
                    // The interrupt is just another finished word, which is
                    // exactly what happens when somebody types the next one.
                    practice.speakWord("next")
                }
            }
            practice.onWordEnded = { milliseconds in
                // Only once the word this check started has begun, so an
                // ending left over from the rounds cannot be mistaken for it.
                guard started >= 1, audible == nil else { return }
                audible = milliseconds
            }
            practice.speakWord("elephants")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                practice.onWordStarted = nil
                practice.onWordEnded = nil
                finish(audible.map { (audibleMs: $0, interruptedAfter: interruptedAfter) })
            }
        }
    }

    /// One sort, three statistics. Sorting per percentile meant sorting each
    /// sample array three times to print numbers that were already known.
    private struct Timings {
        let median: Double
        let p95: Double
        let slowest: Double
        let count: Int

        init(_ samples: [Double]) {
            let sorted = samples.sorted()
            count = sorted.count
            median = Timings.at(0.5, of: sorted)
            p95 = Timings.at(0.95, of: sorted)
            slowest = sorted.last ?? 0
        }

        private static func at(_ fraction: Double, of sorted: [Double]) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, max(0, Int(fraction * Double(sorted.count - 1))))]
        }
    }

    /// What speech is allowed to add to a typical keystroke, in microseconds.
    ///
    /// A budget, not a measurement of today's machine. 60 wpm is five
    /// keystrokes a second, so 250µs is a twentieth of a percent of the time
    /// between two keys — far below anything a typist could feel, and far above
    /// the enqueue this should be.
    private static let medianBudgetMicroseconds: Double = 250

    /// And what it may add to the slowest twentieth.
    ///
    /// The median alone cannot answer this. Speech happens on word boundaries —
    /// roughly one keystroke in five — so a cost paid only when a word finishes
    /// barely moves the median and would pass. It lands squarely in the tail.
    ///
    /// Looser than the median's, because the tail is where scheduler noise
    /// lives: an unrelated page fault shows up here, and a regression worth
    /// catching is a synchronous call, which costs milliseconds.
    private static let tailBudgetMicroseconds: Double = 2_000

    /// And what it may add to the single slowest keystroke of the run.
    ///
    /// The tail is not enough either. The per-passage voice resolution is one
    /// keystroke in about a hundred and fifty, so it sits past the 99th
    /// percentile and p95 cannot see it — and it is exactly the shape of the
    /// thing §6 forbids. Only the extreme catches a cost paid once per passage.
    ///
    /// 25ms is loose on purpose: it is far above the millisecond-scale hiccups
    /// a busy machine produces and far below what the work this guards against
    /// actually costs — building a synthesizer or walking the installed voice
    /// catalogue are tens to hundreds of milliseconds.
    private static let slowestBudgetMicroseconds: Double = 25_000

    private static func report(
        state: BenchState, clip: (audibleMs: Int, interruptedAfter: Double?)?,
        utterances: Int, runsRecorded: Int
    ) {
        let words = state.spokenWords
        let (silent, speaking) = (state.silent, state.speaking)
        let (passages, speakable) = (state.passages, state.speakable)
        guard !silent.isEmpty, !speaking.isEmpty else {
            print("SPEECHBENCH FAIL: no keystrokes were timed")
            exit(1)
        }
        // Said before anything else, because it is the one failure that is not
        // about the code. A profile in benchmark mode with numbers or
        // punctuation is served generated text whatever the channel says, and
        // the gate is right to refuse it.
        guard speakable > 0 else {
            print(
                "SPEECHBENCH FAIL: the provenance gate refused all \(passages) passages, "
                    + "so there was nothing to measure. This profile is most likely in "
                    + "benchmark mode with numbers, punctuation or a timed test, which is "
                    + "served generated text whatever the source channel says.")
            exit(1)
        }
        // Without this the whole check is vacuous: speech that never happened
        // and speech that costs nothing produce the same timings. The count
        // comes from the player, so it is utterances handed to the synthesizer
        // rather than words offered to the player and possibly dropped.
        guard words > 0 else {
            print("SPEECHBENCH FAIL: speech was on and not one word was offered")
            exit(1)
        }
        // And the stronger claim, in total rather than per pass: words were
        // not merely offered, they reached the synthesizer. Checked here
        // because `report` runs after the clipping check's own wait, by which
        // time everything queued during the rounds has drained.
        guard utterances > 0 else {
            print(
                "SPEECHBENCH FAIL: \(words) words were offered and none became an "
                    + "utterance — the player dropped every one of them")
            exit(1)
        }
        // The other half of that, and it is not symmetric noise: without it,
        // speech left switched on through the off passes produces two nearly
        // identical timings and a confident green.
        guard state.silentWords == 0 else {
            print(
                "SPEECHBENCH FAIL: \(state.silentWords) words were spoken with the "
                    + "setting off, so the two measurements are of the same thing")
            exit(1)
        }
        // Once per passage, counted whenever it happened. `lateResolutions`
        // below says none of it was on the keystroke path; this says it
        // happened at all, per passage — the failure it catches is resolving
        // once for the session and reusing that voice for every later passage,
        // which produces no late lookups and reads a French quote in English.
        guard state.resolutions == speakable else {
            print(
                "SPEECHBENCH FAIL: the voice was resolved \(state.resolutions) times over "
                    + "\(speakable) speakable passages — expected once each")
            exit(1)
        }
        // §6's promise, stated directly: the voice is resolved when the
        // passage arrives, not while somebody is typing it. `prepare()` had a
        // full turn of the runloop before each round's keystrokes, so anything
        // resolved during them was resolved on the path that is supposed to
        // stay clear. The latency gates below would miss it — one slow key in a
        // hundred and fifty sits past the 95th percentile — so it is counted
        // rather than inferred.
        guard state.lateResolutions == 0 else {
            print(
                "SPEECHBENCH FAIL: \(state.lateResolutions) voice lookups happened "
                    + "on the keystroke path — preparation is not running ahead of the typing")
            exit(1)
        }
        // A benchmark has no business in the user's history.
        guard runsRecorded == 0 else {
            print("SPEECHBENCH FAIL: the benchmark recorded \(runsRecorded) run(s)")
            exit(1)
        }

        guard let clip else {
            print("SPEECHBENCH FAIL: the interrupted word never started speaking")
            exit(1)
        }
        guard let interruptedAfter = clip.interruptedAfter else {
            print("SPEECHBENCH FAIL: the interrupt never fired, so nothing was tested")
            exit(1)
        }
        // Against when the interrupt actually landed, not when it was asked to.
        let interruptMs = Int(interruptedAfter * 1000)
        let survived = Int(Double(interruptMs) * clipSurvivalFactor)
        guard clip.audibleMs >= survived else {
            print(
                "SPEECHBENCH FAIL: a word interrupted after \(interruptMs)ms was audible for "
                    + "only \(clip.audibleMs)ms — it is being cut off partway through, "
                    + "which is heard as a missing plural")
            exit(1)
        }

        let off = Timings(silent)
        let on = Timings(speaking)
        let median = on.median - off.median
        let tail = on.p95 - off.p95
        let slowest = on.slowest - off.slowest
        print(
            String(
                format: "SPEECHBENCH off: median %.1fµs p95 %.1fµs max %.1fµs (%d keystrokes)",
                off.median, off.p95, off.slowest, off.count))
        print(
            String(
                format:
                    "SPEECHBENCH on:  median %.1fµs p95 %.1fµs max %.1fµs "
                    + "(%d keystrokes, %d words offered, %d spoken, "
                    + "%d speakable passages, 0 late voice lookups)",
                on.median, on.p95, on.slowest, on.count, words, utterances, speakable))
        guard median <= medianBudgetMicroseconds, tail <= tailBudgetMicroseconds,
            slowest <= slowestBudgetMicroseconds
        else {
            print(
                String(
                    format: "SPEECHBENCH FAIL: speech adds %.1fµs median (budget %.0f), "
                        + "%.1fµs at p95 (budget %.0f), %.1fµs at the slowest key (budget %.0f)",
                    median, medianBudgetMicroseconds, tail, tailBudgetMicroseconds,
                    slowest, slowestBudgetMicroseconds))
            exit(1)
        }
        print(
            "SPEECHBENCH clip: a word interrupted after \(interruptMs)ms still ran "
                + "\(clip.audibleMs)ms — not cut off")
        print(
            String(
                format: "SPEECHBENCH OK: speech adds %.1fµs median, %.1fµs at p95, "
                    + "%.1fµs at the slowest key",
                median, tail, slowest))
        exit(0)
    }

    /// Drives a full run through the real UI and reports what reached disk.
    ///
    /// The same discipline the web-view shell used, for the same reason: unit
    /// tests cover the engine exhaustively, and none of them can tell whether
    /// the app is wired to it.
    static func runSelfTest(practice: PracticeViewController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let store = try? ProfileFileStore.standard()
            let before: Int
            if let store, case .ok(let profile) = store.load() {
                before = profile.results.count
            } else {
                before = 0
            }

            // A missing resource bundle looks exactly like an empty corpus to
            // the picker, so assert the data is actually there rather than
            // letting the app quietly serve generated words forever.
            guard BundledCorpus.quotes.entries.count > 100,
                !BundledCorpus.code.entries.isEmpty,
                BundledCorpus.loadFailures.isEmpty
            else {
                // The reasons, not just the counts. A resource that failed to
                // decode produced the same empty list as one that was never
                // copied, so this used to say "not bundled" for a file that
                // was sitting right there with a syntax error in it.
                print(
                    "SELFTEST FAIL: corpus not usable — "
                        + "\(BundledCorpus.quotes.entries.count) quotes, "
                        + "\(BundledCorpus.code.entries.count) code entries"
                        + (BundledCorpus.loadFailures.isEmpty
                            ? "" : " — " + BundledCorpus.loadFailures.joined(separator: "; ")))
                exit(1)
            }
            // The case must sit the same distance from the caps on all four
            // sides. This was wrong until it was measured: the inter-key gap
            // was being applied after the last key too, so the right and
            // bottom margins were a gap wider than the left and top.
            let keyboardLayout = KeyboardView().layout(forWidth: 900, height: 220)
            let capsRect = keyboardLayout.keys.dropFirst().reduce(keyboardLayout.keys[0].rect) {
                $0.union($1.rect)
            }
            let margins = [
                capsRect.minX - keyboardLayout.caseRect.minX,
                keyboardLayout.caseRect.maxX - capsRect.maxX,
                capsRect.minY - keyboardLayout.caseRect.minY,
                keyboardLayout.caseRect.maxY - capsRect.maxY,
            ]
            guard let tightest = margins.min(), let widest = margins.max(),
                widest - tightest < 0.5, tightest > 0
            else {
                print("SELFTEST FAIL: keyboard margins are \(margins) — expected four equal")
                exit(1)
            }

            // No key on any keyboard shape may be narrower than a key can be.
            //
            // Row totals are `unitsPerRow` by construction — the last key
            // absorbs the slack — so checking the total proves nothing. What
            // can go wrong is a row whose fixed keys leave the absorber too
            // little, or nothing, or less than nothing. That is what a ragged
            // or overflowing keyboard actually is, and nothing else reports
            // it: the view just draws it.
            for shape in [SystemKeyboard.Shape.ansi, .iso, .jis] {
                for (index, row) in KeyboardGeometry.rows(for: shape).enumerated() {
                    guard let narrowest = row.map(\.width).min(), narrowest >= 0.75 else {
                        print(
                            "SELFTEST FAIL: \(shape) row \(index) has a "
                                + "\(row.map(\.width).min() ?? 0)u key — the row does not fit")
                        exit(1)
                    }
                }
            }

            // Legends must come from a keyboard, not from an input method.
            //
            // With a CJK input method active, the *current* layout is the
            // input method's own, and asking it what a key produces answers
            // with `……` above 6 and `¥` above 4 — what that method types, not
            // what is printed on the key. The ASCII-capable layout is the
            // keyboard underneath. This check is worth little on a machine
            // that only ever runs a US layout, where both answers agree; it
            // bites on one where an input method is active, which is where the
            // bug appeared.
            guard SystemKeyboard.legendSourceIsASCIICapable else {
                print(
                    "SELFTEST FAIL: keycap legends are being read from "
                        + "\(SystemKeyboard.layoutName), which is not an ASCII-capable layout")
                exit(1)
            }

            // The status bar of live numbers must actually reach the screen.
            //
            // It did not, for the whole life of this app: laid out correctly,
            // in the hierarchy, not hidden, with the right text and colour —
            // and painted over, because the typing view filled its dirty rect
            // rather than its bounds and AppKit does not clip a view's drawing
            // to its own bounds. Every property that can be asserted from the
            // view tree was true while the pixels were blank, so the only
            // check that can catch it is a look at the pixels.
            //
            // The search walks the whole tree rather than one fixed level of
            // stack views. It used to assume the label was a direct child of a
            // stack that was a direct child of the root, which stopped being
            // true the moment the numbers moved into a status bar and gained a
            // nesting level — and the failure would have been this check
            // quietly not finding its subject.
            @MainActor func textFields(in view: NSView) -> [NSTextField] {
                view.subviews.flatMap { child -> [NSTextField] in
                    (child as? NSTextField).map { [$0] } ?? textFields(in: child)
                }
            }
            let allLabels = textFields(in: practice.view)
            guard let wpmLabel = allLabels.first(where: { $0.stringValue.hasSuffix("wpm") }) else {
                print("SELFTEST FAIL: no wpm label in the status bar")
                exit(1)
            }
            let root = practice.view
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                print("SELFTEST FAIL: could not render the practice view")
                exit(1)
            }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let labelRect = wpmLabel.convert(wpmLabel.bounds, to: root)
            let scale = CGFloat(bitmap.pixelsWide) / max(root.bounds.width, 1)
            // Raw bytes rather than `colorAt(x:y:)`, which raises on bitmap
            // formats it does not recognise — including the one AppKit hands
            // back for a cached display.
            guard let bytes = bitmap.bitmapData, bitmap.samplesPerPixel >= 3 else {
                print("SELFTEST FAIL: rendered bitmap has no readable pixels")
                exit(1)
            }
            let rowBytes = bitmap.bytesPerRow
            let step = bitmap.samplesPerPixel
            // The bitmap counts rows from the top; the view does not.
            let top = Int((root.bounds.height - labelRect.maxY) * scale)
            let background = Theme.background.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1
            let firstRow = max(0, top)
            let lastRow = min(bitmap.pixelsHigh, top + Int(labelRect.height * scale))
            let firstColumn = max(0, Int(labelRect.minX * scale))
            let lastColumn = min(bitmap.pixelsWide, Int(labelRect.maxX * scale))
            let rows: Range<Int> = firstRow..<max(firstRow, lastRow)
            let columns: Range<Int> = firstColumn..<max(firstColumn, lastColumn)
            var inked = 0
            for y in rows {
                for x in columns {
                    let offset = y * rowBytes + x * step
                    let brightness =
                        (CGFloat(bytes[offset]) + CGFloat(bytes[offset + 1])
                            + CGFloat(bytes[offset + 2])) / (3 * 255)
                    if abs(brightness - background) > 0.15 { inked += 1 }
                }
            }
            guard inked > 20 else {
                print(
                    "SELFTEST FAIL: the header reads \"\(wpmLabel.stringValue)\" but only "
                        + "\(inked) of its pixels differ from the background — it is covered")
                exit(1)
            }

            // The Settings window builds, every pane of it.
            //
            // Nothing else here touches it: the practice screen is what
            // `--selftest` drives, and a pane that traps while being laid out
            // would ship green and only be found by opening Settings. The voice
            // picker is the reason this was added — it builds a 230-item menu
            // from whatever voices the machine has, which is the most
            // machine-dependent thing in this app.
            let settings = SettingsWindowController()
            guard settings.paneCount == expectedSettingsPanes else {
                print(
                    "SELFTEST FAIL: Settings built \(settings.paneCount) panes, expected "
                        + "\(expectedSettingsPanes)")
                exit(1)
            }

            // The Statistics window too, for the same reason — it is built
            // lazily when somebody clicks, so a toolbar or a moved control that
            // traps would ship green and be found by a user.
            let statsController = StatsViewController()
            statsController.history = { [] }
            statsController.refresh()
            let statsToolbar = statsController.makeToolbar()
            guard
                statsToolbar.delegate != nil,
                statsController.toolbarDefaultItemIdentifiers(statsToolbar)
                    .contains(StatsViewController.groupingItem),
                statsController.toolbar(
                    statsToolbar, itemForItemIdentifier: StatsViewController.groupingItem,
                    willBeInsertedIntoToolbar: true)?.view != nil
            else {
                print("SELFTEST FAIL: the Statistics toolbar has no grouping control")
                exit(1)
            }

            // The practice grid, both ways round. `refresh` above ran on an
            // empty history, which is the state that hides it.
            guard statsController.calendarState == (hidden: true, cells: 0) else {
                print(
                    "SELFTEST FAIL: an empty history should hide the practice grid, got "
                        + "\(statsController.calendarState)")
                exit(1)
            }
            // With runs it has to be shown *and* filled. Checking only that it
            // is visible would pass against a controller that stopped calling
            // `show(_:)` — a grid drawing nothing, raising nothing.
            statsController.history = { selftestHistory() }
            statsController.refresh()
            let filled = statsController.calendarState
            guard filled.hidden == false, filled.cells == PracticeCalendarView.windowDays else {
                print(
                    "SELFTEST FAIL: a history with runs should show a "
                        + "\(PracticeCalendarView.windowDays)-cell practice grid, got \(filled)")
                exit(1)
            }
            // And that it draws. At the probe's 460pt width the grid is 150
            // cells of 12pt, a little over 21,000 pixels before the legend and
            // before any Retina scaling. A floor of 15,000 catches a blank or
            // half-laid-out grid on a 1x display without pinning geometry that
            // is meant to change.
            let ink = statsController.calendarInk()
            guard ink.ink > 15_000 else {
                print("SELFTEST FAIL: the practice grid drew \(ink.ink) pixels — it is blank")
                exit(1)
            }
            // The run typed above lands on today, so exactly one cell is
            // tinted. If flattening every intensity changes nothing, the tint
            // never reached the screen and the grid is sixty identical squares.
            guard ink.tinted > 0 else {
                print("SELFTEST FAIL: the practice grid renders identically with no intensity")
                exit(1)
            }
            // And that it knows what it is counting. Both metrics draw the
            // same shape, so a grid fed characters while labelled sessions is
            // wrong only in its tooltip -- invisible to every pixel check
            // above, and the sort of thing a metric switch breaks silently.
            // The keystroke counter, end to end: count, reach disk, come back.
            // Nothing else covers the write path, and a counter that silently
            // fails to persist looks exactly like a user who did not type.
            let countDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TypeReviewCount-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: countDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: countDirectory) }

            // A clock the check owns, so the day boundary is a fact rather
            // than whatever time the check happens to run at.
            var clock = Date(timeIntervalSince1970: 1_773_500_000)
            let counter = KeystrokeCounter(directory: countDirectory, now: { clock })
            for _ in 0..<7 { counter.record() }
            guard counter.snapshot().total == 7 else {
                print("SELFTEST FAIL: counted 7 keys, snapshot says \(counter.snapshot().total)")
                exit(1)
            }
            // Across midnight the count must split between two days rather
            // than following the clock into one bucket or being lost.
            clock = clock.addingTimeInterval(36 * 60 * 60)
            counter.record()
            let split = counter.snapshot()
            guard split.days.count == 2, split.total == 8 else {
                print(
                    "SELFTEST FAIL: a day boundary should split the count, got "
                        + "\(split.days.count) day(s) totalling \(split.total)")
                exit(1)
            }
            counter.flush()
            let reloaded = KeystrokeCounter(directory: countDirectory, now: { clock })
            guard reloaded.snapshot() == split else {
                print("SELFTEST FAIL: the keystroke counts did not survive a save and load")
                exit(1)
            }
            reloaded.erase()
            guard reloaded.isEmpty,
                !FileManager.default.fileExists(
                    atPath: countDirectory.appendingPathComponent("keystrokes.json").path)
            else {
                print("SELFTEST FAIL: erasing the keystroke counts left something behind")
                exit(1)
            }

            // The link from the preference to the tap. Pinned through the
            // volatile domain and restored after, so a check never writes a
            // real setting, and the sound is pinned *off* so nothing here can
            // put a permission prompt on screen.
            if let delegate = NSApp.delegate as? AppDelegate {
                let soundBefore = UserDefaults.standard.volatileDomain(
                    forName: UserDefaults.argumentDomain)
                for wantsCounting in [true, false] {
                    var arguments = soundBefore
                    arguments[AppPreferences.globalSound.key] = false
                    arguments[AppPreferences.countKeystrokes.key] = wantsCounting
                    UserDefaults.standard.setVolatileDomain(
                        arguments, forName: UserDefaults.argumentDomain)
                    delegate.applySoundPreferences()
                    let installed = delegate.globalSound.onKeyPressed != nil
                    guard installed == wantsCounting else {
                        print(
                            "SELFTEST FAIL: with counting=\(wantsCounting) the key hook is "
                                + "\(installed ? "installed" : "absent")")
                        exit(1)
                    }
                }
                // That the error hook is installed at all, with the global
                // sound pinned off like everything else here.
                //
                // This does **not** prove the thing worth proving, and saying
                // so is the point. What matters is that the hook survives
                // `coveredElsewhere`, and reaching that state needs the
                // monitor actually listening, which needs Input Monitoring.
                // An earlier version of this check set the preference to true
                // to get there. It bought nothing and cost two things: on a
                // machine without the permission the monitor never listens, so
                // `coveredElsewhere` stays false and the assertion passes
                // without visiting the branch it named — and on a machine
                // without it *yet*, asking put a permission prompt on screen
                // from a check whose whole contract is that it does not.
                //
                // So this asserts what is reachable, and the scope question is
                // held by the comment beside the wiring in
                // `applySoundPreferences` instead. A test that cannot run is
                // better absent than faked.
                var mistypeArguments = soundBefore
                mistypeArguments[AppPreferences.globalSound.key] = false
                mistypeArguments[AppPreferences.mistypeSound.key] = true
                UserDefaults.standard.setVolatileDomain(
                    mistypeArguments, forName: UserDefaults.argumentDomain)
                delegate.applySoundPreferences()
                guard practice.onMistype != nil else {
                    print("SELFTEST FAIL: the mistype hook was not installed")
                    exit(1)
                }
                mistypeArguments[AppPreferences.mistypeSound.key] = false
                UserDefaults.standard.setVolatileDomain(
                    mistypeArguments, forName: UserDefaults.argumentDomain)
                delegate.applySoundPreferences()
                // The hook stays; the controller reads the preference. Checked
                // because the alternative design — unwiring it here — is the
                // one somebody will reach for later, and it would reintroduce
                // exactly the coupling this feature exists to avoid.
                guard practice.onMistype != nil else {
                    print("SELFTEST FAIL: the mistype hook was torn down by a preference")
                    exit(1)
                }
                UserDefaults.standard.setVolatileDomain(
                    soundBefore, forName: UserDefaults.argumentDomain)
                delegate.applySoundPreferences()
            }

            // Pinned rather than assumed. This reads a real preference, so
            // asserting the *default* made the check pass or fail on whether
            // whoever ran it had touched the control -- a test that inherits
            // the machine's state, which is the same fault the calendar's own
            // tests avoid by pinning their timezone.
            let metricBefore = UserDefaults.standard.volatileDomain(
                forName: UserDefaults.argumentDomain)
            for (wanted, expected) in [
                (AppPreferences.StatsMetric.characters, "characters typed"),
                (.sessions, "sessions"),
                // Keystrokes with the counter off must fall back to characters
                // rather than drawing an empty grid under a heading claiming
                // to show every key pressed.
                (.keystrokes, "characters typed"),
            ] {
                var arguments = metricBefore
                arguments[AppPreferences.statsMetric.key] = wanted.rawValue
                UserDefaults.standard.setVolatileDomain(
                    arguments, forName: UserDefaults.argumentDomain)
                statsController.refresh()
                let summary = statsController.calendarSummary
                guard summary.hasSuffix(expected) else {
                    print(
                        "SELFTEST FAIL: with metric=\(wanted.rawValue) the grid describes "
                            + "itself as \"\(summary)\"")
                    exit(1)
                }
            }
            UserDefaults.standard.setVolatileDomain(
                metricBefore, forName: UserDefaults.argumentDomain)

            // And the data that menu is built from. An empty group would draw a
            // language header with nothing under it; an identifier that does
            // not resolve is a row that silently selects nothing.
            let voiceGroups = SpeechVoices.grouped()
            guard !voiceGroups.isEmpty, voiceGroups.allSatisfy({ !$0.voices.isEmpty }) else {
                print("SELFTEST FAIL: \(voiceGroups.count) voice groups, some empty")
                exit(1)
            }
            // English only. The picker offers a voice to choose deliberately,
            // and 180 voices across 49 languages is a list nobody chooses from.
            let foreign = voiceGroups.flatMap(\.voices)
                .filter { AVSpeechSynthesisVoice(identifier: $0.identifier)
                    .map { !($0.language == "en" || $0.language.hasPrefix("en-")) } ?? false }
            guard foreign.isEmpty else {
                print("SELFTEST FAIL: \(foreign.count) non-English voices in the picker")
                exit(1)
            }
            let unresolvable = voiceGroups.flatMap(\.voices)
                .filter { AVSpeechSynthesisVoice(identifier: $0.identifier) == nil }
            guard unresolvable.isEmpty else {
                print(
                    "SELFTEST FAIL: \(unresolvable.count) voices do not resolve by identifier, "
                        + "e.g. \(unresolvable[0].name)")
                exit(1)
            }

            // The library round-trip, through the real file store: add,
            // reload from disk, confirm the corpus serves it, delete. The unit
            // tests cover the parser and the picker; only this can tell
            // whether the app is wired to them.
            let library = practice.library
            let libraryBefore = library.passages.count
            do {
                try library.add(title: "selftest", text: "the quick brown fox jumps over it")
            } catch {
                print("SELFTEST FAIL: library add: \(error)")
                exit(1)
            }
            let reread = LibraryStore(directory: library.directory)
            guard reread.passages.count == libraryBefore + 1,
                let added = reread.passages.last,
                added.title == "selftest"
            else {
                print("SELFTEST FAIL: library did not survive a reload from \(library.fileURL.path)")
                exit(1)
            }
            var libraryRNG = Mulberry32(seed: 1)
            let served = try? CorpusAdapter(channel: .user, library: reread.passages)
                .adaptiveSource(
                    filter: Filter(allowed: ["e", "t", "a"], focus: nil), wordCount: 7,
                    rng: &libraryRNG)
            guard served?.text == added.text else {
                print("SELFTEST FAIL: Library channel served \(served?.text ?? "nothing")")
                exit(1)
            }
            do { try library.delete(id: added.id) } catch {
                print("SELFTEST FAIL: library delete: \(error)")
                exit(1)
            }

            guard let view = practice.view.subviews.compactMap({ $0 as? TypingView }).first else {
                print("SELFTEST FAIL: no typing surface")
                exit(1)
            }
            // A human cadence. Without it the run lands at hundreds of
            // thousands of wpm, which the profile validator rightly refuses —
            // the metric bounds exist to catch exactly that shape of nonsense.
            var syntheticClock: Double = 0
            practice.clock = {
                syntheticClock += 120
                return syntheticClock
            }
            // Through the same entry point AppKit uses for committed text, so
            // the input path is the one being tested rather than bypassed.
            let expected = practice.currentPassage
            guard !expected.isEmpty else {
                print("SELFTEST FAIL: no passage")
                exit(1)
            }
            // Newlines are not typed. `TextInput` steps over them by itself —
            // Enter is reserved for advancing — so sending one is scored
            // against the character *after* it, and every keystroke from there
            // on lands one position out.
            //
            // Quotes have no newlines, which is why this passed for as long as
            // it did. Code passages preserve their layout and are full of
            // them, so with the Code channel selected the self-test reported a
            // perfectly typed passage at 7% accuracy: a check failing on the
            // app being right.
            let passageBefore = practice.currentPassageId
            let typeable = Array(expected.utf16).filter { $0 != 0x0A }
            for unit in typeable {
                view.insertText(String(utf16CodeUnits: [unit], count: 1), replacementRange: NSRange())
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let store else {
                    print("SELFTEST FAIL: no store")
                    exit(1)
                }
                let reloaded = store.load()
                guard case .ok(let profile) = reloaded else {
                    print(
                        "SELFTEST FAIL: profile reloaded as \(reloaded.statusName) from \(store.fileURL.path)"
                            + " — in-memory runs: \(practice.runCount)")
                    exit(1)
                }
                guard profile.results.count == before + 1 else {
                    print(
                        "SELFTEST FAIL: expected \(before + 1) runs on disk, found \(profile.results.count)")
                    exit(1)
                }
                let metrics = profile.results.last!.metrics
                // The check types the passage exactly, so anything but a
                // perfect run means characters were dropped, reordered or
                // scored against text that changed underneath — and none of
                // that showed up before, because the only assertion was that
                // *a* run reached disk. One run at 1% accuracy was reported as
                // OK before this line existed.
                // Against the typeable count, not the passage's. A skipped
                // newline stays `.untyped` and is counted as neither correct
                // nor wrong, so a passage with layout can never reach its own
                // length here.
                guard metrics.accuracy > 99.9, metrics.correctChars == typeable.count else {
                    let recorded = profile.results.last!
                    print(
                        "SELFTEST FAIL: typed \(typeable.count) characters exactly but the "
                            + "run recorded \(Int(metrics.accuracy))% accuracy "
                            + "(\(metrics.correctChars) correct, \(metrics.incorrectChars) wrong)")
                    print("  passage read:     \(passageBefore)")
                    print("  passage recorded: \(recorded.passageId)")
                    print("  expected head:    \(String(expected.prefix(50)).debugDescription)")
                    print("  recorded head:    \(String(recorded.text.prefix(50)).debugDescription)")
                    exit(1)
                }
                // The status item's mark, before the summary. A template
                // image is only ever read for its alpha, so one that draws
                // nothing is not a faint icon — it is an empty menu-bar slot,
                // and every build in front of it stays green. The geometry is
                // shared with the Dock icon, so a change made for one can
                // empty the other with nothing on screen to say so.
                let mark = Mark.menuBarImage(pointSize: Theme.SymbolSize.menuBarMark)
                let side = Int(Theme.SymbolSize.menuBarMark * 2)
                let markRep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                if let markRep {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: markRep)
                    mark.draw(in: NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
                    NSGraphicsContext.restoreGraphicsState()
                }
                var inked = 0
                if let markRep {
                    for y in 0..<markRep.pixelsHigh {
                        for x in 0..<markRep.pixelsWide
                        where (markRep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.08 {
                            inked += 1
                        }
                    }
                }
                // A fifth of the square is the floor. The mark is an outlined
                // window with keys in it and covers about half; anything near
                // zero is an empty slot, and a solid block would mean the
                // geometry collapsed rather than drew.
                let coverage = Double(inked) / Double(side * side)
                guard mark.isTemplate, coverage > 0.20, coverage < 0.85 else {
                    print(
                        "SELFTEST FAIL: menu-bar mark covers "
                            + String(format: "%.0f%%", coverage * 100)
                            + " of its square (template: \(mark.isTemplate))")
                    exit(1)
                }
                print(
                    "SELFTEST OK: typed \(typeable.count) chars — "
                        + "\(Int(metrics.netWpm)) wpm, \(Int(metrics.accuracy))% accuracy, "
                        + "\(profile.results.count) run(s) on disk")
                exit(0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            print("SELFTEST FAIL: timed out")
            exit(2)
        }
    }
}

/// One finished run, for the checks that need a non-empty history.
///
/// Driven through the engine rather than fabricated. `RunResult` has no public
/// initialiser, and adding one so a check could build a fake would widen the
/// engine's surface for the benefit of the check alone. Typing a passage is
/// also the more honest fixture — it is the shape a real history has, produced
/// the way a real history is produced.
@MainActor
private func selftestHistory() -> [RunResult] {
    let text = "the quick brown fox"
    guard let session = try? Session(profile: Profile()),
        (try? session.startWithText(text)) != nil
    else { return [] }
    var clock: Double = 0
    for character in text {
        clock += 150
        _ = try? session.input(String(character), timeStamp: clock)
    }
    return session.profile.results
}
