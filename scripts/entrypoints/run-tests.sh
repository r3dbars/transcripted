#!/bin/bash
# run-tests.sh — Compile and run Transcripted's fast utility test suite
# The fast test manifest is the source of truth for which root Tests/*.swift files run.

set -euo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

MANIFEST="Tests/FastTests.manifest"
BUILD_DIR="build"
GENERATED_RUNNER="$BUILD_DIR/FastTestRunner.$$.swift"
COVERAGE_DIR="$BUILD_DIR/coverage/fast-tests"
COVERAGE_PROFDATA="$COVERAGE_DIR/coverage.profdata"
COVERAGE_SUMMARY="$COVERAGE_DIR/summary.txt"
COVERAGE_LCOV="$COVERAGE_DIR/report.lcov"
COVERAGE_IGNORE_REGEX='(^|/)Tests/|(^|/)build/'

coverage_requested=false
coverage_env="${FAST_TEST_COVERAGE:-${TRANSCRIPTED_FAST_TEST_COVERAGE:-0}}"
case "$coverage_env" in
    1|true|TRUE|yes|YES)
        coverage_requested=true
        ;;
esac

USAGE="Usage: bash run-tests.sh [--coverage] [--filter <entryFn|File>] [--list]"

filter_selector=""
list_only=false
expect_filter_value=false

for arg in "$@"; do
    # Two-token form: the previous iteration set this sentinel so the value is
    # consumed here instead of falling through to the unknown-option arm.
    if [ "$expect_filter_value" = true ]; then
        filter_selector="$arg"
        expect_filter_value=false
        continue
    fi
    case "$arg" in
        --coverage)
            coverage_requested=true
            ;;
        --filter|--only)
            expect_filter_value=true
            ;;
        --filter=*|--only=*)
            filter_selector="${arg#*=}"
            ;;
        --list)
            list_only=true
            ;;
        -h|--help)
            echo "$USAGE"
            echo ""
            echo "Set FAST_TEST_COVERAGE=1 or pass --coverage to write LLVM coverage artifacts to $COVERAGE_DIR."
            echo "Pass --filter <selector> (or --only <selector>) to run a single suite by entry function or file name."
            echo "Pass --list to print the known fast-test entry functions and exit."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "$USAGE"
            exit 2
            ;;
    esac
done

if [ "$expect_filter_value" = true ]; then
    echo "Missing value for --filter"
    echo "$USAGE"
    exit 2
fi

cleanup_generated_runner() {
    rm -f "$GENERATED_RUNNER"
}
trap cleanup_generated_runner EXIT

if [ ! -f "$MANIFEST" ]; then
    echo "Fast test manifest not found: $MANIFEST"
    exit 1
fi

manifest_entries=$(
    grep -v '^[[:space:]]*#' "$MANIFEST" | \
    sed '/^[[:space:]]*$/d'
)

if [ -z "$manifest_entries" ]; then
    echo "Fast test manifest is empty: $MANIFEST"
    exit 1
fi

manifest_files=$(
    printf '%s\n' "$manifest_entries" | \
    cut -d: -f1 | \
    sort
)

actual_files=$(
    find Tests -maxdepth 1 -name '*Tests.swift' -exec basename {} \; | \
    sort
)

if [ "$manifest_files" != "$actual_files" ]; then
    echo "Fast test manifest is out of sync with Tests/*.swift"
    echo ""
    echo "Manifest entries:"
    printf '%s\n' "$manifest_files"
    echo ""
    echo "Actual test files:"
    printf '%s\n' "$actual_files"
    exit 1
fi

# Catch root test-shaped files the *Tests.swift glob cannot see (FooTest.swift,
# FooSmoke.swift): they would neither run nor trip the sync check above.
# Shared non-test sources are fine when the runner compiles them explicitly.
stray_root_swift=$(
    find Tests -maxdepth 1 -name '*.swift' ! -name '*Tests.swift' -exec basename {} \; | \
    while IFS= read -r stray; do
        grep -qF "Tests/$stray" "$0" || printf '%s\n' "$stray"
    done
)
if [ -n "$stray_root_swift" ]; then
    echo "Root Tests/*.swift files invisible to the fast-test runner:"
    printf '%s\n' "$stray_root_swift" | sed 's/^/  - /'
    echo "Rename to <Name>Tests.swift and register in $MANIFEST, or add the file to this runner's compile list."
    exit 1
fi

# Known entry-function names, derived after the integrity guards above so --list
# and --filter only ever surface a manifest that already passed sync checks.
known_entry_functions=$(
    printf '%s\n' "$manifest_entries" | \
    cut -d: -f2 | \
    sort
)

if [ "$list_only" = true ]; then
    printf '%s\n' "$known_entry_functions"
    exit 0
fi

if [ -n "$filter_selector" ]; then
    selector_lower=$(printf '%s' "$filter_selector" | tr '[:upper:]' '[:lower:]')
    filtered_entries=$(
        printf '%s\n' "$manifest_entries" | \
        while IFS=':' read -r test_file entry_function; do
            [ -z "$test_file" ] && continue
            file_no_ext="${test_file%.swift}"
            file_lower=$(printf '%s' "$test_file" | tr '[:upper:]' '[:lower:]')
            func_lower=$(printf '%s' "$entry_function" | tr '[:upper:]' '[:lower:]')
            match=false
            if [ "$filter_selector" = "$entry_function" ] || \
               [ "$filter_selector" = "$test_file" ] || \
               [ "$filter_selector" = "$file_no_ext" ]; then
                match=true
            fi
            # Substring match (case-insensitive) without a case/esac block, which
            # confuses the bash 3.2 parser inside this $() substitution.
            if [ "${file_lower#*"$selector_lower"}" != "$file_lower" ] || \
               [ "${func_lower#*"$selector_lower"}" != "$func_lower" ]; then
                match=true
            fi
            if [ "$match" = true ]; then
                printf '%s:%s\n' "$test_file" "$entry_function"
            fi
        done
    )

    if [ -z "$filtered_entries" ]; then
        echo "No fast test matches: $filter_selector"
        echo ""
        echo "Known entry functions:"
        printf '%s\n' "$known_entry_functions"
        exit 2
    fi

    manifest_entries="$filtered_entries"
fi

mkdir -p "$BUILD_DIR"

cat > "$GENERATED_RUNNER" <<'EOF'
// Generated by run-tests.sh from Tests/FastTests.manifest.

import Foundation

@main
struct FastTestRunner {
    static func main() async {
        print("Transcripted Fast Test Suite\n")
EOF

while IFS=':' read -r test_file entry_function; do
    if [ -z "$test_file" ] || [ -z "$entry_function" ]; then
        echo "Malformed fast test manifest entry: ${test_file}:${entry_function}"
        exit 1
    fi

    if [ ! -f "Tests/$test_file" ]; then
        echo "Manifest references missing fast test file: Tests/$test_file"
        exit 1
    fi

    # Catch manifest typos here so they fail with a precise message instead of a
    # cryptic swiftc 'cannot find <entry> in scope' from the generated runner.
    if ! grep -q "func $entry_function(" "Tests/$test_file"; then
        echo "Manifest entry function not found: $entry_function (declared in Tests/$test_file?)"
        exit 1
    fi

    printf '        await runEntry(%s)\n' "$entry_function" >> "$GENERATED_RUNNER"
done <<EOF
$manifest_entries
EOF

cat >> "$GENERATED_RUNNER" <<'EOF'

        print("\n\(totalTests) tests, \(passedTests) passed, \(failedTests) failed")
        if failedTests > 0 {
            print("FAILED")
            exit(1)
        } else {
            print("ALL TESTS PASSED")
        }
    }

    static func runEntry(_ entry: () -> Void) async {
        entry()
    }

    static func runEntry(_ entry: () async -> Void) async {
        await entry()
    }
}
EOF

FAST_TEST_SOURCES=(
    "Tests/TestHelpers.swift"
    "$GENERATED_RUNNER"
)

while IFS=':' read -r test_file entry_function; do
    FAST_TEST_SOURCES+=("Tests/$test_file")
done <<EOF
$manifest_entries
EOF

APP_SOURCES=(
    "Sources/Support/ActivationPolicyController.swift"
    "Sources/Support/TranscriptedPermissionKind.swift"
    "Sources/Support/TranscriptedPermissionAccess.swift"
    "Sources/Support/TranscriptedStoragePaths.swift"
    "Sources/Timeline/TimelineDatabase.swift"
    "Sources/Timeline/TimelineRetentionManager.swift"
    "Sources/Support/ClaudeDesktopIntegrationInstaller.swift"
    "Sources/Support/AgentMCPConnector.swift"
    "Sources/Support/LaunchAtLoginPreferences.swift"
    "Sources/Support/MenuBarVisibilityPreferences.swift"
    "Sources/Support/PermissionsOnboardingPreferences.swift"
    "Sources/Support/HotkeyPreferences.swift"
    "Sources/Support/OnboardingDictationShortcutPolicy.swift"
    "Sources/Support/PhysicalDictationTriggerPreferences.swift"
    "Sources/Support/CustomDictionaryPreferences.swift"
    "Sources/Support/SpeakerEmbedderPreferences.swift"
    "Sources/Support/DockVisibilityPreferences.swift"
    "Sources/Support/MicrophoneProcessingPreferences.swift"
    "Sources/Support/QuitConfirmationPreferences.swift"
    "Sources/Support/AutoCallDetectionPreferences.swift"
    "Sources/Support/AudioStoragePreferences.swift"
    "Sources/Support/CaptureLibraryChangeBroadcaster.swift"
    "Sources/Support/CaptureLibrarySize.swift"
    "Sources/Support/CaptureLibraryMigrationPlanner.swift"
    "Sources/Support/LiveMeetingCodexPreferences.swift"
    "Sources/Support/LocalMeetingSummaryPreferences.swift"
    "Sources/Support/TimelinePreferences.swift"
    "Sources/Support/SpeechModelBetaPreferences.swift"
    "Sources/Support/TranscriptionModelPreferences.swift"
    "Sources/Support/ExistingInstallModelPrefetchPolicy.swift"
    "Sources/Support/ModelCacheInventory.swift"
    "Sources/Support/SingleInstanceGuard.swift"
    "Sources/Support/DictationAutoSendPreferences.swift"
    "Sources/Support/DictationCleanupPreferences.swift"
    "Sources/Support/DictationOverlayPresentationPreferences.swift"
    "Sources/Support/DictationFillerCleanupPolicy.swift"
    "Sources/Support/ClipboardRestoringTextPaster.swift"
    "Sources/Accessibility/AccessibilityBridge.swift"
    "Sources/Dictation/DictationSessionTimeout.swift"
    "Sources/Dictation/DictationStoragePaths.swift"
    "Sources/Dictation/DictationStopFinalizationPolicy.swift"
    "Sources/Dictation/DictationTranscriptWriter.swift"
    "Sources/Dictation/DictationTranscriptStore.swift"
    "Sources/Meeting/MeetingStoragePaths.swift"
    "Sources/Support/TranscriptedConstants.swift"
    "Sources/Timeline/ActiveDisplayTracker.swift"
    "Sources/Timeline/InputIdleSnapshot.swift"
    "Sources/Timeline/ForegroundAppSampler.swift"
    "Sources/Timeline/ScreenCaptureEngine.swift"
    "Sources/Speech/DictationInputDeviceSelectionPolicy.swift"
    "Sources/Speech/DictationReadinessWaitPolicy.swift"
    "Sources/Speech/ParakeetModelInitDiagnostics.swift"
    "Sources/Speech/ParakeetPrewarmPolicy.swift"
    "Sources/Speech/ParakeetRecoveryState.swift"
    "Sources/Speech/ParakeetStartRecordingFailurePolicy.swift"
    "Sources/Speech/ParakeetShortAudioGate.swift"
    "Sources/Speech/DictationAudioRecovery.swift"
    "Sources/Speech/RecordedAudioTimeline.swift"
    "Sources/Speech/DictationAudioLevelMeter.swift"
    "Sources/Meeting/MeetingRecordingStartGate.swift"
    "Sources/Meeting/MeetingCaptureSupport.swift"
    "Sources/Meeting/MeetingCaptureHealthTelemetry.swift"
    "Sources/Meeting/MeetingFailureExplanation.swift"
    "Sources/Meeting/MeetingFailureCopy.swift"
    "Sources/Meeting/MeetingFailureKind.swift"
    "Sources/Meeting/MeetingPromptDetector.swift"
    "Sources/Meeting/MeetingPromptHeuristics.swift"
    "Sources/Meeting/MeetingPromptTelemetry.swift"
    "Sources/Meeting/MicActivityMonitor.swift"
    "Sources/Meeting/CameraActivityMonitor.swift"
    "Sources/Meeting/SustainedActivityConfirmer.swift"
    "Sources/Meeting/MeetingAudioInactivityDetector.swift"
    "Sources/Meeting/MeetingAudioStorageManager.swift"
    "Sources/Meeting/MeetingRecordingCleanup.swift"
    "Sources/Meeting/MeetingImportedAudioPreparer.swift"
    "Sources/Meeting/MeetingSessionUIPolicy.swift"
    "Sources/Meeting/MeetingMicBoostPromptPolicy.swift"
    "Sources/Meeting/MeetingWarmupStatusPolicy.swift"
    "Sources/Meeting/MeetingTranscriptStyler.swift"
    "Sources/Meeting/MeetingArtifactRenamer.swift"
    "Sources/Meeting/LocalMeetingSummarizer.swift"
    "Sources/Meeting/MeetingQuickSummaryExtractor.swift"
    "Sources/Meeting/MeetingQuickSummaryWriter.swift"
    "Sources/Meeting/LiveMeetingCodexSession.swift"
    "Sources/Meeting/LiveMeetingPreviewServer.swift"
    "Sources/Meeting/LiveMeetingStreamingUpdatePolicy.swift"
    "Sources/Meeting/LiveMeetingTranscriptFeed.swift"
    "Sources/UI/MenuBar/MenuBarHeaderLayoutPolicy.swift"
    "Sources/UI/MenuBar/MenuBarHeaderStatusPresentation.swift"
    "Sources/UI/MenuBar/PasteLastDictationFeedback.swift"
    "Sources/Observability/AnalyticsReporter.swift"
    "Sources/Observability/SpeakerRecognitionTelemetry.swift"
    "Sources/Observability/ActivationTelemetry.swift"
    "Sources/Observability/FeatureDiscoveryTelemetry.swift"
    "Sources/Observability/LockedFileAppender.swift"
    "Sources/Observability/JSONLWriter.swift"
    "Sources/Observability/AnalyticsEventPolicy.swift"
    "Sources/Observability/UpdateActionSafetyPolicy.swift"
    "Sources/Observability/ObservabilityTextRedactor.swift"
    "Sources/Observability/ObservabilityLogRotation.swift"
    "Sources/Observability/PayloadSanitizationCore.swift"
    "Sources/Observability/AnalyticsPayloadSanitizer.swift"
    "Sources/Observability/AnalyticsPreferences.swift"
    "Sources/Observability/CrashReportingPreferences.swift"
    "Sources/Observability/EventFileWritePolicy.swift"
    "Sources/Observability/LocalObservabilityPayloadSanitizer.swift"
    "Sources/Observability/ObservabilityEvent.swift"
    "Sources/Observability/ReliabilityPacketRecorder.swift"
    "Sources/Observability/RuntimeDiagnosticsStore.swift"
    "Sources/Observability/UpdateFailureKind.swift"
    "Sources/Observability/SentryRuntimeConfiguration.swift"
    "Sources/Observability/SentryEventPolicy.swift"
    "Sources/Observability/SentryPayloadSanitizer.swift"
    "Sources/Observability/UnrecognizedSelectorReason.swift"
    "Sources/Reliability/WakeRecoveryCoordinator.swift"
    "Sources/TranscriptedCore/Audio/MicRecordingSegment.swift"
    "Sources/TranscriptedCore/Models/SpeakerMapping.swift"
    "Sources/TranscriptedCore/Models/TranscriptionTypes.swift"
    "Sources/TranscriptedCore/Speaker/SpeakerProfile.swift"
    "Sources/TranscriptedCore/Speaker/SpeakerMatchOutcome.swift"
    "Sources/TranscriptedCore/Speaker/SpeakerNamingPolicy.swift"
    "Sources/TranscriptedCore/Speaker/SpeakerPeopleReviewPolicy.swift"
    "Sources/TranscriptedCore/Storage/TranscriptFormatOptions.swift"
    "Sources/TranscriptedCore/Storage/TranscriptFrontmatter.swift"
    "Sources/Support/SpeakerNameSelectionPolicy.swift"
    "Sources/UI/Shared/AgentConnectionGuide.swift"
    "Sources/UI/Shared/FeedbackIssueBuilder.swift"
    "Sources/UI/Shared/SupportDiagnosticsBundle.swift"
    "Sources/UI/Shared/FirstRunExperience.swift"
    "Sources/UI/Shared/AppSoundPlayer.swift"
    "Sources/UI/Shared/FocusOrderContract.swift"
    "Sources/UI/Settings/TranscriptedSettingsPage.swift"
    "Sources/UI/Settings/SettingsRecentCaptureRefreshPolicy.swift"
    "Sources/UI/Settings/SettingsContentLayoutPolicy.swift"
    "Sources/UI/Settings/HomeDeleteConfirmationPolicy.swift"
    "Sources/UI/Settings/OnboardingAbandonmentReasonPolicy.swift"
    "Sources/UI/Settings/HomeRootAlertPolicy.swift"
    "Sources/UI/Settings/HomeScanWarningPolicy.swift"
    "Sources/UI/Settings/HomeCanvasGreeting.swift"
    "Sources/UI/Shared/HomeMeetingDeletion.swift"
    "Sources/UI/Shared/OwnFileResolver.swift"
    "Sources/UI/Shared/HomeMeetingRowActionTargets.swift"
    "Sources/UI/Shared/HomeMeetingRename.swift"
    "Sources/UI/Settings/HomeMeetingSummaryBetaPresentationPolicy.swift"
    "Sources/UI/Settings/SpeakerVoiceRowPresentation.swift"
    "Sources/UI/Settings/HomeFailedMeetingInlinePresentation.swift"
    "Sources/UI/Settings/FailedMeetingRecoveryPresentation.swift"
    "Sources/UI/Settings/HomeMeetingPreviewFormatter.swift"
    "Sources/UI/Overlay/CapturePillController.swift"
    "Sources/UI/Overlay/FloatingOverlayPanel.swift"
    "Sources/UI/Overlay/DictationMeterPolicy.swift"
    "Sources/UI/Overlay/MeetingLiveViewAffordancePolicy.swift"
    "Sources/UI/Overlay/MeetingPillRestPolicy.swift"
    "Sources/Support/MeetingOverlayPillPreferences.swift"
    "Sources/UI/Overlay/DictationCancelHintPolicy.swift"
    "Sources/UI/Overlay/DictationNoSpeechPresentationPolicy.swift"
    "Sources/UI/Overlay/DictationMicrophoneLoadingPresentationPolicy.swift"
    "Sources/UI/Overlay/DictationWarmupPresentationPolicy.swift"
    "Sources/UI/Overlay/DictationRecordingStartOverlayPolicy.swift"
    "Sources/UI/Shared/MeetingAudioArchiveResolver.swift"
    "Sources/UI/Shared/MeetingAudioPlayback.swift"
    "Sources/UI/Shared/RecentCaptureScanners.swift"
    "Sources/UI/Shared/RecentMeetingMetadataCache.swift"
    "Sources/UI/Shared/HomeCaptureRefreshObserver.swift"
    "Sources/UI/Shared/SpeakerReviewQueueScanner.swift"
    "Sources/UI/Settings/TypingTimeSavedFormatter.swift"
    "Sources/UI/Settings/AutoEnterDisplayNameResolver.swift"
    "Sources/UI/Overlay/MeetingDurationFormatter.swift"
    "Sources/UI/Overlay/LiveTranscriptPlainTextRenderer.swift"
    "Sources/Meeting/MeetingStartFailureClassifier.swift"
    "Sources/Meeting/MeetingSystemAudioStatusCopy.swift"
    "Sources/UI/Settings/HomePresentation.swift"
    "Sources/UI/Settings/HomeSearchMatching.swift"
    "Sources/Capture/PhysicalShortcutMatcher.swift"
)

# Fail early on a stale APP_SOURCES entry (renamed or deleted source) so the
# error names the missing path instead of a raw swiftc 'no such file' dump.
missing_app_sources=()
for app_source in "${APP_SOURCES[@]}"; do
    if [ ! -f "$app_source" ]; then
        missing_app_sources+=("$app_source")
    fi
done
if [ "${#missing_app_sources[@]}" -gt 0 ]; then
    echo "APP_SOURCES lists files that no longer exist on disk:"
    printf '  - %s\n' "${missing_app_sources[@]}"
    echo "Update the APP_SOURCES list in $0 to match the current tree."
    exit 1
fi

TEST_BINARY="$BUILD_DIR/tests"

if [ "$coverage_requested" = true ]; then
    mkdir -p "$COVERAGE_DIR"
    rm -f "$COVERAGE_DIR"/*.profraw "$COVERAGE_PROFDATA" "$COVERAGE_SUMMARY" "$COVERAGE_LCOV"
    TEST_BINARY="$COVERAGE_DIR/tests"
fi

echo "Compiling tests..."
SWIFTC_ARGS=(
    swiftc
)

if [ "$coverage_requested" = true ]; then
    SWIFTC_ARGS+=(
        -profile-generate
        -profile-coverage-mapping
    )
fi

SWIFTC_ARGS+=(
    "${FAST_TEST_SOURCES[@]}"
    "${APP_SOURCES[@]}"
    -framework AppKit
    -framework AVFoundation
    -framework ApplicationServices
    -framework Carbon
    -framework CoreMedia
    -framework CoreMediaIO
    -framework EventKit
    -framework FoundationModels
    -framework Network
    -framework ScreenCaptureKit
    -lsqlite3
    -parse-as-library
    -o "$TEST_BINARY"
)

compile_status=0
"${SWIFTC_ARGS[@]}" 2>&1 || compile_status=$?
if [ "$compile_status" -ne 0 ]; then
    echo ""
    echo "+------------------------------------------------------------------+"
    echo "| Fast-test compile failed.                                        |"
    echo "| A 'cannot find ... in scope' usually means a manifest entry or   |"
    echo "| APP_SOURCES file is missing or out of date.                      |"
    echo "| Check Tests/FastTests.manifest and the APP_SOURCES list in this  |"
    echo "| runner before chasing the swiftc output above.                   |"
    echo "+------------------------------------------------------------------+"
    exit "$compile_status"
fi

echo "Running tests..."
echo ""

print_failure_rerun_hint() {
    echo ""
    echo "Re-run one suite with: bash run-tests.sh --filter <entryFn>"
}

if [ "$coverage_requested" = true ]; then
    run_status=0
    LLVM_PROFILE_FILE="$COVERAGE_DIR/default-%p.profraw" TRANSCRIPTED_DISABLE_FILE_LOGGER=1 "$TEST_BINARY" || run_status=$?
    if [ "$run_status" -ne 0 ]; then
        print_failure_rerun_hint
        exit "$run_status"
    fi

    profraw_files=("$COVERAGE_DIR"/*.profraw)
    if [ ! -e "${profraw_files[0]}" ]; then
        echo "No LLVM profile data was written under $COVERAGE_DIR"
        exit 1
    fi

    llvm_profdata="${LLVM_PROFDATA:-}"
    if [ -z "$llvm_profdata" ]; then
        llvm_profdata="$(xcrun --find llvm-profdata)"
    fi

    llvm_cov="${LLVM_COV:-}"
    if [ -z "$llvm_cov" ]; then
        llvm_cov="$(xcrun --find llvm-cov)"
    fi

    echo ""
    echo "Writing coverage artifacts..."
    "$llvm_profdata" merge -sparse "${profraw_files[@]}" -o "$COVERAGE_PROFDATA"
    "$llvm_cov" report "$TEST_BINARY" \
        -instr-profile="$COVERAGE_PROFDATA" \
        -ignore-filename-regex="$COVERAGE_IGNORE_REGEX" \
        > "$COVERAGE_SUMMARY"
    "$llvm_cov" export "$TEST_BINARY" \
        -instr-profile="$COVERAGE_PROFDATA" \
        -format=lcov \
        -ignore-filename-regex="$COVERAGE_IGNORE_REGEX" \
        > "$COVERAGE_LCOV"

    echo "Coverage summary: $COVERAGE_SUMMARY"
    echo "Coverage LCOV: $COVERAGE_LCOV"
else
    run_status=0
    TRANSCRIPTED_DISABLE_FILE_LOGGER=1 "$TEST_BINARY" || run_status=$?
    if [ "$run_status" -ne 0 ]; then
        print_failure_rerun_hint
        exit "$run_status"
    fi
fi
