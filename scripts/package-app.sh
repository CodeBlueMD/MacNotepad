#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MacNotepad"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# Locate compiled binary (Universal or single-arch)
if [ -f ".build/apple/Products/Release/${APP_NAME}" ]; then
  BIN_PATH=".build/apple/Products/Release/${APP_NAME}"
elif [ -f ".build/release/${APP_NAME}" ]; then
  BIN_PATH=".build/release/${APP_NAME}"
else
  echo "Building release binary..."
  swift build -c release
  BIN_PATH=".build/release/${APP_NAME}"
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.codebluemd.macnotepad</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc sign so it opens cleanly on Apple Silicon MacBook Air
codesign --force --deep --sign - "${APP_BUNDLE}" || true

if command -v hdiutil >/dev/null 2>&1; then
  hdiutil create -volname "${APP_NAME}" -srcfolder "${APP_BUNDLE}" -ov -format UDZO "${BUILD_DIR}/${APP_NAME}.dmg"
  echo "Created ${BUILD_DIR}/${APP_NAME}.dmg"
fi

echo "Packaged ${APP_BUNDLE} successfully."
