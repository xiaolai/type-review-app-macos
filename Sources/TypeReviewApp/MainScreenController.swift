import AppKit

/// Which screen the main window is showing, in the order the toolbar's switch
/// and the View menu list them.
enum MainScreen: String, CaseIterable {
    case practice, play
}

/// Practice and Play, as the two screens of the main window.
///
/// Screens of one window rather than two windows, and rather than macOS
/// window tabs. Statistics has a window of its own because it is worth seeing
/// beside the practice screen; these two are the reverse — the same keyboard
/// drawer, the same window shape, one keyboard between them, and never wanted
/// side by side. Window tabs were the other way to put them in one frame, but
/// tabs are for documents: each can be closed, dragged out or multiplied, and
/// none of that means anything for a fixed pair. Calendar's Day / Week /
/// Month is the pattern — a switch in the middle of the toolbar.
///
/// Both screens stay alive while the other shows. The practice passage keeps
/// its place, and a game pauses rather than ending.
@MainActor
final class MainScreenController: NSViewController {
    let practice: PracticeViewController
    let play: PlayViewController
    private(set) var current: MainScreen?

    init(practice: PracticeViewController, play: PlayViewController) {
        self.practice = practice
        self.play = play
        super.init(nibName: nil, bundle: nil)
        addChild(practice)
        addChild(play)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = GroundedView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        view.wantsLayer = true
    }

    func show(_ screen: MainScreen) {
        guard screen != current else { return }
        current = screen
        let incoming: NSViewController
        let outgoing: NSViewController
        let focus: NSView
        switch screen {
        case .practice: (incoming, outgoing, focus) = (practice, play, practice.focusView)
        case .play: (incoming, outgoing, focus) = (play, practice, play.focusView)
        }
        // Only a screen that was ever shown has anything to take away. Asking
        // one that was not for its view loads it — and loading Play before
        // Practice started its first game before Practice had read the
        // profile, so Letters planned for a typist with no history.
        if outgoing.isViewLoaded { outgoing.view.removeFromSuperview() }
        incoming.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(incoming.view)
        NSLayoutConstraint.activate([
            incoming.view.topAnchor.constraint(equalTo: view.topAnchor),
            incoming.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            incoming.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            incoming.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        view.window?.makeFirstResponder(focus)
    }
}
