import XCTest

@testable import TypeReviewKit

/// The parts of the sound layer that can be checked without a sound card.
///
/// A sound bug is invisible to every other check in this project: the app
/// builds, the self-test passes, the window looks right, and nothing plays.
/// These assert the arithmetic that decides whether a keystroke produces
/// audible samples at all.
final class KeySoundTests: XCTestCase {
    private let rate = 44_100.0

    /// Deterministic "noise", so a render is reproducible. Full-scale
    /// alternating samples are the worst case for a filter and the easiest
    /// signal to reason about.
    private func square(_ count: Int) -> [Double] {
        (0..<count).map { $0.isMultiple(of: 2) ? 1.0 : -1.0 }
    }

    // MARK: - Packs

    func testEveryPackIsReachableByItsStoredName() {
        for pack in KeySoundPack.all {
            XCTAssertEqual(KeySoundPack.named(pack.name)?.name, pack.name)
        }
        // The name is what sits in UserDefaults, so an unknown one has to
        // resolve rather than trap or vanish.
        XCTAssertNil(KeySoundPack.named("no-such-pack"))
    }

    func testCategoriesFallBackToTheStandardVoice() {
        // `soft` overrides every category; `mechvibe` does too. A category a
        // pack does not name must still produce the standard voice rather
        // than silence.
        let sparse = KeySoundPack(
            name: "sparse", label: "Sparse",
            kind: .synth(
                standard: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 30, filter: .lowpass, frequency: 1000, q: 1, peak: 0.3)),
                overrides: [:]))
        for category in SoundCategory.allCases {
            XCTAssertNotNil(sparse.voice(for: category), category.rawValue)
        }
    }

    func testSilentPackYieldsNoVoiceAndNoSlice() {
        for category in SoundCategory.allCases {
            XCTAssertNil(KeySoundPack.off.voice(for: category))
            XCTAssertNil(KeySoundPack.off.sliceMs(for: category))
        }
    }

    func testSampleSliceLengthsFollowTheirOverrides() {
        XCTAssertEqual(KeySoundPack.typewriter.sliceMs(for: .standard), 80)
        XCTAssertEqual(KeySoundPack.typewriter.sliceMs(for: .enter), 130)
        // A synth pack has no slices, and a sample pack has no voices.
        XCTAssertNil(KeySoundPack.typewriter.voice(for: .standard))
        XCTAssertNil(KeySoundPack.mechvibe.sliceMs(for: .standard))
    }

    // MARK: - Categories

    func testPhysicalKeysMapToTheirCategories() {
        XCTAssertEqual(soundCategory(forKeyCode: KeyCode.tab), .tab)
        XCTAssertEqual(soundCategory(forKeyCode: KeyCode.return), .enter)
        XCTAssertEqual(soundCategory(forKeyCode: KeyCode.keypadEnter), .enter)
        XCTAssertEqual(soundCategory(forKeyCode: KeyCode.space), .space)
        // Backspace shares the esc voice deliberately — see the note on
        // `soundCategory`.
        XCTAssertEqual(soundCategory(forKeyCode: KeyCode.escape), .esc)
        XCTAssertEqual(soundCategory(forKeyCode: KeyCode.delete), .esc)
        // A letter — code 0 is `a` on ANSI.
        XCTAssertEqual(soundCategory(forKeyCode: 0), .standard)
    }

    // MARK: - Envelope

    func testEnvelopeRisesThroughTheAttackThenDecays() {
        let frames = Int(0.05 * rate)
        let peak = 0.4
        let attack = 0.001
        let attackFrames = Int(attack * rate)

        XCTAssertEqual(
            SynthRenderer.envelope(
                frame: 0, frames: frames, peak: peak, attackSeconds: attack, sampleRate: rate),
            0, accuracy: 1e-12,
            "starting anywhere but zero is a discontinuity, and it clicks")

        let apex = SynthRenderer.envelope(
            frame: attackFrames, frames: frames, peak: peak, attackSeconds: attack,
            sampleRate: rate)
        XCTAssertEqual(apex, peak, accuracy: 1e-9)

        // Monotonic decay after the apex.
        var previous = apex
        for frame in stride(from: attackFrames + 1, to: frames, by: 37) {
            let value = SynthRenderer.envelope(
                frame: frame, frames: frames, peak: peak, attackSeconds: attack, sampleRate: rate)
            XCTAssertLessThanOrEqual(value, previous, "envelope rose again at frame \(frame)")
            previous = value
        }
        // And it lands on Web Audio's floor rather than on zero, which is
        // what keeps the tail the same length as the site's.
        XCTAssertEqual(
            SynthRenderer.envelope(
                frame: frames, frames: frames, peak: peak, attackSeconds: attack, sampleRate: rate),
            peak * SynthRenderer.decayFloor, accuracy: 1e-9)
    }

    // MARK: - Rendering

    func testEverySynthVoiceRendersAudibleSamples() {
        // The check that would have caught a silent build: every voice of
        // every synth pack must produce samples, and they must not be zero.
        for pack in KeySoundPack.all {
            for category in SoundCategory.allCases {
                guard let voice = pack.voice(for: category) else { continue }
                let mix = SynthRenderer.render(voice, sampleRate: rate, noise: square)
                XCTAssertFalse(
                    mix.isEmpty, "\(pack.name)/\(category.rawValue) rendered no samples")
                let peak = mix.map(abs).max() ?? 0
                XCTAssertGreaterThan(
                    peak, 0.001, "\(pack.name)/\(category.rawValue) rendered silence")
                XCTAssertTrue(
                    mix.allSatisfy(\.isFinite),
                    "\(pack.name)/\(category.rawValue) produced a non-finite sample")
            }
        }
    }

    func testRenderedLengthFollowsTheLongestVoice() {
        // mechvibe's standard voice is a 50 ms noise burst over a 60 ms
        // oscillator, so the buffer has to be 60 ms — truncating to the noise
        // would cut the body off mid-decay.
        guard let voice = KeySoundPack.mechvibe.voice(for: .standard) else {
            return XCTFail("mechvibe should have a standard voice")
        }
        let mix = SynthRenderer.render(voice, sampleRate: rate, noise: square)
        XCTAssertEqual(Double(mix.count) / rate, 0.060, accuracy: 0.001)
    }

    func testASilentVoiceRendersNothingAtAll() {
        let mix = SynthRenderer.render(SynthVoice(), sampleRate: rate, noise: square)
        XCTAssertTrue(mix.isEmpty, "an empty voice must not allocate a buffer")
    }

    // MARK: - Filters

    func testBandpassStaysStableAtTheHighestCentreUsed() {
        // 3.5 kHz is `mechvibe`'s esc voice, the highest centre in any pack.
        // A state-variable filter goes unstable if its coefficient is pushed
        // too far, and the failure is a burst of full-scale noise — loud,
        // and exactly the kind of thing to catch before shipping.
        let out = SynthRenderer.bandpass(
            square(Int(0.05 * rate)), centre: 3500, q: 1.5, sampleRate: rate)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        XCTAssertLessThan(out.map(abs).max() ?? 0, 10, "bandpass ran away")
    }

    func testLowpassAttenuatesFasterAlternationThanTheCutoff() {
        // Full-rate alternation is the highest frequency representable, so a
        // 1.2 kHz lowpass should leave very little of it.
        let out = SynthRenderer.lowpass(
            square(Int(0.035 * rate)), cutoff: 1200, sampleRate: rate)
        XCTAssertLessThan(out.map(abs).max() ?? 1, 0.5)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
    }
}

extension KeySoundTests {
    func testTogglingOffRemembersNothingAndTogglingOnRestores() {
        // On -> off, whatever was playing.
        XCTAssertEqual(nextSoundPack(current: .typewriter, remembered: .mechvibe), .off)
        XCTAssertEqual(nextSoundPack(current: .soft, remembered: nil), .off)
        // Off -> back to what was last audible.
        XCTAssertEqual(nextSoundPack(current: .off, remembered: .typewriter), .typewriter)
    }

    func testTogglingOnNeverLandsBackOnSilence() {
        // Nothing remembered — a first-ever toggle.
        XCTAssertEqual(nextSoundPack(current: .off, remembered: nil), .mechvibe)
        // And the case worth having a function for: `off` remembered as the
        // last audible pack, which would otherwise switch sound "on" to
        // silence and look like the shortcut is broken.
        XCTAssertEqual(nextSoundPack(current: .off, remembered: .off), .mechvibe)
    }
}
