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
/// The thrown error has the format check's message, so a caught mismatch
/// takes the same failed-attempt path. Its code differs (12, not the check's
/// 5) so field logs can tell a caught raise from a pre-check rejection.
public enum AudioTapInstallGuard {
    public static let errorDomain = "Audio"
    /// Nothing branches on "Audio" error codes; this only marks the source.
    public static let tapInstallRaisedErrorCode = 12

    /// True for the error `run` throws after catching a raise.
    public static func isTapInstallRaise(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == errorDomain && nsError.code == tapInstallRaisedErrorCode
    }

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
                code: tapInstallRaisedErrorCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "The microphone route did not become ready. Check your input device and try again.",
                    NSUnderlyingErrorKey: caught
                ]
            )
        }
    }
}
