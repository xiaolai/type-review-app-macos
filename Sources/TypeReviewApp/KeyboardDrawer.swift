import AppKit

/// The keyboard, in a drawer that slides out below the window.
///
/// The main window never changes size. The drawer is a separate borderless
/// window with no background, attached as a child of the main one and parked
/// against its bottom edge — so what the user sees is the keyboard sliding out
/// from under the window and back, with nothing else drawn around it.
///
/// A child window because a drawer is, by definition, outside its parent. The
/// two earlier attempts were both inside it: a split pane traded space with
/// the passage, and a clipping band ate into the window's own height. Neither
/// is a drawer. `NSWindow.addChildWindow` gives the part that makes it one —
/// the drawer moves, orders, miniaturises and closes with the parent, with no
/// bookkeeping here. (`NSDrawer`, the class, has been deprecated since 10.13.)
@MainActor
final class KeyboardDrawer {
    let keyboard = KeyboardView()
    private let window: NSWindow
    private weak var parent: NSWindow?
    // Kept alive, never removed: the drawer lives as long as the app does, so
    // there is no teardown to get wrong.
    private var observers: [NSObjectProtocol] = []
    private var keyboardHeight: NSLayoutConstraint!

    private(set) var isOpen = false

    /// How wide the drawer is relative to the window it hangs from. Not full
    /// width: a drawer inset a little on each side reads as a separate object
    /// rather than as the window's own bottom edge.
    private static let widthFraction: CGFloat = 0.95
    /// The air between the window's bottom edge and the drawer's top. Without
    /// it the two shapes touch and merge into one.
    private static let gap: CGFloat = 10
    /// A window cannot have zero height, so "shut" is one point tall and
    /// ordered out once it gets there.
    private static let shutHeight: CGFloat = 1

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: Self.shutHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        // No background, and therefore no shadow: macOS derives a window's
        // shadow from its frame, not from what it draws, so a transparent
        // full-width window would cast a rectangular shadow around nothing.
        // The keyboard's own case supplies the edge.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Display only. Without this the transparent area either swallows
        // clicks meant for whatever is behind it or pulls focus off the
        // passage, and the keyboard is a picture, not a control.
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]

        let content = NSView()
        content.clipsToBounds = true
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(keyboard)
        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // Pinned to the bottom, so as the window grows downward the
            // keyboard travels with its lower edge and is revealed bottom
            // first — a sheet coming out of a slot. Pinned to the top it would
            // sit still and unroll, which is a different effect.
            keyboard.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        // The keyboard's height follows the drawer's width, so the constraint
        // is held rather than set once.
        keyboardHeight = keyboard.heightAnchor.constraint(equalToConstant: 1)
        keyboardHeight.isActive = true
        window.contentView = content
    }

    func attach(to parent: NSWindow) {
        self.parent = parent
        // The child relationship handles moving, ordering and closing. Width
        // is the one thing it does not track, so a resize is observed. A
        // height change moves the parent's bottom edge too, which is why this
        // recomputes the whole frame rather than just the width.
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: parent, queue: .main
                ) { [weak self] _ in
                    guard let self, self.isOpen else { return }
                    self.reframe()
                })
        }
        // A drawer hanging below a full-screen window is off the display
        // entirely. Put it away and bring it back with the window.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willEnterFullScreenNotification, object: parent, queue: .main
            ) { [weak self] _ in self?.window.orderOut(nil) })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: parent, queue: .main
            ) { [weak self] _ in
                guard let self, self.isOpen else { return }
                self.present()
            })
    }

    /// The keyboard is sized from the drawer's width, so the drawer's width has
    /// to be known before its height can be.
    private var drawerWidth: CGFloat {
        (parent?.frame.width ?? 0) * Self.widthFraction
    }

    private func frame(open: Bool) -> NSRect {
        guard let parent else { return .zero }
        let width = drawerWidth
        let height = open ? keyboard.naturalHeight(forWidth: width) : Self.shutHeight
        return NSRect(
            x: parent.frame.midX - width / 2, y: parent.frame.minY - Self.gap - height,
            width: width, height: height)
    }

    private func present() {
        guard let parent else { return }
        reframe()
        parent.addChildWindow(window, ordered: .above)
    }

    /// Re-lays the drawer against the window it hangs from. Called whenever
    /// the parent moves or resizes, and after a preference changes the
    /// window's shape.
    func reframe() {
        keyboardHeight.constant = keyboard.naturalHeight(forWidth: drawerWidth)
        guard isOpen else { return }
        window.setFrame(frame(open: true), display: true)
    }

    func setOpen(_ open: Bool, animated: Bool) {
        guard let parent, open != isOpen else { return }
        isOpen = open

        if open {
            keyboardHeight.constant = keyboard.naturalHeight(forWidth: drawerWidth)
            makeRoomBelow(parent)
            // Ordered in shut, then grown: appearing at full size and then
            // animating would show the finished state for one frame first.
            window.setFrame(frame(open: false), display: false)
            parent.addChildWindow(window, ordered: .above)
        }

        let duration = AppPreferences.drawerSeconds.value
        guard animated, duration > 0.01 else {
            if open {
                window.setFrame(frame(open: true), display: true)
            } else {
                parent.removeChildWindow(window)
                window.orderOut(nil)
            }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame(open: open), display: true)
        } completionHandler: { [weak self] in
            guard let self, !self.isOpen else { return }
            parent.removeChildWindow(self.window)
            self.window.orderOut(nil)
        }
    }

    /// Nudges the window up if the drawer would open past the bottom of the
    /// screen. What Apple's own drawers did, and the alternative is a drawer
    /// the user cannot see and has no way to discover.
    private func makeRoomBelow(_ parent: NSWindow) {
        guard let screen = parent.screen else { return }
        let needed = Self.gap + keyboard.naturalHeight(forWidth: drawerWidth)
        let shortfall = screen.visibleFrame.minY - (parent.frame.minY - needed)
        guard shortfall > 0 else { return }
        var moved = parent.frame
        moved.origin.y = min(
            moved.origin.y + shortfall, screen.visibleFrame.maxY - moved.height)
        parent.setFrame(moved, display: true, animate: true)
    }
}
