import Foundation

@MainActor
protocol BackendDelegate: AnyObject {
    func backendConnected(id: ObjectIdentifier, side: JoyConSide, name: String)
    func backendDisconnected(id: ObjectIdentifier, name: String)
    func backendButton(device: ObjectIdentifier, _ button: PadButton, pressed: Bool)
    /// up/right already in the upright vertical-grip frame, [-1, 1].
    func backendStick(device: ObjectIdentifier, stick: ObjectIdentifier, up: Float, right: Float)
    /// Runtime permission loss (I-1): the backend discovered — after a
    /// pre-flight check already looked fine — that it cannot actually open a
    /// device (e.g. IOHIDCheckAccess reads stale-granted TCC state after a
    /// rebuild/re-sign, but IOHIDDeviceOpen returns kIOReturnNotPermitted).
    /// Default no-op so backends that can never hit this (GCBackend) need no
    /// conformance change.
    func backendPermissionDenied()
    /// The selected backend could not start at all. The facade falls back to
    /// its safe backend and surfaces `reason` rather than remaining inert.
    func backendUnavailable(reason: String)
    /// One matched device opened but never became usable. Other devices may
    /// remain live, so this is surfaced without tearing down the whole backend.
    func backendDeviceFailed(name: String, reason: String)
}

extension BackendDelegate {
    func backendPermissionDenied() {}
    func backendUnavailable(reason: String) {}
    func backendDeviceFailed(name: String, reason: String) {}
}

@MainActor
protocol InputBackend: AnyObject {
    func start(delegate: BackendDelegate)
    func stop()
}
