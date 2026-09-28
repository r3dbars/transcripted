// Support/CalendarNamingPreferences.swift
// Preference flag for calendar naming.
//
// When enabled, a voice whose best match is someone expected in the meeting is
// named silently after 2 confirmed meetings instead of 5, at slightly lower
// similarity bars (SpeakerNamingPolicy.InviteeBars in Core). "Expected" means on
// the calendar invite, or, for calls with no invite, one of the 12 people heard
// most recently. Tuned in the YODAS3 speaker lab
// (Tools/SpeakerEvalHarness/YODAS_LAB_RESULTS.md).
//
// Shipped default-off so it rolls out behind a toggle.

import Foundation

enum CalendarNamingPreferences {

    private static let enabledKey = "calendar-naming-enabled"

    /// Whether meetings name expected people sooner. Default: false.
    static func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}
