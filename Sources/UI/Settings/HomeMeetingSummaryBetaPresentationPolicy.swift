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
