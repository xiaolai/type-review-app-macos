import XCTest

@testable import TypeReviewKit

final class MistypeTests: XCTestCase {
    func testTheIndexJustWrittenCarriesTheVerdict() {
        XCTAssertTrue(mistypeJustHappened(statuses: [.incorrect, .untyped], at: 0))
        XCTAssertFalse(mistypeJustHappened(statuses: [.correct, .untyped], at: 0))
        XCTAssertFalse(mistypeJustHappened(statuses: [.untyped, .untyped], at: 0))
    }

    /// The whole reason the rule takes the *old* cursor, driven through real
    /// `TextInput`s rather than through two hand-written arrays.
    ///
    /// The earlier version of this asserted the same literal twice under two
    /// names and instantiated neither mode, so it would have passed unchanged
    /// if either one started writing the verdict somewhere else — which is the
    /// only thing it was there to catch.
    func testBothModesWriteTheVerdictAtTheOldCursor() throws {
        for stopOnError in [false, true] {
            let input = try TextInput(expected: "ab", stopOnError: stopOnError)
            let before = input.snapshot().pos
            input.appendChar("z", timeStamp: 0)
            let after = input.snapshot()
            XCTAssertTrue(
                mistypeJustHappened(statuses: after.statuses, at: before),
                "stopOnError=\(stopOnError) did not mark the old cursor")
            // And the modes really do differ, so the test above is not passing
            // because both happen to behave identically.
            XCTAssertEqual(after.pos, stopOnError ? before : before + 1)
        }
    }

    /// A correct keystroke is silent in both modes, for the same reason.
    func testACorrectKeystrokeIsSilentInBothModes() throws {
        for stopOnError in [false, true] {
            let input = try TextInput(expected: "ab", stopOnError: stopOnError)
            let before = input.snapshot().pos
            input.appendChar("a", timeStamp: 0)
            XCTAssertFalse(
                mistypeJustHappened(statuses: input.snapshot().statuses, at: before),
                "stopOnError=\(stopOnError) sounded a correct key")
        }
    }

    /// A position that once held a mistake and was put right is silent. The
    /// sound belongs to the mistake, not to the position.
    func testCorrectingAMistakeIsSilent() {
        XCTAssertFalse(mistypeJustHappened(statuses: [.correct, .correct], at: 1))
    }

    /// A stale cursor answers false rather than trapping.
    func testOutOfRangeIsSilentRatherThanFatal() {
        XCTAssertFalse(mistypeJustHappened(statuses: [.incorrect], at: 1))
        XCTAssertFalse(mistypeJustHappened(statuses: [.incorrect], at: -1))
        XCTAssertFalse(mistypeJustHappened(statuses: [], at: 0))
    }

    func testTheFirstSoundOfARunAlwaysPlays() {
        XCTAssertTrue(mistypeMaySound(lastSoundedMs: nil, nowMs: 0))
    }

    /// The case the gate exists for: a key held down, repeating at the system
    /// rate. A commit is handled by the commit boundary, not by this.
    func testAHeldKeyDoesNotMachineGun() {
        XCTAssertTrue(mistypeMaySound(lastSoundedMs: nil, nowMs: 1000))
        XCTAssertFalse(mistypeMaySound(lastSoundedMs: 1000, nowMs: 1000))
        XCTAssertFalse(mistypeMaySound(lastSoundedMs: 1000, nowMs: 1000 + 59))
    }

    /// And the case it must not swallow: two deliberate wrong keys.
    func testTwoDeliberateMistakesBothSound() {
        XCTAssertTrue(mistypeMaySound(lastSoundedMs: 1000, nowMs: 1000 + mistypeMinimumGapMs))
        XCTAssertTrue(mistypeMaySound(lastSoundedMs: 1000, nowMs: 1400))
    }

    /// A clock that went backwards must not pass every comparison it is given.
    func testABackwardClockRestartsRatherThanOpeningTheGate() {
        XCTAssertTrue(mistypeMaySound(lastSoundedMs: 1000, nowMs: 10))
    }
}
