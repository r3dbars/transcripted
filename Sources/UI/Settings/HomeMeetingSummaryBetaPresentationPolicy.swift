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

struct HomeLocalSummaryNotice: Identifiable, Equatable {
    let id = UUID()
    let transcriptURL: URL
    let chunkCount: Int

    var title: String { "AI summary saved" }
    var status: String { "Saved" }
    var detail: String {
        let passText = chunkCount == 1 ? "one local Gemma pass" : "\(chunkCount) local Gemma passes"
        return "The meeting Markdown was enhanced with a generated title and summary preview using \(passText)."
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
