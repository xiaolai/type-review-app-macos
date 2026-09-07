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
    /// Asks the owner to stand the global hot key down while the recorder is
    /// armed, and to put it back afterwards. Carbon hot keys are handled below
    /// the Cocoa event stream, so without this the combination already in use
    /// fires its action instead of being captured — making the one shortcut
    /// you most want to change the one you cannot.
    var suspendHotKey: (Bool) -> Void = { _ in }

    private let tabs = SettingsTabViewController()
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
    /// The warning under "Sound in every app", shown only while the setting
    /// is on and the system is not delivering the events it needs.
    private var permissionLabel: NSTextField?
    private var permissionRows: [NSGridRow] = []
    /// The note under "Start at login". Carries whatever `SMAppService` has to
    /// say — an approval it is still waiting for, or the reason it refused.
    private var loginNoteLabel: NSTextField?
    private var loginNoteRows: [NSGridRow] = []
    /// The last registration error, kept until the next attempt. `status`
    /// alone cannot say why something failed.
    private var loginError: String?
    /// Where the profile lives, resolved once when the Data pane is built.
    private var profileURL: URL?
    private static let lastPaneKey = "SettingsLastPane"
    private static let paneWidth: CGFloat = 500
    private static let paneMargin: CGFloat = 22
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
        // Only when there is nothing to restore. The window has an autosave
        // name, and centring unconditionally on every presentation meant the
        // position it saved was overwritten before anyone could see it.
        if window?.setFrameUsingName("TypeReviewSettings") != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Both settings below can be changed from outside this app — Input
    /// Monitoring in System Settings, the login item under General ▸ Login
    /// Items — so what this window shows has to be re-read on the way back in
    /// rather than trusted from when it was built.
    func windowDidBecomeKey(_ notification: Notification) {
        refreshSoundScope()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(tabs.selectedTabViewItemIndex, forKey: Self.lastPaneKey)
    }

    // MARK: - Building

    /// Assembles the panes. Each is built by its own method: this was one
    /// 107-line function holding four unrelated windows' worth of controls,
    /// with the Data pane's file-store access inline in the middle of it.
    private func build() {
        buildPracticePane()
        buildAppearancePane()
        buildSoundPane()
        buildDataPane()
    }

    private func buildPracticePane() {
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
    }

    private func buildAppearancePane() {
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
    }

    private func buildSoundPane() {
        addPane(title: "Sound", symbol: "speaker.wave.2") { grid in
            self.addRow(
                grid, "Keyboard", self.soundPackPopup(),
                hint: "Heard on every keystroke. Picking one plays it.")
            self.addRow(grid, "Volume", self.volumeSlider())
            self.addRow(
                grid, "Sound in every app", self.globalSoundToggle(),
                hint: "Clicks wherever you type, not only in this window.")
            self.addPermissionRow(grid)
            self.addRow(
                grid, "Modifier keys", self.modifierSoundToggle(),
                hint: "⇧ ⌃ ⌥ ⌘ fn ⇪ click too. A capital stays one sound here.")
            self.addRow(
                grid, "Start at login", self.loginItemToggle(),
                hint: "TYPE waits in the menu bar, ready before you type.")
            self.addLoginNoteRow(grid)
            self.addRow(
                grid, "Shortcut", self.shortcutRecorder(),
                hint: "Works from any app. ⌫ clears it, ⎋ cancels.")
        }
    }

    private func buildDataPane() {
        addPane(title: "Data", symbol: "internaldrive") { grid in
            // Resolved once. The store was constructed three times here — for
            // the label, for the tooltip and again in the reveal action — and
            // each one turned a failure into an empty string, so a store that
            // could not be opened showed a blank path above a button that did
            // nothing when clicked.
            let location = Result { try ProfileFileStore.standard().fileURL }
            let path = NSTextField(labelWithString: "")
            path.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            path.lineBreakMode = .byTruncatingMiddle
            let reveal = NSButton(
                title: "Show in Finder", target: self, action: #selector(self.revealProfile(_:)))
            reveal.bezelStyle = .rounded
            switch location {
            case .success(let url):
                path.stringValue = url.path
                path.textColor = Theme.secondaryText
                path.toolTip = url.path
                self.profileURL = url
            case .failure(let error):
                path.stringValue = "unavailable — \(error.localizedDescription)"
                path.textColor = .systemOrange
                reveal.isEnabled = false
            }
            // A file the user can point at is the difference between "we keep
            // your data safe" and showing them where it is. No web build can
            // offer this.
            // Wider than a caption: middle-truncated to 260 points this read as
            // an abbreviated path that looked more like a wrong one.
            path.preferredMaxLayoutWidth = Self.pathWidth
            path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            path.widthAnchor.constraint(equalToConstant: Self.pathWidth).isActive = true
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
        // A value with no preset gets an item of its own rather than being
        // displayed as the nearest one. 0.01 seconds showed as "Off" while the
        // drawer went on animating — the control reporting a setting the app
        // was not using.
        if let exact = choices.firstIndex(where: { abs($0.1 - current) < 0.0005 }) {
            popup.selectItem(at: exact)
        } else {
            popup.menu?.addItem(.separator())
            popup.addItem(withTitle: String(format: "Custom (%.2fs)", current))
            // Shown, not choosable. Left enabled it could be selected, and the
            // handler ignores it — so picking Normal and then Custom displayed
            // 0.33s over a preference that still said 0.26.
            popup.lastItem?.isEnabled = false
            popup.selectItem(at: popup.numberOfItems - 1)
        }
        bind(popup) {
            let index = popup.indexOfSelectedItem
            // The custom item displays the current value; selecting it is not
            // a change and must not write a preset over it.
            guard index >= 0, index < choices.count else { return }
            AppPreferences.drawerSeconds.value = choices[index].1
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
        // Held so `refreshSoundScope` can put it back in step. The pack can be
        // changed from either menu or from the global shortcut, and this
        // picker was read once at construction — so reopening the retained
        // Settings window showed whatever had been chosen the first time.
        controls["soundPack"] = popup
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

    /// Whether keystrokes are heard in every app.
    ///
    /// Asks for Input Monitoring as part of switching on rather than leaving
    /// it as a second step to discover. Without the permission the monitor
    /// installs cleanly and is never called — the switch would read "on" over
    /// a keyboard that stayed silent.
    private func globalSoundToggle() -> NSControl {
        let toggle = NSSwitch()
        toggle.identifier = .init("globalSound")
        controls["globalSound"] = toggle
        bind(toggle) { [weak self] in
            let on = toggle.state == .on
            if on, !GlobalKeySound.isPermitted { GlobalKeySound.requestPermission() }
            AppPreferences.globalSound.value = on
            self?.refreshSoundScope()
        }
        return toggle
    }

    /// Whether the modifier keys click.
    ///
    /// One switch rather than six. "Should shift click?" has one answer per
    /// person, not one per key, and a six-row matrix would be handing the
    /// design decision back to the user.
    private func modifierSoundToggle() -> NSControl {
        let toggle = NSSwitch()
        toggle.identifier = .init("modifierSound")
        controls["modifierSound"] = toggle
        bind(toggle) { [weak self] in
            AppPreferences.modifierSound.value = toggle.state == .on
            self?.refreshSoundScope()
        }
        return toggle
    }

    /// Whether TYPE starts with the Mac.
    ///
    /// Reads `SMAppService` rather than a preference of its own: the user can
    /// revoke this in System Settings, and a mirrored copy would go on saying
    /// the app starts at login after they had turned it off.
    private func loginItemToggle() -> NSControl {
        let toggle = NSSwitch()
        toggle.identifier = .init("loginItem")
        controls["loginItem"] = toggle
        bind(toggle) { [weak self] in
            do {
                self?.loginError = nil
                try LoginItem.setEnabled(toggle.state == .on)
            } catch {
                self?.loginError = error.localizedDescription
            }
            self?.refreshSoundScope()
        }
        return toggle
    }

    /// A caption-and-button row, hidden until it has something to say.
    ///
    /// Built once and shown or hidden, because a row added and removed would
    /// re-order the pane under the pointer. Written twice before — the Input
    /// Monitoring warning and the login-item note differed only in their
    /// button — which is two copies of the same styling to keep in step.
    private func addStatusRow(
        _ grid: NSGridView, button title: String, action: Selector
    ) -> (label: NSTextField, row: NSGridRow) {
        let label = NSTextField(labelWithString: "")
        label.font = .preferredFont(forTextStyle: .caption1)
        // The system's own warning colour rather than red: these are settings
        // that are not doing anything yet, not errors.
        label.textColor = .systemOrange
        label.lineBreakMode = .byTruncatingTail
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        let stack = NSStackView(views: [label, button])
        stack.spacing = 8
        stack.alignment = .centerY
        let row = grid.addRow(with: [NSGridCell.emptyContentView, stack])
        row.topPadding = 1
        row.bottomPadding = 4
        return (label, row)
    }

    private func addPermissionRow(_ grid: NSGridView) {
        let made = addStatusRow(
            grid, button: "Allow…", action: #selector(openInputMonitoringSettings(_:)))
        permissionLabel = made.label
        permissionRows = [made.row]
    }

    private func addLoginNoteRow(_ grid: NSGridView) {
        let made = addStatusRow(
            grid, button: "Login Items…", action: #selector(openLoginItemsSettings(_:)))
        loginNoteLabel = made.label
        loginNoteRows = [made.row]
    }

    /// Re-reads the two settings the system owns, and shows or hides the two
    /// rows that only exist when something is in the way.
    private func refreshSoundScope() {
        if let popup = controls["soundPack"] as? NSPopUpButton {
            popup.selectItem(at: KeySoundPack.all.firstIndex(of: AppPreferences.soundPack.value) ?? 0)
        }
        let global = AppPreferences.globalSound.value
        (controls["globalSound"] as? NSSwitch)?.state = global ? .on : .off
        (controls["modifierSound"] as? NSSwitch)?.state =
            AppPreferences.modifierSound.value ? .on : .off
        // Modifiers are only heard through the system-wide monitor, so the row
        // means nothing while that is off — disabled rather than hidden, so it
        // does not appear and disappear as the switch above it is used.
        (controls["modifierSound"] as? NSSwitch)?.isEnabled = global
        let blocked = global && !GlobalKeySound.isPermitted
        permissionLabel?.stringValue = "Input Monitoring is off — other apps are not heard."
        for row in permissionRows { row.isHidden = !blocked }

        // Awaiting approval counts as on. It is a registration the user has
        // asked for, so showing it off invited a second `register()` — and
        // left no way to cancel the pending one, because switching an
        // already-off switch off does nothing.
        (controls["loginItem"] as? NSSwitch)?.state = LoginItem.isRequested ? .on : .off
        let note = loginNote
        loginNoteLabel?.stringValue = note ?? ""
        for row in loginNoteRows { row.isHidden = note == nil }

        resizePanes()
    }

    /// What, if anything, stands between the switch and the app actually
    /// starting at login.
    ///
    /// Only two things qualify: an approval macOS is waiting for, and a
    /// refusal it actually gave. Not `.notFound` — which reads like "this app
    /// is missing" and is in fact what `SMAppService` reports for a main app
    /// that has simply never been registered. Showing it turned the ordinary
    /// off state into a warning that TYPE could not be registered at all,
    /// under a switch that then registered it on the first click.
    private var loginNote: String? {
        if let loginError { return loginError }
        return LoginItem.status == .requiresApproval
            ? "Waiting for your approval in System Settings." : nil
    }

    /// Asks, then opens the pane.
    ///
    /// The request is what puts TYPE into the Input Monitoring list in the
    /// first place. Sending someone straight to that pane before the app has
    /// ever asked lands them in a list TYPE is not in, with nothing to switch
    /// on and no hint that the `+` button is the way through.
    @objc private func openInputMonitoringSettings(_ sender: Any?) {
        GlobalKeySound.requestPermission()
        GlobalKeySound.openPermissionSettings()
    }

    @objc private func openLoginItemsSettings(_ sender: Any?) {
        LoginItem.openSettings()
    }

    /// The global shortcut, as a recorder. Held so nothing else has to know
    /// how it stores itself.
    private func shortcutRecorder() -> NSControl {
        let recorder = ShortcutRecorder(shortcut: AppPreferences.soundShortcut.value)
        recorder.onRecordingChanged = { [weak self] recording in self?.suspendHotKey(recording) }
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

    /// A number field with its stepper, drawn as one control.
    ///
    /// Two fixes to what AppKit gives you by default, both visible in a
    /// screenshot. The stepper sat three points clear of the field, which made
    /// the value and the thing that changes it read as two separate controls
    /// that happened to be adjacent. And `NSStepper` is intrinsically taller
    /// than `NSTextField` at the same control size, so it stood proud of the
    /// field above and below — the row looked misaligned rather than paired.
    ///
    /// Flush, and pinned to the field's height, so it reads as one input with
    /// its own increment control.
    private func numberRow(_ field: NSTextField, _ stepper: NSStepper) -> NSStackView {
        let row = NSStackView(views: [field, stepper])
        row.spacing = 0
        row.alignment = .centerY
        stepper.heightAnchor.constraint(equalTo: field.heightAnchor).isActive = true
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
        // Not `Int(…)`. The validator allows fractions, so 50.9 was shown as
        // 50 and the next edit would have written that back — the display
        // quietly rounding a value the user had set.
        controls["targetWpm"]?.stringValue = settings.targetWpm == settings.targetWpm.rounded()
            ? String(Int(settings.targetWpm)) : String(settings.targetWpm)
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
        refreshSoundScope()
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
        // Reported like any other edit. This discarded the result, so a reset
        // the engine refused looked exactly like one it accepted.
        if !write(.default) { NSSound.beep() }
        refresh()
    }

    @objc private func revealProfile(_ sender: Any?) {
        // Resolved when the pane was built; the button is disabled when there
        // is nothing to reveal, so this cannot silently do nothing.
        guard let profileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([profileURL])
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

/// The tab controller, with the window resize animated to match the crossfade.
///
/// The panes are different heights — Practice is 554 points tall and Data is
/// 188 — so switching tabs changes the window's height by up to 366. AppKit
/// crossfades the *views* for you and snaps the *window* to its new size in
/// one frame, and the two together read as a flash rather than as a
/// transition: the content dissolves politely inside a window that has already
/// jumped.
///
/// Animating the frame over the same duration is what makes it one movement.
/// The top edge is pinned, because a settings window that grows from its
/// title bar downward is what every other one on the system does — letting
/// macOS keep the bottom edge instead would walk the title bar up the screen
/// on every click.
final class SettingsTabViewController: NSTabViewController {
    /// Matched to the crossfade AppKit runs for `.crossfade`, so neither
    /// finishes visibly before the other.
    private static let duration: TimeInterval = 0.2

    override func transition(
        from fromViewController: NSViewController, to toViewController: NSViewController,
        options: NSViewController.TransitionOptions = [],
        // `@Sendable` to match what AppKit declares. Without it every call to
        // `super` warns about handing a non-Sendable closure to a Sendable
        // parameter — the override is the place to state the contract, not
        // three call sites downstream.
        completionHandler completion: (@Sendable () -> Void)? = nil
    ) {
        guard let window = view.window else {
            super.transition(
                from: fromViewController, to: toViewController, options: options,
                completionHandler: completion)
            return
        }

        let target = toViewController.preferredContentSize
        guard target.height > 0 else {
            super.transition(
                from: fromViewController, to: toViewController, options: options,
                completionHandler: completion)
            return
        }
        let content = window.contentRect(forFrameRect: window.frame)
        var frame = window.frameRect(
            forContentRect: NSRect(origin: content.origin, size: target))
        frame.origin.y = window.frame.maxY - frame.height

        // Order depends on the direction, and getting it wrong is visible.
        //
        // Both panes are in the view hierarchy while the crossfade runs, so
        // the window cannot shrink below the taller one: animating a shrink
        // first ran the window down to the new height and then let it snap
        // straight back to the old one — measurably, 554 → 191 → 554. Growing
        // has no such conflict.
        //
        // So: grow before the crossfade, shrink after it. Either way the
        // window is never asked to be smaller than what it currently holds.
        let isGrowing = frame.height >= window.frame.height
        if isGrowing { animate(to: frame) }
        // Only Sendable values cross into the completion handler — a `CGRect`,
        // a `Bool`, and `self` weakly. Capturing a local closure there is what
        // the compiler objects to, and rightly.
        super.transition(
            from: fromViewController, to: toViewController, options: options
        ) { [weak self] in
            MainActor.assumeIsolated {
                if !isGrowing { self?.animate(to: frame) }
                completion?()
            }
        }
    }

    private func animate(to frame: NSRect) {
        guard let window = view.window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }
}
