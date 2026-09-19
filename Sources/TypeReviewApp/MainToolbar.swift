import AppKit
import TypeReviewKit

/// The main window's toolbar.
///
/// A window without an `NSToolbar` gets the short, opaque title bar macOS has
/// drawn since before Big Sur: title centred in its own strip, traffic lights
/// centred in a band that is doing nothing else. The unified toolbar is what
/// merges that strip with the toolbar into one material band — which is where
/// the traffic lights move to, and the single largest reason a Mac app reads as
/// current or as a decade old. There is no API to reposition the lights; this
/// is the lever.
///
/// Commands live here; the live numbers do not. A toolbar is for things the
/// user can do, and words-per-minute is not one of them — it is what the run is
/// producing, so it stays with the text it describes.
///
/// The switch between Practice and Play sits in the middle. The two items
/// leading it belong to the screen showing — Source and New Text, or Game and
/// New Game — and swap with it; the three trailing it open the same windows
/// from either screen, so they never move.
///
/// Its own type rather than an extension on `AppDelegate`: the delegate is
/// already the longest file in the app, and the toolbar needs none of its state
/// — only somewhere to send its actions, and a way to read the two things its
/// menus tick: the source, and the game's mode and rules.
@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate {
    var onNewText: () -> Void = {}
    var onToggleKeyboard: () -> Void = {}
    var onShowLibrary: () -> Void = {}
    var onShowStats: () -> Void = {}
    var onChooseSource: (CorpusChannel) -> Void = { _ in }
    var onSwitchScreen: (MainScreen) -> Void = { _ in }
    var onNewGame: () -> Void = {}
    var onChoosePlayMode: (PlayMode) -> Void = { _ in }
    var onChoosePlayRules: (_ gentle: Bool) -> Void = { _ in }
    /// Read rather than stored, like `currentChannel`.
    var currentPlay: () -> (mode: PlayMode, gentle: Bool) = { (.words, true) }
    /// Read rather than stored, so the checkmark reflects the channel even when
    /// it was changed from the menu bar or the status item.
    var currentChannel: () -> CorpusChannel = { .auto }

    private var sourceItem: NSMenuToolbarItem?
    private var gameItem: NSMenuToolbarItem?
    private weak var toolbar: NSToolbar?
    private weak var screenSwitch: NSSegmentedControl?
    private(set) var screen: MainScreen = .practice

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "TypeReviewMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.screenSwitch]
        self.toolbar = toolbar
        return toolbar
    }

    /// Shows a screen's own leading items and marks the switch.
    ///
    /// Items are swapped in place rather than the toolbar being replaced, so
    /// the switch and the trailing three stay exactly where they were.
    func show(_ screen: MainScreen) {
        screenSwitch?.selectedSegment = Self.segment(of: screen)
        guard screen != self.screen, let toolbar else { return }
        self.screen = screen
        let (leaving, arriving) =
            screen == .play ? (Self.practiceLead, Self.playLead) : (Self.playLead, Self.practiceLead)
        for identifier in leaving {
            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier }) {
                toolbar.removeItem(at: index)
            }
        }
        for (index, identifier) in arriving.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
    }

    /// Refreshes the game item's checkmarks, the way `refresh` does the
    /// source's.
    func refreshPlay() {
        gameItem?.menu = gameMenu()
    }

    /// Refreshes the source item's checkmark. Called whenever the channel
    /// changes anywhere, for the same reason `markSourceMenu` exists.
    func refresh() {
        guard let sourceItem else { return }
        sourceItem.menu = sourceMenu()
    }

    /// Shows whether the keyboard drawer is out.
    ///
    /// Driven from `markKeyboardMenus`, which is the one place that already
    /// knew, so the toolbar cannot disagree with the two menus that carry the
    /// same checkmark. A toggle kept in step by three separate callers is a
    /// toggle that is eventually wrong in one of them.
    func markKeyboard(_ visible: Bool) {
        keyboardButton?.state = visible ? .on : .off
    }

    // MARK: - Items

    private weak var keyboardButton: NSButton?

    private static let source = NSToolbarItem.Identifier("source")
    private static let newText = NSToolbarItem.Identifier("newText")
    private static let keyboard = NSToolbarItem.Identifier("keyboard")
    private static let library = NSToolbarItem.Identifier("library")
    private static let stats = NSToolbarItem.Identifier("stats")
    private static let screenSwitch = NSToolbarItem.Identifier("screen")
    private static let game = NSToolbarItem.Identifier("game")
    private static let newGame = NSToolbarItem.Identifier("newGame")

    // Source and new-text lead, because they decide what you are about to type;
    // on Play, what falls and a new game do the same job. The three windows sit
    // at the trailing edge, away from the text. The app's mark is not here — it
    // is a title-bar accessory, so it sits bare rather than in a button's
    // capsule. See `TitleMarkController`.
    private static let practiceLead: [NSToolbarItem.Identifier] = [source, newText]
    private static let playLead: [NSToolbarItem.Identifier] = [game, newGame]
    private static let trailing: [NSToolbarItem.Identifier] = [keyboard, library, stats]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.practiceLead + [.flexibleSpace, Self.screenSwitch, .flexibleSpace] + Self.trailing
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.practiceLead + Self.playLead + [.flexibleSpace, Self.screenSwitch] + Self.trailing
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.source:
            return makeSourceItem()
        case Self.newText:
            return button(
                identifier, label: "New Text", symbol: "shuffle",
                tip: "Fresh passage (⇥)", action: #selector(newTextPressed))
        case Self.screenSwitch:
            return makeScreenSwitchItem()
        case Self.game:
            return makeGameItem()
        case Self.newGame:
            return button(
                identifier, label: "New Game", symbol: "arrow.counterclockwise",
                tip: "Start again (⇥)", action: #selector(newGamePressed))
        case Self.keyboard:
            return makeKeyboardItem()
        case Self.library:
            return button(
                identifier, label: "Library", symbol: "books.vertical",
                tip: "Your own practice text", action: #selector(libraryPressed))
        case Self.stats:
            return button(
                // A trend line, not `chart.bar`. Bars at toolbar size read as
                // signal strength or a level meter — a status indicator rather
                // than somewhere to go — and what this window actually shows is
                // speed over time.
                identifier, label: "Statistics", symbol: "chart.line.uptrend.xyaxis",
                tip: "Speed, streaks and slowest keys", action: #selector(statsPressed))
        default:
            return nil
        }
    }

    private func makeSourceItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: Self.source)
        item.label = "Source"
        item.toolTip = "Where practice text comes from"
        item.image = symbol("text.book.closed")
        item.menu = sourceMenu()
        sourceItem = item
        return item
    }

    /// One segment per screen, in `MainScreen`'s order, named and tipped as
    /// the View menu names them.
    private func makeScreenSwitchItem() -> NSToolbarItem {
        let screens = MainScreen.allCases
        let control = NSSegmentedControl(
            labels: screens.map(\.title), trackingMode: .selectOne, target: self,
            action: #selector(screenPicked(_:)))
        for (segment, screen) in screens.enumerated() {
            control.setToolTip("\(screen.title) (\(screen.shortcutLabel))", forSegment: segment)
        }
        control.selectedSegment = Self.segment(of: screen)
        screenSwitch = control
        let item = NSToolbarItem(itemIdentifier: Self.screenSwitch)
        item.label = "Screen"
        item.paletteLabel = "Screen"
        item.view = control
        return item
    }

    private static func segment(of screen: MainScreen) -> Int {
        // Every case is in `allCases`; -1, no segment, is unreachable.
        MainScreen.allCases.firstIndex(of: screen) ?? -1
    }

    private func makeGameItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: Self.game)
        item.label = "Game"
        item.toolTip = "What falls, and what happens when it lands"
        item.image = symbol("gamecontroller")
        item.menu = gameMenu()
        gameItem = item
        return item
    }

    private func makeKeyboardItem() -> NSToolbarItem {
        let (item, button) = ToolbarItems.toggle(
            Self.keyboard, label: "Keyboard", symbol: "keyboard",
            tip: "Show or hide the on-screen keyboard",
            target: self, action: #selector(keyboardPressed))
        keyboardButton = button
        // Seeded from the preference rather than left off. The toolbar is
        // built after the drawer has already been opened or not, so a
        // button that started off would have been wrong on every launch
        // where the keyboard is showing — which is the default one.
        button.state = AppPreferences.showKeyboard.value ? .on : .off
        return item
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier, label: String, symbol name: String,
        tip: String, action: Selector
    ) -> NSToolbarItem {
        ToolbarItems.button(
            identifier, label: label, symbol: name, tip: tip, target: self, action: action)
    }

    /// A missing symbol yields a label-only item rather than an invisible
    /// button. Every name used here has shipped since well before the app's
    /// macOS 14 floor, so this is a guard, not an expectation.
    private func symbol(_ name: String) -> NSImage? {
        Theme.toolbarSymbol(name)
    }

    private func sourceMenu() -> NSMenu {
        let menu = NSMenu()
        let active = currentChannel()
        for channel in CorpusChannel.allCases {
            let item = NSMenuItem(
                title: channel.label, action: #selector(sourcePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = channel.rawValue
            item.state = channel == active ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// What falls, then the rules, each with its checkmark.
    private func gameMenu() -> NSMenu {
        let menu = NSMenu()
        let now = currentPlay()
        for mode in PlayMode.allCases {
            let item = NSMenuItem(
                title: mode.label, action: #selector(playModePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == now.mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, gentle) in [("Gentle — nothing is lost", true), ("Arcade — three lives", false)] {
            let item = NSMenuItem(
                title: title, action: #selector(playRulesPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = gentle ? 1 : 0
            item.state = gentle == now.gentle ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Actions

    @objc private func newTextPressed() { onNewText() }
    @objc private func newGamePressed() { onNewGame() }

    @objc private func screenPicked(_ sender: NSSegmentedControl) {
        let screens = MainScreen.allCases
        guard screens.indices.contains(sender.selectedSegment) else { return }
        onSwitchScreen(screens[sender.selectedSegment])
    }

    @objc private func playModePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = PlayMode(rawValue: raw),
            mode != currentPlay().mode
        else { return }
        onChoosePlayMode(mode)
        refreshPlay()
    }

    @objc private func playRulesPicked(_ sender: NSMenuItem) {
        let gentle = sender.tag == 1
        guard gentle != currentPlay().gentle else { return }
        onChoosePlayRules(gentle)
        refreshPlay()
    }
    @objc private func keyboardPressed() { onToggleKeyboard() }
    @objc private func libraryPressed() { onShowLibrary() }
    @objc private func statsPressed() { onShowStats() }

    @objc private func sourcePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let channel = CorpusChannel(rawValue: raw)
        else { return }
        // No guard on the unchanged channel here: `AppDelegate.setChannel` has
        // it, and both this and the View menu go through that one function. A
        // second copy here is what let the View menu keep the bug after this
        // path was fixed.
        // No `refresh()` here: `onChooseSource` marks the source menus, and
        // that path already calls back into this controller. Refreshing again
        // rebuilt the same menu twice for one click.
        onChooseSource(channel)
    }
}
