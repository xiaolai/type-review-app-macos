import AppKit
import TypeReviewKit

extension Diagnostics {
    /// Renders the App Store screenshots, for `make screenshots`.
    ///
    /// Staged, not caught. Play animates, so a screenshot taken off the screen
    /// is whatever frame happened to be up; here every scene is set up by hand
    /// instead — a seeded game stepped to a chosen moment with time then held,
    /// a practice run typed to a chosen point on a synthetic clock — and each
    /// window is rendered by AppKit into an image. Nothing is read back from the
    /// screen, so nothing needs Screen Recording permission or an unlocked
    /// session, which is what lets this run on a Mac nobody is using.
    ///
    /// What it writes is raw: each window as AppKit drew it, and beside it a
    /// JSON file saying where the window sat. `Tools/compose-screenshots.swift`
    /// puts them on the App Store's canvas with the corners and shadow the
    /// window server would have added, and checks what it made.
    static func runScreenshots(app: AppDelegate) {
        guard let index = CommandLine.arguments.firstIndex(of: "--screenshots"),
            CommandLine.arguments.indices.contains(index + 1)
        else { stop("usage: --screenshots <output folder>", code: 2) }
        let raw = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            .appendingPathComponent("raw", isDirectory: true)
        // Fresh every run: a scene that fails to write must not leave last
        // run's picture of it behind to be composed as if it were new.
        try? FileManager.default.removeItem(at: raw)
        do {
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        } catch {
            stop("could not create \(raw.path): \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let window = app.window, let practice = app.practice, let play = app.play,
                let surface = practice.view.subviews.compactMap({ $0 as? TypingView }).first
            else { stop("the main window, its screens or the typing surface are missing") }
            // A window that is not key draws its inactive state: grey traffic
            // lights, a grey title mark, the keyboard toggle without its accent.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            play.holdsTime = true
            play.nextSeed = { 20_260_919 }
            let typist = Typist(practice: practice, surface: surface)
            typist.typeHistory()
            let runs = Typist.practiceDays.count
            guard practice.history.count == runs else {
                stop("typed \(runs) runs and the profile holds \(practice.history.count)")
            }
            let scenes = scenes(app: app, window: window, practice: practice, play: play, typist: typist)
            run(scenes[...], into: raw) {
                print("SCREENSHOTS OK: \(scenes.count) scenes rendered into \(raw.path)")
                exit(0)
            }
        }
    }

    // MARK: - Scenes

    private struct Scene {
        let name: String
        let dark: Bool
        /// Sets the scene up and answers the windows to render, lowest first.
        let stage: @MainActor () throws(CheckFailure) -> [NSWindow]
    }

    private static func scenes(
        app: AppDelegate, window: NSWindow, practice: PracticeViewController,
        play: PlayViewController, typist: Typist
    ) -> [Scene] {
        let main = { (window.childWindows ?? []) + [window] }
        // A screen just put in the window has not been laid out, and a field
        // with no height is one nothing falls through.
        let show = { (screen: MainScreen) in
            app.show(screen, remember: false)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        return [
            Scene(name: "1-play-words", dark: false) { () throws(CheckFailure) in
                show(.play)
                try stageWords(play)
                return main()
            },
            Scene(name: "2-play-letters", dark: true) { () throws(CheckFailure) in
                show(.play)
                try stageLetters(play)
                return main()
            },
            Scene(name: "3-practice", dark: false) { () throws(CheckFailure) in
                show(.practice)
                try typist.typePartOfARun()
                return main()
            },
            Scene(name: "4-statistics", dark: false) { () throws(CheckFailure) in
                app.showStats(nil)
                guard let stats = NSApp.windows.first(where: { $0.title == "Statistics" }) else {
                    throw CheckFailure(message: "the Statistics window did not open")
                }
                stats.makeKeyAndOrderFront(nil)
                return [stats]
            },
            Scene(name: "5-sound", dark: false) { () throws(CheckFailure) in
                app.showSettings(nil)
                guard
                    let settings = NSApp.windows.first(where: {
                        $0.windowController is SettingsWindowController
                    })
                else { throw CheckFailure(message: "the Settings window did not open") }
                settings.makeKeyAndOrderFront(nil)
                return [settings]
            },
        ]
    }

    /// Words, part way into a game: a word bursting, the next one half typed.
    private static func stageWords(_ play: PlayViewController) throws(CheckFailure) {
        play.seedEffects(7)
        play.newGame(mode: .words, gentle: true, remember: false)
        play.typeThroughInput(" ")
        // A game under way: a score, a streak, and the pace up enough that
        // more than one word is falling.
        for _ in 0..<14 {
            try step(play, until: "a word to type") { ($0.game.target?.y ?? -1) > 0 }
            clear(play)
        }
        // Two in view is as busy as Words gets: the pace that lets a third
        // fall also spaces arrivals a third of the field apart.
        try step(play, until: "two words well in view, the lower past half way") { play in
            busy(play, count: 2, from: 0.18, lowest: 0.55...0.7)
        }
        clear(play)
        // Long enough for the letters to fly apart, not so long that they
        // have gone.
        play.advance(by: 0.26)
        // Half of the next word, and never all of it.
        if let next = play.game.target, next.chars.count > 1 {
            for character in next.chars.prefix(min(2, next.chars.count - 1)) {
                play.typeThroughInput(character)
            }
        }
        guard play.effectsInFlight > 0 else { throw CheckFailure(message: "Words: nothing bursting") }
        guard (play.game.target?.typed ?? 0) > 0 else {
            throw CheckFailure(message: "Words: no word half typed")
        }
    }

    /// Letters, with the lesson on the keyboard: several falling, one bursting.
    private static func stageLetters(_ play: PlayViewController) throws(CheckFailure) {
        play.seedEffects(11)
        play.newGame(mode: .letters, gentle: true, remember: false)
        play.typeThroughInput(" ")
        // Eight quick clears lift the pace to about 1.5: fast enough to allow
        // four at once, slow enough that four fit in view. Every quick clear
        // adds 5%, and much past 1.9 they arrive too far apart for four.
        for _ in 0..<8 {
            try step(play, until: "a letter to type") { ($0.game.target?.y ?? -1) > 0 }
            clear(play)
        }
        try step(play, until: "four letters in view, the lowest past half way") { play in
            busy(play, count: 4, from: 0.02, lowest: 0.55...0.75)
        }
        clear(play)
        play.advance(by: 0.24)
        guard play.effectsInFlight > 0 else { throw CheckFailure(message: "Letters: nothing bursting") }
    }

    /// Whether `count` things are at least `from` down the field with the
    /// lowest in `lowest`, both fractions of its height. Anything that gets
    /// past the band is typed, so the wait never ends in a pile on the floor.
    private static func busy(
        _ play: PlayViewController, count: Int, from: Double, lowest: ClosedRange<Double>
    ) -> Bool {
        let height = play.game.field.height
        guard let target = play.game.target else { return false }
        if target.y > height * lowest.upperBound {
            clear(play)
            return false
        }
        let inView = play.game.items.filter { $0.y >= height * from }
        return inView.count >= count && target.y >= height * lowest.lowerBound
    }

    /// Steps the game a frame at a time until `done` holds, and fails rather
    /// than spinning when a minute of game time goes by without it.
    private static func step(
        _ play: PlayViewController, until what: String, _ done: (PlayViewController) -> Bool
    ) throws(CheckFailure) {
        for _ in 0..<3600 {
            if done(play) { return }
            play.advance(by: 1.0 / 60)
        }
        throw CheckFailure(message: "a minute of play went by without \(what)")
    }

    /// Types what the target wants, all of it.
    private static func clear(_ play: PlayViewController) {
        guard let target = play.game.target else { return }
        let rest = play.game.mode == .letters ? [target.chars[0]] : Array(target.chars[target.typed...])
        for character in rest { play.typeThroughInput(character) }
    }

    // MARK: - Running and rendering

    private static func run(
        _ scenes: ArraySlice<Scene>, into raw: URL, done: @escaping @MainActor () -> Void
    ) {
        guard let scene = scenes.first else { return done() }
        NSApp.appearance = NSAppearance(named: scene.dark ? .darkAqua : .aqua)
        // Twice: once for the appearance to reach every view and layer, and
        // once for what the scene staged in it to be drawn.
        settle {
            let windows: [NSWindow]
            do throws(CheckFailure) {
                windows = try scene.stage()
            } catch {
                stop("\(scene.name): \(error.message)")
            }
            settle {
                capture(scene, windows, into: raw)
                run(scenes.dropFirst(), into: raw, done: done)
            }
        }
    }

    /// Lets AppKit lay out and draw before anything is read back.
    private static func settle(_ then: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                NSApp.windows.forEach { $0.displayIfNeeded() }
                CATransaction.flush()
                then()
            }
        }
    }

    /// Where a window sat, for the composer.
    private struct Placed: Codable {
        let file: String
        let x, y, width, height, scale: Double
        /// A titled window gets the window server's rounded corners; anything
        /// else draws its own shape.
        let titled: Bool
    }

    private struct Shot: Codable {
        let name: String
        let dark: Bool
        let windows: [Placed]
    }

    private static func capture(_ scene: Scene, _ windows: [NSWindow], into raw: URL) {
        // The top window must be key, or it is drawn in its inactive state and
        // the picture is wrong in a way nothing else would notice. Asked for
        // again once, since another app in front can take activation away.
        guard let top = windows.last else { stop("\(scene.name): no windows to render") }
        if !top.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            top.makeKeyAndOrderFront(nil)
            top.displayIfNeeded()
        }
        guard NSApp.isActive, top.isKeyWindow else {
            stop(
                "\(scene.name): the window is not key, so it would be drawn inactive. "
                    + "Another app is in front on this Mac; run with its screen locked or idle.")
        }
        var placed: [Placed] = []
        for (index, window) in windows.enumerated() {
            guard let image = render(window, scene: scene.name) else {
                stop("\(scene.name): window \(index) could not be rendered")
            }
            let file = "\(scene.name)-\(index).png"
            write(image, to: raw.appendingPathComponent(file))
            placed.append(
                Placed(
                    file: file, x: window.frame.minX, y: window.frame.minY,
                    width: window.frame.width, height: window.frame.height,
                    scale: window.backingScaleFactor, titled: window.styleMask.contains(.titled)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(Shot(name: scene.name, dark: scene.dark, windows: placed))
                .write(to: raw.appendingPathComponent("\(scene.name).json"))
        } catch {
            stop("\(scene.name): could not write its description: \(error.localizedDescription)")
        }
        print("rendered \(scene.name): \(windows.count) window(s)")
    }

    /// A window as AppKit draws it, frame and toolbar included, at its
    /// backing scale.
    private static func render(_ window: NSWindow, scene: String) -> CGImage? {
        guard let frame = window.contentView?.superview else { return nil }
        window.displayIfNeeded()
        let (image, holes) = withKnockoutsEmulated(in: frame) { () -> CGImage? in
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            return rep.cgImage
        }
        guard let image else { return nil }
        // Each knockout is a selected segment, and its label has to be there.
        let scale = CGFloat(image.width) / frame.bounds.width
        for hole in holes
        where inkedPixels(image, in: hole, viewHeight: frame.bounds.height, scale: scale) < 30 {
            stop("\(scene): a selected segment at \(hole) rendered without its label")
        }
        return image
    }

    /// Runs `body` with every `destOut` knockout in `view`'s layers emulated,
    /// and answers the knocked-out regions in `view`'s coordinates.
    ///
    /// Core Animation's software renderer, which is what draws a view into an
    /// image, cannot composite a `destOut` layer — Apple documents that it
    /// skips compositing filters. The toolbar's Practice/Play switch relies on
    /// one: the selected segment's label is drawn over a pill, and the pill is
    /// then knocked out of the unselected labels beneath with `destOut`.
    /// Drawn as an ordinary layer, the knockout paints over the selected label
    /// and the switch reads blank. So for the length of `body` each knockout is
    /// hidden together with what it would have removed — the earlier siblings
    /// that lie wholly inside it — and both are put back straight after.
    private static func withKnockoutsEmulated<T>(
        in view: NSView, _ body: () -> T
    ) -> (T, [CGRect]) {
        guard let root = view.layer else { return (body(), []) }
        var hidden: [CALayer] = []
        var holes: [CGRect] = []
        func visit(_ layer: CALayer) {
            let children = layer.sublayers ?? []
            for (index, child) in children.enumerated()
            where !child.isHidden && String(describing: child.compositingFilter ?? "") == "destOut" {
                let shapes = (child.sublayers ?? []).map { child.convert($0.frame, to: layer) }
                let regions = shapes.isEmpty ? [child.frame] : shapes
                hidden.append(child)
                for earlier in children[..<index]
                where !earlier.isHidden && regions.contains(where: { $0.contains(earlier.frame) }) {
                    hidden.append(earlier)
                }
                holes += regions.map { layer.convert($0, to: root) }
            }
            children.forEach(visit)
        }
        visit(root)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hidden.forEach { $0.isHidden = true }
        let result = body()
        hidden.forEach { $0.isHidden = false }
        CATransaction.commit()
        return (result, holes)
    }

    /// Pixels in `rect` — a region of a view `viewHeight` tall, drawn at
    /// `scale` — that differ clearly from the region's own corner.
    private static func inkedPixels(
        _ image: CGImage, in rect: CGRect, viewHeight: CGFloat, scale: CGFloat
    ) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        // Rows run top down in the buffer; the view's y runs bottom up.
        let left = max(0, Int((rect.minX * scale).rounded()) + 4)
        let right = min(width, Int((rect.maxX * scale).rounded()) - 4)
        let top = max(0, Int(((viewHeight - rect.maxY) * scale).rounded()) + 4)
        let bottom = min(height, Int(((viewHeight - rect.minY) * scale).rounded()) - 4)
        guard left < right, top < bottom else { return 0 }
        let corner = (top * width + left) * 4
        let ground = Array(pixels[corner..<corner + 3])
        var inked = 0
        for row in top..<bottom {
            for column in left..<right {
                let offset = (row * width + column) * 4
                let differs = (0..<3).contains { abs(Int(pixels[offset + $0]) - Int(ground[$0])) > 60 }
                if differs { inked += 1 }
            }
        }
        return inked
    }

    private static func write(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            stop("could not encode \(url.lastPathComponent)")
        }
        do { try data.write(to: url) } catch {
            stop("could not write \(url.path): \(error.localizedDescription)")
        }
    }

    private static func stop(_ message: String, code: Int32 = 1) -> Never {
        print("SCREENSHOTS FAIL: \(message)")
        exit(code)
    }
}

/// Types practice runs on a synthetic clock, the way a person would: slower on
/// the keys people are slow on, and now and then the wrong key — so the
/// history has something for the heat map and Statistics to show.
@MainActor
private final class Typist {
    private let practice: PracticeViewController
    private let surface: TypingView
    private var now = 0.0
    private var random = Spray(seed: 42)
    /// Keys this typist finds hard, which is what makes the heat map warm.
    private static let slow = Set("qzxpbvyj,.'")

    init(practice: PracticeViewController, surface: TypingView) {
        self.practice = practice
        self.surface = surface
        practice.clock = { [unowned self] in now }
    }

    /// Days back from today on which this typist practised: most days of the
    /// last five weeks, ending in a streak, so the calendar and the streak
    /// have something to show.
    static let practiceDays = [34, 33, 31, 28, 27, 24, 21, 20, 17, 14, 13, 10, 7, 6, 3, 2, 1, 0]

    func typeHistory() {
        let today = Date().timeIntervalSince1970 * 1000
        for daysAgo in Self.practiceDays {
            // This time of day, that many days ago: one run on each day.
            let when = today - Double(daysAgo) * 86_400_000
            practice.runClock = { when }
            practice.startFreshRun()
            type(practice.currentPassage, fraction: 1, forcedMistake: nil)
        }
        practice.runClock = { Date().timeIntervalSince1970 * 1000 }
    }

    /// A run under way: the first part of a passage typed, with a mistake in
    /// it, and the caret waiting.
    ///
    /// On a public-domain passage, never a fair-use one. The listing is public,
    /// App Review has asked about third-party text before, and which passage
    /// comes up is random — one run put a copyrighted quotation on the
    /// practice screenshot while the run before had put Dickens there.
    func typePartOfARun() throws(Diagnostics.CheckFailure) {
        practice.startFreshRun()
        for _ in 0..<200 where practice.currentLicense != "public domain" {
            practice.startFreshRun()
        }
        guard practice.currentLicense == "public domain" else {
            throw Diagnostics.CheckFailure(
                message: "two hundred passages in a row were not public domain")
        }
        type(practice.currentPassage, fraction: 0.4, forcedMistake: 9)
    }

    private func type(_ passage: String, fraction: Double, forcedMistake: Int?) {
        // Newlines are not typed; `TextInput` steps over them. See the
        // self-test's note on the Code channel.
        let units = Array(passage.utf16).filter { $0 != 0x0A }
        // On a letter: a space has no neighbour to be typed by mistake.
        let isLetter = { (unit: UInt16) in (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) }
        let forced = forcedMistake.flatMap { start in units.indices.first { $0 >= start && isLetter(units[$0]) } }
        for (index, unit) in units.prefix(Int(Double(units.count) * fraction)).enumerated() {
            let character = String(utf16CodeUnits: [unit], count: 1)
            let lower = Character(character.lowercased())
            now += 150 + (Self.slow.contains(lower) ? 240 : 0) + Double.random(in: 0..<90, using: &random)
            let wrong =
                forcedMistake == nil
                ? Double.random(in: 0..<1, using: &random) < 0.03 : index == forced
            surface.insertText(
                wrong ? Self.neighbour(of: character) : character, replacementRange: NSRange())
        }
    }

    /// The key beside this one on a QWERTY row, or the character itself if it
    /// is not a letter.
    private static func neighbour(of character: String) -> String {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map(Array.init)
        let lower = Character(character.lowercased())
        for row in rows {
            guard let index = row.firstIndex(of: lower) else { continue }
            let other = String(row[index + 1 < row.count ? index + 1 : index - 1])
            return character == character.lowercased() ? other : other.uppercased()
        }
        return character
    }
}
