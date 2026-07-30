#!/bin/zsh
# Build JoyConKeys.app from the SPM package — no Xcode project needed.
#
# Usage:
#   scripts/build-app.sh                        ad-hoc signed (default)
#   SIGN_IDENTITY=my-cert scripts/build-app.sh  persistent identity
#
# Ad-hoc signing works out of the box, but macOS re-keys the Accessibility
# (TCC) grant on every rebuild — you must delete and re-add the entry each
# time. To keep the grant across rebuilds, sign with any persistent
# certificate (see README "Re-building without losing the Accessibility
# grant") and keep the bundle identifier stable.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
IDENTIFIER="com.xiaosong.joycon-keys"
APP="dist/JoyConKeys.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$(swift build -c release --show-bin-path)/JoyConKeys" "$APP/Contents/MacOS/JoyConKeys"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --identifier "$IDENTIFIER" "$APP"
else
    # Surface the real codesign error (expired cert, locked keychain,
    # ambiguous match…) before degrading — a silent ad-hoc fallback is
    # exactly what kills a persistent TCC grant.
    if ! err=$(codesign --force --sign "$SIGN_IDENTITY" --identifier "$IDENTIFIER" "$APP" 2>&1); then
        echo "warning: codesign with '$SIGN_IDENTITY' failed:" >&2
        echo "$err" >&2
        echo "warning: falling back to AD-HOC signing — the Accessibility grant will NOT survive this rebuild" >&2
        codesign --force --sign - --identifier "$IDENTIFIER" "$APP"
    fi
fi

echo "built: $APP"
