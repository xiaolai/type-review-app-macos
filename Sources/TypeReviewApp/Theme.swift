import AppKit

/// Colours for the typing surface.
///
/// Deliberately semantic rather than a palette copied from the website. The
/// web app carries four hand-built themes because a browser gives it no
/// system colours; here the system supplies them, and following the user's
/// appearance is both less code and more correct.
enum Theme {
    static var background: NSColor { .textBackgroundColor }
    /// Not yet typed.
    static var pending: NSColor { .tertiaryLabelColor }
    static var correct: NSColor { .labelColor }
    static var incorrect: NSColor { .systemRed }
    static var caret: NSColor { .controlAccentColor }
    static var secondaryText: NSColor { .secondaryLabelColor }

    // Computed, not stored: NSFont is not Sendable, and a static let would be
    // shared mutable state under strict concurrency. These are cheap.
    @MainActor static var typingFont: NSFont {
        .monospacedSystemFont(ofSize: 22, weight: .regular)
    }
    @MainActor static var statFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    }

    /// The stroke weight for every SF Symbol in the app's chrome.
    ///
    /// `.light`, not the default `.regular`. This app is a sheet of thin
    /// monospaced text on a plain ground, and regular-weight icons sat
    /// heavier than anything they shared a window with — the toolbar read as
    /// the loudest thing on screen, which for a typing app is the wrong thing
    /// to be looking at.
    ///
    /// One constant rather than a weight per call site, so the toolbar, the
    /// settings tabs, the status bar and the menu-bar item cannot drift apart
    /// — which they already had, at `.regular`, `.medium` and unset.
    static let symbolWeight: NSFont.Weight = .light

    /// An SF Symbol at the app's weight.
    ///
    /// `pointSize` is explicit because `NSImage.SymbolConfiguration` has no
    /// weight-only form: asking for a weight means stating a size too.
    @MainActor static func symbol(
        _ name: String, size: CGFloat, scale: NSImage.SymbolScale = .medium,
        description: String? = nil
    ) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size, weight: symbolWeight, scale: scale))
    }

    /// Sizes, named so the call sites read as intent rather than as numbers.
    enum SymbolSize {
        /// Toolbar buttons, in both the practice and library windows.
        static let toolbar: CGFloat = 15
        /// The settings window's tab strip, which shows a label underneath.
        static let settingsTab: CGFloat = 18
        /// Beside the status bar's digits, so it matches their cap height.
        static let statusBar: CGFloat = 13
        /// The menu-bar item — see the note at `installStatusItem`.
        static let menuBar: CGFloat = 13
    }
}
