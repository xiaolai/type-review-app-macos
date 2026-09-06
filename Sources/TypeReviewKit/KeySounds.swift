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

public struct KeySoundPack: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case silent
        case synth(standard: SynthVoice, overrides: [SoundCategory: SynthVoice])
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
    public func voice(for category: SoundCategory) -> SynthVoice? {
        guard case .synth(let standard, let overrides) = kind else { return nil }
        return overrides[category] ?? standard
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
            ]))

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
            ]))

    /// Offered in this order, which is the website's.
    public static let all: [KeySoundPack] = [off, mechvibe, typewriter, soft]

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

/// The sound category for a physical key, or nil for keys that stay silent.
///
/// Backspace shares the `esc` voice deliberately, as it does on the website:
/// a mechanical typewriter has no backspace, so there is no historically
/// honest sound to borrow, and `esc` is the shortest and crispest voice in
/// every pack — it reads as a small corrective tick rather than a keystroke.
public func soundCategory(forKeyCode code: UInt16) -> SoundCategory? {
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
    public static func envelope(
        frame: Int, frames: Int, peak: Double, attackSeconds: Double, sampleRate: Double
    ) -> Double {
        guard frames > 0, frame >= 0 else { return 0 }
        let attackFrames = max(1, Int(attackSeconds * sampleRate))
        if frame < attackFrames {
            return peak * (Double(frame) / Double(attackFrames))
        }
        let progress = Double(frame - attackFrames) / Double(max(1, frames - attackFrames))
        return peak * pow(decayFloor, min(1, progress))
    }

    /// One-pole lowpass. At a 35 ms burst and these cutoffs it is
    /// indistinguishable from the biquad the site uses, and it has no
    /// stability corner to worry about.
    public static func lowpass(_ input: [Double], cutoff: Double, sampleRate: Double) -> [Double] {
        let dt = 1 / sampleRate
        let rc = 1 / (2 * Double.pi * max(1, cutoff))
        let alpha = dt / (rc + dt)
        var out = [Double](repeating: 0, count: input.count)
        var previous = 0.0
        for i in input.indices {
            previous += alpha * (input[i] - previous)
            out[i] = previous
        }
        return out
    }

    /// State-variable bandpass — the Chamberlin topology. `f` is clamped
    /// below the point where the two-integrator loop goes unstable, which is
    /// why a 3.5 kHz centre at 44.1 kHz stays well behaved.
    public static func bandpass(
        _ input: [Double], centre: Double, q: Double, sampleRate: Double
    ) -> [Double] {
        let f = 2 * sin(Double.pi * min(max(1, centre), sampleRate / 2.2) / sampleRate)
        let damping = 1 / max(0.5, q)
        var low = 0.0
        var band = 0.0
        var out = [Double](repeating: 0, count: input.count)
        for i in input.indices {
            let high = input[i] - low - damping * band
            band += f * high
            low += f * band
            out[i] = band
        }
        return out
    }

    /// The whole voice as mono samples. `noise` supplies the white-noise
    /// source so a test can render deterministically; the app passes a real
    /// random generator.
    public static func render(
        _ voice: SynthVoice, sampleRate: Double, noise: (Int) -> [Double]
    ) -> [Double] {
        guard !voice.isSilent else { return [] }
        let longest = max(voice.noise?.durationMs ?? 0, voice.oscillator?.durationMs ?? 0)
        let frames = Int((longest / 1000) * sampleRate)
        guard frames > 0 else { return [] }
        var mix = [Double](repeating: 0, count: frames)

        if let config = voice.noise {
            let count = min(frames, Int((config.durationMs / 1000) * sampleRate))
            if count > 0 {
                let source = noise(count)
                let filtered: [Double]
                switch config.filter {
                case .lowpass:
                    filtered = lowpass(source, cutoff: config.frequency, sampleRate: sampleRate)
                case .bandpass:
                    filtered = bandpass(
                        source, centre: config.frequency, q: config.q, sampleRate: sampleRate)
                }
                for i in 0..<count {
                    mix[i] += filtered[i]
                        * envelope(
                            frame: i, frames: count, peak: config.peak, attackSeconds: 0.001,
                            sampleRate: sampleRate)
                }
            }
        }

        if let config = voice.oscillator {
            let count = min(frames, Int((config.durationMs / 1000) * sampleRate))
            let step = 2 * Double.pi * config.frequency / sampleRate
            for i in 0..<count {
                mix[i] += sin(step * Double(i))
                    * envelope(
                        frame: i, frames: count, peak: config.peak, attackSeconds: 0.002,
                        sampleRate: sampleRate)
            }
        }
        return mix
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
