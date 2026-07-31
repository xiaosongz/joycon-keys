import Foundation
import GameController

/// Connects to Joy-Con via the GameController framework and forwards
/// connection + button + stick events to the facade's `BackendDelegate`.
///
/// A single Joy-Con exposes NO extendedGamepad profile on macOS — only
/// physicalInputProfile with Button A/B/X/Y, Home (R) / Share (L), Menu,
/// Direction Pad (the stick), and Left/Right Shoulder (= SL/SR). A combined
/// pair reports ZL/ZR as triggers instead and loses SL/SR (SDL issue #6095).
@MainActor
final class GCBackend: InputBackend {
    weak var delegate: BackendDelegate?

    private var observers: [NSObjectProtocol] = []
    private var wiredControllers: [GCController] = []

    func start(delegate: BackendDelegate) {
        self.delegate = delegate
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

    func stop() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        for controller in wiredControllers {
            let p = controller.physicalInputProfile
            for button in p.buttons.values { button.pressedChangedHandler = nil }
            for dpad in p.dpads.values {
                dpad.valueChangedHandler = nil
                for b in [dpad.up, dpad.down, dpad.left, dpad.right] { b.pressedChangedHandler = nil }
            }
        }
        wiredControllers.removeAll()
        delegate = nil
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
        wiredControllers.append(controller)
        delegate?.backendConnected(
            id: ObjectIdentifier(controller), side: side,
            name: controller.vendorName ?? "Controller")

        let p = controller.physicalInputProfile
        bind(p.buttons[GCInputButtonA], .buttonA)
        bind(p.buttons[GCInputButtonB], .buttonB)
        bind(p.buttons[GCInputButtonX], .buttonX)
        bind(p.buttons[GCInputButtonY], .buttonY)
        // The same GC element means a different physical button per mode:
        // a single Joy-Con reports its rail SL/SR as Left/Right Shoulder,
        // while a combined pair reports the big bumpers L/R there (and
        // never reports SL/SR at all — SDL issue #6095).
        if side == .other {
            bind(p.buttons[GCInputLeftShoulder], .bumperLeft)
            bind(p.buttons[GCInputRightShoulder], .bumperRight)
        } else {
            bind(p.buttons[GCInputLeftShoulder], .shoulderLeft)
            bind(p.buttons[GCInputRightShoulder], .shoulderRight)
        }
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
        wiredControllers.removeAll { $0 === controller }
        delegate?.backendDisconnected(
            id: ObjectIdentifier(controller), name: controller.vendorName ?? "controller")
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
                self.delegate?.backendButton(id, pressed: isPressed)
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
            MainActor.assumeIsolated { self.delegate?.backendStick(stick, up: up, right: right) }
        }
    }
}
