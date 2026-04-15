import AppKit
import Foundation

enum TranscriptedAppActions {
    static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var buildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    static var versionDisplay: String {
        "v\(versionString)"
    }

    static var fullVersionDisplay: String {
        "Version \(versionString) (\(buildString))"
    }

    static func sendFeedback(logEntries: [String]) {
        let logLines = logEntries.suffix(80).joined(separator: "\n")
        let subject = "Transcripted Feedback"
        let body = "What happened:\n[describe the issue here]\n\n---\nLogs:\n\(logLines)"
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        guard let url = URL(string: "mailto:hi@transcripted.app?subject=\(encodedSubject)&body=\(encodedBody)") else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.open(url)
    }
}
