#!/bin/zsh
# Maintainer deploy: build the .app, install to /Applications (launchd
# refuses executables on external volumes), point the LaunchAgent at it,
# restart. Signing identity + bundle identifier stay constant so the
# Accessibility grant survives.
set -euo pipefail
cd "$(dirname "$0")"

# Maintainer default; anyone else deploys ad-hoc unless they export one.
export SIGN_IDENTITY="${SIGN_IDENTITY:-joycon-keys-sign}"
scripts/build-app.sh

APP_DEST="/Applications/JoyConKeys.app"
LABEL="com.xiaosong.joycon-keys"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/joycon-keys.log"

# First run: materialize the LaunchAgent from the repo template.
mkdir -p "$HOME/Library/LaunchAgents"
[[ -f "$PLIST" ]] || cp scripts/launchagent.plist "$PLIST"

# Replace the running instance cleanly before swapping the bundle.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# Stage next to the destination, then swap — a failed copy must not leave
# /Applications with no app at all.
rm -rf "$APP_DEST.new"
/bin/cp -Rf dist/JoyConKeys.app "$APP_DEST.new"
rm -rf "$APP_DEST"
mv "$APP_DEST.new" "$APP_DEST"

# launchd does NOT expand ~ — write absolute paths.
/usr/libexec/PlistBuddy \
    -c "Set :ProgramArguments:0 \"$APP_DEST/Contents/MacOS/JoyConKeys\"" \
    -c "Set :StandardOutPath \"$LOG\"" \
    -c "Set :StandardErrorPath \"$LOG\"" \
    "$PLIST"

launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 2
tail -5 "$LOG"
