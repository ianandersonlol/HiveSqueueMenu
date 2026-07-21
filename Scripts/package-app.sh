#!/bin/bash
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="HiveSqueueMenu"
BUNDLE_ID="${BUNDLE_ID:-com.hivesqueuemenu.app}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
OUTPUT_PATH="${1:-.build/$APP_NAME.app}"

case "$OUTPUT_PATH" in
  /*.app|*.app) ;;
  *)
    echo "error: output path must end in .app" >&2
    exit 1
    ;;
esac

if [ "$OUTPUT_PATH" = "/.app" ] || [ "$OUTPUT_PATH" = "$HOME" ]; then
  echo "error: refusing unsafe output path" >&2
  exit 1
fi

swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
EXECUTABLE_PATH="$BIN_PATH/$APP_NAME"

if [ ! -x "$EXECUTABLE_PATH" ]; then
  echo "error: built executable not found at $EXECUTABLE_PATH" >&2
  exit 1
fi

OUTPUT_DIRECTORY="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIRECTORY"
APP_PATH="$(cd "$OUTPUT_DIRECTORY" && pwd)/$(basename "$OUTPUT_PATH")"
MACOS_PATH="$APP_PATH/Contents/MacOS"
RESOURCES_PATH="$APP_PATH/Contents/Resources"

rm -rf "$APP_PATH"
mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"
cp "$EXECUTABLE_PATH" "$MACOS_PATH/$APP_NAME"

for resource_bundle in "$BIN_PATH"/*.bundle; do
  if [ -d "$resource_bundle" ]; then
    cp -R "$resource_bundle" "$RESOURCES_PATH/"
  fi
done

PLIST_PATH="$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $MARKETING_VERSION" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$PLIST_PATH"

codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
echo "Packaged $APP_PATH"
