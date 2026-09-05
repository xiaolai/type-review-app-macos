import AppKit
import TypeReviewKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var practice: PracticeViewController?
    private var statsWindow: NSWindow?
    // Built on demand: a main-actor default value cannot be initialised from
    // AppDelegate's nonisolated init.
    private var stats: StatsViewController?
    private var settings: SettingsWindowController?
    private var keyboardMenuItem: NSMenuItem?
    private var sourceMenuItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let practice = PracticeViewController()
        self.practice = practice

        let window = NSWindow(contentViewController: practice)
        window.title = "TYPE"
        window.setContentSize(NSSize(width: 900, height: 640))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setFrameAutosaveName("TypeReviewMain")
        window.minSize = NSSize(width: 720, height: 560)
        if window.frame.origin == .zero { window.center() }
        self.window = window

        NSApp.mainMenu = makeMenu()
        practice.setKeyboardVisible(
            UserDefaults.standard.object(forKey: "ShowKeyboard") as? Bool ?? true)
        markSourceMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if CommandLine.arguments.contains("--selftest") { runSelfTest() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
        let keyboardItem = viewMenu.addItem(
            withTitle: "Show Keyboard", action: #selector(toggleKeyboard(_:)), keyEquivalent: "k")
        keyboardItem.target = self
        keyboardItem.state = UserDefaults.standard.object(forKey: "ShowKeyboard") as? Bool ?? true
            ? .on : .off
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
        let visible = keyboardMenuItem?.state != .on
        keyboardMenuItem?.state = visible ? .on : .off
        UserDefaults.standard.set(visible, forKey: "ShowKeyboard")
        practice?.setKeyboardVisible(visible)
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
