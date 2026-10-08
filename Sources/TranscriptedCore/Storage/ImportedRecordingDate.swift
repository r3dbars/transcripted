import AVFoundation
import Foundation

/// When an imported recording was made, for its note date and filename. Shared by
/// the app's "Transcribe a file" (MeetingImportedAudioPreparer) and the CLI's
/// import-audio, so a file gets the same date either way (issue #850): a date the
/// recorder embedded, else a file timestamp that predates the import, else now.
public enum ImportedRecordingDate {
    /// A source timestamp within this window of the import is treated as the copy
    /// or download act rather than the original recording time (issue #850).
    public static let copyDetectionWindow: TimeInterval = 120

    /// Embedded dates before this are treated as malformed/sentinel values — e.g.
    /// the 1904 QuickTime epoch or the 1970 Unix epoch written by buggy encoders —
    /// rather than real recording times (issue #850). 1990-01-01 UTC predates any
    /// consumer digital recorder that embeds creation metadata.
    public static let earliestPlausibleRecordingDate = Date(timeIntervalSince1970: 631_152_000)

    public static func resolve(
        from sourceURL: URL,
        sourceAttributes: [FileAttributeKey: Any],
        now: Date = Date()
    ) async -> Date {
        // Prefer a date the recorder embedded in the file: it describes when the
        // audio was actually captured, which is what an imported note should show.
        // Ignore implausible dates (future, or sentinel/zero values) so a bogus tag
        // never becomes the note date — fall through to the file system instead.
        if let embeddedDate = await embeddedRecordingDate(from: sourceURL),
           isPlausibleEmbeddedDate(embeddedDate, now: now) {
            return embeddedDate
        }

        // Otherwise fall back to the source file's own timestamps, but only when
        // they look like the original recording rather than a copy or download.
        if let filesystemDate = reliableFilesystemDate(
            from: sourceURL,
            sourceAttributes: sourceAttributes,
            now: now
        ) {
            return filesystemDate
        }

        // Last resort (issue #850): creation date unavailable or unreliable, so
        // use the import time.
        return now
    }

    /// Whether an embedded recording date looks like a real capture time. Rejects
    /// sentinel/zero dates written by buggy encoders and anything in the future, so
    /// the resolver falls through to the file system rather than stamping the note
    /// with a bogus date (issue #850).
    public static func isPlausibleEmbeddedDate(_ date: Date, now: Date) -> Bool {
        date >= earliestPlausibleRecordingDate
            && date.timeIntervalSince(now) <= copyDetectionWindow
    }

    /// Best file-system estimate of when the source audio was recorded. Copies,
    /// downloads, and AirDrops only ever push a file's timestamps forward, so the
    /// earliest timestamp is the closest lower bound on the original recording.
    /// Any timestamp inside the import window is the copy act itself and is
    /// discarded as unreliable (issue #850).
    public static func reliableFilesystemDate(
        from sourceURL: URL,
        sourceAttributes: [FileAttributeKey: Any],
        now: Date
    ) -> Date? {
        var candidates: [Date] = []
        if let creationDate = sourceAttributes[.creationDate] as? Date {
            candidates.append(creationDate)
        } else if let resourceDate = try? sourceURL
            .resourceValues(forKeys: [.creationDateKey]).creationDate {
            candidates.append(resourceDate)
        }
        if let modificationDate = sourceAttributes[.modificationDate] as? Date {
            candidates.append(modificationDate)
        }

        return candidates
            .filter { now.timeIntervalSince($0) >= copyDetectionWindow }
            .min()
    }

    public static func embeddedRecordingDate(from sourceURL: URL) async -> Date? {
        let asset = AVURLAsset(url: sourceURL)
        return await embeddedRecordingDate(from: asset)
    }

    public static func embeddedRecordingDate(from asset: AVURLAsset) async -> Date? {
        if let creationDate = try? await asset.load(.creationDate),
           let date = await metadataDate(creationDate) {
            return date
        }

        let metadata = (try? await asset.load(.metadata)) ?? []
        var best: (priority: Int, date: Date)?
        for item in metadata {
            let keyString = metadataKeyString(for: item)
            guard isRecordingDateMetadata(keyString: keyString),
                  let date = await metadataDate(item) else { continue }
            let priority = recordingDatePriority(forKeyString: keyString)
            // Prefer the most explicit creation/recording tag. Earlier code took
            // the globally earliest matched date, which let a stray tag win.
            if let current = best {
                if priority < current.priority
                    || (priority == current.priority && date < current.date) {
                    best = (priority, date)
                }
            } else {
                best = (priority, date)
            }
        }
        return best?.date
    }

    /// Lowercased identifier/key text used to classify a metadata item.
    public static func metadataKeyString(for item: AVMetadataItem) -> String {
        [
            item.identifier?.rawValue,
            item.commonKey?.rawValue,
            item.keySpace?.rawValue,
            item.key.map { String(describing: $0) }
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }

    public static func isRecordingDateMetadata(_ item: AVMetadataItem) -> Bool {
        isRecordingDateMetadata(keyString: metadataKeyString(for: item))
    }

    /// True only for metadata that records when the audio was captured. Dates that
    /// describe something else — store purchase, encode/tagging time, release or
    /// album date — are rejected so they can never become the note date (#850).
    public static func isRecordingDateMetadata(keyString: String) -> Bool {
        let nonRecordingMarkers = [
            "purchase",   // iTunes purchaseDate
            "encod",      // encodedBy / encodingTime / TENC / TSSE
            "tagging",    // TDTG tagging time
            "release",    // TDRL / TDOR / originalReleaseTime / albumReleaseDate
            "publish",
            "album",
            "modif"       // modification date
        ]
        if nonRecordingMarkers.contains(where: keyString.contains) {
            return false
        }

        let recordingMarkers = [
            "creationdate",
            "creation",
            "created",
            "recordingdate",
            "recordingtime",
            "recorded",
            "tdrc"        // ID3v2.4 recording time
        ]
        return recordingMarkers.contains(where: keyString.contains)
    }

    /// Ranks recording-date metadata so an explicit creation tag wins over a looser
    /// recording tag, and both win over anything generic. Lower is better.
    public static func recordingDatePriority(forKeyString keyString: String) -> Int {
        if keyString.contains("creation") || keyString.contains("created") {
            return 0
        }
        if keyString.contains("recording") || keyString.contains("recorded")
            || keyString.contains("tdrc") {
            return 1
        }
        return 2
    }

    public static func metadataDate(
        _ item: AVMetadataItem,
        defaultTimeZone: TimeZone = .current
    ) async -> Date? {
        if let string = try? await item.load(.stringValue),
           let date = parseMetadataDate(string, defaultTimeZone: defaultTimeZone) {
            return date
        }

        if let value = try? await item.load(.value) {
            if let date = value as? Date {
                return date
            }
            if let string = value as? String,
               let date = parseMetadataDate(string, defaultTimeZone: defaultTimeZone) {
                return date
            }
            if let string = value as? NSString,
               let date = parseMetadataDate(String(string), defaultTimeZone: defaultTimeZone) {
                return date
            }
        }

        if let date = try? await item.load(.dateValue) {
            return date
        }

        return nil
    }

    public static func parseMetadataDate(
        _ value: String,
        defaultTimeZone: TimeZone = .current
    ) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ssZ",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        formatter.timeZone = defaultTimeZone
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }
}
