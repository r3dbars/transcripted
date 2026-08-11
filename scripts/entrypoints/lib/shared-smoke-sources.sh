# shellcheck shell=bash
# Shared swiftc source-file lists for the fast-test runner and the
# deterministic smoke binaries. These three scripts each hand-list the
# .swift files they need on a raw `swiftc` command line (no SPM target, so
# no automatic dependency discovery), and their lists overlap heavily:
#
#   run-tests.sh              (APP_SOURCES)   - fast-test support sources
#   run-e2e-smoke.sh           (SWIFT_SOURCES) - deterministic E2E smoke
#   run-slow-pasteback-smoke.sh (SWIFT_SOURCES) - pasteback timing smoke
#
# Every time a source file backing these lists moves or splits, every list
# that includes it must be updated by hand; nothing catches a *missing*
# entry (check-build-source-lists.py only catches stale/missing-on-disk
# entries in an existing list). Centralizing the overlapping subset here
# means a rename/move touches one file share by fewer scripts:
#
#   - SHARED_TEST_STORAGE_SOURCES is compiled by both run-tests.sh and
#     run-e2e-smoke.sh (storage-path/transcript/summary plumbing exercised
#     by both the fast-test suite and the deterministic E2E smoke).
#   - SHARED_PASTEBACK_SUPPORT_SOURCES is compiled by both run-tests.sh and
#     run-slow-pasteback-smoke.sh (the clipboard-restoring paster and the
#     shared app constants it reads).
#
# This file intentionally does NOT attempt full auto-discovery (e.g. `find
# Sources -name '*.swift'`) the way scripts/entrypoints/lib/swiftc-app-args.sh
# does for the full app build: these three scripts deliberately compile a
# small hand-picked subset to keep fast-test/smoke compile times low, and
# auto-discovery would pull in the whole app graph. Each script still keeps
# its own delta of files unique to it appended after these shared arrays.
#
# Outputs (bash arrays):
#   SHARED_TEST_STORAGE_SOURCES     - used by run-tests.sh + run-e2e-smoke.sh
#   SHARED_PASTEBACK_SUPPORT_SOURCES - used by run-tests.sh + run-slow-pasteback-smoke.sh
#
# Consumers run under `set -euo pipefail`, and macOS ships bash 3.2, where
# `"${ARR[@]}"` on an EMPTY array aborts with "unbound variable" under
# `set -u` (fixed in bash 4.4+, but macOS's /bin/bash never moved past 3.2).
# Every consumer must expand these arrays with the
# `${ARR[@]+"${ARR[@]}"}` guard, not a bare `"${ARR[@]}"`, so a future edit
# that empties one of these arrays doesn't hard-abort every script that
# sources this file. check-build-source-lists.py separately fails the build
# if either array is ever actually empty, so the guard here is defense in
# depth, not the primary check.

SHARED_TEST_STORAGE_SOURCES=(
    "Sources/TranscriptedCore/Protocols/ImportedTranscriptionRecoverySession.swift"
    "Sources/Support/TranscriptedStoragePaths.swift"
    "Sources/Support/CaptureLibraryPathSafety.swift"
    "Sources/Dictation/DictationStoragePaths.swift"
    "Sources/Dictation/DictationTranscriptWriter.swift"
    "Sources/Dictation/DictationTranscriptStore.swift"
    "Sources/Meeting/MeetingStoragePaths.swift"
    "Sources/Meeting/MeetingArtifactRecoveryStore.swift"
    "Sources/Meeting/MeetingArtifactRenameTransaction.swift"
    "Sources/Meeting/MeetingTranscriptStyler.swift"
    "Sources/Meeting/MeetingArtifactRenamer.swift"
    "Sources/Observability/ObservabilityTextRedactor.swift"
    "Sources/Observability/PayloadSanitizationCore.swift"
    "Sources/Observability/AnalyticsPayloadSanitizer.swift"
    "Sources/TranscriptedCore/Audio/MicRecordingSegment.swift"
    "Sources/TranscriptedCore/Logging/PrivacyTextRedactor.swift"
    "Sources/TranscriptedCore/Models/TranscriptionTypes.swift"
    "Sources/TranscriptedCore/Speaker/SpeakerProfile.swift"
    "Sources/TranscriptedCore/Storage/TranscriptFrontmatter.swift"
    "Sources/TranscriptedCore/Utilities/DateFormattingHelper.swift"
    "Sources/UI/Shared/SupportDiagnosticsBundle.swift"
    "Sources/UI/Shared/HomeMeetingDeletion.swift"
    "Sources/UI/Shared/CaptureUndo.swift"
    "Sources/UI/Shared/LibraryTokens.swift"
    "Sources/UI/Settings/HomeMeetingPreviewFormatter.swift"
    "Sources/UI/Shared/MeetingAudioArchiveResolver.swift"
    "Sources/UI/Shared/RecentCaptureScanners.swift"
    "Sources/UI/Shared/RecentMeetingMetadataCache.swift"
)

SHARED_PASTEBACK_SUPPORT_SOURCES=(
    "Sources/Support/ClipboardRestoringTextPaster.swift"
    "Sources/Support/TranscriptedConstants.swift"
    "Sources/TranscriptedCore/Utilities/SupersessionEpoch.swift"
)
