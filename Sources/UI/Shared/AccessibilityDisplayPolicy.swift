import AppKit
import SwiftUI

/// Small shared policy for honoring the system **Reduce Motion** and
/// **Reduce Transparency** accessibility settings on Transcripted's main
/// surfaces (the dictation overlay, the meeting overlay, and the Settings
/// window).
///
/// AppKit surfaces read these booleans directly; SwiftUI surfaces can keep
/// using `@Environment(\.accessibilityReduceMotion)` /
/// `\.accessibilityReduceTransparency`. The helpers here keep the "calm under
/// Reduce Motion, solid under Reduce Transparency" rules in one place instead
/// of being re-derived at each call site.
enum AccessibilityDisplayPolicy {

    /// System "Reduce Motion" preference (System Settings ▸ Accessibility ▸ Display).
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// System "Reduce Transparency" preference.
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// Returns an opaque version of `color` when Reduce Transparency is on,
    /// otherwise the color unchanged. Use for layer backdrops that would
    /// otherwise let the desktop bleed through a translucent panel.
    static func backdropColor(_ color: NSColor) -> NSColor {
        guard reduceTransparency else { return color }
        return (color.usingColorSpace(.deviceRGB) ?? color).withAlphaComponent(1.0)
    }

    /// Collapses an animation duration to an instant when Reduce Motion is on,
    /// so the same code path stays calm for users who opt out of motion.
    static func motionDuration(_ duration: TimeInterval) -> TimeInterval {
        reduceMotion ? 0 : duration
    }
}
