import AppKit
import TypeReviewKit

/// The statistics window: totals, streaks, a sixty-day practice grid, and one
/// table that answers the same four questions about either a key or a finger.
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
///
/// The grid is the last of those to arrive. `dailyCounts` was already being
/// computed here and immediately reduced to `.count` for "N days practised",
/// which threw the distribution away on the line that built it; the website
/// had been drawing that distribution all along.
final class StatsViewController: NSViewController {
    private let summary = NSTextField(labelWithString: "")
    private let streakLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    /// The sixty-day grid. Hidden rather than emptied when there is no
    /// history: the empty branch below blanks the streak label for the same
    /// reason, and sixty grey squares saying "you have never practised" is a
    /// worse first launch than not raising the subject.
    private let calendar = PracticeCalendarView()
    /// What the grid counts. Beside the grid rather than in the toolbar: the
    /// toolbar's segmented control switches what the *window* is showing, and
    /// two identical-looking controls up there, governing a table and a grid
    /// respectively, would leave neither obviously attached to anything.
    private let metric = NSPopUpButton(frame: .zero, pullsDown: false)
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
    /// The system-wide counts, or nil when the user has not switched counting
    /// on. Nil rather than an empty log, so "off" and "nothing typed" stay
    /// distinguishable — they draw the same grid otherwise.
    var keystrokes: () -> KeystrokeLog? = { nil }
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
        // Columns share the width instead of keeping fixed sizes. Four fixed
        // columns came to 350pt in a table around 520 wide, so every row hugged
        // the left with a third of the window empty beside it — centring the
        // text alone would have centred it inside that same left-hand block.
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for (identifier, title) in [
            ("key", "Key"), ("hits", "Typed"), ("avg", "Avg ms"), ("err", "Errors"),
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = 120
            // Below this the headings truncate before the numbers do, which
            // reads as a broken table rather than a narrow one.
            column.minWidth = 64
            column.headerCell.alignment = .center
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
        // `.automatic` in a toolbar, which is what draws the current macOS
        // segmented picker rather than the older rounded capsule.
        grouping.segmentStyle = .automatic
        // The grouping control is not in here: it belongs in the toolbar, which
        // is where macOS puts a control that switches what a window is showing.
        // An arranged subview rather than a plain one: NSStackView collapses
        // a hidden arranged subview, so the no-history case closes the gap
        // instead of leaving the table pushed down by an invisible grid.
        calendar.heightAnchor.constraint(
            equalToConstant: calendar.intrinsicContentSize.height).isActive = true
        // A borderless pop-up, not a segmented control. A segmented control
        // fills its selection with the accent colour, which is the same blue
        // the grid six points below uses to mean "this many characters" — two
        // different meanings for one colour, side by side. This reads as a
        // caption that happens to be clickable, which is what it is.
        metric.addItems(withTitles: AppPreferences.StatsMetric.allCases.map(\.label))
        markMetric()
        metric.target = self
        metric.action = #selector(metricChanged)
        metric.isBordered = false
        metric.controlSize = .small
        metric.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let header = NSStackView(views: [summary, streakLabel, metric, calendar])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        // The grid is evidence for the streak line above it, not another line
        // of it, so it gets air the two labels do not.
        header.setCustomSpacing(14, after: streakLabel)
        header.setCustomSpacing(6, after: metric)
        // Full width, so the grid has room for all twenty columns rather than
        // being squeezed to the width of the longest label above it.
        calendar.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
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

    // MARK: - Probes
    //
    // Read by `--selftest` and by nothing else. The Statistics window is built
    // lazily when somebody clicks, so everything in it is one refactor away
    // from being broken in a build that otherwise passes.

    /// Whether the practice grid is showing, and how many cells it holds.
    var calendarState: (hidden: Bool, cells: Int) { (calendar.isHidden, calendar.cellCount) }

    /// What the grid actually draws. See `PracticeCalendarView.renderProbe`.
    func calendarInk() -> (ink: Int, tinted: Int) { calendar.renderProbe() }

    /// The grid's own description of what it is counting.
    var calendarSummary: String { calendar.summaryText }

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
            calendar.isHidden = true
            metric.isHidden = true
            rows = []
            table.reloadData()
            return
        }
        calendar.isHidden = false
        metric.isHidden = false
        markMetric()

        let best = results.map(\.metrics.netWpm).max() ?? 0
        let recent = results.suffix(10).map(\.metrics.netWpm)
        let average = recent.reduce(0, +) / Double(recent.count)
        summary.stringValue = String(
            format: "%d runs · best %.0f wpm · last 10 average %.0f wpm", results.count, best,
            average)

        // Named to avoid shadowing the calendar *view* this controller now
        // holds. The two are one letter apart and mean entirely different
        // things.
        let statsCalendar = localStatisticsCalendar()
        let now = Date().timeIntervalSince1970 * 1000
        let days = streak(results, now: now, calendar: statsCalendar)
        let practiceDays = dailyCounts(results, calendar: statsCalendar).count
        // The preference, not the control. `makeHeader` is what seeds the
        // segment, and it runs lazily on first view access -- so anything
        // asking before the window is on screen read segment 0 and got
        // sessions regardless of what the user had chosen.
        // Keystrokes falls back to characters when the counter is off, rather
        // than drawing an empty grid: an all-grey chart under a heading that
        // says "All keystrokes" reads as "you have typed nothing", not as
        // "this is switched off".
        var chosen = AppPreferences.statsMetric.value
        let log = chosen == .keystrokes ? keystrokes() : nil
        if chosen == .keystrokes, log == nil { chosen = .characters }

        let perDay: OrderedMap<Int>
        switch chosen {
        case .sessions: perDay = dailyCounts(results, calendar: statsCalendar)
        case .characters: perDay = charactersPerDay(results, calendar: statsCalendar)
        case .keystrokes: perDay = log?.countsByDay() ?? OrderedMap<Int>()
        }
        calendar.show(
            practiceCalendar(
                countsByDay: perDay, now: now, days: PracticeCalendarView.windowDays,
                calendar: statsCalendar),
            unit: PracticeCalendarView.Unit(chosen))
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

    @objc private func metricChanged() {
        let all = AppPreferences.StatsMetric.allCases
        AppPreferences.statsMetric.value = all[min(max(0, metric.indexOfSelectedItem), all.count - 1)]
        refresh()
    }

    /// Keeps the segment in step with the preference, which is what `present`
    /// actually reads.
    private func markMetric() {
        let all = AppPreferences.StatsMetric.allCases
        metric.selectItem(at: all.firstIndex(of: AppPreferences.statsMetric.value) ?? 0)
    }

    @objc private func groupingChanged() { refresh() }
}

/// The window's toolbar.
///
/// A window with no `NSToolbar` gets the short opaque title bar macOS drew
/// before Big Sur — title centred in its own strip, traffic lights in a band
/// doing nothing else. The practice window and the Library both carry a unified
/// toolbar for exactly that reason, and this window was the one left behind, so
/// it read as the odd one out in its own app.
///
/// The grouping picker moves in here rather than sitting in an improvised row
/// above the table. A control that switches what the window is showing is a
/// toolbar control on macOS; below the title it is a widget somebody drew.
extension StatsViewController: NSToolbarDelegate {
    static let groupingItem = NSToolbarItem.Identifier("grouping")

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "TypeReviewStats")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.groupingItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard identifier == Self.groupingItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Group by"
        item.paletteLabel = item.label
        item.toolTip = "Show the numbers per key or per finger"
        item.view = grouping
        // Off for the same reason the keyboard toggle sets it: with a custom
        // view AppKit disables the item unless the target implements
        // validation, and there is no state in which this picker is
        // unavailable.
        item.autovalidates = false
        // A segmented control has no menu form of its own, so in a window
        // narrow enough to push it into the toolbar's overflow it becomes a
        // "Group by" entry that cannot group by anything. This is the same two
        // choices as a menu.
        let overflow = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.label)
        // Ticked when the menu is about to be shown rather than when it is
        // built. Built once, the checkmark froze at whatever was selected at
        // construction and went on claiming Keys after the user chose Fingers.
        submenu.delegate = self
        for (index, title) in ["Keys", "Fingers"].enumerated() {
            let choice = NSMenuItem(
                title: title, action: #selector(groupingPicked(_:)), keyEquivalent: "")
            choice.target = self
            choice.tag = index
            submenu.addItem(choice)
        }
        overflow.submenu = submenu
        item.menuFormRepresentation = overflow
        return item
    }
}

extension StatsViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            item.state = item.tag == grouping.selectedSegment ? .on : .off
        }
    }
}

extension StatsViewController {
    /// The overflow menu's half of the grouping picker. Moves the segmented
    /// control with it, so the two cannot disagree about what is shown.
    @objc fileprivate func groupingPicked(_ sender: NSMenuItem) {
        grouping.selectedSegment = sender.tag
        groupingChanged()
    }
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
        label.alignment = .center
        if identifier == "err", entry.errorRate > 0.05 { label.textColor = Theme.incorrect }
        return label
    }
}
