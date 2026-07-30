# Raw HID Engine Implementation Plan

**Spike verdict (2026-07-30): PASS.** Raw reports coexist with GameController:
0x21 subcommand ack + continuous 0x30 full reports while the GC-based app ran.
Two corrections learned: (1) the mode-set subcommand is ignored if sent
immediately after IOHIDDeviceOpen — retry on a ~2-3 s timer until the first
0x30 arrives (NOT retry-on-0x3F-receipt as Task 5's code sketch does: 0x3F
reports are event-driven, a silent controller never triggers that retry);
(2) payload convention A (no leading 0x01 in the buffer; ID only in the
reportID parameter) is the one that works.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settings toggle "Always use raw HID" that swaps the input engine from GameController to a direct IOHIDManager reader so all four SL/SR rail buttons work regardless of macOS Joy-Con merge state.

**Architecture:** `ControllerEngine` becomes a facade that owns the published UI state and the shared stick/repeat logic; exactly one of two backends (`GCBackend` = today's GameController code, `RawHIDBackend` = new IOHIDManager code) feeds it through a small delegate protocol. Spec: `docs/superpowers/specs/2026-07-30-raw-hid-engine-design.md`.

**Tech Stack:** Swift 6 toolchain in Swift-5 language mode, SPM executable target, IOKit.hid, GameController, SwiftUI. No third-party deps.

## Global Constraints

- Swift language mode stays `.v5` (Package.swift `swiftLanguageMode(.v5)`) — C-callback isolation bridging relies on it.
- `PadButton` raw values are persistence keys — never rename, never add cases (spec: L/R rail buttons fold into `.triggerLeft`/`.triggerRight`).
- Default for the toggle is **false** (`AppDefaults.useRawHIDKey = "useRawHID"`).
- Joy-Con only: VendorID `0x057E`, ProductID `0x2006` (L) / `0x2007` (R). No Pro Controller.
- Version bump to **0.2.0** (CFBundleVersion 3) ships in this branch; user's scheme is 0.x — never 1.x.
- Branch `feature/raw-hid-engine`; commits allowed in this repo (vault no-commit rule does NOT apply here).
- Every build check is `cd ~/git/joycon-keys && swift build 2>&1 | tail -5`; tests are `swift test 2>&1 | tail -20`.
- Manual hardware steps require the physical Joy-Cons; the executor must pause and ask the user to perform button presses when noted.

---

### Task 1: Spike — verify raw reports coexist with GameController (GATE)

The whole feature rests on one assumption: IOHIDManager still receives input
reports from the Joy-Con HID devices while Apple's GameController framework
also has them open — in both split and combined states. Prove it before
building anything. **If this fails, stop: report to user, feature becomes a
documented limitation.**

**Files:**
- Create: `scripts/spike-rawhid.swift` (kept in repo — it doubles as a protocol debugging tool)

**Interfaces:**
- Produces: go/no-go decision recorded at the top of this plan file; raw axis
  orientation notes for Task 6.

- [ ] **Step 1: Write the spike script**

```swift
#!/usr/bin/env swift
// Spike: do Joy-Con HID devices deliver raw input reports while the
// GameController framework coexists? Run from a terminal that has (or can
// be granted) Input Monitoring. Dumps report ID + first 12 bytes.
import Foundation
import IOKit.hid

let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
print("Input Monitoring access: \(access == kIOHIDAccessTypeGranted ? "granted" : "NOT granted (\(access))")")
if access != kIOHIDAccessTypeGranted { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatchingMultiple(manager, [
    [kIOHIDVendorIDKey: 0x057E, kIOHIDProductIDKey: 0x2006],
    [kIOHIDVendorIDKey: 0x057E, kIOHIDProductIDKey: 0x2007],
] as CFArray)

var buffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]

let matchCallback: IOHIDDeviceCallback = { _, result, _, device in
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    print("matched: \(name) open=\(String(format: "0x%X", IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))))")
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    buffers[device] = buf
    IOHIDDeviceRegisterInputReportCallback(device, buf, 64, { _, _, _, type, reportID, report, length in
        let bytes = (0..<min(length, 12)).map { String(format: "%02X", report[$0]) }.joined(separator: " ")
        print("report id=0x\(String(format: "%02X", reportID)) len=\(length): \(bytes)")
    }, nil)
    // Subcommand 0x03 0x30: switch to standard full report mode.
    var packet: [UInt8] = [0x00, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x03, 0x30]
    let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x01, &packet, packet.count)
    print("mode-set setReport: \(String(format: "0x%X", r))")
}
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
print("open result: \(String(format: "0x%X", IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))))")
print("Press Joy-Con buttons now. Ctrl-C to quit.")
CFRunLoopRun()
```

- [ ] **Step 2: Run it — split state**

Ask the user to make sure at least the right Joy-Con is connected (app log
shows current state: `tail -5 ~/Library/Logs/joycon-keys.log`). Run:

```bash
cd ~/git/joycon-keys && swift scripts/spike-rawhid.swift
```

If access prints NOT granted: grant the terminal (Ghostty) Input Monitoring in
System Settings › Privacy & Security › Input Monitoring, restart terminal,
re-run. Ask the user to press SL and SR on the right Joy-Con.
Expected: `report id=0x30` lines streaming; byte 3 changes with presses
(SR sets 0x10, SL sets 0x20).

- [ ] **Step 3: Run it — combined state**

Ask the user to connect both Joy-Cons and combine them (hold Capture+Home 3 s
if not already merged; the JoyConKeys app log shows `wired: Joy-Con (L/R)`
when merged). Re-run the spike. Ask for SL/SR presses on BOTH halves.
Expected: reports still stream from BOTH devices with SL/SR bits changing.
**This is the gate.** Also note stick byte behavior for up/right deflection —
record which raw axis increases (needed to confirm the upright-frame
assumption in Task 6).

- [ ] **Step 4: Record verdict + commit**

Add one line under this plan's title: `**Spike verdict (date):** PASS/FAIL — notes`.

```bash
git add scripts/spike-rawhid.swift docs/superpowers/plans/2026-07-30-raw-hid-engine.md
git commit -m "spike: raw HID coexistence check"
```

---

### Task 2: Report parser (pure logic, TDD)

**Files:**
- Modify: `Package.swift` (add test target)
- Create: `Sources/JoyConKeys/Engine/RawHID/JoyConReport.swift`
- Test: `Tests/JoyConKeysTests/JoyConReportTests.swift`

**Interfaces:**
- Consumes: `PadButton`, `JoyConSide` (existing, `Sources/JoyConKeys/Model/PadButton.swift`).
- Produces:
  - `struct RawStick: Equatable { var x: Int; var y: Int }`
  - `struct JoyConReport: Equatable { var pressed: Set<PadButton>; var stick: RawStick? }`
  - `static func JoyConReport.parseStandard(_ bytes: [UInt8], side: JoyConSide) -> JoyConReport?`
    (nil unless `bytes[0] == 0x30` and length ≥ 12; `side` is `.left`/`.right`
    from the device's product ID — never `.other` in raw mode)

- [ ] **Step 1: Add test target to Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JoyConKeys",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "JoyConKeys",
            path: "Sources/JoyConKeys",
            // Swift 5 mode: GameController + AX C callbacks don't model
            // isolation, and strict concurrency rejects the assumeIsolated
            // bridging this app relies on. Revisit when GC gets Sendable
            // annotations.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "JoyConKeysTests",
            dependencies: ["JoyConKeys"],
            path: "Tests/JoyConKeysTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: Write failing tests**

`Tests/JoyConKeysTests/JoyConReportTests.swift`:

```swift
import XCTest
@testable import JoyConKeys

final class JoyConReportTests: XCTestCase {
    /// 0x30 report skeleton: [id, timer, battery/conn, btn3, btn4, btn5,
    /// L-stick ×3, R-stick ×3]. Zero-filled beyond what a test sets.
    private func report(btn3: UInt8 = 0, btn4: UInt8 = 0, btn5: UInt8 = 0,
                        stick: [UInt8] = [0, 0, 0], right: Bool = true) -> [UInt8] {
        var b: [UInt8] = [0x30, 0x00, 0x8E, btn3, btn4, btn5, 0, 0, 0, 0, 0, 0]
        if right { b[9] = stick[0]; b[10] = stick[1]; b[11] = stick[2] }
        else { b[6] = stick[0]; b[7] = stick[1]; b[8] = stick[2] }
        return b
    }

    func testRejectsNonStandardReport() {
        XCTAssertNil(JoyConReport.parseStandard([0x3F, 0x00, 0x00], side: .right))
        XCTAssertNil(JoyConReport.parseStandard(Array(report().prefix(11)), side: .right))
    }

    func testRightFaceButtons() {
        // Y=0x01 X=0x02 B=0x04 A=0x08
        let r = JoyConReport.parseStandard(report(btn3: 0x0F), side: .right)!
        XCTAssertEqual(r.pressed, [.buttonY, .buttonX, .buttonB, .buttonA])
    }

    func testRightRailAndTriggers() {
        // SR=0x10 SL=0x20 R=0x40 ZR=0x80 — R and ZR both fold into .triggerRight
        let r = JoyConReport.parseStandard(report(btn3: 0xF0), side: .right)!
        XCTAssertEqual(r.pressed, [.shoulderRight, .shoulderLeft, .triggerRight])
    }

    func testLeftArrowsMirrorToFaceActions() {
        // Down=0x01 Up=0x02 Right=0x04 Left=0x08 → B, X, A, Y by position
        let r = JoyConReport.parseStandard(report(btn5: 0x0F), side: .left)!
        XCTAssertEqual(r.pressed, [.buttonB, .buttonX, .buttonA, .buttonY])
    }

    func testLeftRailAndTriggers() {
        // SR(L)=0x10 SL(L)=0x20 L=0x40 ZL=0x80 — L and ZL fold into .triggerLeft
        let r = JoyConReport.parseStandard(report(btn5: 0xF0), side: .left)!
        XCTAssertEqual(r.pressed, [.shoulderRight, .shoulderLeft, .triggerLeft])
    }

    func testSharedButtons() {
        // Minus=0x01 Plus=0x02 RStick=0x04 LStick=0x08 Home=0x10 Capture=0x20
        // Stick clicks are ignored by design (GameController never exposed them).
        let r = JoyConReport.parseStandard(report(btn4: 0x3F), side: .right)!
        XCTAssertEqual(r.pressed, [.options, .menu, .home, .capture])
    }

    func testStickUnpacking12Bit() {
        // x = b0 | (b1 & 0x0F) << 8 ; y = (b1 >> 4) | b2 << 4
        // bytes [0x34, 0xD2, 0x7A] → x = 0x234, y = 0x7AD
        let r = JoyConReport.parseStandard(
            report(stick: [0x34, 0xD2, 0x7A], right: true), side: .right)!
        XCTAssertEqual(r.stick, RawStick(x: 0x234, y: 0x7AD))
        let l = JoyConReport.parseStandard(
            report(stick: [0x34, 0xD2, 0x7A], right: false), side: .left)!
        XCTAssertEqual(l.stick, RawStick(x: 0x234, y: 0x7AD))
    }
}
```

- [ ] **Step 3: Run tests, verify failure**

Run: `cd ~/git/joycon-keys && swift test 2>&1 | tail -20`
Expected: compile error — `JoyConReport` not defined.

- [ ] **Step 4: Implement parser**

`Sources/JoyConKeys/Engine/RawHID/JoyConReport.swift`:

```swift
import Foundation

/// One decoded standard-full-mode (0x30) input report from a single physical
/// Joy-Con. Pure byte parsing — no IOKit, fully unit-testable.
struct RawStick: Equatable {
    var x: Int
    var y: Int
}

struct JoyConReport: Equatable {
    var pressed: Set<PadButton>
    var stick: RawStick?

    /// Layout (https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering):
    /// byte 3 right-half buttons, byte 4 shared, byte 5 left-half buttons,
    /// bytes 6-8 left stick, 9-11 right stick (two packed 12-bit axes).
    /// `side` comes from the HID product ID (0x2006 left / 0x2007 right);
    /// a physical Joy-Con only ever sets its own half's bytes.
    static func parseStandard(_ bytes: [UInt8], side: JoyConSide) -> JoyConReport? {
        guard bytes.count >= 12, bytes[0] == 0x30 else { return nil }
        var pressed: Set<PadButton> = []

        let b3 = bytes[3]  // right half
        if b3 & 0x01 != 0 { pressed.insert(.buttonY) }
        if b3 & 0x02 != 0 { pressed.insert(.buttonX) }
        if b3 & 0x04 != 0 { pressed.insert(.buttonB) }
        if b3 & 0x08 != 0 { pressed.insert(.buttonA) }
        if b3 & 0x10 != 0 { pressed.insert(.shoulderRight) }  // SR(R)
        if b3 & 0x20 != 0 { pressed.insert(.shoulderLeft) }   // SL(R)
        // Large rail R and trigger ZR fold into the same action row — R has
        // no PadButton identity of its own (spec §RawHIDBackend).
        if b3 & 0xC0 != 0 { pressed.insert(.triggerRight) }

        let b4 = bytes[4]  // shared
        if b4 & 0x01 != 0 { pressed.insert(.options) }  // −
        if b4 & 0x02 != 0 { pressed.insert(.menu) }     // +
        // 0x04 / 0x08 = stick clicks: ignored, same as the GC engine.
        if b4 & 0x10 != 0 { pressed.insert(.home) }
        if b4 & 0x20 != 0 { pressed.insert(.capture) }

        let b5 = bytes[5]  // left half — arrows mirror face actions by position
        if b5 & 0x01 != 0 { pressed.insert(.buttonB) }  // ▼
        if b5 & 0x02 != 0 { pressed.insert(.buttonX) }  // ▲
        if b5 & 0x04 != 0 { pressed.insert(.buttonA) }  // ▶
        if b5 & 0x08 != 0 { pressed.insert(.buttonY) }  // ◀
        if b5 & 0x10 != 0 { pressed.insert(.shoulderRight) }  // SR(L)
        if b5 & 0x20 != 0 { pressed.insert(.shoulderLeft) }   // SL(L)
        if b5 & 0xC0 != 0 { pressed.insert(.triggerLeft) }    // L / ZL

        let s = side == .left ? Array(bytes[6...8]) : Array(bytes[9...11])
        let stick = RawStick(
            x: Int(s[0]) | (Int(s[1] & 0x0F) << 8),
            y: (Int(s[1]) >> 4) | (Int(s[2]) << 4))

        return JoyConReport(pressed: pressed, stick: stick)
    }
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `swift test 2>&1 | tail -20` — expected: all pass.
Note `testStickUnpacking12Bit` uses a zero-filled other-side stick, which
decodes to RawStick(0,0), not nil — if the assertion style above fights that,
assert only on the parsed side's stick value.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/JoyConKeys/Engine/RawHID/JoyConReport.swift Tests/
git commit -m "feat: pure parser for Joy-Con standard HID reports"
```

---

### Task 3: Stick calibration (pure logic, TDD)

**Files:**
- Create: `Sources/JoyConKeys/Engine/RawHID/StickCalibration.swift`
- Test: `Tests/JoyConKeysTests/StickCalibrationTests.swift`

**Interfaces:**
- Consumes: `RawStick` (Task 2), `JoyConSide`.
- Produces:
  - `struct StickCalibration: Equatable` with
    `static let fallback: StickCalibration` (center 2048/2048, all ranges 1400),
    `static func decode(spi bytes: [UInt8], side: JoyConSide) -> StickCalibration?`,
    `func normalize(_ raw: RawStick) -> (x: Float, y: Float)` (clamped to [-1, 1]).

- [ ] **Step 1: Write failing tests**

`Tests/JoyConKeysTests/StickCalibrationTests.swift`:

```swift
import XCTest
@testable import JoyConKeys

final class StickCalibrationTests: XCTestCase {
    /// Pack three 12-bit pairs into 9 SPI bytes (inverse of decode).
    private func pack(_ pairs: [(Int, Int)]) -> [UInt8] {
        pairs.flatMap { (a, b) -> [UInt8] in
            [UInt8(a & 0xFF), UInt8((a >> 8) | ((b & 0x0F) << 4)), UInt8(b >> 4)]
        }
    }

    func testDecodeLeftLayout() {
        // Left SPI order: (xAboveCenter,yAbove), (centerX,centerY), (xBelow,yBelow)
        let cal = StickCalibration.decode(
            spi: pack([(1200, 1100), (2000, 2100), (900, 950)]), side: .left)!
        XCTAssertEqual(cal, StickCalibration(
            centerX: 2000, centerY: 2100,
            rangeXPlus: 1200, rangeYPlus: 1100, rangeXMinus: 900, rangeYMinus: 950))
    }

    func testDecodeRightLayout() {
        // Right SPI order: (centerX,centerY), (xBelow,yBelow), (xAbove,yAbove)
        let cal = StickCalibration.decode(
            spi: pack([(2000, 2100), (900, 950), (1200, 1100)]), side: .right)!
        XCTAssertEqual(cal, StickCalibration(
            centerX: 2000, centerY: 2100,
            rangeXPlus: 1200, rangeYPlus: 1100, rangeXMinus: 900, rangeYMinus: 950))
    }

    func testDecodeRejectsShortBuffer() {
        XCTAssertNil(StickCalibration.decode(spi: [0, 1, 2], side: .left))
    }

    func testNormalizeCenterAndExtremes() {
        let cal = StickCalibration(
            centerX: 2000, centerY: 2000,
            rangeXPlus: 1000, rangeYPlus: 1000, rangeXMinus: 1000, rangeYMinus: 1000)
        XCTAssertEqual(cal.normalize(RawStick(x: 2000, y: 2000)).x, 0, accuracy: 0.001)
        XCTAssertEqual(cal.normalize(RawStick(x: 3000, y: 2000)).x, 1, accuracy: 0.001)
        XCTAssertEqual(cal.normalize(RawStick(x: 1000, y: 2000)).x, -1, accuracy: 0.001)
        XCTAssertEqual(cal.normalize(RawStick(x: 2000, y: 2500)).y, 0.5, accuracy: 0.001)
        // Beyond calibrated range clamps.
        XCTAssertEqual(cal.normalize(RawStick(x: 4095, y: 0)).x, 1, accuracy: 0.001)
        XCTAssertEqual(cal.normalize(RawStick(x: 4095, y: 0)).y, -1, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run tests, verify compile failure**

Run: `swift test 2>&1 | tail -10` — expected: `StickCalibration` not defined.

- [ ] **Step 3: Implement**

`Sources/JoyConKeys/Engine/RawHID/StickCalibration.swift`:

```swift
import Foundation

/// Per-axis stick calibration from the Joy-Con's SPI flash. Factory data
/// lives at 0x603D (left) / 0x6046 (right), 9 bytes of three packed 12-bit
/// pairs; user calibration (0x8012 / 0x801D, magic 0xB2A1 two bytes before)
/// uses the same encoding and wins when present.
struct StickCalibration: Equatable {
    var centerX: Int
    var centerY: Int
    var rangeXPlus: Int
    var rangeYPlus: Int
    var rangeXMinus: Int
    var rangeYMinus: Int

    /// Used when SPI reads fail — generous ranges, nominal center.
    static let fallback = StickCalibration(
        centerX: 2048, centerY: 2048,
        rangeXPlus: 1400, rangeYPlus: 1400, rangeXMinus: 1400, rangeYMinus: 1400)

    static func decode(spi bytes: [UInt8], side: JoyConSide) -> StickCalibration? {
        guard bytes.count >= 9 else { return nil }
        func pair(_ i: Int) -> (Int, Int) {
            (Int(bytes[i]) | (Int(bytes[i + 1] & 0x0F) << 8),
             (Int(bytes[i + 1]) >> 4) | (Int(bytes[i + 2]) << 4))
        }
        let p0 = pair(0), p1 = pair(3), p2 = pair(6)
        // Same fields, different SPI ordering per side.
        let (above, center, below) = side == .left ? (p0, p1, p2) : (p2, p0, p1)
        return StickCalibration(
            centerX: center.0, centerY: center.1,
            rangeXPlus: above.0, rangeYPlus: above.1,
            rangeXMinus: below.0, rangeYMinus: below.1)
    }

    /// Raw 12-bit → [-1, 1], clamped. Upright (vertical-grip) frame:
    /// +x = right, +y = up — matches how the engine's handleStick wants it.
    func normalize(_ raw: RawStick) -> (x: Float, y: Float) {
        func norm(_ v: Int, _ center: Int, _ plus: Int, _ minus: Int) -> Float {
            let d = v - center
            let r = d >= 0 ? Float(d) / Float(max(plus, 1))
                           : Float(d) / Float(max(minus, 1))
            return min(1, max(-1, r))
        }
        return (norm(raw.x, centerX, rangeXPlus, rangeXMinus),
                norm(raw.y, centerY, rangeYPlus, rangeYMinus))
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `swift test 2>&1 | tail -10` — expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/JoyConKeys/Engine/RawHID/StickCalibration.swift Tests/JoyConKeysTests/StickCalibrationTests.swift
git commit -m "feat: SPI stick calibration decode + normalization"
```

---

### Task 4: Facade/backend refactor (no behavior change)

Split today's `ControllerEngine` into a facade plus `GCBackend`. Pure
mechanical move — after this task the app must behave byte-for-byte like
v0.1.1 with the GameController path.

**Files:**
- Modify: `Sources/JoyConKeys/Engine/ControllerEngine.swift` (becomes facade + shared stick logic + `Repeater`)
- Create: `Sources/JoyConKeys/Engine/InputBackend.swift`
- Create: `Sources/JoyConKeys/Engine/GCBackend.swift`

**Interfaces:**
- Consumes: existing `MappingStore.action(for:)`, `KeySynth.perform(_:)`, `PadButton`, `JoyConSide`.
- Produces (used by Tasks 5–7):

```swift
@MainActor
protocol BackendDelegate: AnyObject {
    func backendConnected(id: ObjectIdentifier, side: JoyConSide, name: String)
    func backendDisconnected(id: ObjectIdentifier, name: String)
    func backendButton(_ button: PadButton, pressed: Bool)
    /// up/right already in the upright vertical-grip frame, [-1, 1].
    func backendStick(_ stick: ObjectIdentifier, up: Float, right: Float)
}

@MainActor
protocol InputBackend: AnyObject {
    func start(delegate: BackendDelegate)
    func stop()
}
```

- Facade keeps public surface used by views: `connected: [Connected]`,
  `pressed: Set<PadButton>`, plus new `rawHIDDenied: Bool` (published, false
  until Task 7 sets it) and `func applyBackendPreference()`.

- [ ] **Step 1: Create `InputBackend.swift`** with the two protocols above, verbatim.

- [ ] **Step 2: Create `GCBackend.swift`**

Move `wire`, `unwire`, `bind`, `bindStick`, `side(of:)`, the notification
observers, and the `debug` flag out of `ControllerEngine` unchanged, with
these mechanical substitutions:
- class declaration: `@MainActor final class GCBackend: InputBackend`
- `connected.append/removeAll` → `delegate?.backendConnected/Disconnected(...)`
- button handler body → `delegate?.backendButton(id, pressed: isPressed)`
  (delete the `pressed.insert` / `KeySynth.perform` lines — the facade owns those)
- `bindStick`'s handler tail → `delegate?.backendStick(stick, up: up, right: right)`
  (the per-side sideways-frame remap STAYS here — it is a GameController quirk)
- `start(delegate:)` = current `init` body (observer registration, discovery,
  wire existing controllers); `stop()` = remove observers, and for each wired
  controller nil out its handlers (`pressedChangedHandler` on every bound
  button, `valueChangedHandler` on every bound dpad) so a stopped backend can
  never fire the delegate again. This requires new internal bookkeeping the
  old code didn't have: `private var wiredControllers: [GCController] = []`
  appended in `wire`, pruned in `unwire`, drained in `stop()` (walk
  `physicalInputProfile.buttons.values` / `.dpads.values` and nil handlers).
- Keep `weak var delegate: BackendDelegate?`.

- [ ] **Step 3: Rewrite `ControllerEngine` as facade**

```swift
import Combine
import Foundation

/// Facade: owns UI-published state and the shared stick/repeat pipeline;
/// exactly ONE backend (GameController or raw HID) feeds it at a time, so
/// backends can never double-fire an action.
@MainActor
final class ControllerEngine: ObservableObject, BackendDelegate {
    struct Connected: Identifiable, Equatable {
        let id: ObjectIdentifier
        let side: JoyConSide
        let name: String
    }

    @Published private(set) var connected: [Connected] = []
    @Published private(set) var pressed: Set<PadButton> = []
    /// True when the user wants raw HID but Input Monitoring is denied
    /// (Settings shows the remediation caption). Set in Task 7.
    @Published private(set) var rawHIDDenied = false

    private let store: MappingStore
    private let repeater = Repeater()
    private var activeStick: ObjectIdentifier?
    private var backend: InputBackend?

    init(store: MappingStore) {
        self.store = store
        applyBackendPreference()
    }

    /// Reads the useRawHID default and swaps backends if needed. Task 4
    /// wires only the GC path; Task 7 adds the raw branch + permission check.
    func applyBackendPreference() {
        let current = backend
        current?.stop()
        clearLiveState()
        let next: InputBackend = GCBackend()
        backend = next
        next.start(delegate: self)
        _ = current  // replaced
    }

    private func clearLiveState() {
        repeater.release()
        pressed.removeAll()
        activeStick = nil
        connected.removeAll()
    }

    // MARK: BackendDelegate

    func backendConnected(id: ObjectIdentifier, side: JoyConSide, name: String) {
        connected.removeAll { $0.id == id }
        connected.append(Connected(id: id, side: side, name: name))
        NSLog("[joycon-keys] wired: %@ (%@)", name, side.rawValue)
    }

    func backendDisconnected(id: ObjectIdentifier, name: String) {
        connected.removeAll { $0.id == id }
        // Only wipe live input state when nothing is left — another
        // still-connected controller may be mid-press or mid-repeat.
        if connected.isEmpty {
            repeater.release()
            pressed.removeAll()
            activeStick = nil
        }
        NSLog("[joycon-keys] disconnected: %@", name)
    }

    func backendButton(_ button: PadButton, pressed isPressed: Bool) {
        if isPressed {
            pressed.insert(button)
            KeySynth.perform(store.action(for: button))
        } else {
            pressed.remove(button)
        }
    }

    func backendStick(_ stick: ObjectIdentifier, up: Float, right: Float) {
        handleStick(stick, up: up, right: right)
    }

    // handleStick(_:up:right:) and Repeater: keep EXACTLY as they are today.
}
```

`handleStick` and `Repeater` move over without edits.

- [ ] **Step 4: Build + unit tests**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: clean build, tests pass.

- [ ] **Step 5: Manual smoke (ask user if needed)**

```bash
./deploy.sh
tail -3 ~/Library/Logs/joycon-keys.log
```

Expected: `wired: Joy-Con (R) (right)` (or current hardware state), and a
button press still types its mapped key. Behavior identical to v0.1.1.

- [ ] **Step 6: Commit**

```bash
git add Sources/JoyConKeys/Engine/
git commit -m "refactor: split ControllerEngine into facade + GCBackend"
```

---

### Task 5: RawHIDBackend — devices, mode set, buttons

**Files:**
- Create: `Sources/JoyConKeys/Engine/RawHID/RawHIDBackend.swift`

**Interfaces:**
- Consumes: `InputBackend`/`BackendDelegate` (Task 4), `JoyConReport` (Task 2),
  `StickCalibration` (Task 3 — wired for real in Task 6).
- Produces: `final class RawHIDBackend: InputBackend` plus
  `static func accessGranted() -> Bool` and `static func requestAccess()`
  (Task 7 uses both).

- [ ] **Step 1: Implement the backend**

```swift
import Foundation
import IOKit.hid

/// Reads Joy-Con directly over Bluetooth HID, bypassing the GameController
/// framework's pair-merge — all four SL/SR rail buttons work in every mode.
/// HID callbacks land on a background queue; only translated state changes
/// hop to the MainActor delegate.
final class RawHIDBackend: InputBackend {
    private final class Device {
        let device: IOHIDDevice
        let side: JoyConSide
        let name: String
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 362)
        var previous: Set<PadButton> = []
        var calibration = StickCalibration.fallback
        var calibrated = false
        var packetCounter: UInt8 = 0
        var modeSetAttempts = 0
        init(_ d: IOHIDDevice, side: JoyConSide, name: String) {
            device = d; self.side = side; self.name = name
        }
        deinit { buffer.deallocate() }
    }

    private weak var delegate: BackendDelegate?
    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice: Device] = [:]
    private let queue = DispatchQueue(label: "joyconkeys.rawhid", qos: .userInteractive)
    private let debug = ProcessInfo.processInfo.environment["JOYKEYS_DEBUG"] != nil

    static func accessGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func requestAccess() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    @MainActor func start(delegate: BackendDelegate) {
        self.delegate = delegate
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        IOHIDManagerSetDeviceMatchingMultiple(m, [
            [kIOHIDVendorIDKey: 0x057E, kIOHIDProductIDKey: 0x2006],
            [kIOHIDVendorIDKey: 0x057E, kIOHIDProductIDKey: 0x2007],
        ] as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            Unmanaged<RawHIDBackend>.fromOpaque(ctx!).takeUnretainedValue().attach(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            Unmanaged<RawHIDBackend>.fromOpaque(ctx!).takeUnretainedValue().detach(dev)
        }, ctx)
        IOHIDManagerSetDispatchQueue(m, queue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerActivate(m)
    }

    @MainActor func stop() {
        guard let m = manager else { return }
        // Cancel delivers no further callbacks once its handler runs; tear
        // down device state on the HID queue to avoid racing a live report.
        IOHIDManagerSetCancelHandler(m) { }
        IOHIDManagerCancel(m)
        queue.async { [self] in
            for (dev, _) in devices { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
            devices.removeAll()
        }
        manager = nil
        delegate = nil
    }

    // MARK: device lifecycle (HID queue)

    private func attach(_ dev: IOHIDDevice) {
        let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let side: JoyConSide = pid == 0x2006 ? .left : .right
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String
            ?? "Joy-Con (\(side == .left ? "L" : "R"))"
        let open = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard open == kIOReturnSuccess else {
            NSLog("[joycon-keys] raw open failed 0x%X for %@", open, name)
            return
        }
        let d = Device(dev, side: side, name: name)
        devices[dev] = d
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, d.buffer, 362, { ctx, _, _, _, reportID, report, length in
            Unmanaged<RawHIDBackend>.fromOpaque(ctx!).takeUnretainedValue()
                .handleReport(reportID: reportID, bytes: report, length: length)
        }, ctx)
        sendSubcommand(d, 0x03, [0x30])  // standard full report mode
        d.modeSetAttempts = 1
        notifyMain { $0.backendConnected(id: ObjectIdentifier(dev), side: side, name: name) }
    }

    private func detach(_ dev: IOHIDDevice) {
        guard let d = devices.removeValue(forKey: dev) else { return }
        notifyMain { $0.backendDisconnected(id: ObjectIdentifier(dev), name: d.name) }
    }

    // MARK: reports (HID queue)

    private func handleReport(reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        // Identify source device by scanning our table for the buffer —
        // callback context is self, the report pointer IS the device buffer.
        guard let d = devices.values.first(where: { $0.buffer == bytes }) else { return }
        let data = Array(UnsafeBufferPointer(start: bytes, count: length))

        if reportID == 0x3F, d.modeSetAttempts > 0, d.modeSetAttempts < 4 {
            // Still in simple mode — the mode-set subcommand didn't land yet.
            d.modeSetAttempts += 1
            sendSubcommand(d, 0x03, [0x30])
            return
        }
        if reportID == 0x21 {
            handleSubcommandReply(d, data)  // Task 6 fills this in
            return
        }
        guard reportID == 0x30,
              let parsed = JoyConReport.parseStandard(data, side: d.side) else { return }

        if debug, parsed.pressed != d.previous {
            NSLog("[debug] raw %@ pressed=%@", d.name,
                  parsed.pressed.map(\.rawValue).sorted().joined(separator: ","))
        }
        // Edge emission: 0x30 streams at ~60 Hz; only diffs cross to main.
        let went = parsed.pressed.subtracting(d.previous)
        let released = d.previous.subtracting(parsed.pressed)
        d.previous = parsed.pressed
        for b in went { notifyMain { $0.backendButton(b, pressed: true) } }
        for b in released { notifyMain { $0.backendButton(b, pressed: false) } }

        if let stick = parsed.stick {
            let (x, y) = d.calibration.normalize(stick)
            let id = ObjectIdentifier(d.device)
            // Raw axes arrive in the upright vertical-grip frame: +y up, +x right.
            notifyMain { $0.backendStick(id, up: y, right: x) }
        }
    }

    private func handleSubcommandReply(_ d: Device, _ data: [UInt8]) {
        // Task 6: SPI calibration replies. Until then: ignore.
    }

    // MARK: subcommands (HID queue)

    private func sendSubcommand(_ d: Device, _ subcommand: UInt8, _ args: [UInt8]) {
        var packet: [UInt8] = [d.packetCounter]
        d.packetCounter = (d.packetCounter + 1) & 0x0F
        packet += [0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40]  // neutral rumble
        packet += [subcommand] + args
        // Report ID 0x01 goes in the reportID parameter, NOT the buffer.
        let r = IOHIDDeviceSetReport(d.device, kIOHIDReportTypeOutput, 0x01, packet, packet.count)
        if r != kIOReturnSuccess {
            NSLog("[joycon-keys] raw subcommand 0x%02X failed 0x%X", subcommand, r)
        }
    }

    private func notifyMain(_ body: @escaping (BackendDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let delegate = self?.delegate else { return }
            body(delegate)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5` — expected: clean. (Backend not yet
reachable from the app; that wiring is Task 7. Compile-only checkpoint.)

- [ ] **Step 3: Commit**

```bash
git add Sources/JoyConKeys/Engine/RawHID/RawHIDBackend.swift
git commit -m "feat: raw HID backend — device lifecycle, mode set, button edges"
```

---

### Task 6: RawHIDBackend — stick calibration over SPI

**Files:**
- Modify: `Sources/JoyConKeys/Engine/RawHID/RawHIDBackend.swift`

**Interfaces:**
- Consumes: `StickCalibration.decode(spi:side:)` (Task 3).
- Produces: calibrated stick values flowing through `backendStick`.

- [ ] **Step 1: Request calibration on attach**

In `attach(_:)`, after the mode-set subcommand, add:

```swift
        requestCalibration(d)
```

And implement (SPI read: subcommand 0x10, args = 4-byte LE address + length):

```swift
    /// Factory calibration: left 0x603D, right 0x6046 (9 bytes). User
    /// calibration (left 0x8010, right 0x801B: 2-byte magic 0xB2A1 + 9
    /// bytes) overrides factory when its magic is present — read 11 bytes
    /// starting at the magic and decide from the reply.
    private func requestCalibration(_ d: Device) {
        let factory: UInt32 = d.side == .left ? 0x603D : 0x6046
        let user: UInt32 = d.side == .left ? 0x8010 : 0x801B
        sendSubcommand(d, 0x10, spiArgs(factory, 9))
        sendSubcommand(d, 0x10, spiArgs(user, 11))
    }

    private func spiArgs(_ addr: UInt32, _ len: UInt8) -> [UInt8] {
        [UInt8(addr & 0xFF), UInt8((addr >> 8) & 0xFF),
         UInt8((addr >> 16) & 0xFF), UInt8((addr >> 24) & 0xFF), len]
    }
```

- [ ] **Step 2: Parse the SPI reply**

Replace the `handleSubcommandReply` stub:

```swift
    /// 0x21 reply layout: byte 13 ack (bit 7 set = OK), byte 14 replied
    /// subcommand, and for SPI reads bytes 15-18 echo the address, 19 the
    /// length, 20+ the payload.
    private func handleSubcommandReply(_ d: Device, _ data: [UInt8]) {
        guard data.count > 20, data[13] & 0x80 != 0, data[14] == 0x10 else { return }
        let addr = UInt32(data[15]) | (UInt32(data[16]) << 8)
            | (UInt32(data[17]) << 16) | (UInt32(data[18]) << 24)
        let len = Int(data[19])
        guard data.count >= 20 + len else { return }
        let payload = Array(data[20..<(20 + len)])

        let factory: UInt32 = d.side == .left ? 0x603D : 0x6046
        let user: UInt32 = d.side == .left ? 0x8010 : 0x801B

        if addr == user, len == 11 {
            // Magic 0xB2A1 (LE bytes A1 B2) marks user calibration present.
            if payload[0] == 0xA1, payload[1] == 0xB2,
               let cal = StickCalibration.decode(spi: Array(payload[2...]), side: d.side) {
                d.calibration = cal
                d.calibrated = true
                if debug { NSLog("[debug] raw %@ user calibration loaded", d.name) }
            }
        } else if addr == factory, len == 9, !d.calibrated {
            if let cal = StickCalibration.decode(spi: payload, side: d.side) {
                d.calibration = cal
                d.calibrated = true
                if debug { NSLog("[debug] raw %@ factory calibration loaded", d.name) }
            }
        }
    }
```

(No timeout machinery: `calibration` starts at `.fallback`, so a lost reply
just means slightly coarser stick scaling — acceptable, logged via debug.)

- [ ] **Step 3: Build + tests**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5` — expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/JoyConKeys/Engine/RawHID/RawHIDBackend.swift
git commit -m "feat: raw HID stick calibration via SPI flash reads"
```

---

### Task 7: Toggle wiring — facade, Settings UI, permission path

**Files:**
- Modify: `Sources/JoyConKeys/Engine/ControllerEngine.swift` (raw branch in `applyBackendPreference`)
- Modify: `Sources/JoyConKeys/UI/SettingsPane.swift` (new section + `AppDefaults.useRawHIDKey`)

**Interfaces:**
- Consumes: `RawHIDBackend` incl. `accessGranted()` / `requestAccess()` (Task 5),
  facade surface (Task 4).
- Produces: user-visible toggle; `AppDefaults.useRawHIDKey = "useRawHID"`.

- [ ] **Step 1: Facade raw branch**

Replace `applyBackendPreference` body in `ControllerEngine`:

```swift
    /// Reads the useRawHID default and swaps backends if needed. Raw HID
    /// requires Input Monitoring; when denied we fall back to GameController
    /// and surface it via rawHIDDenied so Settings can show remediation.
    func applyBackendPreference() {
        let wantRaw = UserDefaults.standard.bool(forKey: AppDefaults.useRawHIDKey)
        let canRaw = wantRaw && RawHIDBackend.accessGranted()
        rawHIDDenied = wantRaw && !canRaw
        let needsSwap: Bool
        switch backend {
        case is RawHIDBackend: needsSwap = !canRaw
        case is GCBackend: needsSwap = canRaw
        default: needsSwap = true  // first launch
        }
        guard needsSwap else { return }
        backend?.stop()
        clearLiveState()
        let next: InputBackend = canRaw ? RawHIDBackend() : GCBackend()
        backend = next
        next.start(delegate: self)
        NSLog("[joycon-keys] input backend: %@", canRaw ? "raw HID" : "GameController")
    }
```

Also add to the app-becomes-active path: in `SettingsPane` (next step) the
`didBecomeActiveNotification` handler calls `engine.applyBackendPreference()`
— that is what flips to raw automatically after the user grants permission
and returns to the app (if macOS requires an app relaunch for the grant, the
launch-time `applyBackendPreference()` covers it).

- [ ] **Step 2: Settings section**

In `SettingsPane`, add above the version/footer `Section`:

```swift
            Section("Input engine") {
                Toggle("Always use raw HID", isOn: Binding(
                    get: { useRawHID },
                    set: { enable in
                        useRawHID = enable
                        if enable && !RawHIDBackend.accessGranted() {
                            RawHIDBackend.requestAccess()
                        }
                        engine.applyBackendPreference()
                    }))
                if engine.rawHIDDenied {
                    Text("Raw HID needs Input Monitoring permission.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Open Privacy & Security › Input Monitoring") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                    .font(.caption)
                }
                Text("Reads Joy-Con directly over Bluetooth HID. All four SL/SR buttons work even when macOS combines the pair — no Capture+Home gesture needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

With supporting properties on `SettingsPane`:

```swift
    @EnvironmentObject var engine: ControllerEngine
    @AppStorage(AppDefaults.useRawHIDKey) private var useRawHID = false
```

Extend the existing `didBecomeActiveNotification` `.onReceive` closure to also
call `engine.applyBackendPreference()`, and extend `AppDefaults`:

```swift
enum AppDefaults {
    static let startMinimizedKey = "startMinimized"
    static let startMinimizedDefault = true
    static let useRawHIDKey = "useRawHID"
}
```

(`ContentView` already injects the engine into the environment tree; verify
`SettingsPane` actually receives it — it is instantiated inside `ContentView`,
so `@EnvironmentObject` resolves. If not, pass it explicitly.)

- [ ] **Step 3: Build + tests**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5` — expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/JoyConKeys/Engine/ControllerEngine.swift Sources/JoyConKeys/UI/SettingsPane.swift
git commit -m "feat: Always-use-raw-HID toggle with Input Monitoring fallback"
```

---

### Task 8: Hardware test matrix, docs, version bump

- [ ] **Step 1: Deploy and grant**

```bash
./deploy.sh
```

Flip the toggle ON in Settings (⚙ tab). Expected: red caption appears (app has
no Input Monitoring yet); click the button, grant **JoyConKeys** in System
Settings › Privacy & Security › Input Monitoring. Return to the app (relaunch
via `launchctl kickstart -k gui/$UID/com.xiaosong.joycon-keys` if the grant
doesn't take live). Log must show `input backend: raw HID`.

- [ ] **Step 2: Run the matrix (user presses buttons; verify via log + typed output)**

| # | Scenario | Expect |
|---|---|---|
| 1 | Toggle OFF | log `input backend: GameController`, behavior = v0.1.1 |
| 2 | Raw + single R | SL, SR, ZR, R, A/B/X/Y, stick repeat all fire |
| 3 | Raw + single L | arrows mirror to face actions, SL/SR, ZL/L, stick |
| 4 | Raw + both split | two devices in header, both fully live |
| 5 | Raw + both combined (Capture+Home) | **identical to #4 — SL/SR alive** |
| 6 | Live toggle flip both ways | no stuck keys, no double events |
| 7 | Charging swap (dock one half mid-use) | clean disconnect/reconnect, no gesture |
| 8 | Stick feel raw vs GC | arrow-repeat cadence indistinguishable |

Fix whatever fails before proceeding; re-run the failed row after each fix.
Check with `JOYKEYS_DEBUG=1` if element identity looks wrong — especially the
left-stick raw axis orientation (spec assumed upright frame; if deflections
are rotated, correct the `(up: y, right: x)` mapping in `handleReport` and
note it in the spec).

- [ ] **Step 3: README + version**

- `scripts/Info.plist`: `CFBundleShortVersionString` → `0.2.0`,
  `CFBundleVersion` → `3`.
- `README.md`: new subsection under Settings docs — what the toggle does, that
  it needs Input Monitoring, why it exists (macOS merge kills SL/SR; link
  https://github.com/libsdl-org/SDL/issues/6095), and that the combine/split
  gesture becomes unnecessary.

- [ ] **Step 4: Commit**

```bash
git add scripts/Info.plist README.md
git commit -m "docs: raw HID toggle docs; bump to 0.2.0"
```

---

### Task 9: PR review, merge, release

- [ ] **Step 1: Push branch + open PR**

```bash
git push -u origin feature/raw-hid-engine
gh pr create --title "Raw HID input engine (SL/SR in combined mode)" \
  --body "Adds an opt-in IOHIDManager backend so all four SL/SR rail buttons work regardless of macOS Joy-Con merge state. Spec: docs/superpowers/specs/2026-07-30-raw-hid-engine-design.md"
```

- [ ] **Step 2: Opus adversarial review**

Dispatch an Opus subagent to review the full branch diff
(`git diff main...feature/raw-hid-engine`) PR-style: correctness of the HID
callback threading (device table mutated on HID queue vs stop() from main),
Unmanaged context lifetime, packet-counter/subcommand protocol, edge-emission
correctness, facade swap state hygiene, Settings binding re-entry. Fix every
validated finding; commit fixes; stop the reviewer agent when done (user
requirement: never leave idle agents).

- [ ] **Step 3: Merge + release**

```bash
gh pr merge --squash --delete-branch   # retry once after `sleep 3` if "out of date" race
git checkout main && git pull --ff-only
./scripts/build-app.sh
ditto -c -k --keepParent dist/JoyConKeys.app /tmp/JoyConKeys-0.2.0.zip
gh release create v0.2.0 /tmp/JoyConKeys-0.2.0.zip --title "v0.2.0 — raw HID engine" \
  --notes "Opt-in raw HID input engine: SL/SR work even when macOS combines the pair. Requires Input Monitoring permission."
```

- [ ] **Step 4: File the session** — update memory (`reference_joycon-keys-mapper`),
  daily note Done entry, redeploy locally with `./deploy.sh`, verify log shows
  `input backend: raw HID`.
