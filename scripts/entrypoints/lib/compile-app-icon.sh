#!/bin/bash
# Compile AppIcon/Transcripted.icon (Icon Composer) into the bundle's Assets.car.
#
# macOS 26 reads CFBundleIconName from Assets.car and picks the light, dark,
# clear, or tinted rendition itself. Without it, macOS derives a dark icon from
# the flat Transcripted.icns, which came out all black. Resources/Transcripted.icns
# stays the CFBundleIconFile fallback, so only Assets.car is copied here; actool's
# own regenerated .icns is discarded.
#
# Usage: compile_app_icon <app-bundle-path>

compile_app_icon() {
    local app_bundle="$1"
    local icon_source="AppIcon/Transcripted.icon"
    if [ ! -d "$icon_source" ]; then
        echo "Error: missing $icon_source" >&2
        return 1
    fi

    local work_dir
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/transcripted-app-icon.XXXXXX")"
    mkdir -p "$work_dir/out"
    if ! xcrun actool \
        --compile "$work_dir/out" \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        --app-icon Transcripted \
        --output-partial-info-plist "$work_dir/partial.plist" \
        --errors --warnings \
        --output-format human-readable-text \
        "$icon_source" >"$work_dir/actool.log" 2>&1 \
        || [ ! -f "$work_dir/out/Assets.car" ]; then
        cat "$work_dir/actool.log" >&2
        echo "Error: actool could not compile $icon_source (needs Xcode 26 or newer)" >&2
        rm -rf "$work_dir"
        return 1
    fi

    cp "$work_dir/out/Assets.car" "$app_bundle/Contents/Resources/Assets.car"
    rm -rf "$work_dir"
    echo "App icon compiled (light + dark)"
}
