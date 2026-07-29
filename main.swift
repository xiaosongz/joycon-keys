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

// MARK: - Key synthesis

func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { continue }
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
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

func edge(_ pressed: Bool, _ state: inout Bool, _ action: () -> Void) {
    if pressed && !state { action() }
    state = pressed
}

func wire(_ controller: GCController) {
    let name = controller.vendorName ?? "unknown controller"
    guard let pad = controller.extendedGamepad else {
        let elements = controller.physicalInputProfile.elements.keys.sorted().joined(separator: ", ")
        print("[joycon-keys] \(name): no extendedGamepad profile; elements: \(elements)")
        return
    }
    print("[joycon-keys] wired: \(name)")

    var aState = false, bState = false, xState = false, yState = false
    var menuState = false, optionsState = false
    var lClickState = false, rClickState = false

    pad.valueChangedHandler = { pad, _ in
        handleVertical(pad.leftThumbstick.yAxis.value + pad.rightThumbstick.yAxis.value
                       + (pad.dpad.up.isPressed ? 1 : 0) - (pad.dpad.down.isPressed ? 1 : 0))

        edge(pad.buttonA.isPressed, &aState) { postKey(KEY_RETURN) }
        edge(pad.buttonB.isPressed, &bState) { postKey(KEY_ESCAPE) }
        edge(pad.buttonX.isPressed, &xState) { postKey(KEY_1) }
        edge(pad.buttonY.isPressed, &yState) { postKey(KEY_2) }
        edge(pad.buttonMenu.isPressed, &menuState) { postKey(KEY_TAB, flags: .maskShift) }
        edge(pad.buttonOptions?.isPressed ?? false, &optionsState) { postKey(KEY_TAB, flags: .maskShift) }
        edge(pad.leftThumbstickButton?.isPressed ?? false, &lClickState) { postKey(KEY_F5) }
        edge(pad.rightThumbstickButton?.isPressed ?? false, &rClickState) { postKey(KEY_F5) }
    }
}

// MARK: - Main

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
