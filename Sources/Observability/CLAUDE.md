# Observability Directory

## What This Does

This directory contains the app's logging, diagnostics, crash reporting,
anonymous analytics, and Sparkle update plumbing.

## Key Files

- `AppLogger.swift` — developer-facing debug log writer
- `EventReporter.swift` — structured event capture
- `ObservabilityEvent.swift` — shared structured event payload used by local event logging and derived reliability packets
- `LocalObservabilityPayloadSanitizer.swift` — redacts local event messages and context before disk writes
- `ReliabilityPacketRecorder.swift` — writes privacy-safe `reliability.jsonl` packets for important dictation, meeting, and runtime outcomes so support feedback can include failure shape without raw audio or transcript data
- `JSONLWriter.swift` — shared append-only JSONL writer that reuses file handles and falls back cleanly if log files are rotated or recreated
- `LockedFileAppender.swift` — cross-process-safe file append helper that serializes writes and uses `flock` so concurrent JSONL/debug-log writers do not interleave records
- `DiagnosticsTrail.swift` — lightweight high-signal diagnostics helper
- `RuntimeDiagnostics.swift` — app runtime heartbeat, dirty-shutdown detection, and active session stage tracking for force quits / silent exits
- `RuntimeDiagnosticsStore.swift` — JSON marker persistence and privacy-safe dirty-shutdown context builder
- `CrashReporter.swift` — crash reporting setup
- `CrashReportingPreferences.swift` — Settings-backed crash reporting preference
- `AnalyticsReporter.swift` — privacy-first anonymous usage analytics to PostHog
- `AnalyticsPreferences.swift` — Settings-backed anonymous analytics preference
- `AnalyticsEventPolicy.swift` — explicit allowlist of PostHog events + properties
- `ActivationTelemetry.swift` — centralized activation analytics helpers for artifact actions, agent prompt/setup CTAs, and saved-recent artifact return-proxy buckets
- `AnalyticsPayloadSanitizer.swift` — strips sensitive analytics properties before send
- `EventFileWritePolicy.swift` — buffering policy for info-level event writes so routine telemetry does not hammer local JSONL files
- `ObservabilityTextRedactor.swift` — shared text redactor for support-facing and diagnostic strings before they leave local-only surfaces
- `SentryEventPolicy.swift` — explicit allowlist of non-fatal events permitted to reach Sentry
- `SentryPayloadSanitizer.swift` — strips obvious sensitive values before Sentry sends
- `PayloadSanitizationCore.swift` — shared `shouldDrop(key:)` + `redactAndCap(_:maxValueLength:)` helpers used by both sanitizers so redaction rules stay in one place while each destination keeps its own length cap and sensitive-key list
- `SentryRuntimeConfiguration.swift` — resolves Sentry DSN, environment, release, and dist from `Info.plist` or process environment
- `SparkleUpdaterController.swift` — live Sparkle update controller used by the menubar app, including update-state telemetry and ready-to-install restart flows
- `UpdateFailureKind.swift` — canonical Sparkle/update failure taxonomy used to normalize network, appcast, download, signature, install, and busy-session errors for analytics

## Current Notes

- Treat this directory as shared infrastructure for the current dictation + meetings app
- Sparkle is the live in-app update path on `main`; the older beta DMG self-update flow is no longer part of the app target
- `LockedFileAppender` is the canonical append path for local debug and JSONL logs. Keep concurrent file writes funneled through it so app and helper processes do not splice records together.
- Do not assume older draft/style/analysis event flows are still active just because they appear in historical docs or event logs
- `build.sh` and beta behavior can affect logs, signing, and permissions during local testing
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1` disables `app.jsonl` writes for test and smoke runs so local production logs stay clean
- Sentry runtime config is resolved by `SentryRuntimeConfiguration` from `Info.plist` (`TranscriptedSentryDSN`, `TranscriptedSentryEnvironment`, `TranscriptedSentryReleasePrefix`) or process environment (`SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `SENTRY_RELEASE`, `SENTRY_DIST`), and crash reports must stay scrubbed of transcript/audio/title/path data
- `SentryRuntimeConfiguration` rejects non-HTTPS DSNs, so insecure local overrides fail closed instead of downgrading crash transport
- Shipped builds should report releases as `transcripted@<CFBundleShortVersionString>` and dist as `CFBundleVersion`; release packaging registers that Sentry release explicitly through `scripts/release/register-sentry-release.sh`
- PostHog config is read from `Info.plist` (`TranscriptedPostHogAPIKey`, `TranscriptedPostHogHost`) or process environment (`POSTHOG_API_KEY`, `POSTHOG_HOST`), and anonymous analytics must stay event-allowlisted and bucketed rather than sending raw payloads
- Activation analytics should route through `ActivationTelemetry` so artifact action, agent prompt/setup, and saved-recent artifact return-proxy events keep stable names, targets, result enums, and coarse age/window buckets.
- Non-fatal error forwarding to Sentry is allowlisted. New `.error` events should not automatically assume they are safe to send off-device.
- `RuntimeDiagnostics` writes only coarse runtime state under app-owned state. Keep it free of transcript text, raw audio, file paths, device names, meeting titles, and speaker names.
- `ReliabilityPacketRecorder` derives packets from already-reviewed observability events. Keep its context allowlist coarse and bucketed; do not add raw error text, transcript text, raw audio, file paths, device names, meeting titles, speaker names, emails, tokens, or source app names.
- Update telemetry should keep using `UpdateFailureKind` instead of ad hoc string parsing so dashboards stay stable across Sparkle error wording changes.

## Verification

After changing observability code:

```bash
bash build.sh --no-open
bash run-tests.sh
```

Relevant direct coverage:

- `Tests/AnalyticsEventPolicyTests.swift`
- `Tests/AnalyticsPayloadSanitizerTests.swift`
- `Tests/AnalyticsReporterTests.swift`
- `Tests/ObservabilityPreferencesTests.swift`
- `Tests/SentryEventPolicyTests.swift`
- `Tests/SentryPayloadSanitizerTests.swift`
- `Tests/SentryRuntimeConfigurationTests.swift`
- `Tests/ObservabilityLogWriterTests.swift`
- `Tests/ReliabilityPacketRecorderTests.swift`
- `Tests/RuntimeDiagnosticsStoreTests.swift`
- `Tests/UpdateFailureKindTests.swift`

Useful files while testing:

- `~/Library/Application Support/Transcripted/logs/debug.log`
- `~/Library/Application Support/Transcripted/logs/events.jsonl`
- `~/Library/Application Support/Transcripted/logs/reliability.jsonl` for privacy-safe outcome packets attached to support diagnostics
- `~/Library/Application Support/Transcripted/logs/app.jsonl` for embedded `TranscriptedCore` JSONL logs and QA validation
