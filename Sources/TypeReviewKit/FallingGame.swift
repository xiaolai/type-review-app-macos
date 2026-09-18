import Foundation

/// What falls in Play.
public enum PlayMode: String, CaseIterable, Sendable {
    case letters, words, sentences

    /// Seconds to fall the height of the field at pace 1. Slow on purpose:
    /// the people this is for are learning where the keys are.
    public var fallSeconds: Double {
        switch self {
        case .letters: return 8.5
        case .words: return 12
        case .sentences: return 30
        }
    }
}

/// A rectangle's size, in the app's points. Its own type so the rules need
/// nothing from a UI framework.
public struct PlaySize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// One thing falling: a letter, a word or a sentence.
public struct FallingItem: Equatable, Sendable {
    public let id: Int
    /// One UTF-16 unit each; every text Play drops is ASCII.
    public let chars: [String]
    public let size: PlaySize
    public internal(set) var x: Double
    /// Top edge, measured down from the top of the field.
    public internal(set) var y: Double
    /// Characters typed so far — the next one expected is `chars[typed]`.
    public internal(set) var typed = 0
    /// Characters already burst away: the finished words of a sentence.
    public internal(set) var gone: Set<Int> = []
    /// On the floor under gentle rules, waiting to be typed.
    public internal(set) var landed = false
    public internal(set) var misses = 0
    /// Points its keystrokes earned, for the figure shown when it clears.
    public internal(set) var gained = 0
    /// The game clock when a key was last missed on it, for the red flash.
    public internal(set) var wrongAt = -Double.infinity
}

/// What a step of the rules produced, for the screen to show and sound.
public enum PlayEvent: Equatable, Sendable {
    /// A key matched nothing that was asked for.
    case wrong
    /// These characters of an item were finished and fly apart.
    case burst(id: Int, indices: [Int], word: String)
    /// An item is done and gone, worth this many points in all.
    case cleared(id: Int, points: Int)
    case sentenceDone(String)
    case landed(id: Int)
    /// Reached the floor under arcade rules: a life is gone with it.
    case lost(id: Int)
    case over
}

/// The rules of Play: what falls, how fast, what a key does to it.
///
/// No AppKit and no clock of its own. Time arrives through `update(dt:)` and
/// keys through `type(_:)`, and every random choice draws from a seeded
/// `Mulberry32`, so a test can replay a game exactly — which is the whole
/// reason it lives in the Kit rather than beside the view that draws it.
///
/// It never touches a profile. A falling game's keystroke timings include
/// finding the target and waiting for it, and fed to the planner they would
/// read as slow keys; the profile format is also pinned to the website's. So
/// Play reads the lesson plan and writes nothing back.
public final class FallingGame {
    public let mode: PlayMode
    /// Gentle rules lose nothing: an item that reaches the floor waits there,
    /// and nothing new falls until it is typed. Arcade rules take a life.
    public let gentle: Bool
    /// One character's box at this mode's type size. The typing font is
    /// monospaced, so a text's width is its length times this.
    public let cell: PlaySize
    public var field = PlaySize(width: 800, height: 360)
    /// Kept clear either side, as the passage's margin is.
    public var margin: Double = 32

    public private(set) var items: [FallingItem] = []
    public private(set) var score = 0
    public private(set) var streak = 0
    public private(set) var lives = 3
    /// How fast things fall and arrive, relative to `fallSeconds`. It follows
    /// the player: up after clean, early clears, down after landings.
    public private(set) var pace = 1.0
    public private(set) var isOver = false
    public private(set) var clock = 0.0

    public static let paceRange = 0.5...2.6

    private let letters: [String]
    private var rng: Mulberry32
    private var misses: [String: Double] = [:]
    private var spawnIn = 0.3
    private var holdFor = 0.0
    private var nextID = 0
    private var bag: [String] = []

    /// `letters` is what Letters mode drops — the lesson plan's included
    /// letters, so the game drills what practice has unlocked. Each must be one
    /// character, as the plan's are: a falling letter is one key.
    public init(mode: PlayMode, gentle: Bool, letters: [String], cell: PlaySize, seed: UInt32) {
        precondition(mode != .letters || !letters.isEmpty, "Letters mode needs a letter to drop")
        precondition(
            letters.allSatisfy { $0.utf16.count == 1 }, "each letter Play drops must be one character")
        self.mode = mode
        self.gentle = gentle
        self.letters = letters
        self.cell = cell
        rng = Mulberry32(seed: seed)
    }

    /// Points per correct key: up by half every ten in a row, to four times.
    public var multiplier: Double { min(4, 1 + Double(streak / 10) * 0.5) }

    /// The item keys go to: a half-typed one if there is one, else the lowest.
    /// Letters mode takes any falling copy of the key instead — see `type`.
    private var targetIndex: Int? {
        if mode != .letters, let locked = items.firstIndex(where: { $0.typed > 0 }) { return locked }
        return items.indices.max { items[$0].y < items[$1].y }
    }

    public var target: FallingItem? { targetIndex.map { items[$0] } }

    /// The character the target wants next, as it is written.
    public var expected: String? {
        guard let target else { return nil }
        return target.chars[mode == .letters ? 0 : target.typed]
    }

    // MARK: - Time

    /// Moves the game on by `dt` seconds.
    ///
    /// In steps that end at every moment something changes — an arrival falling
    /// due, a hold ending, something reaching the floor — so how time is cut
    /// into frames never changes what happens. A landing slows the pace and a
    /// hold ending lets the next arrival in; one long step that ran past either
    /// applied the old pace, or the old hold, to all of it.
    public func update(dt: Double) -> [PlayEvent] {
        guard !isOver, dt > 0 else { return [] }
        var events: [PlayEvent] = []
        var left = dt
        while left > 0, !isOver {
            arrive()
            let step = min(left, untilNextChange())
            events += advance(by: step)
            left -= step
        }
        // The last boundary too. Left to the next call, what fell due exactly
        // now was missing from this one's result — or present, when the same
        // time cut in two left a rounding remainder that took one more lap.
        if !isOver { arrive() }
        return events
    }

    private var fallSpeed: Double { field.height / mode.fallSeconds * pace }

    /// How many may be falling at once.
    private var mostFalling: Int {
        switch mode {
        case .letters: return min(6, 2 + Int(pace * 2))
        case .words: return min(4, 1 + Int(pace * 1.5))
        case .sentences: return 1
        }
    }

    private var arrivalInterval: Double {
        (mode == .letters ? 1.5 : mode == .words ? 3.4 : 0.9) / pace.squareRoot()
    }

    /// Lets in whatever is due, at the top, unless something holds it back.
    ///
    /// Only ever at a step's boundary, which is the only moment an arrival can
    /// fall due or stop being held — so it arrives exactly then, and starts at
    /// the top. It used to be let in at a step's end and started as far down
    /// as the time since it was due; that also counted time it had spent held
    /// back, and so as far down as the step was long. While held, the clock
    /// does not bank time.
    private func arrive() {
        // Nothing on the field: the next arrival is a moment away at most.
        if items.isEmpty { spawnIn = min(spawnIn, 0.35) }
        guard spawnIn <= 0, holdFor <= 0, items.count < mostFalling,
            !(gentle && items.contains { $0.landed })
        else { return }
        spawn()
        spawnIn = arrivalInterval
    }

    /// The floor for an item: where its bottom meets the field's.
    private func floorLine(for item: FallingItem) -> Double {
        max(0, field.height - item.size.height)
    }

    /// Seconds until the next arrival falls due, a hold ends, or something
    /// falling reaches the floor — whichever is first — or infinity when none
    /// of them is coming. Zero when something is already at the floor or past
    /// it, which a field made shorter underneath it leaves: that landing is
    /// now, not at the end of whatever step comes next.
    private func untilNextChange() -> Double {
        var soonest = Double.infinity
        if spawnIn > 0 { soonest = spawnIn }
        if holdFor > 0 { soonest = min(soonest, holdFor) }
        let speed = fallSpeed
        guard speed > 0 else { return soonest }
        for item in items where !item.landed {
            let toFloor = (floorLine(for: item) - item.y) / speed
            guard toFloor > 0 else { return 0 }
            soonest = min(soonest, toFloor)
        }
        return soonest
    }

    /// One step in which nothing changes until its end: `update` never asks
    /// for more time than that.
    private func advance(by dt: Double) -> [PlayEvent] {
        clock += dt
        holdFor = max(0, holdFor - dt)
        spawnIn = max(0, spawnIn - dt)
        let speed = fallSpeed

        var events: [PlayEvent] = []
        var lost: [Int] = []
        for index in items.indices where !items[index].landed {
            items[index].y += speed * dt
            let floor = floorLine(for: items[index])
            // Within a billionth of a point: a step ends exactly when an item
            // arrives, and the arithmetic can leave it that far short.
            guard items[index].y >= floor - 1e-9 else { continue }
            if gentle {
                items[index].y = floor
                items[index].landed = true
                pace = max(Self.paceRange.lowerBound, pace * 0.9)
                events.append(.landed(id: items[index].id))
            } else {
                lost.append(items[index].id)
            }
        }
        // A life per landing, never below none: a field made shorter under
        // things already falling can land more at once than there are lives
        // left. What lands after the last life is simply gone.
        for id in lost where lives > 0 {
            lives -= 1
            streak = 0
            pace = max(Self.paceRange.lowerBound, pace * 0.88)
            events.append(.lost(id: id))
        }
        items.removeAll { lost.contains($0.id) }
        if lives == 0 {
            isOver = true
            events.append(.over)
        }
        return events
    }

    private func spawn() {
        let text: String
        switch mode {
        case .letters: text = pickLetter()
        case .words: text = draw(from: PlayText.words)
        case .sentences: text = draw(from: PlayText.sentences)
        }
        let chars = text.utf16.map { String(utf16CodeUnits: [$0], count: 1) }
        let size = PlaySize(width: cell.width * Double(chars.count), height: cell.height)
        var x = ((field.width - size.width) / 2).rounded()
        if mode != .sentences {
            // The widest gap from anything still near the top, of a few tries,
            // so two words do not arrive on top of each other.
            let low = margin
            let high = max(margin, field.width - margin - size.width)
            var best = -Double.infinity
            for _ in 0..<14 {
                let candidate = (low + rng.next() * (high - low)).rounded()
                let clearance = items.filter { $0.y < size.height * 4 }
                    .map { max($0.x - (candidate + size.width), candidate - ($0.x + $0.size.width)) }
                    .min() ?? .infinity
                if clearance > best {
                    best = clearance
                    x = candidate
                }
            }
        }
        items.append(
            FallingItem(id: nextID, chars: chars, size: size, x: x, y: -size.height))
        nextID += 1
    }

    /// Missed letters fall more often; one already falling, less.
    private func pickLetter() -> String {
        let showing = Set(items.map { $0.chars[0] })
        let weights = letters.map { letter -> Double in
            let weight = 1 + (misses[letter] ?? 0) * 0.6
            return showing.contains(letter) ? weight * 0.2 : weight
        }
        var roll = rng.next() * weights.reduce(0, +)
        for (letter, weight) in zip(letters, weights) {
            roll -= weight
            if roll < 0 { return letter }
        }
        return letters[letters.count - 1]
    }

    /// Every text once before any repeats, in a seeded order.
    private func draw(from source: [String]) -> String {
        if bag.isEmpty {
            bag = source
            for index in stride(from: bag.count - 1, to: 0, by: -1) {
                bag.swapAt(index, Int(rng.next() * Double(index + 1)))
            }
        }
        return bag.removeLast()
    }

    // MARK: - Keys

    /// One committed character.
    ///
    /// Compared without case, unlike practice. The texts are lower case and a
    /// child with Caps Lock on would otherwise miss every key with no idea
    /// why; which letter it is matters here, not which case.
    public func type(_ character: String) -> [PlayEvent] {
        // Nothing falling is nothing to miss, in every mode.
        guard !isOver, !items.isEmpty else { return [] }
        let key = character.lowercased()
        return mode == .letters ? typeLetter(key) : typeText(key)
    }

    /// Any falling copy of the letter counts; the lowest goes first.
    private func typeLetter(_ key: String) -> [PlayEvent] {
        guard
            let index = items.indices.filter({ items[$0].chars[0].lowercased() == key })
                .max(by: { items[$0].y < items[$1].y })
        else { return miss() }
        hit(items[index].chars[0], at: index)
        let item = items.remove(at: index)
        return [.burst(id: item.id, indices: [0], word: item.chars[0])] + clear(item)
    }

    /// The next character of the target: a word bursts as it is finished, and
    /// a whole item clears when its last character is typed.
    private func typeText(_ key: String) -> [PlayEvent] {
        guard let index = targetIndex else { return [] }
        let position = items[index].typed
        let chars = items[index].chars
        guard key == chars[position].lowercased() else { return miss() }
        hit(chars[position], at: index)
        items[index].typed += 1

        var events: [PlayEvent] = []
        let endsWord =
            chars[position] != " " && (position == chars.count - 1 || chars[position + 1] == " ")
        if endsWord {
            var start = position
            while start > 0, chars[start - 1] != " " { start -= 1 }
            let indices = Array(start...position)
            items[index].gone.formUnion(indices)
            let word = chars[start...position].joined().trimmingCharacters(in: .punctuationCharacters)
            events.append(.burst(id: items[index].id, indices: indices, word: word))
        }
        if items[index].typed == chars.count {
            let item = items.remove(at: index)
            events += clear(item)
            if mode == .sentences {
                events.append(.sentenceDone(chars.joined()))
                // A moment for the sentence to be heard before the next one.
                holdFor = 1.8
                if item.misses <= 1 { pace = min(Self.paceRange.upperBound, pace * 1.06) }
            }
        }
        return events
    }

    private func hit(_ character: String, at index: Int) {
        streak += 1
        let gain = Int((10 * multiplier).rounded())
        score += gain
        items[index].gained += gain
        if let count = misses[character] { misses[character] = max(0, count - 0.5) }
    }

    private func miss() -> [PlayEvent] {
        streak = 0
        if let expected { misses[expected, default: 0] += 1 }
        if let index = targetIndex {
            items[index].misses += 1
            items[index].wrongAt = clock
        }
        return [.wrong]
    }

    private func clear(_ item: FallingItem) -> [PlayEvent] {
        let depth = max(0, min(1, item.y / max(1, field.height)))
        let count = item.chars.filter { $0 != " " }.count
        let bonus = Int(((1 - depth) * 8 * Double(count) * multiplier).rounded())
        score += bonus
        if item.misses == 0, depth < 0.55, !item.landed {
            pace = min(Self.paceRange.upperBound, pace * 1.05)
        } else if depth > 0.8 || item.landed {
            pace = max(Self.paceRange.lowerBound, pace * 0.97)
        }
        return [.cleared(id: item.id, points: item.gained + bonus)]
    }
}

/// The words and sentences Play drops.
///
/// Lower-case English in plain ASCII, short enough for a child learning the
/// keyboard. Held to the same rules as the practice corpus — English, and
/// nothing cleaning would change — by `PlayTextTests`.
public enum PlayText {
    public static let words = [
        "cat", "dog", "sun", "fish", "jump", "frog", "cake", "star", "moon", "tree", "ball",
        "duck", "bird", "kite", "milk", "rain", "snow", "play", "blue", "green", "happy",
        "smile", "apple", "zebra", "pizza", "robot", "rocket", "tiger", "panda", "cloud",
        "train", "house", "water", "lemon", "music", "dance", "bread", "plant", "ocean", "candy",
    ]

    public static let sentences = [
        "the cat naps on the mat.", "i can jump so high.", "the sun is hot today.",
        "we like to play ball.", "my dog can run fast.", "a fish swims in the pond.",
        "look at the big moon.", "the frog is green.", "i see a red kite.",
        "we eat cake and milk.", "the bird sings a song.", "snow is cold and white.",
    ]
}
