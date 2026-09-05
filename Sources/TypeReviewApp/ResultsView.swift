import AppKit
import TypeReviewKit

/// The card shown when a run finishes.
///
/// Deliberately quiet: four numbers, a small speed trace, and the slowest
/// bigrams. The web version also shows a replay animation and achievement
/// chips; those are motivation features, and whether this app wants them is a
/// product question, not a porting one.
final class ResultsView: NSView {
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let weakest = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "⏎ next run · ⇥ new text")
    private var series: [Double] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        headline.font = NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .medium)
        headline.textColor = Theme.correct
        detail.font = Theme.statFont
        detail.textColor = Theme.secondaryText
        weakest.font = Theme.statFont
        weakest.textColor = Theme.secondaryText
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = Theme.secondaryText

        let stack = NSStackView(views: [headline, detail, weakest, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(result: RunResult, history: [RunResult]) {
        headline.stringValue = String(format: "%.0f wpm", result.metrics.netWpm)
        detail.stringValue = String(
            format: "%.0f%% accurate · %.0f raw · consistency %.0f · %.0fs",
            result.metrics.accuracy, result.metrics.rawWpm, result.metrics.consistency,
            result.metrics.durationMs / 1000)
        // Named from the whole history, not this run: three attempts at a pair
        // is noise, and `slowestBigrams` drops anything under five hits for
        // exactly that reason.
        let slow = slowestBigrams(history, count: 3, minHits: 5)
        weakest.stringValue = slow.isEmpty
            ? "slowest pairs: not enough data yet"
            : "slowest pairs: "
                + slow.map { String(format: "%@ %.0fms", $0.bigram, $0.avgMs) }
                    .joined(separator: " · ")
        series = result.metrics.wpmSeries
        needsDisplay = true
    }

    /// A per-second speed trace. Sparkline rather than a chart: the useful
    /// question after a run is "was I steady", which a shape answers faster
    /// than axes would.
    override func draw(_ dirtyRect: NSRect) {
        guard series.count > 1 else { return }
        let plot = NSRect(
            x: 0, y: bounds.height - 60, width: bounds.width, height: 52)
        guard let maximum = series.max(), maximum > 0 else { return }

        let path = NSBezierPath()
        for (index, value) in series.enumerated() {
            let x = plot.minX + plot.width * CGFloat(index) / CGFloat(series.count - 1)
            let y = plot.maxY - plot.height * CGFloat(value / maximum)
            if index == 0 { path.move(to: NSPoint(x: x, y: y)) } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }
        Theme.caret.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}
