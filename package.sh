#!/bin/bash
# Package Draft.app into a distributable DMG

APP_NAME="Draft"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="Draft.dmg"
DMG_VOLUME="Draft"
STAGING_DIR="$BUILD_DIR/dmg-staging"

# Verify build exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ $APP_BUNDLE not found — run build.sh first"
    exit 1
fi

echo "📦 Packaging Draft.dmg..."

# Clean previous artifacts
rm -f "$BUILD_DIR/$DMG_NAME"
rm -rf "$STAGING_DIR"

# Create staging directory with app + Applications symlink
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Create compressed DMG
hdiutil create \
    -volname "$DMG_VOLUME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$BUILD_DIR/$DMG_NAME" 2>&1

if [ $? -ne 0 ]; then
    echo "❌ DMG creation failed!"
    rm -rf "$STAGING_DIR"
    exit 1
fi

# Clean up staging
rm -rf "$STAGING_DIR"

# Report size
DMG_SIZE=$(du -h "$BUILD_DIR/$DMG_NAME" | cut -f1)
APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo "✅ $BUILD_DIR/$DMG_NAME created ($DMG_SIZE compressed, from $APP_SIZE app bundle)"
