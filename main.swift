// joycon-keys — map Joy-Con buttons to keyboard events on macOS.
//
// Uses the system GameController framework (native Joy-Con support since
// macOS 13 Ventura) and synthesizes keyboard events via CGEvent.
//
// Mapping:
//   stick / dpad up-down  -> Up / Down arrow (with auto-repeat)
//   A                     -> Return
//   B                     -> Escape
//   X                     -> "1"
//   Y                     -> "2"
//   stick click           -> F5            (dictation toggle)
//   Plus / Minus          -> Shift+Tab     (Claude Code mode switch)
//
// Build:  swiftc -O main.swift -o joycon-keys
// Run:    ./joycon-keys   (needs Accessibility permission for key synthesis)

import Foundation
import GameController
import CoreGraphics
import ApplicationServices

// MARK: - Key codes (Carbon virtual key codes)

let KEY_RETURN: CGKeyCode = 36
let KEY_TAB: CGKeyCode = 48
let KEY_ESCAPE: CGKeyCode = 53
let KEY_F5: CGKeyCode = 96
let KEY_DOWN: CGKeyCode = 125
let KEY_UP: CGKeyCode = 126
let KEY_1: CGKeyCode = 18
let KEY_2: CGKeyCode = 19
let KEY_SPACE: CGKeyCode = 49
let KEY_CONTROL: CGKeyCode = 59

// MARK: - Key synthesis

// Modifier flags go on the key-DOWN only; the key-up must carry empty flags,
// otherwise the synthetic modifier (especially Fn) stays latched system-wide.
func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
    down.flags = flags
    up.flags = []
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

// Dictation shortcut on this machine = "press Control twice" (symbolic
// hotkey 164, type=modifier, mask 262144). Verified: synthetic double-tap
// triggers it; Fn+Space does not (that shortcut is not registered).
func postDictationToggle() {
    let src = CGEventSource(stateID: .hidSystemState)
    for tap in 0..<2 {
        if tap > 0 { usleep(120_000) }
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: KEY_CONTROL, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: KEY_CONTROL, keyDown: false) else { continue }
        down.flags = .maskControl
        up.flags = []
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
    }
}

// Fn+Space as an explicit press-and-release sequence (~0.2 s total).
// Fn has no ordinary key events — it must be synthesized as flagsChanged
// (vk 63) with the flag set on press and CLEARED on release; a flags-only
// space event leaves Fn latched system-wide because no fn-up ever fires.
func postFnSpace() {
    let src = CGEventSource(stateID: .hidSystemState)
    if let fnDown = CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: true) {
        fnDown.type = .flagsChanged
        fnDown.flags = .maskSecondaryFn
        fnDown.post(tap: .cghidEventTap)
    }
    usleep(50_000)
    if let d = CGEvent(keyboardEventSource: src, virtualKey: KEY_SPACE, keyDown: true) {
        d.flags = .maskSecondaryFn
        d.post(tap: .cghidEventTap)
    }
    usleep(50_000)
    if let u = CGEvent(keyboardEventSource: src, virtualKey: KEY_SPACE, keyDown: false) {
        u.flags = .maskSecondaryFn
        u.post(tap: .cghidEventTap)
    }
    usleep(50_000)
    if let fnUp = CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: false) {
        fnUp.type = .flagsChanged
        fnUp.flags = []
        fnUp.post(tap: .cghidEventTap)
    }
}

// MARK: - Auto-repeat for held directions

final class Repeater {
    private var timer: DispatchSourceTimer?
    private(set) var activeKey: CGKeyCode?

    func press(_ key: CGKeyCode) {
        guard activeKey != key else { return }
        release()
        activeKey = key
        postKey(key)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.40, repeating: 0.12)
        t.setEventHandler { postKey(key) }
        t.resume()
        timer = t
    }

    func release() {
        timer?.cancel()
        timer = nil
        activeKey = nil
    }
}

let repeater = Repeater()

// Stick-to-digital with hysteresis: engage past 0.6, release inside 0.4.
func handleVertical(_ y: Float) {
    if y > 0.6 {
        repeater.press(KEY_UP)
    } else if y < -0.6 {
        repeater.press(KEY_DOWN)
    } else if abs(y) < 0.4 {
        repeater.release()
    }
}

// MARK: - Controller wiring
//
// A single Joy-Con exposes no extendedGamepad profile on macOS — only
// physicalInputProfile with: Button A/B/X/Y, Button Home, Button Menu,
// Direction Pad (the stick, as an analog dpad), Left/Right Shoulder (SL/SR).
// Binding by element name covers both a single Joy-Con and a combined pair.

let debug = ProcessInfo.processInfo.environment["JOYKEYS_DEBUG"] != nil

func bind(_ button: GCControllerButtonInput?, _ label: String,
          _ key: CGKeyCode, _ flags: CGEventFlags = []) {
    button?.pressedChangedHandler = { _, _, pressed in
        if debug { print("[debug] \(label) pressed=\(pressed)") }
        if pressed { postKey(key, flags: flags) }
    }
}

func bindAction(_ button: GCControllerButtonInput?, _ label: String, _ action: @escaping () -> Void) {
    button?.pressedChangedHandler = { _, _, pressed in
        if debug { print("[debug] \(label) pressed=\(pressed)") }
        if pressed { action() }
    }
}

func bindVertical(_ dpad: GCControllerDirectionPad?, _ label: String) {
    dpad?.valueChangedHandler = { _, x, y in
        if debug { print("[debug] \(label) x=\(x) y=\(y)") }
        handleVertical(y)
    }
}

func wire(_ controller: GCController) {
    let name = controller.vendorName ?? "unknown controller"
    let profile = controller.physicalInputProfile
    print("[joycon-keys] wired: \(name) — elements: \(profile.elements.keys.sorted().joined(separator: ", "))")

    bind(profile.buttons[GCInputButtonA], "A", KEY_RETURN)
    bind(profile.buttons[GCInputButtonB], "B", KEY_ESCAPE)
    bind(profile.buttons[GCInputButtonX], "X", KEY_1)
    bind(profile.buttons[GCInputButtonY], "Y", KEY_2)
    // Single Joy-Con reports only SL/SR (as Left/Right Shoulder); a combined
    // pair reports ZL/ZR (as triggers) instead — see SDL issue #6095.
    // SL = macOS dictation (synthetic double-Control, the registered hotkey);
    // SR = synthetic Fn+Space (third-party voice input shortcut).
    bindAction(profile.buttons[GCInputLeftShoulder], "LeftShoulder", postDictationToggle)
    bindAction(profile.buttons[GCInputRightShoulder], "RightShoulder", postFnSpace)
    bindAction(profile.buttons[GCInputLeftTrigger], "LeftTrigger", postDictationToggle)
    bindAction(profile.buttons[GCInputRightTrigger], "RightTrigger", postFnSpace)
    bindAction(profile.buttons[GCInputButtonHome], "Home", postDictationToggle)
    bind(profile.buttons[GCInputButtonMenu], "Menu", KEY_TAB, .maskShift)
    bind(profile.buttons[GCInputButtonOptions], "Options", KEY_TAB, .maskShift)

    bindVertical(profile.dpads[GCInputDirectionPad], "DirectionPad")
    bindVertical(profile.dpads[GCInputLeftThumbstick], "LeftStick")
    bindVertical(profile.dpads[GCInputRightThumbstick], "RightStick")
}

// MARK: - Main

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered even when piped (launchd logs)

let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
if !trusted {
    print("[joycon-keys] WARNING: no Accessibility permission — key events will be silently dropped.")
    print("             System Settings > Privacy & Security > Accessibility > enable your terminal (or this binary).")
}

// Receive controller input even when this process is not frontmost.
GCController.shouldMonitorBackgroundEvents = true

NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
    if let c = note.object as? GCController { wire(c) }
}
NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { note in
    let name = (note.object as? GCController)?.vendorName ?? "controller"
    repeater.release()
    print("[joycon-keys] disconnected: \(name)")
}

GCController.startWirelessControllerDiscovery()
for c in GCController.controllers() { wire(c) }
print("[joycon-keys] running — waiting for Joy-Con (Ctrl-C to quit)")
RunLoop.main.run()
