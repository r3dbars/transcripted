import Foundation

/// Foundation-pure formatter for the "typing time saved" banded rounding used
/// on the Home stats surface. Extracted from `TranscriptedSettingsView` so the
/// 40-wpm banded-rounding rules can be exercised by the fast-test runner.
///
/// Behavior is byte-for-byte identical to the original inline implementation:
/// assumes 40 words-per-minute typing speed, then buckets the resulting hours
/// into "0h" / "<1h" / "X.Xh" / "Xh" bands.
enum TypingTimeSavedFormatter {
    static func format(dictatedWords wordCount: Int) -> String {
        guard wordCount > 0 else { return "0h" }

        let hours = Double(wordCount) / 40.0 / 60.0
        guard hours >= 1 else { return "<1h" }

        if hours < 10 {
            let roundedTenths = (hours * 10).rounded() / 10
            if roundedTenths >= 10 {
                return "\(Int(roundedTenths.rounded()))h"
            }
            return String(format: "%.1fh", roundedTenths)
        }

        return "\(Int(hours.rounded()))h"
    }
}
