import AVFoundation
import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

extension MeetingAudioStorageManager {
    private static let frontmatterPreviewByteLimit = 64 * 1024

    static func audioArchiveDirectoriesWithTranscripts(
        in meetingsFolder: URL,
        fileManager: FileManager
    ) -> [(directory: URL, transcript: TranscriptInfo)] {
        let audioRoot = meetingsFolder.appendingPathComponent("audio", isDirectory: true)
        guard isSafeNonSymlinkDirectory(audioRoot, fileManager: fileManager) else { return [] }
        guard let directories = try? fileManager.contentsOfDirectory(
            at: audioRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories.compactMap { directory in
            guard isAudioArchiveDirectory(directory, fileManager: fileManager),
                  let transcript = transcriptInfo(
                      forAudioDirectory: directory,
                      meetingsFolder: meetingsFolder,
                      fileManager: fileManager
                  ) else { return nil }
            return (directory, transcript)
        }
    }

    private static func isAudioArchiveDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.lastPathComponent.hasSuffix("_audio") else { return false }
        return isSafeNonSymlinkDirectory(url, fileManager: fileManager)
    }

    struct TranscriptInfo {
        let referenceDate: Date
        let captureID: UUID
        /// Starred meetings keep their audio past the retention window.
        let isStarred: Bool
    }

    static func transcriptInfo(
        forAudioDirectory audioDirectory: URL,
        meetingsFolder: URL,
        fileManager: FileManager
    ) -> TranscriptInfo? {
        let name = audioDirectory.lastPathComponent
        guard name.hasSuffix("_audio") else { return nil }
        let stem = String(name.dropLast("_audio".count))
        let transcriptURL = meetingsFolder.appendingPathComponent(stem).appendingPathExtension("md")
        guard fileManager.fileExists(atPath: transcriptURL.path),
              let properties = try? transcriptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              properties.isRegularFile == true, properties.isSymbolicLink != true else { return nil }
        guard let raw = try? previewString(at: transcriptURL),
              let values = transcriptedMeetingFrontmatterValues(raw),
              let captureID = TranscriptFrontmatter.captureID(in: values) else {
            return nil
        }

        return TranscriptInfo(
            referenceDate: transcriptReferenceDate(for: transcriptURL, raw: raw),
            captureID: captureID,
            isStarred: MeetingStarFrontmatter.isStarred(values: values)
        )
    }

    private static func previewString(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try autoreleasepool(invoking: { try handle.read(upToCount: frontmatterPreviewByteLimit) }) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The frontmatter of an app-owned meeting transcript, or nil for any
    /// other Markdown.
    private static func transcriptedMeetingFrontmatterValues(_ raw: String) -> [String: String]? {
        guard raw.contains("\n## Full Transcript") || raw.contains("\n## Transcript"),
              let values = TranscriptFrontmatter.values(in: raw),
              values["capture_type"]?.lowercased() == "meeting" else {
            return nil
        }

        guard isValidTranscriptIdentifier(values["transcript_id"])
            || isValidTranscriptIdentifier(values["capture_id"]) else {
            return nil
        }
        return values
    }

    private static func transcriptReferenceDate(for url: URL, raw: String) -> Date {
        if let frontmatterDate = TranscriptFrontmatter.recordedAt(in: raw) {
            return frontmatterDate
        }

        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    private static func isValidTranscriptIdentifier(_ value: String?) -> Bool {
        guard let value else { return false }
        return UUID(uuidString: value) != nil
    }
}
