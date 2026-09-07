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
    /// Written once: the empty state is also restored after the unreadable
    /// state has replaced it.
    private static let emptyMessage = "Nothing here yet.\nAdd a .txt or .md file, or paste text."

    /// What sanitising did to a passage, when it did anything worth saying.
    private static func note(for result: SanitizeResult) -> String {
        var parts: [String] = []
        if result.truncated { parts.append("truncated to the \(maxUserPassageLength)-character cap") }
        if result.droppedChars > 0 { parts.append("\(result.droppedChars) unusable characters removed") }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }
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
        configureTable()
        let scroll = makeScrollView()
        styleLabels()
        install(scroll: scroll, in: content)
        window?.contentView = content
        configureWindowChrome()
    }

    /// Columns, selection and row style. Split out of `build`, which
    /// configured the table, the scroll view, the empty state, the layout, the
    /// toolbar and the window's chrome in one 81-line run.
    private func configureTable() {
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
    }

    private func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        // No bezel. A hard rectangular frame drawn around a list is the
        // pre-Big Sur look; `.inset` table style already gives the rows their
        // own inset shape, and Finder, Mail and Notes all let that sit
        // directly on the window rather than inside a box.
        scroll.borderType = .noBorder
        return scroll
    }

    private func styleLabels() {
        // What an empty table should say, in place of four blank rows.
        emptyLabel.stringValue = Self.emptyMessage
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.maximumNumberOfLines = 2

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
    }

    /// Add, Paste and Remove act on the whole library, so they belong in the
    /// window's toolbar rather than in a row of push buttons along the bottom.
    /// That row is the pre-Big Sur shape for this window, and moving it up is
    /// also what gives this window the same unified title bar as the practice
    /// window — one chrome for the app, not two.
    private func install(scroll: NSScrollView, in content: NSView) {
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
    }

    private func configureWindowChrome() {
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
        // Unreadable is not empty. Both have zero passages in memory, so the
        // window said "Nothing here yet" over a file that was sitting on disk
        // full of text it could not parse — and the user only found out when
        // an addition was refused.
        if store.isUnreadable {
            emptyLabel.stringValue = "This library file could not be read."
            emptyLabel.isHidden = false
            statusLabel.stringValue =
                "not overwriting it — the file is at \(store.fileURL.path)"
            return
        }
        emptyLabel.stringValue = Self.emptyMessage
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
        statusLabel.stringValue = "reading \(urls.count) file\(urls.count == 1 ? "" : "s")…"
        // Read and parsed off the main actor. This did all of it inline in the
        // panel's callback — open a large file, or a batch of them, on a slow
        // volume and the whole app stopped until it finished, with the cap on
        // passage length applied only at the very end and so bounding nothing
        // that had already been done.
        Task { @MainActor in
            let parsed = await Self.read(urls)
            self.install(parsed)
        }
    }

    /// One file's worth of text, or the reason there is none.
    private struct Ingested: Sendable {
        let name: String
        let title: String
        let text: String?
        let failure: String?
    }

    private nonisolated static func read(_ urls: [URL]) async -> [Ingested] {
        await Task.detached(priority: .userInitiated) {
            urls.map { url in
                let name = url.lastPathComponent
                let title = url.deletingPathExtension().lastPathComponent
                // The panel grants access to the chosen file even under the
                // sandbox, but a security scope still has to be entered for
                // files reached any other way — a drag, for instance.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // Bounded before anything is decoded. The passage cap used to
                // apply only after the whole file had been read and parsed, so
                // a gigabyte of text was a gigabyte of work to then discard.
                // Generous enough that nothing anyone would type is refused.
                let limit = maxUserPassageLength * 8
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: limit) ?? Data()
                    guard let raw = String(data: data, encoding: .utf8) else {
                        return Ingested(
                            name: name, title: title, text: nil,
                            failure: "\(name): not readable as UTF-8")
                    }
                    let text = parseLibraryText(raw, kind: LibraryFileKind(filename: name))
                    return Ingested(name: name, title: title, text: text, failure: nil)
                } catch {
                    // The actual reason. `try?` reported "not readable as
                    // UTF-8" for a permission failure and for a file that had
                    // been moved, which is the wrong thing to go and fix.
                    return Ingested(
                        name: name, title: title, text: nil,
                        failure: "\(name): \(error.localizedDescription)")
                }
            }
        }.value
    }

    /// Adds what was read. On the main actor, because the store is.
    private func install(_ parsed: [Ingested]) {
        var added = 0
        var failures: [String] = []
        for item in parsed {
            if let failure = item.failure {
                failures.append(failure)
                continue
            }
            guard let text = item.text else { continue }
            do {
                try store.add(title: item.title, text: text)
                added += 1
            } catch UserPassageError.empty {
                failures.append("\(item.name): no typeable text left after cleaning")
            } catch UserPassageError.full {
                failures.append("library is full (\(maxUserPassages))")
                break
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
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
            let cleaned = sanitize(text)
            try store.add(title: "", text: cleaned.text)
            reload()
            // Says what it did to the text. More than the cap was silently cut
            // to the cap and reported as an ordinary success, so someone
            // pasting a chapter got its first few pages and no indication that
            // the rest had gone.
            statusLabel.stringValue =
                "pasted\(Self.note(for: cleaned)) · \(store.passages.count) in library"
        } catch UserPassageError.empty {
            // Not "whitespace". Sanitising also removes control characters and
            // anything outside the basic plane, so an emoji-only clipboard
            // reached here and was told it contained spaces.
            statusLabel.stringValue = "nothing to add — no typeable text left after cleaning"
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
        // Reloaded whatever happens. Deletions commit one at a time, so a
        // failure part way through left earlier ones committed while the table
        // still showed them — and the next attempt, working from stale row
        // indexes, would have deleted different passages.
        var removed = 0
        var failure: String?
        for id in ids {
            do {
                try store.delete(id: id)
                removed += 1
            } catch {
                failure = error.localizedDescription
                break
            }
        }
        reload()
        statusLabel.stringValue = failure.map {
            removed == 0 ? "could not remove: \($0)" : "removed \(removed) of \(ids.count) — \($0)"
        } ?? "removed \(removed)"
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
        // Validation is driven by the table's selection in `reload()`, so the
        // toolbar must not second-guess it on every runloop pass.
        ToolbarItems.button(
            identifier, label: label, symbol: symbol, tip: tip, target: self, action: action,
            autovalidates: false)
    }
}
