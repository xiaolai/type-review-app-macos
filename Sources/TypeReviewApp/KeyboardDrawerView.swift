import AppKit

/// The keyboard, as something that slides out of the bottom of the window.
///
/// A clipping band pinned to the window's bottom edge, with the keyboard
/// anchored to the *top* of that band at its full height. Shrinking the band's
/// height therefore carries the keyboard down with it and clips what has
/// passed the window edge — so the keyboard slides out of sight rather than
/// being cropped in place, and the practice screen above reclaims the space in
/// the same motion.
///
/// Not `NSSplitView`: that gives a resizable pane with a divider, which is a
/// different thing — the panes stay on screen and merely trade space. Not
/// `NSDrawer` either, which has been deprecated since 10.13 and slides outside
/// the window entirely.
final class KeyboardDrawerView: NSView {
    let keyboard = KeyboardView()
    private var openHeight: NSLayoutConstraint!

    private(set) var isOpen = true

    /// Long enough to be seen, short enough not to be waited for.
    private static let duration: TimeInterval = 0.24

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The clip is the whole mechanism: without it the keyboard simply
        // draws over the passage on its way out.
        clipsToBounds = true

        keyboard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboard)
        let height = keyboard.naturalHeight
        openHeight = heightAnchor.constraint(equalToConstant: height)
        NSLayoutConstraint.activate([
            openHeight,
            keyboard.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Anchored to the top, not the bottom. Pinned to the bottom the
            // keyboard would stay put and lose its top rows as the band
            // closed; pinned to the top it travels with the band.
            keyboard.topAnchor.constraint(equalTo: topAnchor),
            keyboard.heightAnchor.constraint(equalToConstant: height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A hairline where the drawer meets the practice screen, so the two read
    /// as separate surfaces while the drawer is out.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        // maxY, not 0: this view is not flipped, so y=0 is the bottom edge —
        // which is off the window, where a separator is no use to anyone.
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func setOpen(_ open: Bool, animated: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        let target = open ? keyboard.naturalHeight : 0
        guard animated else {
            openHeight.constant = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            // Ease out: the drawer leaves quickly and arrives gently, which is
            // how a physical one behaves and how every other Mac panel moves.
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            openHeight.animator().constant = target
            superview?.layoutSubtreeIfNeeded()
        }
    }
}
