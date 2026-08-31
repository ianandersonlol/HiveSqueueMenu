#!/bin/bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <executable-path> <app-bundle-path> <bundle-id>" >&2
  exit 1
fi

EXECUTABLE_PATH="$1"
APP_BUNDLE_PATH="$2"
BUNDLE_ID="$3"
APP_NAME="$(basename "$APP_BUNDLE_PATH" .app)"
MACOS_DIR="$APP_BUNDLE_PATH/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE_PATH/Contents/Resources"
EXECUTABLE_DIR="$(cd "$(dirname "$EXECUTABLE_PATH")" && pwd)"

if [ ! -x "$EXECUTABLE_PATH" ]; then
  echo "error: executable not found or not executable: $EXECUTABLE_PATH" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"

shopt -s nullglob
for resource_bundle in "$EXECUTABLE_DIR"/*.bundle; do
  cp -R "$resource_bundle" "$RESOURCES_DIR/"
done

cat > "$APP_BUNDLE_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_BUNDLE_PATH" >/dev/null
echo "built $APP_BUNDLE_PATH"
