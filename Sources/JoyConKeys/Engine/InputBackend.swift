import Foundation

@MainActor
protocol BackendDelegate: AnyObject {
    func backendConnected(id: ObjectIdentifier, side: JoyConSide, name: String)
    func backendDisconnected(id: ObjectIdentifier, name: String)
    func backendButton(_ button: PadButton, pressed: Bool)
    /// up/right already in the upright vertical-grip frame, [-1, 1].
    func backendStick(_ stick: ObjectIdentifier, up: Float, right: Float)
    /// Runtime permission loss (I-1): the backend discovered — after a
    /// pre-flight check already looked fine — that it cannot actually open a
    /// device (e.g. IOHIDCheckAccess reads stale-granted TCC state after a
    /// rebuild/re-sign, but IOHIDDeviceOpen returns kIOReturnNotPermitted).
    /// Default no-op so backends that can never hit this (GCBackend) need no
    /// conformance change.
    func backendPermissionDenied()
}

extension BackendDelegate {
    func backendPermissionDenied() {}
}

@MainActor
protocol InputBackend: AnyObject {
    func start(delegate: BackendDelegate)
    func stop()
}
