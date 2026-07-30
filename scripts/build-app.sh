#!/bin/zsh
# Build JoyConKeys.app from the SPM package — no Xcode project needed.
#
# Usage:
#   scripts/build-app.sh                 build into ./dist/JoyConKeys.app
#   SIGN_IDENTITY=- scripts/build-app.sh   ad-hoc sign (default for others)
#
# The maintainer signs with a persistent self-signed cert and a stable
# bundle identifier so the macOS Accessibility (TCC) grant survives
# rebuilds. Ad-hoc signing works too — you just re-grant permission after
# each rebuild.
set -e
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:-joycon-keys-sign}"
IDENTIFIER="com.xiaosong.joycon-keys"
APP="dist/JoyConKeys.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp "$(swift build -c release --show-bin-path)/JoyConKeys" "$APP/Contents/MacOS/JoyConKeys"

if ! codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$IDENTIFIER" "$APP" 2>/dev/null; then
    echo "note: identity '$SIGN_IDENTITY' unavailable — falling back to ad-hoc signing"
    codesign --force --deep --sign - --identifier "$IDENTIFIER" "$APP"
fi

echo "built: $APP"
