#!/bin/zsh
# Build, sign with the stable identity, install to ~/bin, restart the agent.
# Signing with the same cert keeps the TCC Accessibility grant across rebuilds.
set -e
cd "$(dirname "$0")"
swiftc -O main.swift -o joycon-keys
codesign --force --sign joycon-keys-sign --identifier com.xiaosong.joycon-keys joycon-keys
/bin/cp -f joycon-keys ~/bin/joycon-keys
launchctl kickstart -k "gui/$(id -u)/com.xiaosong.joycon-keys"
sleep 2
tail -3 ~/Library/Logs/joycon-keys.log
