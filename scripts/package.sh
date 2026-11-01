#!/bin/sh
# Builds a Release "Lighthouse 2.app" with SwiftPM, strips and signs it, and writes
# dist/Lighthouse-2-<version>.zip plus its .sha256, and dist/Lighthouse.app.dSYM (symbols, not shipped).
# The zip holds only "Lighthouse 2.app" (bundle id com.lighthouse.v2, executable Lighthouse). Works without `xcodebuild` (the icon comes from the asset
# catalog's PNGs through iconutil).
#
# SIGN_IDENTITY: codesign identity, default "-" (ad-hoc). See README "Signing".
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PLIST="App/Lighthouse/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
IDENTITY="${SIGN_IDENTITY:--}"
DIST="$ROOT/dist"
STAGE="$DIST/stage"
APP="$STAGE/Lighthouse 2.app"
ZIP="$DIST/Lighthouse-2-$VERSION.zip"

echo "Lighthouse 2 $VERSION ($BUILD) from $(git describe --always --dirty 2>/dev/null || echo unknown)"
swift build -c release --product LighthouseApp
BIN="$(swift build -c release --show-bin-path)/LighthouseApp"

rm -rf "$STAGE" "$ZIP" "$ZIP.sha256"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lighthouse"
# Ship the binary without its symbol table (much smaller). The symbols stay in a dSYM next
# to the zip, outside the app, so crash reports can still be symbolicated.
rm -rf "$DIST/Lighthouse.app.dSYM"
dsymutil "$APP/Contents/MacOS/Lighthouse" -o "$DIST/Lighthouse.app.dSYM"
strip "$APP/Contents/MacOS/Lighthouse"
sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/' -e 's/$(EXECUTABLE_NAME)/Lighthouse/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.lighthouse.v2/' -e 's/$(PRODUCT_NAME)/Lighthouse 2/' \
    "$PLIST" > "$APP/Contents/Info.plist"
if grep -q '\$(' "$APP/Contents/Info.plist"; then
    echo "error: unresolved build setting in Info.plist" >&2
    exit 1
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
cp App/Lighthouse/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# The installed app must not depend on the build folder (dylibs, rpaths or resource bundles).
if otool -L "$APP/Contents/MacOS/Lighthouse" | tail -n +2 | grep -E '\.build/|DerivedData|@rpath'; then
    echo "error: binary links a build-folder library" >&2
    exit 1
fi
if otool -l "$APP/Contents/MacOS/Lighthouse" | grep -A2 LC_RPATH | grep -E '\.build/|DerivedData'; then
    echo "error: binary has a build-folder rpath" >&2
    exit 1
fi

codesign --force --sign "$IDENTITY" --identifier com.lighthouse.v2 "$APP"
codesign --verify --strict --verbose=2 "$APP"

(cd "$STAGE" && ditto -c -k --norsrc --noextattr --noqtn --keepParent "Lighthouse 2.app" "$ZIP")
if zipinfo -1 "$ZIP" | grep -v '^Lighthouse 2\.app/'; then
    echo "error: zip holds something other than Lighthouse 2.app" >&2
    exit 1
fi
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
cat "$ZIP.sha256"
echo "$ZIP"
