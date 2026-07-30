# joycon-keys

Map Nintendo Switch Joy-Con buttons to keyboard events on macOS. ~150 lines of
Swift, no dependencies — uses the system GameController framework (native
Joy-Con support since macOS 13 Ventura) and CGEvent for key synthesis.

Built for driving voice dictation and Claude Code option menus from the couch.

## Mapping

| Joy-Con                | Key         | Purpose                        |
|------------------------|-------------|--------------------------------|
| Stick / d-pad up-down  | ↑ / ↓       | Move through options (repeats) |
| A                      | Return      | Confirm                        |
| B                      | Escape      | Cancel / interrupt             |
| X                      | `1`         | Pick option 1 directly         |
| Y                      | `2`         | Pick option 2 directly         |
| SL (single) / ZL (paired) | double-Control | macOS dictation toggle    |
| SR (single) / ZR (paired) | Ctrl+Opt+Cmd+D | Codex dictation toggle    |
| Home                   | double-Control | macOS dictation (backup)*   |
| Plus / Minus           | Shift+Tab   | Claude Code mode switch        |

Shoulder-button reality on macOS (confirmed by
[SDL issue #6095](https://github.com/libsdl-org/SDL/issues/6095)): a single
Joy-Con reports only SL/SR (as Left/Right Shoulder) — R and ZR are never
reported at all. A combined pair reports R/ZR (shoulder/trigger) and loses
SL/SR. The two modes are symmetric and mutually exclusive; this tool binds
shoulders *and* triggers so dictation works in either mode.
Run with `JOYKEYS_DEBUG=1` to print every element event — useful for checking
stick axis orientation before remapping.

Edit the `pad.valueChangedHandler` block in `main.swift` to change bindings —
key codes are Carbon virtual key codes, listed at the top of the file.

## Build

```sh
swiftc -O main.swift -o joycon-keys
```

Only Command Line Tools required, no Xcode.

## Install (launchd, auto-start)

```sh
swiftc -O main.swift -o joycon-keys
cp joycon-keys ~/bin/joycon-keys       # MUST be a local-disk path, see below
cp com.xiaosong.joycon-keys.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.xiaosong.joycon-keys.plist
```

Gotchas learned the hard way:

- **launchd refuses to exec from an external volume** (exit 78 EX_CONFIG).
  This repo lives under `~/git` → symlink to `/Volumes/970EVO` — that path
  cannot be the `ProgramArguments` target. Hence the copy to `~/bin`.
- **TCC identity**: a launchd-spawned process is its own responsible process.
  Terminal grants do NOT carry over — `joycon-keys` itself must be enabled in
  System Settings > Privacy & Security > Accessibility. Because the binary is
  ad-hoc signed, **every rebuild changes its code hash and the grant must be
  re-toggled** (and the binary re-copied to ~/bin).
- Logs: `~/Library/Logs/joycon-keys.log`. Restart after permission changes:
  `launchctl kickstart -k gui/$(id -u)/com.xiaosong.joycon-keys`.

Without Accessibility permission the tool runs and wires the Joy-Con but key
events are silently dropped — that is the number-one "nothing happens" cause.

Dictation is triggered by synthesizing the shortcut this machine actually
registers — "press Control twice" (symbolic hotkey 164) — not a key combo.

## Notes

- `GCController.shouldMonitorBackgroundEvents = true` makes input arrive even
  when the terminal is not frontmost, so it works system-wide.
- A single Joy-Con works; both handlers (left/right stick, Plus/Minus) are
  wired so either half — or a combined pair — behaves the same.
- Stick handling is digital with hysteresis (engage past 0.6, release inside
  0.4) plus auto-repeat (400 ms delay, 120 ms interval), tuned for menu
  navigation rather than analog control.

**Home button caveat:** if Steam is running (even in the background), Steam
grabs the controller Home/guide button globally and brings itself to the
front — that is Steam's own "guide button focuses Steam" behavior, not this
tool. Fix: quit Steam, or disable it in Steam → Settings → Controller.
