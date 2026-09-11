#!/usr/bin/env bash
set -e

APP_NAME="MacDroid Commander"
APP_BUNDLE="build/${APP_NAME}.app"
DMG_NAME="MacDroid_Commander_v1.0.dmg"
DMG_OUTPUT="build/${DMG_NAME}"
TMP_DIR="build/dmg_staging"

echo "=========================================="
echo "Packaging ${APP_NAME} DMG..."
echo "=========================================="

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "❌ Error: ${APP_BUNDLE} not found! Please build the app first."
    exit 1
fi

rm -rf "${TMP_DIR}" "${DMG_OUTPUT}"
mkdir -p "${TMP_DIR}"

echo "1. Copying ${APP_BUNDLE} to staging..."
cp -R "${APP_BUNDLE}" "${TMP_DIR}/"

echo "2. Creating /Applications symlink..."
ln -s /Applications "${TMP_DIR}/Applications"

echo "3. Creating compressed DMG image with hdiutil..."
hdiutil create -volname "${APP_NAME}" \
               -srcfolder "${TMP_DIR}" \
               -ov \
               -format UDZO \
               "${DMG_OUTPUT}"

echo "4. Cleaning up temporary staging..."
rm -rf "${TMP_DIR}"

if [ -f "${DMG_OUTPUT}" ]; then
    echo "=========================================="
    echo "✓ DMG created successfully: ${DMG_OUTPUT}"
    ls -lh "${DMG_OUTPUT}"
    echo "=========================================="
else
    echo "❌ DMG creation failed!"
    exit 1
fi
