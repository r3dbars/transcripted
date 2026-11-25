import SwiftUI

// Two small links between Today and the rest of the window: a meeting that's
// recording right now drawn live on today's meetings lane, and the saved
// dictation a Today click should land on.

/// Where a meeting recording right now sits on today's tape, as fractions of
/// the 6 AM to midnight window. Nil when `tapeDay` isn't today.
struct TodayLiveMeetingSpan: Equatable {
    let start: Double
    let end: Double

    static func make(
        elapsedSeconds: Int,
        now: Date,
        tapeDay: Date,
        calendar: Calendar = .current
    ) -> TodayLiveMeetingSpan? {
        guard calendar.isDate(tapeDay, inSameDayAs: now) else { return nil }
        let day = calendar.startOfDay(for: now)
        let started = now.addingTimeInterval(-TimeInterval(max(0, elapsedSeconds)))
        let end = TodayTapeBuilder.fraction(of: now, onDayStarting: day, calendar: calendar)
        let start = TodayTapeBuilder.fraction(of: max(started, day), onDayStarting: day, calendar: calendar)
        return TodayLiveMeetingSpan(start: min(start, end), end: end)
    }
}

/// The growing green bar on today's meetings lane while a meeting records:
/// green because it's live. It reads the shell's `SettingsRecordingClock`,
/// so only this bar redraws, once a second, and only while recording; the
/// day card around it stays put.
struct TodayLiveMeetingMark: View {
    let tapeDay: Date
    let width: CGFloat

    @Environment(SettingsRecordingClock.self) private var clock: SettingsRecordingClock?

    var body: some View {
        let seconds = clock?.wholeSeconds ?? 0
        if let span = TodayLiveMeetingSpan.make(elapsedSeconds: seconds, now: Date(), tapeDay: tapeDay) {
            let barWidth = max(8, width * CGFloat(span.end - span.start))
            Capsule()
                .fill(LibraryTokens.accent)
                .frame(width: barWidth, height: 12)
                .offset(x: min(width * CGFloat(span.start), max(0, width - barWidth)))
                .allowsHitTesting(false)
                .accessibilityLabel("Recording now, \(HomeRecordingElapsed.text(TimeInterval(seconds)))")
                .accessibilityIdentifier("transcripted.today.tape.live-meeting")
        }
    }
}

extension TodayRecentItem {
    /// The saved dictation's own id (`SavedDictationEntry.id`) for a
    /// dictation row, so a click can find it on Dictations. Nil otherwise.
    var dictationEntryID: String? {
        guard kind == .dictation, id.hasPrefix(Self.dictationIDPrefix) else { return nil }
        let entryID = String(id.dropFirst(Self.dictationIDPrefix.count))
        return entryID.isEmpty ? nil : entryID
    }

    /// `TodayViewModel` builds dictation row ids as this prefix plus the entry id.
    static let dictationIDPrefix = "dictation-"
}

/// How long the Dictations page keeps loading older entries to find the one
/// a Today click asked for. Dictations loads in pages of ten; Today reaches
/// back a week, so a busy week can be a few pages down.
enum TodayDictationRevealPolicy {
    static let maximumExtraPages = 30
    static let giveUpAfter: Duration = .seconds(10)
}

/// A dictation the shell is waiting to scroll to, and how many older pages
/// it has loaded looking for it.
struct DictationPendingReveal: Equatable {
    let entryID: String
    var extraPagesLoaded = 0
}
