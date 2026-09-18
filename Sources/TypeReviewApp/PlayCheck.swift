import AppKit
import TypeReviewKit

extension Diagnostics {
    /// Play, driven through the real window by `--selftest`.
    ///
    /// Time is stepped by hand through `advance(by:)` and keys go through the
    /// input client, the path AppKit commits text by — so the check is
    /// deterministic, needs no screen, and makes no sound: the error tone is
    /// counted rather than played. What it proves is the wiring the Kit's
    /// tests cannot see: the switch, the toolbar, a word falling, drawing,
    /// bursting and scoring, a wrong key being heard, the window's ground in
    /// both appearances, and — checked by the caller — the profile left alone.
    static func checkPlay(
        play: PlayViewController, practice: PracticeViewController,
        screens: MainScreenController, show: (MainScreen) -> Void
    ) -> Result<String, CheckFailure> {
        func fail(_ message: String) -> Result<String, CheckFailure> {
            .failure(CheckFailure(message: message))
        }
        func toolbarItems(_ window: NSWindow) -> Set<String> {
            Set(window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])
        }
        guard let window = screens.view.window else { return fail("the screens are in no window") }

        // The switch, and everything that follows the screen.
        show(.play)
        window.contentView?.layoutSubtreeIfNeeded()
        guard play.view.window === window, practice.view.window == nil else {
            return fail("switching to Play did not put Play in the window in place of Practice")
        }
        let onPlay = toolbarItems(window)
        guard onPlay.isSuperset(of: ["screen", "game", "newGame", "keyboard", "library", "stats"]),
            !onPlay.contains("source"), !onPlay.contains("newText")
        else { return fail("on Play the toolbar shows \(onPlay.sorted())") }
        for mode in PlayMode.allCases
        where NSImage(
            systemSymbolName: PlayViewController.symbol(for: mode), accessibilityDescription: nil) == nil
        {
            return fail("the status-bar symbol for \(mode.rawValue) does not exist")
        }

        // A word falls, and is drawn as passage text.
        play.newGame(mode: .words, gentle: true)
        play.typeThroughInput("x")
        guard play.state == .playing else { return fail("the first key did not start the game") }
        var steps = 0
        while (play.game.target?.y ?? -1) <= 0, steps < 400 {
            play.advance(by: 0.05)
            steps += 1
        }
        guard let target = play.game.target, target.y > 0 else {
            return fail("nothing fell in twenty seconds of game time")
        }
        let word = target.chars.joined()
        guard play.image(forItem: target.id) != nil else {
            return fail("the falling word \"\(word)\" is showing no image")
        }
        // Its letters, drawn without the caret. The block caret alone is
        // enough ink to pass a count, which is how a word that drew no letters
        // at all passed this check when it counted the image on screen.
        guard let letters = play.imageWithoutCaret(of: target) else {
            return fail("the falling word \"\(word)\" could not be drawn")
        }
        let ink = inkedPixels(letters)
        guard ink > 40 else { return fail("the falling word \"\(word)\" drew \(ink) pixels of letters") }

        // Typed, it bursts and scores.
        for character in target.chars { play.typeThroughInput(character) }
        guard !play.game.items.contains(where: { $0.id == target.id }) else {
            return fail("typing \"\(word)\" did not clear it")
        }
        guard play.game.streak == target.chars.count, play.game.score > 0 else {
            return fail(
                "typing \"\(word)\" scored \(play.game.score) with \(play.game.streak) in a row")
        }
        guard play.effectsInFlight > 0 else { return fail("clearing \"\(word)\" burst nothing") }
        let score = play.game.score

        // A wrong key is heard, once, and breaks the streak. Counted, not
        // played: a check makes no sound on somebody else's Mac.
        steps = 0
        while play.game.target == nil, steps < 400 {
            play.advance(by: 0.05)
            steps += 1
        }
        let tone = play.onMistype
        var tones = 0
        play.onMistype = { tones += 1 }
        play.typeThroughInput("7")
        play.onMistype = tone
        guard play.game.streak == 0 else { return fail("a wrong key left \(play.game.streak) in a row") }
        guard tones == 1 || !AppPreferences.mistypeSound.value else {
            return fail("a wrong key on Play asked for the error tone \(tones) times")
        }

        // The ground, resolved, in both appearances. A dynamic colour here
        // draws the wallpaper tint — see `GroundedView`.
        guard let grounded = screens.view as? GroundedView else {
            return fail("the main window's root is not a GroundedView")
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            grounded.ground()
            var wanted = NSColor.clear
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                wanted = NSColor(cgColor: Theme.background.cgColor) ?? .clear
            }
            guard window.backgroundColor.type == .componentBased,
                let actual = window.backgroundColor.usingColorSpace(.sRGB),
                let expected = wanted.usingColorSpace(.sRGB),
                abs(actual.redComponent - expected.redComponent) < 0.002,
                abs(actual.greenComponent - expected.greenComponent) < 0.002,
                abs(actual.blueComponent - expected.blueComponent) < 0.002
            else {
                window.appearance = nil
                return fail("in \(name.rawValue) the window's ground is not the passage's")
            }
        }
        window.appearance = nil
        grounded.ground()

        // Back to Practice: the toolbar returns and the game waits.
        show(.practice)
        let onPractice = toolbarItems(window)
        guard practice.view.window === window, play.view.window == nil,
            onPractice.contains("source"), !onPractice.contains("game")
        else { return fail("switching back left the toolbar showing \(onPractice.sorted())") }
        guard play.state == .paused else { return fail("leaving Play did not pause the game") }
        return .success("\"\(word)\" cleared for \(score) pts")
    }

    /// Pixels that differ from the image's corner, which is its ground.
    private static func inkedPixels(_ image: CGImage) -> Int {
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
        let ground = Array(pixels[0..<4])
        var inked = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let differs = (0..<4).contains { abs(Int(pixels[offset + $0]) - Int(ground[$0])) > 24 }
            if differs { inked += 1 }
        }
        return inked
    }
}
