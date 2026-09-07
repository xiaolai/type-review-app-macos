
/// The modifier keys a shortcut can carry.
///
/// This app's own set rather than `NSEvent.ModifierFlags`, so the model stays
/// in the Kit where it can be tested — the app converts at the boundary, in
/// both directions, because Cocoa and Carbon disagree about the bit values and
/// the global hot-key API speaks Carbon.
public struct ShortcutModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)

    /// Every bit this type defines. A stored value with anything else set did
    /// not come from this app and is not something to register.
    public static let all: ShortcutModifiers = [.control, .option, .shift, .command]

    /// The ones that make a combination unlikely to be typed by accident.
    /// Shift is excluded deliberately — see `KeyboardShortcut.isValid`.
    public static let qualifying: ShortcutModifiers = [.control, .option, .command]

    /// In the order macOS prints them, which is not the order they are
    /// declared in and is not alphabetical: ⌃⌥⇧⌘, always.
    public var glyphs: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// A key plus its modifiers, as stored and as displayed.
public struct KeyboardShortcut: Sendable, Equatable, Codable {
    public let keyCode: UInt16
    public let modifiers: ShortcutModifiers

    public init(keyCode: UInt16, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Whether this is safe to claim system-wide.
    ///
    /// At least one of control, option or command is required, and shift alone
    /// is explicitly not enough. A global hot key is taken from every other
    /// app on the machine for as long as this one runs — registering `S` or
    /// `⇧S` would mean nobody could type a capital S anywhere until TYPE
    /// quit. The recorder refuses such a combination rather than accepting it
    /// and leaving the user to work out why their keyboard broke.
    public var isValid: Bool { !modifiers.intersection(.qualifying).isEmpty }

    /// The shortcut as macOS would print it, given the character the key
    /// produces. The character is passed in because only the app can ask the
    /// system what a physical key types under the current layout — which is
    /// also what keeps this correct under Dvorak.
    public func display(keyName: String) -> String {
        modifiers.glyphs + keyName
    }

    /// ⌃⌥⌘S. Deliberately awkward: three modifiers together is close to
    /// unused, and S is the letter this does something to. `⌘S` or `⌥S`
    /// would be theft from every other app.
    public static let defaultSoundToggle = KeyboardShortcut(
        keyCode: 1, modifiers: [.control, .option, .command])  // kVK_ANSI_S
}
