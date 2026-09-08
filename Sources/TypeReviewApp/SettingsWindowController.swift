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
    /// Says which voice is now in effect, in that voice. A voice picker that
    /// made no sound would be asking the user to choose from 180 names.
    var previewSpeech: () -> Void = {}
    /// Asks the owner to stand the global hot key down while the recorder is
    /// armed, and to put it back afterwards. Carbon hot keys are handled below
    /// the Cocoa event stream, so without this the combination already in use
    /// fires its action instead of being captured — making the one shortcut
    /// you most want to change the one you cannot.
    var suspendHotKey: (Bool) -> Void = { _ in }
    /// Told when the profile on disk has been replaced, so the running session
    /// stops saving a copy that is now older than the file.
    var profileReplaced: (String) -> Void = { _ in }
    /// Lets the next start ask for Input Monitoring again. Switching the
    /// setting on is a deliberate act, and the monitor's once-per-run latch is
    /// there to stop the *app* nagging, not to ignore a control being pressed.
    var askForKeyPermission: () -> Void = {}

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
    /// The "Allow…" button, hidden when the row is explaining something a
    /// button cannot fix.
    private var permissionButton: NSButton?
    private var permissionRows: [NSGridRow] = []
    /// The note under "Start at login". Carries whatever `SMAppService` has to
    /// say — an approval it is still waiting for, or the reason it refused.
    private var loginNoteLabel: NSTextField?
    private var loginNoteRows: [NSGridRow] = []
    /// The last registration error, kept until the next attempt. `status`
    /// alone cannot say why something failed.
    private var loginError: String?
    private weak var mutedApps: MutedAppsList?
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
        // Four things AppKit will not do for a hand-rolled settings window,
        // each silent when omitted: the default collectionBehavior is 0, and
        // without .auxiliary this window displaces the main one in Stage
        // Manager; tabbingMode defaults to .automatic, and this window has been
        // seen absorbed into another window's tab group; the frame is not
        // remembered without an autosave name; and the last-viewed pane is not
        // restored, which the HIG asks for.
        window.collectionBehavior = [.auxiliary, .fullScreenNone]
        window.tabbingMode = .disallowed
        // No transition options, deliberately. `SettingsTabViewController`
        // swaps the panes with no animation and then fades the arriving one
        // itself, in the same animation group as the height — see the note
        // there for what AppKit's own crossfade costs on a pane that shrinks.
        tabs.transitionOptions = []
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

    /// How many panes were built. Read by `--selftest`, which constructs this
    /// window to prove every pane lays out — including the voice picker, whose
    /// menu is assembled from whatever voices the machine happens to have.
    var paneCount: Int { panes.count }

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
        // Voices are installed and removed in System Settings, which is the
        // third thing that can change behind this window's back. The menu was
        // built once at construction and this controller is retained, so a
        // voice downloaded while it was open never appeared and a removed one
        // stayed selectable.
        refreshVoiceMenu()
        // The login item is the other thing System Settings can change behind
        // this window's back, and it lives in General. Refreshing only Sound
        // left that row showing what it read when the window opened.
        refreshGeneralPane()
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
        buildGeneralPane()
        buildDataPane()
        buildAboutPane()
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
            // Above the system-wide rows rather than below them: everything
            // from here down is about the keystroke click in other
            // applications, and this is not that. The volume it follows is the
            // one immediately above it.
            self.addRow(
                grid, "Speak words", self.speakWordsToggle(),
                hint: "A word is read aloud when it is finished and correct. "
                    + "Not in code or generated drills.")
            self.addRow(
                grid, "Voice", self.speechVoicePopup(),
                hint: "Automatic follows the language of the text. Picking one says its name.")
            self.addRow(
                grid, "Sound in every app", self.globalSoundToggle(),
                hint: "Clicks wherever you type, not only in this window.")
            self.addPermissionRow(grid)
            self.addRow(
                grid, "Modifier keys", self.modifierSoundToggle(),
                hint: "⇧ ⌃ ⌥ ⌘ fn ⇪ click too. A capital stays one sound here.")
            self.addRow(
                grid, "Key release", self.releaseSoundToggle(),
                hint: "Keys are heard coming back up. Recorded packs have none.")
            self.addRow(
                grid, "Silent in", self.mutedAppsControl(),
                hint: "Password managers are never watched. Password fields never sound.")
            // Here rather than under Statistics because it needs the same
            // Input Monitoring permission and the same tap as the row above,
            // and the two exclusions named in that hint apply to it exactly.
            self.addRow(
                grid, "Count keystrokes", self.countKeystrokesToggle(),
                hint: "A daily total of keys pressed in any app, for the Statistics grid. "
                    + "A number per day and nothing else — no times, no which keys, no app "
                    + "names. Kept on this Mac, never sent anywhere.")
            self.addRow(
                grid, "", self.eraseKeystrokesButton(),
                hint: "Deletes the daily totals. Practice history is untouched.")
            self.addRow(
                grid, "Shortcut", self.shortcutRecorder(AppPreferences.soundShortcut),
                hint: "Works from any app. ⌫ clears it, ⎋ cancels.")
        }
    }

    /// How TYPE starts and where it lives on the Mac.
    ///
    /// Fourth rather than first, against the usual habit of putting General at
    /// the front. The first pane is the one Settings opens on, and that should
    /// stay Practice — the reason people come here. A convention about
    /// ordering is not worth a worse landing.
    ///
    /// "Start at login" moved here from Sound, where it had been put because
    /// system-wide keystroke sound was the reason it was added. That was
    /// filing it by motive rather than by what it is, and it cost exactly what
    /// you would expect: it was asked for again by someone who had the
    /// Settings window open.
    private func buildGeneralPane() {
        addPane(title: "General", symbol: "gearshape") { grid in
            self.addRow(
                grid, "Start at login", self.loginItemToggle(),
                hint: "TYPE waits in the menu bar, ready before you type.")
            self.addLoginNoteRow(grid)
            self.addRow(
                grid, "Start in the menu bar", self.startInMenuBarToggle(),
                hint: "Only for launches you start. Opening TYPE again brings the window back.")
            self.addRow(
                grid, "Show in Dock", self.showInDockToggle(),
                hint: "Off takes the menu bar with it — macOS ties the two.")
            // Last, and directly under the Dock row, because it answers the
            // question that setting raises: with no Dock tile there is no
            // ⌘-Tab entry either, and this is the way back that does not
            // involve aiming at a small icon.
            self.addRow(
                grid, "Show TYPE", self.shortcutRecorder(AppPreferences.summonShortcut),
                hint: "Brings the window up from any app, and puts it away again.")
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
            let importButton = NSButton(
                title: "Import…", target: self, action: #selector(self.importProfile(_:)))
            importButton.bezelStyle = .rounded
            // Beside Show in Finder rather than anywhere else, because the two
            // are the same idea from opposite ends: one hands the file over,
            // the other takes one back. Moving between the App Store build and
            // the direct one is the case that needs it — they are different
            // applications to the system and cannot read each other's storage.
            let buttons = NSStackView(views: [reveal, importButton])
            buttons.spacing = 8
            let revealRow = grid.addRow(with: [NSGridCell.emptyContentView, buttons])
            revealRow.topPadding = 10
        }
    }

    /// Who made this and what it stands on.
    ///
    /// Last, where an About belongs. Its content is one block rather than a
    /// column of label-and-control rows, so the row spans both columns —
    /// merged, or the centred block would sit in the right-hand column with
    /// the label column's width empty beside it.
    private func buildAboutPane() {
        addPane(title: "About", symbol: "info.circle") { grid in
            let content = AboutPane.makeContent()
            let row = grid.addRow(with: [content])
            row.mergeCells(in: NSRange(location: 0, length: 2))
            grid.cell(for: content)?.xPlacement = .center
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
        // And the mask has to say so, which it did not. The default is `.none`,
        // so the pane kept the frame it was built with while the window
        // animated to a different height around it. Anchored at the bottom
        // left with a fixed height, its top edge — the edge every row hangs
        // from — slid out of the window and snapped back when layout next ran.
        // That shudder was the tab switch's, and it was this.
        root.autoresizingMask = [.width, .height]
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
        //
        // Laid out first, for the reason `resizePanes` gives: an unlaid-out
        // wrapping label reports a single line's height, so a pane containing
        // prose is built too short and corrects itself later, visibly.
        grid.layoutSubtreeIfNeeded()
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
        let toggle = checkbox()
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

    /// Whether a finished word is read aloud.
    ///
    /// No permission to ask for and no preview to play: this speaks the
    /// passage being typed, and there is nothing to demonstrate without one.
    private func speakWordsToggle() -> NSControl {
        let toggle = checkbox()
        toggle.state = AppPreferences.speakWords.value ? .on : .off
        bind(toggle) { AppPreferences.speakWords.value = toggle.state == .on }
        return toggle
    }

    /// Rebuilds the voice menu against the voices installed right now, keeping
    /// the selection by identifier. Silent: rebuilding is not choosing, so it
    /// must not fire the preview.
    private func refreshVoiceMenu() {
        guard let popup = controls["speechVoice"] as? NSPopUpButton else { return }
        let action = popup.action
        popup.action = nil
        populateVoices(popup)
        popup.action = action
    }

    /// Which voice reads the words.
    ///
    /// Grouped by language rather than listed flat: this machine offers 180
    /// voices across 49 languages, and a flat popup of 180 is a list you scroll
    /// past rather than choose from. The languages the user actually reads come
    /// first, so the common case is at the top.
    ///
    /// The identifier travels in `representedObject`, never the title. Four of
    /// the voices installed here are called Eddy, and the title is localised.
    private func speechVoicePopup() -> NSControl {
        let popup = NSPopUpButton()
        populateVoices(popup)
        controls["speechVoice"] = popup
        bind(popup) { [weak self] in
            AppPreferences.speechVoice.value =
                popup.selectedItem?.representedObject as? String ?? ""
            self?.previewSpeech()
        }
        return popup
    }

    private func populateVoices(_ popup: NSPopUpButton) {
        let menu = NSMenu()
        // Headers are items that cannot be picked, which only holds with
        // automatic enabling switched off — left on, AppKit enables everything
        // it can find a target for and the language names become choosable.
        menu.autoenablesItems = false
        let automatic = NSMenuItem(title: "Automatic", action: nil, keyEquivalent: "")
        automatic.representedObject = ""
        automatic.isEnabled = true
        menu.addItem(automatic)

        let current = AppPreferences.speechVoice.value
        var chosen: NSMenuItem?
        for group in SpeechVoices.grouped() {
            menu.addItem(.separator())
            let header = NSMenuItem(title: group.language, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for voice in group.voices {
                let item = NSMenuItem(title: voice.name, action: nil, keyEquivalent: "")
                item.representedObject = voice.identifier
                item.indentationLevel = 1
                item.isEnabled = true
                menu.addItem(item)
                if voice.identifier == current { chosen = item }
            }
        }
        popup.menu = menu
        // Falls back to Automatic when the stored identifier names a voice this
        // machine no longer has — the same answer the player gives, so the
        // control cannot claim a voice that is not being used.
        popup.select(chosen ?? automatic)
    }

    /// Whether keystrokes are heard in every app.
    ///
    /// Asks for Input Monitoring as part of switching on rather than leaving
    /// it as a second step to discover. Without the permission the monitor
    /// installs cleanly and is never called — the box would read ticked over
    /// a keyboard that stayed silent.
    private func globalSoundToggle() -> NSControl {
        let toggle = checkbox()
        toggle.identifier = .init("globalSound")
        controls["globalSound"] = toggle
        bind(toggle) { [weak self] in
            let on = toggle.state == .on
            if on { self?.askForKeyPermission() }
            AppPreferences.globalSound.value = on
            self?.refreshSoundScope()
        }
        return toggle
    }

    /// Whether keys pressed anywhere are counted.
    ///
    /// A separate switch from the keyboard sound, though they share a tap and
    /// a permission. Tying it to the sound would have meant counting only
    /// while the sound was on, and a grid with gaps wherever somebody had
    /// muted their keyboard looks exactly like days they did not type.
    private func countKeystrokesToggle() -> NSControl {
        let toggle = checkbox()
        toggle.identifier = .init("countKeystrokes")
        controls["countKeystrokes"] = toggle
        bind(toggle) { [weak self] in
            let on = toggle.state == .on
            if on { self?.askForKeyPermission() }
            AppPreferences.countKeystrokes.value = on
            self?.refreshSoundScope()
        }
        return toggle
    }

    /// Throws away the counts, and says so plainly first.
    ///
    /// A confirmation because it cannot be undone and the data cannot be
    /// reconstructed — there is nowhere else it exists.
    private func eraseKeystrokesButton() -> NSControl {
        let button = NSButton(
            title: "Erase keystroke counts", target: self, action: #selector(eraseKeystrokes))
        button.bezelStyle = .rounded
        button.controlSize = .small
        controls["eraseKeystrokes"] = button
        return button
    }

    @objc private func eraseKeystrokes() {
        let alert = NSAlert()
        alert.messageText = "Erase the keystroke counts?"
        alert.informativeText =
            "The daily totals of keys pressed will be deleted from this Mac. Your practice "
            + "history and statistics are not affected. This cannot be undone."
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        (NSApp.delegate as? AppDelegate)?.keystrokes?.erase()
    }

    /// Whether the modifier keys click.
    ///
    /// One box rather than six. "Should shift click?" has one answer per
    /// person, not one per key, and a six-row matrix would be handing the
    /// design decision back to the user.
    private func modifierSoundToggle() -> NSControl {
        let toggle = checkbox()
        toggle.identifier = .init("modifierSound")
        controls["modifierSound"] = toggle
        bind(toggle) { [weak self] in
            AppPreferences.modifierSound.value = toggle.state == .on
            self?.refreshSoundScope()
        }
        return toggle
    }

    /// The applications the keyboard stays silent in.
    ///
    /// Held so the pane can re-read it: the same list is edited from the menu
    /// bar, which is where most entries will come from.
    private func mutedAppsControl() -> NSControl {
        let list = MutedAppsList()
        mutedApps = list
        return StackControl(NSStackView(views: [list]))
    }

    /// Whether TYPE starts with the Mac.
    ///
    /// Reads `SMAppService` rather than a preference of its own: the user can
    /// revoke this in System Settings, and a mirrored copy would go on saying
    /// the app starts at login after they had turned it off.
    private func startInMenuBarToggle() -> NSControl {
        let toggle = checkbox()
        toggle.identifier = .init("startInMenuBar")
        controls["startInMenuBar"] = toggle
        bind(toggle) { AppPreferences.startInMenuBar.value = toggle.state == .on }
        return toggle
    }

    /// Stated positively, matching the preference. A box labelled for the
    /// thing it removes is read wrong by half the people who see it.
    private func showInDockToggle() -> NSControl {
        let toggle = checkbox()
        toggle.identifier = .init("showInDock")
        controls["showInDock"] = toggle
        // No work here beyond the write: the app delegate watches this
        // preference and reconciles the activation policy, so the Dock tile
        // appears and disappears while the window stays where it is.
        bind(toggle) { AppPreferences.showInDock.value = toggle.state == .on }
        return toggle
    }

    /// Whether a key is heard coming back up.
    ///
    /// Not disabled with the scope switch above it, unlike "Modifier keys":
    /// releases sound in the practice window as well, so this one means
    /// something whether or not the system-wide monitor is running.
    private func releaseSoundToggle() -> NSControl {
        let toggle = checkbox()
        toggle.identifier = .init("releaseSound")
        controls["releaseSound"] = toggle
        bind(toggle) { [weak self] in
            AppPreferences.releaseSound.value = toggle.state == .on
            self?.refreshSoundScope()
        }
        return toggle
    }

    private func loginItemToggle() -> NSControl {
        let toggle = checkbox()
        toggle.identifier = .init("loginItem")
        controls["loginItem"] = toggle
        bind(toggle) { [weak self] in
            do {
                self?.loginError = nil
                try LoginItem.setEnabled(toggle.state == .on)
            } catch {
                self?.loginError = error.localizedDescription
            }
            self?.refreshGeneralPane()
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
    ) -> (label: NSTextField, button: NSButton, row: NSGridRow) {
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
        return (label, button, row)
    }

    private func addPermissionRow(_ grid: NSGridView) {
        let made = addStatusRow(
            grid, button: "Allow…", action: #selector(openInputMonitoringSettings(_:)))
        permissionLabel = made.label
        permissionButton = made.button
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
        (controls["globalSound"] as? NSButton)?.state = global ? .on : .off
        let counting = AppPreferences.countKeystrokes.value
        (controls["countKeystrokes"] as? NSButton)?.state = counting ? .on : .off
        // Nothing to erase is not an error, but a live button that does
        // nothing is worse than a dim one that explains itself.
        (controls["eraseKeystrokes"] as? NSButton)?.isEnabled =
            (NSApp.delegate as? AppDelegate)?.keystrokes?.isEmpty == false
        (controls["modifierSound"] as? NSButton)?.state =
            AppPreferences.modifierSound.value ? .on : .off
        // Modifiers are only heard through the system-wide monitor, so the row
        // means nothing while that is off — disabled rather than hidden, so it
        // does not appear and disappear as the box above it is used.
        (controls["modifierSound"] as? NSButton)?.isEnabled = global
        (controls["releaseSound"] as? NSButton)?.state =
            AppPreferences.releaseSound.value ? .on : .off
        mutedApps?.reload()
        // Two reasons the setting can be on while nothing is heard, and one
        // row to say either. The permission comes first when both apply: it is
        // the one with a button that fixes it, and the other install being
        // open is the more obvious of the two to a person looking at their own
        // screen.
        let unpermitted = global && !GlobalKeySound.isPermitted
        let conflicted = global && !unpermitted && Channel.shouldYieldToSibling
        if unpermitted {
            permissionLabel?.stringValue = "Input Monitoring is off — other apps are not heard."
        } else if conflicted {
            permissionLabel?.stringValue =
                "Another copy of TYPE started first — only it is heard."
        }
        permissionButton?.isHidden = !unpermitted
        for row in permissionRows { row.isHidden = !(unpermitted || conflicted) }

        resizePanes()
    }

    /// The General pane's live state.
    ///
    /// Split from `refreshSoundScope` when the login item moved out of Sound.
    /// Both end in `resizePanes()`, which is idempotent — `refresh()` calling
    /// it twice costs one extra grid measurement, and is worth more than a
    /// direct caller that forgets it and leaves a pane the wrong height.
    private func refreshGeneralPane() {
        // Awaiting approval counts as on. It is a registration the user has
        // asked for, so showing it off invited a second `register()` — and
        // left no way to cancel the pending one, because unticking an
        // already-unticked box does nothing.
        (controls["loginItem"] as? NSButton)?.state = LoginItem.isRequested ? .on : .off
        (controls["startInMenuBar"] as? NSButton)?.state =
            AppPreferences.startInMenuBar.value ? .on : .off
        (controls["showInDock"] as? NSButton)?.state =
            AppPreferences.showInDock.value ? .on : .off
        let note = loginNote
        loginNoteLabel?.stringValue = note ?? ""
        for row in loginNoteRows { row.isHidden = note == nil }

        resizePanes()
    }

    /// What, if anything, stands between the box and the app actually
    /// starting at login.
    ///
    /// Only two things qualify: an approval macOS is waiting for, and a
    /// refusal it actually gave. Not `.notFound` — which reads like "this app
    /// is missing" and is in fact what `SMAppService` reports for a main app
    /// that has simply never been registered. Showing it turned the ordinary
    /// off state into a warning that TYPE could not be registered at all,
    /// under a box that then registered it on the first click.
    private var loginNote: String? {
        if let loginError { return loginError }
        return LoginItem.status == .requiresApproval
            ? "Waiting for your approval in System Settings." : nil
    }

    /// Asks, then opens the pane.
    ///
    /// Asking is what shows macOS's own prompt, which carries an "Open System
    /// Settings" button of its own and is the path most people will take. The
    /// pane is opened as well for anyone who has already answered once, since
    /// the prompt is shown only the first time a process asks.
    @objc private func openInputMonitoringSettings(_ sender: Any?) {
        GlobalKeySound.requestPermission()
        GlobalKeySound.openPermissionSettings()
    }

    @objc private func openLoginItemsSettings(_ sender: Any?) {
        LoginItem.openSettings()
    }

    /// The global shortcut, as a recorder. Held so nothing else has to know
    /// how it stores itself.
    /// One recorder, told which preference it edits.
    ///
    /// The struct is captured by value and its setter is `nonmutating`, so
    /// the closure writes through to `UserDefaults` rather than to a copy.
    private func shortcutRecorder(_ preference: AppPreferences.ShortcutPreference) -> NSControl {
        let recorder = ShortcutRecorder(shortcut: preference.value)
        recorder.onRecordingChanged = { [weak self] recording in self?.suspendHotKey(recording) }
        recorder.onChange = { shortcut in
            // Writing the preference posts `didChange`, which is what makes
            // the app re-register the hot key and relabel both menus. The
            // recorder itself knows none of that.
            preference.value = shortcut
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

    /// The window's boolean control.
    ///
    /// A checkbox rather than `NSSwitch`. `NSSwitch` has exactly one size on
    /// macOS 26 — it accepts `controlSize` and ignores it, measuring 54×24 for
    /// all four values — and fifty-four points of width for a boolean is a lot
    /// in a pane whose other controls are popups. A checkbox is sixteen.
    ///
    /// No title, because the label belongs in the grid's left column with
    /// every other row's. A checkbox carrying its own text would drop out of
    /// that column, and the right-aligned label axis is the one thing holding
    /// these panes together.
    private func checkbox() -> NSButton {
        NSButton(checkboxWithTitle: "", target: nil, action: nil)
    }

    private func toggle(_ key: String) -> NSControl {
        let control = checkbox()
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
            // Lay out before measuring. `fittingSize` asks each subview how
            // tall it wants to be, and a wrapping label answers "one line"
            // until layout has told it how wide it is — the About pane
            // measured 348 points before layout and 461 after, and the window
            // was sized to the first number and then to the second. That
            // 113-point correction is the jump.
            pane.grid.layoutSubtreeIfNeeded()
            let size = NSSize(
                width: Self.paneWidth,
                height: pane.grid.fittingSize.height + 2 * Self.paneMargin)
            // Only on a real change. Writing `preferredContentSize` makes the
            // tab controller resize the window immediately and without
            // animation, so an identical value still cost a snap — and this
            // runs on `windowDidBecomeKey`, which is exactly what clicking a
            // tab in an unfocused window fires just before the transition.
            guard pane.controller.preferredContentSize != size else { continue }
            pane.controller.preferredContentSize = size
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
        (controls["stopOnError"] as? NSButton)?.state = settings.stopOnError ? .on : .off
        (controls["noBackspace"] as? NSButton)?.state = settings.noBackspace ? .on : .off
        (controls["includeNumbers"] as? NSButton)?.state = settings.includeNumbers ? .on : .off
        (controls["includePunctuation"] as? NSButton)?.state =
            settings.includePunctuation ? .on : .off

        // The duration row only means something in time mode, and the word
        // count only in word mode.
        for row in rows["testDurationSec"] ?? [] { row.isHidden = settings.testMode != .time }
        for row in rows["wordCount"] ?? [] { row.isHidden = settings.testMode != .words }
        refreshSoundScope()
        refreshGeneralPane()
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
        case "stopOnError": settings.stopOnError = (sender as? NSButton)?.state == .on
        case "noBackspace": settings.noBackspace = (sender as? NSButton)?.state == .on
        case "includeNumbers": settings.includeNumbers = (sender as? NSButton)?.state == .on
        case "includePunctuation": settings.includePunctuation = (sender as? NSButton)?.state == .on
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

    /// Replaces the profile with one from a file.
    ///
    /// Validated through the same deserializer the app loads with, so a file
    /// edited by hand or truncated by a crash is refused here rather than
    /// becoming statistics that cannot be computed later. The reason shown is
    /// the validator's own, which is more specific than anything this method
    /// could invent.
    ///
    /// The old profile is renamed, never deleted. "Replace" is the one word in
    /// this window that can lose a year of someone's history, and a rename
    /// costs nothing.
    @objc private func importProfile(_ sender: Any?) {
        let store: ProfileFileStore
        do {
            store = try ProfileFileStore.standard()
        } catch {
            // Swallowed with `try?` before, which left an enabled button that
            // did nothing at all — the worst of the three possible behaviours.
            present(error: "The profile store is unavailable.", detail: error.localizedDescription)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose a profile.json to replace the current one."
        guard panel.runModal() == .OK, let source = panel.url else { return }

        let text: String
        do {
            text = try String(contentsOf: source, encoding: .utf8)
        } catch {
            present(error: "That file could not be read.", detail: error.localizedDescription)
            return
        }
        let incoming: Profile
        switch deserializeProfile(text) {
        case .ok(let profile): incoming = profile
        case .corrupt(let reason):
            present(error: "That is not a profile TYPE can read.", detail: reason)
            return
        default:
            present(error: "That file holds no profile.", detail: "It parsed, but there was nothing in it.")
            return
        }

        let existing = store.load()
        let losing: String
        if case .ok(let current) = existing {
            losing = "The \(current.results.count) run\(current.results.count == 1 ? "" : "s") "
                + "already here will be kept in a file beside it."
        } else {
            losing = "There is nothing here to replace."
        }
        let confirm = NSAlert()
        confirm.messageText = "Replace this profile with \(incoming.results.count) imported runs?"
        confirm.informativeText = losing
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Replace")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        // Copy the old one aside, write the new one beside it, then swap. The
        // first attempt renamed the original out of the way and wrote in its
        // place, which meant a failed write left *no* profile — and the next
        // launch would read that as a clean first run, losing the history the
        // rename existed to protect. Restoring on failure patched that; this
        // removes it, because the original never leaves its own path until a
        // complete replacement is already on disk.
        let folder = store.fileURL.deletingLastPathComponent()
        var kept: URL?
        if FileManager.default.fileExists(atPath: store.fileURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let destination = folder.appendingPathComponent("profile-replaced-\(stamp).json")
            do {
                try FileManager.default.copyItem(at: store.fileURL, to: destination)
                kept = destination
            } catch {
                present(
                    error: "The current profile could not be copied aside.",
                    detail: error.localizedDescription + " Nothing was changed.")
                return
            }
        }
        // Through the store, not around it. Writing the bytes here by hand was
        // atomic but not durable: `writeDurably` does the temp-file-and-rename
        // *and* an `F_FULLFSYNC`, which is the difference between surviving a
        // crash and surviving the power going out. Replacing the store's write
        // path with a hand-rolled one quietly dropped half of that.
        //
        // Failure is safe because the copy above already exists and the store
        // only renames its temp file over the original once the write
        // succeeded — so the profile on disk is either the old one or the new
        // one, never neither.
        do {
            try store.save(incoming)
        } catch {
            present(
                error: "The imported profile could not be written.",
                detail: error.localizedDescription
                    + (kept == nil ? " Nothing was changed." : " The existing profile is intact."))
            return
        }
        profileReplaced("imported profile — reopen TYPE before this session saves")

        // Every view that shows history read it at launch, so saying "it is
        // in" while the window still shows the old numbers would be a lie the
        // user can see. Reopening is the honest short path.
        let done = NSAlert()
        done.messageText = "Imported."
        done.informativeText =
            "TYPE needs to reopen to show it. The profile it replaced is in the same folder."
        done.addButton(withTitle: "Quit TYPE")
        done.addButton(withTitle: "Later")
        if done.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    private func present(error: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = error
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
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
/// Resizes the window and brings the new pane in, as one movement.
///
/// ## Why it is not AppKit's crossfade
///
/// A pane that shrinks cannot resize *during* a crossfade. Traced with both
/// panes in the hierarchy, the window runs down to the new height and then
/// jumps back to the outgoing pane's — 594 → 204 with a full frame at 594 in
/// between, three runs out of three. It is the outgoing grid that does it:
/// with empty panes the same trace is clean, which is why an earlier probe
/// missed it entirely. Levelling `preferredContentSize` across the two
/// controllers does not help, and neither does relaxing `contentMinSize`.
///
/// Working around it meant waiting for the crossfade to finish and resizing
/// afterwards, which is two movements, and looks like two.
///
/// So the content is swapped with no animation at all — which puts AppKit's
/// resize where it belongs, before anything moves — and the fade is done here
/// instead, in the same animation group as the height. One movement: the
/// window finds its new height while the pane that arrived comes up inside it.
final class SettingsTabViewController: NSTabViewController {
    /// Long enough to read as one movement rather than a jump.
    private static let duration: TimeInterval = 0.3

    /// Prompt at the start, unhurried at the end. `easeInEaseOut` eases into
    /// the movement as well, which on a height change reads as hesitation
    /// before anything happens.
    private static var timing: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
    }

    override func transition(
        from fromViewController: NSViewController, to toViewController: NSViewController,
        options: NSViewController.TransitionOptions = [],
        // `@Sendable` to match what AppKit declares. Without it every call to
        // `super` warns about handing a non-Sendable closure to a Sendable
        // parameter — the override is the place to state the contract, not
        // three call sites downstream.
        completionHandler completion: (@Sendable () -> Void)? = nil
    ) {
        let target = toViewController.preferredContentSize
        guard let window = view.window, target.height > 0 else {
            // Nothing to animate against. Hand it back whole, and leave the
            // arriving pane opaque — the fade below is the only thing that
            // ever makes it otherwise, and skipping it here without this would
            // leave a pane at whatever alpha it was last interrupted at.
            toViewController.view.alphaValue = 1
            super.transition(
                from: fromViewController, to: toViewController, options: options,
                completionHandler: completion)
            return
        }

        // The top edge stays put. Growing or shrinking from the title bar
        // downwards is what a settings window does; moving both edges reads
        // as the window jumping.
        let content = window.contentRect(forFrameRect: window.frame)
        var frame = window.frameRect(
            forContentRect: NSRect(origin: content.origin, size: target))
        frame.origin.y = window.frame.maxY - frame.height

        // Content first and instantly, so AppKit's own resize — the jump back
        // to the outgoing pane's height — happens before the eye is on
        // anything. `completion` rides with it: with no animation the
        // transition really has finished by the time it is called.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            super.transition(
                from: fromViewController, to: toViewController, options: [],
                completionHandler: completion)
        }

        let arriving = toViewController.view
        arriving.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = Self.timing
            window.animator().setFrame(frame, display: true)
            arriving.animator().alphaValue = 1
        }
    }
}
