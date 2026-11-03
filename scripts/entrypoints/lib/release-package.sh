#!/bin/bash
# Signing and disk-image helpers shared by build-beta.sh and
# scripts/release/sign-release.sh. Source this file; it only defines constants
# and functions.
#
# The caller sets APP_NAME, APP_BUNDLE, BUILD_DIR, DMG_NAME and, for
# create_release_dmg, TRANSCRIPTED_HEADLESS_PACKAGE_SMOKE (0 or 1).
#
# build-beta.sh signs inline (local and un-notarized test builds). The Release
# Candidate workflow builds an unsigned app in a job with no secrets and calls
# these same functions from sign-release.sh in the `release` environment job,
# so a shipped build is signed by exactly the code a local build uses.

DMG_WINDOW_WIDTH=960
DMG_WINDOW_HEIGHT=640
DMG_ICON_SIZE=144
DMG_TEXT_SIZE=16
DMG_APP_ICON_X=220
DMG_APP_ICON_Y=340
DMG_APPLICATIONS_ICON_X=740
DMG_APPLICATIONS_ICON_Y=340
DMG_BACKGROUND_PATH="scripts/release/assets/dmg-background.png"
BETA_ENTITLEMENTS="config/entitlements/beta.plist"
KEYBOARD_ENTITLEMENTS="config/entitlements/keyboard.plist"

validate_signed_app() {
    echo "Validating app signature..."
    codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
    codesign -dvvv --entitlements - "$APP_BUNDLE"
}


create_finder_layout_dmg() {
    local output_path="$1"
    local staging_dir="$BUILD_DIR/dmg-staging"
    local rw_dmg="$BUILD_DIR/${DMG_NAME%.dmg}-layout.dmg"
    local staging_size_mb
    local image_size_mb
    local attach_output
    local device
    local mount_dir
    local background_alias_line=""

    echo "ℹ️  create-dmg not found — using built-in Finder layout fallback"

    rm -rf "$staging_dir"
    rm -f "$rw_dmg"
    mkdir -p "$staging_dir"
    cp -R "$APP_BUNDLE" "$staging_dir/"
    ln -s /Applications "$staging_dir/Applications"

    if [ -f "$DMG_BACKGROUND_PATH" ]; then
        mkdir -p "$staging_dir/.background"
        cp "$DMG_BACKGROUND_PATH" "$staging_dir/.background/dmg-background.png"
        chflags hidden "$staging_dir/.background" || true
    fi

    staging_size_mb="$(du -sm "$staging_dir" | awk '{print $1}')"
    image_size_mb=$((staging_size_mb + 160))

    hdiutil create \
        -srcfolder "$staging_dir" \
        -volname "$DMG_VOLUME_NAME" \
        -fs HFS+ \
        -format UDRW \
        -size "${image_size_mb}m" \
        "$rw_dmg" >/dev/null

    if [ -d "/Volumes/$DMG_VOLUME_NAME" ]; then
        hdiutil detach "/Volumes/$DMG_VOLUME_NAME" -force >/dev/null 2>&1 || true
    fi

    attach_output="$(
        hdiutil attach \
        -readwrite \
        -noverify \
        -noautoopen \
        "$rw_dmg"
    )"
    device="$(printf '%s\n' "$attach_output" | awk '/Apple_HFS/ {print $1; exit}')"
    mount_dir="$(printf '%s\n' "$attach_output" | awk '/Apple_HFS/ {$1=""; $2=""; sub(/^  +/, ""); print; exit}')"

    if [ -f "$mount_dir/.background/dmg-background.png" ]; then
        background_alias_line="set background picture of viewOptions to (POSIX file \"$mount_dir/.background/dmg-background.png\" as alias)"
    fi

    bless --folder "$mount_dir" --openfolder "$mount_dir" >/dev/null 2>&1 || true

    if ! osascript <<EOF >/dev/null
tell application "Finder"
    tell disk "$DMG_VOLUME_NAME"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, $((200 + DMG_WINDOW_WIDTH)), $((120 + DMG_WINDOW_HEIGHT))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $DMG_ICON_SIZE
        set text size of viewOptions to $DMG_TEXT_SIZE
        $background_alias_line
        set position of item "$APP_NAME.app" of container window to {$DMG_APP_ICON_X, $DMG_APP_ICON_Y}
        set position of item "Applications" of container window to {$DMG_APPLICATIONS_ICON_X, $DMG_APPLICATIONS_ICON_Y}
        update without registering applications
        delay 1
        close
        open
        delay 1
    end tell
end tell
EOF
    then
        hdiutil detach "$device" -force >/dev/null 2>&1 || true
        return 1
    fi

    sync
    hdiutil detach "$device" >/dev/null

    hdiutil convert \
        "$rw_dmg" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$output_path" >/dev/null

    rm -f "$rw_dmg"
    rm -rf "$staging_dir"
}

resolve_sign_identity() {
    local requested_identity="$1"
    local found_line

    if [ -n "$requested_identity" ]; then
        found_line="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$requested_identity" | head -1 || true)"
        if [ -z "$found_line" ]; then
            echo "❌ Requested signing identity not found: $requested_identity"
            echo "Available identities:"
            security find-identity -v -p codesigning || true
            exit 1
        fi
        printf '%s\n' "$found_line"
        return 0
    fi

    security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 || true
}

sign_embedded_payloads() {
    local sign_hash="$1"
    local framework_path
    local nested_code_path
    local helper_path
    local input_method_path

    while IFS= read -r -d '' nested_code_path; do
        if [ "$sign_hash" = "-" ]; then
            codesign --force --sign "$sign_hash" "$nested_code_path"
        else
            codesign --force \
                --sign "$sign_hash" \
                --options runtime \
                --timestamp \
                --preserve-metadata=identifier,entitlements,requirements \
                "$nested_code_path"
        fi
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

    for helper_path in "$APP_BUNDLE"/Contents/Helpers/*; do
        [ -f "$helper_path" ] || continue
        if [ "$sign_hash" = "-" ]; then
            codesign --force --sign "$sign_hash" "$helper_path"
        else
            codesign --force \
                --sign "$sign_hash" \
                --options runtime \
                --timestamp \
                "$helper_path"
        fi
    done

    # The Writing keyboard is a nested input-method bundle with no nested code
    # of its own. Signing is inside-out, so it's signed here, before the outer
    # app, with its own entitlements. With no keyboard bundle this loop does
    # nothing.
    for input_method_path in "$APP_BUNDLE/Contents/Library/Input Methods"/*.app; do
        [ -d "$input_method_path" ] || continue
        if [ "$sign_hash" = "-" ]; then
            codesign --force --sign "$sign_hash" \
                --entitlements "$KEYBOARD_ENTITLEMENTS" \
                "$input_method_path"
        else
            codesign --force \
                --sign "$sign_hash" \
                --options runtime \
                --timestamp \
                --entitlements "$KEYBOARD_ENTITLEMENTS" \
                "$input_method_path"
        fi
    done
}


# Sign the nested code, then the app. "-" (or an empty identity) signs ad-hoc
# for local smoke testing.
sign_app_bundle() {
    local identity="${1:-}"
    local SIGNING_IDENTITY="$identity"
    if [ -n "$SIGNING_IDENTITY" ]; then
        echo "Signing with: ${SIGNING_DISPLAY_NAME:-$SIGNING_IDENTITY}"
        sign_embedded_payloads "$SIGNING_IDENTITY"
        if ! codesign --force \
            --sign "$SIGNING_IDENTITY" \
            --options runtime \
            --timestamp \
            --entitlements "$BETA_ENTITLEMENTS" \
            "$APP_BUNDLE" 2>&1; then
            echo "❌ Signing failed! Make sure you have a valid Developer ID Application certificate."
            echo "   Open Xcode → Settings → Accounts → Manage Certificates"
            exit 1
        fi
    else
        echo "⚠️  No Developer ID found — signing ad-hoc for local smoke testing"
        sign_embedded_payloads "-"
        codesign --force \
            --sign - \
            --entitlements "$BETA_ENTITLEMENTS" \
            "$APP_BUNDLE" 2>&1
    fi

}

# Build $BUILD_DIR/$DMG_NAME from $APP_BUNDLE.
create_release_dmg() {
    # Create DMG
    echo "Creating DMG..."
    rm -f "$BUILD_DIR/$DMG_NAME"

    if [ "$TRANSCRIPTED_HEADLESS_PACKAGE_SMOKE" = "1" ]; then
        # Exercise the real signed payload and disk-image assembly without driving
        # Finder. Keep the staging folder as local evidence. This intentionally does
        # not prove the distribution install-window layout or notarization.
        HEADLESS_DMG_STAGE="$(mktemp -d "$BUILD_DIR/dmg-headless.XXXXXX")"
        ditto "$APP_BUNDLE" "$HEADLESS_DMG_STAGE/$APP_NAME.app"
        ln -s /Applications "$HEADLESS_DMG_STAGE/Applications"
        hdiutil create -volname "$DMG_VOLUME_NAME" -srcfolder "$HEADLESS_DMG_STAGE" \
            -format UDZO "$BUILD_DIR/$DMG_NAME"
    elif command -v create-dmg >/dev/null 2>&1; then
        DMG_BG_FLAGS=()
        if [ -f "$DMG_BACKGROUND_PATH" ]; then
            DMG_BG_FLAGS+=(--background "$DMG_BACKGROUND_PATH")
        fi

        create-dmg \
            --volname "$DMG_VOLUME_NAME" \
            --window-pos 200 120 \
            --window-size "$DMG_WINDOW_WIDTH" "$DMG_WINDOW_HEIGHT" \
            --icon-size "$DMG_ICON_SIZE" \
            --icon "$APP_NAME.app" "$DMG_APP_ICON_X" "$DMG_APP_ICON_Y" \
            --hide-extension "$APP_NAME.app" \
            --app-drop-link "$DMG_APPLICATIONS_ICON_X" "$DMG_APPLICATIONS_ICON_Y" \
            --no-internet-enable \
            "${DMG_BG_FLAGS[@]}" \
            "$BUILD_DIR/$DMG_NAME" \
            "$APP_BUNDLE" \
            2>&1 || true
    else
        create_finder_layout_dmg "$BUILD_DIR/$DMG_NAME"
    fi

    if [ ! -f "$BUILD_DIR/$DMG_NAME" ]; then
        echo "❌ DMG creation failed!"
        exit 1
    fi

}

# Sign the DMG when there is a real identity.
sign_release_dmg() {
    local SIGNING_IDENTITY="${1:-}"
    # Sign the DMG
    if [ -n "$SIGNING_IDENTITY" ]; then
        echo "Signing DMG..."
        codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$BUILD_DIR/$DMG_NAME"
    else
        echo "⚠️  Skipping DMG signature (no Developer ID available)"
    fi

}
