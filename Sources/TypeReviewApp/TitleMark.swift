import AppKit

/// The app's mark, where the window's title used to be, in a colour that
/// changes every time the window opens.
///
/// A title-bar accessory rather than a toolbar item, and the difference is
/// visible: macOS gives every toolbar item its own glass capsule, so the mark
/// sat in a button and read as one more control. An accessory is drawn in the
/// title bar itself, bare, which is what a name should look like. `.leading`
/// puts it where the word was, so nothing else in the bar has to move.
@MainActor
enum TitleMark {
    /// This window's hue. Only the hue is remembered — saturation and
    /// brightness depend on whether the title bar is light or dark, and that
    /// can change under a window that is already open.
    private static var hue = CGFloat.random(in: 0..<1)
    private static weak var markView: MarkView?

    /// A new colour. Called when the window opens rather than once at launch:
    /// the app lives in the menu bar now and can go days without quitting, so
    /// tying the colour to the process would mean seeing the same one all week.
    static func reroll() {
        hue = CGFloat.random(in: 0..<1)
        markView?.apply(hue: hue)
    }

    static func install(in window: NSWindow) {
        let mark = MarkView()
        mark.apply(hue: hue)
        mark.toolTip = "TYPE"
        mark.translatesAutoresizingMaskIntoConstraints = false
        markView = mark

        // The accessory's own view is sized by the title bar; the mark is
        // inset inside it so it does not touch the traffic lights on one side
        // or the first toolbar item on the other.
        let container = NSView()
        container.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            mark.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            mark.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.frame = NSRect(
            x: 0, y: 0, width: Theme.SymbolSize.title + 22, height: Theme.SymbolSize.title + 8)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)
    }

    /// An image view that bakes the colour into the symbol rather than tinting
    /// it.
    ///
    /// `contentTintColor` is the obvious answer and was tried first. In this
    /// position it does not take: the view accepts the colour — reading the
    /// property back returns exactly what was set — and the mark still renders
    /// flat grey, unchanged across every reopen. Baking the colour into the
    /// symbol with `paletteColors` produces a different *image*, which nothing
    /// can decline to notice, and four consecutive opens then give four
    /// distinct colours.
    ///
    /// The subclass exists for the appearance hook: a baked colour is resolved
    /// for light or dark at the moment it is made, so switching appearance
    /// under an open window has to rebuild it.
    private final class MarkView: NSImageView {
        private var hue: CGFloat = 0

        func apply(hue: CGFloat) {
            self.hue = hue
            image = Theme.titleMark(tintedWith: Theme.tint(hue: hue, for: effectiveAppearance))
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            apply(hue: hue)
        }
    }
}
