#!/bin/bash
# Compile the actual Speakers model and store against the real Core archive.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
OUT_DIR="$REPO_ROOT/build/speaker-settings-model-tests"
if [ ! -f deps-libs/libDraftDeps.a ] || [ ! -d deps-modules/TranscriptedCore.swiftmodule ]; then
    echo "Dependencies not found — run build-deps.sh first."
    exit 1
fi
mkdir -p "$OUT_DIR"
module_flags=(-I "$REPO_ROOT/deps-modules")
for dir in "$REPO_ROOT"/deps-modules/*/; do
    [ -d "$dir" ] || continue
    case "$(basename "$dir")" in *.swiftmodule) continue ;; esac
    module_flags+=(-I "$dir")
done
swiftc -parse-as-library -target arm64-apple-macos26.0 -O \
    "${module_flags[@]}" -F "$REPO_ROOT/deps-frameworks" \
    -L "$REPO_ROOT/deps-libs" -lDraftDeps \
    -Xlinker -rpath -Xlinker "$REPO_ROOT/deps-frameworks" \
    -framework AppKit -framework SwiftUI -framework AVFoundation -framework Combine \
    -framework CoreML -framework CoreAudio -framework Metal -framework MetalKit \
    -framework Accelerate -framework Network -framework UserNotifications -lc++ \
    Sources/Support/CoalescedRefreshState.swift \
    Sources/Support/SpeakerNameSelectionPolicy.swift \
    Sources/Meeting/SpeakerReviewChannel.swift \
    Sources/Meeting/SpeakerNamingStanding.swift \
    Sources/Meeting/SpeakerPeopleReviewPolicy.swift \
    Sources/Meeting/SpeakerClipLibrary.swift \
    Sources/Meeting/SpeakerSettingsStore.swift \
    Sources/Meeting/SpeakerSilentNameCorrectionTelemetry.swift \
    Sources/Observability/SpeakerRecognitionTelemetry.swift \
    Sources/UI/Shared/HomeMeetingPreviewFormatter.swift \
    Sources/UI/Shared/SpeakerReviewSamplePolicy.swift \
    Sources/UI/Shared/SpeakerReviewQueueScanner.swift \
    Sources/UI/Shared/SpeakerNamingTierPresentation.swift \
    Sources/UI/Settings/SpeakerDuplicateNameMatching.swift \
    Sources/UI/Settings/SpeakerDuplicateDetection.swift \
    Sources/UI/Settings/SpeakerMergeTargets.swift \
    Sources/UI/Settings/SpeakerReviewCardProgress.swift \
    Sources/UI/Settings/SpeakerReviewStack.swift \
    Sources/UI/Settings/SpeakerReviewSession.swift \
    Sources/UI/Settings/SpeakerPeopleSettingsViewModel.swift \
    Sources/UI/Settings/SpeakerPeopleSettingsViewModel+Review.swift \
    Sources/UI/Settings/SpeakerPeopleSettingsViewModel+Duplicates.swift \
    Tests/Integration/SpeakerSettingsModelScaffold.swift \
    Tests/Integration/SpeakerSettingsModelSmoke.swift \
    -o "$OUT_DIR/model-smoke" 2>&1 | tee "$OUT_DIR/compile.log"
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 "$OUT_DIR/model-smoke"
