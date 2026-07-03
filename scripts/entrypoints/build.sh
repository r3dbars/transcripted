#!/bin/bash
# Build Transcripted - local dictation + meeting transcription app

set -euo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Transcripted"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
STAGED_APP_BINARY="$BUILD_DIR/$APP_NAME-bin"
LOCAL_ENTITLEMENTS="config/entitlements/local.plist"
SIGN_IDENTITY="${SIGN_IDENTITY:-${SIGNING_IDENTITY:-}}"
OPEN_APP_AFTER_BUILD="${OPEN_APP_AFTER_BUILD:-1}"
BUNDLE_PARAKEET_MODELS="${BUNDLE_PARAKEET_MODELS:-0}"
SWIFTC_NUM_THREADS="${SWIFTC_NUM_THREADS:-$(sysctl -n hw.ncpu 2>/dev/null || printf '8')}"
MCP_PACKAGE_DIR="Tools/TranscriptedMCP"
MCP_BINARY="$MCP_PACKAGE_DIR/.build/release/transcripted-mcp"
BUNDLED_MCP_BINARY="$APP_BUNDLE/Contents/Helpers/transcripted-mcp"
DEPS_ARCHIVE="deps-libs/libDraftDeps.a"
DEPS_BUILD_STAMP="deps-libs/.build-deps-stamp"
DEPS_MODULE_ROOT="deps-modules"
DEPS_FRAMEWORK_ROOT="deps-frameworks"
ESPEAK_FRAMEWORK="$DEPS_FRAMEWORK_ROOT/ESpeakNG.framework"
SENTRY_FRAMEWORK="$DEPS_FRAMEWORK_ROOT/Sentry.framework"
SPARKLE_FRAMEWORK="$DEPS_FRAMEWORK_ROOT/Sparkle.framework"
TRANSCRIPTED_CORE_MODULE="$DEPS_MODULE_ROOT/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule"
ARGMAX_CORE_MODULE="$DEPS_MODULE_ROOT/ArgmaxCore.swiftmodule/arm64-apple-macos.swiftmodule"
WHISPERKIT_MODULE="$DEPS_MODULE_ROOT/WhisperKit.swiftmodule/arm64-apple-macos.swiftmodule"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-open)
            OPEN_APP_AFTER_BUILD=0
            ;;
        --open)
            OPEN_APP_AFTER_BUILD=1
            ;;
        --thin)
            BUNDLE_PARAKEET_MODELS=0
            ;;
        --full)
            BUNDLE_PARAKEET_MODELS=1
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: bash build.sh [--no-open] [--thin|--full]"
            exit 1
            ;;
    esac
    shift
done

dependency_input_paths() {
    {
        printf '%s\n' "Package.swift"
        printf '%s\n' "scripts/entrypoints/build-deps.sh"
        find "Sources/TranscriptedCore" -type f ! -name "CLAUDE.md"
    } | sort
}

dependency_input_listing() {
    dependency_input_paths | while IFS= read -r path; do
        [ -e "$path" ] || continue
        printf '%s\t%s\n' "$(stat -f '%m' "$path")" "$path"
    done
}

dependency_input_digest() {
    dependency_input_paths | while IFS= read -r path; do
        [ -f "$path" ] || continue
        shasum -a 256 "$path"
    done | shasum -a 256 | awk '{print $1}'
}

newest_dependency_input() {
    dependency_input_listing | awk 'NR == 1 || $1 > max { max = $1; line = $0 } END { if (line != "") print line }'
}

deps_build_stamp_info() {
    if [ -f "$DEPS_BUILD_STAMP" ]; then
        printf '%s\t%s\n' "$(stat -f '%m' "$DEPS_BUILD_STAMP")" "$DEPS_BUILD_STAMP"
    fi
}

deps_build_stamp_digest() {
    if [ -f "$DEPS_BUILD_STAMP" ]; then
        awk -F= '$1 == "dependency_inputs_sha256" { print $2; exit }' "$DEPS_BUILD_STAMP"
    fi
}

ensure_build_prerequisites() {
    if [ ! -f "$LOCAL_ENTITLEMENTS" ]; then
        echo "Missing entitlements file: $LOCAL_ENTITLEMENTS"
        exit 1
    fi
}

ensure_deps_ready() {
    local newest_input
    local build_stamp
    local newest_input_mtime
    local newest_input_path
    local build_stamp_mtime
    local build_stamp_path
    local current_digest
    local stamp_digest

    if [ -f "$DEPS_ARCHIVE" ] && [ -f "$DEPS_BUILD_STAMP" ] && [ -d "$DEPS_MODULE_ROOT" ] && [ -f "$TRANSCRIPTED_CORE_MODULE" ] && [ -f "$ARGMAX_CORE_MODULE" ] && [ -f "$WHISPERKIT_MODULE" ] && [ -d "$SENTRY_FRAMEWORK" ] && [ -d "$SPARKLE_FRAMEWORK" ]; then
        newest_input="$(newest_dependency_input)"
        build_stamp="$(deps_build_stamp_info)"

        IFS=$'\t' read -r newest_input_mtime newest_input_path <<< "$newest_input"
        IFS=$'\t' read -r build_stamp_mtime build_stamp_path <<< "$build_stamp"

        if [ -n "$newest_input_mtime" ] && [ -n "$build_stamp_mtime" ] && [ "$newest_input_mtime" -gt "$build_stamp_mtime" ]; then
            echo "Dependencies are stale for TranscriptedCore."
            echo "Newest input:"
            echo "  $newest_input_path"
            echo "Built deps stamp:"
            echo "  $build_stamp_path"
            echo ""
            echo "Run: bash build-deps.sh --force"
            exit 1
        fi

        current_digest="$(dependency_input_digest)"
        stamp_digest="$(deps_build_stamp_digest)"
        if [ -z "$stamp_digest" ] || [ "$current_digest" != "$stamp_digest" ]; then
            echo "Dependencies are stale for TranscriptedCore."
            echo "Dependency input digest changed."
            echo "  current: ${current_digest:-missing}"
            echo "  stamp:   ${stamp_digest:-missing}"
            echo ""
            echo "Run: bash build-deps.sh --force"
            exit 1
        fi

        return 0
    fi

    echo "Dependencies missing or stale for TranscriptedCore."
    echo "Expected:"
    echo "  $DEPS_ARCHIVE"
    echo "  $DEPS_BUILD_STAMP"
    echo "  $DEPS_MODULE_ROOT/"
    echo "  $TRANSCRIPTED_CORE_MODULE"
    echo "  $ARGMAX_CORE_MODULE"
    echo "  $WHISPERKIT_MODULE"
    echo "  $SENTRY_FRAMEWORK"
    echo "  $SPARKLE_FRAMEWORK"
    echo ""
    echo "Run: bash build-deps.sh --force"
    exit 1
}

resolve_sign_identity() {
    local requested_identity="$1"
    local found_line

    if [ -n "$requested_identity" ]; then
        found_line="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$requested_identity" | head -1 || true)"
        if [ -z "$found_line" ]; then
            echo "Requested signing identity not found: $requested_identity"
            echo "Available identities:"
            security find-identity -v -p codesigning || true
            exit 1
        fi
        printf '%s\n' "$found_line"
        return 0
    fi

    found_line="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 || true)"
    if [ -n "$found_line" ]; then
        printf '%s\n' "$found_line"
        return 0
    fi

    printf '%s\n' ""
}

verify_signature() {
    codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
    codesign -dvvv --entitlements - "$APP_BUNDLE"
}

verify_launch_smoke() {
    local smoke_log="$REPO_ROOT/$BUILD_DIR/launch-smoke.log"
    local smoke_home="$REPO_ROOT/$BUILD_DIR/launch-smoke-home"
    local ui_report="$REPO_ROOT/$BUILD_DIR/launch-ui-smoke.json"
    local open_pid=""
    local pre_launch_app_pids=""
    rm -f "$smoke_log"
    rm -rf "$smoke_home"
    rm -f "$ui_report"
    mkdir -p "$smoke_home"

    snapshot_launch_smoke_app_pids() {
        pgrep -f "$APP_BINARY" || true
    }

    is_pre_launch_app_pid() {
        local candidate_pid="$1"
        printf '%s\n' "$pre_launch_app_pids" | grep -qx "$candidate_pid"
    }

    terminate_launch_smoke_app() {
        local app_pids
        local pid
        app_pids="$(snapshot_launch_smoke_app_pids)"
        for pid in $app_pids; do
            if ! is_pre_launch_app_pid "$pid"; then
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done
        sleep 0.5
        app_pids="$(snapshot_launch_smoke_app_pids)"
        for pid in $app_pids; do
            if ! is_pre_launch_app_pid "$pid"; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done
    }

    pre_launch_app_pids="$(snapshot_launch_smoke_app_pids)"

    /usr/bin/open -n -g -F -W \
        --stdout "$smoke_log" \
        --stderr "$smoke_log" \
        --env "CFFIXED_USER_HOME=$smoke_home" \
        --env "HOME=$smoke_home" \
        --env "TRANSCRIPTED_DISABLE_FILE_LOGGER=1" \
        --env "TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS=1" \
        --env "TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD=1" \
        --env "TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT=$ui_report" \
        --env "TRANSCRIPTED_LAUNCH_UI_SMOKE_TERMINATE_AFTER_REPORT=1" \
        "$APP_BUNDLE" >>"$smoke_log" 2>&1 &
    open_pid=$!

    for _ in $(seq 1 50); do
        if [ -s "$ui_report" ]; then
            break
        fi
        if ! kill -0 "$open_pid" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    if ! kill -0 "$open_pid" 2>/dev/null && [ ! -s "$ui_report" ]; then
        wait "$open_pid" || true
        echo "Transcripted exited during launch smoke."
        echo "Smoke log:"
        cat "$smoke_log"
        exit 1
    fi

    if [ ! -s "$ui_report" ]; then
        echo "Transcripted launch UI smoke report was not written."
        echo "Smoke log:"
        cat "$smoke_log"
        terminate_launch_smoke_app
        kill "$open_pid" 2>/dev/null || true
        wait "$open_pid" 2>/dev/null || true
        exit 1
    fi

    if ! /usr/bin/python3 - "$ui_report" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    report = json.load(handle)

errors = []
if not report.get("appLaunched"):
    errors.append("appLaunched was false")
if not report.get("statusItemExists"):
    errors.append("status item was missing")
if not report.get("popoverConfigured"):
    errors.append("popover was not configured")
if not report.get("onboardingCompleted"):
    errors.append("onboarding was not completed for smoke")

actions = report.get("content", {}).get("primaryActions", {})
for key, expected in {
    "home": ("Home", "transcripted.menubar.primary.home"),
    "startDictation": ("Start Dictation", "transcripted.menubar.primary.start-dictation"),
    "startMeeting": ("Start Meeting", "transcripted.menubar.primary.start-meeting"),
    "pasteLastDictation": ("Paste Last Dictation", "transcripted.menubar.primary.paste-last-dictation"),
    "recentMeetings": ("Recent Meetings", "transcripted.menubar.primary.recent-meetings"),
}.items():
    expected_title, expected_identifier = expected
    row = actions.get(key) or {}
    if row.get("title") != expected_title:
        errors.append(f"{key} title was {row.get('title')!r}")
    if row.get("automationIdentifier") != expected_identifier:
        errors.append(f"{key} automation identifier was {row.get('automationIdentifier')!r}")
    if not row.get("isVisible"):
        errors.append(f"{key} row was hidden")
for key in ("home", "startDictation", "startMeeting"):
    row = actions.get(key) or {}
    if not row.get("isEnabled"):
        errors.append(f"{key} row was disabled")

utility_actions = report.get("content", {}).get("utilityActions", {})
for key, expected in {
    "connectAgent": ("Connect Agent", "transcripted.menubar.utility.connect-agent"),
    "submitFeedback": ("Submit feedback", "transcripted.menubar.utility.submit-feedback"),
    "checkUpdates": ("Check for Updates", "transcripted.menubar.utility.check-updates"),
    "settings": ("Settings", "transcripted.menubar.utility.settings"),
    "quit": ("Quit", "transcripted.menubar.utility.quit"),
}.items():
    expected_title, expected_identifier = expected
    row = utility_actions.get(key) or {}
    if row.get("title") != expected_title:
        errors.append(f"{key} title was {row.get('title')!r}")
    if row.get("automationIdentifier") != expected_identifier:
        errors.append(f"{key} automation identifier was {row.get('automationIdentifier')!r}")
    if not row.get("isVisible"):
        errors.append(f"{key} row was hidden")
for key in ("connectAgent", "submitFeedback", "settings", "quit"):
    row = utility_actions.get(key) or {}
    if not row.get("isEnabled"):
        errors.append(f"{key} row was disabled")

header = report.get("content", {}).get("header", {})
if header.get("statusText") not in ("Ready", "On demand", "Cached"):
    errors.append(f"unexpected header status {header.get('statusText')!r}")

if errors:
    print("Launch UI smoke failed:")
    for error in errors:
        print(f"- {error}")
    sys.exit(1)
PY
    then
        terminate_launch_smoke_app
        kill "$open_pid" 2>/dev/null || true
        wait "$open_pid" 2>/dev/null || true
        exit 1
    fi

    if ! wait "$open_pid"; then
        echo "Transcripted exited with an error during launch smoke."
        echo "Smoke log:"
        cat "$smoke_log"
        exit 1
    fi
}

sign_embedded_code() {
    local sign_hash="$1"
    local framework_path
    local metallib_path
    local nested_code_path
    local helper_path

    while IFS= read -r -d '' nested_code_path; do
        codesign --force --sign "$sign_hash" "$nested_code_path"
    done < <(
        find "$APP_BUNDLE/Contents/Frameworks" \
            \( -path "*/Sparkle.framework/Versions/*/Updater.app" \
            -o -path "*/Sparkle.framework/Versions/*/XPCServices/*.xpc" \
            -o -path "*/Sparkle.framework/Versions/*/Autoupdate" \) \
            -print0 | sort -z
    )

    for framework_path in "$APP_BUNDLE"/Contents/Frameworks/*.framework; do
        [ -d "$framework_path" ] || continue
        codesign --force --sign "$sign_hash" "$framework_path"
    done

    for metallib_path in "$APP_BUNDLE"/Contents/MacOS/*.metallib; do
        [ -f "$metallib_path" ] || continue
        codesign --force --sign "$sign_hash" "$metallib_path"
    done

    for helper_path in "$APP_BUNDLE"/Contents/Helpers/*; do
        [ -f "$helper_path" ] || continue
        codesign --force --sign "$sign_hash" "$helper_path"
    done
}

bundle_mcp_server() {
    echo "Building Transcripted MCP server..."
    swift build -c release --package-path "$MCP_PACKAGE_DIR"

    if [ ! -x "$MCP_BINARY" ]; then
        echo "MCP build finished without a runnable binary: $MCP_BINARY"
        exit 1
    fi

    cp "$MCP_BINARY" "$BUNDLED_MCP_BINARY"
    chmod 755 "$BUNDLED_MCP_BINARY"
}

echo "Building Transcripted..."

ensure_build_prerequisites
ensure_deps_ready
ORIGINAL_SENTRY_RELEASE_WAS_SET=0
ORIGINAL_SENTRY_DIST_WAS_SET=0
if [ "${SENTRY_RELEASE+x}" = "x" ]; then
    ORIGINAL_SENTRY_RELEASE_WAS_SET=1
    ORIGINAL_SENTRY_RELEASE="$SENTRY_RELEASE"
fi
if [ "${SENTRY_DIST+x}" = "x" ]; then
    ORIGINAL_SENTRY_DIST_WAS_SET=1
    ORIGINAL_SENTRY_DIST="$SENTRY_DIST"
fi
SENTRY_METADATA="$(python3 scripts/release/sentry-release-metadata.py --format shell Info.plist)"
eval "$SENTRY_METADATA"
BUILD_SENTRY_RELEASE="$SENTRY_RELEASE"
BUILD_SENTRY_DIST="$SENTRY_DIST"
if [ "$ORIGINAL_SENTRY_RELEASE_WAS_SET" = "1" ]; then
    export SENTRY_RELEASE="$ORIGINAL_SENTRY_RELEASE"
else
    unset SENTRY_RELEASE
fi
if [ "$ORIGINAL_SENTRY_DIST_WAS_SET" = "1" ]; then
    export SENTRY_DIST="$ORIGINAL_SENTRY_DIST"
else
    unset SENTRY_DIST
fi
echo "Sentry metadata: release=$BUILD_SENTRY_RELEASE dist=$BUILD_SENTRY_DIST"

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Helpers"

# Bundle the Parakeet model directory used by the runtime loader.
PARAKEET_MODELS_ROOT="$HOME/Library/Application Support/FluidAudio/Models"
PARAKEET_BUNDLE_DIR="$APP_BUNDLE/Contents/Resources/parakeet-models"
# FluidAudio 0.15.x cache folder name (no -coreml suffix); AsrModels.load(from:)
# resolves <parent>/<folderName>, so the bundled dir must use this exact name.
PARAKEET_MODEL_DIR="parakeet-tdt-0.6b-v3"

bundled_parakeet_models=false
model_src="$PARAKEET_MODELS_ROOT/$PARAKEET_MODEL_DIR"
if [ ! -d "$model_src" ]; then
    # Dev machine still on a pre-0.15 cache layout.
    model_src="$PARAKEET_MODELS_ROOT/parakeet-tdt-0.6b-v3-coreml"
fi
if [ "$BUNDLE_PARAKEET_MODELS" = "0" ]; then
    echo "Skipping bundled Parakeet models (--thin); runtime download will occur on first use."
else
    mkdir -p "$PARAKEET_BUNDLE_DIR"
    # JointDecisionv3.mlmodelc is required by FluidAudio 0.15.x; bundling without it
    # would make the runtime loader try to download into the signed app bundle.
    if [ -d "$model_src/Encoder.mlmodelc" ] && [ -d "$model_src/JointDecisionv3.mlmodelc" ]; then
        echo "Bundling Parakeet models from $model_src..."
        rm -rf "$PARAKEET_BUNDLE_DIR/$PARAKEET_MODEL_DIR"
        ditto "$model_src" "$PARAKEET_BUNDLE_DIR/$PARAKEET_MODEL_DIR"
        bundled_parakeet_models=true
    elif [ -d "$model_src/Encoder.mlmodelc" ]; then
        echo "Parakeet cache at $model_src predates FluidAudio 0.15 (missing JointDecisionv3.mlmodelc) — skipping bundling"
    fi
fi

if [ "$BUNDLE_PARAKEET_MODELS" != "0" ] && [ "$bundled_parakeet_models" = false ]; then
    echo "Parakeet models not found — Parakeet engine will attempt runtime download"
fi

# Bundle the ERes2Net speaker-embedding CoreML model — OFF by default.
# The weights derive from VoxCeleb2 (research-only license), so distribution builds
# must NOT redistribute them. Local/dev testing still works without bundling because
# the app resolves the model from the FluidAudio Models cache at runtime. To make a
# self-contained local build that bundles the model, set TRANSCRIPTED_BUNDLE_ERES2NET=1.
ERES2NET_SRC="$HOME/Library/Application Support/FluidAudio/Models/eres2net-embedding"
ERES2NET_DEST="$APP_BUNDLE/Contents/Resources/eres2net-embedding"
if [ "${TRANSCRIPTED_BUNDLE_ERES2NET:-0}" = "1" ] && [ -d "$ERES2NET_SRC/Model.mlmodelc" ]; then
    echo "Bundling ERes2Net speaker-embedding model (TRANSCRIPTED_BUNDLE_ERES2NET=1)..."
    mkdir -p "$ERES2NET_DEST"
    rm -rf "$ERES2NET_DEST/Model.mlmodelc"
    ditto "$ERES2NET_SRC/Model.mlmodelc" "$ERES2NET_DEST/Model.mlmodelc"
else
    echo "ERes2Net model not bundled (default; VoxCeleb2 license) — runtime uses the local cache. Set TRANSCRIPTED_BUNDLE_ERES2NET=1 to bundle for a local build."
fi

# Copy Info.plist
cp Info.plist "$APP_BUNDLE/Contents/"
/usr/libexec/PlistBuddy -c "Set :TranscriptedBuildChannel local" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :TranscriptedBuildChannel string local" "$APP_BUNDLE/Contents/Info.plist"
BUILD_REVISION="$(git rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')"
/usr/libexec/PlistBuddy -c "Set :TranscriptedBuildRevision $BUILD_REVISION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :TranscriptedBuildRevision string $BUILD_REVISION" "$APP_BUNDLE/Contents/Info.plist"

# Copy bundled app resources (custom sounds, etc.) when present
if [ -d "Resources" ]; then
    cp -R Resources/. "$APP_BUNDLE/Contents/Resources/"
fi

bundle_mcp_server

# Unified dependencies (FluidAudio + mlx-swift-lm + WhisperKit)
echo "Dependencies found"

# Shared frameworks/linker/source arguments — single source of truth with
# build-beta.sh so dev and shipped builds cannot diverge.
source "$ENTRYPOINT_DIR/lib/swiftc-app-args.sh"
build_app_swiftc_args

# Bundle Metal libraries if present
# MLX searches for mlx.metallib next to the binary first (Contents/MacOS/)
for metallib in deps-libs/*.metallib; do
    [ -f "$metallib" ] && cp "$metallib" "$APP_BUNDLE/Contents/MacOS/"
done

# ESpeakNG.framework is only present on FluidAudio < 0.15 deps builds.
[ -d "$ESPEAK_FRAMEWORK" ] && cp -R "$ESPEAK_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
cp -R "$SENTRY_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"

# Third-party license texts ship with the app: eSpeak NG is GPL-3.0 and the
# rest (MIT/Apache) require notice preservation in distributed binaries.
cp THIRD_PARTY_LICENSES.md "$APP_BUNDLE/Contents/Resources/"

# Compile
echo "Compiling..."
echo "Swift compiler threads: $SWIFTC_NUM_THREADS"
rm -f "$STAGED_APP_BINARY"
swiftc \
    -O \
    -whole-module-optimization \
    -num-threads "$SWIFTC_NUM_THREADS" \
    -o "$STAGED_APP_BINARY" \
    "${APP_SWIFTC_LINK_ARGS[@]}" \
    "${APP_SOURCE_FILES[@]}" \
    "${APP_SWIFTC_TAIL_ARGS[@]}" \
    2>&1

mv "$STAGED_APP_BINARY" "$APP_BINARY"

if [ ! -x "$APP_BINARY" ]; then
    echo "Build finished without a runnable app binary: $APP_BINARY"
    exit 1
fi

SIGN_MATCH="$(resolve_sign_identity "$SIGN_IDENTITY")"
SIGN_HASH=""
SIGN_NAME=""
if [ -n "$SIGN_MATCH" ]; then
    SIGN_HASH="$(echo "$SIGN_MATCH" | awk '{print $2}')"
    SIGN_NAME="$(echo "$SIGN_MATCH" | sed 's/.*"\(.*\)"/\1/')"
fi

if [ -n "$SIGN_HASH" ]; then
    echo "Signing with: ${SIGN_NAME:-$SIGN_HASH} ($SIGN_HASH)"
    sign_embedded_code "$SIGN_HASH"
    codesign --force --sign "$SIGN_HASH" \
        --entitlements "$LOCAL_ENTITLEMENTS" \
        "$APP_BUNDLE"
else
    echo "No Developer ID found — signing ad-hoc (permissions may not persist)"
    sign_embedded_code "-"
    codesign --force --sign - \
        --entitlements "$LOCAL_ENTITLEMENTS" \
        "$APP_BUNDLE"
fi

echo "Verifying signature..."
verify_signature

if [ -n "$SIGN_HASH" ] && codesign -dv "$APP_BUNDLE" 2>&1 | grep -q "Signature=adhoc"; then
    echo "Expected Developer ID signature but binary is ad-hoc."
    exit 1
fi

if [ "${TRANSCRIPTED_SKIP_LAUNCH_SMOKE:-0}" = "1" ]; then
    echo "⚠️  Skipping launch smoke (TRANSCRIPTED_SKIP_LAUNCH_SMOKE=1) — app launch is UNVERIFIED in this build"
else
    echo "Running launch smoke check..."
    verify_launch_smoke
fi

echo "Checking performance budget..."
PERFORMANCE_BUDGET_ARGS=(--app "$APP_BUNDLE")
if [ "$BUNDLE_PARAKEET_MODELS" = "0" ]; then
    PERFORMANCE_BUDGET_ARGS+=(--allow-missing-parakeet-model --max-app-mb 220 --max-resources-mb 80)
fi
scripts/ops/performance-budget.rb "${PERFORMANCE_BUDGET_ARGS[@]}"

echo "Build complete!"
if [ "$OPEN_APP_AFTER_BUILD" = "1" ]; then
    echo "Opening Transcripted..."
    open "$APP_BUNDLE"
else
    echo "Skipping app open (--no-open)."
fi
