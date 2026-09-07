@preconcurrency import AVFoundation
import TypeReviewKit

/// Plays a click per keystroke.
///
/// The website builds a Web Audio graph per keystroke — a buffer source into
/// a biquad into a gain into a panner. AVAudioEngine has no equivalent worth
/// reaching for here: `AVAudioUnitEQ` would give the filter, but wiring a
/// fresh node graph per keystroke and tearing it down again is far more
/// machinery than the job needs, and node connection is not cheap on the
/// audio thread.
///
/// So the voices are **rendered to PCM once and cached**. A synth voice is a
/// few hundred samples of filtered noise plus a decaying sine; computing that
/// is trivial, and doing it once per (pack, category) rather than once per
/// keystroke means a keystroke costs one buffer schedule. The filters are the
/// same one-pole lowpass and state-variable bandpass shapes Web Audio's
/// biquads implement, at the same cutoffs, so the packs sound like their
/// counterparts on the site.
///
/// Nothing here is created until the first audible keystroke: while the pack
/// is `off` there is no engine, no file read and no audio device held open.
@MainActor
final class KeySoundPlayer {
    private var engine: AVAudioEngine?
    private var pack: KeySoundPack = .off
    private var volume: Double = 0.5

    /// One player node per voice, round-robined. A single node cannot play
    /// two overlapping slices, and at 150 wpm the tail of one keystroke is
    /// still sounding when the next arrives — with one node the earlier
    /// sound is cut off and fast typing turns into a stutter.
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private static let voiceCount = 8

    /// What a rendered buffer belongs to.
    ///
    /// Both halves, not just the category. Keyed by category alone, the
    /// release of a key would have been served the press's buffer — the cache
    /// silently answering a question it had not been asked, which is the same
    /// shape of bug as the single `sample` below.
    private struct Rendered: Hashable {
        let category: SoundCategory
        let stroke: Stroke
    }

    /// Rendered audio per category and stroke, built lazily and thrown away
    /// when the pack changes.
    private var rendered: [Rendered: AVAudioPCMBuffer] = [:]
    /// For the sample pack: the whole recording, plus the onsets found in it.
    private var sample: AVAudioPCMBuffer?
    private var onsets: [Int] = []
    /// Why the recording could not be loaded, if it could not. Also stops the
    /// load being retried on every keystroke.
    private(set) var loadFailure: String?
    private var isLoadingSample = false

    /// Resamples a decoded recording into the engine's format.
    private nonisolated static func converted(
        _ input: AVAudioPCMBuffer, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        guard let converter = AVAudioConverter(from: input.format, to: format) else { return nil }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }
        // A reference box, not a captured `var`. The input block is typed
        // `@Sendable`, so a mutable local captured in it is a data race as far
        // as the compiler is concerned — even though `convert` calls it
        // synchronously on this thread.
        final class Once: @unchecked Sendable { var supplied = false }
        let once = Once()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if once.supplied {
                status.pointee = .endOfStream
                return nil
            }
            once.supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        // Sample-rate conversion interpolates, and interpolation overshoots on
        // a transient. This recording is percussive and already close to full
        // scale, so the converted buffer peaked at 1.15 — which the mixer
        // clips. Scaled back to the peak it came in with, never boosted, so
        // the waveform is unchanged apart from the overshoot.
        if let source = input.floatChannelData?[0], let result = output.floatChannelData?[0] {
            var inputPeak: Float = 0
            for i in 0..<Int(input.frameLength) { inputPeak = max(inputPeak, abs(source[i])) }
            var outputPeak: Float = 0
            for i in 0..<Int(output.frameLength) { outputPeak = max(outputPeak, abs(result[i])) }
            if outputPeak > inputPeak, outputPeak > 0 {
                let gain = inputPeak / outputPeak
                for channel in 0..<Int(output.format.channelCount) {
                    guard let data = output.floatChannelData?[channel] else { continue }
                    for i in 0..<Int(output.frameLength) { data[i] *= gain }
                }
            }
        }
        return output
    }

    nonisolated static let format = AVAudioFormat(
        standardFormatWithSampleRate: 44_100, channels: 2)!

    // MARK: - Configuration

    func setPack(_ pack: KeySoundPack) {
        guard pack != self.pack else { return }
        self.pack = pack
        rendered.removeAll()
        sample = nil
        onsets = []
        if case .silent = pack.kind { teardown() }
    }

    func setVolume(_ value: Double) {
        volume = min(1, max(0, value))
        engine?.mainMixerNode.outputVolume = Float(volume)
    }

    // MARK: - Playing

    /// Plays one half of a keystroke for a physical key. `pan` is -1...1.
    ///
    /// A pack with no release simply has no buffer for one, so nothing here
    /// needs to know whether the current pack has releases — asking for one it
    /// does not have is silence, not a special case.
    func play(category: SoundCategory, stroke: Stroke = .press, pan: Double) {
        if case .silent = pack.kind { return }
        guard volume > 0, let buffer = buffer(for: category, stroke: stroke) else { return }
        guard let node = nextPlayerNode() else { return }
        node.pan = Float(min(1, max(-1, pan)))
        // `.interrupts` rather than the default: the node is being reused
        // round-robin, and if all eight are still sounding the oldest should
        // give way to the key just pressed rather than the new key being
        // dropped. A dropped keystroke is far more noticeable than a clipped
        // tail.
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        node.play()
    }

    private func nextPlayerNode() -> AVAudioPlayerNode? {
        guard start() != nil else { return nil }
        let node = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        return node
    }

    private func buffer(for category: SoundCategory, stroke: Stroke = .press)
        -> AVAudioPCMBuffer?
    {
        let key = Rendered(category: category, stroke: stroke)
        if let cached = rendered[key] { return cached }
        let built: AVAudioPCMBuffer?
        switch pack.kind {
        case .silent:
            built = nil
        case .synth:
            built = pack.voice(for: category, stroke: stroke).flatMap(render)
        case .sample(let resource, let ext, _, _):
            // Recorded packs have no release, and the typewriter is the
            // reason that is the right default rather than a gap: a typebar
            // returns almost silently, and the strike is the event. A release
            // slice would be a quieter copy of a sound that does not happen.
            built = stroke == .release
                ? nil
                : loadSample(resource, ext).flatMap { _ in
                    pack.sliceMs(for: category).flatMap(slice)
                }
        }
        if let built { rendered[key] = built }
        return built
    }

    /// The loudest sample in the buffer this category would play, or nil if
    /// no buffer could be built. Used by `--soundcheck`: unit tests cover the
    /// synthesis arithmetic, but only running the built app can tell whether
    /// the typewriter recording actually shipped inside it and decodes.
    func renderedPeak(for category: SoundCategory) -> Float? {
        guard let buffer = buffer(for: category),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) where abs(channel[i]) > peak {
            peak = abs(channel[i])
        }
        return peak
    }

    // MARK: - Engine lifecycle

    @discardableResult
    private func start() -> AVAudioEngine? {
        // Running, not merely existing. Changing the output device — plugging
        // in headphones, or a sample-rate change — stops and uninitialises the
        // engine, and returning the cached object then scheduled buffers into
        // something that would never play them: sound stopped for the rest of
        // the session with nothing to indicate why.
        if let engine, engine.isRunning { return engine }
        if engine != nil { teardown() }
        let engine = AVAudioEngine()
        for _ in 0..<Self.voiceCount {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: Self.format)
            voices.append(node)
        }
        engine.mainMixerNode.outputVolume = Float(volume)
        do {
            try engine.start()
        } catch {
            // Silence is the right failure mode for a sound effect. Nothing
            // about typing depends on it, and an alert would be worse than
            // the missing click.
            voices.removeAll()
            return nil
        }
        self.engine = engine
        return engine
    }

    private func teardown() {
        engine?.stop()
        voices.removeAll()
        nextVoice = 0
        engine = nil
    }

    // MARK: - Synthesis

    /// Wraps `SynthRenderer.render` in a stereo buffer. The arithmetic lives
    /// in the Kit, where it can be tested without a sound card; this is only
    /// the plumbing.
    private func render(_ voice: SynthVoice) -> AVAudioPCMBuffer? {
        let rate = Self.format.sampleRate
        var generator = SystemRandomNumberGenerator()
        let mix = SynthRenderer.render(voice, sampleRate: rate) { count in
            SynthRenderer.whiteNoise(count, using: &generator)
        }
        guard !mix.isEmpty,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(mix.count)),
            let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(mix.count)
        // Mono content written to both channels; the pan is applied by the
        // player node, not baked into the buffer, so one rendered voice
        // serves every key position.
        for frame in mix.indices {
            channels[0][frame] = Float(mix[frame])
            channels[1][frame] = Float(mix[frame])
        }
        return buffer
    }

    // MARK: - Sample pack

    /// Loads the recording and finds its keystroke onsets.
    ///
    /// Playing from random positions in the clip is what the site started
    /// with and had to abandon: most of an 83-second recording is the gap
    /// between keystrokes, so a random slice usually lands in dead air. The
    /// onsets are scanned once, and every slice starts on one.
    @discardableResult
    private func loadSample(_ resource: String, _ ext: String) -> AVAudioPCMBuffer? {
        if let sample { return sample }
        // One attempt, and it does not happen here. Decoding the recording is
        // 83 seconds of audio and about four million samples to scan, and it
        // used to run synchronously on the main actor at the first typewriter
        // keystroke — freezing input and the window for as long as it took,
        // and doing it again on every switch back to the pack.
        //
        // Started once and installed when it lands. Until then this pack is
        // silent, which is a far better failure than a stalled app.
        guard loadFailure == nil, !isLoadingSample else { return nil }
        isLoadingSample = true
        let wanted = pack
        Task.detached(priority: .userInitiated) {
            let loaded = Self.decodeSample(resource: resource, ext: ext)
            await MainActor.run {
                self.isLoadingSample = false
                // Only if it is still the pack the user has chosen. Switching
                // away while this was in flight would otherwise install a
                // recording nothing is going to play.
                guard self.pack == wanted else { return }
                switch loaded {
                case .loaded(let box):
                    self.sample = box.buffer
                    self.onsets = box.onsets
                    self.rendered.removeAll()
                case .failed(let reason):
                    self.loadFailure = reason
                }
            }
        }
        return nil
    }

    /// What a decode attempt produced.
    private enum LoadOutcome: Sendable {
        case loaded(LoadedSample)
        case failed(String)
    }

    /// The decoded, resampled recording and where its strikes begin.
    ///
    /// `@unchecked Sendable` because `AVAudioPCMBuffer` is not `Sendable` and
    /// this one is handed across exactly once, from the task that made it to
    /// the main actor, and never touched again by the sender.
    private final class LoadedSample: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let onsets: [Int]
        init(buffer: AVAudioPCMBuffer, onsets: [Int]) {
            self.buffer = buffer
            self.onsets = onsets
        }
    }

    /// Reads, converts and scans the recording. No actor, no shared state.
    private nonisolated static func decodeSample(
        resource: String, ext: String
    ) -> LoadOutcome {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
            let file = try? AVAudioFile(forReading: url),
            let decoded = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)),
            (try? file.read(into: decoded)) != nil
        else { return .failed("could not read \(resource).\(ext)") }
        // Converted to the engine's format before anything is measured or
        // sliced. The recording is 48 kHz and the engine runs at 44.1 kHz, and
        // the slicing below copies sample for sample — so every typewriter
        // click played 8.8% too long and about 1.5 semitones flat, which is
        // audible as a duller, slower typewriter than the one on the site.
        guard let raw = converted(decoded, to: format), let data = raw.floatChannelData?[0]
        else { return .failed("could not convert \(resource).\(ext) to the engine's format") }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(raw.frameLength)))
        let found = SampleSlicing.onsets(in: samples, sampleRate: format.sampleRate)
        guard !found.isEmpty else { return .failed("\(resource).\(ext) has no detectable strikes") }
        return .loaded(LoadedSample(buffer: raw, onsets: found))
    }

    /// Cuts one slice at a random onset, with the short fades that stop the
    /// cut edges from popping.
    ///
    /// The slice is chosen once and cached per category rather than per
    /// keystroke. The site re-randomises every keystroke; caching costs some
    /// of that variation and buys a keystroke that is a single buffer
    /// schedule, which is what keeps fast typing from stuttering. The onset
    /// is still random per app run, so two sessions do not sound identical.
    private func slice(_ sliceMs: Double) -> AVAudioPCMBuffer? {
        guard let sample, let source = sample.floatChannelData?[0], !onsets.isEmpty
        else { return nil }
        let rate = sample.format.sampleRate
        let frames = min(Int((sliceMs / 1000) * rate), Int(sample.frameLength))
        guard frames > 0,
            let start = onsets.randomElement(),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let channels = buffer.floatChannelData else { return nil }

        let fadeIn = max(1, Int(0.0015 * rate))
        let fadeOut = max(1, Int(0.008 * rate))
        for i in 0..<frames {
            let index = start + i
            let raw = index < Int(sample.frameLength) ? source[index] : 0
            // The envelope lives in the engine, where it is tested. See
            // `SampleSlicing.gain`.
            let value = raw * SampleSlicing.gain(
                atFrame: i, frames: frames, fadeIn: fadeIn, fadeOut: fadeOut)
            channels[0][i] = value
            channels[1][i] = value
        }
        return buffer
    }
}

/// Where a key sits across the keyboard, as a stereo pan.
///
/// The website hard-codes two sets of QWERTY key names, because a browser
/// cannot ask what physical keyboard is attached. This app already knows:
/// `KeyboardGeometry` describes the real rows for the real shape, so the pan
/// falls out of the key's own position and is automatically right on ISO and
/// JIS boards, where the hard-coded sets would be wrong.
///
/// Continuous rather than three-valued, which is a small improvement on the
/// original: a key drifts smoothly from left to right across the board
/// instead of snapping between two positions. The range is still the site's
/// ±0.3 — noticeable on headphones, not theatrical on speakers.
/// Main-actor isolated because of the cache below, and because the only
/// caller is `keyDown`. `SystemKeyboard.shape` is a main-thread query anyway.
@MainActor
enum KeyPan {
    static let amount = 0.3

    /// Built once. `rows(for:)` walks the whole layout, and this is called on
    /// the keystroke path.
    private static var cache: [UInt16: Double] = [:]
    private static var cachedShape: SystemKeyboard.Shape?

    static func pan(forKeyCode code: UInt16) -> Double {
        let shape = SystemKeyboard.shape
        if cachedShape != shape {
            cache = positions(for: shape)
            cachedShape = shape
        }
        // An unknown key — one not drawn on this shape — stays centred
        // rather than guessing a side.
        guard let fraction = cache[code] else { return 0 }
        return (fraction - 0.5) * 2 * amount
    }

    /// Each key's horizontal centre, as a fraction of the row's width.
    private static func positions(for shape: SystemKeyboard.Shape) -> [UInt16: Double] {
        var out: [UInt16: Double] = [:]
        for row in KeyboardGeometry.rows(for: shape) {
            let total = row.reduce(0.0) { $0 + $1.width }
            guard total > 0 else { continue }
            var x = 0.0
            for placed in row {
                out[placed.key.code] = (x + placed.width / 2) / total
                x += placed.width
            }
        }
        return out
    }
}
