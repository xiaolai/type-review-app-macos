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
        // And it lands on Web Audio's floor rather than on zero, which is what
        // keeps the tail the same length as the site's.
        //
        // The floor is absolute. This asserted `peak * decayFloor`, which is
        // the same mistake the implementation made:
        // `exponentialRampToValueAtTime(0.0001, end)` ramps *to* 0.0001, not
        // to a fraction of the peak — so a 0.4-peak voice ended at 0.00004 and
        // the test agreed with it.
        XCTAssertEqual(
            SynthRenderer.envelope(
                frame: frames, frames: frames, peak: peak, attackSeconds: attack, sampleRate: rate),
            SynthRenderer.decayFloor, accuracy: 1e-9)
    }

    /// The filters must stay finite everywhere, not only at the frequencies
    /// the built-in packs happen to use.
    ///
    /// The state-variable bandpass this replaced reached infinity in 589
    /// frames at a 20 kHz centre, and the built-in centres blew up at an 8 kHz
    /// sample rate. Alternating ±1 is the worst case: full energy at Nyquist.
    func testFiltersStayFiniteAtEveryFrequencyAndRate() {
        let input = (0..<2000).map { $0 % 2 == 0 ? 1.0 : -1.0 }
        for rate in [8000.0, 22_050, 44_100, 48_000] {
            for frequency in [1.0, 200, 1200, 3500, 12_000, 20_000, rate, rate * 4] {
                for q in [0.1, 1.0, 5.0, 30.0] {
                    let band = SynthRenderer.bandpass(
                        input, centre: frequency, q: q, sampleRate: rate)
                    XCTAssertTrue(
                        band.allSatisfy { $0.isFinite },
                        "bandpass diverged at \(frequency) Hz, q \(q), rate \(rate)")
                    let low = SynthRenderer.lowpass(
                        input, cutoff: frequency, q: q, sampleRate: rate)
                    XCTAssertTrue(
                        low.allSatisfy { $0.isFinite },
                        "lowpass diverged at \(frequency) Hz, q \(q), rate \(rate)")
                }
            }
        }
    }

    /// A render must not trap or crash on values a caller can legally pass.
    func testRenderRejectsImpossibleDurations() {
        let bad = SynthVoice(
            noise: NoiseVoice(durationMs: 35, filter: .lowpass, frequency: 1200, q: 1, peak: 0.25),
            oscillator: OscillatorVoice(frequency: 400, durationMs: -50, peak: 0.2))
        XCTAssertFalse(SynthRenderer.render(bad, sampleRate: 44_100, noise: { count in
            [Double](repeating: 0.5, count: count)
        }).isEmpty)

        let nonsense = SynthVoice(
            noise: NoiseVoice(
                durationMs: .infinity, filter: .lowpass, frequency: 1200, q: 1, peak: 0.25))
        XCTAssertTrue(SynthRenderer.render(nonsense, sampleRate: 44_100, noise: { count in
            [Double](repeating: 0.5, count: count)
        }).isEmpty)
    }

    /// A noise source that returns too few samples must be refused, not
    /// subscripted past its end.
    func testShortNoiseSourceIsRefused() {
        let voice = SynthVoice(
            noise: NoiseVoice(durationMs: 35, filter: .lowpass, frequency: 1200, q: 1, peak: 0.25))
        let rendered = SynthRenderer.render(voice, sampleRate: 44_100, noise: { _ in [] })
        XCTAssertTrue(rendered.allSatisfy { $0 == 0 })
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

    func testEveryBandpassVoiceStaysStable() {
        // Exhaustive, and it did not used to be. This was a literal 3.5 kHz
        // with a comment naming the voice it came from — `mechvibe`'s esc,
        // "the highest centre in any pack". Adding a pack with a 5.6 kHz voice
        // left it passing over a case it no longer covered, and saying so.
        // Instability is a function of Q as much as of centre anyway, so the
        // highest centre was never the whole risk.
        //
        // A state-variable filter goes unstable if its coefficient is pushed
        // too far, and the failure is a burst of full-scale noise — loud, and
        // exactly the kind of thing to catch before shipping.
        var checked = 0
        for pack in KeySoundPack.all {
            for category in SoundCategory.allCases {
                guard let noise = pack.voice(for: category)?.noise, noise.filter == .bandpass
                else { continue }
                checked += 1
                let out = SynthRenderer.bandpass(
                    square(Int(0.05 * rate)), centre: noise.frequency, q: noise.q,
                    sampleRate: rate)
                let where_ = "\(pack.name)/\(category.rawValue) at \(noise.frequency) Hz Q \(noise.q)"
                XCTAssertTrue(out.allSatisfy(\.isFinite), "\(where_) produced a non-finite sample")
                XCTAssertLessThan(out.map(abs).max() ?? 0, 10, "\(where_) ran away")
            }
        }
        // A loop that silently matched nothing looks exactly like a loop that
        // passed.
        XCTAssertGreaterThan(checked, 0, "no bandpass voice was checked")
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
