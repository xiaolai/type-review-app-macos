import AppKit

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

    /// Fired when any of these change, so the window can take its new shape
    /// without being reopened.
    static let didChange = Notification.Name("AppPreferencesDidChange")

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
            NotificationCenter.default.post(name: AppPreferences.didChange, object: nil)
        }
    }
}

extension AppPreferences.Preference where Value == Double {
    var value: Double {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return `default` }
            return clamped(UserDefaults.standard.double(forKey: key))
        }
        nonmutating set {
            UserDefaults.standard.set(clamped(newValue), forKey: key)
            NotificationCenter.default.post(name: AppPreferences.didChange, object: nil)
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

    static func contentSize(columns: Int, rows: Int) -> NSSize {
        let width = characterWidth * CGFloat(columns) + 2 * horizontalInset
        // 20 top + header 16 + 32 gap, then the text, then 24 + footer 14 + 20.
        let chrome: CGFloat = 20 + 16 + 32 + 24 + 14 + 20
        return NSSize(
            width: ceil(width), height: ceil(lineHeight * CGFloat(rows) + chrome))
    }
}
