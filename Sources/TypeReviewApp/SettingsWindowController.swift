import AppKit
import TypeReviewKit

/// The Settings window.
///
/// Hand-rolled AppKit rather than a SwiftUI `Settings` scene, which is a
/// `Scene` and cannot exist in an `NSApplication.shared.run()` host.
///
/// Two rules run through it. Every write goes through the engine's
/// `validateSettings`, so a control can never put a value into the profile
/// that the loader would later refuse. And a control never emits a value
/// merely because it displayed one — which is what keeps an imported
/// out-of-range setting from being silently rewritten by opening this window.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Reads and writes the live settings. Returns false when the engine
    /// refuses, so the control can be put back rather than left showing a
    /// value nothing accepted.
    var read: () -> ProfileSettings = { .default }
    var write: (ProfileSettings) -> Bool = { _ in false }

    private let tabs = NSTabViewController()
    private var controls: [String: NSControl] = [:]
    private var rows: [String: NSGridRow] = [:]
    private static let lastPaneKey = "SettingsLastPane"

    init() {
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        // Five things AppKit will not do for a hand-rolled settings window,
        // each silent when omitted: the default collectionBehavior is 0, and
        // without .auxiliary this window displaces the main one in Stage
        // Manager; tabbingMode defaults to .automatic, and this window has been
        // seen absorbed into another window's tab group; transitionOptions
        // reads 4096 in practice though the header documents 4097, so panes
        // hard-cut without an explicit crossfade; the frame is not remembered
        // without an autosave name; and the last-viewed pane is not restored,
        // which the HIG asks for.
        window.collectionBehavior = [.auxiliary, .fullScreenNone]
        window.tabbingMode = .disallowed
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        window.setFrameAutosaveName("TypeReviewSettings")
        super.init(window: window)
        window.delegate = self
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        refresh()
        let last = UserDefaults.standard.integer(forKey: Self.lastPaneKey)
        if last < tabs.tabViewItems.count { tabs.selectedTabViewItemIndex = last }
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(tabs.selectedTabViewItemIndex, forKey: Self.lastPaneKey)
    }

    // MARK: - Building

    private func build() {
        addPane(title: "Practice", symbol: "keyboard") { grid in
            self.addRow(grid, "Mode", self.segmented("mode", SettingsSchema.modes.map(\.rawValue)))
            self.addRow(
                grid, "Target speed", self.stepperField("targetWpm"),
                hint: "The pace a key must hold to count as mastered.")
            self.addRow(
                grid, "Benchmark ends on",
                self.segmented("testMode", SettingsSchema.testModes.map(\.rawValue)))
            self.addRow(grid, "Words per run", self.presetPopup("wordCount"))
            self.addRow(grid, "Duration", self.presetPopup("testDurationSec"))
            self.addRow(
                grid, "Passage length",
                self.popup("passageLength", SettingsSchema.passageLengths.map(\.rawValue)))
            self.addRow(
                grid, "Stop on error", self.toggle("stopOnError"),
                hint: "A mistyped key does not advance the cursor.")
            self.addRow(
                grid, "Confidence mode", self.toggle("noBackspace"),
                hint: "Backspace is ignored — commit each keystroke.")
            self.addRow(grid, "Include numbers", self.toggle("includeNumbers"))
            self.addRow(grid, "Include punctuation", self.toggle("includePunctuation"))
            let restore = NSButton(
                title: "Restore Defaults", target: self, action: #selector(self.restoreDefaults(_:)))
            restore.bezelStyle = .rounded
            let row = grid.addRow(with: [NSGridCell.emptyContentView, restore])
            row.topPadding = 8
        }

        addPane(title: "Data", symbol: "externaldrive") { grid in
            let path = NSTextField(
                labelWithString: (try? ProfileFileStore.standard().fileURL.path) ?? "")
            path.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            path.textColor = Theme.secondaryText
            path.lineBreakMode = .byTruncatingMiddle
            let reveal = NSButton(
                title: "Show in Finder", target: self, action: #selector(self.revealProfile(_:)))
            reveal.bezelStyle = .rounded
            // A file the user can point at is the difference between "we keep
            // your data safe" and showing them where it is. No web build can
            // offer this.
            grid.addRow(with: [NSTextField(labelWithString: "Profile:"), path])
            grid.addRow(with: [NSGridCell.emptyContentView, reveal])
        }
    }

    private func addPane(title: String, symbol: String, populate: (NSGridView) -> Void) {
        // NSGridView, not stacked rows: a settings pane reads as native largely
        // because its labels and controls line up, and a ragged column is the
        // first thing that looks wrong.
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        populate(grid)

        let root = NSView()
        // Autoresizing stays on for the pane's root view, or preferredContentSize
        // silently does nothing and every pane renders at one size.
        root.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
        ])
        let size = grid.fittingSize
        root.frame = NSRect(x: 0, y: 0, width: max(560, size.width + 40), height: size.height + 40)

        let controller = NSViewController()
        controller.view = root
        controller.title = title
        controller.preferredContentSize = root.frame.size
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    private func addRow(_ grid: NSGridView, _ label: String, _ control: NSControl, hint: String? = nil) {
        let hintView: NSView
        if let hint {
            let field = NSTextField(labelWithString: hint)
            field.font = .preferredFont(forTextStyle: .caption1)
            field.textColor = Theme.secondaryText
            hintView = field
        } else {
            hintView = NSGridCell.emptyContentView
        }
        let row = grid.addRow(with: [
            NSTextField(labelWithString: "\(label):"), control, hintView,
        ])
        row.yPlacement = .center
        if let key = control.identifier?.rawValue { rows[key] = row }
    }

    // MARK: - Controls

    private func segmented(_ key: String, _ options: [String]) -> NSControl {
        let control = NSSegmentedControl(
            labels: options.map(\.capitalized), trackingMode: .selectOne, target: self,
            action: #selector(changed(_:)))
        control.identifier = .init(key)
        controls[key] = control
        return control
    }

    private func popup(_ key: String, _ options: [String]) -> NSControl {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        for option in options { control.addItem(withTitle: option.capitalized) }
        control.target = self
        control.action = #selector(changed(_:))
        control.identifier = .init(key)
        controls[key] = control
        return control
    }

    private func presetPopup(_ key: String) -> NSControl {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        let presets = key == "wordCount"
            ? SettingsSchema.wordCountPresets : SettingsSchema.durationPresets
        for preset in presets { control.addItem(withTitle: String(Int(preset))) }
        control.target = self
        control.action = #selector(changed(_:))
        control.identifier = .init(key)
        controls[key] = control
        return control
    }

    private func toggle(_ key: String) -> NSControl {
        let control = NSSwitch()
        control.target = self
        control.action = #selector(changed(_:))
        control.identifier = .init(key)
        controls[key] = control
        return control
    }

    private func stepperField(_ key: String) -> NSControl {
        let field = NSTextField(string: "")
        field.alignment = .right
        field.formatter = {
            let formatter = NumberFormatter()
            formatter.minimum = NSNumber(value: SettingsSchema.UIBounds.targetWpm.lo)
            formatter.maximum = NSNumber(value: SettingsSchema.UIBounds.targetWpm.hi)
            formatter.allowsFloats = false
            return formatter
        }()
        field.target = self
        field.action = #selector(changed(_:))
        field.identifier = .init(key)
        field.frame.size.width = 70
        controls[key] = field
        return field
    }

    // MARK: - State

    /// Renders the live settings. Never emits: a value outside a control's
    /// range is shown as its own item rather than clamped, because clamping on
    /// display rewrites data the user never touched.
    private func refresh() {
        let settings = read()
        (controls["mode"] as? NSSegmentedControl)?.selectedSegment =
            SettingsSchema.modes.firstIndex(of: settings.mode) ?? 0
        (controls["testMode"] as? NSSegmentedControl)?.selectedSegment =
            SettingsSchema.testModes.firstIndex(of: settings.testMode) ?? 0
        controls["targetWpm"]?.stringValue = String(Int(settings.targetWpm))
        select(controls["wordCount"], settings.wordCount, SettingsSchema.wordCountPresets)
        select(controls["testDurationSec"], settings.testDurationSec, SettingsSchema.durationPresets)
        (controls["passageLength"] as? NSPopUpButton)?.selectItem(
            at: SettingsSchema.passageLengths.firstIndex(of: settings.passageLength) ?? 0)
        (controls["stopOnError"] as? NSSwitch)?.state = settings.stopOnError ? .on : .off
        (controls["noBackspace"] as? NSSwitch)?.state = settings.noBackspace ? .on : .off
        (controls["includeNumbers"] as? NSSwitch)?.state = settings.includeNumbers ? .on : .off
        (controls["includePunctuation"] as? NSSwitch)?.state =
            settings.includePunctuation ? .on : .off

        // The duration row only means something in time mode, and the word
        // count only in word mode.
        rows["testDurationSec"]?.isHidden = settings.testMode != .time
        rows["wordCount"]?.isHidden = settings.testMode != .words
    }

    /// Selects a preset, or adds a `Custom (600)` item for a value that has
    /// none — an imported profile may legally hold one, and a picker that
    /// silently snapped it to the nearest preset would destroy it.
    private func select(_ control: NSControl?, _ value: Double, _ presets: [Double]) {
        guard let popup = control as? NSPopUpButton else { return }
        while popup.numberOfItems > presets.count { popup.removeItem(at: popup.numberOfItems - 1) }
        if let index = presets.firstIndex(of: value) {
            popup.selectItem(at: index)
        } else {
            popup.menu?.addItem(.separator())
            popup.addItem(withTitle: "Custom (\(Int(value)))")
            popup.selectItem(at: popup.numberOfItems - 1)
        }
    }

    @objc private func changed(_ sender: NSControl) {
        guard let key = sender.identifier?.rawValue else { return }
        var settings = read()

        switch key {
        case "mode":
            settings.mode = SettingsSchema.modes[
                max(0, (sender as? NSSegmentedControl)?.selectedSegment ?? 0)]
        case "testMode":
            settings.testMode = SettingsSchema.testModes[
                max(0, (sender as? NSSegmentedControl)?.selectedSegment ?? 0)]
        case "targetWpm":
            guard let value = Double(sender.stringValue) else { return refresh() }
            settings.targetWpm = value
        case "wordCount", "testDurationSec":
            guard let popup = sender as? NSPopUpButton else { return }
            let presets = key == "wordCount"
                ? SettingsSchema.wordCountPresets : SettingsSchema.durationPresets
            // Past the presets sits the Custom item, which displays the current
            // value and is not something to write back.
            guard popup.indexOfSelectedItem < presets.count else { return }
            let value = presets[popup.indexOfSelectedItem]
            if key == "wordCount" { settings.wordCount = value } else {
                settings.testDurationSec = value
            }
        case "passageLength":
            settings.passageLength = SettingsSchema.passageLengths[
                max(0, (sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0)]
        case "stopOnError": settings.stopOnError = (sender as? NSSwitch)?.state == .on
        case "noBackspace": settings.noBackspace = (sender as? NSSwitch)?.state == .on
        case "includeNumbers": settings.includeNumbers = (sender as? NSSwitch)?.state == .on
        case "includePunctuation": settings.includePunctuation = (sender as? NSSwitch)?.state == .on
        default: return
        }

        if !write(settings) {
            // The engine said no. Put the control back to what it actually
            // holds rather than leaving a value nothing accepted on screen.
            NSSound.beep()
        }
        refresh()
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        _ = write(.default)
        refresh()
    }

    @objc private func revealProfile(_ sender: Any?) {
        guard let url = try? ProfileFileStore.standard().fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
