import AppKit
import ApplicationServices
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
    @Published private(set) var accessibilityTrusted = false
    /// True when the user wants raw HID but Input Monitoring is denied
    /// (Settings shows the remediation caption).
    @Published private(set) var rawHIDDenied = false
    /// Non-permission raw-HID startup/device failure for Settings remediation.
    @Published private(set) var rawHIDError: String?

    private let store: MappingStore
    private let repeater = Repeater()
    private var activationObserver: NSObjectProtocol?
    private var accessibilityChecked = false
    private struct StickIdentity: Hashable {
        let device: ObjectIdentifier
        let stick: ObjectIdentifier
    }
    /// Live state stays device-scoped so disconnecting one controller cannot
    /// leave its UI highlight or keyboard repeat behind while another remains.
    private var buttonsByDevice: [ObjectIdentifier: Set<PadButton>] = [:]
    private var stickDirections: [StickIdentity: PadButton] = [:]
    /// Which dpad currently owns the digital stick direction — so centering
    /// one stick can't cancel a repeat the *other* stick is driving.
    private var activeStick: StickIdentity?
    private var backend: InputBackend?
    /// Sticky for this launch: a runtime kIOReturnNotPermitted proves the
    /// cached IOHIDCheckAccess "granted" is stale, so re-trying raw HID on
    /// every activation would thrash backends (fail → fallback → retry).
    /// Cleared only by toggling raw HID off — a real TCC change needs an
    /// app relaunch anyway.
    private var rawRuntimeDenied = false
    /// Sticky for this launch, like rawRuntimeDenied, but kept separate so a
    /// manager-open failure is not mislabeled as a TCC denial.
    private var rawRuntimeUnavailable = false

    init(store: MappingStore, startBackend: Bool = true, promptForAccessibility: Bool = true) {
        self.store = store
        refreshAccessibility(prompt: promptForAccessibility)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibility() }
        }
        if startBackend { applyBackendPreference() }
    }

    func refreshAccessibility(prompt: Bool = false) {
        let trusted: Bool
        if prompt {
            trusted = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        } else {
            trusted = AXIsProcessTrusted()
        }
        let changed = accessibilityTrusted != trusted
        if changed { accessibilityTrusted = trusted }
        if !accessibilityChecked || changed {
            NSLog("[joycon-keys] accessibility trusted: %@",
                  trusted ? "yes" : "NO — grant it in System Settings › Privacy & Security › Accessibility")
        }
        accessibilityChecked = true
    }

    /// Reads the useRawHID default and swaps backends if needed. Raw HID
    /// needs Input Monitoring; when that is denied we stay on GameController
    /// and surface it via `rawHIDDenied` so Settings can show remediation.
    /// Cheap to call repeatedly (Settings calls it on every activation) —
    /// it returns immediately unless the running backend is the wrong one.
    func applyBackendPreference() {
        let wantRaw = UserDefaults.standard.bool(forKey: AppDefaults.useRawHIDKey)
        if !wantRaw {
            rawRuntimeDenied = false
            rawRuntimeUnavailable = false
            rawHIDError = nil
        }
        let accessGranted = RawHIDBackend.accessGranted()
        let canRaw = wantRaw && !rawRuntimeDenied && !rawRuntimeUnavailable && accessGranted
        // Settings calls this on every activation; only actually publish
        // when the value changes, or @Published fires objectWillChange for
        // no-op re-sets and floods SwiftUI with invalidations (MINOR-1).
        let denied = wantRaw && (rawRuntimeDenied || !accessGranted)
        if rawHIDDenied != denied { rawHIDDenied = denied }
        // With no backend yet (first launch) both casts are false, so this
        // reads as "needs swap" either way.
        let needsSwap = canRaw ? !(backend is RawHIDBackend) : !(backend is GCBackend)
        guard needsSwap else { return }
        backend?.stop()
        clearLiveState()
        let next: InputBackend = canRaw ? RawHIDBackend() : GCBackend()
        backend = next
        next.start(delegate: self)
        NSLog("[joycon-keys] input backend: %@",
              backend is RawHIDBackend ? "raw HID" : "GameController")
    }

    private func clearLiveState() {
        repeater.release()
        buttonsByDevice.removeAll()
        stickDirections.removeAll()
        pressed.removeAll()
        activeStick = nil
        connected.removeAll()
    }

    // MARK: BackendDelegate

    func backendConnected(id: ObjectIdentifier, side: JoyConSide, name: String) {
        if backend is RawHIDBackend { rawHIDError = nil }
        connected.removeAll { $0.id == id }
        connected.append(Connected(id: id, side: side, name: name))
        NSLog("[joycon-keys] wired: %@ (%@)", name, side.rawValue)
    }

    func backendDisconnected(id: ObjectIdentifier, name: String) {
        connected.removeAll { $0.id == id }
        buttonsByDevice.removeValue(forKey: id)
        stickDirections = stickDirections.filter { $0.key.device != id }
        if activeStick?.device == id {
            repeater.release()
            activeStick = nil
            resumeAnyHeldStick()
        }
        refreshPressed()
        NSLog("[joycon-keys] disconnected: %@", name)
    }

    func backendButton(device: ObjectIdentifier, _ button: PadButton, pressed isPressed: Bool) {
        var deviceButtons = buttonsByDevice[device] ?? []
        if isPressed {
            deviceButtons.insert(button)
            KeySynth.perform(store.action(for: button))
        } else {
            deviceButtons.remove(button)
        }
        if deviceButtons.isEmpty {
            buttonsByDevice.removeValue(forKey: device)
        } else {
            buttonsByDevice[device] = deviceButtons
        }
        refreshPressed()
    }

    func backendStick(device: ObjectIdentifier, stick: ObjectIdentifier, up: Float, right: Float) {
        handleStick(StickIdentity(device: device, stick: stick), up: up, right: right)
    }

    /// Runtime permission loss (I-1): the pre-flight IOHIDCheckAccess said
    /// granted, but an actual device open came back kIOReturnNotPermitted —
    /// stale TCC state after a rebuild/re-sign is the known repro. This is a
    /// forced fallback, not a preference re-apply: swap to GCBackend directly
    /// WITHOUT re-reading useRawHID, so the toggle stays ON and Settings
    /// shows the red caption. `rawRuntimeDenied` keeps later
    /// applyBackendPreference() calls from re-trying raw HID this launch
    /// (the stale-granted check would just fail the same way and thrash);
    /// recovery is toggle off/on or relaunch after fixing the grant.
    func backendPermissionDenied() {
        rawHIDDenied = true
        rawRuntimeDenied = true
        backend?.stop()
        clearLiveState()
        let next: InputBackend = GCBackend()
        backend = next
        next.start(delegate: self)
        NSLog("[joycon-keys] raw HID permission denied at runtime — falling back to GameController")
    }

    func backendUnavailable(reason: String) {
        rawHIDDenied = false
        rawHIDError = reason
        rawRuntimeUnavailable = true
        backend?.stop()
        clearLiveState()
        let next: InputBackend = GCBackend()
        backend = next
        next.start(delegate: self)
        NSLog("[joycon-keys] raw HID unavailable — falling back to GameController: %@", reason)
    }

    func backendDeviceFailed(name: String, reason: String) {
        rawHIDError = "\(name): \(reason)"
        NSLog("[joycon-keys] raw HID device failed: %@: %@", name, reason)
    }

    /// Stick-to-digital with hysteresis: engage past 0.6, release inside
    /// 0.4; the dominant axis wins so diagonals don't flicker. Only the
    /// stick that engaged a direction may release it — a second stick
    /// centering must not cancel the first one's auto-repeat.
    private func handleStick(_ stick: StickIdentity, up: Float, right: Float) {
        if abs(up) < 0.4 && abs(right) < 0.4 {
            stickDirections.removeValue(forKey: stick)
            guard activeStick == stick else {
                refreshPressed()
                return
            }
            repeater.release()
            activeStick = nil
            resumeAnyHeldStick()
            refreshPressed()
            return
        }
        var dir: PadButton?
        if abs(up) >= abs(right) {
            if up > 0.6 { dir = .stickUp } else if up < -0.6 { dir = .stickDown }
        } else {
            if right > 0.6 { dir = .stickRight } else if right < -0.6 { dir = .stickLeft }
        }
        guard let dir else { return }
        stickDirections[stick] = dir
        startRepeating(stick, direction: dir)
        refreshPressed()
    }

    private func startRepeating(_ stick: StickIdentity, direction: PadButton) {
        activeStick = stick
        repeater.press(direction) { [weak self] token in
            guard let self else { return }
            KeySynth.performRepeat(self.store.action(for: direction), token: token)
        }
    }

    private func resumeAnyHeldStick() {
        guard activeStick == nil, let (stick, direction) = stickDirections.first else { return }
        startRepeating(stick, direction: direction)
    }

    private func refreshPressed() {
        var live = buttonsByDevice.values.reduce(into: Set<PadButton>()) { $0.formUnion($1) }
        if let direction = repeater.active { live.insert(direction) }
        pressed = live
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }
}

/// Fires an action immediately, then auto-repeats it while held
/// (400 ms delay, then every 120 ms) — keyboard-style repeat for the stick.
@MainActor
final class Repeater {
    private var timer: DispatchSourceTimer?
    private var repeatToken: KeySynth.RepeatToken?
    private(set) var active: PadButton?

    func press(_ id: PadButton, _ fire: @escaping @MainActor (KeySynth.RepeatToken) -> Void) {
        guard active != id else { return }
        release()
        active = id
        let token = KeySynth.beginRepeat()
        repeatToken = token
        fire(token)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.40, repeating: 0.12)
        t.setEventHandler { MainActor.assumeIsolated { fire(token) } }
        t.resume()
        timer = t
    }

    func release() {
        timer?.cancel()
        timer = nil
        if let repeatToken { KeySynth.cancelRepeat(repeatToken) }
        repeatToken = nil
        active = nil
    }

    deinit {
        // Deallocating a resumed-but-uncancelled DispatchSource traps.
        timer?.cancel()
        if let repeatToken { KeySynth.cancelRepeat(repeatToken) }
    }
}
