import Foundation

enum HomeMeetingSummaryBetaPresentationPolicy {
    static func visibleSummaryPreview(
        for item: RecentMeetingItem,
        isEnabled: Bool
    ) -> RecentMeetingSummaryPreview? {
        isEnabled ? item.summaryPreview : nil
    }

    static func displayTitle(
        for item: RecentMeetingItem,
        isEnabled: Bool
    ) -> String {
        isEnabled ? item.displayTitle : item.title
    }

    static func shouldShowSummarySparkle(
        for item: RecentMeetingItem,
        isEnabled: Bool
    ) -> Bool {
        visibleSummaryPreview(for: item, isEnabled: isEnabled) != nil
    }

    static func shouldShowAvailableSummaryDot(
        for item: RecentMeetingItem,
        isEnabled: Bool
    ) -> Bool {
        isEnabled && item.summaryPreview == nil
    }

    static func shouldShowSummaryMenuActions(isEnabled: Bool) -> Bool {
        isEnabled
    }
}

enum HomeLocalSummaryNoticeKind: Equatable {
    case saved(chunkCount: Int)
    case failed(message: String)
}

struct HomeLocalSummaryNotice: Identifiable, Equatable {
    let id = UUID()
    let transcriptURL: URL
    let meetingTitle: String
    let kind: HomeLocalSummaryNoticeKind

    init(transcriptURL: URL, meetingTitle: String, chunkCount: Int) {
        self.transcriptURL = transcriptURL
        self.meetingTitle = meetingTitle
        self.kind = .saved(chunkCount: chunkCount)
    }

    init(transcriptURL: URL, meetingTitle: String, failureMessage: String) {
        self.transcriptURL = transcriptURL
        self.meetingTitle = meetingTitle
        self.kind = .failed(message: Self.normalizedFailureMessage(failureMessage))
    }

    var title: String {
        isFailure ? "AI summary failed" : "AI summary saved"
    }

    var status: String {
        switch kind {
        case .saved:
            return "Saved"
        case .failed:
            return "Needs retry"
        }
    }

    var actionTitle: String {
        isFailure ? "Retry summary" : "Open enhanced transcript"
    }

    var shouldAutoDismiss: Bool {
        !isFailure
    }

    var isFailure: Bool {
        if case .failed = kind { return true }
        return false
    }

    var detail: String {
        switch kind {
        case .saved(let chunkCount):
            let passText = chunkCount == 1 ? "one local Gemma pass" : "\(chunkCount) local Gemma passes"
            return "The meeting Markdown was enhanced with a generated title and summary preview using \(passText)."
        case .failed(let message):
            return "The local AI summary did not finish: \(message) Nothing was changed. Retry when setup is ready."
        }
    }

    private static func normalizedFailureMessage(_ raw: String) -> String {
        let message = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let fallback = message.isEmpty ? "Check Beta setup, then try again." : message
        let limit = 180
        guard fallback.count > limit else { return fallback }
        let shortened = String(fallback.prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(shortened)..."
    }
}

enum HomeLocalSummaryNoticeDismissalPolicy {
    static let autoDismissDelayNanoseconds: UInt64 = 6_000_000_000

    static func noticeAfterAutoDismiss(
        current: HomeLocalSummaryNotice?,
        scheduledNoticeID: UUID
    ) -> HomeLocalSummaryNotice? {
        shouldDismiss(current: current, scheduledNoticeID: scheduledNoticeID) ? nil : current
    }

    static func shouldDismiss(
        current: HomeLocalSummaryNotice?,
        scheduledNoticeID: UUID
    ) -> Bool {
        current?.id == scheduledNoticeID
    }
}
