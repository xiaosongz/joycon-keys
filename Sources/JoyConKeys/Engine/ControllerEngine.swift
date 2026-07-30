import Combine
import Foundation
import GameController

/// Connects to Joy-Con via the GameController framework, fires mapped
/// actions, and publishes connection + pressed state for the UI.
///
/// A single Joy-Con exposes NO extendedGamepad profile on macOS — only
/// physicalInputProfile with Button A/B/X/Y, Home (R) / Share (L), Menu,
/// Direction Pad (the stick), and Left/Right Shoulder (= SL/SR). A combined
/// pair reports ZL/ZR as triggers instead and loses SL/SR (SDL issue #6095).
@MainActor
final class ControllerEngine: ObservableObject {
    struct Connected: Identifiable, Equatable {
        let id: ObjectIdentifier
        let side: JoyConSide
        let name: String
    }

    @Published private(set) var connected: [Connected] = []
    @Published private(set) var pressed: Set<PadButton> = []

    private let store: MappingStore
    private let repeater = Repeater()
    /// Which dpad currently owns the digital stick direction — so centering
    /// one stick can't cancel a repeat the *other* stick is driving.
    private var activeStick: ObjectIdentifier?
    private var observers: [NSObjectProtocol] = []

    init(store: MappingStore) {
        self.store = store
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let c = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.wire(c) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let c = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.unwire(c) }
        })
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery()
        for c in GCController.controllers() { wire(c) }
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    static func side(of controller: GCController) -> JoyConSide {
        let name = controller.vendorName ?? ""
        if name.contains("(L)") { return .left }
        if name.contains("(R)") { return .right }
        return .other
    }

    private func wire(_ controller: GCController) {
        // The framework default is already the main queue, but every
        // MainActor.assumeIsolated below TRAPS if that ever changes — pin it.
        // Must be set before handlers are configured (GCDevicePhysicalInput).
        controller.handlerQueue = .main
        let side = Self.side(of: controller)
        let entry = Connected(
            id: ObjectIdentifier(controller), side: side,
            name: controller.vendorName ?? "Controller")
        connected.removeAll { $0.id == entry.id }
        connected.append(entry)
        NSLog("[joycon-keys] wired: %@ (%@)", entry.name, side.rawValue)

        let p = controller.physicalInputProfile
        bind(p.buttons[GCInputButtonA], .buttonA)
        bind(p.buttons[GCInputButtonB], .buttonB)
        bind(p.buttons[GCInputButtonX], .buttonX)
        bind(p.buttons[GCInputButtonY], .buttonY)
        bind(p.buttons[GCInputLeftShoulder], .shoulderLeft)
        bind(p.buttons[GCInputRightShoulder], .shoulderRight)
        bind(p.buttons[GCInputLeftTrigger], .triggerLeft)
        bind(p.buttons[GCInputRightTrigger], .triggerRight)
        bind(p.buttons[GCInputButtonHome], .home)
        bind(p.buttons[GCInputButtonShare], .capture)
        bind(p.buttons[GCInputButtonMenu], .menu)
        bind(p.buttons[GCInputButtonOptions], .options)

        if side == .other {
            // Combined "Joy-Con (L/R)": macOS merges both minis into one
            // controller and we cannot split it, so treat each half as the
            // SAME mirrored remote instead of a big gamepad. The left
            // half's arrow buttons arrive as a digital Direction Pad —
            // mirror them onto the face-button actions by position
            // (▲=X, ▶=A, ▼=B, ◀=Y), and let both thumbsticks drive the
            // stick actions (axes are already upright in this mode).
            if let dpad = p.dpads[GCInputDirectionPad] {
                bind(dpad.up, .buttonX)
                bind(dpad.right, .buttonA)
                bind(dpad.down, .buttonB)
                bind(dpad.left, .buttonY)
            }
        } else {
            // Single Joy-Con: the Direction Pad IS the analog stick.
            bindStick(p.dpads[GCInputDirectionPad], side: side)
        }
        bindStick(p.dpads[GCInputLeftThumbstick], side: side)
        bindStick(p.dpads[GCInputRightThumbstick], side: side)
    }

    private func unwire(_ controller: GCController) {
        connected.removeAll { $0.id == ObjectIdentifier(controller) }
        // Only wipe live input state when nothing is left — another
        // still-connected controller may be mid-press or mid-repeat.
        if connected.isEmpty {
            repeater.release()
            pressed.removeAll()
            activeStick = nil
        }
        NSLog("[joycon-keys] disconnected: %@", controller.vendorName ?? "controller")
    }

    private let debug = ProcessInfo.processInfo.environment["JOYKEYS_DEBUG"] != nil

    private func bind(_ button: GCControllerButtonInput?, _ id: PadButton) {
        guard let button else { return }
        let debug = self.debug
        button.pressedChangedHandler = { [weak self] element, _, isPressed in
            guard let self else { return }
            if debug {
                NSLog("[debug] %@ -> %@ pressed=%d",
                      element.localizedName ?? "?", id.rawValue, isPressed ? 1 : 0)
            }
            MainActor.assumeIsolated {
                if isPressed {
                    self.pressed.insert(id)
                    KeySynth.perform(self.store.action(for: id))
                } else {
                    self.pressed.remove(id)
                }
            }
        }
    }

    /// Vertical-grip axis remap. macOS reports single-Joy-Con axes in the
    /// SIDEWAYS grip frame (rail up, stick left of the face buttons):
    ///   Joy-Con (R): grip up = reported +x, grip right = reported -y
    ///   Joy-Con (L): grip up = reported -x, grip right = reported +y
    /// Anything else (combined pair, Pro Controller) is already upright.
    private func bindStick(_ dpad: GCControllerDirectionPad?, side: JoyConSide) {
        guard let dpad else { return }
        let stick = ObjectIdentifier(dpad)
        dpad.valueChangedHandler = { [weak self] _, x, y in
            guard let self else { return }
            let (up, right): (Float, Float)
            switch side {
            case .right: (up, right) = (x, -y)
            case .left: (up, right) = (-x, y)
            case .other: (up, right) = (y, x)
            }
            MainActor.assumeIsolated { self.handleStick(stick, up: up, right: right) }
        }
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
