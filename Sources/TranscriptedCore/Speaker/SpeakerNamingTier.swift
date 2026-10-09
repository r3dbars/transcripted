import Foundation

/// Where a saved person stands on the way to being named on their own, for the
/// New / Learning / Auto dial in the speaker review and Settings › Speakers.
/// A picture of `SpeakerNamingPolicy`'s profile gates, never a gate itself:
///   - auto: confirmed in at least the meetings this context needs and healthy
///     (no recent corrections or disputes), so a clear match is named silently;
///   - learning: confirmed in 2 or more meetings but not there yet, or on
///     probation after a correction;
///   - new: confirmed in 0 or 1 meetings.
/// Silent naming still needs a strong, unambiguous match each time.
public enum SpeakerNamingTier: String, Sendable, Equatable, CaseIterable {
    case new
    case learning
    case auto

    /// Confirmed meetings at which a person leaves `new`.
    public static let learningFrom = 2

    /// `required` is the confirmed-meeting bar for the context: the meeting's
    /// own (2 on a live meeting's lineup, else 5) or
    /// `SpeakerNamingPolicy.requiredConfirmedMeetings` outside a meeting.
    /// `isTrusted` is `SpeakerProfileHealth` == trusted.
    public static func tier(confirmedMeetings: Int, requiredMeetings: Int, isTrusted: Bool) -> SpeakerNamingTier {
        if isTrusted, confirmedMeetings >= max(1, requiredMeetings) { return .auto }
        return confirmedMeetings >= learningFrom ? .learning : .new
    }
}
