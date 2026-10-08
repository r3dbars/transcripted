# Observability

Module `Observability` in `.agents/modules.json`. It owns local logs, diagnostics, crash reporting (Sentry), anonymous analytics (PostHog), and Sparkle update plumbing. May depend on Support and Core `core-vocab`. Every other module may report into it. Sink map, config and retention: `docs/observability.md`; taxonomy and privacy rules: `docs/privacy-first-observability.md`.

## Invariants

- **Nothing sensitive leaves the device.** No transcript text, audio, titles, paths, device labels, speaker names or emails, in any sink. Sentry and PostHog get allowlisted events with bucketed or categorical values, not raw payloads.
- **Harness launches send nothing.** With `AutomatedLaunchEnvironment` active, `AnalyticsReporter` sends nothing and `SentryRuntimeConfiguration` returns no DSN. `TRANSCRIPTED_DISABLE_FILE_LOGGER=1` stops `app.jsonl` writes for tests and smokes.
- **Concurrent file writes go through `LockedFileAppender`** (`flock`), so app and helper processes never splice records.
- **Don't assume old draft/style/analysis event flows are live** just because they show up in old docs or event logs.

## Adding an analytics event or property

Checklist: "Analytics taxonomy review checklist" in `docs/privacy-first-observability.md`. Add the event to `Resources/analytics-events.psv`, and any new reviewed non-bucket property name to `Resources/analytics-reviewed-properties.psv`. Two traps lose data silently:

- **Key names are dropped by substring.** Any key containing `audio`, `authorization`, `bearer`, `bundle`, `credential`, `dsn`, `email`, `error`, `file`, `name`, `password`, `path`, `speaker`, `source_app`, `secret`, `text`, `title`, `token`, `transcript` or `url` (`PayloadSanitizationCore.baseSensitiveKeyFragments`) never leaves the device. Analytics has no escape list, so `error_kind` or `audio_route_kind` just vanishes. Sentry also drops `context` and `identifier`, except keys in `SentryPayloadSanitizer.explicitlySafeKeys`.
- **Some values are validated.** The categorical keys in `AnalyticsPayloadSanitizer` (`failure_kind`, `trigger`, `capture_outcome`, ...) must match `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$` and be at most 80 characters; `session_id`, `correlation_id`, `install_uuid` must be UUIDs. Otherwise the value is dropped.

Emit with a literal name (`AnalyticsReporter.track("event_name", ...)`) so `python3 scripts/dev/check-analytics-emitters.py` sees it. Then run it, `python3 scripts/ops/normalize-analytics-taxonomy.py --check` (also after union merges) and `python3 scripts/dev/check-telemetry-keys.py`. All work on Linux; `bash scripts/dev/linux-checks.sh` runs them together. Route activation events (artifact actions, agent prompt/setup, saved-recent return proxy) through `ActivationTelemetry` so names, targets and buckets stay stable.

## Rules by area

**Event routing**
- `EventReporter.capture` builds an `ObservabilityEventCapturePlan` (no side effects, fast-tested) and runs it: local `events.jsonl`, reliability packet, PostHog forward, Sentry.
- Non-fatal Sentry forwarding is allowlisted (`SentryEventPolicy`). A new `.error` event is not automatically safe to send.
- An allowlisted `.error` always counts in PostHog as `reliability_failure_observed`. `forwardToSentry: false` on `DiagnosticsTrail.record` / `EventReporter.capture` keeps one occurrence out of Sentry; level, local log, packet and PostHog are unchanged. Only the dictation early-release cancel uses it (`DictationEarlyReleaseCancelReport`, tapped Push to Talk keys). Use it for occurrences the user wasn't shown as a failure, never to quiet a noisy real one.
- `AnalyticsEventForwardingPolicy` (in `AnalyticsEventPolicy.swift`) is the only path from an `EventReporter` event to PostHog besides `reliability_failure_observed`. It reads the caller's own context (never the merged engine-state context), checks every value against a fixed set or buckets it, and maps anything unexpected to `unknown`. Its PostHog names go through a variable, so `check-analytics-emitters.py` can't see them; `Tests/AnalyticsEventForwardingPolicyTests.swift` pins that each is registered. Don't also add a direct `AnalyticsReporter.track` for those events or they double count.
- `dictation_zombie_recovery_finished` is the single terminal event per zombie-engine attempt. Keep trigger, stage, result and route categorical; no raw device labels or exact sample counts.

**Reliability packets**
- `ReliabilityPacketRecorder` must get the **raw** entry from `EventReporter.capture`, not the locally blanked copy. It positive-allowlists every key and redacts every value itself; feeding it the blanked copy shipped `[redacted-sensitive-value]` in support bundles and made the `recovered` outcome unreachable. Keep its context allowlist coarse and bucketed: no raw error text, transcript text, audio, paths, device names, titles, speaker names, emails, tokens or source app names.

**Local sanitizer escapes (events.jsonl only)**
- `LocalObservabilityPayloadSanitizer.categoricalSafeKeys` is an exact-key escape from substring blanking for device-class enums, booleans and audio-signal numbers (`input_device_class`, `audio_has_signal`, `audio_peak`...). It applies only while the value still looks categorical; a raw device label stays redacted. Add a key only when its value is an enum, boolean or number by construction.
- `measurementKeySuffixes` is the second escape: a bare number (signed decimal, no exponent, units or grouping) under a `_ms`/`_s`/`_hz`/`_bytes`/`_count`-style key survives, so stage timings stay readable. Non-numeric values under those keys stay redacted.
- Sentry and Analytics sanitize `mergedContext` separately and get neither escape.

**Runtime diagnostics**
- `RuntimeDiagnostics` writes only coarse state under app-owned state: no transcript text, audio, paths, device names, titles or speaker names.
- Sentry context updates run on a serial utility queue (`RuntimeDiagnosticsContextWriter`). Read the crash-reporting preference when applying each update so queued work respects opt-out; the scope can lag during a preferences stall.
- Only the periodic heartbeat write is queued off main, on `RuntimeDiagnosticsMarkerWriter` (serial, latest wins). The launch marker, every session stage and clean shutdown use `writeNow`, synchronously and behind anything queued, so crash evidence is never a stage behind. The heartbeat Timer stays on main so `heartbeat_age_bucket` shows main-thread hangs.
- `RuntimeDiagnosticsStore.save` writes a 0600 temp file with `O_EXCL`, then renames (no fsync), and creates the 0700 folder only when missing.
- Shutdown: `LocalEventShutdownFlush` awaits buffered events, then reliability packets, so Quit replies to AppKit with nothing left in memory.

**Crash reporting (Sentry)**
- `CrashReporterPrivacyOptions` holds the six SDK switches `CrashReporter` applies before `SentrySDK.start`: no default PII, no auto sessions, no network breadcrumbs, zero breadcrumbs, no stack traces, no failed-request capture. `Sentry.Options` conforms to its protocol so tests check values on a fake.
- Config comes from `Info.plist` (`TranscriptedSentryDSN`, `TranscriptedSentryEnvironment`, `TranscriptedSentryReleasePrefix`, `TranscriptedSentryAppHangTrackingEnabled`) or env (`SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `SENTRY_RELEASE`, `SENTRY_DIST`, `SENTRY_ENABLE_APP_HANG_TRACKING`). Non-HTTPS DSNs are rejected, so an insecure override fails closed.
- Shipped builds report release `transcripted@<CFBundleShortVersionString>` and dist `CFBundleVersion`; release packaging registers it with `scripts/release/register-sentry-release.sh`. `build_revision` and `build_channel` ride along as crash tags (`SentryPayloadSanitizer.crashRuntimeTagKeys`).
- App-hang reports: `AppHangReportPolicy` keeps only freezes of 5+ seconds and drops any hang while a modal popup was showing (`AppHangPopupObserver` feeds the tracker), because a modal run loop looks like a freeze to Sentry's watchdog.
- `UnrecognizedSelectorReason` keeps only safe receiver/selector tags, never instance pointers or trailing free text.

**PostHog and telemetry shape**
- Config: `Info.plist` (`TranscriptedPostHogAPIKey`, `TranscriptedPostHogHost`) or env (`POSTHOG_API_KEY`, `POSTHOG_HOST`); hosts must be HTTPS.
- `InstallIdentity` is app-generated and anonymous; never derive it from hardware, account, email or content. `TelemetryContext.enrich` adds version, build revision, OS major, session/correlation UUIDs, categorical device classes and permission booleans.
- `UsageHealthStore` is a bounded `UserDefaults` ledger fed from event enums only. It never scans captures or logs.
- `app_active_day` (`AnalyticsActiveDay`): one event per local day while running, so idle installs differ from quit ones.
- `dictation_started` carries `start_latency_bucket`; both dictation start events carry `first_since_launch`.
- `launch_models_warmed` fires once per launch with `LaunchTimingTelemetry` marks (process start to menu bar icon, shortcuts registered, warmup start, each warmup step, rounded to 10 ms) plus `login_launch`. Marks are set once per process, so wake and model-switch rewarms don't overwrite them. `MachineClassTelemetry` adds a coarse chip-family and memory class, no model identifier.
- Meeting events carry the call-audio tap's upkeep (`system_*_reconnects_bucket`, `system_rebuild_retries_bucket`, `system_sleep_count_bucket`, `system_silent_unresolved`, `system_end_reason`) and `mic_format_rebuilds_bucket`, built from `AudioPipelineDiagnosticsSnapshot` in `meetingCaptureAnalyticsProperties`. `meeting_recording_started` adds `mic_only_by_choice`, `system_permission_check`, `models_warm`. `meeting_system_audio_prompt_answered` records the pre-start prompt; its `outcome` separates `turn_on_without_macos_answer` from `mic_only_before_macos_answer`. A mic-only-by-choice stop reports capture_outcome `mic_only_by_choice` with `system_file_present` / `system_stream_present` false, since the silent stand-in track isn't captured audio.
- Update telemetry uses `UpdateFailureKind`, never ad hoc string parsing, so dashboards survive Sparkle wording changes. `UpdateInstallDetection` decides first launch of a newer version (`update_installed.install_kind`: `restart`, `quit`, `unattributed`).

**Updates (Sparkle)**
- Sparkle is the only in-app update path; the old beta DMG self-update is gone. `SparkleUpdaterController` is the live controller. `UpdateActionSafetyPolicy` blocks "check for updates" during capture or processing; `UpdateAttentionPolicy` decides the orange badge; `BackgroundUpdateDeferralPolicy` defers background downloads on a busy Mac, hotspot or Low Data Mode. Release flow: `docs/sparkle-updates.md`.

## Where things are

- Local logs and events: `AppLogSink` (`debug.log` plus in-app debug panel; how it differs from `TranscriptedCore`'s `AppLogger` is in `docs/observability.md`), `EventReporter`, `EventFileWriter` (actor; info events batch briefly, warnings and errors flush at once, per `EventFileWritePolicy`), `ObservabilityLogRotation` (rename-based, one rotated generation), `ObservabilityTextRedactor` (adapter over Core's `PrivacyTextRedactor`), `ObservabilityEvent`, `LockedFileAppender`, `DiagnosticsTrail`.
- Sanitizers: `PayloadSanitizationCore` (shared `shouldDrop(key:)` and `redactAndCap`), `SentryPayloadSanitizer`, `AnalyticsPayloadSanitizer`, `LocalObservabilityPayloadSanitizer`. Policies: `SentryEventPolicy`, `AnalyticsEventPolicy`.
- Reporters: `CrashReporter`, `CrashReportingPreferences`, `AnalyticsReporter`, `SentryRuntimeConfiguration`.
- Support and runtime state: `SupportDiagnosticsBundle` (privacy-safe summary for feedback emails and manual diagnostic events, with coarse recent reliability packets), `ReliabilityPacketRecorder`, `RuntimeDiagnostics*`.
- Telemetry helpers: `ActivationTelemetry`, `AgentSetupLifecycleTelemetry`, `FeatureDiscoveryTelemetry` (`settingsFeatureDiscovered.` prefix), `ProductUsageTelemetry`, `RetentionTelemetry`, `SpeakerRecognitionTelemetry` (buckets aligned with the matcher's thresholds), `DictationPasteRetryTelemetry`, `WorkflowRecoveryTelemetry` (takes a `track` closure so tests record), `UsageHealthModels`.
- Updates: `SparkleUpdaterController`, `UpdateFailureKind`, `UpdateActionSafetyPolicy`, `UpdateInstallDetection`.

## Verification

```bash
bash build.sh --no-open
bash run-tests.sh
```

Direct coverage in `Tests/`: `Analytics{EventPolicy,EventForwardingPolicy,PayloadSanitizer,Reporter}Tests`, `SpeakerRecognitionTelemetryTests`, `ObservabilityPreferencesTests`, `Sentry{EventPolicy,PayloadSanitizer,RuntimeConfiguration}Tests`, `SupportDiagnosticsBundleTests`, `UnrecognizedSelectorReasonTests`, `Observability{TextRedactor,LogWriter,LogRotation}Tests`, `ReliabilityPacketRecorderTests`, `RuntimeDiagnosticsStoreTests`, `Update{FailureKind,ActionSafetyPolicy,InstallDetection}Tests`.

Files to read while testing, under `~/Library/Application Support/Transcripted/logs/`: `debug.log`, `events.jsonl`, `reliability.jsonl` (outcome packets attached to support diagnostics), `app.jsonl` (embedded `TranscriptedCore` logs, QA validation).
