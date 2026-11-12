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
elif [ -f ".build/out/Products/Release/${APP_NAME}" ]; then
  # Newer SwiftPM (swift-build) puts multi-arch products here.
  BIN_PATH=".build/out/Products/Release/${APP_NAME}"
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

# App icon
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "${ICONSET}"
iconutil -c icns "${ICONSET}" -o "${RESOURCES_DIR}/AppIcon.icns"

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
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>MacNotepad Link</string>
            <key>CFBundleURLSchemes</key>
            <array><string>macnotepad</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Text &amp; Source Code</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.plain-text</string>
                <string>public.text</string>
                <string>public.source-code</string>
                <string>public.script</string>
                <string>public.shell-script</string>
                <string>public.python-script</string>
                <string>public.swift-source</string>
                <string>com.netscape.javascript-source</string>
                <string>public.json</string>
                <string>public.xml</string>
                <string>public.html</string>
                <string>public.css</string>
                <string>public.yaml</string>
                <string>public.comma-separated-values-text</string>
                <string>public.log</string>
                <string>net.daringfireball.markdown</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>net.daringfireball.markdown</string>
            <key>UTTypeDescription</key>
            <string>Markdown Document</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>md</string><string>markdown</string></array>
            </dict>
        </dict>
    </array>
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
