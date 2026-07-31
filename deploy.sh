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
PLIST_NEW="$PLIST.new"
PLIST_BACKUP="$PLIST.rollback"
LOG="$HOME/Library/Logs/joycon-keys.log"
APP_NEW="$APP_DEST.new"
APP_BACKUP="$APP_DEST.rollback"

mkdir -p "$HOME/Library/LaunchAgents"

# Stage next to the destination, then swap — a failed copy must not leave
# /Applications with no app at all.
rm -rf "$APP_NEW" "$APP_BACKUP"
rm -f "$PLIST_NEW" "$PLIST_BACKUP"
/bin/cp -Rf dist/JoyConKeys.app "$APP_NEW"
codesign --verify --deep --strict "$APP_NEW"

# Recreate the LaunchAgent from the trusted template every time. Preserving an
# old user-writable plist would also preserve injected EnvironmentVariables.
cp scripts/launchagent.plist "$PLIST_NEW"

# launchd does NOT expand ~ — write absolute paths.
/usr/libexec/PlistBuddy \
    -c "Set :ProgramArguments:0 \"$APP_DEST/Contents/MacOS/JoyConKeys\"" \
    -c "Set :StandardOutPath \"$LOG\"" \
    -c "Set :StandardErrorPath \"$LOG\"" \
    "$PLIST_NEW"
plutil -lint "$PLIST_NEW" >/dev/null

rollback() {
    local exit_code=$?
    trap - EXIT INT TERM
    if (( exit_code != 0 )); then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        if [[ -d "$APP_BACKUP" ]]; then
            rm -rf "$APP_DEST"
            mv "$APP_BACKUP" "$APP_DEST"
        elif (( APP_INSTALLED_NEW )); then
            rm -rf "$APP_DEST"
        fi
        if [[ -f "$PLIST_BACKUP" ]]; then
            rm -f "$PLIST"
            mv "$PLIST_BACKUP" "$PLIST"
            launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
        elif (( PLIST_INSTALLED_NEW )); then
            rm -f "$PLIST"
        fi
        echo "deploy failed; restored previous installation" >&2
    fi
    rm -rf "$APP_NEW"
    rm -rf "$APP_BACKUP"
    [[ -f "$PLIST_NEW" ]] && rm -f "$PLIST_NEW"
    [[ -f "$PLIST_BACKUP" ]] && rm -f "$PLIST_BACKUP"
    exit "$exit_code"
}
APP_INSTALLED_NEW=0
PLIST_INSTALLED_NEW=0
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Replace the running instance cleanly only after all staged inputs validate.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ -f "$PLIST" ]]; then mv "$PLIST" "$PLIST_BACKUP"; fi
mv "$PLIST_NEW" "$PLIST"
PLIST_INSTALLED_NEW=1
if [[ -d "$APP_DEST" ]]; then mv "$APP_DEST" "$APP_BACKUP"; fi
mv "$APP_NEW" "$APP_DEST"
APP_INSTALLED_NEW=1

launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 2
launchctl print "gui/$(id -u)/$LABEL" >/dev/null
[[ -f "$LOG" ]] && tail -5 "$LOG"

rm -rf "$APP_BACKUP"
rm -f "$PLIST_BACKUP"
trap - EXIT INT TERM
