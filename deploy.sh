#!/bin/zsh
# Maintainer deploy: build the .app, install to ~/Applications (launchd
# refuses executables on external volumes), point the LaunchAgent at it,
# restart. Signing identity + bundle identifier stay constant so the
# Accessibility grant survives.
set -e
cd "$(dirname "$0")"

scripts/build-app.sh

APP_DEST="/Applications/JoyConKeys.app"
LABEL="com.xiaosong.joycon-keys"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Replace the running instance cleanly before swapping the bundle.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf "$APP_DEST"
/bin/cp -Rf dist/JoyConKeys.app "$APP_DEST"

/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $APP_DEST/Contents/MacOS/JoyConKeys" "$PLIST" \
    || /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $APP_DEST/Contents/MacOS/JoyConKeys" "$PLIST"

launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 2
tail -5 ~/Library/Logs/joycon-keys.log
