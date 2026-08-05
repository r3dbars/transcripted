#!/bin/bash
# run-tests.sh — Compile and run Transcripted's fast utility test suite
# Root Tests/*Tests.swift files are discovered by convention. FooTests.swift
# must expose exactly one top-level entry function named testFoo().

set -euo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

source "$ENTRYPOINT_DIR/lib/shared-smoke-sources.sh"

BUILD_DIR="build"
# Keep this path stable so Swift's incremental dependency graph can recognize
# the generated runner across filtered invocations.
# PID-suffixed so two concurrent invocations cannot clobber each other's
# generated runner source. Trade-off: this one generated file is never
# incremental-compile-warm across invocations; the (much larger) APP_SOURCES
# set is what the persistent cache below keeps warm.
GENERATED_RUNNER="$BUILD_DIR/FastTestRunner.$$.swift"
CACHE_ROOT="$REPO_ROOT/$BUILD_DIR/fast-tests-cache"
CACHE_INPUT="$REPO_ROOT/$BUILD_DIR/.fast-tests-cache-input.$$"
CACHE_OUTPUT_MAP=""
TEST_OBJECT_DIR=""
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
cache_enabled=true

case "${TRANSCRIPTED_FAST_TESTS_NO_CACHE:-0}" in
    1|true|TRUE|yes|YES)
        cache_enabled=false
        ;;
esac

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
            echo "Set TRANSCRIPTED_FAST_TESTS_NO_CACHE=1 to disable the persistent app-source compile cache."
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

# Redirect the entire app-owned Transcripted container (Home meeting cache,
# speakers/stats SQLite, logs, and tmp) into a throwaway dir for the run so
# tests can never write fixture rows into ~/Library/Application Support/
# Transcripted. Exported before the test binary launches because
# RecentMeetingMetadataCache.shared is a `static let` that captures its DB path at
# first access — the redirect has to be in the environment from the start.
TRANSCRIPTED_CONTAINER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/transcripted-test-container.XXXXXX")"
export TRANSCRIPTED_CONTAINER_DIR

# The shared app-object cache is mutated and compiled into in place, so two
# overlapping run-tests.sh invocations in one worktree must not interleave.
# mkdir is the portable atomic lock on macOS (no flock(1)); locks older than
# 30 minutes are treated as crashed holders and stolen.
CACHE_LOCK_DIR=""
acquire_cache_lock() {
    # CACHE_LOCK_DIR doubles as the "we own the lock" flag consumed by
    # release_cache_lock (and the EXIT trap). It must only be assigned AFTER
    # mkdir succeeds — a process killed while still *waiting* must not rmdir
    # the lock another process is actively holding.
    local lock_dir="$CACHE_ROOT/.lock"
    local announced=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        # Stale-steal heuristic for crashed holders. There is no heartbeat, so
        # a legitimately-running holder longer than this window could have its
        # lock stolen — 60 minutes is far above any observed full run
        # (~2 min) or cold coverage build, trading that residual risk against
        # an unrecoverable deadlock after a crash.
        if [ -n "$(find "$lock_dir" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
            rm -rf "$lock_dir"
            continue
        fi
        if [ "$announced" -eq 0 ]; then
            echo "Fast-test app-source cache: waiting for a concurrent run to release the cache lock..."
            announced=1
        fi
        sleep 2
    done
    CACHE_LOCK_DIR="$lock_dir"
}
release_cache_lock() {
    if [ -n "$CACHE_LOCK_DIR" ]; then
        rmdir "$CACHE_LOCK_DIR" 2>/dev/null || true
        CACHE_LOCK_DIR=""
    fi
}

cleanup_generated_runner() {
    release_cache_lock
    rm -f "$GENERATED_RUNNER"
    if [ -n "$CACHE_OUTPUT_MAP" ]; then
        rm -f "$CACHE_OUTPUT_MAP"
    fi
    rm -f "$CACHE_INPUT"
    if [ -n "$TEST_OBJECT_DIR" ]; then
        rm -rf "$TEST_OBJECT_DIR"
    fi
    rm -rf "$TRANSCRIPTED_CONTAINER_DIR"
}
trap cleanup_generated_runner EXIT

actual_files=$(
    find Tests -maxdepth 1 -name '*Tests.swift' -exec basename {} \; | \
    sort
)

if [ -z "$actual_files" ]; then
    echo "No root fast tests found at Tests/*Tests.swift"
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
    echo "Rename to <Name>Tests.swift with a test<Name>() entry, or add the shared file to this runner's compile list."
    exit 1
fi

# Derive deterministic file:function rows and fail with a precise convention
# error before swiftc sees the generated runner. The per-file count catches a
# missing or duplicated entry function; filenames make cross-file entry names
# unique by construction.
test_entries=""
known_entry_functions=""
while IFS= read -r test_file; do
    [ -z "$test_file" ] && continue
    base_name="${test_file%Tests.swift}"
    if [ -z "$base_name" ] || [ "$base_name" = "$test_file" ]; then
        echo "Invalid fast test filename: Tests/$test_file"
        echo "Expected <Name>Tests.swift."
        exit 1
    fi
    entry_function="test${base_name}"
    definition_count="$(
        grep -Ec "func[[:space:]]+${entry_function}[[:space:]]*\\(" "Tests/$test_file" || true
    )"
    if [ "$definition_count" -eq 0 ]; then
        echo "Fast test entry function not found: $entry_function (expected in Tests/$test_file)"
        exit 1
    fi
    if [ "$definition_count" -ne 1 ]; then
        echo "Fast test entry function is duplicated: $entry_function ($definition_count declarations in Tests/$test_file)"
        exit 1
    fi
    if [ -n "$test_entries" ]; then
        test_entries="${test_entries}
${test_file}:${entry_function}"
        known_entry_functions="${known_entry_functions}
${entry_function}"
    else
        test_entries="${test_file}:${entry_function}"
        known_entry_functions="$entry_function"
    fi
done <<EOF
$actual_files
EOF

if [ "$list_only" = true ]; then
    printf '%s\n' "$known_entry_functions"
    exit 0
fi

if [ -n "$filter_selector" ]; then
    selector_lower=$(printf '%s' "$filter_selector" | tr '[:upper:]' '[:lower:]')
    filtered_entries=$(
        printf '%s\n' "$test_entries" | \
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

    test_entries="$filtered_entries"
fi

mkdir -p "$BUILD_DIR"

cat > "$GENERATED_RUNNER" <<'EOF'
// Generated by run-tests.sh from root Tests/*Tests.swift naming conventions.

import Foundation

@main
struct FastTestRunner {
    static func main() async {
        print("Transcripted Fast Test Suite\n")
EOF

while IFS=':' read -r test_file entry_function; do
    printf '        await runEntry(%s)\n' "$entry_function" >> "$GENERATED_RUNNER"
done <<EOF
$test_entries
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
$test_entries
EOF

APP_SOURCES=(
    ${SHARED_TEST_STORAGE_SOURCES[@]+"${SHARED_TEST_STORAGE_SOURCES[@]}"}
    ${SHARED_PASTEBACK_SUPPORT_SOURCES[@]+"${SHARED_PASTEBACK_SUPPORT_SOURCES[@]}"}
    "Sources/Support/ActivationPolicyController.swift"
    "Sources/Support/TranscriptedPermissionKind.swift"
    "Sources/Support/TranscriptedPermissionAccess.swift"
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
    "Sources/Support/SpeechModelBetaPreferences.swift"
    "Sources/Support/TranscriptionModelPreferences.swift"
    "Sources/Support/ExistingInstallModelPrefetchPolicy.swift"
    "Sources/Support/ModelCacheInventory.swift"
    "Sources/Support/SingleInstanceGuard.swift"
    "Sources/Support/DictationAutoSendPreferences.swift"
    "Sources/Support/DictationPersistentInputPreferences.swift"
    "Sources/Support/DictationCleanupPreferences.swift"
    "Sources/Support/DictationOverlayPresentationPreferences.swift"
    "Sources/Support/DictationFillerCleanupPolicy.swift"
    "Sources/Accessibility/AccessibilityBridge.swift"
    "Sources/Dictation/DictationSessionTimeout.swift"
    "Sources/Dictation/DictationStoppedAudioRecovery.swift"
    "Sources/Dictation/DictationStopFinalizationPolicy.swift"
    "Sources/Speech/DictationInputDeviceSelectionPolicy.swift"
    "Sources/Speech/DictationReadinessWaitPolicy.swift"
    "Sources/Speech/DictationSessionTypes.swift"
    "Sources/Speech/ParakeetModelInitDiagnostics.swift"
    "Sources/Speech/ParakeetModelState.swift"
    "Sources/Speech/ParakeetPrewarmPolicy.swift"
    "Sources/Speech/ParakeetAudioGraphOwnership.swift"
    "Sources/Speech/ParakeetRecoveryState.swift"
    "Sources/Speech/ParakeetStartRecordingFailurePolicy.swift"
    "Sources/Speech/ParakeetShortAudioGate.swift"
    "Sources/Speech/ParakeetSystemWakePolicy.swift"
    "Sources/Speech/DictationAudioRecovery.swift"
    "Sources/Speech/RecordedAudioTimeline.swift"
    "Sources/Speech/SharedMeetingMicRecorder.swift"
    "Sources/Speech/SharedMeetingMicClaim.swift"
    "Sources/Speech/DictationAudioLevelMeter.swift"
    "Sources/TranscriptedCore/Utilities/SupersessionEpoch.swift"
    "Sources/Speech/TranscriptionModelWarmupOwnership.swift"
    "Sources/Speech/DefaultInputDeviceMonitorSupport.swift"
    "Sources/Meeting/MeetingSessionState.swift"
    "Sources/Meeting/MeetingSessionStateMachine.swift"
    "Sources/Meeting/MeetingRecordingStartGate.swift"
    "Sources/Meeting/MeetingCaptureSupport.swift"
    "Sources/Meeting/MeetingMicPCMRelay.swift"
    "Sources/Meeting/MeetingCaptureHealthTelemetry.swift"
    "Sources/Meeting/MeetingFailureExplanation.swift"
    "Sources/Meeting/MeetingFailureCopy.swift"
    "Sources/Meeting/MeetingFailureKind.swift"
    "Sources/Meeting/MeetingPromptDetector.swift"
    "Sources/Meeting/MeetingPromptRecordAction.swift"
    "Sources/Meeting/MeetingPromptHeuristics.swift"
    "Sources/Meeting/MeetingPromptTelemetry.swift"
    "Sources/Meeting/MicActivityMonitor.swift"
    "Sources/Meeting/CameraActivityMonitor.swift"
    "Sources/Meeting/SustainedActivityConfirmer.swift"
    "Sources/Meeting/MeetingAudioInactivityDetector.swift"
    "Sources/Meeting/MeetingAudioStorageManager.swift"
    "Sources/Meeting/ImportedTranscriptionQueueJournalState.swift"
    "Sources/Meeting/MeetingImportedAudioPreparer.swift"
    "Sources/Meeting/MeetingImportPreparationFailureCopy.swift"
    "Sources/Meeting/MeetingSessionUIPolicy.swift"
    "Sources/Meeting/MeetingMicBoostPromptPolicy.swift"
    "Sources/Meeting/MeetingWarmupStatusPolicy.swift"
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
    "Sources/Observability/DictationPasteRetryTelemetry.swift"
    "Sources/Observability/SpeakerRecognitionTelemetry.swift"
    "Sources/Observability/ActivationTelemetry.swift"
    "Sources/Observability/AgentSetupLifecycleTelemetry.swift"
    "Sources/Observability/FeatureDiscoveryTelemetry.swift"
    "Sources/Observability/LockedFileAppender.swift"
    "Sources/Observability/AnalyticsEventPolicy.swift"
    "Sources/Observability/UpdateActionSafetyPolicy.swift"
    "Sources/Observability/ObservabilityLogRotation.swift"
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
    "Sources/TranscriptedCore/Models/SpeakerMapping.swift"
    "Sources/TranscriptedCore/Models/FailedTranscription.swift"
    "Sources/TranscriptedCore/Speaker/SpeakerMatchOutcome.swift"
    "Sources/TranscriptedCore/Speaker/SpeakerNamingPolicy.swift"
    "Sources/TranscriptedCore/Speaker/SpeakerPeopleReviewPolicy.swift"
    "Sources/TranscriptedCore/Storage/TranscriptFormatOptions.swift"
    "Sources/Support/SpeakerNameSelectionPolicy.swift"
    "Sources/UI/Shared/AgentConnectionGuide.swift"
    "Sources/UI/Shared/FeedbackIssueBuilder.swift"
    "Sources/UI/Shared/FirstRunExperience.swift"
    "Sources/UI/Shared/AppSoundPlayer.swift"
    "Sources/UI/Shared/FocusOrderContract.swift"
    "Sources/UI/Settings/TranscriptedSettingsPage.swift"
    "Sources/UI/Settings/SettingsRecentCaptureRefreshPolicy.swift"
    "Sources/UI/Settings/HomeDeleteConfirmationPolicy.swift"
    "Sources/UI/Settings/OnboardingAbandonmentReasonPolicy.swift"
    "Sources/UI/Settings/HomeRootAlertPolicy.swift"
    "Sources/UI/Settings/HomeScanWarningPolicy.swift"
    "Sources/UI/Settings/HomeCanvasGreeting.swift"
    "Sources/UI/Shared/OwnFileResolver.swift"
    "Sources/UI/Shared/HomeMeetingRowActionTargets.swift"
    "Sources/UI/Shared/HomeMeetingRename.swift"
    "Sources/UI/Settings/HomeMeetingSummaryBetaPresentationPolicy.swift"
    "Sources/UI/Settings/SpeakerVoiceRowPresentation.swift"
    "Sources/UI/Settings/HomeFailedMeetingInlinePresentation.swift"
    "Sources/UI/Settings/FailedMeetingRecoveryPresentation.swift"
    "Sources/UI/Settings/HomeTranscriptionActivityCopy.swift"
    "Sources/UI/Overlay/CapturePillController.swift"
    "Sources/UI/Overlay/CapturePillPlacementPolicy.swift"
    "Sources/UI/Overlay/FloatingOverlayPanel.swift"
    "Sources/UI/Overlay/DictationOverlayPlacementPolicy.swift"
    "Sources/UI/Overlay/DictationMeterPolicy.swift"
    "Sources/UI/Overlay/MeetingLiveViewAffordancePolicy.swift"
    "Sources/UI/Overlay/MeetingPillRestPolicy.swift"
    "Sources/UI/Overlay/MeetingPromptPriority.swift"
    "Sources/Support/MeetingOverlayPillPreferences.swift"
    "Sources/UI/Overlay/DictationCancelHintPolicy.swift"
    "Sources/UI/Overlay/DictationNoSpeechPresentationPolicy.swift"
    "Sources/UI/Overlay/DictationMicrophoneLoadingPresentationPolicy.swift"
    "Sources/UI/Overlay/DictationWarmupPresentationPolicy.swift"
    "Sources/UI/Overlay/DictationRecordingStartOverlayPolicy.swift"
    "Sources/UI/Shared/MeetingAudioPlayback.swift"
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

CACHE_SWIFTC_FLAGS=(
    -parse-as-library
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
)

if [ "$coverage_requested" = true ]; then
    CACHE_SWIFTC_FLAGS+=(
        -profile-generate
        -profile-coverage-mapping
    )
fi

write_output_file_map() {
    local output_map="$1"
    local app_object_dir="$2"
    local test_object_dir="$3"
    local test_index=0
    local app_index=0
    local first_entry=true
    local source
    local object_stem
    local object_dir

    mkdir -p "$app_object_dir" "$test_object_dir"
    {
        echo "{"
        for source in "${FAST_TEST_SOURCES[@]}"; do
            if [ "$first_entry" = false ]; then
                echo ","
            fi
            first_entry=false
            object_dir="$test_object_dir"
            object_stem="test-$test_index"
            printf '  "%s": {"dependencies": "%s/%s~partial.swiftdeps", "object": "%s/%s.o", "swift-dependencies": "%s/%s.swiftdeps"}' \
                "$source" "$object_dir" "$object_stem" "$object_dir" "$object_stem" "$object_dir" "$object_stem"
            test_index=$((test_index + 1))
        done
        for source in "${APP_SOURCES[@]}"; do
            if [ "$first_entry" = false ]; then
                echo ","
            fi
            first_entry=false
            object_dir="$app_object_dir"
            object_stem="app-$app_index"
            printf '  "%s": {"dependencies": "%s/%s~partial.swiftdeps", "object": "%s/%s.o", "swift-dependencies": "%s/%s.swiftdeps"}' \
                "$source" "$object_dir" "$object_stem" "$object_dir" "$object_stem" "$object_dir" "$object_stem"
            app_index=$((app_index + 1))
        done
        echo ","
        printf '  "": {"diagnostics": "%s/master.dia", "swift-dependencies": "%s/master.swiftdeps"}\n' \
            "$app_object_dir" "$app_object_dir"
        echo "}"
    } > "$output_map"
}

if [ "$cache_enabled" = true ]; then
    mkdir -p "$CACHE_ROOT"
    acquire_cache_lock
    {
        printf 'cache-format-v2\n'
        printf 'swiftc-version\n%s\n' "$(swiftc -version)"
        printf 'swiftc-flags\n'
        printf '%s\n' -incremental
        printf '%s\n' "${CACHE_SWIFTC_FLAGS[@]}"
        printf 'app-source-list\n'
        printf '%s\n' "${APP_SOURCES[@]}" | sort
        printf 'app-source-content\n'
        while IFS= read -r app_source; do
            printf '%s\t' "$app_source"
            shasum -a 256 "$app_source" | awk '{print $1}'
        done < <(printf '%s\n' "${APP_SOURCES[@]}" | sort)
    } > "$CACHE_INPUT"
    cache_key="$(shasum -a 256 "$CACHE_INPUT" | awk '{print $1}')"
    cache_dir="$CACHE_ROOT/$cache_key"
    cache_complete="$cache_dir/complete"
    if [ -f "$cache_complete" ]; then
        cache_status="hit"
    else
        cache_status="miss"
        if [ -d "$cache_dir" ]; then
            rm -rf "$cache_dir"
        fi
        mkdir -p "$cache_dir"
    fi
    TEST_OBJECT_DIR="$REPO_ROOT/$BUILD_DIR/fast-tests-run.$$"
    CACHE_OUTPUT_MAP="$cache_dir/output-file-map.json"
    write_output_file_map "$CACHE_OUTPUT_MAP" "$cache_dir/app-objects" "$TEST_OBJECT_DIR"
    echo "Fast-test app-source cache: $cache_status ($cache_dir)"
else
    cache_status="disabled"
    echo "Fast-test app-source cache: disabled"
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

if [ "$cache_enabled" = true ]; then
    SWIFTC_ARGS+=(
        -incremental
        -output-file-map "$CACHE_OUTPUT_MAP"
    )
fi

SWIFTC_ARGS+=(
    "${FAST_TEST_SOURCES[@]}"
    "${APP_SOURCES[@]}"
    "${CACHE_SWIFTC_FLAGS[@]}"
    -o "$TEST_BINARY"
)

compile_status=0
"${SWIFTC_ARGS[@]}" 2>&1 || compile_status=$?
if [ "$compile_status" -ne 0 ]; then
    echo ""
    echo "+------------------------------------------------------------------+"
    echo "| Fast-test compile failed.                                        |"
    echo "| A 'cannot find ... in scope' usually means a convention-derived |"
    echo "| test entry or APP_SOURCES file is missing or out of date.       |"
    echo "| Check <Name>Tests.swift -> test<Name>() and the APP_SOURCES     |"
    echo "| list in this runner before chasing the swiftc output above.     |"
    echo "+------------------------------------------------------------------+"
    exit "$compile_status"
fi

if [ "$cache_enabled" = true ] && [ "$cache_status" = "miss" ]; then
    touch "$cache_complete"
fi
release_cache_lock

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
