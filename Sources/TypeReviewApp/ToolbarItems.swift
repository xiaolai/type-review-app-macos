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
}
