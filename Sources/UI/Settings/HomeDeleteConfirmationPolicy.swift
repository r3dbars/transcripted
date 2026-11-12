import Foundation

struct HomeDeleteConfirmationPresentation: Equatable {
    let title: String
    let message: String
    let confirmTitle: String
}

enum HomeDeleteConfirmationPolicy {
    static let failedMeeting = HomeDeleteConfirmationPresentation(
        title: "Delete this failed meeting?",
        message: "This deletes the saved audio for this meeting. This can't be undone.",
        confirmTitle: "Delete Failed Meeting"
    )
}
