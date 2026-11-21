import SwiftUI
import TranscriptedCore

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

// MARK: - Canvas header

struct HomeAttentionIssue: Identifiable {
    enum Destination {
        case failedMeetings
        case speakers
        case privacy
        case models
    }

    let id: String
    let title: String
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
