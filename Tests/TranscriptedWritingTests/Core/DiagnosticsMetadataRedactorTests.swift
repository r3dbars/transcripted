import Testing
@testable import TranscriptedWritingCore

@Suite("Diagnostics metadata redactor")
struct DiagnosticsMetadataRedactorTests {
    @Test("Known scalar fields survive unchanged")
    func keepsKnownScalars() {
        #expect(field("totalMilliseconds", "42") == "totalMilliseconds=42")
        #expect(field("cleanedChars", "8") == "cleanedChars=8")
        #expect(field("willRestart", "true") == "willRestart=true")
        #expect(field("reason", "launch-failed") == "reason=launch-failed")
        #expect(field("reason", "assets-missing") == "reason=assets-missing")
        #expect(field("reason", "port-in-use") == "reason=port-in-use")
        #expect(field("reason", "health-timeout") == "reason=health-timeout")
        #expect(field("reason", "directory") == "reason=directory")
        #expect(field("reason", "already-running") == "reason=already-running")
        #expect(field("reason", "store-corrupt") == "reason=store-corrupt")
        #expect(field("reason", "key-unavailable") == "reason=key-unavailable")
        #expect(field("reason", "storage-unavailable") == "reason=storage-unavailable")
        #expect(field("reason", "internal-error") == "reason=internal-error")
        #expect(field("app", "com.apple.TextEdit") == "app=com.apple.TextEdit")
        // Screen Memory duty-cycle instrumentation (Phase 1b): counts and
        // timings only, no screen text, so the power probe harness can read
        // them back out of the diagnostics log.
        #expect(field("duration_ms", "187") == "duration_ms=187")
        #expect(field("blocks", "12") == "blocks=12")
        // ScreenCaptureService's actual skip reasons — every one of these
        // was being silently redacted before this fix, which would have
        // made the Phase 1b power probe's TCC-blocked detection always miss.
        #expect(field("reason", "no-permission") == "reason=no-permission")
        #expect(field("reason", "enumeration-failed") == "reason=enumeration-failed")
        #expect(field("reason", "no-display") == "reason=no-display")
        #expect(field("reason", "disabled") == "reason=disabled")
        #expect(field("reason", "screen-locked") == "reason=screen-locked")
        #expect(field("reason", "secure-input") == "reason=secure-input")
        #expect(field("reason", "no-active-text-field") == "reason=no-active-text-field")
        #expect(field("reason", "no-active-session") == "reason=no-active-session")
        #expect(field("reason", "below-threshold") == "reason=below-threshold")
        #expect(field("reason", "excluded-app") == "reason=excluded-app")
        #expect(field("reason", "cadence") == "reason=cadence")
    }

    @Test("Screen Memory's screen-capture-skipped reasons survive as their literal enum case, not a redacted shape")
    func keepsScreenCaptureSkipReasons() {
        // Regression for the bug where `reason=disabled` (exactly 8 chars)
        // logged as `reason=String(8 chars)`: every skip reason looked
        // identical regardless of which gate actually blocked capture.
        #expect(field("reason", "disabled") == "reason=disabled")
        #expect(field("reason", "no-permission") == "reason=no-permission")
        #expect(field("reason", "screen-locked") == "reason=screen-locked")
        #expect(field("reason", "secure-input") == "reason=secure-input")
        #expect(field("reason", "no-active-text-field") == "reason=no-active-text-field")
        #expect(field("reason", "no-active-session") == "reason=no-active-session")
        #expect(field("reason", "below-threshold") == "reason=below-threshold")
        #expect(field("reason", "excluded-app") == "reason=excluded-app")
        #expect(field("reason", "cadence") == "reason=cadence")
        #expect(field("reason", "enumeration-failed") == "reason=enumeration-failed")
        #expect(field("reason", "no-display") == "reason=no-display")
    }

    @Test("The first-launch screen-permission-prompt outcome survives as its literal enum case")
    func keepsScreenPermissionPromptOutcomes() {
        #expect(field("status", "requested") == "status=requested")
        #expect(field("status", "settings-opened") == "status=settings-opened")
        #expect(field("status", "dismissed") == "status=dismissed")
    }

    @Test("The sensitive-scene suppression reason survives as its literal enum case")
    func keepsSensitiveSceneSuppressionReason() {
        #expect(field("reason", "sensitive-scene") == "reason=sensitive-scene")
    }

    @Test("The personal-suggestion source vocabulary survives as its literal enum case")
    func keepsPersonalSuggestionSourceValues() {
        #expect(field("source", "base") == "source=base")
        #expect(field("source", "personal") == "source=personal")
        #expect(field("source", "agreed") == "source=agreed")
        // Nothing free-text ever gets through the "source" key either.
        #expect(field("source", "tomorrow") == "source=String(8 chars)")
    }

    @Test("Scene classification diagnostics survive as fixed vocabulary and integers, never OCR'd text")
    func keepsSceneClassifiedFields() {
        #expect(field("mode", "replying") == "mode=replying")
        #expect(field("mode", "referencing") == "mode=referencing")
        #expect(field("mode", "composing") == "mode=composing")
        #expect(field("turns", "3") == "turns=3")
        #expect(field("turns", "0") == "turns=0")
        #expect(field("refs", "1") == "refs=1")
        // Nothing free-text ever gets through the "mode"/"turns"/"refs" keys.
        #expect(field("mode", "hey are you around") == "mode=String(18 chars)")
        #expect(field("turns", "3 (Slack)") == "turns=String(9 chars)")
    }

    @Test("The screen-capture-completed/-failed kind field survives as its literal enum case")
    func keepsScreenCaptureKindValues() {
        #expect(field("kind", "window") == "kind=window")
        #expect(field("kind", "display") == "kind=display")
        // Nothing free-text ever gets through the "kind" key either.
        #expect(field("kind", "fullscreen") == "kind=String(10 chars)")
    }

    @Test("P99-at-every-section timing fields survive as whole milliseconds")
    func keepsStageTimingFields() {
        // Scene classification (`ScreenCaptureService.freshScene`).
        #expect(field("milliseconds", "4") == "milliseconds=4")
        // Capture/OCR split (`ScreenCaptureService.performWindowCapture`/
        // `performFullDisplayCapture`).
        #expect(field("ocrMilliseconds", "112") == "ocrMilliseconds=112")
        // Personal-brain race (`GhostBrainServerHost.awaitPersonalPrediction`).
        #expect(field("waitedMilliseconds", "250") == "waitedMilliseconds=250")
        // Socket request total (`GhostBrainServerHost`'s `ghost-request-timing`).
        #expect(field("requestMilliseconds", "38") == "requestMilliseconds=38")
        // Accept-to-parsed handshake on its own timing event: the peer
        // code-signature verification plus the wire read.
        #expect(field("handshakeMilliseconds", "12") == "handshakeMilliseconds=12")
        // Nothing free-text ever gets through any of these keys either.
        #expect(field("milliseconds", "private") == "milliseconds=String(7 chars)")
        #expect(field("waitedMilliseconds", "-5") == "waitedMilliseconds=String(2 chars)")
        #expect(field("handshakeMilliseconds", "soon") == "handshakeMilliseconds=String(4 chars)")
    }

    @Test("The personal-lookup-timing outcome vocabulary survives as its literal enum case")
    func keepsPersonalLookupOutcomeValues() {
        #expect(field("outcome", "resolved") == "outcome=resolved")
        #expect(field("outcome", "timeout") == "outcome=timeout")
        #expect(field("outcome", "disabled") == "outcome=disabled")
        // Nothing free-text ever gets through the "outcome" key either.
        #expect(field("outcome", "maybe") == "outcome=String(5 chars)")
    }

    @Test("Unknown and text-like fields expose shape only")
    func redactsUnknownFields() {
        #expect(field("selectedText", "private draft") == "metadata=String(13 chars)")
        #expect(field("newMetric", "42") == "metadata=String(2 chars)")
    }

    @Test("Free text, paths, URLs, and newlines never survive")
    func redactsUnsafeValues() {
        #expect(field("reason", "private draft") == "reason=String(13 chars)")
        #expect(field("app", "/Users/me/draft") == "app=String(15 chars)")
        #expect(field("app", "https://private.example") == "app=String(23 chars)")
        #expect(field("app", "private") == "app=String(7 chars)")
        #expect(field("app", "com.apple.TextEdit\n") == "app=String(19 chars)")
        #expect(field("status", "enabled\nprivate") == "status=String(15 chars)")
        #expect(field("reason", "-50") == "reason=String(3 chars)")
        #expect(field("duration_ms", "private") == "duration_ms=String(7 chars)")
    }

    @Test("Event names are single fixed tokens")
    func sanitizesEvents() {
        #expect(DiagnosticsMetadataRedactor.logSafeEvent("llama-server-start") == "llama-server-start")
        #expect(DiagnosticsMetadataRedactor.logSafeEvent("launch\n") == "event-redacted")
        #expect(DiagnosticsMetadataRedactor.logSafeEvent("private event\ntext") == "event-redacted")
    }

    private func field(_ key: String, _ value: String) -> String {
        DiagnosticsMetadataRedactor.logSafeField(forKey: key, value: value)
    }
}
