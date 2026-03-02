// SpeakerClipExtractor.swift
// Extracts short audio clips per speaker from the system WAV file.
// Used by the post-meeting naming flow so users can hear each speaker's voice.

import Foundation
import AVFoundation

/// Result of extracting an audio clip for one speaker
struct ClipResult {
    let clipURL: URL              // temporary WAV file
    let persistentSpeakerId: UUID // from SpeakerDatabase
    let sortformerSpeakerId: String // "0", "1" for transcript matching
    let sampleText: String        // representative transcript quote
    let matchSimilarity: Double?  // cosine similarity from DB match
    let currentName: String?      // display name if known
    let callCount: Int            // how many times this speaker has been seen
}

@available(macOS 14.0, *)
enum SpeakerClipExtractor {

    /// Extract a 5-8 second audio clip per speaker from the system audio WAV.
    ///
    /// For each speaker, picks the longest single utterance (capped at 8s).
    /// If the longest utterance is under 3s, concatenates short utterances up to 8s.
    /// Uses frame-level seeking to avoid loading the entire file into memory.
    ///
    /// - Parameters:
    ///   - systemAudioURL: Path to the system audio WAV file (48kHz native)
    ///   - utterances: System audio utterances from transcription result
    ///   - speakerDB: Speaker database for looking up profiles
    /// - Returns: Array of ClipResults, one per speaker that needs naming/confirmation
    static func extractClips(
        systemAudioURL: URL,
        utterances: [TranscriptionUtterance],
        speakerDB: SpeakerDatabase
    ) throws -> [ClipResult] {

        let audioFile = try AVAudioFile(forReading: systemAudioURL)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate

        guard sampleRate > 0 else {
            throw ClipError.invalidAudioFormat
        }

        // Group utterances by speaker ID
        let speakerGroups = Dictionary(grouping: utterances, by: { $0.speakerId })

        var results: [ClipResult] = []

        for (speakerId, speakerUtterances) in speakerGroups.sorted(by: { $0.key < $1.key }) {
            // Find the persistent ID and profile for this speaker
            guard let firstWithId = speakerUtterances.first(where: { $0.persistentSpeakerId != nil }),
                  let persistentId = firstWithId.persistentSpeakerId else {
                // Speaker has no persistent ID — skip (shouldn't happen but be safe)
                AppLogger.pipeline.warning("Speaker has no persistent ID, skipping clip extraction", ["speakerId": "\(speakerId)"])
                continue
            }

            let profile = speakerDB.getSpeaker(id: persistentId)
            let similarity = firstWithId.matchSimilarity

            // Pick the best segment(s) for the clip
            let clipSegments = selectClipSegments(utterances: speakerUtterances)
            guard !clipSegments.isEmpty else { continue }

            // Extract audio and write to temp file
            let clipURL = try writeClip(
                from: audioFile,
                segments: clipSegments,
                sampleRate: sampleRate,
                speakerId: speakerId
            )

            // Pick a representative text sample (longest utterance text)
            let sampleText = clipSegments
                .max(by: { $0.transcript.count < $1.transcript.count })?
                .transcript ?? ""

            results.append(ClipResult(
                clipURL: clipURL,
                persistentSpeakerId: persistentId,
                sortformerSpeakerId: String(speakerId),
                sampleText: sampleText,
                matchSimilarity: similarity,
                currentName: profile?.displayName,
                callCount: profile?.callCount ?? 1
            ))
        }

        AppLogger.pipeline.info("Extracted speaker clips", ["count": "\(results.count)"])
        return results
    }

    // MARK: - Persistent Clips

    /// Persistent clips directory alongside transcripts
    static var clipsDirectory: URL {
        TranscriptSaver.defaultSaveDirectory.appendingPathComponent("speaker_clips")
    }

    /// Copy a temporary clip to persistent storage, keyed by speaker UUID.
    /// Overwrites any existing clip for this speaker (keeps the latest).
    static func persistClip(from tempClipURL: URL, speakerId: UUID) {
        let dir = clipsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(speakerId.uuidString).wav")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: tempClipURL, to: dest)
    }

    /// Look up persistent clip URL for a speaker. Returns nil if no clip exists.
    static func persistentClipURL(for speakerId: UUID) -> URL? {
        let url = clipsDirectory.appendingPathComponent("\(speakerId.uuidString).wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Delete persistent clip when a speaker profile is removed.
    static func deletePersistedClip(for speakerId: UUID) {
        let url = clipsDirectory.appendingPathComponent("\(speakerId.uuidString).wav")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Temporary Clip Cleanup

    /// Clean up temporary clip files
    static func cleanupClips(_ clips: [ClipResult]) {
        for clip in clips {
            try? FileManager.default.removeItem(at: clip.clipURL)
        }
    }

    static func cleanupClips(_ entries: [SpeakerNamingEntry]) {
        for entry in entries {
            try? FileManager.default.removeItem(at: entry.clipURL)
        }
    }

    // MARK: - Private

    /// Select which utterance segments to use for the clip.
    /// Prefers the single longest segment (cap 8s). Falls back to concatenating
    /// short segments if the longest is under 3s.
    private static func selectClipSegments(utterances: [TranscriptionUtterance]) -> [TranscriptionUtterance] {
        let maxClipDuration: Double = 8.0
        let minPreferredDuration: Double = 3.0

        // Sort by duration descending
        let sorted = utterances.sorted { ($0.end - $0.start) > ($1.end - $1.start) }

        guard let longest = sorted.first else { return [] }
        let longestDuration = longest.end - longest.start

        if longestDuration >= minPreferredDuration {
            // Single segment is long enough — use it (capped at 8s)
            return [longest]
        }

        // Concatenate short segments until we reach target duration
        var selected: [TranscriptionUtterance] = []
        var totalDuration: Double = 0

        for utterance in sorted {
            let duration = utterance.end - utterance.start
            if totalDuration + duration > maxClipDuration { break }
            selected.append(utterance)
            totalDuration += duration
        }

        // Sort by time for natural playback order
        return selected.sorted { $0.start < $1.start }
    }

    /// Write audio segments to a temporary mono WAV file using frame-level seeking.
    private static func writeClip(
        from audioFile: AVAudioFile,
        segments: [TranscriptionUtterance],
        sampleRate: Double,
        speakerId: Int
    ) throws -> URL {

        let tempDir = NSTemporaryDirectory()
        let clipFilename = "speaker_\(speakerId)_\(UUID().uuidString.prefix(8)).wav"
        let clipURL = URL(fileURLWithPath: tempDir).appendingPathComponent(clipFilename)

        // Output format: mono 48kHz (native quality for playback)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ClipError.invalidAudioFormat
        }

        let outputFile = try AVAudioFile(forWriting: clipURL, settings: outputFormat.settings)
        let inputFormat = audioFile.processingFormat
        let maxClipFrames = AVAudioFrameCount(8.0 * sampleRate)
        var totalFramesWritten: AVAudioFrameCount = 0

        for segment in segments {
            guard totalFramesWritten < maxClipFrames else { break }

            let startFrame = AVAudioFramePosition(segment.start * sampleRate)
            let endFrame = AVAudioFramePosition(min(segment.end, segment.start + 8.0) * sampleRate)
            let frameCount = AVAudioFrameCount(endFrame - startFrame)

            guard frameCount > 0, startFrame >= 0, startFrame < audioFile.length else { continue }

            // Clamp to file length
            let actualFrameCount = min(frameCount, AVAudioFrameCount(audioFile.length - startFrame))
            let remainingAllowed = maxClipFrames - totalFramesWritten
            let framesToRead = min(actualFrameCount, remainingAllowed)

            guard framesToRead > 0 else { continue }

            // Seek to segment start
            audioFile.framePosition = startFrame

            // Read frames from source
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: framesToRead) else {
                continue
            }
            try audioFile.read(into: buffer, frameCount: framesToRead)

            // Convert to mono if needed
            let monoBuffer: AVAudioPCMBuffer
            if inputFormat.channelCount > 1 {
                monoBuffer = try mixToMono(buffer: buffer, outputFormat: outputFormat)
            } else if inputFormat.sampleRate != sampleRate {
                // Shouldn't happen for system audio, but be safe
                monoBuffer = buffer
            } else {
                monoBuffer = buffer
            }

            try outputFile.write(from: monoBuffer)
            totalFramesWritten += monoBuffer.frameLength
        }

        return clipURL
    }

    /// Mix a multi-channel buffer down to mono
    private static func mixToMono(buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: buffer.frameLength) else {
            throw ClipError.bufferCreationFailed
        }
        monoBuffer.frameLength = buffer.frameLength

        guard let monoData = monoBuffer.floatChannelData?[0] else {
            throw ClipError.bufferCreationFailed
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)

        // Average all channels
        for frame in 0..<frameCount {
            var sum: Float = 0
            for ch in 0..<channelCount {
                if let channelData = buffer.floatChannelData?[ch] {
                    sum += channelData[frame]
                }
            }
            monoData[frame] = sum / Float(channelCount)
        }

        return monoBuffer
    }

    enum ClipError: LocalizedError {
        case invalidAudioFormat
        case bufferCreationFailed

        var errorDescription: String? {
            switch self {
            case .invalidAudioFormat: return "Invalid audio file format"
            case .bufferCreationFailed: return "Failed to create audio buffer"
            }
        }
    }
}
