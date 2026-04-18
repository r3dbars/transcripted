import AppKit
import Foundation

@MainActor
enum TranscriptedSupportActions {
    static func sendFeedback(logger: AppLogger?) {
        let rawLogLines = logger?.entries.suffix(80).joined(separator: "\n") ?? "No in-app logs attached."
        let logLines = AnalyticsPayloadSanitizer.redact(rawLogLines)
        let title = "Transcripted Feedback"
        let body = """
        What happened:
        [describe the issue here]

        ---
        Logs:
        \(logLines)
        """

        var components = URLComponents(string: "https://github.com/r3dbars/transcripted/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body)
        ]

        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
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
