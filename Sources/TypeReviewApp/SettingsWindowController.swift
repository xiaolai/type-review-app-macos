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
    /// Plays one keystroke at the current settings. A sound pack picked in
    /// silence is a pack chosen blind — the whole point of the setting is
    /// what it sounds like, so choosing one plays it.
    var previewSound: () -> Void = {}

    private let tabs = NSTabViewController()
    private var controls: [String: NSControl] = [:]
    /// Every row a setting owns — its control row and, when it has one, the
    /// caption beneath. Hiding a setting has to hide both, or a stray line of
    /// grey text is left explaining a control that is not there.
    private var rows: [String: [NSGridRow]] = [:]
    /// Retains the closure-backed targets for the app-preference controls.
    private var proxies: [ActionProxy] = []
    /// Steppers that mirror a profile field, so `refresh` can move them with
    /// the value they show.
    private var steppers: [String: NSStepper] = [:]
    /// Each pane and its grid, so a pane can be re-measured when a row is
    /// hidden.
    private var panes: [(controller: NSViewController, grid: NSGridView)] = []
    private static let lastPaneKey = "SettingsLastPane"
    private static let paneWidth: CGFloat = 500
    private static let paneMargin: CGFloat = 22
    private static let captionWidth: CGFloat = 260
    private static let pathWidth: CGFloat = 330

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
        // The tab strip is already visually distinct from the pane below it, so
        // the rule between them is a second boundary doing the first one's job.
        // Both properties are required — see the note in `AppDelegate`.
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.delegate = self
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        refresh()
        // Both ends checked. `UserDefaults.integer` happily returns whatever
        // `defaults write` put there, including a negative number, and
        // `selectedTabViewItemIndex` traps on one — the same reason every
        // other read in this window is clamped rather than trusted.
        let last = UserDefaults.standard.integer(forKey: Self.lastPaneKey)
        if last >= 0, last < tabs.tabViewItems.count { tabs.selectedTabViewItemIndex = last }
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
            // Set off from the settings it resets, so it reads as an action on
            // the pane rather than as one more row of it.
            row.topPadding = 18
        }

        // Its own pane, and deliberately not mixed in with Practice: nothing
        // here is part of the profile. These are properties of this window on
        // this Mac, and they are stored and validated separately from the
        // settings the website also has.
        // "Appearance", not "Window": it started as window shape alone and now
        // also holds how the typing surface itself is drawn. The website calls
        // its equivalent tab the same thing.
        addPane(title: "Appearance", symbol: "macwindow") { grid in
            self.addRow(
                grid, "Caret", self.caretPopup(),
                hint: "The shape of the cursor on the typing surface.")
            self.addRow(
                grid, "Show invisibles", self.whitespaceToggle(),
                hint: "space · tab → wrap ↵ paragraph ¶")
            self.addRow(
                grid, "Characters per line", self.preferenceStepper(AppPreferences.columns),
                hint: "The window is sized to fit exactly this many.")
            self.addRow(
                grid, "Lines of text", self.preferenceStepper(AppPreferences.rows))
            self.addRow(
                grid, "Keyboard width", self.percentPopup(AppPreferences.drawerWidth, [95, 90, 85, 80, 75]),
                hint: "The keyboard's width, as a share of the window's.")
            self.addRow(
                grid, "Keyboard gap", self.preferenceStepper(AppPreferences.drawerGap),
                hint: "Points of air between the window and the keyboard.")
            self.addRow(
                grid, "Drawer speed", self.drawerSpeedPopup(),
                hint: "How long the keyboard takes to slide out and back.")
        }

        // Its own pane rather than a row in Practice, for the same reason
        // Window is: nothing here is part of the profile. The website keeps
        // sound in localStorage and gives it its own settings tab; this
        // mirrors both decisions.
        addPane(title: "Sound", symbol: "speaker.wave.2") { grid in
            self.addRow(
                grid, "Keyboard", self.soundPackPopup(),
                hint: "Heard on every keystroke. Picking one plays it.")
            self.addRow(grid, "Volume", self.volumeSlider())
            self.addRow(
                grid, "Shortcut", self.shortcutRecorder(),
                hint: "Works from any app. ⌫ clears it, ⎋ cancels.")
        }

        addPane(title: "Data", symbol: "internaldrive") { grid in
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
            // Wider than a caption: middle-truncated to 260 points this read as
            // `/Users/joker/Library_type.app/profile.json`, which looks less
            // like an abbreviated path than a wrong one.
            path.preferredMaxLayoutWidth = Self.pathWidth
            path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            path.widthAnchor.constraint(equalToConstant: Self.pathWidth).isActive = true
            path.toolTip = (try? ProfileFileStore.standard().fileURL.path) ?? ""
            let pathRow = grid.addRow(with: [NSTextField(labelWithString: "Profile:"), path])
            pathRow.yPlacement = .center
            let revealRow = grid.addRow(with: [NSGridCell.emptyContentView, reveal])
            revealRow.topPadding = 10
        }
    }

    private func addPane(title: String, symbol: String, populate: (NSGridView) -> Void) {
        // NSGridView, not stacked rows: a settings pane reads as native largely
        // because its labels and controls line up, and a ragged column is the
        // first thing that looks wrong.
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        // Leading, not fill. Filling makes every control as wide as the widest
        // one in the pane, which is how a target-speed field ended up 330
        // points across.
        grid.column(at: 1).xPlacement = .leading
        populate(grid)

        let root = NSView()
        // Autoresizing stays on for the pane's root view, or preferredContentSize
        // silently does nothing and every pane renders at one size.
        root.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            // Centred rather than pinned left: the labels are right-aligned
            // and the controls left-aligned, so the block has a natural axis,
            // and hanging it off the left edge leaves the whole right side of
            // the window empty.
            grid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.paneMargin),
            // `lessThanOrEqualTo`, not `equalTo`. Pinned to both edges the
            // grid stretches to whatever height the pane was given — and the
            // pane is measured with every row visible, before `refresh()`
            // hides the ones that do not apply. The slack then has to go
            // somewhere, and NSGridView puts it inside a row: a 67-point band
            // of white in the middle of the pane that moved around as the
            // rows changed.
            grid.bottomAnchor.constraint(
                lessThanOrEqualTo: root.bottomAnchor, constant: -Self.paneMargin),
            grid.leadingAnchor.constraint(
                greaterThanOrEqualTo: root.leadingAnchor, constant: Self.paneMargin),
        ])
        // One width for every pane, so switching tabs changes the height and
        // nothing else. A window that also changes width on each click reads
        // as three windows.
        let size = grid.fittingSize
        root.frame = NSRect(
            x: 0, y: 0, width: Self.paneWidth, height: size.height + 2 * Self.paneMargin)

        let controller = NSViewController()
        controller.view = root
        controller.title = title
        controller.preferredContentSize = root.frame.size
        panes.append((controller, grid))
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = Theme.symbol(
            symbol, size: Theme.SymbolSize.settingsTab, description: title)
        tabs.addTabViewItem(item)
    }

    private func bind(_ control: NSControl, _ handler: @escaping () -> Void) {
        let proxy = ActionProxy(handler)
        proxies.append(proxy)
        control.target = proxy
        control.action = #selector(ActionProxy.fire)
    }

    /// A field and stepper bound to an app preference.
    ///
    /// Writes go straight through the preference, which clamps them — so a
    /// control can no more put an out-of-range value into `UserDefaults` than
    /// the profile controls can put one into the profile. Same rule, different
    /// store.
    private func preferenceStepper(_ preference: AppPreferences.Preference<Int>) -> NSControl {
        let field = NSTextField(string: String(preference.value))
        field.formatter = NumberFormatter()
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let stepper = NSStepper()
        stepper.minValue = Double(preference.range.lowerBound)
        stepper.maxValue = Double(preference.range.upperBound)
        stepper.increment = 1
        // NSStepper wraps by default. One click up from 140 characters per
        // line went to 30 and took the window with it, which is not a thing
        // any stepper on this system does.
        stepper.valueWraps = false
        stepper.integerValue = preference.value
        let commit = { [weak field, weak stepper] (value: Int) in
            preference.value = value
            // Read back rather than echo: the preference clamps, and a control
            // showing a value nothing accepted is the bug this avoids.
            field?.stringValue = String(preference.value)
            stepper?.integerValue = preference.value
        }
        bind(field) { commit(field.integerValue) }
        bind(stepper) { commit(stepper.integerValue) }
        return StackControl(numberRow(field, stepper))
    }

    /// A popup of whole percentages. An out-of-list stored value — one typed
    /// straight into `defaults write` — is added to the list rather than
    /// silently snapped to a neighbour, so the popup never lies about what is
    /// in effect.
    private func percentPopup(
        _ preference: AppPreferences.Preference<Int>, _ choices: [Int]
    ) -> NSControl {
        let popup = NSPopUpButton()
        var values = choices
        if !values.contains(preference.value) { values.append(preference.value) }
        values.sort(by: >)
        popup.addItems(withTitles: values.map { "\($0)%" })
        popup.selectItem(at: values.firstIndex(of: preference.value) ?? 0)
        bind(popup) { preference.value = values[popup.indexOfSelectedItem] }
        return popup
    }

    /// Speeds by name rather than a number of seconds. Nobody knows what 0.26
    /// looks like, and everybody knows what "off" means.
    private func drawerSpeedPopup() -> NSControl {
        let popup = NSPopUpButton()
        let choices: [(String, Double)] = [
            ("Off", 0), ("Fast", 0.15), ("Normal", 0.26), ("Slow", 0.5),
        ]
        popup.addItems(withTitles: choices.map(\.0))
        let current = AppPreferences.drawerSeconds.value
        let nearest = choices.enumerated().min {
            abs($0.element.1 - current) < abs($1.element.1 - current)
        }
        popup.selectItem(at: nearest?.offset ?? 2)
        bind(popup) {
            AppPreferences.drawerSeconds.value = choices[popup.indexOfSelectedItem].1
        }
        return popup
    }

    /// Caret shape. Applies live — the view redraws and the run is untouched.
    private func caretPopup() -> NSControl {
        let popup = NSPopUpButton()
        let styles = AppPreferences.CaretStyle.allCases
        popup.addItems(withTitles: styles.map(\.label))
        popup.selectItem(at: styles.firstIndex(of: AppPreferences.caretStyle.value) ?? 0)
        bind(popup) {
            let index = popup.indexOfSelectedItem
            guard index >= 0, index < styles.count else { return }
            AppPreferences.caretStyle.value = styles[index]
        }
        return popup
    }

    /// Whether spaces, tabs and line ends are marked.
    private func whitespaceToggle() -> NSControl {
        let toggle = NSSwitch()
        toggle.state = AppPreferences.showWhitespace.value ? .on : .off
        bind(toggle) { AppPreferences.showWhitespace.value = toggle.state == .on }
        return toggle
    }

    /// The sound packs, by label. Writes immediately rather than on close —
    /// a preview that waited for the window to be dismissed would be useless.
    private func soundPackPopup() -> NSControl {
        let popup = NSPopUpButton()
        let packs = KeySoundPack.all
        popup.addItems(withTitles: packs.map(\.label))
        popup.selectItem(at: packs.firstIndex(of: AppPreferences.soundPack.value) ?? 0)
        bind(popup) { [weak self] in
            let index = popup.indexOfSelectedItem
            guard index >= 0, index < packs.count else { return }
            AppPreferences.soundPack.value = packs[index]
            self?.previewSound()
        }
        return popup
    }

    /// Volume as a slider, because it is a continuous quantity and nobody
    /// thinks about it in numbers. Previews on release rather than on every
    /// intermediate value — a click per pixel of drag is not a preview.
    private func volumeSlider() -> NSControl {
        let slider = NSSlider(
            value: AppPreferences.soundVolume.value,
            minValue: AppPreferences.soundVolume.range.lowerBound,
            maxValue: AppPreferences.soundVolume.range.upperBound,
            target: nil, action: nil)
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        bind(slider) { [weak self] in
            AppPreferences.soundVolume.value = slider.doubleValue
            // `isContinuous` fires throughout the drag; only the mouse-up is
            // worth hearing.
            if NSApp.currentEvent?.type == .leftMouseUp { self?.previewSound() }
        }
        return slider
    }

    /// The global shortcut, as a recorder. Held so nothing else has to know
    /// how it stores itself.
    private func shortcutRecorder() -> NSControl {
        let recorder = ShortcutRecorder(shortcut: AppPreferences.soundShortcut.value)
        recorder.onChange = { shortcut in
            // Writing the preference posts `didChange`, which is what makes
            // the app re-register the hot key and relabel both menus. The
            // recorder itself knows none of that.
            AppPreferences.soundShortcut.value = shortcut
        }
        return recorder
    }

    /// One setting: a right-aligned label, its control, and an optional
    /// caption on the line below.
    ///
    /// Below, not beside. A third column of help text is what made this window
    /// stop looking like a Mac: it pushed the window wide enough to hold the
    /// longest sentence, left a ragged column of grey against a lot of white,
    /// and set the caption at the same size as the label it was subordinate
    /// to. Every settings window Apple ships puts it under the control, small
    /// and grey.
    private func addRow(
        _ grid: NSGridView, _ label: String, _ control: NSControl, hint: String? = nil
    ) {
        let name = NSTextField(labelWithString: "\(label):")
        let row = grid.addRow(with: [name, control])
        row.yPlacement = .center
        row.topPadding = 4
        var owned = [row]

        if let hint {
            let caption = NSTextField(labelWithString: hint)
            caption.font = .preferredFont(forTextStyle: .caption1)
            caption.textColor = Theme.secondaryText
            // One line, and no `preferredMaxLayoutWidth`. Setting it makes the
            // field's intrinsic *height* two lines while the grid still lays
            // it out wide enough for one — so it draws one line and reserves
            // two, and the pane grows a band of white under every caption.
            // Captions here are short enough to fit; the pane is sized to
            // hold them.
            caption.lineBreakMode = .byTruncatingTail
            let captionRow = grid.addRow(with: [NSGridCell.emptyContentView, caption])
            captionRow.topPadding = 1
            captionRow.bottomPadding = 4
            owned.append(captionRow)
        }
        if let key = control.identifier?.rawValue { rows[key] = owned }
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

    /// A bounded number from the profile: field plus stepper, like every other
    /// number in this window. It had only the field, which made the same kind
    /// of value look like two different kinds depending on which pane it was
    /// in.
    private func stepperField(_ key: String) -> NSControl {
        let bounds = SettingsSchema.UIBounds.targetWpm
        let field = NSTextField(string: "")
        field.alignment = .right
        field.formatter = {
            let formatter = NumberFormatter()
            formatter.minimum = NSNumber(value: bounds.lo)
            formatter.maximum = NSNumber(value: bounds.hi)
            formatter.allowsFloats = false
            return formatter
        }()
        field.target = self
        field.action = #selector(changed(_:))
        field.identifier = .init(key)
        // A constraint, not `frame.size`. Inside an autolayout grid the frame
        // is overwritten on the next pass, which is why this field grew to the
        // width of the widest control in the pane.
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        controls[key] = field

        let stepper = NSStepper()
        stepper.minValue = bounds.lo
        stepper.maxValue = bounds.hi
        stepper.increment = 1
        stepper.valueWraps = false
        steppers[key] = stepper
        bind(stepper) { [weak self] in
            field.integerValue = stepper.integerValue
            self?.changed(field)
        }
        return StackControl(numberRow(field, stepper))
    }

    /// A number field with its stepper beside it, spaced the way AppKit spaces
    /// them elsewhere.
    private func numberRow(_ field: NSTextField, _ stepper: NSStepper) -> NSStackView {
        let row = NSStackView(views: [field, stepper])
        row.spacing = 3
        row.alignment = .centerY
        return row
    }

    // MARK: - State

    /// Re-measures each pane after rows have been shown or hidden, so the
    /// window is exactly as tall as what it holds. Without it a pane keeps the
    /// height it was built with and the difference shows as empty space.
    private func resizePanes() {
        for pane in panes {
            pane.controller.preferredContentSize = NSSize(
                width: Self.paneWidth,
                height: pane.grid.fittingSize.height + 2 * Self.paneMargin)
        }
    }

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
        // And the stepper beside it, or it keeps whatever it was built with
        // and the next click jumps the value back there.
        steppers["targetWpm"]?.integerValue = Int(settings.targetWpm)
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
        for row in rows["testDurationSec"] ?? [] { row.isHidden = settings.testMode != .time }
        for row in rows["wordCount"] ?? [] { row.isHidden = settings.testMode != .words }
        resizePanes()
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

/// Target/action as a closure.
///
/// AppKit wants a target object and a selector; these controls want a closure.
/// The window controller keeps the proxies alive, which it can do because it
/// outlives every control in it.
final class ActionProxy: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc func fire() { handler() }
}

/// A stack of controls where AppKit's grid wants a single `NSControl`.
private final class StackControl: NSControl {
    init(_ stack: NSStackView) {
        super.init(frame: .zero)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
