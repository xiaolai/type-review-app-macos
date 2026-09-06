import AppKit
import TypeReviewKit
import UniformTypeIdentifiers

/// The Library window: the user's own documents as practice text.
///
/// A table of what they have added, plus two ways in — a file, or pasted
/// text. Deliberately a plain `NSTableView` rather than a styled list: this
/// is a file manager for text, and the Mac already has a look for that.
final class LibraryWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate
{
    private let store: LibraryStore
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    /// Held so its enabled state can follow the selection, the way the Remove
    /// button used to.
    private var removeItem: NSToolbarItem?

    init(store: LibraryStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Library"
        window.setFrameAutosaveName("TypeReviewLibrary")
        // Same reasoning as the settings window: without .auxiliary this
        // displaces the practice window in Stage Manager, and .automatic
        // tabbing lets it be absorbed into another window's tab bar.
        window.collectionBehavior = [.auxiliary, .fullScreenNone]
        window.tabbingMode = .disallowed
        super.init(window: window)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        reload()
        showWindow(nil)
        if window?.frame.origin == .zero { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let content = DropView()
        content.onDrop = { [weak self] urls in self?.ingest(urls: urls) }

        // Switched on only when there is something to alternate. An empty
        // inset table paints its blank rows as rounded grey bands, which reads
        // as content still loading rather than as a library with nothing in
        // it.
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.style = .inset
        let titleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleColumn.title = "Title"
        titleColumn.width = 330
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Characters"
        sizeColumn.width = 100
        let addedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("added"))
        addedColumn.title = "Added"
        addedColumn.width = 120
        for column in [titleColumn, sizeColumn, addedColumn] { table.addTableColumn(column) }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        // No bezel. A hard rectangular frame drawn around a list is the
        // pre-Big Sur look; `.inset` table style already gives the rows their
        // own inset shape, and Finder, Mail and Notes all let that sit
        // directly on the window rather than inside a box.
        scroll.borderType = .noBorder

        // What an empty table should say, in place of four blank rows.
        emptyLabel.stringValue = "Nothing here yet.\nAdd a .txt or .md file, or paste text."
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.maximumNumberOfLines = 2

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        // Add, Paste and Remove act on the whole library, so they belong in the
        // window's toolbar rather than in a row of push buttons along the
        // bottom. That row is the pre-Big Sur shape for this window, and moving
        // it up is also what gives this window the same unified title bar as
        // the practice window — one chrome for the app, not two.
        for subview in [scroll, statusLabel, emptyLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        window?.contentView = content

        let toolbar = NSToolbar(identifier: "TypeReviewLibrary")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
        // The table already reads as its own surface; a rule above it draws a
        // second edge where one is enough. Both properties are required — see
        // the note in `AppDelegate`: `.none` alone leaves a 1pt line that
        // belongs to the title bar's backdrop, not to the separator.
        window?.titlebarSeparatorStyle = .none
        window?.titlebarAppearsTransparent = true
    }

    private func reload() {
        table.reloadData()
        removeItem?.isEnabled = !table.selectedRowIndexes.isEmpty
        let count = store.passages.count
        emptyLabel.isHidden = count > 0
        table.usesAlternatingRowBackgroundColors = count > 0
        // The empty case is stated in the middle of the table, so the status
        // line does not repeat it.
        statusLabel.stringValue = count == 0
            ? ""
            : "\(count) of \(maxUserPassages) · practise them with View ▸ Source ▸ Library"
    }

    // MARK: - Adding

    @objc private func addFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, UTType("net.daringfireball.markdown") ?? .text]
        panel.message = "Choose plain-text or Markdown files to practise with."
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.ingest(urls: panel.urls)
        }
    }

    private func ingest(urls: [URL]) {
        var added = 0
        var failures: [String] = []
        for url in urls {
            // The panel grants access to the chosen file even under the
            // sandbox, but a security scope still has to be entered for files
            // reached any other way — a drag, for instance.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                failures.append("\(url.lastPathComponent): not readable as UTF-8")
                continue
            }
            let text = parseLibraryText(raw, kind: LibraryFileKind(filename: url.lastPathComponent))
            let title = url.deletingPathExtension().lastPathComponent
            do {
                try store.add(title: title, text: text)
                added += 1
            } catch UserPassageError.empty {
                failures.append("\(url.lastPathComponent): no text left after cleaning")
            } catch UserPassageError.full {
                failures.append("library is full (\(maxUserPassages))")
                break
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reload()
        if !failures.isEmpty {
            // Named rather than counted: "2 files failed" is not actionable.
            statusLabel.stringValue = failures.joined(separator: " · ")
        } else if added > 0 {
            statusLabel.stringValue = "added \(added) · \(store.passages.count) in library"
        }
    }

    @objc private func pasteText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            statusLabel.stringValue = "the clipboard has no text"
            return
        }
        do {
            // Pasted text is treated as plain prose. Someone copying Markdown
            // source would be an unusual thing to want to type as prose, and
            // guessing wrong silently deletes their asterisks.
            try store.add(title: "", text: sanitize(text).text)
            reload()
            statusLabel.stringValue = "pasted · \(store.passages.count) in library"
        } catch UserPassageError.empty {
            statusLabel.stringValue = "nothing to add — the clipboard text was all whitespace"
        } catch UserPassageError.full {
            statusLabel.stringValue = "library is full (\(maxUserPassages))"
        } catch {
            statusLabel.stringValue = "could not add: \(error.localizedDescription)"
        }
    }

    @objc private func removeSelected(_ sender: Any?) {
        let ids = table.selectedRowIndexes.compactMap { row -> String? in
            row < store.passages.count ? store.passages[row].id : nil
        }
        guard !ids.isEmpty else { return }
        do {
            for id in ids { try store.delete(id: id) }
            reload()
            statusLabel.stringValue = "removed \(ids.count)"
        } catch {
            statusLabel.stringValue = "could not remove: \(error.localizedDescription)"
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { store.passages.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < store.passages.count, let column = tableColumn else { return nil }
        let passage = store.passages[row]
        let text: String
        switch column.identifier.rawValue {
        case "title": text = passage.title
        case "size": text = "\(passage.text.count)"
        default:
            text = Self.dateFormatter.string(
                from: Date(timeIntervalSince1970: passage.createdAt / 1000))
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.font = NSFont.systemFont(ofSize: 12)
        if column.identifier.rawValue != "title" { field.textColor = .secondaryLabelColor }
        let cell = NSTableCellView()
        cell.addSubview(field)
        cell.textField = field
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeItem?.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// The window's content view, made a drop target.
///
/// Dropping a file on the window is the obvious Mac gesture for "add this to
/// my library", and it goes through exactly the same `ingest` path as the
/// open panel, so the two cannot diverge in what they accept.
private final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.plainText.identifier],
        ]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
            as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = urls(from: sender)
        guard !dropped.isEmpty else { return false }
        onDrop?(dropped)
        return true
    }
}

// MARK: - Toolbar

extension LibraryWindowController: NSToolbarDelegate {
    private static let addItem = NSToolbarItem.Identifier("add")
    private static let pasteItem = NSToolbarItem.Identifier("paste")
    private static let deleteItem = NSToolbarItem.Identifier("remove")

    private static let layout: [NSToolbarItem.Identifier] = [
        addItem, pasteItem, .flexibleSpace, deleteItem,
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.layout
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.layout
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.addItem:
            return item(identifier, "Add File", "plus", "Add a .txt or .md file", #selector(addFile(_:)))
        case Self.pasteItem:
            return item(
                identifier, "Paste Text", "doc.on.clipboard", "Add the clipboard as a passage",
                #selector(pasteText(_:)))
        case Self.deleteItem:
            let remove = item(
                identifier, "Remove", "trash", "Remove the selected passages",
                #selector(removeSelected(_:)))
            // Nothing is selected when the window is built, and a Remove that
            // is always live invites deleting whatever happens to be first.
            remove.isEnabled = false
            removeItem = remove
            return remove
        default:
            return nil
        }
    }

    private func item(
        _ identifier: NSToolbarItem.Identifier, _ label: String, _ symbol: String,
        _ tip: String, _ action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = Theme.symbol(symbol, size: Theme.SymbolSize.toolbar)
        item.target = self
        item.action = action
        item.isBordered = true
        // Validation is driven by the table's selection in `reload()`, so the
        // toolbar must not second-guess it on every runloop pass.
        item.autovalidates = false
        return item
    }
}
