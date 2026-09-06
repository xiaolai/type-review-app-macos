import AppKit

/// The window's contents: practice above, the keyboard in a drawer below.
///
/// A drawer rather than a fixed panel because the keyboard is a teaching aid,
/// not part of the exercise — a beginner wants it open, someone drilling
/// speed wants the screen back, and most people want something in between.
/// Making that a drag rather than a preference means the answer is at hand
/// while typing.
///
/// Built on `NSSplitViewController`, which is where every other Mac app puts
/// this. It is what supplies the parts that would otherwise all need writing:
/// a divider the user can grab, an animated collapse, a remembered position
/// across launches, and full window width by construction. `NSDrawer` — the
/// class that owns the name — has been deprecated since 10.13 and slides
/// *outside* the window, which is not what is wanted here.
final class KeyboardDrawerController: NSSplitViewController {
    let practice = PracticeViewController()
    private let keyboardView = KeyboardView()
    private var keyboardItem: NSSplitViewItem!
    private var collapseObservation: NSKeyValueObservation?

    /// Called whenever the drawer opens or closes — including by a drag, which
    /// is why this is an observation rather than something the toggle sets.
    /// A menu checkmark that only tracks the menu is a checkmark that lies.
    var onDrawerChanged: ((Bool) -> Void)?

    /// The smallest the keyboard stays legible at. The largest comes from the
    /// keyboard itself — cap size is capped, so a wider window makes a wider
    /// case, not a taller one.
    private static let minThickness: CGFloat = 80

    override func loadView() {
        // NSSplitViewController builds its own view; this just names it for
        // the frame autosave, which is what remembers the drawer's height.
        super.loadView()
        // Horizontal divider, i.e. panes stacked top and bottom. The default
        // is the other one — `isVertical` describes the divider, not the
        // arrangement, and left at its default the keyboard appears beside the
        // passage instead of under it.
        splitView.isVertical = false
        splitView.dividerStyle = .thin
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        practice.keyboard = keyboardView

        let practiceItem = NSSplitViewItem(viewController: practice)
        practiceItem.minimumThickness = 260
        practiceItem.canCollapse = false
        addSplitViewItem(practiceItem)

        let keyboardController = NSViewController()
        keyboardController.view = keyboardView
        keyboardItem = NSSplitViewItem(viewController: keyboardController)
        keyboardItem.minimumThickness = Self.minThickness
        keyboardItem.maximumThickness = keyboardView.naturalHeight
        keyboardItem.canCollapse = true
        // holdingPriority stays at its default. Raising it — the intuitive
        // move for "this pane keeps its size" — pins the item to its *minimum*
        // thickness instead, and the drawer opens 80 points tall no matter
        // what position is set. Measured, not reasoned: with the default, the
        // drawer opens at 211 and the passage above absorbs window resizing,
        // which is the wanted behaviour anyway.
        // Dragging the divider to the floor closes the drawer rather than
        // leaving a sliver, and it comes back the size it was.
        keyboardItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        keyboardItem.isCollapsed = !UserDefaults.standard.bool(forKey: Self.openKey)
        addSplitViewItem(keyboardItem)

        collapseObservation = keyboardItem.observe(\.isCollapsed, options: [.new]) {
            [weak self] item, _ in
            guard let self, !self.isAdjusting else { return }
            UserDefaults.standard.set(!item.isCollapsed, forKey: Self.openKey)
            self.onDrawerChanged?(!item.isCollapsed)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(dividerMoved),
            name: NSSplitView.didResizeSubviewsNotification, object: splitView)
    }

    /// The drawer's height is kept here rather than in `splitView.autosaveName`.
    ///
    /// AppKit's autosave stores raw subview frames and restores them before
    /// the first layout, which is too early to know the window's size and too
    /// opaque to fall back from: on a first launch there is nothing to restore
    /// and the drawer opens at whatever the split view has left over, which is
    /// not the keyboard's height. One number under our own key answers both.
    override func viewDidLayout() {
        super.viewDidLayout()
        // Placed on the first *layout*, not the first appearance: in
        // viewDidAppear the split view has not been sized yet, and a position
        // computed against a zero height lands on the minimum thickness.
        guard !didPlaceDivider, splitView.bounds.height > 1, let keyboardItem else { return }
        didPlaceDivider = true

        // Open it, size it, and shut it again if it was meant to be shut.
        //
        // The detour is the point. A collapsed item has no thickness, so when
        // it is later opened AppKit restores the last one it saw — and on a
        // launch that started collapsed it has never seen one, so the drawer
        // springs open at its 80-point minimum instead of the height the user
        // left it at. Giving AppKit the real thickness once, before collapsing,
        // means opening needs no correction afterwards. No animation runs here:
        // this all happens inside the first layout pass.
        isAdjusting = true
        let shouldOpen = !keyboardItem.isCollapsed
        keyboardItem.isCollapsed = false
        applyStoredHeight()
        keyboardItem.isCollapsed = !shouldOpen
        isAdjusting = false
        lastSplitHeight = splitView.bounds.height
        UserDefaults.standard.set(shouldOpen, forKey: Self.openKey)
        onDrawerChanged?(shouldOpen)
    }

    private func applyStoredHeight() {
        guard splitView.bounds.height > 1 else { return }
        isAdjusting = true
        splitView.setPosition(
            splitView.bounds.height - drawerHeight - splitView.dividerThickness, ofDividerAt: 0)
        isAdjusting = false
    }

    /// A hairline divider is a hairline target. AppKit's proposed rect is the
    /// one drawn — a single point — and a drawer whose handle has to be hunted
    /// for is a drawer nobody drags. Six points is the usual answer and is
    /// what Apple's own bottom panes feel like.
    override func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int
    ) -> NSRect {
        var rect = proposedEffectiveRect
        rect.origin.y -= 3
        rect.size.height += 6
        return rect
    }

    @objc private func dividerMoved() {
        guard didPlaceDivider, !isAdjusting, let keyboardItem else { return }

        // A window resize and a divider drag arrive as the same notification.
        // Told apart by whether the split view itself changed size, because
        // they want opposite things: on a window resize the keyboard keeps its
        // height and the passage above absorbs the difference, and only a drag
        // is the user choosing a new height.
        //
        // Without this the panes divide the change proportionally, so a
        // drawer set to 150 in a 500-point window silently becomes 192 when
        // the window settles at 644 — and that number is then saved as though
        // the user had picked it.
        let splitHeight = splitView.bounds.height
        if abs(splitHeight - lastSplitHeight) > 0.5 {
            lastSplitHeight = splitHeight
            pendingSave?.cancel()
            if !keyboardItem.isCollapsed { applyStoredHeight() }
            return
        }
        // Recorded when the gesture settles, not while it is in flight.
        //
        // A drag emits a resize per mouse event, and a drag that ends by
        // collapsing the drawer walks the whole way down first. Saving every
        // step means saving the last step before the collapse — an arbitrary
        // way-station, which the drawer would then reopen at. Waiting a beat
        // and checking the drawer is still open records the height the user
        // stopped at, and records nothing at all when they closed it.
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            guard let self, let item = self.keyboardItem, !item.isCollapsed else { return }
            let height = item.viewController.view.bounds.height
            guard height > 1 else { return }
            self.drawerHeight = height
            UserDefaults.standard.set(height, forKey: Self.heightKey)
        }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: save)
    }

    private static let openKey = "KeyboardDrawerOpen"
    private static let heightKey = "KeyboardDrawerHeight"
    private var didPlaceDivider = false
    /// The height the user chose, held here rather than re-read from defaults
    /// on each use. A collapse animation walks the pane's height down through
    /// every intermediate value, and each step reports itself as a resize — so
    /// a stored height read back mid-animation is not the user's height, it is
    /// a frame of the animation.
    private lazy var drawerHeight: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: Self.heightKey)
        return stored > 0 ? min(stored, keyboardView.naturalHeight) : keyboardView.naturalHeight
    }()
    /// True while this class is moving the divider itself, so the resize
    /// notifications that causes are not mistaken for the user dragging.
    private var isAdjusting = false
    private var pendingSave: DispatchWorkItem?
    /// The split view's own height last time it was looked at. What separates
    /// "the window resized" from "the divider was dragged" — the two events
    /// arrive as the same notification and want opposite responses.
    private var lastSplitHeight: CGFloat = 0

    var isDrawerOpen: Bool { !(keyboardItem?.isCollapsed ?? true) }

    /// Animated, because a drawer that teleports does not read as a drawer —
    /// the movement is what says where it went and how to get it back.
    func setDrawerOpen(_ open: Bool, animated: Bool = true) {
        guard let keyboardItem, keyboardItem.isCollapsed == open else { return }
        if animated {
            keyboardItem.animator().isCollapsed = !open
        } else {
            keyboardItem.isCollapsed = !open
        }
    }
}
