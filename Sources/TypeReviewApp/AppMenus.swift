import AppKit
import TypeReviewKit

/// Everything that builds a menu, and the routines that keep the copies of it
/// in step.
///
/// Split out of `AppDelegate`, which was doing this alongside startup, window
/// management and sound routing. Two menus offer the same commands — the menu
/// bar's and the status item's — so the marking functions exist to stop the
/// two disagreeing, and they belong beside the builders that create the items
/// they mark rather than three hundred lines away from them.
///
/// `private` had to go on the way across: an extension in another file is
/// outside a private member's scope. Nothing is more exposed in practice —
/// these are `@objc` selector targets, which the runtime could always reach.
extension AppDelegate {
    /// The menu-bar item.
    ///
    /// The app's own mark as a template image, so macOS inverts it for a dark
    /// menu bar and dims it when the bar is inactive — the two things a
    /// hand-tinted image gets wrong.
    ///
    /// Literally the same mark as the Dock icon rather than a symbol chosen to
    /// look like it: `Mark.menuBarImage` draws from the geometry that
    /// `Tools/make-icon.swift` draws the `.icns` and the Icon Composer layer
    /// from. There is no reason for an app to have two faces, and a menu-bar
    /// mark that has quietly stopped matching the Dock is exactly the drift
    /// nobody notices until a screenshot puts the two side by side.
    ///
    /// The colour does not survive — a template reads only alpha, so the three
    /// window dots arrive as ink rather than as red, yellow and green. At this
    /// size that is not a loss: the colours would be three pixels each, and
    /// what carries the meaning is the arrangement.
    ///
    /// The menu is the app's own verbs, not a second copy of the main menu:
    /// what someone reaches for when TYPE is not the front app.
    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Sized explicitly, and measured rather than guessed. The mark is
        // square, so unlike the wide symbol this replaced it needs no scale
        // correction — the ink comes out exactly the side it is given. 15
        // points matches the tallest of its neighbours, which run 12 to 15.5;
        // the old mark was set to about 24 by 14, and losing the width is
        // correct rather than a regression, because that width was a badge
        // hanging off one side.
        let image = Mark.menuBarImage(pointSize: Theme.SymbolSize.menuBarMark)
        image.accessibilityDescription = "TYPE"
        item.button?.image = image
        item.button?.toolTip = "TYPE"

        let menu = NSMenu()
        let show = menu.addItem(
            withTitle: "Open TYPE", action: #selector(showMainWindow(_:)), keyEquivalent: "")
        show.target = self
        statusOpenItem = show
        menu.addItem(.separator())
        let keyboard = menu.addItem(
            withTitle: "Show Keyboard", action: #selector(toggleKeyboard(_:)), keyEquivalent: "")
        keyboard.target = self
        statusKeyboardItem = keyboard
        // No "New Text" here, though the menu bar and the toolbar both offer
        // it. From the status item the window is usually away, and starting a
        // fresh passage would silently discard a run in progress with nothing
        // on screen to show for it — a destructive command whose effect is
        // invisible at the moment it is given. When the window *is* up, the
        // toolbar button and ⌘N are both already in reach.
        // A submenu, because the packs are a list and a list of four does not
        // belong inline in a menu this short. The toggle sits at its top with
        // the shortcut printed beside it, which is also how someone discovers
        // the shortcut exists.
        let soundItem = menu.addItem(withTitle: "Sound", action: nil, keyEquivalent: "")
        soundItem.submenu = makeSoundMenu()
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
    /// The digit each corpus source answers to, by name rather than by
    /// position. Anything not listed gets no shortcut.
    static let sourceShortcuts: [String: String] = [
        "auto": "4", "quotes": "5", "code": "6", "user": "7", "generated": "8",
    ]

    /// Prints the summon shortcut beside "Open TYPE".
    ///
    /// A global shortcut nobody can see is one nobody uses, and the status
    /// menu is where someone looks when the window is away — which is exactly
    /// when the shortcut is worth knowing. Whatever is actually registered,
    /// so a combination another app has taken is never advertised as working.
    ///
    /// The item's action stays `showMainWindow` rather than the toggle. The
    /// two only differ when a window is already up and frontmost, which is not
    /// a state anyone reaches this menu from — and of the two, showing is the
    /// harmless direction to be wrong in.
    func markSummonShortcut() {
        // What registered, not what is stored. A combination another app owns
        // is refused by `RegisterEventHotKey`, and printing it beside the item
        // promised something that does nothing — the one thing a menu should
        // never do.
        let shortcut = summonHotKey == nil ? nil : AppPreferences.summonShortcut.value
        statusOpenItem?.keyEquivalent = shortcut?.keyEquivalentString ?? ""
        statusOpenItem?.keyEquivalentModifierMask = shortcut?.modifiers.cocoa ?? []
    }

    /// Three surfaces offer the keyboard toggle, so all three show its state.
    ///
    /// The toolbar button was the one that did not, for as long as it existed:
    /// the two menus carried a checkmark while the button in the title bar
    /// offered to "show or hide" without saying which. One function, called
    /// from the three places that change the drawer, is what keeps them from
    /// disagreeing.
    func markKeyboardMenus(_ visible: Bool) {
        keyboardMenuItem?.state = visible ? .on : .off
        statusKeyboardItem?.state = visible ? .on : .off
        toolbarController?.markKeyboard(visible)
    }
    /// Every key equivalent carries Command.
    ///
    /// In the web-view version this rule was load-bearing because WKWebView
    /// hands keys to the page first. Here the reason is different but the rule
    /// is the same: the typing view consumes bare keys as *typing*, so a
    /// bare-letter shortcut would either be swallowed mid-drill or steal a
    /// character from the passage.
    func makeMenu() -> NSMenu {
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
        // Not "Quit", and not `terminate`. TYPE lives in the menu bar, so ⌘Q
        // puts it away rather than ending it — and the item says so, because
        // a "Quit" that does not quit is worse than no item at all. The one
        // place the app really ends is the status item's own Quit, which is
        // where someone goes when they mean it.
        let putAway = appMenu.addItem(
            withTitle: "Close to Menu Bar", action: #selector(hideToMenuBar(_:)),
            keyEquivalent: "q")
        putAway.target = self
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
        for channel in CorpusChannel.allCases {
            // Stated per channel, not derived from declaration order. `index +
            // 4` meant reordering the enum silently moved everyone's shortcuts,
            // and a seventh channel would have produced the two-character
            // equivalent "10", which is not a shortcut at all. A channel with
            // no entry here simply has none, which is the honest outcome for
            // one added later.
            let item = sourceMenu.addItem(
                withTitle: channel.label, action: #selector(chooseSource(_:)),
                keyEquivalent: Self.sourceShortcuts[channel.rawValue] ?? "")
            item.target = self
            item.representedObject = channel.rawValue
        }
        sourceItem.submenu = sourceMenu
        viewMenu.addItem(sourceItem)
        sourceMenuItems = sourceMenu.items

        let soundItem = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        soundItem.submenu = makeSoundMenu()
        viewMenu.addItem(soundItem)
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
        // Close was missing, which is why ⌘W did nothing at all. `performClose`
        // rather than a custom action, so it closes whichever window is in
        // front — Settings and Library should close like windows, not put the
        // whole app away.
        windowMenu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowItem.submenu = windowMenu
        root.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return root
    }
    /// A checkmark on the active source, so the menu says which corpus the
    /// text is coming from rather than only offering to change it.
    func markSourceMenu() {
        let active = practice?.channel.rawValue
        for item in sourceMenuItems {
            item.state = (item.representedObject as? String) == active ? .on : .off
        }
        // The toolbar's source menu carries the same checkmark, so it has to be
        // told too — otherwise changing the source from the menu bar leaves the
        // toolbar claiming the old one.
        toolbarController?.refresh()
    }
    /// The Sound submenu, built fresh for each menu that wants one.
    ///
    /// One builder rather than two hand-kept copies: the menu bar and the
    /// status item offer exactly the same choices, and the last thing this
    /// should grow is two lists that drift.
    ///
    /// The packs sit under the toggle rather than replacing it. Turning sound
    /// off and picking a pack are different intentions — the toggle is the one
    /// with a shortcut because it is the one wanted in a hurry, when someone
    /// walks into the room.
    func makeSoundMenu() -> NSMenu {
        let menu = NSMenu(title: "Sound")
        // This menu's enabled state is decided in `markSoundMenus`, from
        // whether a foreign app is known and whether global sound is on.
        // AppKit's automatic validation, which only asks whether the target
        // responds to the action, would re-enable "Mute in …" over the top of
        // that — and it responds, always. Two rules for one property is one
        // too many.
        menu.autoenablesItems = false
        // Not "Sound" — the submenu is already called that, and "Sound ▸
        // Sound" reads like a mistake. A verb phrase with a checkmark, the
        // same shape as "Show Keyboard" two items up.
        let toggle = menu.addItem(
            withTitle: "Play Sounds", action: #selector(toggleSound(_:)), keyEquivalent: "")
        toggle.target = self
        // Directly under it, because it answers the next question someone
        // asks about the first: sound, yes — but where? This is the item that
        // matters most from the status bar, since the case for system-wide
        // sound is precisely the one where TYPE has no window open.
        let everywhere = menu.addItem(
            withTitle: "Sound in Every App", action: #selector(toggleGlobalSound(_:)),
            keyEquivalent: "")
        everywhere.target = self
        // Directly under the scope switch, because it refines it: sound in
        // every app, except this one.
        let mute = menu.addItem(
            withTitle: "Mute in This App", action: #selector(toggleMuteFrontmost(_:)),
            keyEquivalent: "")
        mute.target = self
        menu.addItem(.separator())
        for pack in KeySoundPack.all {
            let item = menu.addItem(
                withTitle: pack.label, action: #selector(chooseSoundPack(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pack.name
        }
        // So the item that names the frontmost application is right when the
        // menu is opened rather than when it was built.
        menu.delegate = self
        soundMenus.append(menu)
        markSoundMenus()
        return menu
    }
    /// A checkmark on the active pack, and on the toggle when sound is on.
    /// Called from everywhere the pack can change — the menus, the Settings
    /// window, and the global shortcut — so the two menus never disagree with
    /// each other or with what is actually audible.
    func markSoundMenus() {
        let active = AppPreferences.soundPack.value
        let shortcut = AppPreferences.soundShortcut.value
        for menu in soundMenus {
            for item in menu.items {
                if let name = item.representedObject as? String {
                    item.state = name == active.name ? .on : .off
                } else if item.action == #selector(toggleMuteFrontmost(_:)) {
                    let app = globalSound.lastForeignApp
                    item.title = app?.localizedName.map { "Mute in \($0)" } ?? "Mute in This App"
                    item.isEnabled =
                        app?.bundleIdentifier != nil && AppPreferences.globalSound.value
                    item.state = (app?.bundleIdentifier).map(AppPreferences.mutedApps.contains)
                        == true ? .on : .off
                } else if item.action == #selector(toggleGlobalSound(_:)) {
                    let on = AppPreferences.globalSound.value
                    item.state = on ? .on : .off
                    // On, but muted by the system, is a state the user cannot
                    // otherwise see from here — the monitor is installed and
                    // never called. Say so where the switch is.
                    // Three states, because "on" is not the same as "heard".
                    // The status menu is the only surface a menu-bar-only
                    // build has, so a setting that is on and silent has to
                    // explain itself here or nowhere.
                    if on, !GlobalKeySound.isPermitted {
                        item.title = "Sound in Every App (Needs Input Monitoring)"
                    } else if on, Channel.shouldYieldToSibling {
                        item.title = "Sound in Every App (Another Copy Started First)"
                    } else {
                        item.title = "Sound in Every App"
                    }
                } else if item.action == #selector(toggleSound(_:)) {
                    item.state = AppPreferences.soundIsOn ? .on : .off
                    // The menu advertises whatever is actually registered, so
                    // it cannot end up printing a combination that no longer
                    // does anything. Cleared means no shortcut shown.
                    item.keyEquivalent = shortcut?.keyEquivalentString ?? ""
                    item.keyEquivalentModifierMask = shortcut?.modifiers.cocoa ?? []
                }
            }
        }
    }
}
