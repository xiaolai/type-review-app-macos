import AppKit

/// A root view that paints its whole window in the passage's ground.
///
/// Without it the practice window was two colours in Dark Mode. The passage
/// is drawn on `textBackgroundColor`, which macOS never tints; the window
/// around it — title bar, margins, status strip — was left at its default
/// background, which macOS tints with the wallpaper. Measured on a macOS 27
/// Mac: #272a2f around #282828, a faint rectangle wherever the text view
/// ended. In Light Mode the two happen to be the same white, which is why the
/// title-bar note in `AppDelegate` could say the toolbar sits "on the same
/// white as the text" and be true only half the time.
///
/// The colour is handed over resolved, not dynamic. Given
/// `textBackgroundColor` itself, the window still draws the tinted material,
/// exactly as if nothing had been set; given that colour resolved for the
/// current appearance, it paints it. So it is resolved again whenever the
/// appearance changes.
final class GroundedView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ground()
    }

    private func ground() {
        guard let window else { return }
        var resolved = Theme.background
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: Theme.background.cgColor) ?? Theme.background
        }
        window.backgroundColor = resolved
    }
}
