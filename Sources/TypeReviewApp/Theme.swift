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
}
