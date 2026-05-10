import Foundation

enum MeetingTuning {
    static let defaultSnoozeInterval: TimeInterval = 30 * 60
    static let pendingCooldown: TimeInterval = 90
    static let calendarSearchBack: TimeInterval = 5 * 60
    static let calendarSearchForward: TimeInterval = 15 * 60
    static let calendarPromptScoreBack: TimeInterval = 5 * 60
    static let calendarPromptScoreForward: TimeInterval = 5 * 60
    static let calendarReminderPostStartGrace: TimeInterval = 5 * 60
    static let runtimeActivityFreshness: TimeInterval = 5 * 60
    static let promptPollInterval: TimeInterval = 20
    static let promptPollIntervalNanoseconds = UInt64(promptPollInterval * 1_000_000_000)
    static let audioInactivityThreshold: TimeInterval = 5 * 60
    static let audioInactivityCountdown = 30
    static let audioInactivityActiveLevelThreshold: Float = 0.02
    static let detectedMeetingPromptTimeout = 10
}
