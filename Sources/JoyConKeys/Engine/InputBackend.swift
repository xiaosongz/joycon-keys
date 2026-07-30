import Foundation

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
