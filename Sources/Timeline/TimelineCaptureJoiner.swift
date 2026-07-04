import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum TimelineCaptureKind: String, Sendable {
    case meeting
    case dictation
}

struct TimelineCaptureCard: Equatable, Sendable {
    let kind: TimelineCaptureKind
    let captureID: String
    let day: String
    let start: Date
    let end: Date
    let title: String
    let summary: String
    let category: String
    let sourceURL: URL
    let sourceModifiedAt: Date?
    let needsSpeakerReview: Bool
}

protocol TimelineCaptureProjectionStore: Sendable {
    func existingCaptureIDs(for kind: TimelineCaptureKind) -> Set<String>
    func upsert(_ cards: [TimelineCaptureCard])
    func removeCaptureIDs(_ captureIDs: Set<String>, kind: TimelineCaptureKind)
}

struct TimelineCaptureJoinResult: Equatable {
    let upserted: Int
    let removed: Int
    let scanned: Int
}

enum TimelineCaptureJoiner {
    static let meetingsCategory = "Meetings"
    private static let dictationGapSeconds: TimeInterval = 15 * 60
    private static let dictationDefaultDuration: TimeInterval = 60
    private static let scanLimit = 10_000

    static func loadCards(
        meetingDirectory: URL? = nil,
        dictationDirectory: URL? = nil,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [TimelineCaptureCard] {
        meetingCards(directory: meetingDirectory, calendar: calendar)
            + dictationCards(directory: dictationDirectory, calendar: calendar)
    }

    @discardableResult
    static func refresh(
        store: TimelineCaptureProjectionStore,
        meetingDirectory: URL? = nil,
        dictationDirectory: URL? = nil,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> TimelineCaptureJoinResult {
        let cards = loadCards(
            meetingDirectory: meetingDirectory,
            dictationDirectory: dictationDirectory,
            calendar: calendar
        )
        let meetingIDs = Set(cards.filter { $0.kind == .meeting }.map(\.captureID))
        let dictationIDs = Set(cards.filter { $0.kind == .dictation }.map(\.captureID))
        let staleMeetingIDs = store.existingCaptureIDs(for: .meeting).subtracting(meetingIDs)
        let staleDictationIDs = store.existingCaptureIDs(for: .dictation).subtracting(dictationIDs)

        store.upsert(cards)
        store.removeCaptureIDs(staleMeetingIDs, kind: .meeting)
        store.removeCaptureIDs(staleDictationIDs, kind: .dictation)

        return TimelineCaptureJoinResult(
            upserted: cards.count,
            removed: staleMeetingIDs.count + staleDictationIDs.count,
            scanned: cards.count
        )
    }

    static func observeCaptureLibraryChanges(
        store: TimelineCaptureProjectionStore,
        meetingDirectory: URL? = nil,
        dictationDirectory: URL? = nil,
        notificationCenter: NotificationCenter = .default
    ) -> TimelineCaptureJoinObserver {
        TimelineCaptureJoinObserver(
            store: store,
            meetingDirectory: meetingDirectory,
            dictationDirectory: dictationDirectory,
            notificationCenter: notificationCenter
        )
    }

    private static func meetingCards(
        directory: URL?,
        calendar: Calendar
    ) -> [TimelineCaptureCard] {
        RecentMeetingsScanner.loadRecent(
            limit: scanLimit,
            directory: directory,
            cache: nil
        ).compactMap { item in
            guard let markdown = try? String(contentsOf: item.transcriptURL, encoding: .utf8),
                  let document = TranscriptFrontmatter.document(in: markdown) else {
                return nil
            }
            let values = document.values
            guard let captureID = TranscriptFrontmatter.captureID(in: values)?.uuidString else {
                return nil
            }

            let start = item.startDate
                ?? TranscriptFrontmatter.recordedAt(values: values)
                ?? item.date
            let duration = TranscriptFrontmatter.durationSeconds(from: values["duration"]).map(TimeInterval.init)
            let end = item.endDate
                ?? duration.map { start.addingTimeInterval(max($0, dictationDefaultDuration)) }
                ?? start.addingTimeInterval(dictationDefaultDuration)

            return TimelineCaptureCard(
                kind: .meeting,
                captureID: captureID,
                day: TimelineDayBoundary.day(for: start, calendar: calendar),
                start: start,
                end: maxDate(end, start.addingTimeInterval(dictationDefaultDuration)),
                title: item.displayTitle,
                summary: meetingSummary(from: item.summaryPreview),
                category: meetingsCategory,
                sourceURL: item.transcriptURL,
                sourceModifiedAt: modifiedDate(of: item.transcriptURL),
                needsSpeakerReview: item.speakerStatus.needsReview
            )
        }
    }

    private static func dictationCards(
        directory: URL?,
        calendar: Calendar
    ) -> [TimelineCaptureCard] {
        let entries = DictationTranscriptStore.recentSavedDictations(
            limit: scanLimit,
            directory: directory
        ).sorted { $0.createdAt < $1.createdAt }

        var bursts: [[SavedDictationEntry]] = []
        for entry in entries {
            guard let lastBurst = bursts.last,
                  let previous = lastBurst.last,
                  entry.createdAt.timeIntervalSince(previous.createdAt) <= dictationGapSeconds,
                  entry.url == previous.url else {
                bursts.append([entry])
                continue
            }
            bursts[bursts.count - 1].append(entry)
        }

        return bursts.compactMap { burst in
            guard let first = burst.first, let last = burst.last else { return nil }
            let start = first.createdAt
            let end = maxDate(
                last.createdAt.addingTimeInterval(dictationDefaultDuration),
                start.addingTimeInterval(dictationDefaultDuration)
            )
            let title = burst.count == 1 ? first.title : "\(burst.count) dictations"
            return TimelineCaptureCard(
                kind: .dictation,
                captureID: dictationBurstID(for: burst),
                day: TimelineDayBoundary.day(for: start, calendar: calendar),
                start: start,
                end: end,
                title: title,
                summary: dictationSummary(for: burst),
                category: meetingsCategory,
                sourceURL: first.url,
                sourceModifiedAt: modifiedDate(of: first.url),
                needsSpeakerReview: false
            )
        }
    }

    private static func meetingSummary(from preview: RecentMeetingSummaryPreview?) -> String {
        guard let summary = preview?.summary.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return "Meeting transcript saved."
        }
        return summary
    }

    private static func dictationBurstID(for entries: [SavedDictationEntry]) -> String {
        let ids = entries.map { entry in
            entry.entryID ?? "\(Int(entry.createdAt.timeIntervalSince1970))"
        }
        return "dictation:\(ids.first ?? "unknown"):\(ids.last ?? "unknown"):\(ids.count)"
    }

    private static func dictationSummary(for entries: [SavedDictationEntry]) -> String {
        let text = entries
            .map(\.text)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 280 else { return text }
        let index = text.index(text.startIndex, offsetBy: 280)
        return String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func modifiedDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func maxDate(_ lhs: Date, _ rhs: Date) -> Date {
        lhs >= rhs ? lhs : rhs
    }
}

final class TimelineCaptureJoinObserver {
    private let notificationCenter: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(
        store: TimelineCaptureProjectionStore,
        meetingDirectory: URL?,
        dictationDirectory: URL?,
        notificationCenter: NotificationCenter = .default
    ) {
        self.notificationCenter = notificationCenter

        let refresh: @Sendable () -> Void = {
            _ = TimelineCaptureJoiner.refresh(
                store: store,
                meetingDirectory: meetingDirectory,
                dictationDirectory: dictationDirectory
            )
        }

        tokens.append(
            notificationCenter.addObserver(
                forName: .meetingCaptureArtifactsDidChange,
                object: nil,
                queue: nil
            ) { _ in refresh() }
        )
        tokens.append(
            notificationCenter.addObserver(
                forName: .dictationTranscriptDidSave,
                object: nil,
                queue: nil
            ) { _ in refresh() }
        )
    }

    deinit {
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
    }
}
