# Raw HID Engine — Design

**Date:** 2026-07-30
**Branch:** `feature/raw-hid-engine`
**Target release:** v0.2.0

## Problem

macOS merges a connected Joy-Con pair into one "Joy-Con (L/R)" controller at the
GameController-framework layer. The merged MFi profile has no slots for the four
small rail buttons — SL/SR on both halves go silent (SDL issue #6095), and the
user must hold Capture+Home to split the pair every time they swap a Joy-Con off
the charger. The merge is framework-level only: Bluetooth keeps two separate HID
devices (vendor `0x057E`, products `0x2006` L / `0x2007` R), so reading those
devices directly recovers every button in every mode.

## Goal

A Settings toggle — **"Always use raw HID"** — that switches input capture from
the GameController framework to a direct IOHIDManager engine. With it on, SL/SR
work regardless of combine state and the combine/split gesture becomes
irrelevant. Mappings, key synthesis, and the UI are unchanged.

Non-goals: Pro Controller support, rumble, battery display, IMU/motion. The raw
report carries battery level and IMU data; ignore them (noted for the future,
not built).

## Architecture

`ControllerEngine` becomes a thin **facade** that keeps its current public
surface (`@Published connected: [Connected]`, `@Published pressed:
Set<PadButton>`, `@MainActor ObservableObject`) so no view changes. Behind it,
exactly one of two backends is active:

- **`GCBackend`** — the existing GameController implementation, moved
  wholesale out of `ControllerEngine` with its behavior unchanged (wire/unwire,
  mirror policy, stick frame remaps).
- **`RawHIDBackend`** — new IOHIDManager implementation.

A backend receives a reference to the facade (or a small delegate protocol) and
reports three things: device connected (side, name), device disconnected,
button/stick events already translated to `PadButton` + pressed state and
normalized stick values. Shared stick-to-digital logic (hysteresis + repeater)
stays in the facade so both backends feed the identical code path.

Switching: `@AppStorage("useRawHID")` (key in `AppDefaults`, default **false**)
drives the facade. On change it tears down the active backend (release
repeater, clear pressed, close devices / remove GC handlers) and starts the
other — live, no app restart. Only one backend is ever active, which eliminates
double-event risk by construction.

## RawHIDBackend

**Discovery.** One `IOHIDManager`, matching dictionary VendorID `0x057E` +
ProductID `0x2006`/`0x2007`, schedule on a dedicated background dispatch queue.
Device-matched and device-removed callbacks drive connect state (marshaled to
MainActor). Each physical Joy-Con is its own device in every merge state — the
charging-swap scenario reduces to ordinary device add/remove.

**Initialization per device.**
1. Open device. `kIOReturnNotPermitted` → permission path (below).
2. Send subcommand `0x03 0x30` (set standard full input-report mode). Output
   report format: `0x01`, global packet counter (0–15), 8 neutral rumble bytes
   (`00 01 40 40 00 01 40 40`), subcommand byte, arguments.
3. Read factory stick calibration via SPI-flash read subcommand `0x10`
   (left stick data at `0x603D`, right at `0x6046`, 9 bytes each of packed
   12-bit min/center/max). If user calibration present (`0x8010`/`0x801B`
   magic `0xB2A1`), prefer it. On any read failure: fallback calibration
   center 2048, range ±1400, and log.

**Input report `0x30`** (arrives ~60 Hz once full mode set):
- Byte 3: right-half buttons — Y `0x01`, X `0x02`, B `0x04`, A `0x08`,
  SR(R) `0x10`, SL(R) `0x20`, R `0x40`, ZR `0x80`.
- Byte 4: shared — Minus `0x01`, Plus `0x02`, RStick `0x04`, LStick `0x08`,
  Home `0x10`, Capture `0x20`.
- Byte 5: left-half buttons — Down `0x01`, Up `0x02`, Right `0x04`, Left
  `0x08`, SR(L) `0x10`, SL(L) `0x20`, L `0x40`, ZL `0x80`.
- Bytes 6–8 left stick, 9–11 right stick: two packed 12-bit axes.

Also accept simple report `0x3F` (button-status mode, the default before the
subcommand lands) by triggering mode-set retry rather than parsing it.

**PadButton translation** preserves current app semantics exactly. Raw mode
sees all of SL, SR, L/R, ZL/ZR simultaneously (GameController never could), so
the rule for the extra buttons must be explicit:
- Right Joy-Con: A/B/X/Y → `.buttonA/.buttonB/.buttonX/.buttonY`;
  SL(R) → `.shoulderLeft`, SR(R) → `.shoulderRight`;
  ZR → `.triggerRight`; **R (large rail button) also fires `.triggerRight`** —
  R has no identity of its own anywhere in the app today (combined-mode
  GameController folded it into the same trigger row), and a new PadButton
  case would force a MappingStore migration for zero user value. Revisit only
  if distinct L/R bindings become a real need.
- Left Joy-Con mirror of the same rule: SL(L) → `.shoulderLeft`,
  SR(L) → `.shoulderRight`, ZL → `.triggerLeft`, L → `.triggerLeft`.
- Left Joy-Con: arrow buttons keep the position-mirror policy — Up →
  `.buttonX`, Right → `.buttonA`, Down → `.buttonB`, Left → `.buttonY`.
  Minus → `.options`, Plus → `.menu`, Capture → `.capture`, Home → `.home`.
- Stick clicks (LStick/RStick press): ignored, same as today (GameController
  exposed none for Joy-Con). Not a regression.

**Sticks.** Raw 12-bit → calibrated to [-1, 1] using per-axis min/center/max →
rotated to the upright frame (raw values are in the sideways/hardware frame;
apply the same per-side remap the GC path uses) → fed into the shared
hysteresis/repeat logic. Behavior must be indistinguishable from GC mode.

Implementation note (2026-07-30): raw HID delivers the upright frame directly — the per-side GC remap does not apply to the raw path; hardware matrix row 8 verifies.

**Threading.** HID callbacks arrive on the background queue; translate raw
bytes there (cheap, allocation-free), dispatch only state changes to
MainActor. Debounce: report `0x30` streams at ~60 Hz continuously — compare
against previous button bitmap and emit only edges.

## Permission and failure path

Raw device open requires **Input Monitoring** (TCC `kTCCServiceListenEvent`).
On `kIOReturnNotPermitted` (or `IOHIDCheckAccess` reporting denied):

- Facade auto-falls back to `GCBackend` so the app keeps working.
- Settings caption under the toggle turns red: "Raw HID needs Input Monitoring
  permission" + button opening
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`.
- The toggle itself stays ON — after the user grants (and relaunches if macOS
  requires it), the raw backend activates without re-toggling.
- Request the permission proactively with `IOHIDRequestAccess` when the toggle
  is first switched ON.

**Spike risk (verify before building the rest):** confirm macOS 26 still
delivers raw input reports to IOHIDManager while the GameController framework
concurrently owns the same devices, in both split and combined states. hidapi
tools historically work, but this is the load-bearing assumption — test with a
20-line spike that opens the R Joy-Con and dumps reports. If exclusive access
blocks us, the feature falls back to a documented limitation and the toggle is
not built (decision point returns to user).

## Settings UI

In `SettingsPane`, new "Input engine" section between Startup and the footer:

- `Toggle("Always use raw HID", …)` bound to `AppDefaults.useRawHIDKey`.
- Caption (normal state): "Reads Joy-Con directly over Bluetooth HID. All four
  SL/SR buttons work even when macOS combines the pair — no Capture+Home
  gesture needed. Requires Input Monitoring permission."
- Caption (denied state): red, as above, with the settings-pane link button.

## Testing

Manual matrix (with `JOYKEYS_DEBUG=1` raw-report dump):

| Scenario | Expect |
|---|---|
| Toggle OFF (default) | Behavior identical to v0.1.1 |
| Raw + single R | All R buttons incl. SL/SR + stick w/ repeat |
| Raw + single L | Arrow mirror + SL/SR + stick |
| Raw + both, macOS split | Two devices, both fully live |
| Raw + both, macOS combined | Same as split — SL/SR alive (the whole point) |
| Live toggle flip both ways | No stuck keys, no double events, repeater released |
| Permission denied | GC fallback + red caption + link works |
| Charging swap (one half off/on charger) | Clean add/remove, no gesture needed |

Stick feel A/B: raw vs GC mode arrow-repeat cadence should be
indistinguishable.

## Ship

Feature branch → Opus PR review → merge to main → GitHub release **v0.2.0**
(zipped app). README: new section documenting the toggle, the Input Monitoring
permission, and why raw mode exists (link SDL #6095).
