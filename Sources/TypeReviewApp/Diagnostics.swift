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
    static let flags = ["--soundcheck", "--selftest", "--speechbench", "--screenshots"]

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

    /// Practice, Appearance, Sound, Everywhere, General, Data, About.
    ///
    /// Named once rather than written into both the check and its message,
    /// which is how the first version of this reported "built 6 panes, expected
    /// 6" — a failure message that argued with itself.
    private static let expectedSettingsPanes = 7

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

    /// Every key on every shape has a finger, or is listed as deliberately
    /// without one — and no key is on both lists.
    ///
    /// Three directions, because all three failures are invisible on screen. A
    /// key missing from the chart draws no number, which looks exactly like a
    /// key whose number was never wanted — that is how the ISO § and the four
    /// JIS keys went unmarked while the ANSI board looked complete. A code in
    /// the chart that no keyboard has never matches anything, so it reads as
    /// coverage while covering nothing. And a key in *both* lists is a
    /// contradiction that resolves itself silently, whichever way the lookup
    /// happens to be written.
    @MainActor private static func checkFingerChart() {
        var placed: Set<UInt16> = []
        for shape in SystemKeyboard.Shape.allCases {
            for row in KeyboardGeometry.rows(for: shape) {
                for key in row { placed.insert(key.key.code) }
            }
        }
        func list(_ codes: Set<UInt16>) -> String {
            codes.sorted().map(String.init).joined(separator: ", ")
        }
        let unexplained = placed.subtracting(FingerTips.assigned)
            .subtracting(FingerTips.unassigned)
        guard unexplained.isEmpty else {
            print(
                "SELFTEST FAIL: \(unexplained.count) key(s) have no finger and are not "
                    + "listed as deliberately without one: \(list(unexplained))")
            exit(1)
        }
        let phantom = FingerTips.assigned.union(FingerTips.unassigned).subtracting(placed)
        guard phantom.isEmpty else {
            print(
                "SELFTEST FAIL: FingerTips names \(phantom.count) key(s) no keyboard has: "
                    + list(phantom))
            exit(1)
        }
        let both = FingerTips.assigned.intersection(FingerTips.unassigned)
        guard both.isEmpty else {
            print(
                "SELFTEST FAIL: \(both.count) key(s) are both given a finger and listed as "
                    + "deliberately without one: \(list(both))")
            exit(1)
        }
    }

    /// Two homing ridges on every shape, and the F cap actually draws one.
    ///
    /// Counting `isHoming` proves only that the geometry knows about them:
    /// delete the line that draws the ridge and the count is still two. So the
    /// board is rendered and the foot of the F cap compared with the foot of
    /// the G cap beside it — same size, same colour, same legend weight, no
    /// ridge. The control is what makes the measurement mean anything: ink in
    /// both bands would be the cap's own edge, not a ridge.
    @MainActor private static func checkHomingRidges() {
        for shape in SystemKeyboard.Shape.allCases {
            let ridges = KeyboardGeometry.rows(for: shape)
                .flatMap { $0 }.filter(\.key.isHoming).count
            guard ridges == 2 else {
                print("SELFTEST FAIL: the \(shape) keyboard has \(ridges) homing ridges, not two")
                exit(1)
            }
        }

        let board = KeyboardView()
        // Pinned to the light appearance so "darker than the cap" means one
        // thing. Unparented, the view would otherwise inherit whatever the
        // machine running the check happens to be set to.
        board.appearance = NSAppearance(named: .aqua)
        let width: CGFloat = 900
        board.frame = NSRect(
            x: 0, y: 0, width: width, height: board.naturalHeight(forWidth: width))
        guard let rep = board.bitmapImageRepForCachingDisplay(in: board.bounds) else {
            print("SELFTEST FAIL: the keyboard could not be rendered for the ridge check")
            exit(1)
        }
        board.cacheDisplay(in: board.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / board.bounds.width
        let layout = board.layout(forWidth: width, height: board.bounds.height)

        /// The foot of a cap, clear of its bottom edge and of the legend above.
        func foot(of rect: NSRect) -> NSRect {
            NSRect(
                x: rect.midX - rect.width * 0.2, y: rect.maxY - layout.unit * 0.28,
                width: rect.width * 0.4, height: layout.unit * 0.18)
        }
        func ink(in rect: NSRect) -> Int {
            var count = 0
            for y in stride(from: rect.minY * scale, to: rect.maxY * scale, by: 1) {
                for x in stride(from: rect.minX * scale, to: rect.maxX * scale, by: 1) {
                    guard let colour = rep.colorAt(x: Int(x), y: Int(y))?
                        .usingColorSpace(.sRGB)
                    else { continue }
                    let luminance =
                        0.2126 * colour.redComponent + 0.7152 * colour.greenComponent
                        + 0.0722 * colour.blueComponent
                    if luminance < 0.92 { count += 1 }
                }
            }
            return count
        }
        // Asked of the geometry rather than named here: the check is that
        // whatever carries a ridge draws one, not that a particular letter does.
        // The control is its neighbour along the same row — the nearest cap
        // that is a letter and has no ridge.
        guard let ridged = layout.keys.first(where: { $0.key.isHoming }),
            let plain = layout.keys
                .filter({
                    !$0.key.isHoming && $0.key.role == .letter
                        && abs($0.rect.minY - ridged.rect.minY) < 1
                })
                .min(by: {
                    abs($0.rect.midX - ridged.rect.midX) < abs($1.rect.midX - ridged.rect.midX)
                })
        else {
            print("SELFTEST FAIL: no key with a homing ridge, or none beside it to compare with")
            exit(1)
        }
        let drawn = ink(in: foot(of: ridged.rect))
        let control = ink(in: foot(of: plain.rect))
        guard drawn > 8, control == 0 else {
            print(
                "SELFTEST FAIL: the ridged cap drew \(drawn) dark pixels at its foot and the cap "
                    + "beside it \(control) — expected ink on the first and none on the second")
            exit(1)
        }
    }

    /// A capital calls for the ⇧ on the *other* hand, and the character
    /// reaches the view with its case intact.
    ///
    /// Two properties, and they need testing two different ways. The rule about
    /// hands is tested by construction, on both hands: a passage brings
    /// whichever capital it happens to bring, and the first version of this
    /// check — one capital, from whatever passage came up — passed an
    /// implementation that always answered the left ⇧ whenever that capital
    /// happened to be a right-hand letter. The wiring is tested by typing into
    /// the real controller, because the bug it guards against is a caller
    /// lowercasing the character on the way in, which is where it was until
    /// this branch.
    ///
    /// Play's caller is not covered, and cannot be: its words are lower case,
    /// so nothing it sends could tell a preserved capital from a flattened one.
    /// The rule half below is what protects the view itself either way.
    @MainActor private static func checkShiftIsMarked(_ practice: PracticeViewController) {
        let board = KeyboardView()
        board.showsFingerTips = true
        let layout = board.layout(forWidth: 900, height: 220)
        let printed = board.printedLegends(layout)
        func modifiers() -> Set<UInt16> {
            board.nextKeystroke(layout, printed: printed)?.modifiers ?? []
        }

        for hand in [FingerTips.Hand.left, .right] {
            // A cap on this hand that prints a second glyph under ⇧.
            let candidate = layout.keys.first { placed in
                guard FingerTips.hand(of: placed.key.code) == hand,
                    let legends = printed[placed.key.code], let shifted = legends.shifted
                else { return false }
                return shifted != legends.plain
            }
            guard let candidate, let wanted = printed[candidate.key.code]?.shifted else {
                print("SELFTEST FAIL: no \(hand)-hand key prints a shifted character to test ⇧ with")
                exit(1)
            }
            board.showWithoutHeat(plan: nil, expected: wanted)
            let other: FingerTips.Hand = hand == .left ? .right : .left
            guard modifiers() == [FingerTips.shift(for: other)] else {
                print(
                    "SELFTEST FAIL: \(wanted) is typed by the \(hand) hand, so it needs the "
                        + "\(other) hand's ⇧ (key \(FingerTips.shift(for: other))) — the aid "
                        + "marked \(modifiers().sorted())")
                exit(1)
            }
            // And the plain glyph on that same cap needs nothing held, which is
            // the case distinction the whole thing rests on.
            if let plain = printed[candidate.key.code]?.plain {
                board.showWithoutHeat(plan: nil, expected: plain)
                guard modifiers().isEmpty else {
                    print(
                        "SELFTEST FAIL: \(plain) needs nothing held and the aid marked "
                            + "\(modifiers().sorted())")
                    exit(1)
                }
            }
        }

        // The wiring: a capital typed into the real controller still arrives as
        // a capital.
        practice.keyboard = board
        guard let surface = practice.view.subviews.compactMap({ $0 as? TypingView }).first else {
            print("SELFTEST FAIL: no typing surface for the shift check")
            exit(1)
        }
        var units: [UInt16] = []
        var capital: Int?
        for _ in 0..<50 {
            practice.startFreshRun()
            units = Array(practice.currentPassage.utf16).filter { $0 != 0x0A }
            capital = units.indices.first { $0 > 0 && (0x41...0x5A).contains(units[$0]) }
            if capital != nil { break }
        }
        guard let capital else {
            print("SELFTEST FAIL: fifty passages in a row had no capital to test ⇧ with")
            exit(1)
        }
        // Typed correctly, every character of it. Typing a deliberately wrong
        // one to advance would stall against stop-on-error and fail this check
        // for a reason that has nothing to do with ⇧.
        for unit in units.prefix(capital) {
            surface.insertText(
                String(utf16CodeUnits: [unit], count: 1), replacementRange: NSRange())
        }
        let wanted = String(utf16CodeUnits: [units[capital]], count: 1)
        let held = board.nextKeystroke(
            board.layout(forWidth: 900, height: 220),
            printed: board.printedLegends(board.layout(forWidth: 900, height: 220))
        )?.modifiers ?? []
        guard held.count == 1, let shift = held.first, FingerTips.digit(of: shift) == 5 else {
            print(
                "SELFTEST FAIL: the next character is \(wanted) and the keys held with it came "
                    + "out as \(held.sorted()) — expected one ⇧, which is a little finger's")
            exit(1)
        }

        // Left as it was found: the run below types a whole passage and counts
        // the characters, which a half-typed one would throw out.
        practice.keyboard = nil
        practice.startFreshRun()
    }

    /// A check that failed, and what it has to say.
    struct CheckFailure: Error {
        let message: String
    }

    /// Drives a full run through the real UI and reports what reached disk.
    ///
    /// The same discipline the web-view shell used, for the same reason: unit
    /// tests cover the engine exhaustively, and none of them can tell whether
    /// the app is wired to it.
    ///
    /// `playCheck` runs Play once Practice has recorded its run — see
    /// `checkPlay` — and answers nil if there is no Play screen to check.
    static func runSelfTest(
        practice: PracticeViewController,
        playCheck: @escaping () -> Result<String, CheckFailure>?
    ) {
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
            // Choosing the source already chosen must not restart the run.
            //
            // `practice.channel`'s setter calls `startFreshRun()` every time,
            // so the guard against an unchanged channel is the only thing
            // standing between a stray click on the ticked menu item and the
            // passage somebody was halfway through. It was fixed once in the
            // toolbar and left broken in the View menu, because the two lines
            // existed in three places; they are one function now, and this is
            // what keeps them that way.
            //
            // Checked after every call, not once after the last one. A fresh
            // run can draw the passage it just had — about one time in fifteen
            // — so the id is not a perfect witness to a restart. Comparing
            // only at the end made the first two calls decorative and left the
            // odds of missing a broken guard at that same one in fifteen;
            // comparing each time puts them at one in fifteen cubed.
            //
            // It is still an id comparison, so a restart that happens to
            // redraw the same passage is invisible to it. That is the residual
            // hole, and it is small rather than absent.
            if let delegate = NSApp.delegate as? AppDelegate {
                let channelBefore = practice.channel
                let passageBefore = practice.currentPassageId
                for round in 1...3 {
                    delegate.setChannel(channelBefore)
                    guard practice.currentPassageId == passageBefore,
                        practice.channel == channelBefore
                    else {
                        print(
                            "SELFTEST FAIL: re-choosing the current source restarted the run "
                                + "on round \(round) — passage went from \(passageBefore) "
                                + "to \(practice.currentPassageId)")
                        exit(1)
                    }
                }
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
            for shape in SystemKeyboard.Shape.allCases {
                for (index, row) in KeyboardGeometry.rows(for: shape).enumerated() {
                    guard let narrowest = row.map(\.width).min(), narrowest >= 0.75 else {
                        print(
                            "SELFTEST FAIL: \(shape) row \(index) has a "
                                + "\(row.map(\.width).min() ?? 0)u key — the row does not fit")
                        exit(1)
                    }
                }
            }

            checkFingerChart()
            checkHomingRidges()
            checkShiftIsMarked(practice)

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

            // A mistyped space has to show.
            //
            // Glyphs are coloured by status, and a space has no ink to colour.
            // For as long as this app existed, a wrong key where a space
            // belonged was scored as a mistake and drawn as nothing: the cursor
            // moved on over a blank cell, and the mistake looked accepted. The
            // same passage is drawn twice, identical but for that one space,
            // correct in one and mistyped in the other, with the caret in the
            // same place, and the mistyped drawing must differ. A difference
            // rather than a colour, because the byte order of a cached bitmap
            // is not worth guessing and nothing else in the two differs: the
            // glyphs match, and so does the caret. Invisibles are off, because
            // that is the default and the case that was blank.
            do {
                let spaceView = TypingView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
                spaceView.showsWhitespace = false
                @MainActor func render(_ statuses: [CharStatus], passage: String = "ab cd") -> (bytes: [UInt8], rep: NSBitmapImageRep)? {
                    spaceView.setPassage(passage, statuses: statuses, cursor: 3)
                    guard let rep = spaceView.bitmapImageRepForCachingDisplay(in: spaceView.bounds)
                    else { return nil }
                    spaceView.cacheDisplay(in: spaceView.bounds, to: rep)
                    guard let data = rep.bitmapData else { return nil }
                    return (Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh)), rep)
                }
                // The control: the same statuses and the same caret over a passage
                // of spaces, so the only ink it has is the caret's.
                guard let clean = render([.correct, .correct, .correct, .untyped, .untyped]),
                    let wrong = render([.correct, .correct, .incorrect, .untyped, .untyped]),
                    let caretOnly = render([.correct, .correct, .correct, .untyped, .untyped], passage: "     "),
                    clean.bytes.count == wrong.bytes.count, clean.bytes.count == caretOnly.bytes.count
                else {
                    print("SELFTEST FAIL: could not render the typing view to check a mistyped space")
                    exit(1)
                }
                let step = clean.rep.samplesPerPixel
                let row = clean.rep.bytesPerRow
                var inked = 0
                var differing = 0
                for y in 0..<clean.rep.pixelsHigh {
                    for x in 0..<clean.rep.pixelsWide {
                        let offset = y * row + x * step
                        var fromCaretOnly = 0
                        var fromClean = 0
                        for channel in 0..<step {
                            fromCaretOnly = max(fromCaretOnly, abs(Int(clean.bytes[offset + channel]) - Int(caretOnly.bytes[offset + channel])))
                            fromClean = max(fromClean, abs(Int(clean.bytes[offset + channel]) - Int(wrong.bytes[offset + channel])))
                        }
                        if fromCaretOnly > 40 { inked += 1 }
                        if fromClean > 12 { differing += 1 }
                    }
                }
                // Without letters the comparison below proves nothing, so that is
                // a failure of its own rather than a pass nobody could see. Ink is
                // counted against the caret-only control rather than the
                // background, because measured from the background the caret's
                // own pixels are ink, and they are there with no letters at all.
                guard inked > 50 else {
                    print("SELFTEST FAIL: the typing view drew no text offscreen, so a mistyped space cannot be checked")
                    exit(1)
                }
                guard differing > 50 else {
                    print(
                        "SELFTEST FAIL: a mistyped space changed \(differing) pixels — it is drawn "
                            + "as a blank cell, so the mistake looks accepted")
                    exit(1)
                }
            }

            // And it has to show where a line wraps.
            //
            // CoreText hangs a line's closing space past the frame's edge, and
            // the view clips at its own. Laid out as wide as the view, a line
            // that filled it exactly drew that space's cell wholly outside the
            // clip: measured, 0 of 13.6 points at an exact fit, half of it half
            // a column wider. So a passage with one space is drawn at every
            // quarter column from too narrow for its first word to wide enough
            // not to wrap, and at each width the mistyped cell must change about
            // as many pixels as it does at a width where it cannot be near an
            // edge. A sweep, because which width exposes it moves with the font.
            //
            // Four fifths, not all: anti-aliasing can cost each vertical edge of
            // the cell one column of pixels at a fractional offset, which is
            // under a sixth of a 13.6-point cell. A clip in quarter-column steps
            // costs at least a quarter, so it cannot hide inside that margin.
            do {
                let column = PracticeWindowMetrics.characterWidth
                let passage = "abcdefgh ijklmnop"
                let correct = [CharStatus](repeating: .untyped, count: passage.utf16.count)
                var mistyped = correct
                mistyped[8] = .incorrect
                let edgeView = TypingView(frame: NSRect(x: 0, y: 0, width: column * 40, height: 200))
                edgeView.showsWhitespace = false
                @MainActor func render(_ statuses: [CharStatus]) -> (bytes: [UInt8], step: Int)? {
                    edgeView.setPassage(passage, statuses: statuses, cursor: 0)
                    guard let rep = edgeView.bitmapImageRepForCachingDisplay(in: edgeView.bounds),
                        rep.samplesPerPixel >= 3
                    else { return nil }
                    edgeView.cacheDisplay(in: edgeView.bounds, to: rep)
                    guard let data = rep.bitmapData else { return nil }
                    return (Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh)), rep.bytesPerRow / rep.pixelsWide)
                }
                @MainActor func cellPixels(atColumns columns: CGFloat) -> Int? {
                    edgeView.setFrameSize(NSSize(width: column * columns, height: 200))
                    guard let a = render(correct), let b = render(mistyped), a.bytes.count == b.bytes.count
                    else { return nil }
                    var changed = 0
                    for pixel in stride(from: 0, to: a.bytes.count - a.step + 1, by: a.step) {
                        var largest = 0
                        for channel in 0..<min(a.step, 4) {
                            largest = max(largest, abs(Int(a.bytes[pixel + channel]) - Int(b.bytes[pixel + channel])))
                        }
                        if largest > 12 { changed += 1 }
                    }
                    return changed
                }
                guard let unwrapped = cellPixels(atColumns: 40), unwrapped > 50 else {
                    print("SELFTEST FAIL: a mistyped space in the middle of a line drew no cell, so the wrap-edge check cannot see")
                    exit(1)
                }
                var clipped: [String] = []
                for quarter in 24...80 {
                    let columns = CGFloat(quarter) / 4
                    guard let pixels = cellPixels(atColumns: columns) else {
                        print("SELFTEST FAIL: could not render the typing view \(columns) columns wide")
                        exit(1)
                    }
                    if pixels * 5 < unwrapped * 4 { clipped.append("\(columns) columns: \(pixels) of \(unwrapped)") }
                }
                guard clipped.isEmpty else {
                    print(
                        "SELFTEST FAIL: a space mistyped where a line wraps is cut off at the view's edge — "
                            + clipped.joined(separator: "; "))
                    exit(1)
                }
            }

            // Invisibles mark what the passage contains, and nothing else.
            //
            // A line this window wrapped used to end in an arrow every typist
            // reads as Return, at the end of nearly every line of a quote, none
            // of which contains a line break. A passage with no spaces, tabs or
            // line breaks has nothing to mark, so with invisibles on it must
            // draw exactly what it draws with them off, however many lines it
            // wraps onto. Letters only, so the wrap falls inside a word and
            // there is still no whitespace for a mark to belong to. The second
            // passage is the control: a real line break must still get its
            // mark, or this would pass for a build that draws no marks at all.
            do {
                let marksView = TypingView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
                var rowBytes = 0
                var rowsHigh = 0
                @MainActor func pixels(_ text: String, invisibles: Bool) -> [UInt8]? {
                    marksView.showsWhitespace = invisibles
                    marksView.setPassage(
                        text, statuses: Array(repeating: .untyped, count: text.utf16.count), cursor: 0)
                    guard let rep = marksView.bitmapImageRepForCachingDisplay(in: marksView.bounds)
                    else { return nil }
                    marksView.cacheDisplay(in: marksView.bounds, to: rep)
                    guard let data = rep.bitmapData else { return nil }
                    rowBytes = rep.bytesPerRow
                    rowsHigh = rep.pixelsHigh
                    return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
                }
                let unbroken = String(repeating: "abcdefghij", count: 30)
                let broken = "abc\ndef"
                guard let unbrokenOff = pixels(unbroken, invisibles: false),
                    let unbrokenOn = pixels(unbroken, invisibles: true),
                    let brokenOff = pixels(broken, invisibles: false),
                    let brokenOn = pixels(broken, invisibles: true)
                else {
                    print("SELFTEST FAIL: could not render the typing view to check its line-end marks")
                    exit(1)
                }
                guard brokenOff != brokenOn else {
                    print("SELFTEST FAIL: a real line break drew no mark with invisibles on, so the wrap check cannot see")
                    exit(1)
                }
                // And the unbroken passage has to have wrapped. If it did not,
                // there was no wrap for a mark to be drawn at, and the comparison
                // below is two identical pictures proving nothing: it passed just
                // as well for a view that drew nothing at all. Ink in two separate
                // bands of rows is at least two lines.
                //
                // Letters are found by difference from a control of as many spaces,
                // with the caret in the same place, so the caret cancels out.
                // Measured from the background instead, the untyped colour is too
                // faint to count, only the caret's band registered, and this failed
                // against a view that wraps perfectly well.
                guard let lettersGone = pixels(String(repeating: " ", count: unbroken.utf16.count), invisibles: false),
                    lettersGone.count == unbrokenOff.count
                else {
                    print("SELFTEST FAIL: could not render the typing view's control for the wrap check")
                    exit(1)
                }
                var bands = 0
                var inBand = false
                for y in 0..<rowsHigh {
                    let start = y * rowBytes
                    let inked = (start..<(start + rowBytes)).contains {
                        abs(Int(unbrokenOff[$0]) - Int(lettersGone[$0])) > 12
                    }
                    if inked && !inBand { bands += 1 }
                    inBand = inked
                }
                guard bands >= 2 else {
                    print(
                        "SELFTEST FAIL: the passage meant to wrap drew \(bands) line(s), so the check that a wrap "
                            + "gets no mark had nothing to look at")
                    exit(1)
                }
                guard unbrokenOff == unbrokenOn else {
                    print("SELFTEST FAIL: a passage with no whitespace or line breaks drew marks with invisibles on — a wrap is being marked as a line break")
                    exit(1)
                }
            }

            // The practice window takes Latin keyboards only, unless told not to.
            //
            // This checks that both settings reach the typing view's input
            // context. It cannot check what macOS then does with them: a check
            // runs as an accessory and never activates that context, so whether
            // the input source really switches, and switches back, is for a
            // person to confirm once.
            do {
                @MainActor func typingViews(in view: NSView) -> [TypingView] {
                    view.subviews.flatMap { child -> [TypingView] in
                        (child as? TypingView).map { [$0] } ?? typingViews(in: child)
                    }
                }
                guard let surface = typingViews(in: practice.view).first else {
                    print("SELFTEST FAIL: no typing view in the practice window")
                    exit(1)
                }
                // What launch left, before anything here applies the preference
                // itself. The loop below re-applies it, so on its own it would pass
                // for a build that restricts nothing until a setting changes.
                let atLaunch = surface.inputContext?.allowedInputSourceLocales ?? []
                let launchExpected = AppPreferences.latinInputOnly.value
                    ? [NSAllRomanInputSourcesLocaleIdentifier] : []
                guard atLaunch == launchExpected else {
                    print(
                        "SELFTEST FAIL: at launch the typing view allows \(atLaunch), but "
                            + "Latin keyboards only is \(AppPreferences.latinInputOnly.value ? "on" : "off")")
                    exit(1)
                }
                let latinBefore = UserDefaults.standard.volatileDomain(
                    forName: UserDefaults.argumentDomain)
                for restricted in [true, false] {
                    var arguments = latinBefore
                    arguments[AppPreferences.latinInputOnly.key] = restricted
                    UserDefaults.standard.setVolatileDomain(
                        arguments, forName: UserDefaults.argumentDomain)
                    practice.applyTypingPreferences()
                    let allowed = surface.inputContext?.allowedInputSourceLocales ?? []
                    let expected = restricted ? [NSAllRomanInputSourcesLocaleIdentifier] : []
                    guard allowed == expected else {
                        print(
                            "SELFTEST FAIL: with Latin keyboards only \(restricted ? "on" : "off"), "
                                + "the typing view allows \(allowed)")
                        exit(1)
                    }
                }
                UserDefaults.standard.setVolatileDomain(
                    latinBefore, forName: UserDefaults.argumentDomain)
                practice.applyTypingPreferences()
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

            // The window stays the width it was designed to be.
            //
            // Captions wrap now, so they can no longer widen it, but a control
            // can — the voice menu is as wide as the longest voice name the
            // machine has. A window that grows does not look broken, only
            // wider, on a screen most people open once. It has happened: a
            // hint added once measured 897 points against a design that had
            // never gone past 870, and the window grew by 37 of them with
            // nothing to say so.
            // Asked as well as needed. Checking the need alone passes a
            // window every pane asks 900 points for over content that needs
            // 546 — the ask is what the window is actually set to.
            let paneSizes = settings.paneSizes
            let overBudget = paneSizes.filter {
                max($0.asked.width, $0.needed.width) > SettingsWindowController.widthBudget
            }
            guard overBudget.isEmpty else {
                for pane in overBudget {
                    print(
                        "SELFTEST FAIL: the \(pane.title) pane asks for "
                            + "\(Int(pane.asked.width))pt and needs \(Int(pane.needed.width))pt, "
                            + "over the Settings window's "
                            + "\(Int(SettingsWindowController.widthBudget))pt budget")
                }
                exit(1)
            }

            // Every pane asks for one width, never less than it needs, and
            // exactly its height. The tab transition animates to what a pane
            // asks for and Auto Layout then enforces what it needs; where the
            // two differ, the window moves twice — see `resizePanes`.
            let sharedWidth = paneSizes.first?.asked.width ?? 0
            let misfits = paneSizes.filter {
                $0.asked.width != sharedWidth
                    || $0.asked.width < $0.needed.width - 0.5
                    || abs($0.asked.height - $0.needed.height) > 0.5
            }
            guard misfits.isEmpty else {
                for pane in misfits {
                    print(
                        "SELFTEST FAIL: the \(pane.title) pane asks for "
                            + "\(Int(pane.asked.width))×\(Int(pane.asked.height)) and needs "
                            + "\(Int(pane.needed.width))×\(Int(pane.needed.height)), and every "
                            + "pane should ask for \(Int(sharedWidth)) wide")
                }
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
            do {
                try reloaded.erase()
            } catch {
                print("SELFTEST FAIL: erasing the keystroke counts threw: \(error)")
                exit(1)
            }
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
                // Play, after Practice has recorded its run, so the check can
                // see that a whole game leaves that record alone.
                let played: String
                switch playCheck() {
                case .success(let summary)?:
                    played = summary
                case .failure(let failure)?:
                    print("SELFTEST FAIL: \(failure.message)")
                    exit(1)
                case nil:
                    print("SELFTEST FAIL: there is no Play screen to check")
                    exit(1)
                }
                // The whole profile, not its length: a game that rewrote a
                // setting, or a result in place, leaves the count alone.
                guard case .ok(let afterPlay) = store.load(), afterPlay == profile else {
                    print("SELFTEST FAIL: playing a game changed the profile on disk")
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
                        + "\(profile.results.count) run(s) on disk; play: \(played)")
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
