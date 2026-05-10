// SpeakerClipExtractor.swift
// Extracts short audio clips per speaker from a source WAV file (mic or system).
// Used by the post-meeting naming flow so users can hear each speaker's voice.

import Foundation
import AVFoundation
import SQLite3

/// Result of extracting an audio clip for one speaker
struct ClipResult {
    let clipURL: URL              // temporary WAV file
    let persistentSpeakerId: UUID // from SpeakerDatabase
    let diarizerSpeakerId: String // "0", "1" for transcript matching
    let channel: UtteranceChannel // which audio source this clip came from
    let sampleText: String        // representative transcript quote
    let matchSimilarity: Double?  // cosine similarity from DB match
    let currentName: String?      // display name if known
    let callCount: Int            // how many times this speaker has been seen
}

private struct ClipProfileSnapshot {
    let currentName: String?
    let callCount: Int
}

@available(macOS 14.0, *)
public enum SpeakerClipExtractor {

    /// Extract a 5-8 second audio clip per speaker from a source WAV file.
    ///
    /// For each speaker, picks the longest single utterance (capped at 8s).
    /// If the longest utterance is under 3s, concatenates short utterances up to 8s.
    /// Uses frame-level seeking to avoid loading the entire file into memory.
    ///
    /// - Parameters:
    ///   - sourceAudioURL: Path to the source WAV file (mic or system audio)
    ///   - utterances: Utterances from this channel
    ///   - channel: Which channel these utterances came from
    ///   - speakerDB: Speaker database for looking up profiles
    /// - Returns: Array of ClipResults, one per speaker that needs naming/confirmation
    static func extractClips(
        sourceAudioURL: URL,
        utterances: [TranscriptionUtterance],
        channel: UtteranceChannel,
        speakerDB: any SpeakerStore,
        clipsDirectory: URL = defaultClipsDirectory
    ) throws -> [ClipResult] {

        let audioFile = try AVAudioFile(forReading: sourceAudioURL)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate

        guard AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate) else {
            throw ClipError.invalidAudioFormat
        }

        // Group utterances by speaker ID
        let speakerGroups = Dictionary(grouping: utterances, by: { $0.speakerId })
        let profileSnapshots = profileSnapshots(
            for: Set(
                speakerGroups.values.flatMap { group in
                    group.compactMap(\.persistentSpeakerId)
                }
            ),
            speakerDB: speakerDB
        )

        var results: [ClipResult] = []

        for (speakerId, speakerUtterances) in speakerGroups.sorted(by: { $0.key < $1.key }) {
            // Find the persistent ID and profile for this speaker
            guard let firstWithId = speakerUtterances.first(where: { $0.persistentSpeakerId != nil }),
                  let persistentId = firstWithId.persistentSpeakerId else {
                // Speaker has no persistent ID — skip (shouldn't happen but be safe)
                AppLogger.pipeline.warning("Speaker has no persistent ID, skipping clip extraction", ["speakerId": "\(speakerId)", "channel": channel.rawValue])
                continue
            }

            let profile = profileSnapshots[persistentId]
            let similarity = firstWithId.matchSimilarity

            // Pick the best segment(s) for the clip
            let clipSegments = selectClipSegments(utterances: speakerUtterances)
            guard !clipSegments.isEmpty else { continue }

            // Extract audio and write to temp file
            let clipURL = try writeClip(
                from: audioFile,
                segments: clipSegments,
                sampleRate: sampleRate,
                speakerId: speakerId,
                channel: channel,
                clipsDirectory: clipsDirectory
            )

            // Pick a representative text sample (longest utterance text)
            let sampleText = clipSegments
                .max(by: { $0.transcript.count < $1.transcript.count })?
                .transcript ?? ""

            results.append(ClipResult(
                clipURL: clipURL,
                persistentSpeakerId: persistentId,
                diarizerSpeakerId: String(speakerId),
                channel: channel,
                sampleText: sampleText,
                matchSimilarity: similarity,
                currentName: profile?.currentName,
                callCount: profile?.callCount ?? 1
            ))
        }

        AppLogger.pipeline.info("Extracted speaker clips", ["count": "\(results.count)", "channel": channel.rawValue])
        return results
    }

    // MARK: - Persistent Clips

    /// Default persistent clips directory derived from `CoreStoragePaths.default`.
    /// Embedders should pass an explicit `clipsDirectory:` to the persistence helpers
    /// below rather than relying on this default.
    public static var defaultClipsDirectory: URL {
        CoreStoragePaths.default.speakerClips
    }

    /// Copy a temporary clip to persistent storage, keyed by speaker UUID.
    /// Overwrites any existing clip for this speaker (keeps the latest).
    public static func persistClip(
        from tempClipURL: URL,
        speakerId: UUID,
        clipsDirectory: URL = defaultClipsDirectory
    ) {
        let dir = clipsDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            AppLogger.pipeline.error("Failed to create clips directory", ["error": error.localizedDescription])
            return
        }
        let dest = dir.appendingPathComponent("\(speakerId.uuidString).wav")
        removeClipFile(dest, label: "existing persisted clip")
        do {
            try FileManager.default.copyItem(at: tempClipURL, to: dest)
            FileManager.default.restrictToOwnerOnly(atPath: dest.path)
        } catch {
            AppLogger.pipeline.error("Failed to persist speaker clip", ["speakerId": speakerId.uuidString, "error": error.localizedDescription])
        }
    }

    /// Look up persistent clip URL for a speaker. Returns nil if no clip exists.
    public static func persistentClipURL(
        for speakerId: UUID,
        clipsDirectory: URL = defaultClipsDirectory
    ) -> URL? {
        let url = clipsDirectory.appendingPathComponent("\(speakerId.uuidString).wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Delete persistent clip when a speaker profile is removed.
    public static func deletePersistedClip(
        for speakerId: UUID,
        clipsDirectory: URL = defaultClipsDirectory
    ) {
        let url = clipsDirectory.appendingPathComponent("\(speakerId.uuidString).wav")
        removeClipFile(url, label: "persisted clip")
    }

    // MARK: - Private

    private static func profileSnapshots(
        for ids: Set<UUID>,
        speakerDB: any SpeakerStore
    ) -> [UUID: ClipProfileSnapshot] {
        guard !ids.isEmpty else { return [:] }

        if let database = speakerDB as? SpeakerDatabase {
            return database.clipProfileSnapshots(ids: ids)
        }

        return Dictionary(
            uniqueKeysWithValues: speakerDB.allSpeakers()
                .filter { ids.contains($0.id) }
                .map {
                    (
                        $0.id,
                        ClipProfileSnapshot(currentName: $0.displayName, callCount: $0.callCount)
                    )
                }
        )
    }

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
        speakerId: Int,
        channel: UtteranceChannel,
        clipsDirectory: URL
    ) throws -> URL {
        guard AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate) else {
            throw ClipError.invalidAudioFormat
        }

        let tempDir = clipsDirectory
        // Security: keep temporary speaker clips inside Transcripted's owner-only
        // app tmp directory instead of the process-wide temp folder, so sensitive
        // voice samples do not spill into a broader shared scratch location.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        FileManager.default.restrictDirectoryToOwnerOnly(atPath: tempDir.path)
        let clipFilename = "speaker_\(channel.rawValue)_\(speakerId)_\(UUID().uuidString.prefix(8)).wav"
        let clipURL = tempDir.appendingPathComponent(clipFilename)

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
        FileManager.default.restrictToOwnerOnly(atPath: clipURL.path)
        let inputFormat = audioFile.processingFormat
        let maxClipFrames = AVAudioFrameCount(8.0 * sampleRate)
        var totalFramesWritten: AVAudioFrameCount = 0

        for segment in segments {
            guard totalFramesWritten < maxClipFrames else { break }
            guard segment.start.isFinite, segment.end.isFinite else { continue }

            let rawStartFrame = segment.start * sampleRate
            let rawEndFrame = min(segment.end, segment.start + 8.0) * sampleRate
            guard rawStartFrame.isFinite,
                  rawEndFrame.isFinite,
                  rawStartFrame >= 0,
                  rawStartFrame <= Double(AVAudioFramePosition.max),
                  rawEndFrame <= Double(AVAudioFramePosition.max),
                  rawEndFrame > rawStartFrame else {
                continue
            }

            let rawFrameCount = rawEndFrame - rawStartFrame
            guard rawFrameCount <= Double(AVAudioFrameCount.max) else { continue }

            let startFrame = AVAudioFramePosition(rawStartFrame)
            let frameCount = AVAudioFrameCount(rawFrameCount)

            guard frameCount > 0, startFrame >= 0, startFrame < audioFile.length else { continue }

            // Clamp to file length
            let availableFrames = min(audioFile.length - startFrame, AVAudioFramePosition(AVAudioFrameCount.max))
            let actualFrameCount = min(frameCount, AVAudioFrameCount(availableFrames))
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

    private static func removeClipFile(_ url: URL, label: String) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLogger.pipeline.warning("Failed to remove clip file", [
                "label": label,
                "file": url.lastPathComponent,
                "error": error.localizedDescription
            ])
        }
    }
}

@available(macOS 14.0, *)
private extension SpeakerDatabase {
    func clipProfileSnapshots(ids: Set<UUID>) -> [UUID: ClipProfileSnapshot] {
        guard !ids.isEmpty else { return [:] }

        return queue.sync {
            guard isDatabaseOpen else { return [:] }

            let sortedIds = ids.map(\.uuidString).sorted()
            let placeholders = Array(repeating: "?", count: sortedIds.count).joined(separator: ",")
            let sql = """
            SELECT id, display_name, call_count
            FROM speakers
            WHERE id IN (\(placeholders));
            """
            var statement: OpaquePointer?
            var snapshots: [UUID: ClipProfileSnapshot] = [:]

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                for (index, idString) in sortedIds.enumerated() {
                    sqlite3_bind_text(statement, Int32(index + 1), (idString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                }

                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let idPtr = sqlite3_column_text(statement, 0) else { continue }
                    let idString = String(cString: idPtr)
                    guard let id = UUID(uuidString: idString) else {
                        AppLogger.speakers.warning("Skipping corrupt speaker UUID during clip profile lookup", ["raw_id": idString])
                        continue
                    }

                    snapshots[id] = ClipProfileSnapshot(
                        currentName: sqlite3_column_text(statement, 1).map { String(cString: $0) },
                        callCount: Int(sqlite3_column_int(statement, 2))
                    )
                }
            } else {
                AppLogger.speakers.error("Failed to prepare clip profile lookup", ["sqlite_error": dbErrorMessage()])
            }

            sqlite3_finalize(statement)
            return snapshots
        }
    }
}
