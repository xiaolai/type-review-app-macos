import XCTest

@testable import TypeReviewKit

/// The rules of Play, driven by hand: time through `update(dt:)`, keys through
/// `type(_:)`, every random choice from a fixed seed.
final class FallingGameTests: XCTestCase {
    private let cell = PlaySize(width: 13, height: 27)
    private let field = PlaySize(width: 800, height: 360)

    private func game(
        _ mode: PlayMode, gentle: Bool = true, letters: [String] = ["e", "t", "a"], seed: UInt32 = 7
    ) -> FallingGame {
        let game = FallingGame(mode: mode, gentle: gentle, letters: letters, cell: cell, seed: seed)
        game.field = field
        return game
    }

    /// Steps the clock until `done` holds, and fails rather than spinning if
    /// it never does.
    @discardableResult
    private func advance(
        _ game: FallingGame, seconds limit: Double = 60, until done: (FallingGame, [PlayEvent]) -> Bool
    ) -> [PlayEvent] {
        var seen: [PlayEvent] = []
        var elapsed = 0.0
        while elapsed < limit {
            let events = game.update(dt: 0.05)
            seen += events
            elapsed += 0.05
            if done(game, events) { return seen }
        }
        XCTFail("condition not reached in \(limit) seconds of game time")
        return seen
    }

    private func typeTarget(_ game: FallingGame) -> [PlayEvent] {
        var events: [PlayEvent] = []
        guard let target = game.target else { return events }
        for character in target.chars[target.typed...] { events += game.type(character) }
        return events
    }

    func testSomethingArrivesInsideTheMarginsAndFallsAtThePace() throws {
        let game = game(.words)
        advance(game) { game, _ in !game.items.isEmpty }
        let item = try XCTUnwrap(game.items.first)
        XCTAssertGreaterThanOrEqual(item.x, game.margin)
        XCTAssertLessThanOrEqual(item.x + item.size.width, field.width - game.margin)
        XCTAssertEqual(item.size.width, cell.width * Double(item.chars.count))
        let before = item.y
        _ = game.update(dt: 1)
        let after = try XCTUnwrap(game.items.first { $0.id == item.id }).y
        XCTAssertEqual(after - before, field.height / PlayMode.words.fallSeconds, accuracy: 1e-9)
    }

    func testTypingAWordBurstsItAndScores() throws {
        let game = game(.words)
        advance(game) { game, _ in !game.items.isEmpty }
        let target = try XCTUnwrap(game.target)
        let events = typeTarget(game)
        XCTAssertTrue(
            events.contains(.burst(id: target.id, indices: Array(target.chars.indices), word: target.chars.joined())))
        XCTAssertTrue(events.contains { if case .cleared(target.id, _) = $0 { return true } else { return false } })
        XCTAssertFalse(game.items.contains { $0.id == target.id })
        XCTAssertEqual(game.streak, target.chars.count)
        XCTAssertGreaterThan(game.score, 0)
    }

    func testAWrongKeyBreaksTheStreakAndMarksTheTarget() throws {
        let game = game(.words)
        advance(game) { game, _ in !game.items.isEmpty }
        let target = try XCTUnwrap(game.target)
        _ = game.type(target.chars[0])
        XCTAssertEqual(game.streak, 1)
        // Nothing in the word lists contains a digit.
        XCTAssertEqual(game.type("7"), [.wrong])
        XCTAssertEqual(game.streak, 0)
        let marked = try XCTUnwrap(game.items.first { $0.id == target.id })
        XCTAssertEqual(marked.misses, 1)
        XCTAssertEqual(marked.wrongAt, game.clock)
        XCTAssertEqual(marked.typed, 1, "a wrong key must not move the target on")
    }

    func testAHalfTypedWordKeepsTheKeysEvenWhenAnotherIsLower() throws {
        let game = game(.words)
        advance(game) { game, _ in !game.items.isEmpty }
        let first = try XCTUnwrap(game.target)
        _ = game.type(first.chars[0])
        advance(game) { game, _ in game.items.count >= 2 }
        XCTAssertEqual(game.target?.id, first.id)
    }

    func testCaseDoesNotMatter() throws {
        let game = game(.words)
        advance(game) { game, _ in !game.items.isEmpty }
        let target = try XCTUnwrap(game.target)
        _ = game.type(target.chars[0].uppercased())
        XCTAssertEqual(game.items.first { $0.id == target.id }?.typed, 1)
    }

    func testLettersTakeTheLowestCopyOfTheKey() throws {
        let game = game(.letters, letters: ["f"])
        advance(game) { game, _ in game.items.count >= 2 }
        let lowest = try XCTUnwrap(game.items.max { $0.y < $1.y })
        let events = game.type("f")
        XCTAssertEqual(events.first, .burst(id: lowest.id, indices: [0], word: "f"))
        XCTAssertFalse(game.items.contains { $0.id == lowest.id })
        XCTAssertEqual(game.items.count, 1)
    }

    func testLettersDropOnlyTheLettersItWasGiven() {
        let game = game(.letters, letters: ["q", "z"])
        var seen = Set<String>()
        for _ in 0..<2400 {
            _ = game.update(dt: 0.05)
            seen.formUnion(game.items.map { $0.chars[0] })
            if let lowest = game.items.max(by: { $0.y < $1.y }), lowest.y > 100 {
                _ = game.type(lowest.chars[0])
            }
        }
        XCTAssertEqual(seen, ["q", "z"])
    }

    func testASentenceBurstsWordByWordAndThenHoldsBeforeTheNext() throws {
        let game = game(.sentences)
        advance(game) { game, _ in !game.items.isEmpty }
        let sentence = try XCTUnwrap(game.target)
        let text = sentence.chars.joined()
        let events = typeTarget(game)
        let bursts = events.compactMap { event -> String? in
            if case .burst(_, _, let word) = event { return word } else { return nil }
        }
        XCTAssertEqual(bursts, text.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) })
        XCTAssertEqual(events.last, .sentenceDone(text))
        XCTAssertTrue(game.items.isEmpty)
        // The hold: nothing new for 1.8 seconds, then the next sentence.
        _ = game.update(dt: 1.7)
        XCTAssertTrue(game.items.isEmpty)
        _ = game.update(dt: 0.2)
        XCTAssertEqual(game.items.count, 1)
    }

    func testGentleRulesLoseNothingAndWaitForTheKeys() throws {
        let game = game(.words, gentle: true)
        let events = advance(game) { _, events in events.contains { if case .landed = $0 { return true } else { return false } } }
        XCTAssertFalse(events.contains { if case .lost = $0 { return true } else { return false } })
        let landed = try XCTUnwrap(game.items.first { $0.landed })
        XCTAssertEqual(landed.y, field.height - cell.height)
        XCTAssertLessThan(game.pace, 1)
        // Nothing more falls while something waits on the floor.
        let count = game.items.count
        for _ in 0..<600 { _ = game.update(dt: 0.05) }
        XCTAssertEqual(game.items.count, count)
        XCTAssertEqual(game.lives, 3)
        XCTAssertFalse(game.isOver)
        // Typing everything that waits there lets the game go on.
        while game.target != nil { _ = typeTarget(game) }
        advance(game) { game, _ in game.items.contains { !$0.landed } }
    }

    func testArcadeRulesTakeALifePerLandingAndEnd() {
        let game = game(.words, gentle: false)
        let events = advance(game, seconds: 300) { game, _ in game.isOver }
        XCTAssertEqual(events.filter { if case .lost = $0 { return true } else { return false } }.count, 3)
        XCTAssertEqual(events.last, .over)
        XCTAssertEqual(game.lives, 0)
        XCTAssertEqual(game.update(dt: 1), [], "a finished game does not move")
        XCTAssertEqual(game.type("a"), [])
    }

    func testThePaceStaysInItsRange() {
        let fast = game(.letters, letters: ["e"])
        advance(fast, seconds: 300) { game, _ in
            for item in game.items where item.y > 0 { _ = game.type(item.chars[0]) }
            return game.pace >= FallingGame.paceRange.upperBound
        }
        XCTAssertLessThanOrEqual(fast.pace, FallingGame.paceRange.upperBound)

        let slow = game(.words, gentle: false, seed: 3)
        for _ in 0..<20_000 { _ = slow.update(dt: 0.05) }
        XCTAssertGreaterThanOrEqual(slow.pace, FallingGame.paceRange.lowerBound)
    }

    func testAKeyWithNothingFallingIsIgnored() {
        for mode in PlayMode.allCases {
            let game = game(mode)
            _ = game.update(dt: 0.1)
            XCTAssertTrue(game.items.isEmpty)
            XCTAssertEqual(game.type("e"), [], "\(mode) scored a key with nothing falling")
            XCTAssertEqual(game.streak, 0)
        }
    }

    /// Four letters landing in one step with three lives left take three
    /// lives, not four: lives stop at none, and so do the losses reported.
    func testLivesNeverGoBelowNone() {
        let game = game(.letters, gentle: false)
        advance(game) { game, _ in game.items.count >= 4 }
        let events = game.update(dt: 100)
        XCTAssertEqual(game.lives, 0)
        XCTAssertEqual(events.filter { if case .lost = $0 { return true } else { return false } }.count, 3)
        XCTAssertEqual(events.last, .over)
        XCTAssertTrue(game.isOver)
    }

    /// Where a new arrival starts does not depend on how time was cut up.
    func testOneLongStepPlacesAnArrivalAsManyShortOnesDo() throws {
        let long = game(.words, seed: 5)
        let short = game(.words, seed: 5)
        _ = long.update(dt: 1)
        for _ in 0..<20 { _ = short.update(dt: 0.05) }
        let a = try XCTUnwrap(long.items.first)
        let b = try XCTUnwrap(short.items.first)
        XCTAssertEqual(long.items.count, short.items.count)
        XCTAssertEqual(a.chars, b.chars)
        XCTAssertEqual(a.x, b.x)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
    }

    /// Plays `seconds` of game time cut into steps of `step`, the last one
    /// short, and answers every event in order.
    private func play(_ game: FallingGame, for seconds: Double, step: Double) -> [PlayEvent] {
        var events: [PlayEvent] = []
        var left = seconds
        while left > 1e-12 {
            let dt = min(step, left)
            events += game.update(dt: dt)
            left -= dt
        }
        return events
    }

    private func assertSameGame(
        _ a: FallingGame, _ b: FallingGame, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.items.count, b.items.count, "items", file: file, line: line)
        for (x, y) in zip(a.items, b.items) {
            XCTAssertEqual(x.id, y.id, file: file, line: line)
            XCTAssertEqual(x.chars, y.chars, file: file, line: line)
            XCTAssertEqual(x.x, y.x, file: file, line: line)
            XCTAssertEqual(x.y, y.y, accuracy: 1e-6, file: file, line: line)
            XCTAssertEqual(x.landed, y.landed, file: file, line: line)
        }
        XCTAssertEqual(a.lives, b.lives, "lives", file: file, line: line)
        XCTAssertEqual(a.pace, b.pace, accuracy: 1e-9, "pace", file: file, line: line)
        XCTAssertEqual(a.isOver, b.isOver, "over", file: file, line: line)
    }

    /// How time is cut into frames changes nothing: landings slow the pace at
    /// the moment they happen, and lives go at the moment they are lost,
    /// however long the step that contains them.
    func testTheGameDoesNotDependOnHowTimeIsCutUp() {
        for (mode, gentle) in [(PlayMode.letters, false), (.words, true), (.words, false)] {
            let fine = game(mode, gentle: gentle, seed: 11)
            let coarse = game(mode, gentle: gentle, seed: 11)
            let ragged = game(mode, gentle: gentle, seed: 11)
            let seen = play(fine, for: 30, step: 0.05)
            XCTAssertEqual(play(coarse, for: 30, step: 1.5), seen, "\(mode) gentle \(gentle)")
            XCTAssertEqual(play(ragged, for: 30, step: 0.37), seen, "\(mode) gentle \(gentle)")
            XCTAssertTrue(
                seen.contains { if case .landed = $0 { true } else if case .lost = $0 { true } else { false } },
                "\(mode) gentle \(gentle): nothing reached the floor, so this proved nothing")
            assertSameGame(fine, coarse)
            assertSameGame(fine, ragged)
        }
    }

    /// What falls due exactly as a step ends is on the field when it returns,
    /// whether that moment ends one step or two. The first arrival is due at
    /// 0.3 seconds.
    func testAnArrivalDueAsAStepEndsIsThereWhenItReturns() {
        let whole = game(.words, seed: 5)
        let split = game(.words, seed: 5)
        _ = whole.update(dt: 0.3)
        _ = split.update(dt: 0.2)
        _ = split.update(dt: 0.1)
        XCTAssertEqual(whole.items.count, 1)
        assertSameGame(whole, split)
    }

    /// A field made shorter under something falling lands it at once, not at
    /// the end of whatever step comes next — the landing slows the pace, and
    /// everything still falling feels that from the moment it happens.
    func testAFieldMadeShorterLandsWhatItPassedAtOnce() {
        for gentle in [true, false] {
            let whole = game(.words, gentle: gentle, seed: 5)
            let split = game(.words, gentle: gentle, seed: 5)
            for game in [whole, split] {
                advance(game) { game, _ in game.items.count == 2 }
                let lowest = game.items.max { $0.y < $1.y }!
                // The floor a point above the lowest item's bottom.
                game.field = PlaySize(
                    width: field.width, height: lowest.y + lowest.size.height - 1)
            }
            XCTAssertEqual(
                whole.update(dt: 1), split.update(dt: 0.5) + split.update(dt: 0.5),
                "gentle \(gentle)")
            assertSameGame(whole, split)
        }
    }

    /// A hold ending partway through a step lets the next arrival in at that
    /// moment, not at the end of the step.
    func testAHoldEndsWhenItEndsInsideALongStep() {
        let fine = game(.sentences, seed: 3)
        let coarse = game(.sentences, seed: 3)
        for game in [fine, coarse] {
            advance(game) { game, _ in !game.items.isEmpty }
            _ = typeTarget(game)
            XCTAssertTrue(game.items.isEmpty)
        }
        XCTAssertEqual(play(coarse, for: 3, step: 3), play(fine, for: 3, step: 0.05))
        XCTAssertFalse(fine.items.isEmpty, "nothing arrived after the hold, so this proved nothing")
        assertSameGame(fine, coarse)
    }

    /// Time spent held back is not banked: what arrives after a hold starts
    /// near the top, not as far down as the hold was long.
    func testAnArrivalAfterAHoldStartsAtTheTop() throws {
        let game = game(.sentences)
        advance(game) { game, _ in !game.items.isEmpty }
        _ = typeTarget(game)
        _ = game.update(dt: 1.7)
        XCTAssertTrue(game.items.isEmpty)
        _ = game.update(dt: 0.2)
        let arrival = try XCTUnwrap(game.items.first)
        let speed = field.height / PlayMode.sentences.fallSeconds * game.pace
        XCTAssertLessThanOrEqual(arrival.y, -cell.height + speed * 0.2 + 1e-9)
    }

    func testTheSameSeedPlaysTheSameGame() {
        func arrivals(_ seed: UInt32) -> [String] {
            let game = game(.words, gentle: false, seed: seed)
            var seen: [Int: String] = [:]
            for _ in 0..<4000 {
                _ = game.update(dt: 0.05)
                for item in game.items where seen[item.id] == nil {
                    seen[item.id] = "\(item.chars.joined())@\(item.x)"
                }
            }
            return seen.keys.sorted().map { seen[$0]! }
        }
        XCTAssertEqual(arrivals(11), arrivals(11))
        XCTAssertNotEqual(arrivals(11), arrivals(12))
    }

    /// What Letters mode drops: the plan's included letters, drawn from the
    /// profile's own alphabet. `Session` plans from the same function, so the
    /// session vectors cover what it returns.
    func testTheLessonPlanIncludesLettersFromTheProfilesAlphabet() {
        let profile = Profile()
        let plan = lessonPlan(for: profile)
        XCTAssertFalse(plan.included.isEmpty)
        XCTAssertTrue(Set(plan.included).isSubset(of: Set(buildAlphabet(profile.settings))))
    }
}
