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
    private let removeButton = NSButton()

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

        table.usesAlternatingRowBackgroundColors = true
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
        scroll.borderType = .bezelBorder

        let addFile = NSButton(
            title: "Add File…", target: self, action: #selector(addFile(_:)))
        let paste = NSButton(
            title: "Paste Text", target: self, action: #selector(pasteText(_:)))
        removeButton.title = "Remove"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        removeButton.isEnabled = false
        for button in [addFile, paste] { button.bezelStyle = .rounded }

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let buttons = NSStackView(views: [addFile, paste, removeButton, statusLabel])
        buttons.spacing = 8
        buttons.alignment = .centerY

        for subview in [scroll, buttons] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window?.contentView = content
    }

    private func reload() {
        table.reloadData()
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
        let count = store.passages.count
        statusLabel.stringValue = count == 0
            ? "empty — add a .txt or .md file, or paste text"
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
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
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
