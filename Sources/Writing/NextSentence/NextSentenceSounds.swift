import AVFoundation
import Foundation

/// The card's sounds. A sound kit in Application Support (`next-sentence/sounds/kit.json`, one WAV per
/// moment with its level) is used when it's there; otherwise short tones are made on the fly, each with
/// a soft attack and a quick fade. Pitch carries meaning either way: shorter and more direct sit a
/// little higher, cutting words walks the pitch down.
enum NextSentenceSound {
    case open, close
    /// A tone or length step (pad, arrows, Tab). Pitch follows the pad position.
    case step(tone: Int, length: Int)
    /// A word cut or put back with the end handle; `kept` is the share of the message left.
    case trim(kept: Double)
    /// An option rolled in; up is toward the text.
    case roll(up: Bool)
    /// A hold reached full: release now to send, or remix.
    case armed
    case insert, send
    case listenStart, listenStop
    case remix
}

@MainActor
final class NextSentenceSounds {
    static let shared = NextSentenceSounds()

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    /// The kit's own players, each through a varispeed so one file can be pitched up or down.
    private var kitPlayers: [(player: AVAudioPlayerNode, speed: AVAudioUnitVarispeed)] = []
    private var kitNext = 0
    /// Filled in the background by `preload()`; until then the made tones play.
    private var kit: [String: (buffer: AVAudioPCMBuffer, gain: Float)] = [:]

    /// Reads the sound kit off the main thread (it's files on disk), then makes it the card's sounds.
    func preload() {
        Task.detached(priority: .utility) {
            let loaded = NextSentenceSoundKit(sounds: Self.loadKit())
            await MainActor.run { NextSentenceSounds.shared.kit = loaded.sounds }
        }
    }
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
    private var idleStop: DispatchWorkItem?

    private struct Note {
        var frequency: Double
        var duration: Double
        var volume: Double
        var delay: Double = 0
        var triangle = false
    }

    func play(_ sound: NextSentenceSound) {
        guard NextSentencePreferences.soundsEnabled() else { return }
        let (role, rate) = Self.kitRole(for: sound)
        if let sample = kit[role], start(), let pair = kitPlayer(for: sample.buffer.format) {
            pair.speed.rate = rate
            pair.player.volume = sample.gain
            pair.player.scheduleBuffer(sample.buffer, at: nil, options: .interrupts)
            if !pair.player.isPlaying, !engine.outputConnectionPoints(for: pair.player, outputBus: 0).isEmpty { pair.player.play() }
            scheduleIdleStop()
            return
        }
        let notes = Self.notes(for: sound)
        guard let format, let buffer = Self.render(notes, format: format), start() else { return }
        let player = players[next % players.count]
        next += 1
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying, !engine.outputConnectionPoints(for: player, outputBus: 0).isEmpty { player.play() }
        scheduleIdleStop()
    }

    /// The pad's tick walks a full octave from bottom (Full) to top (Tiny), on a pentatonic scale so
    /// every step sounds like a note. Left and right nudge it a semitone: direct a touch brighter.
    static func stepRatio(tone: Int, length: Int) -> Double {
        let scale = [12.0, 9, 7, 4, 0] // Tiny ... Full, in semitones above the bottom note
        let semitones = scale[max(0, min(4, length))] + Double(1 - max(0, min(2, tone)))
        return pow(2, (semitones - 6) / 12) // centered, so the middle of the pad sits near the tick's own pitch
    }

    /// Which kit file plays, and how fast (pitch) for the moments that carry a position.
    private static func kitRole(for sound: NextSentenceSound) -> (String, Float) {
        switch sound {
        case .open: return ("open", 1)
        case .close: return ("close", 1)
        case .step(let tone, let length): return ("step", Float(stepRatio(tone: tone, length: length)))
        case .trim(let kept): return ("trim", 0.8 + 0.4 * Float(max(0, min(1, kept))))
        case .roll(let up): return ("roll", up ? 1.06 : 0.94)
        case .armed: return ("armed", 1)
        case .insert: return ("insert", 1)
        case .send: return ("send", 1)
        case .listenStart: return ("listenStart", 1)
        case .listenStop: return ("listenStop", 1)
        case .remix: return ("remix", 1)
        }
    }

    nonisolated private static func loadKit() -> [String: (buffer: AVAudioPCMBuffer, gain: Float)] {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcripted/next-sentence/sounds", isDirectory: true)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("kit.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        var kit: [String: (buffer: AVAudioPCMBuffer, gain: Float)] = [:]
        for (role, entry) in manifest {
            guard let name = entry["file"] as? String,
                  let file = try? AVAudioFile(forReading: folder.appendingPathComponent(name)),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil else { continue }
            kit[role] = (buffer, Float((entry["gain"] as? Double) ?? 0.3))
        }
        return kit
    }

    private func kitPlayer(for format: AVAudioFormat) -> (player: AVAudioPlayerNode, speed: AVAudioUnitVarispeed)? {
        if kitPlayers.isEmpty {
            for _ in 0..<4 {
                let player = AVAudioPlayerNode()
                let speed = AVAudioUnitVarispeed()
                engine.attach(player)
                engine.attach(speed)
                engine.connect(player, to: speed, format: format)
                engine.connect(speed, to: engine.mainMixerNode, format: format)
                kitPlayers.append((player, speed))
            }
        }
        // All kit files share one format; a file that doesn't falls back to the made tones.
        guard let first = kitPlayers.first, first.player.outputFormat(forBus: 0) == format else { return nil }
        defer { kitNext += 1 }
        return kitPlayers[kitNext % kitPlayers.count]
    }

    private static func notes(for sound: NextSentenceSound) -> [Note] {
        switch sound {
        case .open:
            return [Note(frequency: 523, duration: 0.09, volume: 0.05), Note(frequency: 784, duration: 0.12, volume: 0.045, delay: 0.055)]
        case .close:
            return [Note(frequency: 659, duration: 0.06, volume: 0.035), Note(frequency: 440, duration: 0.09, volume: 0.03, delay: 0.04)]
        case .step(let tone, let length):
            return [Note(frequency: 620 * stepRatio(tone: tone, length: length), duration: 0.035, volume: 0.04, triangle: true)]
        case .trim(let kept):
            return [Note(frequency: 420 + 520 * max(0, min(1, kept)), duration: 0.028, volume: 0.035, triangle: true)]
        case .roll(let up):
            return [Note(frequency: up ? 1_180 : 980, duration: 0.022, volume: 0.04, triangle: true),
                    Note(frequency: up ? 1_480 : 1_240, duration: 0.03, volume: 0.02, delay: 0.018)]
        case .armed:
            return [Note(frequency: 1_100, duration: 0.05, volume: 0.035)]
        case .insert:
            return [Note(frequency: 660, duration: 0.11, volume: 0.045)]
        case .send:
            return [Note(frequency: 988, duration: 0.08, volume: 0.045), Note(frequency: 1_319, duration: 0.12, volume: 0.04, delay: 0.07)]
        case .listenStart:
            return [Note(frequency: 587, duration: 0.07, volume: 0.04), Note(frequency: 880, duration: 0.1, volume: 0.04, delay: 0.06)]
        case .listenStop:
            return [Note(frequency: 880, duration: 0.07, volume: 0.04), Note(frequency: 1_175, duration: 0.11, volume: 0.035, delay: 0.06)]
        case .remix:
            return [Note(frequency: 880, duration: 0.06, volume: 0.035), Note(frequency: 1_109, duration: 0.06, volume: 0.03, delay: 0.045),
                    Note(frequency: 1_319, duration: 0.1, volume: 0.03, delay: 0.09)]
        }
    }

    /// All of a sound's notes mixed into one buffer: a 3ms attack, then an exponential fade.
    private static func render(_ notes: [Note], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let length = notes.map { $0.delay + $0.duration }.max() ?? 0
        let frames = AVAudioFrameCount(length * rate) + 1
        guard frames > 1, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for index in 0..<Int(frames) { samples[index] = 0 }
        for note in notes {
            let start = Int(note.delay * rate)
            let count = Int(note.duration * rate)
            let attack = 0.003 * rate
            for offset in 0..<count where start + offset < Int(frames) {
                let t = Double(offset) / rate
                let phase = note.frequency * t
                let wave = note.triangle ? 2 * abs(2 * (phase - floor(phase + 0.5))) - 1 : sin(2 * .pi * phase)
                let rise = min(1, Double(offset) / attack)
                let fade = exp(-5.5 * Double(offset) / Double(count))
                samples[start + offset] += Float(wave * rise * fade * note.volume)
            }
        }
        return buffer
    }

    private func start() -> Bool {
        if engine.isRunning { return true }
        if players.isEmpty, let format {
            for _ in 0..<4 {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                players.append(player)
            }
        }
        do { try engine.start() } catch { return false }
        return true
    }

    /// The engine only runs while sounds are playing.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.players.forEach { $0.stop() }
            self.kitPlayers.forEach { $0.player.stop() }
            self.engine.stop()
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

/// Hands the loaded kit from the background read to the main actor. Built once and never changed,
/// so passing it across is safe.
struct NextSentenceSoundKit: @unchecked Sendable {
    let sounds: [String: (buffer: AVAudioPCMBuffer, gain: Float)]
}
