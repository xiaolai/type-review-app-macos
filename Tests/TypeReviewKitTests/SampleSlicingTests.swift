import XCTest

@testable import TypeReviewKit

final class SampleSlicingTests: XCTestCase {
    func testOnsetsMarkEachStrikeOnce() {
        // Two strikes a quarter of a second apart, each a short burst.
        var samples = [Float](repeating: 0, count: 44_100)
        for index in 1000..<1200 { samples[index] = 0.8 }
        for index in 12_000..<12_200 { samples[index] = 0.8 }
        let onsets = SampleSlicing.onsets(in: samples, sampleRate: 44_100)
        // One per strike — the body of a burst is not a second onset.
        XCTAssertEqual(onsets.count, 2)
        // Backed up by the pre-roll, and never before the start of the array.
        XCTAssertEqual(onsets[0], 1000 - Int(0.002 * 44_100))
        XCTAssertEqual(onsets[1], 12_000 - Int(0.002 * 44_100))
    }

    func testOnsetAtTheVeryStartIsNotNegative() {
        var samples = [Float](repeating: 0, count: 100)
        samples[0] = 1
        XCTAssertEqual(SampleSlicing.onsets(in: samples, sampleRate: 44_100), [0])
    }

    func testQuietRecordingHasNoOnsets() {
        let samples = [Float](repeating: 0.1, count: 5000)
        XCTAssertTrue(SampleSlicing.onsets(in: samples, sampleRate: 44_100).isEmpty)
    }

    func testEmptyInputAndZeroRateAreHandled() {
        XCTAssertTrue(SampleSlicing.onsets(in: [], sampleRate: 44_100).isEmpty)
        XCTAssertTrue(SampleSlicing.onsets(in: [1, 1, 1], sampleRate: 0).isEmpty)
    }

    func testSliceEndsInSilence() {
        let frames = 100
        // The last frame is exactly zero, which is the point: ending at
        // `frames - index` left it one step of gain above silence.
        XCTAssertEqual(
            SampleSlicing.gain(atFrame: frames - 1, frames: frames, fadeIn: 5, fadeOut: 10), 0)
        XCTAssertEqual(SampleSlicing.gain(atFrame: 0, frames: frames, fadeIn: 5, fadeOut: 10), 0)
        XCTAssertEqual(SampleSlicing.gain(atFrame: 50, frames: frames, fadeIn: 5, fadeOut: 10), 1)
    }

    func testGainIsZeroOutsideTheSlice() {
        XCTAssertEqual(SampleSlicing.gain(atFrame: -1, frames: 10, fadeIn: 1, fadeOut: 1), 0)
        XCTAssertEqual(SampleSlicing.gain(atFrame: 10, frames: 10, fadeIn: 1, fadeOut: 1), 0)
    }
}
