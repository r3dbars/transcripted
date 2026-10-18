// PhysicalShortcutTapPolicy.swift
// Foundation/CoreGraphics-pure decisions the physical-shortcut event tap
// uses for its event mask, media-key (NSSystemDefined) handling, Fn-vs-
// modifier mismatch logging, tap-disable recovery logs, and the installed-
// binding snapshot. The CGEventTap class stays in PhysicalShortcutDetector;
// this file is the testable seam so a macOS Fn/media-key change can be
// diagnosed without reading Sources as text.

import CoreGraphics
import Foundation

enum PhysicalShortcutTapPolicy {
    /// `NSEvent.EventType.system` / NX_SYSDEFINED. Play/pause and other
    /// hardware media keys arrive as this instead of keyDown when F-keys
    /// are in media-key mode (F8 is NX_KEYTYPE_PLAY = 16).
    static let systemDefinedEventTypeRawValue: UInt32 = 14

    /// How long to wait before logging the same diagnostic again.
    static let diagnosticLogInterval: TimeInterval = 5

    static var systemDefinedEventType: CGEventType {
        CGEventType(rawValue: systemDefinedEventTypeRawValue)!
    }

    /// Current tap mask: keyDown, keyUp, flagsChanged. Media keys are not
    /// included yet, so a Tahoe F8 that arrives as NSSystemDefined is
    /// invisible to the tap.
    static func eventsOfInterestMask() -> CGEventMask {
        (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
    }

    /// Media-key events must always continue to the rest of the system.
    /// The current tap never sees them, so this is false for every type.
    static func mustPassThrough(eventTypeRawValue: UInt32) -> Bool {
        false
    }

    static func tapDisabledReason(for type: CGEventType) -> String? {
        tapDisabledReason(forEventTypeRawValue: type.rawValue)
    }

    /// Current tap re-enables silently and does not name the reason.
    static func tapDisabledReason(forEventTypeRawValue raw: UInt32) -> String? {
        nil
    }

    static func tapDisabledContext(reason: String, reenabled: Bool) -> [String: String] {
        [:]
    }

    static func installedBindingsContext(_ bindings: [PhysicalShortcutBinding]) -> [String: String] {
        [:]
    }
}

enum PhysicalShortcutMediaKeyPolicy {
    /// NX_KEYTYPE_PLAY. F8 in media-key mode.
    static let playPauseNXKeyType = 16
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS
    static let auxControlButtonsSubtype: Int16 = 8
    static let keyDownState = 0xA
    static let keyUpState = 0xB

    static func parseAuxControl(subtype: Int16, data1: Int) -> (nxKeyType: Int, isKeyDown: Bool)? {
        nil
    }

    static func nxKeyType(forFunctionKey keyCode: UInt32) -> Int? {
        nil
    }

    static func dictationFunctionKeyArrivedAsMediaKey(
        nxKeyType: Int,
        dictationBinding: PhysicalDictationTriggerBinding?
    ) -> Bool {
        false
    }

    static func nxKeyKind(_ nxKeyType: Int) -> String {
        "other"
    }

    static func mediaKeyContext(nxKeyType: Int) -> [String: String] {
        [:]
    }
}

enum PhysicalShortcutModifierMismatchPolicy {
    /// Current tap drops a non-matching F8 silently, including Cmd+F8 on a
    /// saved F8, with no log.
    static func shouldLog(
        saved: PhysicalDictationTriggerBinding,
        keyCode: UInt32,
        modifiers: UInt32
    ) -> Bool {
        false
    }
}

/// Injected-clock rate limit so tests never assert wall-clock time.
struct PhysicalShortcutDiagnosticRateLimiter {
    let interval: TimeInterval
    private var lastAccepted: [String: TimeInterval] = [:]

    init(interval: TimeInterval = PhysicalShortcutTapPolicy.diagnosticLogInterval) {
        self.interval = interval
    }

    mutating func shouldEmit(_ id: String, now: TimeInterval) -> Bool {
        false
    }
}
