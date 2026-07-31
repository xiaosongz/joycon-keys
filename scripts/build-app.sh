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
    codesign --force --options runtime --sign - --identifier "$IDENTIFIER" "$APP"
else
    # A caller that requests a stable identity is depending on it for TCC and
    # login-item continuity. Fail closed: deploying an ad-hoc fallback would
    # replace a working app with one whose permissions are silently orphaned.
    if ! err=$(codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        --identifier "$IDENTIFIER" "$APP" 2>&1); then
        echo "warning: codesign with '$SIGN_IDENTITY' failed:" >&2
        echo "$err" >&2
        echo "error: refusing to fall back to ad-hoc signing; no app was deployed" >&2
        exit 1
    fi
fi

codesign --verify --deep --strict "$APP"
echo "built: $APP"
