import AppKit
import TypeReviewKit

/// Preferences that belong to this app rather than to the profile.
///
/// Deliberately not part of `ProfileSettings`. That schema — its fields, its
/// bounds and its defaults — is shared with the website and pinned by golden
/// vector, so a field added here would either break those vectors or have to
/// be invented on both sides for something only a Mac window has. Window shape
/// and animation speed are properties of *this* app; they live in
/// `UserDefaults` and never touch the profile file.
enum AppPreferences {
    /// Characters per line of passage text — the window's width, expressed in
    /// the only unit that matters for reading.
    static let columns = Preference(key: "PassageColumns", default: 60, range: 30...140)
    /// Lines of passage text visible — the window's height.
    static let rows = Preference(key: "PassageRows", default: 10, range: 4...40)
    /// How long the keyboard drawer takes to open or close. Zero is a valid
    /// answer, and for anyone who finds animation costly it is the right one.
    static let drawerSeconds = Preference(key: "DrawerSeconds", default: 0.26, range: 0...1.5)
    /// The drawer's width as a percentage of the window's. The keyboard fills
    /// it, so this is the keyboard's size.
    static let drawerWidth = Preference(key: "DrawerWidthPercent", default: 95, range: 50...100)
    /// The air between the window's bottom edge and the drawer's top, in
    /// points. Zero is allowed: flush is a look, even if it is not this one.
    static let drawerGap = Preference(key: "DrawerGap", default: 10, range: 0...60)

    /// The shape of the caret on the typing surface.
    ///
    /// Three, because they are the three every terminal and editor offers and
    /// people arrive with a preference already formed. Stored by raw value, so
    /// the names have to stay stable.
    enum CaretStyle: String, CaseIterable {
        case vertical, block, horizontal

        var label: String {
            switch self {
            case .vertical: return "Bar"
            case .block: return "Block"
            case .horizontal: return "Underline"
            }
        }
    }

    enum caretStyle {
        static let key = "CaretStyle"
        static var value: CaretStyle {
            get { CaretStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .vertical }
            set {
                UserDefaults.standard.set(newValue.rawValue, forKey: key)
                AppPreferences.announce(key)
            }
        }
    }

    /// Whether spaces, tabs and line ends are marked on the typing surface.
    ///
    /// The same setting the website calls `showWhitespace`, and the same three
    /// marks, so someone moving between them sees the same page.
    static let showWhitespace = Flag(key: "ShowWhitespace")

    /// How loud the keystroke sounds are. Zero is off in practice, and the
    /// pack named `off` is off by construction; both are honoured.
    static let soundVolume = Preference(key: "SoundVolume", default: 0.5, range: 0...1)

    /// Which keyboard sound pack is active, by `KeySoundPack.name`.
    ///
    /// Its own accessor rather than a `Preference`, which is built around a
    /// numeric range: the meaningful validation here is membership of the
    /// pack list, and an unknown name — a stale one from an older build, or
    /// something typed into `defaults write` — resolves to `off` rather than
    /// to a crash or to silence that cannot be explained.
    ///
    /// Kept in `UserDefaults` and deliberately out of `ProfileSettings`, for
    /// the same reason window shape is: the website stores sound in
    /// `localStorage` too, so putting it in the profile would break the
    /// byte-identical exchange the golden vectors pin.
    enum soundPack {
        static let key = "SoundPack"

        static var value: KeySoundPack {
            get {
                let name = UserDefaults.standard.string(forKey: key) ?? KeySoundPack.off.name
                return KeySoundPack.named(name) ?? .off
            }
            set {
                // Remembered here rather than only in `toggleSound`, which is
                // what made the toggle restore a pack from two choices ago:
                // picking one from Settings or the menu never updated this, so
                // switching off and back on resurrected whatever the *toggle*
                // had last seen.
                if newValue != .off {
                    UserDefaults.standard.set(newValue.name, forKey: lastAudibleKey)
                }
                UserDefaults.standard.set(newValue.name, forKey: key)
                AppPreferences.announce(key)
            }
        }
    }

    /// Whether keystroke sounds are heard everywhere or only while typing
    /// here.
    ///
    /// Off by default, and deliberately so twice over. Hearing every key you
    /// press all day is a taste, not an improvement; and switching it on asks
    /// macOS for permission to watch the keyboard, which is not something an
    /// app should acquire because it was installed.
    ///
    /// Orthogonal to the pack: `off` still means silence everywhere, so the
    /// global shortcut mutes the whole machine without this having to know.
    static let globalSound = Flag(key: "GlobalSound")

    /// Whether shift, control, option, command, fn and caps lock click too.
    ///
    /// Off, and the default is the interesting part. A real keyboard does
    /// click when you press shift, so the faithful answer would be yes — but
    /// the two places this app makes sound are not doing the same job. In the
    /// practice window sound is *feedback about typing*, and a capital letter
    /// is one keystroke of intent producing one character; clicking twice for
    /// it puts noise in the channel that is supposed to be carrying the
    /// signal. System-wide, sound is texture, and there every physical press
    /// belongs.
    ///
    /// One rule beats two, and when they disagree the core feature wins. It
    /// also means that by default the app watches strictly fewer keyboard
    /// events: with this off, `flagsChanged` is not monitored at all.
    static let modifierSound = Flag(key: "ModifierSound")

    /// Whether keystrokes make any sound at all.
    static var soundIsOn: Bool { soundPack.value != .off }

    /// Turns sound off, or back on to whatever pack was last audible.
    ///
    /// Off is a pack, not a separate mute flag — that is how the website
    /// models it, and a second piece of state would let the two disagree
    /// about whether sound is on. The cost is that switching off would
    /// otherwise forget which pack you were using, so the last audible one is
    /// remembered here and restored. A first-ever toggle has nothing to
    /// restore and picks `mechvibe`: the pack that most sounds like a
    /// keyboard, which is the point of turning it on.
    static func toggleSound() {
        let current = soundPack.value
        let remembered = UserDefaults.standard.string(forKey: lastAudibleKey)
            .flatMap(KeySoundPack.named)
        soundPack.value = nextSoundPack(current: current, remembered: remembered)
    }

    private static let lastAudibleKey = "LastAudibleSoundPack"

    /// The system-wide combination that toggles sound.
    ///
    /// Stored as its two parts rather than as an encoded blob, so it stays
    /// legible in `defaults read` and a wrong value written by hand degrades
    /// to "no shortcut" instead of to a decoding crash. `nil` means the user
    /// cleared it and no global hot key is registered at all.
    enum soundShortcut {
        static let keyCodeKey = "SoundShortcutKeyCode"
        static let modifiersKey = "SoundShortcutModifiers"
        /// Distinguishes "never set, use the default" from "deliberately
        /// cleared", which look identical if only the two keys above exist.
        static let setKey = "SoundShortcutSet"

        static var value: KeyboardShortcut? {
            get {
                let defaults = UserDefaults.standard
                guard defaults.object(forKey: setKey) != nil else {
                    return .defaultSoundToggle
                }
                guard defaults.bool(forKey: setKey) else { return nil }
                // Present, numeric and in range — all three checked. Truncation
                // turned 65536 into 0, and a missing or non-numeric value into
                // 0 as well, so a corrupt preference could claim ⌘A globally.
                guard let rawCode = defaults.object(forKey: keyCodeKey) as? NSNumber,
                    let keyCode = UInt16(exactly: rawCode.int64Value),
                    let rawModifiers = defaults.object(forKey: modifiersKey) as? NSNumber,
                    let modifierBits = Int(exactly: rawModifiers.int64Value),
                    modifierBits & ~ShortcutModifiers.all.rawValue == 0
                else { return nil }
                let candidate = KeyboardShortcut(
                    keyCode: keyCode, modifiers: ShortcutModifiers(rawValue: modifierBits))
                // A combination that is not safe to claim globally is treated
                // as absent rather than registered — the same rule the
                // recorder enforces, applied again on the way out, because
                // `defaults write` does not go through the recorder.
                return candidate.isValid ? candidate : nil
            }
            set {
                let defaults = UserDefaults.standard
                defaults.set(newValue != nil, forKey: setKey)
                if let newValue {
                    defaults.set(Int(newValue.keyCode), forKey: keyCodeKey)
                    defaults.set(newValue.modifiers.rawValue, forKey: modifiersKey)
                }
                AppPreferences.announce(keyCodeKey)
            }
        }
    }

    /// Fired when any of these change, so the window can take its new shape
    /// without being reopened.
    ///
    /// The `userInfo` carries `changedKey`. Without it every observer had to
    /// assume the worst and redo all of its work: changing the volume
    /// re-registered the global hot key and resized the window, which threw
    /// away a size the user had just dragged.
    static let didChange = Notification.Name("AppPreferencesDidChange")
    static let changedKey = "changedKey"

    static func announce(_ key: String) {
        NotificationCenter.default.post(
            name: didChange, object: nil, userInfo: [changedKey: key])
    }

    /// A boolean preference. Two of these existed as hand-written enums that
    /// differed only in their key.
    struct Flag {
        let key: String
        let `default`: Bool

        init(key: String, default: Bool = false) {
            self.key = key
            self.default = `default`
        }

        var value: Bool {
            get {
                guard UserDefaults.standard.object(forKey: key) != nil else { return `default` }
                return UserDefaults.standard.bool(forKey: key)
            }
            nonmutating set {
                guard newValue != value else { return }
                UserDefaults.standard.set(newValue, forKey: key)
                AppPreferences.announce(key)
            }
        }
    }

    struct Preference<Value: Comparable & Sendable> {
        let key: String
        let `default`: Value
        let range: ClosedRange<Value>

        /// Clamped on the way out, not just on the way in: a value typed into
        /// `defaults write` bypasses every control this app owns, and the
        /// window should not be asked to be four characters wide because of it.
        func clamped(_ value: Value) -> Value {
            min(max(value, range.lowerBound), range.upperBound)
        }

        /// NaN compares false against everything, so `min(max(…))` returns it
        /// unchanged — an out-of-range value walking straight past the clamp
        /// and into a control. `defaults write … -string nan` is enough.
        func sanitised(_ value: Value) -> Value where Value == Double {
            value.isFinite ? clamped(value) : `default`
        }
    }
}

extension AppPreferences.Preference where Value == Int {
    var value: Int {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return `default` }
            return clamped(UserDefaults.standard.integer(forKey: key))
        }
        nonmutating set {
            UserDefaults.standard.set(clamped(newValue), forKey: key)
            AppPreferences.announce(key)
        }
    }
}

extension AppPreferences.Preference where Value == Double {
    var value: Double {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return `default` }
            return sanitised(UserDefaults.standard.double(forKey: key))
        }
        nonmutating set {
            UserDefaults.standard.set(clamped(newValue), forKey: key)
            AppPreferences.announce(key)
        }
    }
}

/// The window size that shows exactly the requested amount of text.
///
/// Derived from the font rather than guessed, so "60 characters and 10 lines"
/// stays true when the typing font changes and on a display that renders it
/// differently. The insets repeat the ones `PracticeViewController` lays out
/// with; there is no way to ask a view for them before it exists.
@MainActor
enum PracticeWindowMetrics {
    /// The margin either side of the passage. Declared here and *used* by the
    /// views: this number and the line spacing below were written out again in
    /// `PracticeViewController`'s constraints and in `TypingView`'s paragraph
    /// style, so changing the window's sizing arithmetic without changing both
    /// copies would have made the window a size the text did not fit.
    static let horizontalInset: CGFloat = 32
    static let lineSpacing: CGFloat = 8

    static var characterWidth: CGFloat {
        // Monospace, so any character will do — but measure rather than assume
        // the advance equals half the point size, which it does not.
        ("0" as NSString).size(withAttributes: [.font: Theme.typingFont]).width
    }

    static var lineHeight: CGFloat {
        let font = Theme.typingFont
        return ceil(font.ascender - font.descender + font.leading) + lineSpacing
    }

    /// The height of the bottom status bar — the taller of its text and its
    /// mode symbol, both of which follow `Theme.statFont`.
    static var statusBarHeight: CGFloat {
        let font = Theme.statFont
        return ceil(max(font.ascender - font.descender + font.leading, font.pointSize + 4))
    }

    static func contentSize(columns: Int, rows: Int) -> NSSize {
        let width = characterWidth * CGFloat(columns) + 2 * horizontalInset
        // 20 top, then the text, then a 24 gap, the status bar, and 20 bottom.
        // The header this used to allow 48 points for is gone — the live
        // numbers moved into the status bar — so the passage now starts at the
        // top of the content area and the window is that much shorter for the
        // same number of rows.
        let chrome: CGFloat = 20 + 24 + statusBarHeight + 20
        return NSSize(
            width: ceil(width), height: ceil(lineHeight * CGFloat(rows) + chrome))
    }
}
