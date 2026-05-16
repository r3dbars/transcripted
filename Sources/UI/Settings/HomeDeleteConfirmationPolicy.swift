import Foundation

struct HomeDeleteConfirmationPresentation: Equatable {
    let title: String
    let message: String
    let confirmTitle: String
}

enum HomeDeleteConfirmationPolicy {
    static let meeting = HomeDeleteConfirmationPresentation(
        title: "Delete this meeting?",
        message: "Do you want to delete all of the audio and the transcript that has to do with this meeting? This cannot be undone.",
        confirmTitle: "Delete Meeting"
    )
}
