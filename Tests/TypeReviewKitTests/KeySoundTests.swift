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

    /// A repeatable stand-in for the noise the app actually renders with.
    ///
    /// `square` is a Nyquist-rate tone, so a bandpass centred anywhere a pack
    /// uses rejects nearly all of it: the peak it produces measures the
    /// filter's rejection, not the voice's loudness. That is the right signal
    /// for a stability test and the wrong one for an audibility test, which is
    /// how four releases came to look silent while being perfectly audible.
    /// The app feeds `SynthRenderer.whiteNoise`; so does this, seeded so the
    /// numbers are the same on every run.
    private func noise(_ count: Int) -> [Double] {
        var generator = SeededGenerator(seed: 0x5EED_1234)
        return SynthRenderer.whiteNoise(count, using: &generator)
    }

    /// A fixed-sequence generator: a test that fails one run in fifty is worse
    /// than no test.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            // xorshift64*, chosen for being four lines rather than for its
            // statistics — this fills a noise burst, not a cryptosystem.
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
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
                overrides: [:], release: nil))
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
                // Both halves. A release that rendered silence would be a
                // pack claiming a sound it does not make.
                for stroke in Stroke.allCases {
                    guard let voice = pack.voice(for: category, stroke: stroke) else { continue }
                    let mix = SynthRenderer.render(voice, sampleRate: rate, noise: noise)
                    let where_ = "\(pack.name)/\(category.rawValue)/\(stroke.rawValue)"
                    XCTAssertFalse(mix.isEmpty, "\(where_) rendered no samples")
                    let peak = mix.map(abs).max() ?? 0
                    XCTAssertGreaterThan(peak, 0.001, "\(where_) rendered silence")
                    XCTAssertTrue(
                        mix.allSatisfy(\.isFinite), "\(where_) produced a non-finite sample")
                }
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

    func testAReleaseIsQuieterShorterAndBrighterThanItsPress() {
        // The shape's whole claim, checked against a pack that has one. If a
        // release ever comes out louder or longer than the press it derives
        // from, the numbers have been edited into something that is no longer
        // a key coming back up.
        for pack in KeySoundPack.all {
            for category in SoundCategory.allCases {
                guard let press = pack.voice(for: category, stroke: .press)?.noise,
                    let release = pack.voice(for: category, stroke: .release)?.noise
                else { continue }
                let where_ = "\(pack.name)/\(category.rawValue)"
                XCTAssertLessThan(release.peak, press.peak, "\(where_) release is not quieter")
                XCTAssertLessThan(
                    release.durationMs, press.durationMs, "\(where_) release is not shorter")
                XCTAssertGreaterThan(
                    release.frequency, press.frequency, "\(where_) release is not brighter")
                // Loud enough to survive the envelope's own floor, or it
                // renders as silence and the pack has a release in name only.
                XCTAssertGreaterThan(
                    release.peak, SynthRenderer.decayFloor, "\(where_) release is inaudible")
                XCTAssertEqual(release.filter, press.filter, "\(where_) changed filter type")
            }
        }
    }

    func testAReleaseIsAudibleButNeverAsLoudAsItsPress() {
        // The parameters are checked above; this checks what comes out of the
        // renderer, which is not the same question — a release can be quieter
        // on paper and still arrive inaudible once a short burst has been
        // through a narrow filter.
        //
        // The band is wide because the packs genuinely differ: `thock` lands
        // near an eighth of its press, since all of its weight is in a
        // bottom-out that does not happen on the way up, while `soft` lands
        // above a half, having no body to lose and less press to hide behind.
        // What it rules out is a release nobody can hear and a release that is
        // not a release.
        for pack in KeySoundPack.all {
            for category in SoundCategory.allCases {
                guard let press = pack.voice(for: category, stroke: .press),
                    let release = pack.voice(for: category, stroke: .release)
                else { continue }
                let pressed = SynthRenderer.render(press, sampleRate: rate, noise: noise)
                    .map(abs).max() ?? 0
                let released = SynthRenderer.render(release, sampleRate: rate, noise: noise)
                    .map(abs).max() ?? 0
                let ratio = released / max(pressed, 1e-9)
                let where_ = "\(pack.name)/\(category.rawValue) at \(Int(ratio * 100))%"
                XCTAssertGreaterThan(ratio, 0.05, "\(where_) — release is inaudible")
                XCTAssertLessThan(ratio, 0.75, "\(where_) — release is not quieter enough")
            }
        }
    }

    func testABodyDoesNotSurviveTheKeyComingBackUp() {
        // The physical claim behind `resonance`: the press's oscillator is a
        // bottom-out, and there is no bottom-out on the way up. Packs that set
        // resonance above zero mean something else by it — `clicky`'s spring —
        // and they are the only ones allowed to keep it.
        for pack in [KeySoundPack.mechvibe, .thock, .laptop] {
            let press = pack.voice(for: .space, stroke: .press)
            let release = pack.voice(for: .space, stroke: .release)
            XCTAssertNotNil(press?.oscillator, "\(pack.name) press lost its body")
            if pack.name == "thock" { continue }  // keeps a little case ring
            XCTAssertNil(release?.oscillator, "\(pack.name) release kept a bottom-out")
        }
        XCTAssertNotNil(
            KeySoundPack.clicky.voice(for: .standard, stroke: .release)?.oscillator,
            "clicky lost the ring that is the whole pack")
    }

    func testRecordedPacksHaveNoRelease() {
        // Not an oversight: a typebar returns almost silently, so the strike
        // is the event. Asserted so that adding a release to a sample pack has
        // to be a decision rather than a side effect.
        for category in SoundCategory.allCases {
            XCTAssertNil(KeySoundPack.typewriter.voice(for: category, stroke: .release))
            XCTAssertNil(KeySoundPack.off.voice(for: category, stroke: .release))
        }
    }

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
                // Releases too, and they are the reason this matters more
                // than it did: `brightness` multiplies the centre frequency,
                // so the highest centre in the app is one no pack states.
                for stroke in Stroke.allCases {
                    guard let noise = pack.voice(for: category, stroke: stroke)?.noise,
                        noise.filter == .bandpass
                    else { continue }
                    checked += 1
                    let out = SynthRenderer.bandpass(
                        square(Int(0.05 * rate)), centre: noise.frequency, q: noise.q,
                        sampleRate: rate)
                    let where_ =
                        "\(pack.name)/\(category.rawValue)/\(stroke.rawValue) at \(noise.frequency) Hz Q \(noise.q)"
                    XCTAssertTrue(
                        out.allSatisfy(\.isFinite), "\(where_) produced a non-finite sample")
                    XCTAssertLessThan(out.map(abs).max() ?? 0, 10, "\(where_) ran away")
                }
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


