import AppKit
import TypeReviewKit

extension Diagnostics {
    /// Play, driven through the real window by `--selftest`.
    ///
    /// Time is stepped by hand through `advance(by:)` and keys go through the
    /// input client, the path AppKit commits text by — so the check is
    /// deterministic, needs no screen, and makes no sound: the error tone is
    /// counted rather than played. What it proves is the wiring the Kit's
    /// tests cannot see: the switch, the toolbar and menus, a word falling,
    /// drawing, bursting and scoring, a composition, a wrong key being heard,
    /// the window's ground in both appearances, and — checked by the caller —
    /// the profile left alone.
    ///
    /// Nothing it changes is saved. Games are started with `remember: false`,
    /// and the tone is switched on for the screen rather than in Settings, so
    /// the user's Play mode, rules and Mistype Sound are as they were.
    static func checkPlay(
        play: PlayViewController, practice: PracticeViewController,
        screens: MainScreenController, show: (MainScreen) -> Void
    ) -> Result<String, CheckFailure> {
        guard let window = screens.view.window else {
            return .failure(CheckFailure(message: "the screens are in no window"))
        }
        // Everything the checks below change on screen, put back on every way
        // out — one place, so a check that fails halfway cannot leave its part
        // behind.
        let (mode, gentle) = (play.mode, play.gentle)
        defer {
            window.appearance = nil
            (screens.view as? GroundedView)?.ground()
            play.applyTypingPreferences()
            play.newGame(mode: mode, gentle: gentle, remember: false)
        }
        do {
            try checkSwitch(to: play, from: practice, in: window, show: show)
            let cleared = try checkWordFallsAndBursts(play)
            try checkMistypeTone(play)
            try checkComposition(play)
            try checkGround(screens: screens, window: window)
            try checkSwitchBack(to: practice, from: play, in: window, show: show)
            return .success(cleared)
        } catch {
            return .failure(error)
        }
    }

    /// Both screens' toolbars, item by item: each screen's own two, the
    /// switch between flexible spaces, and the three windows.
    private static let practiceToolbar = toolbar(leading: ["source", "newText"])
    private static let playToolbar = toolbar(leading: ["game", "newGame"])

    private static func toolbar(leading: [String]) -> [String] {
        let space = NSToolbarItem.Identifier.flexibleSpace.rawValue
        return leading + [space, "screen", space, "keyboard", "library", "stats"]
    }

    private static func toolbarItems(_ window: NSWindow) -> [String] {
        window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
    }

    /// Whether every View ▸ Source item is enabled, as the menu bar would
    /// decide it now; nil if there are none to ask.
    private static func sourceMenuEnabled() -> Bool? {
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let picks = NSApp.mainMenu.map(items)?.filter {
            $0.action == #selector(AppDelegate.chooseSource(_:))
        } ?? []
        guard !picks.isEmpty else { return nil }
        for menu in Set(picks.compactMap(\.menu)) { menu.update() }
        return picks.allSatisfy(\.isEnabled)
    }

    /// The switch, and everything that follows the screen.
    private static func checkSwitch(
        to play: PlayViewController, from practice: PracticeViewController, in window: NSWindow,
        show: (MainScreen) -> Void
    ) throws(CheckFailure) {
        // Showing Practice must not have loaded Play. Play plans its first
        // game when it loads, and loaded before Practice had read the profile
        // it planned Letters for a typist with no history.
        guard !play.isViewLoaded else {
            throw CheckFailure(message: "showing Practice loaded Play as well")
        }
        show(.play)
        window.contentView?.layoutSubtreeIfNeeded()
        guard play.view.window === window, practice.view.window == nil else {
            throw CheckFailure(
                message: "switching to Play did not put Play in the window in place of Practice")
        }
        guard let lesson = practice.nextLessonPlan, play.plan == lesson else {
            throw CheckFailure(message: "Play's first game was not planned from Practice's profile")
        }
        let onPlay = toolbarItems(window)
        guard onPlay == playToolbar else {
            throw CheckFailure(message: "on Play the toolbar shows \(onPlay)")
        }
        guard sourceMenuEnabled() == false else {
            throw CheckFailure(message: "View ▸ Source is not greyed out on Play")
        }
        for mode in PlayMode.allCases
        where NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil) == nil {
            throw CheckFailure(message: "the status-bar symbol for \(mode.rawValue) does not exist")
        }
    }

    /// A word falls, is drawn as passage text, and bursts and scores when
    /// typed. Answers what it cleared, for the summary.
    private static func checkWordFallsAndBursts(_ play: PlayViewController) throws(CheckFailure)
        -> String
    {
        play.newGame(mode: .words, gentle: true, remember: false)
        play.typeThroughInput("x")
        guard play.state == .playing else {
            throw CheckFailure(message: "the first key did not start the game")
        }
        var steps = 0
        while (play.game.target?.y ?? -1) <= 0, steps < 400 {
            play.advance(by: 0.05)
            steps += 1
        }
        guard let target = play.game.target, target.y > 0 else {
            throw CheckFailure(message: "nothing fell in twenty seconds of game time")
        }
        let word = target.chars.joined()
        guard play.image(forItem: target.id) != nil else {
            throw CheckFailure(message: "the falling word \"\(word)\" is showing no image")
        }
        // Its letters, drawn without the caret. The block caret alone is
        // enough ink to pass a count, which is how a word that drew no letters
        // at all passed this check when it counted the image on screen.
        guard let letters = play.imageWithoutCaret(of: target) else {
            throw CheckFailure(message: "the falling word \"\(word)\" could not be drawn")
        }
        let ink = inkedPixels(letters)
        guard ink > 40 else {
            throw CheckFailure(message: "the falling word \"\(word)\" drew \(ink) pixels of letters")
        }

        for character in target.chars { play.typeThroughInput(character) }
        guard !play.game.items.contains(where: { $0.id == target.id }) else {
            throw CheckFailure(message: "typing \"\(word)\" did not clear it")
        }
        guard play.game.streak == target.chars.count, play.game.score > 0 else {
            throw CheckFailure(
                message: "typing \"\(word)\" scored \(play.game.score) with \(play.game.streak) in a row")
        }
        guard play.effectsInFlight > 0 else {
            throw CheckFailure(message: "clearing \"\(word)\" burst nothing")
        }
        return "\"\(word)\" cleared for \(play.game.score) pts"
    }

    /// Steps the game until something is falling to be typed at.
    private static func awaitTarget(_ play: PlayViewController) throws(CheckFailure) {
        var steps = 0
        while play.game.target == nil, steps < 400 {
            play.advance(by: 0.05)
            steps += 1
        }
        guard play.game.target != nil else {
            throw CheckFailure(message: "nothing new fell in twenty seconds of game time")
        }
    }

    /// A wrong key is heard exactly once, and breaks the streak. Counted, not
    /// played — a check makes no sound on somebody else's Mac — and with the
    /// tone switched on for the screen, so the wiring is checked whatever
    /// Mistype Sound is set to.
    private static func checkMistypeTone(_ play: PlayViewController) throws(CheckFailure) {
        try awaitTarget(play)
        let (tone, sounds) = (play.onMistype, play.soundsMistypes)
        defer { (play.onMistype, play.soundsMistypes) = (tone, sounds) }
        var tones = 0
        play.onMistype = { tones += 1 }
        play.soundsMistypes = true
        play.typeThroughInput("7")
        guard play.game.streak == 0 else {
            throw CheckFailure(message: "a wrong key left \(play.game.streak) in a row")
        }
        guard tones == 1 else {
            throw CheckFailure(message: "a wrong key on Play asked for the error tone \(tones) times")
        }
    }

    /// A composition is drawn at the caret, puts an input method's candidate
    /// window over one character rather than the whole field, and does not
    /// outlive its game.
    private static func checkComposition(_ play: PlayViewController) throws(CheckFailure) {
        try awaitTarget(play)
        play.markThroughInput("´")
        guard play.hasComposition, play.showsComposition else {
            throw CheckFailure(message: "a composition on Play was not drawn")
        }
        let candidates = play.candidateRect()
        guard candidates.width > 0, candidates.width * 10 < play.view.bounds.width else {
            throw CheckFailure(
                message: "a candidate window would be placed over \(Int(candidates.width)) points")
        }
        play.newGame(remember: false)
        guard !play.hasComposition, !play.showsComposition else {
            throw CheckFailure(message: "a new game kept the old game's composition")
        }
    }

    /// The ground, resolved, in both appearances. A dynamic colour here draws
    /// the wallpaper tint — see `GroundedView`.
    private static func checkGround(screens: MainScreenController, window: NSWindow)
        throws(CheckFailure)
    {
        guard let grounded = screens.view as? GroundedView else {
            throw CheckFailure(message: "the main window's root is not a GroundedView")
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
                throw CheckFailure(message: "in \(name.rawValue) the window's ground is not the passage's")
            }
        }
    }

    /// Back to Practice: its toolbar and Source return, and the game waits.
    private static func checkSwitchBack(
        to practice: PracticeViewController, from play: PlayViewController, in window: NSWindow,
        show: (MainScreen) -> Void
    ) throws(CheckFailure) {
        // A game in play, so there is something for leaving to pause.
        if play.state != .playing { play.typeThroughInput("x") }
        guard play.state == .playing else {
            throw CheckFailure(message: "a key did not start the game again")
        }
        show(.practice)
        let onPractice = toolbarItems(window)
        guard practice.view.window === window, play.view.window == nil,
            onPractice == practiceToolbar
        else {
            throw CheckFailure(message: "switching back left the toolbar showing \(onPractice)")
        }
        guard sourceMenuEnabled() == true else {
            throw CheckFailure(message: "View ▸ Source is not enabled again on Practice")
        }
        guard play.state == .paused else {
            throw CheckFailure(message: "leaving Play did not pause the game")
        }
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
