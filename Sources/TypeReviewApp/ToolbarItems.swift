import AppKit

/// One way to build a toolbar button, for the two toolbars that want the same
/// one.
///
/// The practice window and the Library window each had their own copy of this,
/// identical but for the target and one flag — so the styling decision that
/// makes a button look like a current Mac toolbar button lived in two places
/// and would have had to be changed in both.
@MainActor
enum ToolbarItems {
    /// A bordered image button.
    ///
    /// Bordered is the macOS 11-and-later toolbar button: a capsule that
    /// reacts to the pointer. Unbordered items are the flat icons of the
    /// previous decade.
    ///
    /// `autovalidates` is the caller's to decide. The Library drives its
    /// buttons from the table's selection and must not be second-guessed on
    /// every runloop pass; the practice toolbar has nothing to validate.
    static func button(
        _ identifier: NSToolbarItem.Identifier, label: String, symbol: String, tip: String,
        target: AnyObject, action: Selector, autovalidates: Bool = true
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = Theme.toolbarSymbol(symbol)
        item.target = target
        item.action = action
        item.isBordered = true
        item.autovalidates = autovalidates
        return item
    }

    /// A button that shows whether the thing it controls is on.
    ///
    /// The keyboard toggle was an ordinary button, which meant the toolbar
    /// could offer to "show or hide the on-screen keyboard" without ever
    /// saying which of the two it was about to do. The status menu had carried
    /// a checkmark for this the whole time, so the two surfaces disagreed
    /// about how much they were willing to tell you.
    ///
    /// Built from an `NSButton` rather than by swapping `NSToolbarItem.image`,
    /// because `.pushOnPushOff` is what draws the filled capsule macOS uses
    /// for a toolbar toggle everywhere else — and a home-made "on" look would
    /// be a second opinion about a thing the system already has one about.
    static func toggle(
        _ identifier: NSToolbarItem.Identifier, label: String, symbol: String, tip: String,
        target: AnyObject, action: Selector
    ) -> (item: NSToolbarItem, button: NSButton) {
        let button = NSButton(frame: .zero)
        button.image = Theme.toolbarSymbol(symbol)
        button.imagePosition = .imageOnly
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .toolbar
        button.target = target
        button.action = action
        // A custom view has no intrinsic toolbar sizing, so it is given the
        // same footprint the bordered items get rather than collapsing to the
        // image's own size and sitting a few points narrower than its
        // neighbours.
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 38),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.view = button
        // Off: `autovalidates` asks the target whether the item is *enabled*,
        // and with a custom view AppKit disables it outright unless the target
        // implements validation. The button is always enabled — there is no
        // state in which showing or hiding the keyboard is unavailable.
        item.autovalidates = false
        return (item, button)
    }
}
