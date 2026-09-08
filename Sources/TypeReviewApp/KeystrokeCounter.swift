import AppKit
import TypeReviewKit

/// Counts keys pressed anywhere, a day at a time.
///
/// Its own file beside `profile.json` rather than a field inside it, and
/// deliberately. The profile is a record of practice, and this is a record of
/// typing generally — mixing them would put system-wide data into every
/// profile the user exports or hands to somebody, and would tie erasing one to
/// erasing the other. Two files means "delete this and only this" is a
/// sentence the app can actually offer.
///
/// What it stores is a count per day and nothing else: no times, no key codes,
/// no application names. See `KeystrokeLog`.
@MainActor
final class KeystrokeCounter {
    /// How often a dirty counter reaches disk.
    ///
    /// Not per keystroke: that is a file write per key, in a callback the
    /// system will disable if it runs slow. A minute is the most that can be
    /// lost to a crash or a power cut, against a number whose whole purpose is
    /// to be roughly right.
    private static let flushInterval: TimeInterval = 60

    private let fileURL: URL
    private let calendar: Calendar
    private let now: () -> Date

    private var log = KeystrokeLog()
    /// Counted but not yet folded into `log`.
    private var pending = 0
    private var currentDay: String
    /// When `currentDay` stops being today. Compared per keystroke, which is
    /// one `Date()` and one comparison — the whole per-key cost.
    private var dayEndsAt: Date
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(
        directory: URL, calendar: Calendar = localStatisticsCalendar(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.fileURL = directory.appendingPathComponent("keystrokes.json")
        self.calendar = calendar
        self.now = now
        let today = now()
        self.currentDay = dayKey(today.timeIntervalSince1970 * 1000, calendar: calendar)
        self.dayEndsAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))
            ?? today.addingTimeInterval(86_400)
        load()
    }

    // MARK: - Counting

    /// One key pressed. Called from the event tap, so it allocates nothing and
    /// formats no dates.
    func record() {
        if now() >= dayEndsAt { rollOver() }
        pending += 1
    }

    /// Everything counted so far, including what has not reached disk.
    ///
    /// The grid reads this, so a day's cell has to include the keys pressed in
    /// the last minute — a chart that lags a flush interval behind the
    /// keyboard looks broken in exactly the moment somebody checks it.
    func snapshot() -> KeystrokeLog {
        var merged = log
        merged.add(pending, on: currentDay)
        return merged
    }

    var isEmpty: Bool { snapshot().isEmpty }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        // So a minute of typing is not lost because a modal panel is up.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Quitting and sleeping are the two ordinary ways a minute goes
        // missing. Termination is the common one; sleep matters because a
        // laptop closed mid-sentence may not wake for days.
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.flush() } })
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.flush() } })
    }

    func stop() {
        flush()
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }

    /// Forgets everything, on disk and in memory.
    func erase() {
        log = KeystrokeLog()
        pending = 0
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Disk

    private func rollOver() {
        let today = now()
        log.add(pending, on: currentDay)
        pending = 0
        currentDay = dayKey(today.timeIntervalSince1970 * 1000, calendar: calendar)
        dayEndsAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))
            ?? today.addingTimeInterval(86_400)
        flush()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // An unreadable file is left alone rather than overwritten. It is the
        // only copy of the counts, and a parse failure is at least as likely
        // to be this app's fault as the file's.
        guard let decoded = try? decodeKeystrokeLog(data) else { return }
        log = decoded
    }

    func flush() {
        guard pending > 0 else { return }
        log.add(pending, on: currentDay)
        pending = 0
        log.prune()
        guard let data = try? encodeKeystrokeLog(log) else { return }
        // Atomic: a half-written file here is a year of counts replaced by
        // whatever fitted before the power went out.
        try? data.write(to: fileURL, options: .atomic)
    }
}
