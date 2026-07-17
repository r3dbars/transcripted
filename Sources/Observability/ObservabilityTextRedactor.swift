import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// App-observability adapter over TranscriptedCore's generic text redactor.
///
/// This wrapper intentionally owns the app's existing path-boundary profile.
/// Payload key allowlists and destination-specific metadata rules remain in the
/// local, Sentry, and analytics sanitizers.
enum ObservabilityTextRedactor {
    private static let pathDiagnosticMetadataKeys: Set<String> = [
        "attempt",
        "attempts",
        "code",
        "duration_ms",
        "error",
        "event",
        "failure_kind",
        "operation",
        "outcome",
        "reason",
        "stage",
        "status",
        "trigger",
        "wait_ms",
    ]

    static func redact(_ text: String) -> String {
        PrivacyTextRedactor.redact(
            text,
            pathDiagnosticMetadataKeys: pathDiagnosticMetadataKeys,
            redactEmbeddedAbsolutePaths: true
        )
    }
}
