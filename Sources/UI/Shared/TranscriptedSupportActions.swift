import AppKit
import Foundation

@MainActor
enum TranscriptedSupportActions {
    static func sendFeedback(logger: AppLogger?) {
        guard let url = feedbackIssueURL(logger: logger) else { return }
        AppSoundPlayer.shared.play(.feedbackSubmitted, respectingPreferences: false)
        NSWorkspace.shared.open(url)
    }

    static func feedbackIssueURL(logger: AppLogger?) -> URL? {
        FeedbackIssueBuilder.issueURL(rawLogLines: logger?.entries)
    }

    static var appVersionDescription: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildVersion) {
        case let (short?, build?) where !short.isEmpty && !build.isEmpty && short != build:
            return "Version \(short) (\(build))"
        case let (short?, _) where !short.isEmpty:
            return "Version \(short)"
        case let (_, build?) where !build.isEmpty:
            return "Build \(build)"
        default:
            return "Version unavailable"
        }
    }
}
