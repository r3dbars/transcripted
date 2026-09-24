import AVFoundation
import Foundation

/// A "Record Just My Mic" meeting never builds the system-audio tap. The rest
/// of the meeting flow (speaker review, Home re-transcribe, failed-meeting
/// retries) expects a system track, and the old always-on tap left a silent
/// one. This writes that same silent track without the tap.
///
/// The file is a mono 16-bit WAV at the mic's sample rate, as long as the
/// mic recording. Matching the mic's rate matters: Home's playback mix takes
/// its output rate from the system track, so a lower rate here would play
/// the user's own voice back band-limited. Its sample data is a hole made by
/// extending the file past its header, so on APFS it uses no disk space and
/// takes no time to write, and a Finder copy or `copyItem` clone keeps it
/// sparse.
public enum MicOnlySilentSystemTrack {
    /// Used only when the mic file reports a rate the recorder would never
    /// write.
    public static let fallbackSampleRate = 48_000
    static let bytesPerSample = 2
    static let headerByteCount = 44

    public enum WriteError: Error, Equatable {
        case unreadableMicrophoneAudio
        case destinationExists
        case createFailed
    }

    /// `meeting_<ts>_mic.wav` (or a merged `meeting_<ts>_mic_merged.wav`) →
    /// `meeting_<ts>_system.wav` in the same folder, the name a live tap
    /// would have used, so scratch cleanup treats both tracks alike. A
    /// failed-queue archive's `microphone.wav` gets its `system_audio.wav`.
    public static func destinationURL(forMicrophone micURL: URL) -> URL {
        let directory = micURL.deletingLastPathComponent()
        let stem = micURL.deletingPathExtension().lastPathComponent
        if stem == "microphone" {
            return directory.appendingPathComponent("system_audio.wav")
        }
        let base = stem.range(of: "_mic", options: .backwards).map { String(stem[..<$0.lowerBound]) } ?? stem
        return directory.appendingPathComponent("\(base)_system.wav")
    }

    /// The RIFF size (`data` bytes + 36) is 32 bits, about 12.4 hours at
    /// 48 kHz. A longer mic recording gets a shorter silent track, which the
    /// pipeline accepts.
    static let maxFrames = (Int(UInt32.max) - (headerByteCount - 8)) / bytesPerSample

    /// Writes a silent track as long as `micURL` and returns its URL. Never
    /// overwrites an existing file.
    @discardableResult
    public static func write(
        matching micURL: URL,
        to destinationURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let mic = microphoneDurationAndRate(micURL) else {
            throw WriteError.unreadableMicrophoneAudio
        }
        let url = destinationURL ?? Self.destinationURL(forMicrophone: micURL)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw WriteError.destinationExists
        }
        let sampleRate = Self.sampleRate(matching: mic.sampleRate)
        let frames = min(
            Int((mic.duration * Double(sampleRate)).rounded(.down)),
            maxFrames
        )
        let dataByteCount = frames * bytesPerSample
        guard fileManager.createFile(
            atPath: url.path,
            contents: header(dataByteCount: dataByteCount, sampleRate: sampleRate)
        ) else {
            throw WriteError.createFailed
        }
        fileManager.restrictToOwnerOnly(atPath: url.path)
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            // Growing the file fills the new range with zeros: silent PCM.
            try handle.truncate(atOffset: UInt64(headerByteCount + dataByteCount))
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
        return url
    }

    /// `write(matching:)` for callers that carry on without the track: logs
    /// why it failed (a category, never a path) and returns nil.
    public static func writeIfPossible(matching micURL: URL, fileManager: FileManager = .default) -> URL? {
        do {
            let url = try write(matching: micURL, fileManager: fileManager)
            AppLogger.audioSystem.info("Wrote silent system track for a mic-only recording", [
                "event": "mic_only_silent_system_track_written"
            ])
            return url
        } catch {
            AppLogger.audioSystem.warning("Silent system track for a mic-only recording was not written", [
                "event": "mic_only_silent_system_track_failed",
                "reason": failureReason(error)
            ])
            return nil
        }
    }

    static func failureReason(_ error: Error) -> String {
        switch error as? WriteError {
        case .unreadableMicrophoneAudio: return "unreadable_microphone_audio"
        case .destinationExists: return "destination_exists"
        case .createFailed: return "create_failed"
        case nil: return "extend_failed"
        }
    }

    static func microphoneDurationAndRate(_ micURL: URL) -> (duration: TimeInterval, sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: micURL) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0, file.length >= 0 else { return nil }
        return (duration: Double(file.length) / rate, sampleRate: rate)
    }

    static func sampleRate(matching micSampleRate: Double) -> Int {
        AudioRecordingFormatPolicy.isUsableSampleRate(micSampleRate)
            ? Int(micSampleRate.rounded())
            : fallbackSampleRate
    }

    /// Canonical 44-byte PCM WAV header: mono, 16-bit, `sampleRate`.
    static func header(dataByteCount: Int, sampleRate: Int) -> Data {
        var data = Data(capacity: headerByteCount)
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let blockAlign = UInt16(bytesPerSample)
        append("RIFF")
        append32(UInt32(36 + dataByteCount))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * bytesPerSample))
        append16(blockAlign)
        append16(16)
        append("data")
        append32(UInt32(dataByteCount))
        return data
    }
}
