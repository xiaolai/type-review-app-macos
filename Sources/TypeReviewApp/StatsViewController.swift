import AppKit
import TypeReviewKit

/// The statistics window: totals, streaks, a per-key table and the slowest
/// pairs.
///
/// Everything here comes from the ported aggregations, so the numbers are the
/// website's numbers — including the day-level ones, which are computed in
/// local calendar days rather than fixed 24-hour blocks.
final class StatsViewController: NSViewController {
    private let summary = NSTextField(labelWithString: "")
    private let streakLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private var rows: [(key: String, stat: PerKeyStat)] = []
    private var results: [RunResult] = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))

        summary.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        streakLabel.font = Theme.statFont
        streakLabel.textColor = Theme.secondaryText

        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .default
        table.headerView = NSTableHeaderView()
        for (identifier, title, width) in [
            ("key", "Key", CGFloat(60)), ("hits", "Typed", 80), ("avg", "Avg ms", 90),
            ("err", "Errors", 90),
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [summary, streakLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

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
        view = root
    }

    func present(results: [RunResult]) {
        self.results = results
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
        rows = aggregatePerKey(results).entries
            .filter { $0.value.hits > 0 }
            .sorted { $0.value.avgMs > $1.value.avgMs }
            .map { (key: $0.key, stat: $0.value) }
        table.reloadData()
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
        case "key":
            // A space is a real key and the commonest one; showing it blank
            // would leave the top row unexplained.
            text = entry.key == " " ? "space" : entry.key
        case "hits": text = String(entry.stat.hits)
        case "avg": text = String(format: "%.0f", entry.stat.avgMs)
        default: text = String(format: "%.1f%%", entry.stat.errorRate * 100)
        }

        let label = NSTextField(labelWithString: text)
        label.font = Theme.statFont
        if identifier == "err", entry.stat.errorRate > 0.05 { label.textColor = Theme.incorrect }
        return label
    }
}
