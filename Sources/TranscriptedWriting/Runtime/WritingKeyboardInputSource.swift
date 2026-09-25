#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Carbon
import Foundation

/// Turns the keyboard on in Input Sources. Tilde's installer registers and
/// selects the keyboard but never enables it, so Tilde users added it by
/// hand in System Settings (docs/writing-plan.md, "Permissions").
///
/// Call it on the main thread, right after
/// `GhostKeyboardInstallerHost.installOrUpdateIfNeeded()` succeeded: that
/// call validated the installed bundle's signature and registered it, and
/// this looks the source up by that same identifier.
enum WritingKeyboardInputSource {
    enum EnableResult: Equatable, Sendable {
        /// `TISEnableInputSource` returned `noErr`.
        case enabled
        case alreadyEnabled
        /// No registered input source has this identifier.
        case notRegistered
        /// `TISEnableInputSource` returned this status.
        case failed(OSStatus)
    }

    static func enable(
        inputSourceID: String = TildeProductProfile.current.inputMethodBundleIdentifier
    ) -> EnableResult {
        guard let sources = TISCreateInputSourceList(
            [kTISPropertyInputSourceID: inputSourceID] as CFDictionary,
            true
        )?.takeRetainedValue() as? [TISInputSource],
              sources.count == 1,
              let source = sources.first,
              stringProperty(kTISPropertyBundleID, of: source) == inputSourceID else {
            return .notRegistered
        }
        if booleanProperty(kTISPropertyInputSourceIsEnabled, of: source) { return .alreadyEnabled }
        let status = TISEnableInputSource(source)
        return status == noErr ? .enabled : .failed(status)
    }

    private static func stringProperty(_ key: CFString, of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func booleanProperty(_ key: CFString, of source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue() == kCFBooleanTrue
    }
}
