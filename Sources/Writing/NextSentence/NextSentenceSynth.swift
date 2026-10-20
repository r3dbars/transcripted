import AVFoundation
import Foundation

/// The opening's sound system, made in code: a crisp digital chirp when the card opens, a warm pad
/// that slowly opens up like a machine waking while it writes, and a soft startup chord with a bell
/// when the first words arrive. Everything runs through one room reverb so the three feel related.
@MainActor
final class NextSentenceSynth {
    static let shared = NextSentenceSynth()

    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    /// Mono voices meet here; it hands the reverb the stereo it needs.
    private let bus = AVAudioMixerNode()
    private let player = AVAudioPlayerNode()
    private var pad: AVAudioSourceNode?
    private let voice = NextSentencePadVoice()
    private var format: AVAudioFormat?
    private var idleStop: DispatchWorkItem?
    private var chirp: AVAudioPCMBuffer?
    private var chord: AVAudioPCMBuffer?
    private var heardChime: AVAudioPCMBuffer?

    private init() {}

    /// The card opened.
    func press() { play { $0.chirp } }

    /// They let go of fn after saying what the message should say.
    func heard() { play { $0.heardChime } }

    /// The card is waiting for words: the pad swells in. Safe to call again while it plays.
    func startLoading() {
        guard NextSentencePreferences.soundsEnabled(), start() else { return }
        voice.begin()
    }

    /// Stops the pad, and with `ready` plays the startup chord because the words are here.
    func stopLoading(ready: Bool) {
        let wasPlaying = voice.isPlaying
        voice.release()
        if ready && wasPlaying { play { $0.chord } }
        scheduleIdleStop()
    }

    // MARK: Engine

    private func play(_ pick: (NextSentenceSynth) -> AVAudioPCMBuffer?) {
        guard NextSentencePreferences.soundsEnabled(), start(), let buffer = pick(self),
              !engine.outputConnectionPoints(for: player, outputBus: 0).isEmpty else { return }
        player.scheduleBuffer(buffer, at: nil, options: [])
        if !player.isPlaying { player.play() }
        scheduleIdleStop()
    }

    private func start() -> Bool {
        if engine.isRunning { return true }
        if format == nil {
            let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            guard let mono = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 1) else { return false }
            format = mono
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 28
            engine.attach(reverb)
            engine.attach(bus)
            engine.attach(player)
            let voice = voice
            voice.sampleRate = mono.sampleRate
            let pad = AVAudioSourceNode(format: mono) { _, _, frames, list in
                voice.render(frames: Int(frames), into: UnsafeMutableAudioBufferListPointer(list))
                return noErr
            }
            engine.attach(pad)
            self.pad = pad
            // Mono voices into a mixer, stereo from there through the room. (The reverb won't take mono.)
            guard let stereo = AVAudioFormat(standardFormatWithSampleRate: mono.sampleRate, channels: 2) else { return false }
            engine.connect(player, to: bus, fromBus: 0, toBus: 0, format: mono)
            engine.connect(pad, to: bus, fromBus: 0, toBus: 1, format: mono)
            engine.connect(bus, to: reverb, format: stereo)
            engine.connect(reverb, to: engine.mainMixerNode, format: stereo)
            chirp = Self.render(Self.chirpNotes, format: mono)
            chord = Self.render(Self.chordNotes, format: mono)
            heardChime = Self.render(Self.heardNotes, format: mono)
        }
        do { try engine.start() } catch { return false }
        return true
    }

    /// The engine only runs while there's something to hear.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.voice.isPlaying { return self.scheduleIdleStop() }
            self.player.stop()
            self.engine.stop()
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // MARK: The sounds

    struct Note {
        enum Wave { case sine, triangle, square }
        var frequency: Double
        var at: Double = 0
        var duration: Double
        var wave: Wave = .sine
        var gain: Double
        var attack: Double = 0.004
        var glideTo: Double?
        var lowpass: Double?
        /// FM bell: modulator ratio and starting index.
        var bell: (ratio: Double, index: Double)?
    }

    nonisolated static func midi(_ note: Double) -> Double { 440 * pow(2, (note - 69) / 12) }

    /// A short square-wave chirp gliding up, softened by a low-pass filter.
    static let chirpNotes = [Note(frequency: 1_800, duration: 0.05, wave: .square, gain: 0.05, glideTo: 2_600, lowpass: 5_000)]

    /// Two soft bells rising a fifth (G5, D6): "got it".
    static let heardNotes = [
        Note(frequency: midi(79), duration: 0.9, gain: 0.035, attack: 0.004, bell: (3.5, 1.6)),
        Note(frequency: midi(86), at: 0.09, duration: 1.1, gain: 0.03, attack: 0.004, bell: (3.5, 1.8)),
    ]

    /// A soft C major add-9 startup chord, low notes on triangle, with a bell on top.
    static var chordNotes: [Note] {
        var notes = [48.0, 55, 60, 64, 67, 74].enumerated().map { index, note in
            Note(frequency: midi(note), at: Double(index) * 0.02, duration: 2.2, wave: index < 3 ? .triangle : .sine,
                 gain: 0.045, attack: 0.05)
        }
        notes.append(Note(frequency: midi(86), at: 0.12, duration: 1.4, gain: 0.03, bell: (3.5, 2.2)))
        return notes
    }

    /// Mixes the notes into one buffer: attack, then an exponential fade, with optional glide,
    /// low-pass and FM bell.
    static func render(_ notes: [Note], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let length = (notes.map { $0.at + $0.duration }.max() ?? 0) + 0.05
        let frames = AVAudioFrameCount(length * rate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for index in 0..<Int(frames) { out[index] = 0 }
        for note in notes {
            let start = Int(note.at * rate), count = Int(note.duration * rate)
            var phase = 0.0, modPhase = 0.0, low = 0.0
            let alpha = note.lowpass.map { 1 - exp(-2 * Double.pi * $0 / rate) } ?? 1
            for offset in 0..<count where start + offset < Int(frames) {
                let t = Double(offset) / rate
                let progress = min(1, t / (note.duration * 0.9))
                let frequency = note.glideTo.map { note.frequency * pow($0 / note.frequency, progress) } ?? note.frequency
                var sample: Double
                if let bell = note.bell {
                    let index = bell.index / bell.ratio * exp(-5 * t / (note.duration * 0.6))
                    modPhase += frequency * bell.ratio / rate
                    sample = sin(2 * .pi * phase + index * sin(2 * .pi * modPhase))
                } else {
                    switch note.wave {
                    case .sine: sample = sin(2 * .pi * phase)
                    case .triangle: sample = 2 * abs(2 * (phase - floor(phase + 0.5))) - 1
                    case .square: sample = phase.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : -1
                    }
                }
                phase += frequency / rate
                low += alpha * (sample - low)
                let rise = min(1, t / note.attack)
                let fade = t < note.attack ? 1 : exp(-6.9 * (t - note.attack) / max(0.001, note.duration - note.attack))
                out[start + offset] += Float(low * rise * fade * note.gain)
            }
        }
        return buffer
    }
}

/// The waiting pad, made live on the audio thread: six detuned saws (C, G, D) through a low-pass that
/// opens from 280Hz to 2.4kHz over six seconds, with a gentle 3.2Hz tremolo. It swells in over 0.8s
/// and fades over 0.7s when released. Shared with the render thread by design: plain values only.
final class NextSentencePadVoice: @unchecked Sendable {
    var sampleRate = 48_000.0
    private let frequencies: [Double] = [48.0, 55, 62].flatMap { note in
        [-7.0, 7].map { NextSentenceSynth.midi(note) * pow(2, $0 / 1_200) }
    }
    private var phases = [Double](repeating: 0, count: 6)
    private var t = 0.0
    private var releasedAt: Double?
    private var low = 0.0, band = 0.0
    private(set) var isPlaying = false

    func begin() {
        guard !isPlaying || releasedAt != nil else { return }
        t = 0
        releasedAt = nil
        isPlaying = true
    }

    func release() {
        guard isPlaying, releasedAt == nil else { return }
        releasedAt = t
    }

    func render(frames: Int, into list: UnsafeMutableAudioBufferListPointer) {
        guard let data = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        guard isPlaying else {
            for index in 0..<frames { data[index] = 0 }
            return
        }
        let dt = 1 / sampleRate
        for index in 0..<frames {
            var saw = 0.0
            for osc in 0..<phases.count {
                phases[osc] += frequencies[osc] * dt
                if phases[osc] >= 1 { phases[osc] -= 1 }
                saw += 2 * phases[osc] - 1
            }
            let cutoff = 280 * pow(2_400.0 / 280, min(t, 6) / 6)
            let f = 2 * sin(Double.pi * min(cutoff, sampleRate / 6) / sampleRate)
            low += f * band
            let high = saw - low - 1.4 * band
            band += f * high
            let tremolo = 0.65 + 0.35 * sin(2 * .pi * 3.2 * t)
            var envelope = min(1, t / 0.8)
            envelope *= envelope
            if let released = releasedAt {
                let gone = (t - released) / 0.7
                envelope *= max(0, 1 - gone)
                if gone >= 1 { isPlaying = false }
            }
            // Kept quiet on purpose: it sits under everything while it writes.
            data[index] = Float(low * tremolo * envelope * 0.012)
            t += dt
        }
    }
}
