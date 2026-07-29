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
| Home                   | F5          | Dictation toggle               |
| Plus / Minus           | Shift+Tab   | Claude Code mode switch        |

A single Joy-Con exposes no stick-click or extendedGamepad profile on macOS —
elements arrive via `physicalInputProfile` (A/B/X/Y, Home, Menu, the stick as
an analog Direction Pad, SL/SR shoulders). SL/SR are currently unmapped.
Run with `JOYKEYS_DEBUG=1` to print every element event — useful for checking
stick axis orientation and free button names before remapping.

Edit the `pad.valueChangedHandler` block in `main.swift` to change bindings —
key codes are Carbon virtual key codes, listed at the top of the file.

## Build

```sh
swiftc -O main.swift -o joycon-keys
```

Only Command Line Tools required, no Xcode.

## Run

```sh
./joycon-keys
```

1. Pair the Joy-Con in System Settings > Bluetooth (hold the small sync button
   on the rail until the LEDs sweep).
2. Grant **Accessibility** permission when prompted
   (System Settings > Privacy & Security > Accessibility). The permission
   attaches to the *responsible process* — the terminal app you launch from
   (e.g. Ghostty). If you switch terminals, grant again.
3. Dictation: System Settings > Keyboard > Dictation > shortcut = **F5**.

Without Accessibility permission the tool runs but key events are silently
dropped — that is the number-one "nothing happens" cause.

## Notes

- `GCController.shouldMonitorBackgroundEvents = true` makes input arrive even
  when the terminal is not frontmost, so it works system-wide.
- A single Joy-Con works; both handlers (left/right stick, Plus/Minus) are
  wired so either half — or a combined pair — behaves the same.
- Stick handling is digital with hysteresis (engage past 0.6, release inside
  0.4) plus auto-repeat (400 ms delay, 120 ms interval), tuned for menu
  navigation rather than analog control.
