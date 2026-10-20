// SpeakerClipExtractor.swift
// Extracts short audio clips per speaker from a source WAV file (mic or system).
// Used by the post-meeting naming flow so users can hear each speaker's voice.

import Darwin
import Foundation
import AVFoundation

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

@available(macOS 14.0, *)
public enum SpeakerClipExtractor {

    /// Extract a short audio clip per speaker from a source WAV file.
    ///
    /// Prefers one turn that fits the 8s write cap so the whole quote can
    /// play. If none fit, writes the longest turn cropped and stores no
    /// quote. Short turns under 3s are glued, longest-first, then time
    /// order. The sidecar is built from the segments that actually produced
    /// bytes, not from turns the writer skipped.
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

        var results: [ClipResult] = []

        for (speakerId, speakerUtterances) in speakerGroups.sorted(by: { $0.key < $1.key }) {
            // Find the persistent ID and profile for this speaker
            guard let firstWithId = speakerUtterances.first(where: { $0.persistentSpeakerId != nil }),
                  let persistentId = firstWithId.persistentSpeakerId else {
                // Speaker has no persistent ID — skip (shouldn't happen but be safe)
                AppLogger.pipeline.warning("Speaker has no persistent ID, skipping clip extraction", ["speakerId": "\(speakerId)", "channel": channel.rawValue])
                continue
            }

            let profile = speakerDB.getSpeaker(id: persistentId)
            let similarity = firstWithId.matchSimilarity

            // Pick the best segment(s) for the clip
            let clipSegments = SpeakerClipSamplePolicy.selectClipSegments(utterances: speakerUtterances)
            let sourceDuration = Double(audioFile.length) / sampleRate
            let written = SpeakerClipSamplePolicy.writtenSegments(
                from: clipSegments,
                sourceDuration: sourceDuration
            )
            guard !written.isEmpty else { continue }

            // Extract audio and write to temp file
            let (clipURL, actuallyWritten) = try writeClip(
                from: audioFile,
                segments: written,
                sampleRate: sampleRate,
                speakerId: speakerId,
                channel: channel,
                clipsDirectory: clipsDirectory
            )
            guard !actuallyWritten.isEmpty else {
                removeClipAndSidecar(at: clipURL, label: "empty speaker clip")
                continue
            }

            let sampleText = SpeakerClipSamplePolicy.sampleText(from: actuallyWritten)
            do {
                var sidecar = SpeakerClipSamplePolicy.sidecar(
                    channel: channel.rawValue,
                    diarizerSpeakerId: String(speakerId),
                    written: actuallyWritten
                )
                if let stamped = sidecar.stamped(withWavAt: clipURL) {
                    sidecar = stamped
                    try sidecar.write(nextTo: clipURL)
                }
            } catch {
                AppLogger.pipeline.warning("Failed to write speaker clip sidecar", [
                    "speakerId": "\(speakerId)",
                    "channel": channel.rawValue,
                    "error": error.localizedDescription
                ])
            }

            results.append(ClipResult(
                clipURL: clipURL,
                persistentSpeakerId: persistentId,
                diarizerSpeakerId: String(speakerId),
                channel: channel,
                sampleText: sampleText,
                matchSimilarity: similarity,
                currentName: profile?.displayName,
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
    /// Writes the wav and sidecar to sibling temp names, then renames them
    /// into place so a failed copy never deletes the previous pair. The
    /// incoming sidecar is kept only when it already matches the source wav;
    /// an unbound sidecar is dropped.
    @discardableResult
    public static func persistClip(
        from tempClipURL: URL,
        speakerId: UUID,
        clipsDirectory: URL = defaultClipsDirectory,
        sidecar: SpeakerClipSidecar? = nil
    ) -> Bool {
        persistLocks.withLock(for: speakerId) {
            persistClipLocked(
                from: tempClipURL,
                speakerId: speakerId,
                clipsDirectory: clipsDirectory,
                sidecar: sidecar
            )
        }
    }

    /// Copy the source profile's clip onto the kept profile. Returns false
    /// when that copy fails so the caller can leave the source in place.
    /// The target-has-clip check and the copy share one ordered lock pair
    /// so a clip that lands on the target cannot be overwritten.
    @discardableResult
    public static func transferOnMerge(
        from sourceId: UUID,
        to targetId: UUID,
        clipsDirectory: URL
    ) -> Bool {
        transferOnMerge(
            from: sourceId,
            to: targetId,
            preferredClipsDirectory: clipsDirectory,
            legacyClipsDirectory: clipsDirectory
        )
    }

    @discardableResult
    public static func transferOnMerge(
        from sourceId: UUID,
        to targetId: UUID,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) -> Bool {
        withOrderedPersistLocks(sourceId, targetId) {
            if persistentClipURL(for: targetId, clipsDirectory: preferredClipsDirectory) != nil
                || persistentClipURL(for: targetId, clipsDirectory: legacyClipsDirectory) != nil {
                return true
            }
            let sourceDirectory: URL
            if persistentClipURL(for: sourceId, clipsDirectory: preferredClipsDirectory) != nil {
                sourceDirectory = preferredClipsDirectory
            } else if persistentClipURL(for: sourceId, clipsDirectory: legacyClipsDirectory) != nil {
                sourceDirectory = legacyClipsDirectory
            } else {
                return true
            }
            let sourceClip = sourceDirectory.appendingPathComponent("\(sourceId.uuidString).wav")
            return persistClipLocked(
                from: sourceClip,
                speakerId: targetId,
                clipsDirectory: preferredClipsDirectory,
                sidecar: nil
            )
        }
    }

    public static var persistLockWillAcquire: ((UUID) -> Void)? {
        get { persistLocks.willAcquire }
        set { persistLocks.willAcquire = newValue }
    }

    public static func withPersistLock(for speakerId: UUID, _ body: () -> Void) {
        persistLocks.withLock(for: speakerId, body)
    }

    private static func withOrderedPersistLocks<T>(
        _ firstId: UUID,
        _ secondId: UUID,
        _ body: () -> T
    ) -> T {
        if firstId == secondId {
            return persistLocks.withLock(for: firstId, body)
        }
        let leading = firstId.uuidString < secondId.uuidString ? firstId : secondId
        let trailing = leading == firstId ? secondId : firstId
        return persistLocks.withLock(for: leading) {
            persistLocks.withLock(for: trailing, body)
        }
    }

    private static func persistClipLocked(
        from tempClipURL: URL,
        speakerId: UUID,
        clipsDirectory: URL,
        sidecar: SpeakerClipSidecar?
    ) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        } catch {
            AppLogger.pipeline.error("Failed to create clips directory", ["error": error.localizedDescription])
            return false
        }

        let dest = clipsDirectory.appendingPathComponent("\(speakerId.uuidString).wav")
        let destSidecar = SpeakerClipSidecar.url(nextTo: dest)
        let partWav = dest.appendingPathExtension("part")
        let partSidecar = destSidecar.appendingPathExtension("part")
        defer {
            try? fileManager.removeItem(at: partWav)
            try? fileManager.removeItem(at: partSidecar)
        }

        do {
            try? fileManager.removeItem(at: partWav)
            try? fileManager.removeItem(at: partSidecar)
            try fileManager.copyItem(at: tempClipURL, to: partWav)
            fileManager.restrictToOwnerOnly(atPath: partWav.path)

            let incoming = SpeakerClipSidecar.acceptedIncoming(
                sidecar ?? SpeakerClipSidecar.load(nextTo: tempClipURL),
                matchingSourceAt: tempClipURL
            )
            if let stamped = incoming?.stamped(withWavAt: partWav) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(stamped).write(to: partSidecar, options: .atomic)
                fileManager.restrictToOwnerOnly(atPath: partSidecar.path)
                // Sidecar first: if the wav rename then fails, the old clip
                // stays and the new sidecar will not match it.
                try replaceItem(at: destSidecar, with: partSidecar)
                try replaceItem(at: dest, with: partWav)
            } else {
                try replaceItem(at: dest, with: partWav)
                try? fileManager.removeItem(at: destSidecar)
            }
            fileManager.restrictToOwnerOnly(atPath: dest.path)
            return true
        } catch {
            AppLogger.pipeline.error("Failed to persist speaker clip", [
                "speakerId": speakerId.uuidString,
                "error": error.localizedDescription
            ])
            return false
        }
    }

    private static func replaceItem(at dest: URL, with part: URL) throws {
        // POSIX rename in the same directory keeps `dest`'s name and, when
        // `dest` already exists, replaces it atomically. `replaceItemAt`
        // can keep the `.part` name instead, which would hide the clip.
        if rename(part.path, dest.path) != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Atomic clip replace failed"]
            )
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
        persistLocks.withLock(for: speakerId) {
            let url = clipsDirectory.appendingPathComponent("\(speakerId.uuidString).wav")
            removeClipAndSidecar(at: url, label: "persisted clip")
        }
    }

    /// Write audio segments to a temporary mono WAV file using frame-level seeking.
    private static func writeClip(
        from audioFile: AVAudioFile,
        segments: [SpeakerClipSamplePolicy.WrittenSegment],
        sampleRate: Double,
        speakerId: Int,
        channel: UtteranceChannel,
        clipsDirectory: URL
    ) throws -> (url: URL, written: [SpeakerClipSamplePolicy.WrittenSegment]) {
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
        var actuallyWritten: [SpeakerClipSamplePolicy.WrittenSegment] = []

        for segment in segments {
            guard totalFramesWritten < maxClipFrames else { break }
            guard segment.start.isFinite, segment.end.isFinite else { continue }

            let rawStartFrame = segment.start * sampleRate
            let rawEndFrame = segment.end * sampleRate
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
            if let recorded = SpeakerClipSamplePolicy.recordedSegment(
                from: segment,
                framesWritten: Int(monoBuffer.frameLength),
                sampleRate: sampleRate
            ) {
                actuallyWritten.append(recorded)
            }
        }

        return (clipURL, actuallyWritten)
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

    public static func removeClipAndSidecar(at url: URL, label: String) {
        let sidecar = SpeakerClipSidecar.url(nextTo: url)
        removeClipFile(url, label: label)
        removeClipFile(url.appendingPathExtension("part"), label: "\(label) wav part")
        removeClipFile(sidecar, label: "\(label) sidecar")
        removeClipFile(sidecar.appendingPathExtension("part"), label: "\(label) sidecar part")
    }

    private static let persistLocks = PersistLockTable()

    private static func removeClipFile(_ url: URL, label: String) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch where ClipRemovalPolicy.isAlreadyGone(error) {
            // Nothing to remove: a speaker's first clip, or a profile that
            // never had one. Not worth a warning on every save.
            return
        } catch {
            AppLogger.pipeline.warning("Failed to remove clip file", [
                "label": label,
                "file": url.lastPathComponent,
                "error": error.localizedDescription
            ])
        }
    }
}

private final class PersistLockTable: @unchecked Sendable {
    private let tableLock = NSLock()
    private var locks: [UUID: NSLock] = [:]
    var willAcquire: ((UUID) -> Void)?

    func withLock<T>(for speakerId: UUID, _ body: () -> T) -> T {
        let lock: NSLock = {
            tableLock.lock()
            defer { tableLock.unlock() }
            if let existing = locks[speakerId] { return existing }
            let created = NSLock()
            locks[speakerId] = created
            return created
        }()
        willAcquire?(speakerId)
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

enum ClipRemovalPolicy {
    /// True when removing a clip failed only because there was no file.
    static func isAlreadyGone(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isAlreadyGone(underlying)
        }
        return false
    }
}
