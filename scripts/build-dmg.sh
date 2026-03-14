#!/bin/bash
set -euo pipefail

# ── Configuration ──
APP_NAME="Consolent"
SCHEME="Consolent"
PROJECT="Consolent.xcodeproj"
BUILD_DIR="$(pwd)/build"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
VOL_NAME="${APP_NAME}"

# ── Colors ──
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

step() { echo -e "\n${CYAN}── $1 ──${NC}"; }
ok()   { echo -e "${GREEN}OK${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; exit 1; }

# ── Clean ──
step "Clean previous build"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
ok "Build directory ready"

# ── Build Release ──
step "Building Release"
xcodebuild -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}/derived" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    build 2>&1 | tail -5

# Find .app
BUILT_APP=$(find "${BUILD_DIR}/derived/Build/Products/Release" -name "*.app" -maxdepth 1 | head -1)
if [ -z "${BUILT_APP}" ]; then
    fail "Could not find built .app"
fi

cp -R "${BUILT_APP}" "${APP_PATH}"
ok "Built ${APP_PATH}"

# ── Create DMG ──
step "Creating DMG"

# Check for create-dmg
if command -v create-dmg &> /dev/null; then
    # Fancy DMG with Applications shortcut
    create-dmg \
        --volname "${VOL_NAME}" \
        --window-size 600 400 \
        --icon-size 128 \
        --icon "${APP_NAME}.app" 150 200 \
        --app-drop-link 450 200 \
        --no-internet-enable \
        "${DMG_PATH}" \
        "${APP_PATH}" \
    || true  # create-dmg returns 2 when no signing identity, but DMG is still created

    if [ -f "${DMG_PATH}" ]; then
        ok "DMG created with Applications shortcut"
    else
        # Fallback to hdiutil
        echo "create-dmg failed, falling back to hdiutil..."
        hdiutil create -volname "${VOL_NAME}" \
            -srcfolder "${APP_PATH}" \
            -ov -format UDZO \
            "${DMG_PATH}"
        ok "DMG created (basic)"
    fi
else
    # Simple DMG with hdiutil
    echo "create-dmg not found, using hdiutil (install with: brew install create-dmg)"
    hdiutil create -volname "${VOL_NAME}" \
        -srcfolder "${APP_PATH}" \
        -ov -format UDZO \
        "${DMG_PATH}"
    ok "DMG created (basic)"
fi

# ── Summary ──
DMG_SIZE=$(du -h "${DMG_PATH}" | cut -f1)
step "Done"
echo -e "  DMG: ${GREEN}${DMG_PATH}${NC}"
echo -e "  Size: ${DMG_SIZE}"
echo ""
echo "  To install: open ${DMG_PATH}"
