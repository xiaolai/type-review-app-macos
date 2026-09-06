import AppKit
import TypeReviewKit

/// The practice window's toolbar.
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
/// Its own type rather than an extension on `AppDelegate`: the delegate is
/// already the longest file in the app, and the toolbar needs none of its state
/// — only somewhere to send five actions.
@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate {
    var onNewText: () -> Void = {}
    var onToggleKeyboard: () -> Void = {}
    var onShowLibrary: () -> Void = {}
    var onShowStats: () -> Void = {}
    var onChooseSource: (CorpusChannel) -> Void = { _ in }
    /// Read rather than stored, so the checkmark reflects the channel even when
    /// it was changed from the menu bar or the status item.
    var currentChannel: () -> CorpusChannel = { .auto }

    private var sourceItem: NSMenuToolbarItem?

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "TypeReviewMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    /// Refreshes the source item's checkmark. Called whenever the channel
    /// changes anywhere, for the same reason `markSourceMenu` exists.
    func refresh() {
        guard let sourceItem else { return }
        sourceItem.menu = sourceMenu()
    }

    // MARK: - Items

    private static let source = NSToolbarItem.Identifier("source")
    private static let newText = NSToolbarItem.Identifier("newText")
    private static let keyboard = NSToolbarItem.Identifier("keyboard")
    private static let library = NSToolbarItem.Identifier("library")
    private static let stats = NSToolbarItem.Identifier("stats")

    // Source and new-text lead, because they decide what you are about to type.
    // The three windows sit at the trailing edge, away from the text. The app's
    // mark is not here — it is a title-bar accessory, so it sits bare rather
    // than in a button's capsule. See `TitleMarkController`.
    private static let layout: [NSToolbarItem.Identifier] = [
        source, newText, .flexibleSpace, keyboard, library, stats,
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.layout
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.layout
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.source:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Source"
            item.toolTip = "Where practice text comes from"
            item.image = symbol("text.book.closed")
            item.menu = sourceMenu()
            sourceItem = item
            return item
        case Self.newText:
            return button(
                identifier, label: "New Text", symbol: "shuffle",
                tip: "Fresh passage (⇥)", action: #selector(newTextPressed))
        case Self.keyboard:
            return button(
                identifier, label: "Keyboard", symbol: "keyboard",
                tip: "Show or hide the on-screen keyboard", action: #selector(keyboardPressed))
        case Self.library:
            return button(
                identifier, label: "Library", symbol: "books.vertical",
                tip: "Your own practice text", action: #selector(libraryPressed))
        case Self.stats:
            return button(
                identifier, label: "Statistics", symbol: "chart.bar",
                tip: "Speed, streaks and slowest keys", action: #selector(statsPressed))
        default:
            return nil
        }
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier, label: String, symbol name: String,
        tip: String, action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = symbol(name)
        item.target = self
        item.action = action
        // Bordered, which is the macOS 11-and-later toolbar button: a capsule
        // that reacts to the pointer. Unbordered items are the flat icons of
        // the previous decade.
        item.isBordered = true
        return item
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

    // MARK: - Actions

    @objc private func newTextPressed() { onNewText() }
    @objc private func keyboardPressed() { onToggleKeyboard() }
    @objc private func libraryPressed() { onShowLibrary() }
    @objc private func statsPressed() { onShowStats() }

    @objc private func sourcePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let channel = CorpusChannel(rawValue: raw)
        else { return }
        onChooseSource(channel)
        refresh()
    }
}
