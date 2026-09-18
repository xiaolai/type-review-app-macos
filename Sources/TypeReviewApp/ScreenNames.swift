import AppKit
import TypeReviewKit

/// What the two screens and Play's modes are called and how they are reached,
/// written once. The toolbar's switch and tooltips, the View menu and the
/// status bar all read these; written out in each, they would drift.
extension MainScreen {
    var title: String {
        switch self {
        case .practice: return "Practice"
        case .play: return "Play"
        }
    }

    /// The View menu's key equivalent, with `menuModifiers`. ⌥⌘ because every
    /// free ⌘-digit is taken: ⌘2 and ⌘3 open windows and ⌘4 to ⌘8 pick a source.
    var menuKey: String {
        switch self {
        case .practice: return "1"
        case .play: return "2"
        }
    }

    static let menuModifiers: NSEvent.ModifierFlags = [.command, .option]

    /// The shortcut as a tooltip prints it.
    var shortcutLabel: String { "⌥⌘\(menuKey)" }
}

extension PlayMode {
    var label: String {
        switch self {
        case .letters: return "Letters"
        case .words: return "Words"
        case .sentences: return "Sentences"
        }
    }

    /// The status bar's mark for a mode, as `target` and `stopwatch` are for
    /// practice's two.
    var symbol: String {
        switch self {
        case .letters: return "character"
        case .words: return "textformat.abc"
        case .sentences: return "text.alignleft"
        }
    }
}
