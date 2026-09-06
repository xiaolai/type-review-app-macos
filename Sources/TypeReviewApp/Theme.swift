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

    /// Lighter still for the title bar.
    ///
    /// The toolbar sits on the same white as the passage and has nothing
    /// around it to hold it down — no separator, no material edge — so it
    /// carries weight the other surfaces do not. `.thin` there and `.light`
    /// elsewhere is not an inconsistency: the status bar's mark sits beside
    /// 13-point digits and would disappear against them, and the menu-bar
    /// item has the system's own icons for neighbours.
    static let toolbarSymbolWeight: NSFont.Weight = .thin

    /// An SF Symbol at the app's weight.
    ///
    /// `pointSize` is explicit because `NSImage.SymbolConfiguration` has no
    /// weight-only form: asking for a weight means stating a size too.
    @MainActor static func symbol(
        _ name: String, size: CGFloat, weight: NSFont.Weight = symbolWeight,
        scale: NSImage.SymbolScale = .medium, description: String? = nil
    ) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size, weight: weight, scale: scale))
    }

    /// A title-bar symbol, at the toolbar's own weight.
    @MainActor static func toolbarSymbol(_ name: String) -> NSImage? {
        symbol(name, size: SymbolSize.toolbar, weight: toolbarSymbolWeight)
    }

    /// The app's mark in the title bar, with its colour baked in.
    ///
    /// `.medium` rather than the toolbar's `.thin`: this is the app saying
    /// which app it is, and it stands where a word used to. A hairline mark
    /// reads as one more control instead of as a name.
    ///
    /// `paletteColors` rather than the view's `contentTintColor` — see the
    /// note in `TitleMark.MarkView` for why the obvious way does not hold.
    @MainActor static func titleMark(tintedWith colour: NSColor) -> NSImage? {
        NSImage(systemSymbolName: "keyboard.badge.eye", accessibilityDescription: "TYPE")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: SymbolSize.title, weight: .medium
                ).applying(NSImage.SymbolConfiguration(paletteColors: [colour])))
    }

    /// A hue resolved for one appearance.
    ///
    /// Hue is the only free part. Saturation and brightness are fixed per
    /// appearance so every draw is one the mark can actually be read at — a
    /// random RGB triple gives pale yellow on white, and near-black on dark,
    /// about as often as it gives anything usable. The same hue at the same
    /// brightness cannot work on both grounds, and this mark sits on
    /// `textBackgroundColor`, which is white in one and near-black in the
    /// other.
    ///
    /// Resolved rather than dynamic, because the colour is baked into the
    /// image: a dynamic `NSColor` handed to `paletteColors` has no appearance
    /// to resolve against at the moment the symbol is rendered.
    static func tint(hue: CGFloat, for appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(
            hue: hue,
            saturation: dark ? 0.62 : 0.78,
            brightness: dark ? 0.98 : 0.72,
            alpha: 1)
    }

    /// Sizes, named so the call sites read as intent rather than as numbers.
    enum SymbolSize {
        /// The app's mark, standing where the window title used to.
        static let title: CGFloat = 17
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
