#!/bin/bash
# Shared by the authoritative local and distribution app builds. Builds the
# Writing keyboard, an IMKit input method ported from Tilde's InlineGhostIME
# (docs/writing-plan.md, "Build"), into the app bundle at
#   Contents/Library/Input Methods/Transcripted Keyboard.app
# Call it before the builds' nested-code signing loop: this function never
# signs, and it is safe to re-run (the previous bundle is replaced whole).
#
# Sources/TranscriptedWriting/Core and Sources/TranscriptedKeyboard compile
# into ONE module here, which is why the keyboard's Core import is guarded
# with `#if canImport(TranscriptedWritingCore)`. Swift 5 mode on purpose:
# Tilde keeps the keyboard there too, and the app target's swiftc-app-args.sh
# excludes Sources/TranscriptedKeyboard/ so the keyboard never lands in the
# app binary. The bundle's Info.plist is the one checked in next to the
# sources with both version keys stamped from the root Info.plist, since
# bump-release-version.py only touches the root.

bundle_transcripted_input_method() {
    local repo_root="$1"
    local app_bundle="$2"
    local executable_name="TranscriptedKeyboard"
    local input_methods_dir="$app_bundle/Contents/Library/Input Methods"
    local keyboard_bundle="$input_methods_dir/Transcripted Keyboard.app"
    local staged_bundle="$input_methods_dir/.Transcripted Keyboard.app.building"
    local source_plist="$repo_root/Sources/TranscriptedKeyboard/Info.plist"
    local root_plist="$repo_root/Info.plist"
    local staged_binary="$staged_bundle/Contents/MacOS/$executable_name"
    local staged_plist="$staged_bundle/Contents/Info.plist"

    if [ ! -d "$app_bundle/Contents" ]; then
        echo "bundle-input-method: not an app bundle: $app_bundle" >&2
        return 1
    fi
    if [ ! -f "$source_plist" ] || [ ! -f "$root_plist" ]; then
        echo "bundle-input-method: missing $source_plist or $root_plist" >&2
        return 1
    fi

    local sources=()
    local file
    while IFS= read -r -d '' file; do
        sources+=("$file")
    done < <(find "$repo_root/Sources/TranscriptedWriting/Core" "$repo_root/Sources/TranscriptedKeyboard" \
        -name '*.swift' -print0 | sort -z)
    if [ "${#sources[@]}" -eq 0 ]; then
        echo "bundle-input-method: no keyboard sources found under $repo_root/Sources" >&2
        return 1
    fi

    echo "Building Transcripted Keyboard (${#sources[@]} sources)..."
    rm -rf "$staged_bundle" || return 1
    mkdir -p "$staged_bundle/Contents/MacOS" || return 1
    # No -parse-as-library: main.swift carries the IMKServer top-level code.
    if ! swiftc \
        -swift-version 5 \
        -O \
        -target arm64-apple-macos26.0 \
        -module-name "$executable_name" \
        -framework InputMethodKit \
        -o "$staged_binary" \
        "${sources[@]}"; then
        echo "bundle-input-method: Transcripted Keyboard failed to compile" >&2
        rm -rf "$staged_bundle"
        return 1
    fi
    if [ ! -x "$staged_binary" ]; then
        echo "bundle-input-method: compile finished without a runnable $executable_name" >&2
        rm -rf "$staged_bundle"
        return 1
    fi
    # IMKit instantiates the controller by the class name in Info.plist. A
    # binary without that ObjC class installs fine and then does nothing.
    # The class is internal to the module, so the symbol is local: plain nm,
    # not nm -g.
    if ! nm "$staged_binary" | grep -q ' _OBJC_CLASS_\$_GhostInputController$'; then
        echo "bundle-input-method: $executable_name lacks the GhostInputController class named in Info.plist" >&2
        rm -rf "$staged_bundle"
        return 1
    fi

    local short_version bundle_version
    short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root_plist")" || return 1
    bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$root_plist")" || return 1
    if [ -z "$short_version" ] || [ -z "$bundle_version" ]; then
        echo "bundle-input-method: root Info.plist has no version to stamp" >&2
        rm -rf "$staged_bundle"
        return 1
    fi
    cp "$source_plist" "$staged_plist" || return 1
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $short_version" "$staged_plist" || return 1
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $bundle_version" "$staged_plist" || return 1
    if ! plutil -lint -s "$staged_plist"; then
        echo "bundle-input-method: stamped Info.plist is not a valid plist" >&2
        rm -rf "$staged_bundle"
        return 1
    fi

    rm -rf "$keyboard_bundle" || return 1
    mv "$staged_bundle" "$keyboard_bundle" || return 1
    echo "Bundled Transcripted Keyboard $short_version ($bundle_version) at $keyboard_bundle"
}
