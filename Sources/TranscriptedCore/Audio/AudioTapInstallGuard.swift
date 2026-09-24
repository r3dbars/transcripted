import AVFoundation
import Foundation
import TranscriptedObjCSupport

/// Turns the Objective-C exception `installTap` raises into a Swift error.
///
/// `-[AVAudioNode installTapOnBus:...]` raises "Failed to create tap due to
/// format mismatch" when the input format moves after the caller read it.
/// AirPods do this when opening their mic flips them to the 24 kHz call
/// profile. Swift cannot catch that exception, so before this guard it
/// crashed the app at meeting or dictation start (Sentry APPLE-MACOS-2K).
/// `ensureMicTapFormatStillMatches` narrows the window but cannot close it:
/// the route can still move between the check and the install.
///
/// The thrown error matches the format check's own error (domain "Audio",
/// code 5), so a caught mismatch takes the same failed-attempt path.
public enum AudioTapInstallGuard {
    public static let errorDomain = "Audio"
    public static let formatMismatchErrorCode = 5

    /// Runs `install`, which must be exactly one `installTap` call.
    public static func run(
        operation: String,
        _ install: () -> Void
    ) throws {
        do {
            try TRNObjCExceptionCatcher.perform(install)
        } catch let caught as NSError {
            AppLogger.audioMic.warning("Microphone tap install raised; treating as a failed attempt", [
                "operation": operation,
                "exception": caught.userInfo[TRNObjCExceptionNameKey] as? String ?? "unknown",
                "reason": caught.localizedDescription
            ])
            throw NSError(
                domain: errorDomain,
                code: formatMismatchErrorCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "The microphone route did not become ready. Check your input device and try again.",
                    NSUnderlyingErrorKey: caught
                ]
            )
        }
    }
}
