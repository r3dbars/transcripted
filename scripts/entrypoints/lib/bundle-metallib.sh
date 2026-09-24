#!/bin/bash
# Shared by the authoritative local and distribution app builds.
#
# MLX's shader library goes in a resource bundle under Contents/Resources, not
# next to the binary in Contents/MacOS. codesign signs a non-Mach-O file in
# Contents/MacOS by writing its signature into extended attributes, and Sparkle's
# BinaryDelta refuses to diff trees that carry them, so a colocated metallib
# means no delta updates. A resource is sealed by the app's own signature
# instead, with no extended attributes.
#
# MLX finds it through its SwiftPM-bundle fallback: it looks for
# mlx-swift_Cmlx.bundle under each loaded bundle's resourceURL (the app's is
# Contents/Resources) and loads default.metallib from that bundle's resources
# (mlx/backend/metal/device.cpp, load_default_library). The name comes from
# mlx-swift's SWIFTPM_BUNDLE define.

bundle_mlx_metallib() {
    local deps_libs="$1"
    local app_bundle="$2"
    local source_metallib="$deps_libs/mlx.metallib"
    local resource_bundle="$app_bundle/Contents/Resources/mlx-swift_Cmlx.bundle"

    [ -f "$source_metallib" ] || return 0

    mkdir -p "$resource_bundle/Contents/Resources"
    cp "$source_metallib" "$resource_bundle/Contents/Resources/default.metallib"
    cat > "$resource_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>mlx-swift.Cmlx.resources</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>mlx-swift_Cmlx</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
</dict>
</plist>
PLIST
}
