import Foundation

// MARK: - Capture list copy

/// Empty-state copy for the Home capture lists. Foundation-pure constants so the
/// strings can be pinned by fast tests; `HomeView` reads them directly.
enum HomeCaptureListCopy {
    static let emptyMeetings = "No recent meetings. Record one or transcribe an audio file from General."
    static let emptyDictations = "No recent dictations."
}

// MARK: - Day section labels

/// Foundation-pure day-section label derivation for the Home capture lists.
///
/// `HomeViewModel.dayLabel(for:)` maps a day-start `Date` to the section header
/// string ("Today", "Yesterday", or a formatted weekday/date). The decision and
/// formatting live here so they stay testable without SwiftUI; the view model
/// delegates to keep runtime output byte-for-byte identical.
enum HomeDaySectionLabel {
    static func label(for day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return formatter.string(from: day)
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEEE, MMM d"
        return f
    }()
}

// MARK: - Stable feedback reference ids

/// Foundation-pure stable id derivation for Home feedback targets.
///
/// `HomeFeedbackTarget` derives a deterministic short id from a capture's id
/// string via FNV-1a so feedback payloads stay stable without leaking the raw
/// identifier. The hashing lives here so it can be exercised by fast tests; the
/// god-object delegates to keep output identical.
enum HomeStableReferenceID {
    static func id(for value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Meeting speaker palette selection

/// Foundation-pure palette-slot selection for meeting speaker chips.
///
/// `HomeMeetingSpeakerColor.color(for:)` returns a SwiftUI `Color`, but the
/// underlying decision — which stable palette slot a speaker name maps to — is
/// deterministic and Foundation-only. That selection lives here so it can be
/// fast-tested; `color(for:)` keeps the slot -> `Color` mapping in `HomeView`.
enum HomeMeetingSpeakerPalette {
    /// Number of palette slots the speaker-color mapping spreads names across.
    static let slotCount = 8

    /// Stable palette slot index in `0..<slotCount` for a speaker name.
    static func slotIndex(for speaker: String, slotCount: Int = slotCount) -> Int {
        let normalized = speaker.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized.unicodeScalars.reduce(UInt32(0)) { partial, scalar in
            partial &+ scalar.value
        }
        return Int(value % UInt32(slotCount))
    }
}
