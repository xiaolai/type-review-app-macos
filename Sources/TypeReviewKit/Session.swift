import Foundation

/// Maximum runs kept in profile history. The cap bounds key-stats rebuild
/// time, save size and adaptive replay cost; older runs drop on completion
/// while `index` stays monotonic so identifiers are never reused.
public let maxHistory = 500

/// Upper-bound WPM used to size a time-mode passage.
private let timeModeMaxWpm: Double = 250
/// Safety factor covering variance and bursts.
private let timeModeBuffer: Double = 2
/// Hard cap so a five-minute test cannot generate a megabyte of text.
private let timeModeMaxWords: Double = 10_000

/// How many words a time-mode benchmark needs so the clock runs out before
/// the text does.
func timeModeWordBudget(_ durationSec: Double) -> Int {
    let needed = (durationSec * timeModeMaxWpm / 60).rounded(.up)
    return Int(min(timeModeMaxWords, needed * timeModeBuffer))
}

/// Digits in frequency-ish order — 0 is rare in prose, 1 and 2 common. Order
/// matters: the adaptive engine unlocks left to right.
public let digits: [String] = ["1", "2", "0", "3", "5", "4", "7", "8", "6", "9"]
/// Common ASCII punctuation, most to least common in English prose.
public let punctuation: [String] = [",", ".", "'", "-", "\"", ":", ";", "?", "!"]

/// The effective adaptive alphabet. Letters stay first because the user has
/// already learned them; digits and punctuation extend the tail.
public func buildAlphabet(_ settings: ProfileSettings) -> [String] {
    var alphabet = defaultAlphabet
    if settings.includeNumbers { alphabet += digits }
    if settings.includePunctuation { alphabet += punctuation }
    return alphabet
}

/// Drops UTF-16 surrogate halves. Pasted prose easily contains an emoji, and
/// refusing the whole paste over one is worse than dropping it.
func stripSurrogates(_ string: String) -> String {
    let units = string.utf16.filter { !(0xD800...0xDFFF).contains($0) }
    return String(utf16CodeUnits: units, count: units.count)
}

public struct SessionSnapshot {
    public let mode: Mode
    public let typing: TypingSnapshot
    public let liveMetrics: RunMetrics
    public let elapsedMs: Double
    /// Seconds left in a time-mode benchmark; nil in every other case.
    public let remainingSec: Double?
    public let plan: LessonPlan?
    public let lastResult: RunResult?
    /// Which passage is being typed — `q-twain-travel`, `code-fizzbuzz-py`,
    /// `pseudo:…`.
    ///
    /// Additive, and deliberately: the golden vectors pin the *shape* of what
    /// crosses this boundary, and a new field on a struct nothing serializes
    /// leaves them untouched. `Step` and the step log stay private.
    ///
    /// It exists because the app cannot otherwise see which passage it is
    /// serving. `RunResult` carries the id, but only once the run is over —
    /// too late for anything that has to decide during it.
    public let passageId: String
}

/// Orchestrates one practice run at a time: builds the lesson plan from
/// history, sources text, drives a `TextInput`, and on completion records a
/// result back into the profile.
///
/// Every run feeds the adaptive picture, benchmark runs included — which is
/// why a benchmark still produces a per-bigram histogram.
public final class Session {
    public private(set) var profile: Profile
    private let now: () -> Double
    private var rng: Mulberry32
    /// Text sources. They take the session's RNG by reference, because the
    /// corpus picker draws from the same stream as the generators — a source
    /// with its own generator would make runs reproducible individually and
    /// not in sequence.
    private let adaptiveSource: ((Filter, Int, PassageLength, inout Mulberry32) throws -> Passage)?
    private let benchmarkSource: ((Int, ProfileSettings, inout Mulberry32) throws -> Passage)?
    private let onResult: ((RunResult, Profile) -> Void)?

    private var textInput: TextInput?
    private var passage: Passage?
    private var plan: LessonPlan?
    private var lastResult: RunResult?
    /// Mode captured at `start()`. May lag the settings until the next start.
    private var activeMode: Mode = .adaptive
    /// Benchmark shape captured at `start()`, for the same reason as
    /// `activeMode`: `stageSettings` promises a mid-run change takes effect on
    /// the next run, and reading `profile.settings` live broke that promise for
    /// the one setting where it is most visible — switching to word mode
    /// mid-run stopped the running clock, and shortening the duration ended the
    /// run instantly.
    private var activeTestMode: TestMode = .words
    private var activeTestDurationSec: Double = 30
    /// Latched by the keystroke that ends the run and cleared by `start()`.
    /// Without it, time-mode completion re-fires on every later keystroke —
    /// `TextInput.completed` tracks the cursor, not the clock — and each one
    /// records another result.
    private var runCompleted = false

    public enum SessionError: Error {
        case noActiveRun
        case completedWithoutPassage
    }

    public init(
        profile: Profile,
        now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
        rng: Mulberry32 = Mulberry32(seed: UInt32.random(in: 0...UInt32.max)),
        adaptiveSource: ((Filter, Int, PassageLength, inout Mulberry32) throws -> Passage)? = nil,
        benchmarkSource: ((Int, ProfileSettings, inout Mulberry32) throws -> Passage)? = nil,
        onResult: ((RunResult, Profile) -> Void)? = nil
    ) throws {
        self.profile = profile
        self.now = now
        self.rng = rng
        self.adaptiveSource = adaptiveSource
        self.benchmarkSource = benchmarkSource
        self.onResult = onResult
        try start()
    }

    /// Builds the plan, sources fresh text, resets typing state.
    ///
    /// Every throwing step runs against locals, and session state is replaced
    /// only once they have all succeeded. Assigning as it went left a failed
    /// start half-applied: `runCompleted` was already false and the *previous*
    /// `TextInput` was still installed, so the run the user was in the middle
    /// of became completable a second time and recorded a duplicate result
    /// against the new plan.
    public func start() throws {
        let settings = profile.settings
        let nextPlan: LessonPlan?
        let nextPassage: Passage
        // The RNG is session state like any other, and the source closures take
        // it `inout` — so a source that draws and then throws had already
        // advanced the stream. Generating against a copy keeps a failed start
        // from consuming draws the next one should have made.
        var nextRNG = rng

        if settings.mode == .adaptive {
            let plan = buildPlan()
            nextPlan = plan
            let filter = Filter(allowed: plan.included, focus: plan.focus)
            nextPassage = try adaptiveSource.map {
                try $0(filter, Int(settings.wordCount), settings.passageLength, &nextRNG)
            }
                // The default source ignores passageLength: pseudo-words honour
                // the word count directly, and the bucket only matters to
                // adapters pulling from a real corpus.
                ?? generatePseudoWords(
                    filter: filter,
                    options: PseudoWordOptions(wordCount: Int(settings.wordCount)),
                    rng: &nextRNG)
        } else {
            nextPlan = nil
            let words =
                settings.testMode == .time
                ? timeModeWordBudget(settings.testDurationSec) : Int(settings.wordCount)
            nextPassage = try benchmarkSource.map { try $0(words, settings, &nextRNG) }
                ?? generatePlainWords(
                    options: PlainWordsOptions(
                        wordCount: words, includeNumbers: settings.includeNumbers,
                        includePunctuation: settings.includePunctuation),
                    rng: &nextRNG)
        }

        let nextInput = try TextInput(
            expected: nextPassage.text, stopOnError: settings.stopOnError,
            noBackspace: settings.noBackspace)

        rng = nextRNG
        lastResult = nil
        runCompleted = false
        activeMode = settings.mode
        activeTestMode = settings.testMode
        activeTestDurationSec = settings.testDurationSec
        plan = nextPlan
        passage = nextPassage
        textInput = nextInput
    }

    public func restart() throws { try start() }

    /// A one-off run over caller-supplied text — the inline "custom text"
    /// affordance. Nothing is persisted; the next `start()` returns to the
    /// corpus pipeline.
    public func startWithText(_ text: String) throws {
        let cleaned = stripSurrogates(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        // Same commit-last discipline as `start()`: `makePassage` and
        // `TextInput` both throw, and a half-applied custom run would leave the
        // previous one recordable again.
        let nextPassage = try makePassage(
            id: "custom:\(JSONWriter.stringify(.fromDouble(now())))", text: cleaned)
        let nextInput = try TextInput(
            expected: cleaned, stopOnError: profile.settings.stopOnError,
            noBackspace: profile.settings.noBackspace)

        lastResult = nil
        runCompleted = false
        activeMode = profile.settings.mode
        activeTestMode = profile.settings.testMode
        activeTestDurationSec = profile.settings.testDurationSec
        plan = nil
        passage = nextPassage
        textInput = nextInput
    }

    /// Feeds one character. Records a result on the transition to completion.
    @discardableResult
    public func input(_ character: String, timeStamp: Double) throws -> Feedback {
        guard let textInput else { throw SessionError.noActiveRun }
        // Already over — cursor exhausted, timer expired, or a previous call
        // latched it. Rejecting further input is what stops a duplicate result.
        if runCompleted { return .completed }

        var feedback = textInput.appendChar(character, timeStamp: timeStamp)
        if feedback == .running, activeMode == .benchmark, activeTestMode == .time,
            textInput.elapsedMs >= activeTestDurationSec * 1000
        {
            feedback = .completed
        }
        if feedback == .completed {
            runCompleted = true
            try recordResult()
        }
        return feedback
    }

    public func backspace() throws {
        guard let textInput else { throw SessionError.noActiveRun }
        textInput.backspace()
    }

    /// The only supported write path from a UI into engine state. The caller
    /// must pass a fully validated settings object.
    public func updateSettings(_ next: ProfileSettings) throws {
        profile.settings = next
        try start()
    }

    /// Keystrokes committed in the current run — 0 before the first character.
    public var keystrokes: Int { textInput?.steps.count ?? 0 }

    /// Replaces settings without restarting, so a change mid-run costs the
    /// user nothing. Takes effect on the next `start()`.
    public func stageSettings(_ next: ProfileSettings) {
        profile.settings = next
    }

    public func snapshot() throws -> SessionSnapshot {
        // Both, not just the input. They are assigned together and only after
        // every throwing step of `start()` has succeeded, so one without the
        // other means the invariant has already broken — and reporting an
        // empty id would hand the caller a passage name that names nothing.
        guard let textInput, let passage else { throw SessionError.noActiveRun }
        let typing = textInput.snapshot()
        let elapsedMs = textInput.elapsedMs
        let remainingSec =
            activeTestMode == .time && activeMode == .benchmark
            ? max(0, activeTestDurationSec - elapsedMs / 1000) : nil

        return SessionSnapshot(
            mode: activeMode,
            typing: typing,
            liveMetrics: computeLiveMetrics(
                steps: textInput.steps, statuses: typing.statuses, durationMs: elapsedMs),
            elapsedMs: elapsedMs,
            remainingSec: remainingSec,
            plan: plan,
            lastResult: lastResult,
            passageId: passage.id)
    }

    private func buildPlan() -> LessonPlan {
        let stats = buildBigramStatsMap(profile.results.map(\.histogram))
        return planLesson(
            letters: buildAlphabet(profile.settings),
            bigramStats: stats,
            target: Target(targetSpeed: profile.settings.targetWpm),
            settings: profile.settings.adaptive)
    }

    private func recordResult() throws {
        guard let textInput else { throw SessionError.noActiveRun }
        guard let passage else { throw SessionError.completedWithoutPassage }
        let typing = textInput.snapshot()
        // Monotonic: survives history trimming so identifiers are never reused.
        // Taken from the maximum rather than the last entry, because the
        // deserializer accepts any non-negative index in any order — a profile
        // whose final result is not its highest-numbered one would otherwise
        // hand the next run an index that already exists.
        let nextIndex = (profile.results.map(\.index).max() ?? -1) + 1
        let result = RunResult(
            index: nextIndex,
            mode: activeMode,
            timestamp: now(),
            passageId: passage.id,
            text: passage.text,
            metrics: computeRunMetrics(
                steps: textInput.steps, statuses: typing.statuses,
                durationMs: textInput.elapsedMs),
            histogram: histogramFromSteps(textInput.steps))

        profile.results.append(result)
        if profile.results.count > maxHistory {
            profile.results.removeFirst(profile.results.count - maxHistory)
        }
        lastResult = result
        onResult?(result, profile)
    }
}

/// Cheap subset for live display: skips binning and the consistency curve,
/// which would otherwise run on every frame.
public func computeLiveMetrics(
    steps: [Step], statuses: [CharStatus], durationMs: Double
) -> RunMetrics {
    var correctChars = 0
    var incorrectChars = 0
    for status in statuses {
        if status == .correct { correctChars += 1 } else if status == .incorrect {
            incorrectChars += 1
        }
    }
    let correctSteps = steps.reduce(0) { $0 + ($1.typo ? 0 : 1) }
    let minutes = durationMs / msPerMinute
    return RunMetrics(
        netWpm: minutes > 0 ? Stats.roundTo2(Double(correctChars) / charsPerWord / minutes) : 0,
        rawWpm: minutes > 0 ? Stats.roundTo2(Double(steps.count) / charsPerWord / minutes) : 0,
        accuracy: steps.isEmpty
            ? 100 : Stats.roundTo2(Double(correctSteps) / Double(steps.count) * 100),
        consistency: 0,
        wpmStdDev: 0,
        wpmSeries: [],
        correctChars: correctChars,
        incorrectChars: incorrectChars,
        durationMs: durationMs)
}
