import CoreGraphics
import Foundation

/// Answers "is the screen locked right now?" for the capture-trigger gate.
///
/// macOS has no public, documented API for this. `CGSessionCopyCurrentDictionary`
/// is the same private-but-decade-stable mechanism most lock-state tooling
/// relies on (Apple's own screensaver/loginwindow machinery populates the
/// `CGSSessionScreenIsLocked` key). Because Screen Memory's covenant treats
/// lock state as a hard non-negotiable, this reads the flag fresh on every
/// capture attempt — a snapshot check, not a notification subscription that
/// could be missed if the service started after the lock already engaged.
enum ScreenLockObserver {
    static func isLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            // No session dictionary at all is not the normal signed-in case;
            // fail closed rather than assume unlocked.
            return true
        }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
