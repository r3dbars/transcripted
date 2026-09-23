import AVFoundation
import Foundation

/// A "Record Just My Mic" meeting never builds the system-audio tap. The rest
/// of the meeting flow (speaker review, Home re-transcribe, failed-meeting
/// retries) expects a system track, and the old always-on tap left a silent
/// one. This writes that same silent track without the tap.
///
/// The file is a 16 kHz mono 16-bit WAV as long as the mic recording. Its
/// sample data is a hole made by extending the file past its header, so on
/// APFS it uses no disk space and takes no time to write, and a Finder copy
/// or `copyItem` clone keeps it sparse.
public enum MicOnlySilentSystemTrack {
    public static let sampleRate = 16_000
    static let bytesPerSample = 2
    static let headerByteCount = 44
    /// Keeps the WAV `data` size far below its 4 GiB limit.
    static let maxDurationSeconds: TimeInterval = 24 * 60 * 60

    public enum WriteError: Error, Equatable {
        case unreadableMicrophoneAudio
        case destinationExists
        case createFailed
    }

    /// `meeting_<ts>_mic.wav` → `meeting_<ts>_system.wav` in the same folder,
    /// the name a live tap would have used, so scratch cleanup treats both
    /// tracks alike.
    public static func destinationURL(forMicrophone micURL: URL) -> URL {
        let directory = micURL.deletingLastPathComponent()
        let stem = micURL.deletingPathExtension().lastPathComponent
        let base = stem.hasSuffix("_mic") ? String(stem.dropLast("_mic".count)) : stem
        return directory.appendingPathComponent("\(base)_system.wav")
    }

    /// Writes a silent track as long as `micURL` and returns its URL. Never
    /// overwrites an existing file.
    @discardableResult
    public static func write(
        matching micURL: URL,
        to destinationURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let duration = microphoneDuration(micURL) else {
            throw WriteError.unreadableMicrophoneAudio
        }
        let url = destinationURL ?? Self.destinationURL(forMicrophone: micURL)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw WriteError.destinationExists
        }
        let frames = Int((min(duration, maxDurationSeconds) * Double(sampleRate)).rounded(.down))
        let dataByteCount = frames * bytesPerSample
        guard fileManager.createFile(atPath: url.path, contents: header(dataByteCount: dataByteCount)) else {
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

    static func microphoneDuration(_ micURL: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: micURL) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0, file.length >= 0 else { return nil }
        return Double(file.length) / rate
    }

    /// Canonical 44-byte PCM WAV header: mono, 16-bit, `sampleRate`.
    static func header(dataByteCount: Int) -> Data {
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
