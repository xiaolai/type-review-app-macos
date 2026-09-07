import AppKit

/// The About pane's contents.
///
/// A pane in Settings rather than only the standard About panel, and the
/// reason is the Dock setting. `.accessory` takes the menu bar with it, so an
/// app running without a Dock icon has no App menu — and "About TYPE" lives
/// nowhere else. The status item offers Settings, so a pane here is reachable
/// in every configuration the app can be in. The standard panel stays for the
/// configurations that still have a menu bar.
///
/// Its own file because `SettingsWindowController` is long enough that an
/// audit has said so, and because this is presentation with no state: it reads
/// the bundle and builds views, and nothing here has to be refreshed.
@MainActor
enum AboutPane {
    /// Wide enough for a sentence and narrower than the pane, so the text has
    /// a margin of its own rather than running to the window's edge.
    private static let width: CGFloat = 400

    static func makeContent() -> NSView {
        let stack = NSStackView(views: [])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        // The bundle's own icon rather than a symbol: this is the one place
        // that should show the thing the user clicked in the Dock.
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(10, after: icon)

        let name = NSTextField(labelWithString: "TYPE")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        stack.addArrangedSubview(name)
        stack.setCustomSpacing(2, after: name)

        let version = NSTextField(labelWithString: versionLine)
        version.font = .systemFont(ofSize: 11)
        version.textColor = Theme.secondaryText
        stack.addArrangedSubview(version)
        stack.setCustomSpacing(14, after: version)

        let tagline = wrapping(
            "Typing practice that watches which keys you actually miss, and "
                + "builds the next passage out of them.",
            size: 12, colour: .labelColor, alignment: .center)
        stack.addArrangedSubview(tagline)
        stack.setCustomSpacing(12, after: tagline)

        let link = NSButton(
            title: "type.review", target: OpenLink.shared, action: #selector(OpenLink.open(_:)))
        link.bezelStyle = .rounded
        link.controlSize = .small
        link.toolTip = "https://type.review"
        stack.addArrangedSubview(link)
        stack.setCustomSpacing(18, after: link)

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(rule)
        stack.setCustomSpacing(16, after: rule)

        stack.addArrangedSubview(acknowledgements())
        return stack
    }

    /// `0.1.0 (1)`, read from the bundle rather than written down twice.
    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (version?, build?): return "Version \(version) (\(build))"
        case let (version?, nil): return "Version \(version)"
        // Running from a build with no Info.plist read — say so rather than
        // printing a confident wrong number.
        default: return "Version unknown"
        }
    }

    /// Who and what this is built on.
    ///
    /// The same facts as `CREDITS.md`, said the way someone using the app
    /// would want them: what the sound is, where it came from, and what the
    /// passages are. The repository file keeps the long form — the conversion
    /// command, the recording chain — which is for whoever maintains this, not
    /// for whoever types in it.
    private static func acknowledgements() -> NSView {
        let stack = NSStackView(views: [])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true

        let heading = NSTextField(labelWithString: "Acknowledgements")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(10, after: heading)

        for (title, body) in entries {
            let name = NSTextField(labelWithString: title)
            name.font = .systemFont(ofSize: 11, weight: .medium)
            stack.addArrangedSubview(name)
            stack.setCustomSpacing(1, after: name)
            let text = wrapping(body, size: 11, colour: Theme.secondaryText, alignment: .left)
            stack.addArrangedSubview(text)
            stack.setCustomSpacing(12, after: text)
        }
        return stack
    }

    private static let entries: [(String, String)] = [
        (
            "The typewriter sound",
            "“Typewriter #2” recorded by Joseph SARDIN for BigSoundBank, released "
                + "under CC0. A Hermes Precisa 305, sliced at its own keystrokes so no "
                + "two presses sound quite alike."
        ),
        (
            "The passages",
            "Mostly public domain — Twain, Thoreau, Emerson, Marcus Aurelius and "
                + "others. A few short quotations from living authors are used as fair "
                + "dealing, and each is credited on screen while it is being typed."
        ),
        (
            "The engine",
            "Ported from the TypeScript that runs type.review, and checked against "
                + "it by golden vectors — so a score earned here means the same thing "
                + "as one earned in the browser."
        ),
    ]

    private static func wrapping(
        _ string: String, size: CGFloat, colour: NSColor, alignment: NSTextAlignment
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = .systemFont(ofSize: size)
        field.textColor = colour
        field.alignment = alignment
        field.isSelectable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        // An explicit width rather than `preferredMaxLayoutWidth`. The two
        // disagree about height inside a grid — see the note in `addRow` —
        // and a constraint is the half that both the stack and the grid read
        // the same way.
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    /// A target for the link button.
    ///
    /// `AboutPane` is an enum, so there is no instance for a button to hold a
    /// weak reference to; this is the smallest object that can be one.
    @MainActor
    private final class OpenLink: NSObject {
        static let shared = OpenLink()
        @objc func open(_ sender: Any?) {
            guard let url = URL(string: "https://type.review") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
