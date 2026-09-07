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
    /// `keyboard.badge.eye` as a template image, so macOS inverts it for a
    /// dark menu bar and dims it when the bar is inactive — the two things a
    /// hand-tinted image gets wrong. The same mark as the app icon, because
    /// there is no reason for an app to have two faces; the badge is the point
    /// either way, saying this icon leads somewhere rather than being a status
    /// light.
    ///
    /// The menu is the app's own verbs, not a second copy of the main menu:
    /// what someone reaches for when TYPE is not the front app.
    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Sized explicitly. Left at its default the symbol draws 19 by 11
        // points of ink, which is the shortest thing in the menu bar — its
        // neighbours run 12 to 15.5 tall — because `keyboard.badge.eye` is a
        // wide, short mark and the default configuration sizes by cap
        // height. `.large` at 13 points brings the ink to roughly 24 by 14,
        // matching the taller neighbours and a hair wider than the widest.
        let image = Theme.symbol(
            "keyboard.badge.eye", size: Theme.SymbolSize.menuBar, scale: .large,
            description: "TYPE")
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
    /// Two menus offer the keyboard toggle, so both carry the checkmark.
    func markKeyboardMenus(_ visible: Bool) {
        keyboardMenuItem?.state = visible ? .on : .off
        statusKeyboardItem?.state = visible ? .on : .off
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
        menu.addItem(.separator())
        for pack in KeySoundPack.all {
            let item = menu.addItem(
                withTitle: pack.label, action: #selector(chooseSoundPack(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pack.name
        }
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
                } else if item.action == #selector(toggleGlobalSound(_:)) {
                    let on = AppPreferences.globalSound.value
                    item.state = on ? .on : .off
                    // On, but muted by the system, is a state the user cannot
                    // otherwise see from here — the monitor is installed and
                    // never called. Say so where the switch is.
                    item.title = on && !GlobalKeySound.isPermitted
                        ? "Sound in Every App (Needs Accessibility)" : "Sound in Every App"
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
