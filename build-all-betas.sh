#!/bin/bash
# Build DMGs for all beta users
# Usage: ./build-all-betas.sh
#
# Each user gets a unique DMG with their token baked in.
# Runs sequentially (sed modifies BetaConfig.swift in-place).

set -e

USERS=(
    "draft-beta-nate:Nate"
    "draft-beta-jack:Jack"
    "draft-beta-abdulbaqi:Abdulbaqi"
    "draft-beta-don:Don"
    "draft-beta-sarah:Sarah"
    "draft-beta-travis:Travis"
    "draft-beta-inaje:Inaje"
    "draft-beta-willa:Willa"
    "draft-beta-nathan:Nathan"
    "draft-beta-reserve:Reserve"
)

echo "🔨 Building ${#USERS[@]} beta DMGs..."
echo ""

BUILT=0
FAILED=0

for entry in "${USERS[@]}"; do
    IFS=':' read -r token name <<< "$entry"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Building for $name ($token)..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if ./build-beta.sh "$token" "$name"; then
        BUILT=$((BUILT + 1))
    else
        echo "❌ Failed to build for $name"
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done! Built: $BUILT, Failed: $FAILED"
echo ""
echo "DMGs in build/:"
ls -lh build/Draft-*.dmg 2>/dev/null || echo "No DMGs found"
