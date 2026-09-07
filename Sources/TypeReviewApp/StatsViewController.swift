import AppKit
import TypeReviewKit

/// The statistics window: totals, streaks, and one table that answers the same
/// four questions about either a key or a finger.
///
/// Two views of one set of numbers, because `aggregatePerFinger` is built on
/// `aggregatePerKey` — the same data regrouped. A finger view is what turns a
/// heatmap of thirty keys into "your right pinky is the slow one", which is a
/// sentence the per-key table makes the reader assemble themselves.
///
/// Not the slowest *pairs*, which this used to claim. `slowestBigrams` exists
/// in the engine and the results screen shows them after a run; this window
/// has never had a place for them.
///
/// Everything here comes from the ported aggregations, so the numbers are the
/// website's numbers — including the day-level ones, which are computed in
/// local calendar days rather than fixed 24-hour blocks.
final class StatsViewController: NSViewController {
    private let summary = NSTextField(labelWithString: "")
    private let streakLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    /// One row shape for both groupings. The columns ask the same four
    /// questions either way, so the table does not need to know which it is
    /// showing — only the first column's heading changes.
    private struct Row {
        let label: String
        let hits: Int
        let avgMs: Double
        let errorRate: Double
    }
    private var rows: [Row] = []
    private let grouping = NSSegmentedControl(
        labels: ["Keys", "Fingers"], trackingMode: .selectOne, target: nil, action: nil)
    /// Where to re-read the history from.
    ///
    /// A closure rather than the snapshot this used to keep — which was stored
    /// and never read, and could not have helped anyway: the window showed the
    /// totals as they were when it opened and never moved again, so finishing
    /// a run with Statistics on screen left it quietly stale.
    var history: () -> [RunResult] = { [] }
    private var runObserver: NSObjectProtocol?
    private var dayObserver: NSObjectProtocol?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
        summary.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        streakLabel.font = Theme.statFont
        streakLabel.textColor = Theme.secondaryText
        configureTable()
        install(header: makeHeader(), scroll: makeScrollView(), in: root)
        view = root
    }

    /// Columns and row style. Split out of `loadView`, which was doing this
    /// alongside header construction, scrolling and constraints.
    private func configureTable() {
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .default
        table.headerView = NSTableHeaderView()
        // The same inset rows the Library uses. Left at `.automatic` this
        // table drew full-bleed rows squared off against the window edge,
        // which is the older list shape and made the two tables in one app
        // look like they came from different decades.
        table.style = .inset
        for (identifier, title, width) in [
            ("key", "Key", CGFloat(90)), ("hits", "Typed", 80), ("avg", "Avg ms", 90),
            ("err", "Errors", 90),
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
    }

    private func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func makeHeader() -> NSStackView {
        grouping.selectedSegment = 0
        grouping.target = self
        grouping.action = #selector(groupingChanged)
        grouping.segmentStyle = .rounded
        let header = NSStackView(views: [summary, streakLabel, grouping])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        return header
    }

    private func install(header: NSStackView, scroll: NSScrollView, in root: NSView) {
        root.addSubview(header)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
    }

    /// Re-reads and redisplays. Called when the window opens and whenever a
    /// run finishes while it is open.
    func refresh() { present(results: history()) }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard runObserver == nil else { return }
        runObserver = NotificationCenter.default.addObserver(
            forName: PracticeViewController.runCompleted, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // A finished run is not the only thing that changes these numbers.
        // Midnight changes the streak and the practice-day count without any
        // run happening, and a window left open across it went on reporting
        // yesterday's — the same staleness the run observer was added to fix,
        // arriving by the clock instead of by the keyboard.
        dayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // Both, from one list. Removing them one named field at a time is how
        // the second one gets forgotten — which it was, the moment it was
        // added a few lines above.
        for observer in [runObserver, dayObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        runObserver = nil
        dayObserver = nil
    }

    func present(results: [RunResult]) {
        // Before the empty-history guard, not after. Switching to Fingers with
        // no runs yet left the column headed "Key", which is the one case
        // where the heading is the only thing on screen saying what the empty
        // table would have contained.
        table.tableColumns.first?.title = grouping.selectedSegment == 1 ? "Finger" : "Key"
        guard !results.isEmpty else {
            summary.stringValue = "No runs yet."
            streakLabel.stringValue = ""
            rows = []
            table.reloadData()
            return
        }

        let best = results.map(\.metrics.netWpm).max() ?? 0
        let recent = results.suffix(10).map(\.metrics.netWpm)
        let average = recent.reduce(0, +) / Double(recent.count)
        summary.stringValue = String(
            format: "%d runs · best %.0f wpm · last 10 average %.0f wpm", results.count, best,
            average)

        let calendar = localStatisticsCalendar()
        let days = streak(results, now: Date().timeIntervalSince1970 * 1000, calendar: calendar)
        let practiceDays = dailyCounts(results, calendar: calendar).count
        streakLabel.stringValue =
            "\(days.current)-day streak · longest \(days.longest) · \(practiceDays) days practised"

        // Sorted slowest first: the table is a list of what to work on, so the
        // useful row is at the top rather than wherever the alphabet puts it.
        let perKey = aggregatePerKey(results)
        if grouping.selectedSegment == 1 {
            // Left in the hand's own order rather than sorted slowest-first.
            // Nine rows read as a pair of hands when they are laid out like
            // one, and finding the slow finger among nine is not the search
            // that sorting thirty keys was solving.
            rows = aggregatePerFinger(perKey).map {
                Row(
                    label: $0.finger.label, hits: $0.hits, avgMs: $0.avgMs,
                    errorRate: $0.errorRate)
            }
        } else {
            // Sorted slowest first: the table is a list of what to work on, so
            // the useful row is at the top rather than wherever the alphabet
            // puts it.
            rows = perKey.entries
                .filter { $0.value.hits > 0 }
                .sorted { $0.value.avgMs > $1.value.avgMs }
                .map {
                    // A space is a real key and the commonest one; showing it
                    // blank would leave the top row unexplained.
                    Row(
                        label: $0.key == " " ? "space" : $0.key, hits: $0.value.hits,
                        avgMs: $0.value.avgMs, errorRate: $0.value.errorRate)
                }
        }
        table.reloadData()
    }

    @objc private func groupingChanged() { refresh() }
}

extension StatsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard row < rows.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let entry = rows[row]
        let text: String
        switch identifier {
        case "key": text = entry.label
        case "hits": text = String(entry.hits)
        case "avg": text = String(format: "%.0f", entry.avgMs)
        case "err": text = String(format: "%.1f%%", entry.errorRate * 100)
        // A column this method does not know about is a mistake in
        // `configureTable`, and drawing it as an error rate would hide that
        // behind a plausible-looking number.
        default: return nil
        }

        let label = NSTextField(labelWithString: text)
        label.font = Theme.statFont
        if identifier == "err", entry.errorRate > 0.05 { label.textColor = Theme.incorrect }
        return label
    }
}
