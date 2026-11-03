import Foundation

/// When kept meeting and dictation audio past its window is swept while the
/// app stays open.
///
/// Settings promises "deleted now, and again automatically from then on", but
/// the sweep used to run only at launch, on a settings change, and (meetings
/// only) after a new meeting saved. Transcripted lives in the menu bar and can
/// stay open for weeks, so dictation audio outlived its window until the next
/// quit. The app now asks this policy on a slow timer.
enum AudioRetentionSweepPolicy {
    /// How often an open app sweeps. Retention is counted in days, so a few
    /// hours late is fine, and a sweep only lists two folders.
    static let interval: TimeInterval = 6 * 60 * 60

    /// How often the app asks `isDue`. Cheap: no disk work unless due.
    static let checkInterval: TimeInterval = 60 * 60

    /// False when neither setting can delete anything (meeting Never and
    /// dictation Forever), so there's nothing to sweep.
    static func hasFiniteWindow(
        meeting: AudioRetentionWindow,
        dictation: DictationAudioKeepWindow
    ) -> Bool {
        meeting.days != nil || dictation.days != nil
    }

    static func isDue(
        lastSweep: Date?,
        now: Date,
        meeting: AudioRetentionWindow,
        dictation: DictationAudioKeepWindow
    ) -> Bool {
        guard hasFiniteWindow(meeting: meeting, dictation: dictation) else { return false }
        guard let lastSweep else { return true }
        // A clock set backwards would otherwise stall the sweep until it
        // caught up again.
        if now < lastSweep { return true }
        return now.timeIntervalSince(lastSweep) >= interval
    }
}
