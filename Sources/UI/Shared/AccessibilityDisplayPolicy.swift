import AppKit
import SwiftUI

/// Small shared policy for honoring the system **Reduce Motion**
/// accessibility setting on Transcripted's main surfaces (the dictation
/// overlay, the meeting overlay, and the Settings window).
///
/// AppKit surfaces read this boolean directly; SwiftUI surfaces can keep
/// using `@Environment(\.accessibilityReduceMotion)`. The helpers here keep
/// the "calm under Reduce Motion" rule in one place instead of being
/// re-derived at each call site.
enum AccessibilityDisplayPolicy {

    /// System "Reduce Motion" preference (System Settings ▸ Accessibility ▸ Display).
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Collapses an animation duration to an instant when Reduce Motion is on,
    /// so the same code path stays calm for users who opt out of motion.
    static func motionDuration(_ duration: TimeInterval) -> TimeInterval {
        reduceMotion ? 0 : duration
    }
}
