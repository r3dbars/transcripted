// SpeakerPrintDirectory.swift
// How Settings › Speakers lays out saved people by their voice print: who is
// "Named automatically" (a full, glowing print), who is "Still learning" (a
// partial print plus "One more yes" or "N more"), and the voices nobody has
// named yet that sit outside the open review card. One ring per confirmed
// meeting, so the rings and the words always agree. Foundation-only so the
// fast tests can compile it; the views are SpeakerPeoplePrintSections.swift
// and SpeakerPeoplePersonRow.swift.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum SpeakerPrintDirectory {
    /// The line under the page title.
    static let headerLine = "Confirm a voice in \(SpeakerNamingTierPresentation.segmentCount) meetings and its print fills in. "
        + "Then Transcripted names that person on its own. Voices stay on this Mac."

    enum Section: Equatable, CaseIterable {
        case namedAutomatically
        case stillLearning
        /// Unnamed voices outside the open review card (a skipped call, a
        /// later card, a skipped voice), so they can still be named, merged
        /// or deleted.
        case notNamedYet
    }

    struct Hint: Equatable {
        let text: String
        /// Drawn in the person's print color; otherwise secondary text.
        let usesPersonColor: Bool
    }

    /// What one person's row shows.
    struct Row: Equatable {
        let section: Section
        /// Rings lit in the person's color, innermost first (0...5).
        let litRings: Int
        let hint: Hint?
    }

    /// `standing` is nil for a voice with no name yet.
    static func row(standing: SpeakerNamingStanding?) -> Row {
        guard let standing else {
            return Row(section: .notNamedYet, litRings: 0, hint: nil)
        }
        let lit = SpeakerNamingTierPresentation.filledSegments(
            confirmed: standing.confirmedMeetings,
            required: standing.requiredMeetings,
            tier: standing.tier
        )
        if standing.tier == .auto {
            return Row(section: .namedAutomatically, litRings: lit, hint: nil)
        }
        return Row(section: .stillLearning, litRings: lit, hint: learningHint(standing))
    }

    /// "One more yes" in the person's color when one confirmation is left;
    /// "N more" otherwise. Probation can need several clean confirmations,
    /// so it never promises a fixed number of yeses restores auto-naming.
    private static func learningHint(_ standing: SpeakerNamingStanding) -> Hint {
        guard standing.isTrusted else { return Hint(text: "Keep confirming", usesPersonColor: false) }
        let left = max(0, max(1, standing.requiredMeetings) - max(0, standing.confirmedMeetings))
        if left <= 1 {
            return Hint(text: "One more yes", usesPersonColor: standing.isTrusted && left == 1)
        }
        return Hint(text: "\(left) more", usesPersonColor: false)
    }

    static func title(_ section: Section, count: Int) -> String {
        switch section {
        case .namedAutomatically: return "Named automatically · \(count)"
        case .stillLearning: return "Still learning"
        case .notNamedYet: return "Not named yet"
        }
    }

    /// `items` split into sections in page order, each keeping the order it
    /// came in. Empty sections are left out.
    static func sections<Item>(
        _ items: [Item],
        standing: (Item) -> SpeakerNamingStanding?
    ) -> [(section: Section, items: [Item])] {
        var grouped: [Section: [Item]] = [:]
        for item in items {
            grouped[row(standing: standing(item)).section, default: []].append(item)
        }
        return Section.allCases.compactMap { section in
            guard let members = grouped[section], !members.isEmpty else { return nil }
            return (section, members)
        }
    }

    /// Glowing dots next to "Named automatically": one per person, at most
    /// this many so a long list doesn't push the title off the row.
    static let maximumHeaderDots = 8

    /// The line under a person's name, as the mockup writes it: "14 meetings
    /// · today", "9 meetings · Tuesday" (within the last week), "2 meetings ·
    /// Mar 4" (older), with the year once it isn't this year's.
    static func metaLine(
        meetings: Int,
        lastHeard: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let count = meetings == 1 ? "1 meeting" : "\(max(0, meetings)) meetings"
        return "\(count) · \(lastHeardWord(lastHeard, now: now, calendar: calendar, locale: locale))"
    }

    private static func lastHeardWord(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if daysAgo <= 0 { return "today" }
        if daysAgo == 1 { return "yesterday" }
        let style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if daysAgo < 7 { return date.formatted(style.weekday(.wide)) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(style.month(.abbreviated).day())
        }
        return date.formatted(style.month(.abbreviated).day().year())
    }
}

/// "One more yes" is small text in the person's print color. The palette's
/// dark hexes already read at 4.5:1 on a dark window; its light hexes were
/// tuned for thin strokes on white, which is too faint for 12-point text
/// (Butter is about 3.2:1), so on a light window the text takes a darker
/// shade of the same hue. The rings keep the palette's own hexes.
enum SpeakerPrintTextInk {
    /// `VoicePrintStyle.palette` order: each light hex scaled down until it
    /// reads at 4.5:1 on white, the window and a hovered row.
    static let lightText: [UInt32] = [
        0x664DCA, // Lavender
        0x4158C6, // Periwinkle
        0x0A679C, // Sky
        0x0A6F68, // Lagoon
        0x7B5E00, // Butter
        0x95500B, // Apricot
        0xAE3A30, // Coral
        0xAC3471, // Rose
    ]

    static func hint(colorIndex: Int, dark: Bool) -> VoicePrintRGBA {
        if dark { return VoicePrintInk.personColor(colorIndex: colorIndex, tone: .dark) }
        let count = lightText.count
        return VoicePrintRGBA(hex: lightText[((colorIndex % count) + count) % count])
    }

    /// WCAG 2 contrast ratio between two opaque colors (1 to 21).
    static func contrastRatio(_ first: VoicePrintRGBA, _ second: VoicePrintRGBA) -> Double {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func relativeLuminance(_ color: VoicePrintRGBA) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }
}
