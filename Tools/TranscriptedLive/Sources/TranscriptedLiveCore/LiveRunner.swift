import AVFoundation
import FluidAudio
import Foundation

/// Follows one speaker's WAV files (the mic can roll over to recovery
/// segments) and feeds whatever is new to that speaker's transcriber.
final class TailedStream {
    let transcriber: StreamTranscriber
    private(set) var files: [URL] = []
    private var tails: [URL: WAVTail] = [:]
    private var index = 0
    private var finishedSeconds: Double = 0

    init(transcriber: StreamTranscriber) {
        self.transcriber = transcriber
    }

    func update(files: [URL]) {
        for file in files where !self.files.contains(file) {
            self.files.append(file)
        }
    }

    /// Seconds of audio consumed across every file so far.
    var audioSeconds: Double {
        guard index < files.count, let tail = tails[files[index]] else { return finishedSeconds }
        return finishedSeconds + tail.secondsRead
    }

    /// Reads and transcribes up to `maxSeconds` of new audio. `isBehind` is true
    /// when a full read came back, i.e. there is more waiting on disk.
    func pump(maxSeconds: Double = 5) async throws -> (utterances: [LiveUtterance], isBehind: Bool) {
        while index < files.count {
            let url = files[index]
            let tail = tails[url] ?? WAVTail(url: url)
            tails[url] = tail

            let maxFrames = Int((tail.format?.sampleRate ?? 48_000) * maxSeconds)
            let start = finishedSeconds + tail.secondsRead
            // Transcripted deletes its temp WAVs once the meeting is saved; a file
            // that vanished, even mid-read, has nothing more to give.
            let read: [Float]?
            do {
                read = try tail.readNewMonoSamples(maxFrames: maxFrames)
            } catch where !FileManager.default.fileExists(atPath: url.path) {
                return ([], false)
            }
            guard let samples = read, let format = tail.format else {
                return ([], false)
            }
            if samples.isEmpty {
                // Nothing new here; a later segment means this file is done.
                guard index + 1 < files.count else { return ([], false) }
                finishedSeconds += tail.secondsRead
                index += 1
                continue
            }
            let utterances = try await transcriber.feed(samples, sampleRate: format.sampleRate, startSeconds: start)
            return (utterances, samples.count >= maxFrames)
        }
        return ([], false)
    }
}

public final class LiveRunner {
    public let output: LiveOutput
    private let you: StreamTranscriber
    private let them: StreamTranscriber
    private let log: (String) -> Void
    private var echo = EchoFilter()

    public init(output: LiveOutput, chunkSize: StreamingChunkSize, pauseMs: Int, log: @escaping (String) -> Void) {
        self.output = output
        self.you = StreamTranscriber(speaker: "you", chunkSize: chunkSize, pauseMs: pauseMs)
        self.them = StreamTranscriber(speaker: "them", chunkSize: chunkSize, pauseMs: pauseMs)
        self.log = log
    }

    public func loadModels() async throws {
        log("loading Parakeet EOU (first run downloads it)…")
        try await you.load()
        try await them.load()
        log("model ready")
    }

    // MARK: - Watch

    /// Waits for Transcripted to start recording a meeting, transcribes it live,
    /// then waits for the next one. Runs until the task is cancelled.
    public func watch(recordingsDirectory: URL, pollSeconds: Double = 0.25) async throws {
        log("watching \(recordingsDirectory.path)")
        var finished = Set<String>()

        while !Task.isCancelled {
            guard let recording = RecordingLocator.liveRecordings(in: recordingsDirectory)
                .last(where: { !finished.contains($0.meetingId) }) else {
                try output.heartbeat()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            do {
                try await follow(recording, pollSeconds: pollSeconds)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One meeting going wrong must not stop the watch for the next one.
                log("meeting stopped early: \(error)")
                try? output.end()
            }
            finished.insert(recording.meetingId)
        }
    }

    private func follow(_ recording: ActiveRecording, pollSeconds: Double) async throws {
        let meetingId = recording.meetingId.hasSuffix("_mic") ? String(recording.meetingId.dropLast(4)) : recording.meetingId
        log("meeting started: \(meetingId)")
        try output.begin(meetingId: meetingId, startedAt: recording.startedAt, title: nil, source: "live")
        echo = EchoFilter()

        let mic = TailedStream(transcriber: you)
        let system = TailedStream(transcriber: them)
        var current = recording
        var lastJournalRead = Date()
        var isOver = false

        while !Task.isCancelled {
            mic.update(files: current.micFiles)
            system.update(files: [current.systemFile].compactMap { $0 })

            let behind = try await pumpAll(mic: mic, system: system)

            if Date().timeIntervalSince(lastJournalRead) >= 1 {
                lastJournalRead = Date()
                if let refreshed = RecordingLocator.read(journalAt: recording.journalURL) {
                    current = refreshed
                    // A journal left behind by a crash stops changing.
                    isOver = refreshed.state != "recording" || Date().timeIntervalSince(refreshed.lastActivity) > 60
                } else {
                    isOver = true
                }
            }
            if isOver, !behind {
                break
            }
            if !behind {
                try await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            }
        }

        // Drain what the recorder wrote last, then close out both speakers.
        while try await pumpAll(mic: mic, system: system) {}
        try route(try await them.flush(atSeconds: system.audioSeconds), micPosition: mic.audioSeconds)
        try route(try await you.flush(atSeconds: mic.audioSeconds), micPosition: mic.audioSeconds)
        try await settle(micPosition: mic.audioSeconds, systemPosition: nil, force: true)
        try output.end()
        log("meeting ended: \(meetingId)\(echoNote)")
    }

    /// One read per stream; returns true while either still has a backlog.
    private func pumpAll(mic: TailedStream, system: TailedStream) async throws -> Bool {
        var behind = false
        for stream in [system, mic] {
            let (utterances, isBehind) = try await stream.pump()
            try route(utterances, micPosition: mic.audioSeconds)
            behind = behind || isBehind
        }
        try await settle(
            micPosition: mic.audioSeconds,
            systemPosition: system.files.isEmpty ? nil : system.audioSeconds
        )
        return behind
    }

    // MARK: - Echo-aware output

    /// System lines go straight out; mic lines wait in the echo filter.
    private func route(_ utterances: [LiveUtterance], micPosition: Double) throws {
        for utterance in utterances {
            if utterance.speaker == "you" {
                echo.holdYou(utterance, micPosition: micPosition)
            } else {
                echo.addThem(utterance)
                try write(utterance)
            }
        }
    }

    /// Releases mic lines that are not echoes and publishes the ghost lines.
    /// `systemPosition` nil means there is no system stream to wait for.
    private func settle(micPosition: Double, systemPosition: Double?, force: Bool = false) async throws {
        let themPartial = await them.partialText()
        for utterance in echo.release(systemPosition: systemPosition, themPartial: themPartial, force: force) {
            try write(utterance)
        }
        var youPartial = await you.partialText()
        if echo.isEcho(youPartial, near: micPosition, extraThem: themPartial) {
            youPartial = ""
        }
        try output.update(
            partials: ["you": youPartial, "them": themPartial],
            audioSeconds: max(micPosition, systemPosition ?? 0)
        )
        try output.heartbeat()
    }

    private var echoNote: String {
        echo.droppedCount > 0 ? " (dropped \(echo.droppedCount) mic lines that echoed the call audio)" : ""
    }

    // MARK: - Replay

    public struct ReplayTrack {
        public let url: URL
        public let speaker: String

        public init(url: URL, speaker: String) {
            self.url = url
            self.speaker = speaker
        }
    }

    /// Plays audio files through the live path as if a meeting were happening,
    /// so the mod can be tried without one. `speed` 0 runs as fast as it can.
    public func replay(_ tracks: [ReplayTrack], speed: Double, title: String?) async throws {
        let files = try tracks.map { try AVAudioFile(forReading: $0.url) }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try output.begin(
            meetingId: "replay_\(stamp)", startedAt: Date(),
            title: title ?? tracks.first?.url.deletingPathExtension().lastPathComponent, source: "replay"
        )
        echo = EchoFilter()
        let micIndex = tracks.firstIndex { $0.speaker == "you" }
        let systemIndex = tracks.firstIndex { $0.speaker != "you" }

        let step = 0.25
        var positions = [Double](repeating: 0, count: files.count)
        var done = [Bool](repeating: false, count: files.count)

        while !done.allSatisfy({ $0 }), !Task.isCancelled {
            for (index, file) in files.enumerated() where !done[index] {
                let rate = file.processingFormat.sampleRate
                guard let samples = try Self.readMono(file, frames: AVAudioFrameCount(rate * step)), !samples.isEmpty else {
                    done[index] = true
                    continue
                }
                let transcriber = tracks[index].speaker == "you" ? you : them
                let utterances = try await transcriber.feed(samples, sampleRate: rate, startSeconds: positions[index])
                positions[index] += Double(samples.count) / rate
                try route(utterances, micPosition: micIndex.map { positions[$0] } ?? 0)
            }
            try await settle(
                micPosition: micIndex.map { positions[$0] } ?? 0,
                systemPosition: systemIndex.map { positions[$0] }
            )
            if speed > 0 {
                try await Task.sleep(nanoseconds: UInt64(step / speed * 1_000_000_000))
            }
        }

        let micPosition = micIndex.map { positions[$0] } ?? 0
        for (index, track) in tracks.enumerated() {
            let transcriber = track.speaker == "you" ? you : them
            try route(try await transcriber.flush(atSeconds: positions[index]), micPosition: micPosition)
        }
        try await settle(micPosition: micPosition, systemPosition: nil, force: true)
        try output.end()
        log("replay finished\(echoNote)")
    }

    private static func readMono(_ file: AVAudioFile, frames: AVAudioFrameCount) throws -> [Float]? {
        // AVAudioFile throws (nilError) on a read at the end instead of reading 0.
        let remaining = file.length - file.framePosition
        guard remaining > 0 else { return [] }
        let frames = AVAudioFrameCount(min(Int64(frames), remaining))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
        try file.read(into: buffer, frameCount: frames)
        let count = Int(buffer.frameLength)
        guard count > 0, let channels = buffer.floatChannelData else { return [] }
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for frame in 0..<count { mono[frame] += data[frame] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for frame in 0..<count { mono[frame] *= scale }
        }
        return mono
    }

    private func write(_ utterance: LiveUtterance) throws {
        try output.append(utterance)
        let minutes = Int(utterance.t) / 60
        let seconds = Int(utterance.t) % 60
        log(String(format: "[%02d:%02d] %@: %@", minutes, seconds, utterance.speaker, utterance.text))
    }
}
