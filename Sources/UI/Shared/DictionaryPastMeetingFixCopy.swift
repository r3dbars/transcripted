import Foundation

/// Copy for the line under a correction and its confirm step. Kept out of the
/// SwiftUI file so fast tests can pin it.
enum DictionaryPastMeetingFixCopy {
    static func found(_ meetings: Int) -> String {
        "Also in \(meetingPhrase(meetings, past: true))."
    }

    static func fixAction(_ meetings: Int) -> String {
        meetings == 1 ? "Fix it" : "Fix them"
    }

    static let fixing = "Fixing\u{2026}"
    static let undoing = "Undoing\u{2026}"
    static let undoAction = "Undo"
    static let retryAction = "Try again"

    static func fixed(count: Int, remaining: Int) -> String {
        let fixed = "Fixed \(meetingPhrase(count, past: false))."
        guard remaining > 0 else { return fixed }
        return fixed + " \(remaining) more couldn\u{2019}t be changed yet."
    }

    static func fixOutcomeNote(_ receipt: DictionaryPastMeetingFixReceipt) -> String? {
        guard receipt.fixedCount == 0 else { return nil }
        return receipt.skippedCount > 0
            ? "Couldn\u{2019}t change those meetings. They may be busy or gone."
            : "Those meetings are already fixed."
    }

    static func undone(_ result: DictionaryPastMeetingUndoResult) -> String? {
        var notes: [String] = []
        if result.keptCount > 0 {
            notes.append(result.keptCount == 1
                ? "1 meeting was edited since the fix, so it wasn\u{2019}t undone."
                : "\(result.keptCount) meetings were edited since the fix, so they weren\u{2019}t undone.")
        }
        if result.missingBackupCount > 0 {
            notes.append(result.missingBackupCount == 1
                ? "1 meeting\u{2019}s backup is gone, so it stays fixed."
                : "\(result.missingBackupCount) meetings\u{2019} backups are gone, so they stay fixed.")
        }
        if result.busyCount > 0 {
            notes.append(result.busyCount == 1
                ? "1 meeting was busy, so it wasn\u{2019}t undone yet."
                : "\(result.busyCount) meetings were busy, so they weren\u{2019}t undone yet.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// A fix whose correction is no longer in the list, shown under the list
    /// so it can still be undone.
    static func earlierFix(_ entry: CustomDictionaryEntry, meetings: Int) -> String {
        "Changed \u{201C}\(entry.spoken)\u{201D} to \u{201C}\(entry.replacement)\u{201D} in \(meetings == 1 ? "1 meeting" : "\(meetings) meetings")."
    }

    static func confirmTitle(_ scan: DictionaryPastMeetingScan) -> String {
        "Fix \(meetingPhrase(scan.meetingCount, past: true))?"
    }

    static func confirmMessage(_ entry: CustomDictionaryEntry, scan: DictionaryPastMeetingScan) -> String {
        let spots = scan.spotCount == 1 ? "1 spot" : "\(scan.spotCount) spots"
        return "\u{201C}\(entry.spoken)\u{201D} becomes \u{201C}\(entry.replacement)\u{201D} in \(spots), in any capitalization. Only what was said changes, not titles, names or notes. You can undo this for 3 days."
    }

    static func confirmAction(_ scan: DictionaryPastMeetingScan) -> String {
        "Fix \(meetingPhrase(scan.meetingCount, past: false))"
    }

    private static func meetingPhrase(_ count: Int, past: Bool) -> String {
        let noun = count == 1 ? "meeting" : "meetings"
        return past ? "\(count) past \(noun)" : "\(count) \(noun)"
    }
}
