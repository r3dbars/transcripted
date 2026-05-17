import Foundation

enum MeetingSessionUIPolicy {
    static func shouldShowTranscribing(
        activeTranscriptions: Int,
        queuedTranscriptions: Int
    ) -> Bool {
        activeTranscriptions > 0 || queuedTranscriptions > 0
    }

    static func canStartQueuedTranscription(
        activeTranscriptions: Int,
        isPreparingQueuedTranscriptionStart: Bool
    ) -> Bool {
        activeTranscriptions == 0
            && !isPreparingQueuedTranscriptionStart
    }

    static func shouldClearTranscriptionTriggerAfterBackgroundWork(
        hasTerminalOutcome: Bool
    ) -> Bool {
        hasTerminalOutcome
    }
}

enum MeetingRecordingTitlePolicy {
    static func resolve(explicitTitle: String?, calendarTitle: String?) -> String? {
        normalized(explicitTitle) ?? normalized(calendarTitle)
    }

    static func normalized(_ title: String?) -> String? {
        guard let title else { return nil }
        let normalized = title
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
