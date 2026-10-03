import SwiftUI
import TranscriptedCore

struct HomeDaySection<Item>: Identifiable {
    let day: Date
    let label: String
    let items: [Item]

    var id: TimeInterval { day.timeIntervalSinceReferenceDate }
}

enum HomeMeetingListItem: Identifiable {
    case saved(RecentMeetingItem)
    case failed(MeetingSessionController.FailedMeetingItem)

    var id: String {
        switch self {
        case .saved(let item):
            return "saved-\(item.id)"
        case .failed(let item):
            return "failed-\(item.id.uuidString)"
        }
    }

    /// Home's list order and day grouping (imports by import time).
    var date: Date {
        switch self {
        case .saved(let item):
            return item.listDate
        case .failed(let item):
            return item.timestamp
        }
    }
}

struct HomeDeleteConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let perform: () -> Void

    init(
        title: String,
        message: String,
        confirmTitle: String = "Delete",
        perform: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.perform = perform
    }
}

struct HomeDeleteFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let retryTitle: String
    let details: String?
    let retry: () -> Void

    init(
        title: String,
        message: String,
        retryTitle: String = HomeActionFailureCopy.retryTitle,
        details: String? = nil,
        retry: @escaping () -> Void = {}
    ) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.details = details
        self.retry = retry
    }
}

struct HomeMeetingPreview: Identifiable {
    let id: String
    let title: String
    let date: Date
    let transcriptURL: URL
    let audio: MeetingAudioAttachment?
    let markdown: String
    let content: HomeMeetingPreviewContent
    let readError: String?
    let feedbackTarget: HomeFeedbackTarget

    /// Pass `content` when it was already parsed off main (see
    /// `readMeetingMarkdown`); otherwise it's parsed here from `markdown`.
    init(
        item: RecentMeetingItem,
        markdown: String,
        content: HomeMeetingPreviewContent? = nil,
        readError: String? = nil
    ) {
        id = item.id
        title = item.title
        date = item.date
        transcriptURL = item.transcriptURL
        audio = item.audio
        self.markdown = markdown
        self.content = content ?? HomeMeetingPreviewContent.make(from: markdown)
        self.readError = readError
        feedbackTarget = HomeFeedbackTarget.meeting(item)
    }

    private init(
        id: String,
        title: String,
        date: Date,
        transcriptURL: URL,
        audio: MeetingAudioAttachment?,
        markdown: String,
        content: HomeMeetingPreviewContent,
        readError: String?,
        feedbackTarget: HomeFeedbackTarget
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.transcriptURL = transcriptURL
        self.audio = audio
        self.markdown = markdown
        self.content = content
        self.readError = readError
        self.feedbackTarget = feedbackTarget
    }

    /// Returns a copy reflecting a renamed transcript while keeping the stable `id`
    /// so the open preview sheet updates in place instead of dismissing and re-presenting.
    func updatingAfterRename(
        transcriptURL: URL,
        title: String,
        audio: MeetingAudioAttachment?
    ) -> HomeMeetingPreview {
        HomeMeetingPreview(
            id: id,
            title: title,
            date: date,
            transcriptURL: transcriptURL,
            audio: audio,
            markdown: markdown,
            content: content,
            readError: readError,
            feedbackTarget: feedbackTarget
        )
    }

    /// Returns a copy with freshly-read transcript text after an inline speaker edit.
    func updatingMarkdown(
        _ markdown: String,
        content: HomeMeetingPreviewContent? = nil,
        readError: String? = nil
    ) -> HomeMeetingPreview {
        HomeMeetingPreview(
            id: id,
            title: title,
            date: date,
            transcriptURL: transcriptURL,
            audio: audio,
            markdown: markdown,
            content: content ?? HomeMeetingPreviewContent.make(from: markdown),
            readError: readError,
            feedbackTarget: feedbackTarget
        )
    }
}

enum HomeMeetingMarkdownReadResult {
    /// The preview content is parsed on the same background read, so the
    /// main actor only assigns it.
    case success(String, HomeMeetingPreviewContent)
    case failure(String)
}

// MARK: - Canvas header

struct HomeAttentionIssue: Identifiable {
    enum Destination {
        case failedMeetings
        case speakers
        case privacy
        case models
    }

    enum Tone {
        case warning
        case failure

        var color: Color {
            switch self {
            case .warning: return .orange
            case .failure: return .red
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let tone: Tone
    let destination: Destination
}
// MARK: - Activity rows

enum HomeActivityRowFormatting {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        return f
    }()
}
