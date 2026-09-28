// Support/SpeakerSeparationPreferences.swift
// Preference flag for "split generously, then merge smartly" on the call channel.
//
// When enabled, each live meeting runs the offline diarizer at a higher clustering
// threshold and then folds near-silent voices, merges look-alike voices, and caps
// the voice count at the calendar invite size (SpeakerSeparation.swift in Core).
// Tuned in the YODAS3 speaker lab (Tools/SpeakerEvalHarness/YODAS_LAB_RESULTS.md).
//
// Shipped default-off so it rolls out behind a toggle. Flip the default once it
// holds up on real meetings.

import Foundation

enum SpeakerSeparationPreferences {

    private static let enabledKey = "speaker-separation-v2-enabled"

    /// Whether live meetings use the lab-tuned speaker separation. Default: false.
    static func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}
