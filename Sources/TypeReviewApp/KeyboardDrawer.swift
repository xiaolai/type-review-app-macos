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

    /// How wide the drawer is relative to the window it hangs from, and the
    /// air between them. Both are settings: a drawer inset on each side and
    /// held off the window reads as a separate object rather than as the
    /// window's own bottom edge, but how much of each is taste.
    private var widthFraction: CGFloat { CGFloat(AppPreferences.drawerWidth.value) / 100 }
    private var gap: CGFloat { CGFloat(AppPreferences.drawerGap.value) }
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
        // Every observer below is registered with `queue: .main`, so its block
        // is delivered on the main thread — but the block itself is `@Sendable`
        // and therefore nonisolated, which this class is not. `assumeIsolated`
        // is the honest way to close that gap: it states the guarantee the
        // registration already provides and traps if it is ever untrue, rather
        // than hopping to a later runloop turn and reframing the drawer against
        // a window position that has since moved.
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: parent, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.isOpen else { return }
                        self.reframe()
                    }
                })
        }
        // A drawer hanging below a full-screen window is off the display
        // entirely. Put it away and bring it back with the window.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willEnterFullScreenNotification, object: parent, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.window.orderOut(nil) }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: parent, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isOpen else { return }
                    self.present()
                }
            })
    }

    /// The keyboard is sized from the drawer's width, so the drawer's width has
    /// to be known before its height can be.
    private var drawerWidth: CGFloat {
        (parent?.frame.width ?? 0) * widthFraction
    }

    private func frame(open: Bool) -> NSRect {
        guard let parent else { return .zero }
        let width = drawerWidth
        let height = open ? keyboard.naturalHeight(forWidth: width) : Self.shutHeight
        return NSRect(
            x: parent.frame.midX - width / 2, y: parent.frame.minY - gap - height,
            width: width, height: height)
    }

    /// Whether the parent is full screen, asked of the window rather than
    /// tracked.
    ///
    /// A tracked flag was the first attempt and it can go stale: entering full
    /// screen can *fail* — a second display disappearing, another app taking
    /// the space — and the notification that would clear the flag never
    /// arrives, so the drawer stays hidden for the rest of the session. The
    /// style mask cannot be wrong about this.
    private var isFullScreen: Bool { parent?.styleMask.contains(.fullScreen) ?? false }
    /// Set while an open or close animation is running, so a parent move
    /// during one does not snap the drawer to its finished frame.
    private var transition: Int = 0
    /// Guards against the move notification this method's own move produces.
    private var isMakingRoom = false

    /// Puts the drawer on screen beneath its parent, if it should be there.
    ///
    /// The full-screen test lives here rather than at each call site, so
    /// nothing can attach a drawer to a window that has no room below it.
    private func attach() {
        guard let parent, !isFullScreen, window.parent == nil else { return }
        parent.addChildWindow(window, ordered: .above)
    }

    private func present() {
        guard !isFullScreen else { return }
        reframe()
        attach()
    }

    /// Re-lays the drawer against the window it hangs from. Called whenever
    /// the parent moves or resizes, and after a preference changes the
    /// window's shape.
    func reframe() {
        keyboardHeight.constant = keyboard.naturalHeight(forWidth: drawerWidth)
        guard isOpen, !isFullScreen else { return }
        // Not while an animation is running. `reframe` is called from the
        // parent's move and resize notifications, and moving the window is
        // exactly what `makeRoomBelow` does at the start of an opening — so
        // opening the drawer used to jump it straight to its finished frame
        // and skip the reveal it had just started.
        guard transition == 0 else { return }
        // Clearance is rechecked, not assumed from when it opened. Widening
        // the keyboard or the gap in Settings makes an already-open drawer
        // taller, which can push it below the screen with nothing to notice.
        if let parent { makeRoomBelow(parent, animated: false) }
        window.setFrame(frame(open: true), display: true)
        // Put back if it was hidden for a full-screen transition that then did
        // not happen. `willEnterFullScreen` orders the drawer out before the
        // system has committed, and a failed entry sends nothing afterwards —
        // but it does move the window, which is what calls this.
        //
        // `attach()`, not `present()`. Calling `present()` from here was
        // mutual recursion — it calls `reframe()`, which called it back — and
        // any detached drawer would have run the stack out.
        attach()
    }

    /// Puts the drawer back after its parent has been closed and reopened.
    /// Closing the parent removes the child window from the screen but leaves
    /// this side of it thinking the drawer is out.
    func restoreIfOpen() {
        guard isOpen, window.parent == nil else { return }
        present()
    }

    func setOpen(_ open: Bool, animated: Bool) {
        guard let parent, open != isOpen else { return }
        isOpen = open

        if open {
            keyboardHeight.constant = keyboard.naturalHeight(forWidth: drawerWidth)
            makeRoomBelow(parent, animated: animated)
            // Ordered in shut, then grown: appearing at full size and then
            // animating would show the finished state for one frame first.
            window.setFrame(frame(open: false), display: false)
            attach()
        }

        let duration = AppPreferences.drawerSeconds.value
        guard animated, duration > 0.01 else {
            if open {
                window.setFrame(frame(open: true), display: true)
            } else {
                dismiss(from: parent)
            }
            return
        }

        // Identifies *this* transition. AppKit runs a completion handler for a
        // cancelled animation too, so opening and then quickly closing used to
        // let the opening's completion run last and hide a drawer that was
        // meant to stay — it checked only the current `isOpen`, which by then
        // said "closed" for the wrong reason.
        transition += 1
        let mine = transition
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame(open: open), display: true)
        } completionHandler: { [weak self] in
            // AppKit runs this on the main thread; the closure is `@Sendable`
            // and so cannot say that in the type system. Same reasoning as the
            // observers in `attach(to:)`.
            MainActor.assumeIsolated {
                guard let self, self.transition == mine else { return }
                self.transition = 0
                guard !self.isOpen else { return }
                self.dismiss(from: parent)
            }
        }
    }

    /// Takes the drawer off screen and out of the child-window relationship.
    private func dismiss(from parent: NSWindow) {
        parent.removeChildWindow(window)
        window.orderOut(nil)
    }

    /// Nudges the window up if the drawer would open past the bottom of the
    /// screen. What Apple's own drawers did, and the alternative is a drawer
    /// the user cannot see and has no way to discover.
    private func makeRoomBelow(_ parent: NSWindow, animated: Bool) {
        // Moving or resizing the parent is exactly what the observers in
        // `attach(to:)` listen for, and they call `reframe`, which calls this.
        guard !isMakingRoom, let screen = parent.screen else { return }
        isMakingRoom = true
        defer { isMakingRoom = false }
        let drawerHeight = keyboard.naturalHeight(forWidth: drawerWidth)
        let needed = gap + drawerHeight
        // Moving the window up cannot help when the window and the drawer
        // together are taller than the screen — it just clips the top instead
        // of the bottom. Shortening the window is what actually fits them, and
        // it is reversible: the height is derived from a preference, so the
        // next preference change puts it back.
        let available = screen.visibleFrame.height
        if parent.frame.height + needed > available {
            var shortened = parent.frame
            shortened.size.height = max(200, available - needed)
            shortened.origin.y = screen.visibleFrame.minY + needed
            parent.setFrame(shortened, display: true, animate: animated)
            return
        }
        let shortfall = screen.visibleFrame.minY - (parent.frame.minY - needed)
        guard shortfall > 0 else { return }
        var moved = parent.frame
        moved.origin.y = min(
            moved.origin.y + shortfall, screen.visibleFrame.maxY - moved.height)
        // The caller's choice, not always animated. Opening with
        // `animated: false` — which is what launch does — used to slide the
        // window up anyway, so the app appeared to move itself on startup.
        parent.setFrame(moved, display: true, animate: animated)
    }
}
