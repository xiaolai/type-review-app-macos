import AppKit
import TypeReviewKit

/// The app's two end-to-end checks, run from the command line.
///
/// Extracted from `AppDelegate`, where they were the largest thing in the file
/// by some margin — a 175-line integration test and a 40-line audio check
/// living inside the object that also builds menus, owns windows and routes
/// keystrokes. Nothing here is delegate state: the self-test needs the
/// practice controller and the sound check needs nothing at all, so both are
/// static and take what they use.
///
/// They stay in the app target rather than moving to `TypeReviewKit`, and
/// deliberately: what they check is whether the *app* is wired to the engine,
/// which is exactly the question no unit test can answer.
@MainActor
enum Diagnostics {
    /// Proves every pack can actually produce sound in the built app.
    ///
    /// The unit tests cover the synthesis arithmetic, and they would pass just
    /// as happily if `typewriter.m4a` never made it into the bundle — the
    /// sample pack would simply go quiet, which looks exactly like a pack the
    /// user has not selected. This runs against the real app: real bundle,
    /// real decode, real slicing.
    static func runSoundCheck() {
        // A real `await`, not a nested run loop. Spinning `RunLoop.main`
        // inside a main-queue block keeps the main actor occupied, so the
        // decode task's hop back to it never runs and the wait always times
        // out — the check reported "no buffer" for a recording that was simply
        // never given the chance to arrive.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            let player = KeySoundPlayer()
            var failures: [String] = []
            for pack in KeySoundPack.all {
                player.setPack(pack)
                player.setVolume(1)
                // The recorded pack decodes off the main actor now, so it is
                // not ready the instant it is selected. Waited for rather than
                // slept past a fixed guess: the load reports its own failure,
                // and a check that gave up early would say "no buffer" for a
                // recording that was merely still arriving.
                if case .sample = pack.kind {
                    await waitForSample(player)
                    if let reason = player.loadFailure {
                        failures.append("\(pack.name): \(reason)")
                        continue
                    }
                }
                if case .silent = pack.kind {
                    if player.renderedPeak(for: .standard) != nil {
                        failures.append("\(pack.name): the off pack produced audio")
                    }
                    continue
                }
                for category in SoundCategory.allCases {
                    guard let peak = player.renderedPeak(for: category) else {
                        failures.append("\(pack.name)/\(category.rawValue): no buffer")
                        continue
                    }
                    guard peak > 0.001 else {
                        failures.append(
                            "\(pack.name)/\(category.rawValue): silent (peak \(peak))")
                        continue
                    }
                    print("SOUNDCHECK \(pack.name)/\(category.rawValue) peak \(peak)")
                }
            }
            if failures.isEmpty {
                print("SOUNDCHECK OK: every pack produces audio")
                exit(0)
            }
            for failure in failures { print("SOUNDCHECK FAIL: \(failure)") }
            exit(1)
        }
    }

    /// Waits for the recorded pack to finish decoding, or for it to say why it
    /// cannot.
    private static func waitForSample(_ player: KeySoundPlayer) async {
        let deadline = Date().addingTimeInterval(10)
        while player.renderedPeak(for: .standard) == nil, player.loadFailure == nil,
            Date() < deadline
        {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Drives a full run through the real UI and reports what reached disk.
    ///
    /// The same discipline the web-view shell used, for the same reason: unit
    /// tests cover the engine exhaustively, and none of them can tell whether
    /// the app is wired to it.
    static func runSelfTest(practice: PracticeViewController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let store = try? ProfileFileStore.standard()
            let before: Int
            if let store, case .ok(let profile) = store.load() {
                before = profile.results.count
            } else {
                before = 0
            }

            // A missing resource bundle looks exactly like an empty corpus to
            // the picker, so assert the data is actually there rather than
            // letting the app quietly serve generated words forever.
            guard BundledCorpus.quotes.entries.count > 100,
                !BundledCorpus.code.entries.isEmpty,
                BundledCorpus.loadFailures.isEmpty
            else {
                // The reasons, not just the counts. A resource that failed to
                // decode produced the same empty list as one that was never
                // copied, so this used to say "not bundled" for a file that
                // was sitting right there with a syntax error in it.
                print(
                    "SELFTEST FAIL: corpus not usable — "
                        + "\(BundledCorpus.quotes.entries.count) quotes, "
                        + "\(BundledCorpus.code.entries.count) code entries"
                        + (BundledCorpus.loadFailures.isEmpty
                            ? "" : " — " + BundledCorpus.loadFailures.joined(separator: "; ")))
                exit(1)
            }
            // The case must sit the same distance from the caps on all four
            // sides. This was wrong until it was measured: the inter-key gap
            // was being applied after the last key too, so the right and
            // bottom margins were a gap wider than the left and top.
            let keyboardLayout = KeyboardView().layout(forWidth: 900, height: 220)
            let capsRect = keyboardLayout.keys.dropFirst().reduce(keyboardLayout.keys[0].rect) {
                $0.union($1.rect)
            }
            let margins = [
                capsRect.minX - keyboardLayout.caseRect.minX,
                keyboardLayout.caseRect.maxX - capsRect.maxX,
                capsRect.minY - keyboardLayout.caseRect.minY,
                keyboardLayout.caseRect.maxY - capsRect.maxY,
            ]
            guard let tightest = margins.min(), let widest = margins.max(),
                widest - tightest < 0.5, tightest > 0
            else {
                print("SELFTEST FAIL: keyboard margins are \(margins) — expected four equal")
                exit(1)
            }

            // No key on any keyboard shape may be narrower than a key can be.
            //
            // Row totals are `unitsPerRow` by construction — the last key
            // absorbs the slack — so checking the total proves nothing. What
            // can go wrong is a row whose fixed keys leave the absorber too
            // little, or nothing, or less than nothing. That is what a ragged
            // or overflowing keyboard actually is, and nothing else reports
            // it: the view just draws it.
            for shape in [SystemKeyboard.Shape.ansi, .iso, .jis] {
                for (index, row) in KeyboardGeometry.rows(for: shape).enumerated() {
                    guard let narrowest = row.map(\.width).min(), narrowest >= 0.75 else {
                        print(
                            "SELFTEST FAIL: \(shape) row \(index) has a "
                                + "\(row.map(\.width).min() ?? 0)u key — the row does not fit")
                        exit(1)
                    }
                }
            }

            // Legends must come from a keyboard, not from an input method.
            //
            // With a CJK input method active, the *current* layout is the
            // input method's own, and asking it what a key produces answers
            // with `……` above 6 and `¥` above 4 — what that method types, not
            // what is printed on the key. The ASCII-capable layout is the
            // keyboard underneath. This check is worth little on a machine
            // that only ever runs a US layout, where both answers agree; it
            // bites on one where an input method is active, which is where the
            // bug appeared.
            guard SystemKeyboard.legendSourceIsASCIICapable else {
                print(
                    "SELFTEST FAIL: keycap legends are being read from "
                        + "\(SystemKeyboard.layoutName), which is not an ASCII-capable layout")
                exit(1)
            }

            // The status bar of live numbers must actually reach the screen.
            //
            // It did not, for the whole life of this app: laid out correctly,
            // in the hierarchy, not hidden, with the right text and colour —
            // and painted over, because the typing view filled its dirty rect
            // rather than its bounds and AppKit does not clip a view's drawing
            // to its own bounds. Every property that can be asserted from the
            // view tree was true while the pixels were blank, so the only
            // check that can catch it is a look at the pixels.
            //
            // The search walks the whole tree rather than one fixed level of
            // stack views. It used to assume the label was a direct child of a
            // stack that was a direct child of the root, which stopped being
            // true the moment the numbers moved into a status bar and gained a
            // nesting level — and the failure would have been this check
            // quietly not finding its subject.
            @MainActor func textFields(in view: NSView) -> [NSTextField] {
                view.subviews.flatMap { child -> [NSTextField] in
                    (child as? NSTextField).map { [$0] } ?? textFields(in: child)
                }
            }
            let allLabels = textFields(in: practice.view)
            guard let wpmLabel = allLabels.first(where: { $0.stringValue.hasSuffix("wpm") }) else {
                print("SELFTEST FAIL: no wpm label in the status bar")
                exit(1)
            }
            let root = practice.view
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                print("SELFTEST FAIL: could not render the practice view")
                exit(1)
            }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let labelRect = wpmLabel.convert(wpmLabel.bounds, to: root)
            let scale = CGFloat(bitmap.pixelsWide) / max(root.bounds.width, 1)
            // Raw bytes rather than `colorAt(x:y:)`, which raises on bitmap
            // formats it does not recognise — including the one AppKit hands
            // back for a cached display.
            guard let bytes = bitmap.bitmapData, bitmap.samplesPerPixel >= 3 else {
                print("SELFTEST FAIL: rendered bitmap has no readable pixels")
                exit(1)
            }
            let rowBytes = bitmap.bytesPerRow
            let step = bitmap.samplesPerPixel
            // The bitmap counts rows from the top; the view does not.
            let top = Int((root.bounds.height - labelRect.maxY) * scale)
            let background = Theme.background.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1
            let firstRow = max(0, top)
            let lastRow = min(bitmap.pixelsHigh, top + Int(labelRect.height * scale))
            let firstColumn = max(0, Int(labelRect.minX * scale))
            let lastColumn = min(bitmap.pixelsWide, Int(labelRect.maxX * scale))
            let rows: Range<Int> = firstRow..<max(firstRow, lastRow)
            let columns: Range<Int> = firstColumn..<max(firstColumn, lastColumn)
            var inked = 0
            for y in rows {
                for x in columns {
                    let offset = y * rowBytes + x * step
                    let brightness =
                        (CGFloat(bytes[offset]) + CGFloat(bytes[offset + 1])
                            + CGFloat(bytes[offset + 2])) / (3 * 255)
                    if abs(brightness - background) > 0.15 { inked += 1 }
                }
            }
            guard inked > 20 else {
                print(
                    "SELFTEST FAIL: the header reads \"\(wpmLabel.stringValue)\" but only "
                        + "\(inked) of its pixels differ from the background — it is covered")
                exit(1)
            }

            // The library round-trip, through the real file store: add,
            // reload from disk, confirm the corpus serves it, delete. The unit
            // tests cover the parser and the picker; only this can tell
            // whether the app is wired to them.
            let library = practice.library
            let libraryBefore = library.passages.count
            do {
                try library.add(title: "selftest", text: "the quick brown fox jumps over it")
            } catch {
                print("SELFTEST FAIL: library add: \(error)")
                exit(1)
            }
            let reread = LibraryStore(directory: library.directory)
            guard reread.passages.count == libraryBefore + 1,
                let added = reread.passages.last,
                added.title == "selftest"
            else {
                print("SELFTEST FAIL: library did not survive a reload from \(library.fileURL.path)")
                exit(1)
            }
            var libraryRNG = Mulberry32(seed: 1)
            let served = try? CorpusAdapter(channel: .user, library: reread.passages)
                .adaptiveSource(
                    filter: Filter(allowed: ["e", "t", "a"], focus: nil), wordCount: 7,
                    rng: &libraryRNG)
            guard served?.text == added.text else {
                print("SELFTEST FAIL: Library channel served \(served?.text ?? "nothing")")
                exit(1)
            }
            do { try library.delete(id: added.id) } catch {
                print("SELFTEST FAIL: library delete: \(error)")
                exit(1)
            }

            guard let view = practice.view.subviews.compactMap({ $0 as? TypingView }).first else {
                print("SELFTEST FAIL: no typing surface")
                exit(1)
            }
            // A human cadence. Without it the run lands at hundreds of
            // thousands of wpm, which the profile validator rightly refuses —
            // the metric bounds exist to catch exactly that shape of nonsense.
            var syntheticClock: Double = 0
            practice.clock = {
                syntheticClock += 120
                return syntheticClock
            }
            // Through the same entry point AppKit uses for committed text, so
            // the input path is the one being tested rather than bypassed.
            let expected = practice.currentPassage
            guard !expected.isEmpty else {
                print("SELFTEST FAIL: no passage")
                exit(1)
            }
            for unit in Array(expected.utf16) {
                view.insertText(String(utf16CodeUnits: [unit], count: 1), replacementRange: NSRange())
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let store else {
                    print("SELFTEST FAIL: no store")
                    exit(1)
                }
                let reloaded = store.load()
                guard case .ok(let profile) = reloaded else {
                    print(
                        "SELFTEST FAIL: profile reloaded as \(reloaded.statusName) from \(store.fileURL.path)"
                            + " — in-memory runs: \(practice.runCount)")
                    exit(1)
                }
                guard profile.results.count == before + 1 else {
                    print(
                        "SELFTEST FAIL: expected \(before + 1) runs on disk, found \(profile.results.count)")
                    exit(1)
                }
                let metrics = profile.results.last!.metrics
                // The check types the passage exactly, so anything but a
                // perfect run means characters were dropped, reordered or
                // scored against text that changed underneath — and none of
                // that showed up before, because the only assertion was that
                // *a* run reached disk. One run at 1% accuracy was reported as
                // OK before this line existed.
                guard metrics.accuracy > 99.9, metrics.correctChars == expected.utf16.count else {
                    print(
                        "SELFTEST FAIL: typed \(expected.utf16.count) characters exactly but the "
                            + "run recorded \(Int(metrics.accuracy))% accuracy "
                            + "(\(metrics.correctChars) correct, \(metrics.incorrectChars) wrong)")
                    exit(1)
                }
                // The status item's mark, before the summary. A template
                // image is only ever read for its alpha, so one that draws
                // nothing is not a faint icon — it is an empty menu-bar slot,
                // and every build in front of it stays green. The geometry is
                // shared with the Dock icon, so a change made for one can
                // empty the other with nothing on screen to say so.
                let mark = Mark.menuBarImage(pointSize: Theme.SymbolSize.menuBarMark)
                let side = Int(Theme.SymbolSize.menuBarMark * 2)
                let markRep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                if let markRep {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: markRep)
                    mark.draw(in: NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
                    NSGraphicsContext.restoreGraphicsState()
                }
                var inked = 0
                if let markRep {
                    for y in 0..<markRep.pixelsHigh {
                        for x in 0..<markRep.pixelsWide
                        where (markRep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.08 {
                            inked += 1
                        }
                    }
                }
                // A fifth of the square is the floor. The mark is an outlined
                // window with keys in it and covers about half; anything near
                // zero is an empty slot, and a solid block would mean the
                // geometry collapsed rather than drew.
                let coverage = Double(inked) / Double(side * side)
                guard mark.isTemplate, coverage > 0.20, coverage < 0.85 else {
                    print(
                        "SELFTEST FAIL: menu-bar mark covers "
                            + String(format: "%.0f%%", coverage * 100)
                            + " of its square (template: \(mark.isTemplate))")
                    exit(1)
                }
                print(
                    "SELFTEST OK: typed \(expected.utf16.count) chars — "
                        + "\(Int(metrics.netWpm)) wpm, \(Int(metrics.accuracy))% accuracy, "
                        + "\(profile.results.count) run(s) on disk")
                exit(0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            print("SELFTEST FAIL: timed out")
            exit(2)
        }
    }
}
