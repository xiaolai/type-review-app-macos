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
///
/// One per window, at its root. A screen inside that root does not need its
/// own, and one there would ground the same window twice on every change.
final class GroundedView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ground()
    }

    /// Internal rather than private so `--selftest` can check it in both
    /// appearances without waiting on one to change.
    func ground() {
        guard let window else { return }
        var resolved: NSColor?
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = Theme.background.usingColorSpace(.sRGB)
        }
        // Never the dynamic colour as a fallback: that is the one value known to
        // draw the tint. A colour that cannot be resolved leaves the window as
        // it was, and the self-test's ground check is what says so.
        guard let resolved else {
            assertionFailure("the passage's ground did not resolve to a concrete colour")
            return
        }
        window.backgroundColor = resolved
    }
}
