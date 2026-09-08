import AppKit
import TypeReviewKit

/// The last sixty days of practice, one cell per day.
///
/// A shape rather than a chart, in the same spirit as `ResultsView`'s
/// sparkline: the question it answers is "have I been showing up", and a grid
/// answers that before the reader has finished focusing on it. Axes, gridlines
/// and a legend of tint values would all be answering a question nobody has.
///
/// Laid out linearly, oldest at the top left, rather than aligned to weekdays
/// the way Github's contribution graph is. Weekday alignment costs a variable
/// leading gap that changes shape depending on which day of the week today
/// happens to be, and the practice question is not "which Tuesdays" — it is
/// "how many of the last sixty days". The web app's calendar made the same
/// call for the same reason.
///
/// Twenty columns rather than the web's ten, because this window is wide and
/// short where the web column is narrow and tall. Ten columns here would make
/// each cell a 50pt slab or leave the grid stranded in the middle of the
/// width; the day count is the thing that has to match, not the rectangle.
@MainActor
final class PracticeCalendarView: NSView {
    /// The window the grid covers. Sixty days is two months of habit — long
    /// enough that a lapse is visible, short enough that every cell still
    /// belongs to a period the reader remembers.
    static let windowDays = 60

    private static let columns = 20
    private static let rows = (windowDays + columns - 1) / columns
    /// Capped rather than derived from the width. Cells that grow with the
    /// window turn into tiles and stop reading as a calendar.
    private static let maxCellSize: CGFloat = 18
    private static let gap: CGFloat = 3
    private static let legendHeight: CGFloat = 16

    /// What a cell's number counts. The grid draws identically either way, so
    /// the unit only exists to keep the tooltip honest — a cell reading
    /// "3 sessions" when it means 3 characters is worse than no tooltip.
    enum Unit {
        case sessions, characters

        func describe(_ count: Int) -> String {
            switch self {
            case .sessions: return count == 1 ? "1 session" : "\(count) sessions"
            case .characters:
                // "characters typed", not "keystrokes": this counts what a run
                // recorded, so backspaces, modifiers and every key pressed
                // outside a run are missing.
                return count == 1 ? "1 character typed" : "\(count) characters typed"
            }
        }

        var summary: String {
            switch self {
            case .sessions: return "sessions"
            case .characters: return "characters typed"
            }
        }
    }

    private var days: [PracticeDay] = []
    private var unit: Unit = .sessions

    /// How many cells the grid is currently showing.
    ///
    /// For `--selftest`, which builds this window headlessly. The wiring is
    /// what it checks: a controller that stops calling `show(_:)` leaves a
    /// view that draws nothing and raises no error, which is the failure this
    /// whole window is one refresh away from at any time.
    var cellCount: Int { days.count }

    /// How the grid describes itself — the one place the unit is observable
    /// without reading pixels. A grid fed characters while still labelled
    /// sessions draws identically and lies only in words.
    var summaryText: String { accessibilitySummary() }

    /// Top-left origin, so the first cell drawn is the oldest day.
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let cell = Self.maxCellSize
        let height =
            CGFloat(Self.rows) * cell + CGFloat(Self.rows - 1) * Self.gap + Self.legendHeight
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    func show(_ days: [PracticeDay], unit: Unit = .sessions) {
        self.days = days
        self.unit = unit
        // One region for the whole grid, resolved to a day on demand. Sixty
        // registered rects would have to be torn down and rebuilt on every
        // refresh, and a stale one points at the wrong date rather than at
        // nothing — a tooltip that is confidently wrong.
        removeAllToolTips()
        if !days.isEmpty {
            addToolTip(bounds, owner: self, userData: nil)
        }
        setAccessibilityLabel(accessibilitySummary())
        needsDisplay = true
    }

    // MARK: - Geometry

    /// The grid's own rect, at the leading edge of whatever width it is given.
    ///
    /// Not centred. Everything else in this window starts at the same left
    /// margin, and a centred grid put its first day and its legend well to the
    /// right of the streak line directly above it — the one misalignment on
    /// the window, and the more obvious for being between two things that
    /// describe the same thing.
    private func gridRect() -> NSRect {
        let cell = Self.maxCellSize
        let width = CGFloat(Self.columns) * cell + CGFloat(Self.columns - 1) * Self.gap
        let height = CGFloat(Self.rows) * cell + CGFloat(Self.rows - 1) * Self.gap
        return NSRect(x: 0, y: 0, width: min(width, bounds.width), height: height)
    }

    private func cellRect(at index: Int) -> NSRect {
        let grid = gridRect()
        let cell = Self.maxCellSize
        let column = index % Self.columns
        let row = index / Self.columns
        return NSRect(
            x: grid.minX + CGFloat(column) * (cell + Self.gap),
            y: grid.minY + CGFloat(row) * (cell + Self.gap),
            width: cell, height: cell)
    }

    private func day(at point: NSPoint) -> PracticeDay? {
        days.indices.lazy.first { cellRect(at: $0).contains(point) }.map { days[$0] }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }

        for (index, day) in days.enumerated() {
            let rect = cellRect(at: index)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)

            // The unpractised colour goes down for every cell, and the accent
            // is laid over it at the day's intensity. That is the same result
            // as mixing the two colours, and it keeps a light tint anchored to
            // the empty cell it has to be told apart from — in both
            // appearances, without either being written down.
            Self.emptyFill.setFill()
            path.fill()
            if day.intensity > 0 {
                Theme.caret.withAlphaComponent(day.intensity).setFill()
                path.fill()
            }

            if day.isToday {
                // A ring, not a fill. Today is a position on the grid, and
                // colouring it would collide with the one thing colour already
                // means here, which is how much was typed.
                let ring = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
                ring.lineWidth = 1.5
                NSColor.labelColor.withAlphaComponent(0.55).setStroke()
                ring.stroke()
            }
        }

        drawLegend()
    }

    /// The window's span, named at both ends. Without it the grid is sixty
    /// squares with no units — a reader cannot tell sixty days from sixty
    /// weeks.
    private func drawLegend() {
        guard let oldest = days.first else { return }
        let grid = gridRect()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: Theme.secondaryText,
        ]
        let baseline = grid.maxY + 4

        // `MM-DD`: the year is the same one the reader is in, on a grid that
        // only ever spans sixty days.
        let start = NSAttributedString(string: String(oldest.key.dropFirst(5)), attributes: attributes)
        start.draw(at: NSPoint(x: grid.minX, y: baseline))

        let end = NSAttributedString(string: "today", attributes: attributes)
        end.draw(at: NSPoint(x: grid.maxX - end.size().width, y: baseline))
    }

    /// Slightly stronger than a hairline separator: an unpractised day has to
    /// be visible as a cell, or the grid loses its shape in a quiet fortnight
    /// and the reader cannot tell sixty days from however many they managed.
    private static var emptyFill: NSColor { NSColor.quaternaryLabelColor }

    // MARK: - Off-screen probe

    /// Renders the grid off-screen and reports what it actually inked.
    ///
    /// For `--selftest`. Cell *count* is not evidence that anything was drawn:
    /// this app has already shipped a window that laid out correctly and
    /// rendered blank, past a guard that only counted what it had built. So
    /// this measures pixels, and measures them twice — once as the grid is,
    /// once with every intensity flattened to zero. If those two agree, the
    /// tint is not reaching the screen and the grid is sixty identical
    /// squares, which is the failure that looks most like success.
    func renderProbe(width: CGFloat = 460) -> (ink: Int, tinted: Int) {
        let real = days
        let flattened = days.map {
            PracticeDay(key: $0.key, count: $0.count, isToday: $0.isToday, intensity: 0)
        }
        let a = renderPixels(width: width, days: real)
        let b = renderPixels(width: width, days: flattened)
        days = real

        let ink = a.filter { $0 != 0 }.count
        let tinted = zip(a, b).filter { $0 != $1 }.count
        return (ink, tinted)
    }

    /// One RGBA word per pixel, so two renders can be compared directly.
    private func renderPixels(width: CGFloat, days: [PracticeDay]) -> [UInt32] {
        self.days = days
        let size = NSSize(width: width, height: intrinsicContentSize.height)
        frame = NSRect(origin: .zero, size: size)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return [] }
        cacheDisplay(in: bounds, to: rep)
        guard let data = rep.bitmapData else { return [] }
        let count = rep.pixelsWide * rep.pixelsHigh
        let stride = rep.bitsPerPixel / 8
        return (0..<count).map { index in
            let offset = index * stride
            return (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8)
                | (stride > 3 ? UInt32(data[offset + 3]) : 255)
        }
    }

    // MARK: - Description

    private func accessibilitySummary() -> String {
        let practised = days.filter { $0.count > 0 }.count
        let total = days.reduce(0) { $0 + $1.count }
        return "Practice calendar: \(practised) of \(days.count) days, \(total) \(unit.summary)"
    }
}

extension PracticeCalendarView: NSViewToolTipOwner {
    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
        userData: UnsafeMutableRawPointer?
    ) -> String {
        guard let day = day(at: point) else { return "" }
        return "\(day.key) — \(day.count == 0 ? "no practice" : unit.describe(day.count))"
    }
}
