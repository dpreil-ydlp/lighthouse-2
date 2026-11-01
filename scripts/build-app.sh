#!/bin/sh
# Builds "Lighthouse 2.app" with SwiftPM and wraps it in a bundle using App/Lighthouse/Info.plist.
# Use when xcodebuild is unavailable. Output: ".build/app/Lighthouse 2.app"
set -eu
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product LighthouseApp
BIN="$(swift build -c "$CONFIG" --show-bin-path)/LighthouseApp"
APP=".build/app/Lighthouse 2.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Lighthouse"
sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/' -e 's/$(EXECUTABLE_NAME)/Lighthouse/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.lighthouse.v2/' -e 's/$(PRODUCT_NAME)/Lighthouse 2/' \
    -e 's/$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/' -e 's/$(MACOSX_DEPLOYMENT_TARGET)/14.0/' \
    App/Lighthouse/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
