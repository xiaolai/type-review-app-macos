import AppKit
import TypeReviewKit

/// Main-actor isolated as a whole. Every method here touches AppKit, and the
/// alternative under strict concurrency is annotating them one at a time and
/// still having the compiler object to closures that capture `self`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var practice: PracticeViewController?
    // Built in applicationDidFinishLaunching, for the same reason the stats
    // controller is: a main-actor default value cannot be initialised from
    // AppDelegate's nonisolated init.
    private var drawer: KeyboardDrawer?
    private var statsWindow: NSWindow?
    // Built on demand: a main-actor default value cannot be initialised from
    // AppDelegate's nonisolated init.
    private var stats: StatsViewController?
    private var settings: SettingsWindowController?
    private var libraryWindow: LibraryWindowController?
    private var keyboardMenuItem: NSMenuItem?
    private var preferencesObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var statusKeyboardItem: NSMenuItem?
    private var sourceMenuItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let practice = PracticeViewController()
        self.practice = practice

        let window = NSWindow(contentViewController: practice)
        window.title = "TYPE"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // No hairline under the title bar. The practice screen is a sheet of
        // text on a plain ground; a rule across the top divides it from
        // nothing.
        window.titlebarSeparatorStyle = .none
        // Or closing the window deallocates it, and reopening from the menu
        // bar reaches a window that is no longer there. The default is true
        // for a programmatically created window.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("TypeReviewMain")
        applyWindowSize(to: window)
        if window.frame.origin == .zero { window.center() }
        self.window = window

        NSApp.mainMenu = makeMenu()
        // Before the drawer's state is applied: both menus that offer the
        // keyboard toggle have to exist by the time the checkmark is set, or
        // the one built later starts out lying about it.
        installStatusItem()
        let drawer = KeyboardDrawer()
        self.drawer = drawer
        practice.keyboard = drawer.keyboard
        drawer.attach(to: window)
        markSourceMenu()
        window.makeKeyAndOrderFront(nil)
        // After the window is on screen, and without animation: the drawer
        // should already be out when the app appears, not slide out at launch.
        let showKeyboard = UserDefaults.standard.object(forKey: "ShowKeyboard") as? Bool ?? true
        drawer.setOpen(showKeyboard, animated: false)
        markKeyboardMenus(showKeyboard)
        NSApp.activate(ignoringOtherApps: true)

        preferencesObserver = NotificationCenter.default.addObserver(
            forName: AppPreferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.applyWindowSize(to: window)
                self.drawer?.reframe()
            }
        }

        if CommandLine.arguments.contains("--selftest") { runSelfTest() }
    }

    /// The menu-bar item.
    ///
    /// `keyboard.badge.ellipsis` as a template image, so macOS inverts it for
    /// a dark menu bar and dims it when the bar is inactive — the two things a
    /// hand-tinted image gets wrong. The badge is the point: it says this icon
    /// leads somewhere rather than being a status light.
    ///
    /// The menu is the app's own verbs, not a second copy of the main menu:
    /// what someone reaches for when TYPE is not the front app.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Sized explicitly. Left at its default the symbol draws 19 by 11
        // points of ink, which is the shortest thing in the menu bar — its
        // neighbours run 12 to 15.5 tall — because `keyboard.badge.ellipsis`
        // is a wide, short mark and the default configuration sizes by cap
        // height. `.large` at 13 points brings the ink to roughly 24 by 14,
        // matching the taller neighbours and a hair wider than the widest.
        let image = NSImage(
            systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: "TYPE"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: .large))
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "TYPE"

        let menu = NSMenu()
        let show = menu.addItem(
            withTitle: "Open TYPE", action: #selector(showMainWindow(_:)), keyEquivalent: "")
        show.target = self
        menu.addItem(.separator())
        let keyboard = menu.addItem(
            withTitle: "Show Keyboard", action: #selector(toggleKeyboard(_:)), keyEquivalent: "")
        keyboard.target = self
        statusKeyboardItem = keyboard
        let newText = menu.addItem(
            withTitle: "New Text", action: #selector(newText(_:)), keyEquivalent: "")
        newText.target = self
        menu.addItem(.separator())
        for (title, action) in [
            ("Library", #selector(showLibrary(_:))),
            ("Statistics", #selector(showStats(_:))),
            ("Settings…", #selector(showSettings(_:))),
        ] {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            entry.target = self
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit TYPE", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "")
        item.menu = menu
        statusItem = item
    }

    /// Two menus offer the keyboard toggle, so both carry the checkmark.
    private func markKeyboardMenus(_ visible: Bool) {
        keyboardMenuItem?.state = visible ? .on : .off
        statusKeyboardItem?.state = visible ? .on : .off
    }

    @objc private func showMainWindow(_ sender: Any?) {
        window?.makeKeyAndOrderFront(nil)
        // The drawer is a child window, so closing the main one took it off
        // screen while leaving it marked open. Without this it never comes
        // back and the keyboard is gone until the setting is toggled twice.
        drawer?.restoreIfOpen()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Sizes the window to hold exactly the requested lines and columns.
    ///
    /// The window is resizable and its frame is autosaved, so this sets the
    /// content size rather than the frame — the user's chosen position is
    /// theirs to keep. The minimum stops the passage being squeezed narrower
    /// than it can usefully wrap.
    private func applyWindowSize(to window: NSWindow) {
        let size = PracticeWindowMetrics.contentSize(
            columns: AppPreferences.columns.value, rows: AppPreferences.rows.value)
        window.minSize = NSSize(
            width: PracticeWindowMetrics.contentSize(columns: 30, rows: 4).width,
            height: PracticeWindowMetrics.contentSize(columns: 30, rows: 4).height + 28)
        window.setContentSize(size)
    }

    /// The app outlives its window, because it has a menu-bar item.
    ///
    /// It used to quit — which made the status item incoherent the moment it
    /// was added: closing the window took the menu-bar icon with it, so
    /// "Open TYPE" was an item that could only be reached while a window was
    /// already open. An app with a presence in the menu bar is reachable from
    /// there, and quits from there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open brings it back.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }

    /// Every key equivalent carries Command.
    ///
    /// In the web-view version this rule was load-bearing because WKWebView
    /// hands keys to the page first. Here the reason is different but the rule
    /// is the same: the typing view consumes bare keys as *typing*, so a
    /// bare-letter shortcut would either be swallowed mid-drill or steal a
    /// character from the passage.
    private func makeMenu() -> NSMenu {
        let root = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About TYPE",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide TYPE", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(
            withTitle: "Quit TYPE", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        root.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let statsItem = viewMenu.addItem(
            withTitle: "Statistics", action: #selector(showStats(_:)), keyEquivalent: "2")
        statsItem.target = self
        let libraryItem = viewMenu.addItem(
            withTitle: "Library", action: #selector(showLibrary(_:)), keyEquivalent: "3")
        libraryItem.target = self
        let keyboardItem = viewMenu.addItem(
            withTitle: "Show Keyboard", action: #selector(toggleKeyboard(_:)), keyEquivalent: "k")
        keyboardItem.target = self
        keyboardMenuItem = keyboardItem

        viewMenu.addItem(.separator())
        let sourceItem = NSMenuItem(title: "Source", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu(title: "Source")
        for (index, channel) in CorpusChannel.allCases.enumerated() {
            let item = sourceMenu.addItem(
                withTitle: channel.label, action: #selector(chooseSource(_:)),
                keyEquivalent: String(index + 4))
            item.target = self
            item.representedObject = channel.rawValue
        }
        sourceItem.submenu = sourceMenu
        viewMenu.addItem(sourceItem)
        sourceMenuItems = sourceMenu.items
        viewItem.submenu = viewMenu
        root.addItem(viewItem)

        let practiceItem = NSMenuItem()
        let practiceMenu = NSMenu(title: "Practice")
        let newText = practiceMenu.addItem(
            withTitle: "New Text", action: #selector(newText(_:)), keyEquivalent: "n")
        newText.target = self
        practiceItem.submenu = practiceMenu
        root.addItem(practiceItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowItem.submenu = windowMenu
        root.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return root
    }

    @objc private func newText(_ sender: Any?) {
        practice?.startFreshRun()
    }

    @objc private func chooseSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let channel = CorpusChannel(rawValue: raw)
        else { return }
        practice?.channel = channel
        markSourceMenu()
    }

    /// A checkmark on the active source, so the menu says which corpus the
    /// text is coming from rather than only offering to change it.
    private func markSourceMenu() {
        let active = practice?.channel.rawValue
        for item in sourceMenuItems {
            item.state = (item.representedObject as? String) == active ? .on : .off
        }
    }

    @objc private func toggleKeyboard(_ sender: Any?) {
        guard let drawer else { return }
        let visible = !drawer.isOpen
        drawer.setOpen(visible, animated: true)
        markKeyboardMenus(visible)
        UserDefaults.standard.set(visible, forKey: "ShowKeyboard")
    }

    /// The Library gets its own window for the same reason Statistics does:
    /// managing documents alongside the practice screen beats replacing it.
    @objc private func showLibrary(_ sender: Any?) {
        guard let practice else { return }
        let controller = libraryWindow ?? LibraryWindowController(store: practice.library)
        libraryWindow = controller
        controller.present()
    }

    @objc private func showSettings(_ sender: Any?) {
        let controller = settings ?? SettingsWindowController()
        settings = controller
        controller.read = { [weak self] in self?.practice?.currentSettings ?? .default }
        controller.write = { [weak self] next in self?.practice?.applySettings(next) ?? false }
        controller.present()
    }

    /// Statistics get their own window rather than a route. A separate window
    /// is the Mac answer to "show me this alongside" — it can sit next to the
    /// practice window instead of replacing it.
    @objc private func showStats(_ sender: Any?) {
        let controller = stats ?? StatsViewController()
        stats = controller
        controller.present(results: practice?.history ?? [])
        if statsWindow == nil {
            let window = NSWindow(contentViewController: controller)
            window.title = "Statistics"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 480))
            window.setFrameAutosaveName("TypeReviewStats")
            window.center()
            statsWindow = window
        }
        statsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Drives a full run through the real UI and reports what reached disk.
    ///
    /// The same discipline the web-view shell used, for the same reason: unit
    /// tests cover the engine exhaustively, and none of them can tell whether
    /// the app is wired to it.
    private func runSelfTest() {
        guard let practice else { exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let store = try? ProfileFileStore.standard()
            let before: Int
            if let store, case .ok(let profile) = store.load() {
                before = profile.results.count
            } else {
                before = 0
            }

            // A missing resource bundle looks exactly like an empty corpus to
            // the picker, so assert the data is actually there rather than
            // letting the app quietly serve generated words forever.
            guard BundledCorpus.quotes.entries.count > 100,
                !BundledCorpus.code.entries.isEmpty
            else {
                print(
                    "SELFTEST FAIL: corpus not bundled — "
                        + "\(BundledCorpus.quotes.entries.count) quotes, "
                        + "\(BundledCorpus.code.entries.count) code entries")
                exit(1)
            }
            // The case must sit the same distance from the caps on all four
            // sides. This was wrong until it was measured: the inter-key gap
            // was being applied after the last key too, so the right and
            // bottom margins were a gap wider than the left and top.
            let keyboardLayout = KeyboardView().layout(forWidth: 900, height: 220)
            let capsRect = keyboardLayout.keys.dropFirst().reduce(keyboardLayout.keys[0].rect) {
                $0.union($1.rect)
            }
            let margins = [
                capsRect.minX - keyboardLayout.caseRect.minX,
                keyboardLayout.caseRect.maxX - capsRect.maxX,
                capsRect.minY - keyboardLayout.caseRect.minY,
                keyboardLayout.caseRect.maxY - capsRect.maxY,
            ]
            guard let tightest = margins.min(), let widest = margins.max(),
                widest - tightest < 0.5, tightest > 0
            else {
                print("SELFTEST FAIL: keyboard margins are \(margins) — expected four equal")
                exit(1)
            }

            // No key on any keyboard shape may be narrower than a key can be.
            //
            // Row totals are `unitsPerRow` by construction — the last key
            // absorbs the slack — so checking the total proves nothing. What
            // can go wrong is a row whose fixed keys leave the absorber too
            // little, or nothing, or less than nothing. That is what a ragged
            // or overflowing keyboard actually is, and nothing else reports
            // it: the view just draws it.
            for shape in [SystemKeyboard.Shape.ansi, .iso, .jis] {
                for (index, row) in KeyboardGeometry.rows(for: shape).enumerated() {
                    guard let narrowest = row.map(\.width).min(), narrowest >= 0.75 else {
                        print(
                            "SELFTEST FAIL: \(shape) row \(index) has a "
                                + "\(row.map(\.width).min() ?? 0)u key — the row does not fit")
                        exit(1)
                    }
                }
            }

            // Legends must come from a keyboard, not from an input method.
            //
            // With a CJK input method active, the *current* layout is the
            // input method's own, and asking it what a key produces answers
            // with `……` above 6 and `¥` above 4 — what that method types, not
            // what is printed on the key. The ASCII-capable layout is the
            // keyboard underneath. This check is worth little on a machine
            // that only ever runs a US layout, where both answers agree; it
            // bites on one where an input method is active, which is where the
            // bug appeared.
            guard SystemKeyboard.legendSourceIsASCIICapable else {
                print(
                    "SELFTEST FAIL: keycap legends are being read from "
                        + "\(SystemKeyboard.layoutName), which is not an ASCII-capable layout")
                exit(1)
            }

            // The header of live numbers must actually reach the screen.
            //
            // It did not, for the whole life of this app: laid out correctly,
            // in the hierarchy, not hidden, with the right text and colour —
            // and painted over, because the typing view filled its dirty rect
            // rather than its bounds and AppKit does not clip a view's drawing
            // to its own bounds. Every property that can be asserted from the
            // view tree was true while the pixels were blank, so the only
            // check that can catch it is a look at the pixels.
            let allLabels = practice.view.subviews
                .compactMap { $0 as? NSStackView }
                .flatMap(\.views)
                .compactMap { $0 as? NSTextField }
            guard let wpmLabel = allLabels.first(where: { $0.stringValue.hasSuffix("wpm") }) else {
                print("SELFTEST FAIL: no wpm label in the header")
                exit(1)
            }
            let root = practice.view
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                print("SELFTEST FAIL: could not render the practice view")
                exit(1)
            }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let labelRect = wpmLabel.convert(wpmLabel.bounds, to: root)
            let scale = CGFloat(bitmap.pixelsWide) / max(root.bounds.width, 1)
            // Raw bytes rather than `colorAt(x:y:)`, which raises on bitmap
            // formats it does not recognise — including the one AppKit hands
            // back for a cached display.
            guard let bytes = bitmap.bitmapData, bitmap.samplesPerPixel >= 3 else {
                print("SELFTEST FAIL: rendered bitmap has no readable pixels")
                exit(1)
            }
            let rowBytes = bitmap.bytesPerRow
            let step = bitmap.samplesPerPixel
            // The bitmap counts rows from the top; the view does not.
            let top = Int((root.bounds.height - labelRect.maxY) * scale)
            let background = Theme.background.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1
            let firstRow = max(0, top)
            let lastRow = min(bitmap.pixelsHigh, top + Int(labelRect.height * scale))
            let firstColumn = max(0, Int(labelRect.minX * scale))
            let lastColumn = min(bitmap.pixelsWide, Int(labelRect.maxX * scale))
            let rows: Range<Int> = firstRow..<max(firstRow, lastRow)
            let columns: Range<Int> = firstColumn..<max(firstColumn, lastColumn)
            var inked = 0
            for y in rows {
                for x in columns {
                    let offset = y * rowBytes + x * step
                    let brightness =
                        (CGFloat(bytes[offset]) + CGFloat(bytes[offset + 1])
                            + CGFloat(bytes[offset + 2])) / (3 * 255)
                    if abs(brightness - background) > 0.15 { inked += 1 }
                }
            }
            guard inked > 20 else {
                print(
                    "SELFTEST FAIL: the header reads \"\(wpmLabel.stringValue)\" but only "
                        + "\(inked) of its pixels differ from the background — it is covered")
                exit(1)
            }

            // The library round-trip, through the real file store: add,
            // reload from disk, confirm the corpus serves it, delete. The unit
            // tests cover the parser and the picker; only this can tell
            // whether the app is wired to them.
            let library = practice.library
            let libraryBefore = library.passages.count
            do {
                try library.add(title: "selftest", text: "the quick brown fox jumps over it")
            } catch {
                print("SELFTEST FAIL: library add: \(error)")
                exit(1)
            }
            let reread = LibraryStore(directory: library.directory)
            guard reread.passages.count == libraryBefore + 1,
                let added = reread.passages.last,
                added.title == "selftest"
            else {
                print("SELFTEST FAIL: library did not survive a reload from \(library.fileURL.path)")
                exit(1)
            }
            var libraryRNG = Mulberry32(seed: 1)
            let served = try? CorpusAdapter(channel: .user, library: reread.passages)
                .adaptiveSource(
                    filter: Filter(allowed: ["e", "t", "a"], focus: nil), wordCount: 7,
                    rng: &libraryRNG)
            guard served?.text == added.text else {
                print("SELFTEST FAIL: Library channel served \(served?.text ?? "nothing")")
                exit(1)
            }
            do { try library.delete(id: added.id) } catch {
                print("SELFTEST FAIL: library delete: \(error)")
                exit(1)
            }

            guard let view = practice.view.subviews.compactMap({ $0 as? TypingView }).first else {
                print("SELFTEST FAIL: no typing surface")
                exit(1)
            }
            // A human cadence. Without it the run lands at hundreds of
            // thousands of wpm, which the profile validator rightly refuses —
            // the metric bounds exist to catch exactly that shape of nonsense.
            var syntheticClock: Double = 0
            practice.clock = {
                syntheticClock += 120
                return syntheticClock
            }
            // Through the same entry point AppKit uses for committed text, so
            // the input path is the one being tested rather than bypassed.
            let expected = practice.currentPassage
            guard !expected.isEmpty else {
                print("SELFTEST FAIL: no passage")
                exit(1)
            }
            for unit in Array(expected.utf16) {
                view.insertText(String(utf16CodeUnits: [unit], count: 1), replacementRange: NSRange())
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let store else {
                    print("SELFTEST FAIL: no store")
                    exit(1)
                }
                let reloaded = store.load()
                guard case .ok(let profile) = reloaded else {
                    print(
                        "SELFTEST FAIL: profile reloaded as \(reloaded.statusName) from \(store.fileURL.path)"
                            + " — in-memory runs: \(practice.runCount)")
                    exit(1)
                }
                guard profile.results.count == before + 1 else {
                    print(
                        "SELFTEST FAIL: expected \(before + 1) runs on disk, found \(profile.results.count)")
                    exit(1)
                }
                let metrics = profile.results.last!.metrics
                print(
                    "SELFTEST OK: typed \(expected.utf16.count) chars — "
                        + "\(Int(metrics.netWpm)) wpm, \(Int(metrics.accuracy))% accuracy, "
                        + "\(profile.results.count) run(s) on disk")
                exit(0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            print("SELFTEST FAIL: timed out")
            exit(2)
        }
    }
}
