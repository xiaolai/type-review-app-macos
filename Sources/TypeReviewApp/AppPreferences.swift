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
    static let drawerGap = Preference(key: "DrawerGap", default: 2, range: 0...60)

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
            get { CaretStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .block }
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
                let name = UserDefaults.standard.string(forKey: key) ?? KeySoundPack.mechvibe.name
                // Two different fallbacks, and the difference is the point.
                // A *missing* key means a fresh install, and gets the shipped
                // default above. A key that is present but names a pack this
                // build does not have — a stale name from an older version, or
                // something typed into `defaults write` — is a broken setting
                // rather than an absent one, and goes silent instead of
                // quietly picking a sound the user never chose.
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

    /// Whether a word is read aloud once it has been typed correctly.
    ///
    /// For children learning to read and type: the reward for finishing a word
    /// is hearing it. Off by default, because hearing every word you type is a
    /// taste rather than an improvement — not because it is unreliable at
    /// speed. Words are no longer cut off when the next one arrives; see the
    /// note on the interrupt policy in `SpeechPlayer`.
    ///
    /// Its own switch rather than a mode of the key sound: a child may want the
    /// words without the clicks. It shares the volume slider, so one control
    /// governs everything audible.
    ///
    /// In `UserDefaults`, not in `ProfileSettings`, for the same reason sound
    /// is: that schema is shared with the website and pinned by golden vector.
    static let speakWords = Flag(key: "SpeakWords")

    /// Which voice reads the words, by `AVSpeechSynthesisVoice.identifier`.
    ///
    /// Empty means automatic — follow the language of the passage, which is
    /// what §6 of the speech plan describes and remains the default. An
    /// explicit choice outranks it, because a person who picks a voice has
    /// said something more specific than a language detector can infer: which
    /// voice they want to listen to.
    ///
    /// Its own accessor rather than a `Flag`, and the identifier rather than
    /// the name: names are not unique across languages — this machine has four
    /// voices called Eddy — and a name is localised, so it would stop matching
    /// when the system language changed.
    ///
    /// An identifier this machine does not have resolves to nil at the point of
    /// use and falls back to automatic. Same discipline as `soundPack`: a
    /// setting that has gone stale should behave like a setting that was never
    /// made, not like silence nobody can explain.
    enum speechVoice {
        static let key = "SpeechVoice"

        static var value: String {
            get { UserDefaults.standard.string(forKey: key) ?? "" }
            set {
                UserDefaults.standard.set(newValue, forKey: key)
                AppPreferences.announce(key)
            }
        }
    }

    /// Whether the keyboard drawer is out.
    ///
    /// The last preference that was still being read and written as a raw
    /// `UserDefaults` key in three places, with its default spelled out at one
    /// of them. As a `Flag` the default lives once and the write announces
    /// itself like every other preference does.
    ///
    /// On by default, and the one setting deliberately *not* taken from real
    /// use when the rest were. Someone who has been using this for months has
    /// long since stopped needing the keyboard on screen; someone opening it
    /// for the first time has no way to find out it exists. A default is for
    /// the second person.
    static let showKeyboard = Flag(key: "ShowKeyboard", default: true)

    /// What the practice grid counts.
    ///
    /// Characters by default. Sessions answers "did I show up", which the
    /// streak line beside the grid already answers in words; characters
    /// answers "how much did I do", which nothing else on the window says. A
    /// day of one long passage and a day of three warm-ups are the same cell
    /// under sessions and visibly different under characters.
    enum StatsMetric: String, CaseIterable {
        /// Practice runs finished that day.
        case sessions = "Sessions"
        /// Characters typed inside TYPE that day.
        case characters = "Characters"
        /// Keys pressed anywhere, when `countKeystrokes` is on.
        case keystrokes = "Keystrokes"

        var label: String {
            switch self {
            case .sessions: return "Sessions"
            case .characters: return "Characters here"
            case .keystrokes: return "All keystrokes"
            }
        }
    }

    enum statsMetric {
        static let key = "StatsMetric"
        static var value: StatsMetric {
            get { StatsMetric(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .characters }
            set {
                UserDefaults.standard.set(newValue.rawValue, forKey: key)
                AppPreferences.announce(key)
            }
        }
    }

    /// Whether launching TYPE puts a window on screen.
    ///
    /// Off, so a double-click does what a double-click does. On, the app goes
    /// straight to the menu bar — which is the right shape for someone whose
    /// reason for running it is the keystroke sound rather than the drills.
    ///
    /// Launching at login ignores this and never opens a window either way.
    /// A login launch is the machine starting up, not a request to be shown
    /// something, and an app that threw a window across whatever you were
    /// about to do every morning would be uninstalled by Thursday.
    ///
    /// `applicationShouldHandleReopen` is what makes this safe: opening TYPE
    /// again from the Finder while it is already running brings the window
    /// back, so the setting cannot leave someone with no way in.
    static let startInMenuBar = Flag(key: "StartInMenuBar")

    /// Whether TYPE has a Dock tile.
    ///
    /// On by default, and stored positively rather than as `hideDockIcon` so
    /// that the checkbox, the preference and the code all say the same thing.
    /// An inverted checkbox is a bug waiting for whoever reads it next.
    ///
    /// Turning it off costs the menu bar as well, and that is macOS rather
    /// than a decision here: `.accessory` means no Dock tile, no ⌘-Tab entry
    /// and no menu bar of its own. The status item is unaffected, which is
    /// why it is safe to offer — there is always a way back to the window.
    /// Key equivalents still reach the main menu, since AppKit dispatches
    /// them through `NSApp.mainMenu` whether or not it is drawn.
    static let showInDock = Flag(key: "ShowInDock", default: true)

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

    /// Whether the app keeps a per-day count of keys pressed in other
    /// applications.
    ///
    /// Off, and it stays off unless somebody switches it on. It is the only
    /// setting here that makes the app write down anything about what happens
    /// outside its own window, so it is the one setting whose default is not a
    /// matter of taste.
    ///
    /// Independent of `globalSound` on purpose. Riding on that switch would
    /// have meant counting only while the keyboard sound was on, and a chart
    /// with holes wherever the sound was off looks exactly like days the user
    /// did not type.
    static let countKeystrokes = Flag(key: "CountKeystrokes")

    /// Whether keys are heard coming back up.
    ///
    /// On, because it is what a keyboard does: a real key makes two sounds,
    /// and every pack here described only the first. The setting exists
    /// anyway, because doubling the click rate of something you hear four
    /// hundred times a minute is a taste, and one nobody had been offered
    /// before. Which packs *have* a release is theirs to decide — `typewriter`
    /// has none, since a typebar returns almost silently.
    static let releaseSound = Flag(key: "ReleaseSound", default: true)

    /// Whether a wrong key says so.
    ///
    /// On, because it is the feedback a practice app is for: knowing you
    /// mistyped without looking up is the whole point of typing by touch, and
    /// somebody who does not want it has the switch. Off would be a feature
    /// nobody finds.
    ///
    /// Independent of the pack, including a pack set to Off. Choosing silence
    /// from the keyboard is not the same as choosing not to be told you typed
    /// the wrong letter, and tying the two together would make the quiet
    /// option also the one that teaches least.
    ///
    /// It has no system-wide half and cannot have one: the monitor sees key
    /// codes from other applications, where there is no expected text to be
    /// wrong against. This belongs to the practice window alone.
    static let mistypeSound = Flag(key: "MistypeSound", default: true)

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

    /// Applications the keyboard stays silent in, by bundle identifier.
    ///
    /// A list of exclusions rather than of inclusions, because the setting
    /// above is called "sound in every app" and that is the model: it plays
    /// everywhere, except here. An inclusion list would ask the user to
    /// enumerate every application they ever type in, which has no end, and
    /// would leave the feature doing nothing until they did.
    ///
    /// Bundle identifiers, not names or paths. An app can be renamed and can
    /// be moved; its identifier is what stays put.
    ///
    /// Empty by default. The exclusion that actually matters — password
    /// fields — is handled by `IsSecureEventInputEnabled` without anyone
    /// having to think of it, so there is nothing to preload here and no
    /// guessed list to go stale.
    /// Applications this app will not watch the keyboard in, ever, whatever
    /// the settings say.
    ///
    /// Password managers, as whole applications rather than as password
    /// fields. `IsSecureEventInputEnabled` covers the fields that ask for
    /// protection, and inside a password manager that is not most of them: a
    /// vault search, a secure note, a card number, the label on a one-time
    /// code are ordinary text fields. The gap sits exactly where the stakes
    /// are highest.
    ///
    /// This is not a mute. While one of these is in front the global monitor
    /// is uninstalled, so the events are not received at all.
    ///
    /// ## Where these came from
    ///
    /// Every identifier here was read from a primary source rather than
    /// recalled: the Mac App Store's lookup API, or the `quit:`/`zap` stanzas
    /// of the app's Homebrew cask, both of which state the bundle identifier
    /// outright. That mattered — the LastPass desktop app is
    /// `com.lastpass.lastpassmacdesktop`, and an earlier version of this list
    /// carried only `com.lastpass.LastPass`, which is a container LastPass
    /// also uses but not the application. A wrong identifier does not fail
    /// loudly; it simply never matches, while looking like coverage.
    ///
    /// `make password-managers` re-checks every entry against those sources
    /// and says what has drifted. It reports rather than rewrites: this list
    /// decides when the machine stops listening, so each line is a human
    /// decision, and a generator that silently produced an empty one would
    /// leave a green build over no protection at all.
    ///
    /// A list still cannot be complete, which is why it is not the only
    /// mechanism: `GlobalKeySound.declaresCredentialProvider` asks the
    /// application itself, and the entries that are installed are shown in
    /// Settings so the answer for *this* Mac is something anyone can check.
    static let protectedApps: [String] = [
        // Apple
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        // The system's own authentication surfaces. `LocalAuthentication`'s
        // agent is the Touch-ID-or-password sheet; it came out of watching the
        // monitor while switching applications — dismissing Keychain Access
        // handed the front to it, and it was not on this list, so the monitor
        // was reinstalled for exactly the dialog a password is typed into.
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.SecurityAgent",
        "com.apple.loginwindow",
        // 1Password
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        // Bitwarden
        "com.bitwarden.desktop",
        // LastPass. Both: the desktop app, and the container the Homebrew
        // cask still names, which older installs use.
        "com.lastpass.lastpassmacdesktop",
        "com.lastpass.LastPass",
        // Dashlane
        "com.dashlane.dashlanephonefinal",
        // Keeper
        "com.keepersecurity.passwordmanager",
        "com.callpod.keepermac.lite",
        "com.callpod.keepermac",
        // NordPass
        "com.nordsec.nordpass",
        // Enpass
        "in.sinew.Enpass-Desktop",
        // The KeePass family. KeePassXC answers to its old `org.keepassx`
        // preferences domain as well as its current identifier.
        "org.keepassxc.keepassxc",
        "org.keepassx.keepassxc",
        "com.hicknhacksoftware.MacPass",
        "net.antelle.keeweb",
        "com.markmcguill.strongbox",
        "com.markmcguill.strongbox.pro",
        "com.keepassium.ios",
        "com.keepassium.ios.pro",
        // Proton
        "me.proton.pass.electron",
        // The rest, all from the App Store's own listing
        "pw.buttercup.desktop",
        "com.SiberSystems.RoboForm",
        "com.sibersystems.RoboFormMac",
        "com.outercorner.Secrets",
        "com.mseven.msecuremac",
        "com.safeincloud.Safe-In-Cloud.OSX",
        "net.zetetic.Strip.mac",
        "com.app77.pwsafemac",
        "com.keepsolid.passwarden",
        "com.2stable.passwords",
        // A one-time-code app is not a password manager, but a secret is still
        // typed into it when one is added by hand.
        "com.NeilSardesai.Step-Two-Mac",
    ]

    /// The protected entries that are not worth showing anyone.
    ///
    /// The system's authentication surfaces are protected for the same reason
    /// as everything else here, but they are not applications a person thinks
    /// about — a row reading "loginwindow" in a list of password managers
    /// answers no question and crowds out the rows that do.
    static let hiddenProtectedApps: Set<String> = [
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.SecurityAgent",
        "com.apple.loginwindow",
    ]

    /// Case-insensitively, because a bundle identifier is compared that way and
    /// a vendor's capitalisation is not something to bet a password on —
    /// RoboForm ships both `com.SiberSystems.RoboForm` and
    /// `com.sibersystems.RoboFormMac`.
    static func isProtected(_ bundleID: String) -> Bool {
        protectedApps.contains { $0.compare(bundleID, options: .caseInsensitive) == .orderedSame }
    }

    enum mutedApps {
        static let key = "MutedApps"

        static var value: [String] {
            get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
            set {
                UserDefaults.standard.set(newValue.sorted(), forKey: key)
                AppPreferences.announce(key)
            }
        }

        static func contains(_ bundleID: String) -> Bool { value.contains(bundleID) }

        static func toggle(_ bundleID: String) {
            var current = value
            if let index = current.firstIndex(of: bundleID) {
                current.remove(at: index)
            } else {
                current.append(bundleID)
            }
            value = current
        }
    }

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

    /// A system-wide key combination, stored as its parts.
    ///
    /// Two numbers and a flag rather than an encoded blob, so it stays legible
    /// in `defaults read` and a value written by hand degrades to "no
    /// shortcut" instead of to a decoding crash. `nil` means the user cleared
    /// it and no global hot key is registered at all.
    ///
    /// A type rather than a second copy of forty lines, once there was a
    /// second shortcut to store. The keys are derived from `name`, which
    /// reproduces `SoundShortcutKeyCode` and its two siblings exactly —
    /// renaming them would have silently discarded a shortcut someone had set.
    struct ShortcutPreference {
        let keyCodeKey: String
        let modifiersKey: String
        /// Distinguishes "never set, use the default" from "deliberately
        /// cleared", which look identical if only the two keys above exist.
        let setKey: String
        /// What an untouched installation gets.
        let fallback: KeyboardShortcut?

        init(name: String, fallback: KeyboardShortcut?) {
            keyCodeKey = "\(name)KeyCode"
            modifiersKey = "\(name)Modifiers"
            setKey = "\(name)Set"
            self.fallback = fallback
        }

        var value: KeyboardShortcut? {
            get {
                let defaults = UserDefaults.standard
                guard defaults.object(forKey: setKey) != nil else { return fallback }
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
            nonmutating set {
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

    /// The combination that toggles keystroke sound, from anywhere.
    static let soundShortcut = ShortcutPreference(
        name: "SoundShortcut", fallback: .defaultSoundToggle)

    /// The combination that brings TYPE's window up, and puts it away again.
    ///
    /// The one way in that does not involve aiming at a small icon. It earns
    /// its keep most when the Dock icon is off — ⌘-Tab cannot reach an
    /// accessory app either, so without this the status item is the only door.
    static let summonShortcut = ShortcutPreference(
        name: "SummonShortcut", fallback: .defaultSummon)

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
