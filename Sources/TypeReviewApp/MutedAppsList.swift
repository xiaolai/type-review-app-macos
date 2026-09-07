import AppKit

/// The applications the keyboard stays silent in, as a small table with the
/// `+`/`−` pair macOS uses for lists of this shape.
///
/// Its own view rather than another two hundred lines of
/// `SettingsWindowController`, which an audit has already had cause to call
/// long once.
///
/// This is for *reviewing* the set, not for building it: adding something here
/// means remembering an application's name and finding it in a file picker,
/// which is the worst moment to ask. The menu bar offers "Mute in ⟨app⟩" while
/// you are still in the app you want silenced, and that is the path most
/// exclusions will arrive by.
@MainActor
final class MutedAppsList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let remove = NSButton()
    /// What an empty list should say, in place of a blank rectangle. Without
    /// it the row read as an unexplained gap above two small buttons rather
    /// than as a list with nothing in it yet.
    private let empty = NSTextField(labelWithString: "Nothing muted.")
    /// What each row is, in the order shown. Built-in entries come first and
    /// cannot be removed.
    private enum Entry {
        case protected(String)
        case user(String)

        var bundleID: String {
            switch self {
            case .protected(let id), .user(let id): return id
            }
        }
    }
    private var entries: [Entry] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Re-reads the preference. Called when the list changes from anywhere —
    /// the menu bar writes to it too.
    func reload() {
        // Only the built-in entries that are actually installed. Listing
        // password managers the user does not have would be noise; listing
        // none of them would be worse, because an invisible list of protected
        // applications is assurance nobody can check. Showing the ones that
        // are here lets someone see at a glance whether their own manager is
        // covered — and add it themselves when it is not.
        var installed = AppPreferences.protectedApps.filter {
            !AppPreferences.hiddenProtectedApps.contains($0)
                && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
        // Anything that declares itself a password manager, whether or not it
        // is on the list. Shown for the same reason the list is: coverage the
        // user cannot see is coverage they cannot check.
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !installed.contains(id),
                GlobalKeySound.declaresCredentialProvider(id)
            else { continue }
            installed.append(id)
        }
        entries =
            installed.map(Entry.protected)
            + AppPreferences.mutedApps.value.map(Entry.user)
        table.reloadData()
        empty.isHidden = !entries.isEmpty
        updateRemoveButton()
    }

    /// Removable only for the user's own entries.
    private func updateRemoveButton() {
        let selected = table.selectedRowIndexes
        remove.isEnabled = !selected.isEmpty && selected.allSatisfy { row in
            guard row < entries.count else { return false }
            if case .user = entries[row] { return true }
            return false
        }
    }

    private func build() {
        table.headerView = nil
        table.rowSizeStyle = .small
        table.style = .inset
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        let column = NSTableColumn(identifier: .init("app"))
        column.width = 240
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // A surface, so the area reads as a list. An unbordered scroll view
        // over an empty table is indistinguishable from nothing at all.
        let well = NSView()
        well.wantsLayer = true
        well.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        well.layer?.cornerRadius = 6
        well.layer?.borderWidth = 1
        well.layer?.borderColor = NSColor.separatorColor.cgColor
        well.translatesAutoresizingMaskIntoConstraints = false

        empty.font = .systemFont(ofSize: 11)
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton()
        add.bezelStyle = .smallSquare
        add.isBordered = false
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        add.target = self
        add.action = #selector(addApp)
        remove.bezelStyle = .smallSquare
        remove.isBordered = false
        remove.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")
        remove.target = self
        remove.action = #selector(removeSelected)
        remove.isEnabled = false

        let buttons = NSStackView(views: [add, remove])
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(well)
        well.addSubview(scroll)
        well.addSubview(empty)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            well.topAnchor.constraint(equalTo: topAnchor),
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Tall enough for four rows. Three showed the two Apple entries
            // and pushed the user's actual password manager out of sight,
            // which is the one row they opened this to look for.
            well.heightAnchor.constraint(equalToConstant: 112),
            scroll.topAnchor.constraint(equalTo: well.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -1),
            empty.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            buttons.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 4),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 260),
        ])
    }

    // MARK: - Editing

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Mute"
        panel.message = "Choose applications the keyboard should stay silent in."
        guard panel.runModal() == .OK else { return }
        // By identifier, not by the path chosen. The path is how the user
        // pointed at the app; the identifier is what still matches it after it
        // has been renamed or moved.
        // TYPE itself is filtered out. This list governs the system-wide
        // monitor, and the practice window is deliberately not subject to it —
        // silencing the typing surface through a sound setting would break the
        // thing the app is for. An entry that could never do anything is worse
        // than no entry.
        let picked = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            .filter { $0 != Bundle.main.bundleIdentifier }
        guard !picked.isEmpty else { return }
        var current = AppPreferences.mutedApps.value
        for id in picked where !current.contains(id) { current.append(id) }
        AppPreferences.mutedApps.value = current
        reload()
    }

    @objc private func removeSelected() {
        let selected = table.selectedRowIndexes.compactMap { row -> String? in
            guard row < entries.count, case .user(let id) = entries[row] else { return nil }
            return id
        }
        guard !selected.isEmpty else { return }
        AppPreferences.mutedApps.value = AppPreferences.mutedApps.value.filter {
            !selected.contains($0)
        }
        reload()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        let id = entry.bundleID
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let label = NSTextField(labelWithString: name(for: id, at: url))
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        var trailing: [NSView] = []
        if case .protected = entry {
            // Said in words rather than shown as a lock: "always" is the part
            // that matters, and it is not obvious from a dimmed row whether
            // something is off or merely fixed.
            let note = NSTextField(labelWithString: "always")
            note.font = .systemFont(ofSize: 10)
            note.textColor = .tertiaryLabelColor
            trailing = [note]
        }
        let icon = NSImageView()
        icon.image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let row = NSStackView(views: [icon, label] + trailing)
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    /// The application's name, or its identifier when the application is not
    /// installed any more — an entry for something uninstalled is still worth
    /// showing, because it is still worth being able to delete.
    private func name(for identifier: String, at url: URL?) -> String {
        guard let url else { return identifier }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }
}
