import Foundation

/// Keyboard sound packs, ported from the website's `src/io/sound-packs.ts`.
///
/// Two kinds, and the split is the same one the original made:
///
/// 1. **Synth** — a filtered noise burst plus an optional decaying
///    oscillator, built on the fly. No asset, no licence, no bytes in the
///    bundle. `mechvibe` and `soft`.
/// 2. **Sample** — one real recording, sliced at detected keystroke onsets
///    and played back a slice at a time. `typewriter`.
///
/// The numbers below are the original's, unchanged. They are the result of
/// tuning by ear against a real keyboard, and re-deriving them would only
/// make the two versions of this app sound different from each other.
///
/// This lives in the Kit rather than the app for the same reason
/// `SettingsSchema` does: it is pure data with no AppKit in it, and the
/// arithmetic around envelopes and slice lengths is worth testing. The
/// *engine* that turns it into sound is AVFoundation and lives in the app.
/// Note also where these settings are stored — the website keeps sound in
/// `localStorage`, not in the profile, so the Mac app keeps them in
/// `UserDefaults` and the vector-pinned profile schema never sees them.
public enum SoundCategory: String, Sendable, CaseIterable {
    case standard, tab, enter, esc, space
}

/// The click. A short burst of white noise pushed through one filter.
public struct NoiseVoice: Sendable, Equatable {
    public enum Filter: Sendable, Equatable {
        case bandpass, lowpass
    }
    public let durationMs: Double
    public let filter: Filter
    /// Centre or cutoff frequency, Hz.
    public let frequency: Double
    /// Filter Q. Higher is peakier, and reads as more "ringy".
    public let q: Double
    /// Peak gain at the attack apex, 0...1.
    public let peak: Double

    public init(
        durationMs: Double, filter: Filter, frequency: Double, q: Double, peak: Double
    ) {
        self.durationMs = durationMs
        self.filter = filter
        self.frequency = frequency
        self.q = q
        self.peak = peak
    }
}

/// The body. A decaying sine under the click — what makes a switch sound
/// like it has a keyboard attached rather than being a bare tick.
public struct OscillatorVoice: Sendable, Equatable {
    public let frequency: Double
    public let durationMs: Double
    public let peak: Double

    public init(frequency: Double, durationMs: Double, peak: Double) {
        self.frequency = frequency
        self.durationMs = durationMs
        self.peak = peak
    }
}

public struct SynthVoice: Sendable, Equatable {
    public let noise: NoiseVoice?
    public let oscillator: OscillatorVoice?

    public init(noise: NoiseVoice? = nil, oscillator: OscillatorVoice? = nil) {
        self.noise = noise
        self.oscillator = oscillator
    }

    /// Silence. Every voice absent means no audio graph is built at all.
    public var isSilent: Bool { noise == nil && oscillator == nil }
}

/// Which half of a keystroke is sounding.
///
/// A real key makes two sounds, and every pack here used to describe only the
/// first. The press is the finger driving the key onto the plate; the release
/// is the spring pushing it back into the top housing, which is a lighter part
/// struck by a weaker force.
public enum Stroke: String, Sendable, CaseIterable {
    case press, release
}

/// How a pack's release sounds, stated as what the press is *not*.
///
/// Derived rather than written out, and that is a claim about the physics
/// rather than a shortcut. The release is the same mechanism running backwards
/// — same materials, same switch, so the same filter over the same noise. What
/// changes is only how hard, how long, how bright, and whether the body is
/// there at all. Four numbers per pack says exactly that; twenty-five more
/// voice literals would say it five times over and let them drift apart.
public struct ReleaseShape: Sendable, Equatable {
    /// Loudness against the press. The spring is doing this, not a finger.
    public let gain: Double
    /// Length against the press.
    public let duration: Double
    /// Centre frequency against the press. Higher: the upstroke arrives at
    /// the top housing, which is thinner than the plate the downstroke hits.
    public let brightness: Double
    /// How much of the oscillator survives, and the one field that is not the
    /// same story in every pack. For most it is the bottom-out body, which
    /// simply does not happen on the way up — zero. For `clicky` it is the
    /// spring, which does ring again on release, quieter.
    public let resonance: Double

    public init(gain: Double, duration: Double, brightness: Double, resonance: Double) {
        self.gain = gain
        self.duration = duration
        self.brightness = brightness
        self.resonance = resonance
    }

    public func applied(to voice: SynthVoice) -> SynthVoice {
        SynthVoice(
            noise: voice.noise.map {
                NoiseVoice(
                    durationMs: $0.durationMs * duration, filter: $0.filter,
                    frequency: $0.frequency * brightness, q: $0.q, peak: $0.peak * gain)
            },
            // The pitch of a body is the case, and a case does not change
            // pitch because the key is going the other way. Only its level
            // and length do.
            oscillator: resonance > 0
                ? voice.oscillator.map {
                    OscillatorVoice(
                        frequency: $0.frequency, durationMs: $0.durationMs * duration,
                        peak: $0.peak * gain * resonance)
                }
                : nil)
    }
}

public struct KeySoundPack: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case silent
        case synth(
            standard: SynthVoice, overrides: [SoundCategory: SynthVoice],
            release: ReleaseShape?)
        /// `resource` is a file in the app bundle's `Resources`, without its
        /// extension. Slice lengths are per category, in milliseconds.
        case sample(
            resource: String, ext: String, standardSliceMs: Double,
            overrides: [SoundCategory: Double])
    }

    /// Stored in `UserDefaults`, so it must stay stable.
    public let name: String
    public let label: String
    public let kind: Kind

    public var id: String { name }

    /// The voice for a category, falling back to `standard` — the same rule
    /// the original used, so a pack only has to describe what differs.
    ///
    /// `.press` by default because it is the primary event: every keystroke
    /// has one, and a pack without a `ReleaseShape` has nothing else. A `nil`
    /// release is how a pack says its keys come back up silently, which is
    /// the truth for a typewriter and a decision for everything else.
    public func voice(for category: SoundCategory, stroke: Stroke = .press) -> SynthVoice? {
        guard case .synth(let standard, let overrides, let release) = kind else { return nil }
        let pressed = overrides[category] ?? standard
        switch stroke {
        case .press: return pressed
        case .release: return release?.applied(to: pressed)
        }
    }

    /// The slice length for a category, in milliseconds.
    public func sliceMs(for category: SoundCategory) -> Double? {
        guard case .sample(_, _, let standard, let overrides) = kind else { return nil }
        return overrides[category] ?? standard
    }
}

extension KeySoundPack {
    public static let off = KeySoundPack(name: "off", label: "Off", kind: .silent)

    public static let mechvibe = KeySoundPack(
        name: "mechvibe", label: "Mechvibe",
        kind: .synth(
            standard: SynthVoice(
                noise: NoiseVoice(
                    durationMs: 50, filter: .bandpass, frequency: 3000, q: 1.5, peak: 0.4),
                oscillator: OscillatorVoice(frequency: 90, durationMs: 60, peak: 0.15)),
            overrides: [
                .tab: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 60, filter: .bandpass, frequency: 2400, q: 1.5, peak: 0.45),
                    oscillator: OscillatorVoice(frequency: 75, durationMs: 70, peak: 0.18)),
                .enter: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 70, filter: .bandpass, frequency: 2200, q: 2, peak: 0.5),
                    oscillator: OscillatorVoice(frequency: 70, durationMs: 90, peak: 0.22)),
                // Light, bright tick — no body.
                .esc: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 40, filter: .bandpass, frequency: 3500, q: 1.5, peak: 0.35)),
                // Wide, low spacebar kachunk.
                .space: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 70, filter: .bandpass, frequency: 1800, q: 1.0, peak: 0.45),
                    oscillator: OscillatorVoice(frequency: 60, durationMs: 95, peak: 0.22)),
            ],
            // A bare board: plastic arriving at plastic, with none of the
            // bottom-out that gives the press its weight.
            release: ReleaseShape(gain: 0.34, duration: 0.55, brightness: 1.30, resonance: 0)))

    /// A real mechanical typewriter, sliced at its own keystrokes.
    ///
    /// Source: BigSoundBank "Typewriter #2" (sound 2835), CC0 — a Hermes
    /// Precisa 305, the Swiss 1960s desktop machine with the crisp typebar
    /// snap rather than a soft portable tick. The website ships it as OGG,
    /// which AVFoundation does not decode; the Mac app ships the same
    /// recording converted to mono AAC. Mono on purpose: the pan is applied
    /// per keystroke from the key's own position, so a stereo source would
    /// only fight it. See CREDITS.md.
    public static let typewriter = KeySoundPack(
        name: "typewriter", label: "Typewriter",
        kind: .sample(
            resource: "typewriter", ext: "m4a",
            // A real keystroke is 50-70 ms of attack and decay. The slice
            // matches that, so two keys at 150 wpm — one every ~80 ms — do
            // not overlap into mud.
            standardSliceMs: 80,
            overrides: [
                .tab: 95,
                .space: 110,  // a touch more body
                .enter: 130,  // carriage-return feel
                .esc: 65,
            ]))

    public static let soft = KeySoundPack(
        name: "soft", label: "Soft",
        kind: .synth(
            standard: SynthVoice(
                noise: NoiseVoice(
                    durationMs: 35, filter: .lowpass, frequency: 1200, q: 1, peak: 0.25)),
            overrides: [
                .tab: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 40, filter: .lowpass, frequency: 1000, q: 1, peak: 0.28)),
                .enter: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 50, filter: .lowpass, frequency: 800, q: 1, peak: 0.32)),
                .esc: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 25, filter: .lowpass, frequency: 1500, q: 1, peak: 0.22)),
                .space: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 50, filter: .lowpass, frequency: 900, q: 1, peak: 0.32)),
            ],
            // Proportionally the loudest release of any pack, which is not a
            // mistake: there is less press here for it to hide behind, and a
            // dampened board is exactly where you notice the key coming back.
            release: ReleaseShape(gain: 0.42, duration: 0.60, brightness: 1.25, resonance: 0)))

    /// A heavy board on foam: the sound modern keyboards are built for.
    ///
    /// The gap `mechvibe` and `soft` leave between them. `mechvibe` is a bare
    /// board — a bright click over a small body. `soft` is muted with no body
    /// at all. Neither is what a gasket-mounted case full of foam does, which
    /// is to swallow the click and leave the *body*: a low knock with the
    /// top end taken off it.
    ///
    /// So the click sits at 1.1 kHz rather than 3, and the sine under it is
    /// louder and longer than any other pack's. Being deep is not the same as
    /// being quiet, and that distinction is the whole pack.
    public static let thock = KeySoundPack(
        name: "thock", label: "Thock",
        kind: .synth(
            standard: SynthVoice(
                noise: NoiseVoice(
                    durationMs: 55, filter: .bandpass, frequency: 1100, q: 1.2, peak: 0.38),
                oscillator: OscillatorVoice(frequency: 60, durationMs: 95, peak: 0.26)),
            overrides: [
                .tab: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 62, filter: .bandpass, frequency: 1000, q: 1.2, peak: 0.38),
                    oscillator: OscillatorVoice(frequency: 56, durationMs: 100, peak: 0.26)),
                .enter: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 75, filter: .bandpass, frequency: 900, q: 1.3, peak: 0.44),
                    oscillator: OscillatorVoice(frequency: 50, durationMs: 120, peak: 0.30)),
                // Still the lightest key, but it keeps a body here — a
                // bodyless tick in this pack would sound like a different
                // keyboard, which is what `mechvibe` does on purpose and this
                // one should not.
                .esc: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 42, filter: .bandpass, frequency: 1400, q: 1.2, peak: 0.30),
                    oscillator: OscillatorVoice(frequency: 72, durationMs: 60, peak: 0.18)),
                // The deepest thing the pack makes: a long bar on a foamed
                // plate, which is the sound people buy these boards for.
                .space: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 80, filter: .bandpass, frequency: 820, q: 1.0, peak: 0.44),
                    oscillator: OscillatorVoice(frequency: 45, durationMs: 130, peak: 0.32)),
            ],
            // The quietest and the brightest, both for the same reason: all
            // of this pack's weight is in a bottom-out that does not happen
            // on the way up. A little case ring survives, and no more.
            release: ReleaseShape(gain: 0.30, duration: 0.50, brightness: 1.50, resonance: 0.12)))

    /// A clicky switch, and the ring it leaves behind.
    ///
    /// The defining sound of a buckling spring or a blue switch is not the
    /// click on its own — it is the metallic ping after it, a real spring
    /// resonating in a real barrel. So the oscillator here is not a body at
    /// 60 Hz like every other pack's; it is the ring, high and quiet.
    ///
    /// One oscillator per voice is the model's limit, so this pack spends it
    /// on the ping and has no low end at all. That is the correct trade: a
    /// clicky board with no ping is just a bright `mechvibe`, and the ping is
    /// the thing anyone would recognise. The narrow Q is what keeps the noise
    /// burst sounding struck rather than sprayed.
    public static let clicky = KeySoundPack(
        name: "clicky", label: "Clicky",
        kind: .synth(
            standard: SynthVoice(
                noise: NoiseVoice(
                    durationMs: 38, filter: .bandpass, frequency: 4200, q: 2.6, peak: 0.40),
                oscillator: OscillatorVoice(frequency: 1800, durationMs: 55, peak: 0.09)),
            overrides: [
                .tab: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 44, filter: .bandpass, frequency: 3900, q: 2.6, peak: 0.42),
                    oscillator: OscillatorVoice(frequency: 1650, durationMs: 60, peak: 0.10)),
                .enter: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 52, filter: .bandpass, frequency: 3600, q: 2.8, peak: 0.46),
                    oscillator: OscillatorVoice(frequency: 1450, durationMs: 70, peak: 0.11)),
                .esc: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 28, filter: .bandpass, frequency: 5000, q: 2.4, peak: 0.34),
                    oscillator: OscillatorVoice(frequency: 2200, durationMs: 34, peak: 0.07)),
                // A stabilised bar rings lower and wider than a single switch.
                .space: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 55, filter: .bandpass, frequency: 3000, q: 1.8, peak: 0.44),
                    oscillator: OscillatorVoice(frequency: 1150, durationMs: 65, peak: 0.09)),
            ],
            // The one pack whose release is a real second click. A buckling
            // spring unbuckles on the way up and rings again, which is why
            // this keeps far more of its oscillator than anything else here —
            // and why a clicky board sounds busier than its keystroke count.
            release: ReleaseShape(gain: 0.45, duration: 0.60, brightness: 1.15, resonance: 0.45)))

    /// A scissor keyboard: 1 mm of travel onto an aluminium deck.
    ///
    /// Short, bright and shallow, which is exactly what a laptop key is. The
    /// distinction from `soft` is worth stating, because both are quiet packs:
    /// `soft` is muffled — a lowpass, everything above 1.2 kHz gone. This is
    /// the opposite. It is almost *all* top end, just very brief, with a
    /// faint low tap where the key bottoms out on the deck.
    ///
    /// Every duration here is under half of `mechvibe`'s. A scissor key that
    /// rang for fifty milliseconds would be a different machine.
    public static let laptop = KeySoundPack(
        name: "laptop", label: "Laptop",
        kind: .synth(
            standard: SynthVoice(
                noise: NoiseVoice(
                    durationMs: 24, filter: .bandpass, frequency: 4800, q: 1.3, peak: 0.32),
                oscillator: OscillatorVoice(frequency: 140, durationMs: 28, peak: 0.07)),
            overrides: [
                .tab: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 28, filter: .bandpass, frequency: 4500, q: 1.3, peak: 0.32),
                    oscillator: OscillatorVoice(frequency: 130, durationMs: 32, peak: 0.07)),
                .enter: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 34, filter: .bandpass, frequency: 3900, q: 1.2, peak: 0.35),
                    oscillator: OscillatorVoice(frequency: 115, durationMs: 40, peak: 0.09)),
                .esc: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 18, filter: .bandpass, frequency: 5600, q: 1.3, peak: 0.26),
                    oscillator: OscillatorVoice(frequency: 165, durationMs: 20, peak: 0.05)),
                // The one hollow key on a laptop, because the bar spans the
                // unsupported middle of the deck.
                .space: SynthVoice(
                    noise: NoiseVoice(
                        durationMs: 40, filter: .bandpass, frequency: 2900, q: 1.0, peak: 0.36),
                    oscillator: OscillatorVoice(frequency: 105, durationMs: 48, peak: 0.10)),
            ],
            // Barely there, and brief even by this pack's standards — the esc
            // release lands at ten milliseconds. A scissor key returns under
            // a light spring with nowhere to resonate.
            release: ReleaseShape(gain: 0.38, duration: 0.55, brightness: 1.20, resonance: 0)))

    /// Offered in this order, which is the website's. New packs are appended
    /// rather than filed among the old ones: the order is what the picker
    /// shows, and rearranging it moves entries under people who had learned
    /// where they were.
    public static let all: [KeySoundPack] = [
        off, mechvibe, typewriter, soft, thock, clicky, laptop,
    ]

    public static func named(_ name: String) -> KeySoundPack? {
        all.first { $0.name == name }
    }
}

/// macOS virtual key codes for the keys that get their own sound.
///
/// The website switches on `KeyboardEvent.key` — the produced character —
/// because a browser cannot ask what physical key was pressed. This app can,
/// so it switches on the code instead, which means the categories stay
/// correct under Dvorak and Colemak where the character moves and the key
/// does not.
public enum KeyCode {
    public static let tab: UInt16 = 48
    public static let `return`: UInt16 = 36
    public static let keypadEnter: UInt16 = 76
    public static let escape: UInt16 = 53
    public static let delete: UInt16 = 51
    public static let forwardDelete: UInt16 = 117
    public static let space: UInt16 = 49
}

/// Which voice a physical key uses.
///
/// Total: every key produces a sound. This returned an optional and its
/// documentation described keys that make none, which was never true of any
/// branch — so the caller carried an unreachable nil case.
public func soundCategory(forKeyCode code: UInt16) -> SoundCategory {
    switch code {
    case KeyCode.tab: return .tab
    case KeyCode.return, KeyCode.keypadEnter: return .enter
    case KeyCode.escape, KeyCode.delete, KeyCode.forwardDelete: return .esc
    case KeyCode.space: return .space
    default: return .standard
    }
}

/// Rendering a synth voice to samples.
///
/// Pure, and here rather than in the app for that reason: this is the part
/// worth testing. The app wraps the result in an `AVAudioPCMBuffer` and hands
/// it to an audio engine, and none of that arithmetic can be checked without
/// a sound card. This can.
///
/// The site builds a Web Audio graph per keystroke — buffer source, biquad,
/// gain, panner. Rendering once and caching the samples is the same sound for
/// a fraction of the work: a keystroke becomes one buffer schedule instead of
/// four node allocations, which is what keeps 150 wpm from stuttering.
public enum SynthRenderer {
    /// Web Audio's floor for an exponential gain ramp. Matching it keeps the
    /// tail the same length rather than merely a similar shape.
    public static let decayFloor = 0.0001

    /// Linear attack to `peak`, then exponential decay toward `decayFloor` —
    /// the shape `linearRampToValueAtTime` followed by
    /// `exponentialRampToValueAtTime` produces.
    ///
    /// The floor is absolute, not relative. `exponentialRampToValueAtTime`
    /// ramps *to the value given*, so the curve is
    /// `peak * (floor/peak)^progress` and ends at 0.0001 whatever the peak
    /// was. Writing `peak * floor^progress` ended a 0.4-peak voice at
    /// 0.00004 — every built-in voice decaying further than the reference,
    /// which is audible as a shorter, drier click.
    public static func envelope(
        frame: Int, frames: Int, peak: Double, attackSeconds: Double, sampleRate: Double
    ) -> Double {
        // `decayFloor / peak` is the ramp's ratio, so a peak at or below the
        // floor would divide into something at or above one — and a denormal
        // like 1e-313 overflows it to infinity. Below the floor there is no
        // decay to describe: the voice is already quieter than silence.
        guard frames > 0, frame >= 0, peak > decayFloor else { return 0 }
        let attackFrames = max(1, Int(attackSeconds * sampleRate))
        if frame < attackFrames {
            return peak * (Double(frame) / Double(attackFrames))
        }
        let progress = Double(frame - attackFrames) / Double(max(1, frames - attackFrames))
        return peak * pow(decayFloor / peak, min(1, progress))
    }

    /// A biquad, the shape Web Audio actually uses.
    ///
    /// Both filters here were approximations before: a one-pole for the
    /// lowpass, which discards `q` entirely, and a Chamberlin state-variable
    /// bandpass, whose two-integrator loop is only conditionally stable — a
    /// 20 kHz centre at 44.1 kHz reached infinity in 589 frames, and the
    /// built-in frequencies blow up at an 8 kHz rate. The RBJ forms below are
    /// stable for every cutoff below Nyquist and are what the reference
    /// implementation's `BiquadFilterNode` computes.
    struct Biquad {
        let b0, b1, b2, a1, a2: Double

        func apply(_ input: [Double]) -> [Double] {
            var out = [Double](repeating: 0, count: input.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in input.indices {
                let x0 = input[i]
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1
                x1 = x0
                y2 = y1
                y1 = y0
                out[i] = y0
            }
            return out
        }

        /// Normalised angular frequency, clamped just below Nyquist so the
        /// coefficients stay finite for any requested cutoff.
        static func omega(_ frequency: Double, _ sampleRate: Double) -> Double {
            let nyquist = sampleRate / 2
            let clamped = min(max(1, frequency), nyquist * 0.999)
            return 2 * Double.pi * clamped / sampleRate
        }

        /// Web Audio's lowpass takes `Q` in **decibels**, not as a plain
        /// quality factor — the one detail that would otherwise make a
        /// faithful-looking port sound wrong.
        static func lowpass(cutoff: Double, qDecibels: Double, sampleRate: Double) -> Biquad {
            let w0 = omega(cutoff, sampleRate)
            let cosW = cos(w0)
            let alpha = sin(w0) / (2 * pow(10, qDecibels / 20))
            let a0 = 1 + alpha
            return Biquad(
                b0: (1 - cosW) / 2 / a0, b1: (1 - cosW) / a0, b2: (1 - cosW) / 2 / a0,
                a1: -2 * cosW / a0, a2: (1 - alpha) / a0)
        }

        /// Bandpass with unity peak gain, where `q` *is* the quality factor.
        static func bandpass(centre: Double, q: Double, sampleRate: Double) -> Biquad {
            let w0 = omega(centre, sampleRate)
            let alpha = sin(w0) / (2 * max(0.0001, q))
            let a0 = 1 + alpha
            return Biquad(
                b0: alpha / a0, b1: 0, b2: -alpha / a0,
                a1: -2 * cos(w0) / a0, a2: (1 - alpha) / a0)
        }
    }

    public static func lowpass(
        _ input: [Double], cutoff: Double, q: Double = 1, sampleRate: Double
    ) -> [Double] {
        guard sampleRate > 0 else { return input }
        return Biquad.lowpass(cutoff: cutoff, qDecibels: q, sampleRate: sampleRate).apply(input)
    }

    public static func bandpass(
        _ input: [Double], centre: Double, q: Double, sampleRate: Double
    ) -> [Double] {
        guard sampleRate > 0 else { return input }
        return Biquad.bandpass(centre: centre, q: q, sampleRate: sampleRate).apply(input)
    }

    /// How many frames a component of `durationMs` occupies, or nil when that
    /// is not a number of frames anything can allocate.
    ///
    /// Every public input reached `Int(…)` unchecked before this. A negative
    /// oscillator duration alongside a positive noise one produced a negative
    /// upper bound and crashed on `0..<count`; a non-finite or enormous
    /// duration trapped in the conversion itself.
    static func frameCount(durationMs: Double, sampleRate: Double) -> Int? {
        guard durationMs.isFinite, durationMs >= 0, sampleRate.isFinite, sampleRate > 0
        else { return nil }
        let frames = (durationMs / 1000) * sampleRate
        guard frames.isFinite, frames >= 0, frames < 1e8 else { return nil }
        return Int(frames)
    }

    /// The whole voice as mono samples. `noise` supplies the white-noise
    /// source so a test can render deterministically; the app passes a real
    /// random generator.
    public static func render(
        _ voice: SynthVoice, sampleRate: Double, noise: (Int) -> [Double]
    ) -> [Double] {
        guard !voice.isSilent else { return [] }
        let noiseFrames = voice.noise.flatMap {
            frameCount(durationMs: $0.durationMs, sampleRate: sampleRate)
        } ?? 0
        let oscFrames = voice.oscillator.flatMap {
            frameCount(durationMs: $0.durationMs, sampleRate: sampleRate)
        } ?? 0
        let frames = max(noiseFrames, oscFrames)
        guard frames > 0 else { return [] }
        var mix = [Double](repeating: 0, count: frames)
        if let config = voice.noise, noiseFrames > 0 {
            mixNoise(config, into: &mix, frames: noiseFrames, sampleRate: sampleRate, noise: noise)
        }
        if let config = voice.oscillator, oscFrames > 0 {
            mixOscillator(config, into: &mix, frames: oscFrames, sampleRate: sampleRate)
        }
        return mix
    }

    private static func mixNoise(
        _ config: NoiseVoice, into mix: inout [Double], frames: Int, sampleRate: Double,
        noise: (Int) -> [Double]
    ) {
        let source = noise(frames)
        // The closure is injected, so its contract is checked rather than
        // trusted: a short array used to be an unchecked subscript crash.
        guard source.count >= frames else { return }
        let filtered: [Double] =
            switch config.filter {
            case .lowpass:
                lowpass(source, cutoff: config.frequency, q: config.q, sampleRate: sampleRate)
            case .bandpass:
                bandpass(source, centre: config.frequency, q: config.q, sampleRate: sampleRate)
            }
        for i in 0..<frames {
            mix[i] += filtered[i]
                * envelope(
                    frame: i, frames: frames, peak: config.peak, attackSeconds: 0.001,
                    sampleRate: sampleRate)
        }
    }

    private static func mixOscillator(
        _ config: OscillatorVoice, into mix: inout [Double], frames: Int, sampleRate: Double
    ) {
        let step = 2 * Double.pi * config.frequency / sampleRate
        for i in 0..<frames {
            mix[i] += sin(step * Double(i))
                * envelope(
                    frame: i, frames: frames, peak: config.peak, attackSeconds: 0.002,
                    sampleRate: sampleRate)
        }
    }

    /// White noise in -1...1.
    public static func whiteNoise(_ count: Int, using generator: inout some RandomNumberGenerator)
        -> [Double]
    {
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count { out[i] = Double.random(in: -1...1, using: &generator) }
        return out
    }
}

/// Which pack a sound toggle should land on.
///
/// Pure, and separated from the `UserDefaults` reading and writing around it
/// so the awkward case can be tested: a remembered pack that is itself `off`.
/// That is reachable — an older build, or `defaults write`, can leave `off`
/// in the "last audible" slot — and returning it would give a toggle that
/// switches sound on to silence and appears to do nothing.
public func nextSoundPack(current: KeySoundPack, remembered: KeySoundPack?) -> KeySoundPack {
    guard current == .off else { return .off }
    guard let remembered, remembered != .off else { return .mechvibe }
    return remembered
}

/// Sample-array arithmetic for the recorded pack.
///
/// Here rather than in the app because it is the part worth testing: finding
/// strike onsets in a recording and shaping a slice's edges are ordinary
/// numeric problems, and neither needs an audio device. The app keeps the
/// AVFoundation buffer handling and hands these plain arrays.
public enum SampleSlicing {
    /// The start of each strike in a recording.
    ///
    /// A sample crossing `threshold` marks a strike, and everything within
    /// `minGapSeconds` of it belongs to the same one — a single key press has
    /// a rattle after it, not a second press. `preRollSeconds` backs the mark
    /// up slightly so the slice starts before the attack rather than on it.
    public static func onsets(
        in samples: [Float], sampleRate: Double, threshold: Float = 0.3,
        minGapSeconds: Double = 0.100, preRollSeconds: Double = 0.002
    ) -> [Int] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        let minGap = max(1, Int(minGapSeconds * sampleRate))
        let preRoll = max(0, Int(preRollSeconds * sampleRate))
        var found: [Int] = []
        var last = -minGap
        for index in samples.indices where abs(samples[index]) >= threshold && index - last >= minGap
        {
            found.append(max(0, index - preRoll))
            last = index
        }
        return found
    }

    /// The gain for one frame of a slice, 0...1.
    ///
    /// Linear fades at both ends. The last frame is exactly zero: an envelope
    /// measured from `frames - index` never reaches it, so a slice ended one
    /// step of gain above silence and clicked.
    public static func gain(atFrame index: Int, frames: Int, fadeIn: Int, fadeOut: Int) -> Float {
        guard frames > 0, index >= 0, index < frames else { return 0 }
        var gain: Float = 1
        if fadeIn > 0, index < fadeIn { gain *= Float(index) / Float(fadeIn) }
        let fromEnd = frames - 1 - index
        if fadeOut > 0, fromEnd < fadeOut { gain *= Float(fromEnd) / Float(fadeOut) }
        return gain
    }
}
