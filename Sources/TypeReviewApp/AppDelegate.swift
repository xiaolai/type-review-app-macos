import AppKit
import TypeReviewKit

/// Main-actor isolated as a whole. Every method here touches AppKit, and the
/// alternative under strict concurrency is annotating them one at a time and
/// still having the compiler object to closures that capture `self`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var practice: PracticeViewController?
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
    var keyboardMenuItem: NSMenuItem?
    private var preferencesObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    var statusItem: NSStatusItem?
    var statusKeyboardItem: NSMenuItem?
    var sourceMenuItems: [NSMenuItem] = []
    var toolbarController: MainToolbarController?
    /// Every Sound submenu built — the menu bar's and the status item's. Both
    /// carry the same checkmarks, so both have to be told when the pack
    /// changes, including when it changes from the global shortcut while
    /// neither menu is open.
    var soundMenus: [NSMenu] = []
    private var soundHotKey: GlobalHotKey?

    /// The one keystroke player, at app scope rather than inside the practice
    /// screen. Sound outlives that window now — the whole point of the global
    /// setting is that it works with no window on screen at all.
    ///
    /// `lazy`, like the monitor below, because a main-actor default value
    /// cannot be initialised from AppDelegate's nonisolated init. Neither
    /// costs anything until first touched: the player holds no audio device
    /// until a pack that makes noise is set.
    private lazy var sounds = KeySoundPlayer()
    private lazy var globalSound = GlobalKeySound { [weak self] code in
        self?.playKey(code)
    }
    /// The passage shape the window was last sized to, so an unrelated
    /// preference change does not resize it. See `applyWindowSize`.
    private struct ShapePreference: Equatable { let columns: Int; let rows: Int }
    private var appliedShape: ShapePreference?
    /// Accessibility as of the last time the app was frontmost, so a grant
    /// made while it was in the background can be noticed on the way back.
    private var soundWasPermitted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read first, before anything else can dispatch another Apple event:
        // this is a property of the event being handled right now, and there
        // is no way to ask again later.
        let atLogin = LoginItem.launchedAtLogin
        let practice = PracticeViewController()
        self.practice = practice

        let window = NSWindow(contentViewController: practice)
        window.title = "TYPE"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // The toolbar, and the unified style, are what give this window the
        // current Mac silhouette: one material band holding the title, the
        // controls and the traffic lights, instead of the short opaque strip a
        // toolbar-less window still gets. See `MainToolbarController`.
        let toolbarController = MainToolbarController()
        self.toolbarController = toolbarController
        toolbarController.onNewText = { [weak self] in self?.practice?.startFreshRun() }
        toolbarController.onToggleKeyboard = { [weak self] in self?.toggleKeyboard(nil) }
        toolbarController.onShowLibrary = { [weak self] in self?.showLibrary(nil) }
        toolbarController.onShowStats = { [weak self] in self?.showStats(nil) }
        toolbarController.currentChannel = { [weak self] in self?.practice?.channel ?? .auto }
        toolbarController.onChooseSource = { [weak self] channel in
            self?.practice?.channel = channel
            self?.markSourceMenu()
        }
        window.toolbar = toolbarController.makeToolbar()
        window.toolbarStyle = .unified
        // The mark replaces the word. `window.title` stays set — the Window
        // menu and Mission Control read it — but the title bar draws the
        // app's icon instead, in this launch's colour.
        window.titleVisibility = .hidden
        TitleMark.install(in: window)
        // No hairline under the title bar. The practice screen is a sheet of
        // text on a plain ground; a rule across the top divides it from
        // nothing.
        //
        // Both lines are needed, and `titlebarSeparatorStyle` alone is the
        // trap. Setting it to `.none` genuinely takes effect — reading the
        // property back at runtime returns `.none` — and a 1pt line at
        // rgb(230,230,230) still draws at the toolbar's lower edge, because
        // under a unified toolbar that edge belongs to the title bar's own
        // backdrop rather than to the separator. Making the backdrop
        // transparent is what removes it, and it also lets the toolbar sit on
        // the same white as the text instead of on a slightly different one.
        //
        // Note this is *not* `.fullSizeContentView`: the content still begins
        // below the title bar, so nothing scrolls under the toolbar and the
        // font-derived window sizing in `PracticeWindowMetrics` is untouched.
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
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
        // Started by launchd rather than by a person: leave the menu bar icon
        // and the keystroke sound, and nothing else. A window thrown across
        // whatever you were about to do is the reason people turn login items
        // off again, and the only thing this app needs to be doing at login is
        // making the keyboard sound like a keyboard.
        //
        // The drawer is still set up, before the retreat and while the window
        // still has a chance to arrange it, so "Open TYPE" later shows the
        // keyboard the user left out rather than a window missing half of
        // itself.
        if !atLogin { window.makeKeyAndOrderFront(nil) }
        // Without animation: the drawer should already be out when the app
        // appears, not slide out at launch.
        let showKeyboard = UserDefaults.standard.object(forKey: "ShowKeyboard") as? Bool ?? true
        drawer.setOpen(showKeyboard, animated: false)
        markKeyboardMenus(showKeyboard)
        if atLogin {
            window.orderOut(nil)
            retreatToMenuBar()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        preferencesObserver = NotificationCenter.default.addObserver(
            forName: AppPreferences.didChange, object: nil, queue: .main
        ) { [weak self] note in
            let changed = note.userInfo?[AppPreferences.changedKey] as? String
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                // Only what the change touches. Every preference used to
                // arrive as the same anonymous notification, so adjusting the
                // volume resized the window and re-registered the global hot
                // key — and a window the user had just dragged snapped back.
                if changed == nil || changed == AppPreferences.columns.key
                    || changed == AppPreferences.rows.key
                {
                    self.applyWindowSize(to: window)
                }
                self.drawer?.reframe()
                // Sound is an app preference too, and it rides the same
                // notification — so a pack or volume changed in Settings is
                // live on the next keystroke rather than at the next launch.
                // `applySoundPreferences` marks the menus itself, and
                // `registerSoundShortcut` marks them again after registering —
                // so the explicit call that used to sit here was the third
                // mark for one notification.
                self.applySoundPreferences()
                self.practice?.applyTypingPreferences()
                if changed == nil || changed == AppPreferences.soundShortcut.keyCodeKey {
                    self.registerSoundShortcut()
                }
            }
        }

        observeWindowClosing()
        registerSoundShortcut()
        // Pack, volume and — the new part — scope. This is what starts the
        // system-wide monitor when the setting says so, and what decides
        // whether the typing surface makes its own sound or leaves it to the
        // monitor.
        applySoundPreferences()
        soundWasPermitted = GlobalKeySound.isPermitted

        // One at a time. Both scheduled together, the sound check exits at
        // ~0.2s and the self-test does not start until 0.5s — so asking for
        // both reported the sound check's success and silently never ran the
        // self-test at all. A diagnostic that skips without saying so is worse
        // than one that refuses.
        let soundcheck = CommandLine.arguments.contains("--soundcheck")
        let selftest = CommandLine.arguments.contains("--selftest")
        if soundcheck, selftest {
            print("error: --soundcheck and --selftest cannot be combined — run them separately")
            exit(2)
        }
        if soundcheck { Diagnostics.runSoundCheck() }
        if selftest { Diagnostics.runSelfTest(practice: practice) }
    }



    /// Closes every window and leaves TYPE running in the menu bar.
    ///
    /// What ⌘Q does here. `orderOut` rather than `close` on the main window:
    /// it is `isReleasedWhenClosed = false` either way, but ordering out keeps
    /// its delegate and frame intact so coming back is the same window rather
    /// than a new one that has forgotten where it was.
    @objc func hideToMenuBar(_ sender: Any?) {
        for window in NSApp.windows where window.isVisible && window.canBecomeMain {
            window.orderOut(nil)
        }
        retreatToMenuBar()
    }

    /// Drops the Dock icon and the menu bar, leaving only the status item.
    ///
    /// `.accessory` is what makes this a menu-bar app rather than a windowed
    /// one that happens to have an icon up there: no Dock tile, and no entry
    /// in the ⌘-Tab switcher, which is right for something with no window on
    /// screen. It is reversible — `showMainWindow` puts both back.
    private func retreatToMenuBar() {
        guard NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc func showMainWindow(_ sender: Any?) {
        // Back to a normal app first. Ordering a window front while the policy
        // is still `.accessory` gives a window with no menu bar and no Dock
        // tile, which looks like the app half-launched.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        // A new colour for the mark, but only when the window was actually
        // away. "Open TYPE" on a window that is already up is a no-op, and
        // re-rolling there would change the colour for nothing.
        if window?.isVisible != true { TitleMark.reroll() }
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
        let shape = ShapePreference(
            columns: AppPreferences.columns.value, rows: AppPreferences.rows.value)
        // Every app preference rides one notification, so this ran for a
        // volume drag and a sound toggle as well — and each one snapped a
        // window the user had resized by hand back to the computed size.
        // Nothing about the window changed unless these two numbers did.
        guard shape != appliedShape else { return }
        appliedShape = shape
        let size = PracticeWindowMetrics.contentSize(columns: shape.columns, rows: shape.rows)
        // `contentMinSize`, not `minSize`. The old line set a *frame* minimum
        // from a *content* measurement and made up the difference with a
        // hardcoded 28 points of chrome — which is not what a unified toolbar
        // is, and was never rechecked against one. Letting AppKit account for
        // its own title bar is both shorter and right at any toolbar height.
        window.contentMinSize = PracticeWindowMetrics.contentSize(columns: 30, rows: 4)
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

    /// Closing the last window puts TYPE in the menu bar rather than leaving
    /// a running app with no Dock icon to click and no window to look at.
    ///
    /// Checked on the next pass of the runloop because this fires *before* the
    /// window goes away, so counting here would always find at least one.
    /// Auxiliary windows do not count — the drawer is borderless and cannot
    /// become main, which is exactly the test for "a window the user thinks
    /// of as a window".
    /// Registered for *every* window, not just the practice one.
    ///
    /// This used to be the `NSWindowDelegate` method, which only ever fired
    /// for the one window whose delegate is this object. Library, Settings and
    /// Statistics each have their own controller as delegate, so closing the
    /// practice window and then the last of those left the app running with no
    /// window and still claiming to be a regular app — a Dock tile with
    /// nothing behind it.
    private func observeWindowClosing() {
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            let closing = notification.object as? NSWindow
            MainActor.assumeIsolated {
                // On the next pass of the runloop, because this fires *before*
                // the window goes away and counting here would always find at
                // least one. Auxiliary windows do not count — the drawer is
                // borderless and cannot become main, which is exactly the test
                // for "a window the user thinks of as a window".
                DispatchQueue.main.async { [weak self] in
                    let remaining = NSApp.windows.contains {
                        $0 !== closing && $0.isVisible && $0.canBecomeMain
                    }
                    if !remaining { self?.retreatToMenuBar() }
                }
            }
        }
    }

    /// Clicking the Dock icon with no window open brings it back.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }


    @objc func newText(_ sender: Any?) {
        practice?.startFreshRun()
    }

    @objc func chooseSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let channel = CorpusChannel(rawValue: raw)
        else { return }
        practice?.channel = channel
        markSourceMenu()
    }


    /// Claims the configured combination system-wide, replacing whatever was
    /// claimed before.
    ///
    /// Called at launch and again whenever the preference changes, so a
    /// shortcut edited in Settings is live immediately — the old registration
    /// has to be released first or the previous combination keeps working
    /// alongside the new one.
    /// Stands the global hot key down while the shortcut recorder is armed.
    ///
    /// `RegisterEventHotKey` claims its combination system-wide and dispatches
    /// below the Cocoa event stream, so the recorder's local monitor never
    /// sees it. Re-recording the shortcut you already have fired the sound
    /// toggle instead of being captured.
    private func setSoundShortcutSuspended(_ suspended: Bool) {
        if suspended {
            soundHotKey?.unregister()
            soundHotKey = nil
        } else {
            registerSoundShortcut()
        }
    }

    private func registerSoundShortcut() {
        soundHotKey?.unregister()
        soundHotKey = nil
        guard let shortcut = AppPreferences.soundShortcut.value else {
            markSoundMenus()
            return
        }
        soundHotKey = GlobalHotKey(
            keyCode: UInt32(shortcut.keyCode), modifiers: shortcut.modifiers.carbon
        ) { [weak self] in
            self?.toggleSound(nil)
        }
        if soundHotKey == nil {
            // Another app already owns it. The menu item still works, so this
            // is worth saying once rather than raising a dialog the user can
            // do nothing about from here.
            print("TYPE: \(shortcut.displayString) is taken by another app — menu only")
        }
        markSoundMenus()
    }



    /// Toggling is what the global shortcut does, so it has to work with no
    /// window on screen and TYPE in the background.
    @objc func toggleSound(_ sender: Any?) {
        AppPreferences.toggleSound()
        markSoundMenus()
        // Switching sound *on* silently would leave the user unsure it
        // worked — the shortcut is usable from another app, where there is no
        // window and no menu to look at. One click is the answer. Switching
        // off needs no confirmation: the next keystroke is the confirmation.
        if AppPreferences.soundIsOn { previewSound() }
    }

    @objc func chooseSoundPack(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
            let pack = KeySoundPack.named(name)
        else { return }
        AppPreferences.soundPack.value = pack
        markSoundMenus()
        if AppPreferences.soundIsOn { previewSound() }
    }

    /// Coming back to the front is the one moment Accessibility is likely
    /// to have just been granted — the user has been in System Settings.
    ///
    /// There is no notification for it, and a monitor installed before the
    /// grant is not fed events afterwards, so the permission is re-read here
    /// and the monitors replaced when the answer has changed. Belt and
    /// braces: relaunching is the certain path, and the Settings pane stops
    /// showing its warning either way.
    func applicationDidBecomeActive(_ notification: Notification) {
        let permitted = GlobalKeySound.isPermitted
        guard permitted != soundWasPermitted else { return }
        soundWasPermitted = permitted
        // Both directions relabel the menu. Only one of them reinstalls: a
        // grant needs new monitors, a revocation needs the menu to stop
        // claiming the setting is doing something. Guarding both behind the
        // grant left "Sound in Every App" without its warning until some
        // unrelated preference happened to change.
        if permitted, AppPreferences.globalSound.value { globalSound.reinstall() }
        markSoundMenus()
    }

    /// Everything a keystroke sound needs to know, which is only which
    /// physical key moved.
    ///
    /// The single sink. Both paths that can produce a keystroke — the typing
    /// surface and the system-wide monitor — arrive here, so there is one
    /// place that decides what a key sounds like and no way for the two to
    /// drift apart.
    private func playKey(_ code: UInt16) {
        // Every key has a category — the optional this used to unwrap could
        // not be nil, so the branch that handled it was unreachable.
        sounds.play(
            category: soundCategory(forKeyCode: code), pan: KeyPan.pan(forKeyCode: code))
    }

    /// Applies pack, volume and scope together.
    ///
    /// Scope is the part worth reading twice. Exactly one path may be live at
    /// a time: while the monitor is running it also sees this app's own key
    /// events — that is what its local half is for — so leaving the typing
    /// surface wired as well would click twice for every key pressed in the
    /// practice window. `onKeyStruck` is therefore set to nil, not merely
    /// ignored, so the ownership is visible rather than conditional.
    private func applySoundPreferences() {
        sounds.setPack(AppPreferences.soundPack.value)
        sounds.setVolume(AppPreferences.soundVolume.value)

        let global = AppPreferences.globalSound.value
        globalSound.setRunning(global, soundsModifiers: AppPreferences.modifierSound.value)
        practice?.onKeyStruck = global ? nil : { [weak self] code in self?.playKey(code) }
        markSoundMenus()
    }

    /// Plays one click at the current settings, so a pack picked in the
    /// Settings window or a menu can be heard the moment it is chosen.
    private func previewSound() {
        sounds.play(category: .standard, pan: 0)
    }

    /// Turns system-wide sound on or off from either menu.
    ///
    /// Asking for permission is part of switching it on, not a separate step
    /// the user has to discover: without it the monitor installs cleanly and
    /// is simply never called, and a setting that reports success while doing
    /// nothing is worse than one that refuses. macOS only ever shows its own
    /// prompt once per process lifetime of the answer, so the Settings window
    /// carries the second door for everyone past that.
    @objc func toggleGlobalSound(_ sender: Any?) {
        let wanted = !AppPreferences.globalSound.value
        if wanted, !GlobalKeySound.isPermitted { GlobalKeySound.requestPermission() }
        AppPreferences.globalSound.value = wanted
        // Switching on with no window in front and no keystroke yet made is
        // silent in a way that reads as broken. One click says it took.
        if wanted, AppPreferences.soundIsOn { previewSound() }
    }

    @objc func toggleKeyboard(_ sender: Any?) {
        guard let drawer else { return }
        let visible = !drawer.isOpen
        drawer.setOpen(visible, animated: true)
        markKeyboardMenus(visible)
        UserDefaults.standard.set(visible, forKey: "ShowKeyboard")
    }

    /// The Library gets its own window for the same reason Statistics does:
    /// managing documents alongside the practice screen beats replacing it.
    @objc func showLibrary(_ sender: Any?) {
        guard let practice else { return }
        let controller = libraryWindow ?? LibraryWindowController(store: practice.library)
        libraryWindow = controller
        controller.present()
    }

    @objc func showSettings(_ sender: Any?) {
        let controller = settings ?? SettingsWindowController()
        settings = controller
        controller.read = { [weak self] in self?.practice?.currentSettings ?? .default }
        controller.write = { [weak self] next in self?.practice?.applySettings(next) ?? false }
        controller.previewSound = { [weak self] in self?.previewSound() }
        controller.suspendHotKey = { [weak self] suspended in
            self?.setSoundShortcutSuspended(suspended)
        }
        controller.present()
    }

    /// Statistics get their own window rather than a route. A separate window
    /// is the Mac answer to "show me this alongside" — it can sit next to the
    /// practice window instead of replacing it.
    @objc func showStats(_ sender: Any?) {
        let controller = stats ?? StatsViewController()
        stats = controller
        controller.history = { [weak self] in self?.practice?.history ?? [] }
        controller.refresh()
        if statsWindow == nil {
            let window = NSWindow(contentViewController: controller)
            window.title = "Statistics"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 480))
            window.setFrameAutosaveName("TypeReviewStats")
            // Or closing Statistics deallocates the window while `statsWindow`
            // still points at it, and reopening from the menu reaches freed
            // memory. The default is true for a programmatically created
            // window; the practice window sets this and this one was missed.
            window.isReleasedWhenClosed = false
            // The same two lines the Settings and Library windows carry, and
            // for the same reasons: without `.auxiliary` this displaces the
            // practice window in Stage Manager, and `.automatic` tabbing lets
            // it be absorbed into another window's tab bar. This window was
            // simply missed when the other two were fixed.
            window.collectionBehavior = [.auxiliary, .fullScreenNone]
            window.tabbingMode = .disallowed
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = true
            // Only when there is nothing to restore. `setFrameAutosaveName`
            // reloads the saved frame, and centring unconditionally threw it
            // away — so a window the user had moved came back centred on
            // every launch, and the position was never remembered at all.
            if !window.setFrameUsingName("TypeReviewStats") { window.center() }
            statsWindow = window
        }
        statsWindow?.makeKeyAndOrderFront(nil)
        // Like Library and Settings. Ordering forward without activating
        // leaves the window on screen but not focused when it is opened from
        // the status menu while another app is in front.
        NSApp.activate(ignoringOtherApps: true)
    }

}
