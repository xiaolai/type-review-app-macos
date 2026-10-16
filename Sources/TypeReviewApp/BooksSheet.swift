import AppKit
import TypeReviewKit
import UniformTypeIdentifiers

/// The Books sheet: the shelf, with Continue, Import… and Remove.
///
/// A sheet on the main window rather than a window of its own, unlike the
/// Library. Choosing a book is a step on the way to typing it, made over the
/// screen it is typed on, and it is finished when the choice is.
///
/// The starter shelf — public-domain books that ship in the app — is listed
/// below the books on this Mac. Continuing one puts it on the shelf first.
@MainActor
final class BooksSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: BookStore
    private let table = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let importButton = NSButton(title: "Import…", target: nil, action: nil)

    var onOpen: (String) -> Void = { _ in }
    var onShelfChanged: () -> Void = {}
    /// The child's typing speed so far, for the review sheet's estimate.
    var readingWpm: () -> Double? = { nil }

    private enum Row {
        case book(BookSummary)
        case shelf(Book)
    }
    private var rows: [Row] = []
    private var review: BookReviewController?
    private var onDismiss: () -> Void = {}

    init(store: BookStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Books"
        window.useSRGBBacking()
        super.init(window: window)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present(on parent: NSWindow, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        reload()
        guard let window else { return }
        parent.beginSheet(window)
    }

    private func build() {
        let content = NSView()
        table.style = .inset
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(continuePressed)
        table.target = self
        for (id, title, width) in [
            ("title", "Book", 300.0), ("place", "Read", 90.0), ("sentences", "Sentences", 90.0),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        importButton.target = self
        importButton.action = #selector(importPressed)
        removeButton.target = self
        removeButton.action = #selector(removePressed)
        let close = NSButton(title: "Close", target: self, action: #selector(closePressed))
        close.keyEquivalent = "\u{1b}"
        continueButton.target = self
        continueButton.action = #selector(continuePressed)
        continueButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [importButton, removeButton, progress, NSView(), close, continueButton])
        buttons.spacing = 8
        for subview in [scroll, statusLabel, buttons] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        window?.contentView = content
    }

    private func reload() {
        let onShelf = Set(store.books.map(\.id))
        rows = store.books.map(Row.book) + BundledShelf.books.filter { !onShelf.contains($0.id) }.map(Row.shelf)
        table.reloadData()
        if table.selectedRow < 0, !rows.isEmpty {
            let current = AppPreferences.lastBook.value
            let index = rows.firstIndex { if case .book(let b) = $0 { return b.id == current } else { return false } }
            table.selectRowIndexes([index ?? 0], byExtendingSelection: false)
        }
        if store.indexIsUnreadable {
            statusLabel.stringValue =
                BookStoreError.unreadable(store.indexURL.lastPathComponent).errorDescription ?? ""
        } else if rows.isEmpty {
            statusLabel.stringValue = "No books yet. Import a plain-text (.txt) or EPUB book."
        }
        updateButtons()
    }

    private func updateButtons() {
        let row = table.selectedRow
        continueButton.isEnabled = rows.indices.contains(row)
        if rows.indices.contains(row), case .book = rows[row] {
            removeButton.isEnabled = !store.indexIsUnreadable
        } else {
            removeButton.isEnabled = false
        }
        importButton.isEnabled = !store.indexIsUnreadable && review == nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        switch (rows[row], id) {
        case (.book(let book), "title"):
            text = book.author.isEmpty ? book.title : "\(book.title) — \(book.author)"
        case (.book(let book), "place"):
            text = "\(percentRead(book))%"
        case (.book(let book), "sentences"):
            text = String(book.sentenceCount)
        case (.shelf(let book), "title"):
            text = book.author.isEmpty ? book.title : "\(book.title) — \(book.author)"
        case (.shelf, "place"):
            text = "Starter shelf"
        case (.shelf(let book), "sentences"):
            text = String(book.sentences.count)
        default:
            return nil
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if id != "title" { label.textColor = .secondaryLabelColor }
        return label
    }

    private func percentRead(_ book: BookSummary) -> Int {
        guard case .ok(let saved) = store.progress(book.id), book.sentenceCount > 0 else { return 0 }
        return min(100, saved.sentence * 100 / book.sentenceCount)
    }

    // MARK: - Actions

    @objc private func continuePressed() {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .book(let book):
            dismiss()
            onOpen(book.id)
        case .shelf(let book):
            do {
                try store.add(book)
            } catch {
                statusLabel.stringValue = error.localizedDescription
                return
            }
            onShelfChanged()
            dismiss()
            onOpen(book.id)
        }
    }

    @objc private func removePressed() {
        let row = table.selectedRow
        guard rows.indices.contains(row), case .book(let book) = rows[row], let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \u{201C}\(book.title)\u{201D}?"
        alert.informativeText = "The place in it and its days in the statistics go with it."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                do {
                    try self.store.remove(book.id)
                    self.statusLabel.stringValue = ""
                } catch {
                    self.statusLabel.stringValue = error.localizedDescription
                }
                self.onShelfChanged()
                self.reload()
            }
        }
    }

    @objc private func closePressed() { dismiss() }

    private func dismiss() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        onDismiss()
    }

    @objc private func importPressed() {
        guard let window else { return }
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText]
        if let epub = UTType(filenameExtension: "epub") { types.append(epub) }
        panel.allowedContentTypes = types
        // An EPUB from Apple Books is a folder named `*.epub`.
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a plain-text (.txt) or EPUB book."
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.read(url)
            }
        }
    }

    /// Reads off the main thread, then shows the review sheet.
    func read(_ url: URL) {
        statusLabel.stringValue = "Reading \u{201C}\(url.lastPathComponent)\u{201D}…"
        progress.startAnimation(nil)
        importButton.isEnabled = false
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { try BookImport.draft(from: url) }
            await MainActor.run { [weak self] in self?.readFinished(result) }
        }
    }

    private func readFinished(_ result: Result<BookDraft, Error>) {
        progress.stopAnimation(nil)
        switch result {
        case .failure(let error):
            statusLabel.stringValue = error.localizedDescription
            updateButtons()
        case .success(let draft):
            statusLabel.stringValue = ""
            showReview(draft)
        }
    }

    /// The review sheet, over this one.
    func showReview(_ draft: BookDraft) {
        guard let window else { return }
        let review = BookReviewController(draft: draft, wpm: readingWpm())
        self.review = review
        review.onImport = { [weak self] reviewed in self?.importReviewed(reviewed) ?? false }
        review.onFinish = { [weak self] in
            self?.review = nil
            self?.updateButtons()
        }
        review.present(on: window)
        updateButtons()
    }

    /// Saves the reviewed book. Returns false, with the reason on the review
    /// sheet, when it cannot be.
    private func importReviewed(_ draft: BookDraft) -> Bool {
        do {
            let book = try store.add(draft)
            onShelfChanged()
            reload()
            if let row = rows.firstIndex(where: { if case .book(let b) = $0 { return b.id == book.id } else { return false } }) {
                table.selectRowIndexes([row], byExtendingSelection: false)
            }
            statusLabel.stringValue = "\u{201C}\(book.title)\u{201D} is on the shelf: \(book.sentences.count) sentences."
            return true
        } catch {
            review?.show(error: error.localizedDescription)
            return false
        }
    }

    // MARK: - Probes, for `--selftest`

    var rowTitles: [String] {
        rows.map {
            switch $0 {
            case .book(let book): return book.title
            case .shelf(let book): return "shelf:" + book.title
            }
        }
    }
    var reviewSheet: BookReviewController? { review }
}

/// The parent's review of an imported book, before anything is saved.
///
/// One row per part of the book: a tick, the title, what the reader took it
/// for and why, its words, and its first line. The rules will be wrong for
/// some book, so a person makes the final call. Story starts ticked, the rest
/// unticked but listed, so a wrong guess can be undone.
@MainActor
final class BookReviewController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var draft: BookDraft
    private let wpm: Double?
    private let table = NSTableView()
    private let titleField = NSTextField(string: "")
    private let authorField = NSTextField(string: "")
    private let totalsLabel = NSTextField(labelWithString: "")
    private let warningsLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)

    /// Saves the book; answers whether it was.
    var onImport: (BookDraft) -> Bool = { _ in false }
    var onFinish: () -> Void = {}

    init(draft: BookDraft, wpm: Double?) {
        self.draft = draft
        self.wpm = wpm
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Review the Book"
        window.useSRGBBacking()
        super.init(window: window)
        build()
        updateTotals()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
    }

    private func build() {
        let content = NSView()
        titleField.stringValue = draft.title
        authorField.stringValue = draft.author
        titleField.placeholderString = "Title"
        authorField.placeholderString = "Author"
        let fields = NSGridView(views: [
            [NSTextField(labelWithString: "Title:"), titleField],
            [NSTextField(labelWithString: "Author:"), authorField],
        ])
        fields.column(at: 0).xPlacement = .trailing
        fields.rowSpacing = 6

        table.style = .inset
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        for (id, title, width) in [
            ("include", "", 24.0), ("title", "Part", 160.0), ("kind", "Kind", 70.0),
            ("reason", "Why", 150.0), ("words", "Words", 60.0), ("first", "First line", 240.0),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        totalsLabel.font = Theme.statFont
        warningsLabel.textColor = .systemOrange
        warningsLabel.font = .systemFont(ofSize: 12)
        warningsLabel.stringValue = draft.warnings.map { "⚠︎ " + $0.message }.joined(separator: "\n")
        warningsLabel.isHidden = draft.warnings.isEmpty
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.isHidden = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        importButton.target = self
        importButton.action = #selector(importPressed)
        importButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, importButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [fields, warningsLabel, scroll, totalsLabel, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
        ])
        window?.contentView = content
    }

    /// Words, sittings at the child's speed, and whether there is anything to
    /// import at all.
    private func updateTotals() {
        let words = draft.includedWords
        let sittings = estimatedSittings(words: words, wpm: wpm)
        let speed = wpm.map { String(format: "%.0f wpm so far", $0) } ?? "15 wpm, until there is a speed to go by"
        let ticked = draft.chapters.filter(\.included).count
        totalsLabel.stringValue =
            "\(ticked) of \(draft.chapters.count) parts · \(words.formatted()) words · "
            + "about \(sittings) \(sittings == 1 ? "sitting" : "sittings") of 20 minutes at \(speed)"
        importButton.isEnabled = ticked > 0
    }

    func show(error: String) {
        errorLabel.stringValue = error
        errorLabel.isHidden = false
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { draft.chapters.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard draft.chapters.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let chapter = draft.chapters[row]
        if id == "include" {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(tickChanged(_:)))
            box.state = chapter.included ? .on : .off
            box.tag = row
            return box
        }
        let text: String
        switch id {
        case "title": text = chapter.title.isEmpty ? "Untitled" : chapter.title
        case "kind": text = chapter.kind.label
        case "reason": text = chapter.reason
        case "words": text = chapter.words.formatted()
        case "first": text = chapter.firstLine
        default: return nil
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = id == "first" || id == "reason" ? text : nil
        if !chapter.included { label.textColor = .secondaryLabelColor }
        return label
    }

    @objc private func tickChanged(_ sender: NSButton) {
        setIncluded(sender.state == .on, row: sender.tag)
    }

    func setIncluded(_ included: Bool, row: Int) {
        guard draft.chapters.indices.contains(row) else { return }
        draft.chapters[row].included = included
        table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        updateTotals()
    }

    // MARK: - Actions

    @objc private func cancelPressed() { finish() }

    @objc private func importPressed() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.title = title.isEmpty ? draft.title : title
        draft.author = authorField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if onImport(draft) { finish() }
    }

    /// Presses Import, as the button does.
    func pressImport() { importPressed() }

    private func finish() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        onFinish()
    }

    // MARK: - Probes, for `--selftest`

    var totals: String { totalsLabel.stringValue }
    var warnings: String { warningsLabel.isHidden ? "" : warningsLabel.stringValue }
    var tableRowCount: Int { table.numberOfRows }
    var isImportEnabled: Bool { importButton.isEnabled }
}

extension ChapterKind {
    /// What the review sheet calls a kind.
    var label: String {
        switch self {
        case .story: return "Story"
        case .optional: return "Extra"
        case .skip: return "Skipped"
        }
    }
}
