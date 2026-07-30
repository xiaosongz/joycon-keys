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
    /// Which dpad currently owns the digital stick direction — so centering
    /// one stick can't cancel a repeat the *other* stick is driving.
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

    /// Stick-to-digital with hysteresis: engage past 0.6, release inside
    /// 0.4; the dominant axis wins so diagonals don't flicker. Only the
    /// stick that engaged a direction may release it — a second stick
    /// centering must not cancel the first one's auto-repeat.
    private func handleStick(_ stick: ObjectIdentifier, up: Float, right: Float) {
        let dirs: Set<PadButton> = [.stickUp, .stickDown, .stickLeft, .stickRight]
        if abs(up) < 0.4 && abs(right) < 0.4 {
            guard activeStick == nil || activeStick == stick else { return }
            activeStick = nil
            repeater.release()
            pressed.subtract(dirs)
            return
        }
        var dir: PadButton?
        if abs(up) >= abs(right) {
            if up > 0.6 { dir = .stickUp } else if up < -0.6 { dir = .stickDown }
        } else {
            if right > 0.6 { dir = .stickRight } else if right < -0.6 { dir = .stickLeft }
        }
        guard let dir else { return }
        activeStick = stick
        pressed.subtract(dirs.subtracting([dir]))
        pressed.insert(dir)
        repeater.press(dir) { [weak self] in
            guard let self else { return }
            KeySynth.perform(self.store.action(for: dir))
        }
    }
}

/// Fires an action immediately, then auto-repeats it while held
/// (400 ms delay, then every 120 ms) — keyboard-style repeat for the stick.
@MainActor
final class Repeater {
    private var timer: DispatchSourceTimer?
    private(set) var active: PadButton?

    func press(_ id: PadButton, _ fire: @escaping @MainActor () -> Void) {
        guard active != id else { return }
        release()
        active = id
        fire()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.40, repeating: 0.12)
        t.setEventHandler { MainActor.assumeIsolated { fire() } }
        t.resume()
        timer = t
    }

    func release() {
        timer?.cancel()
        timer = nil
        active = nil
    }

    deinit {
        // Deallocating a resumed-but-uncancelled DispatchSource traps.
        timer?.cancel()
    }
}
