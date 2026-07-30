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
        /// Polls the 0x03 0x30 mode-set subcommand until the first 0x30
        /// report proves the Joy-Con actually switched modes (see attach()).
        var modeSetTimer: DispatchSourceTimer?
        /// Last normalized stick value pushed to the delegate — 0x30 streams
        /// at 60 Hz/device, so a resting stick must not re-notify every
        /// report (see handleReport).
        var lastStick: (Float, Float)?
        init(_ d: IOHIDDevice, side: JoyConSide, name: String) {
            device = d; self.side = side; self.name = name
        }
        deinit { buffer.deallocate() }
    }

    private weak var delegate: BackendDelegate?
    private var manager: IOHIDManager?
    // `RawHIDBackend` conforms to the @MainActor `InputBackend` protocol, which
    // would otherwise infer this whole type — and this stored property — as
    // MainActor-isolated. `devices` is actually confined to `queue`: every
    // read/write happens from IOHIDManager's dispatch-queue callbacks (attach/
    // detach/handleReport) or from code explicitly hopping onto `queue` (see
    // stop()). The serial queue is the real synchronization, not the actor.
    private nonisolated(unsafe) var devices: [IOHIDDevice: Device] = [:]
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
        manager = nil
        delegate = nil
        // IOHIDManagerCancel is asynchronous; IOKit guarantees the cancel
        // handler runs on `queue` only after all in-flight events have been
        // delivered. Tearing down device state (unregistering the report
        // callback, closing the device, releasing the Device/its buffer)
        // from IN the handler — rather than a queue.async racing the cancel
        // — is what prevents IOKit from writing into a freed report buffer.
        // The `[self]` capture plus `_ = m` below keep both this backend and
        // the manager alive until IOKit invokes the handler and then
        // releases it itself, breaking the cycle without a `weak self`.
        IOHIDManagerSetCancelHandler(m) { [self] in
            for (dev, d) in devices {
                d.modeSetTimer?.cancel()
                d.modeSetTimer = nil
                IOHIDDeviceRegisterInputReportCallback(dev, d.buffer, 362, nil, nil)
                IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            devices.removeAll()
            _ = m   // keep the manager alive until its own cancel handler runs (I1)
        }
        IOHIDManagerCancel(m)
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

        // Hardware spike finding: the 0x03 0x30 mode-set subcommand is
        // silently ignored if sent immediately after IOHIDDeviceOpen — the
        // Joy-Con just keeps streaming 0x3F simple-mode reports. Those 0x3F
        // reports are event-driven (button presses only), so a controller
        // sitting idle never triggers a retry that way. Instead, poll the
        // subcommand on a repeating timer until a 0x30 report actually
        // proves the switch landed (see handleReport), then stop polling.
        sendSubcommand(d, 0x03, [0x30])
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.5, repeating: 2.5)
        timer.setEventHandler { [weak self] in
            guard let self, let d = self.devices[dev] else { return }
            self.sendSubcommand(d, 0x03, [0x30])
        }
        d.modeSetTimer = timer
        timer.resume()

        notifyMain { $0.backendConnected(id: ObjectIdentifier(dev), side: side, name: name) }
    }

    private func detach(_ dev: IOHIDDevice) {
        guard let d = devices.removeValue(forKey: dev) else { return }
        d.modeSetTimer?.cancel()
        d.modeSetTimer = nil
        IOHIDDeviceRegisterInputReportCallback(dev, d.buffer, 362, nil, nil)
        IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        for b in d.previous { notifyMain { $0.backendButton(b, pressed: false) } }
        d.previous = []
        notifyMain { $0.backendDisconnected(id: ObjectIdentifier(dev), name: d.name) }
    }

    // MARK: reports (HID queue)

    private func handleReport(reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        // Identify source device by scanning our table for the buffer —
        // callback context is self, the report pointer IS the device buffer.
        guard let d = devices.values.first(where: { $0.buffer == bytes }) else { return }

        if reportID == 0x21 {
            let data = Array(UnsafeBufferPointer(start: bytes, count: length))
            handleSubcommandReply(d, data)  // Task 6 fills this in
            return
        }
        // 0x3F simple-mode reports (and anything else) arrive until the
        // mode-set subcommand lands; nothing to parse from them.
        guard reportID == 0x30 else { return }

        // Mode set confirmed — stop polling for this device.
        if let timer = d.modeSetTimer {
            timer.cancel()
            d.modeSetTimer = nil
        }

        let data = Array(UnsafeBufferPointer(start: bytes, count: length))
        guard let parsed = JoyConReport.parseStandard(data, side: d.side) else { return }

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
            // 0x30 streams at 60 Hz/device; only push to MainActor when the
            // normalized value actually moved, or a resting pair floods
            // SwiftUI with @Published invalidations at 120/sec (I2).
            let moved = d.lastStick.map { abs($0.0 - x) > 0.01 || abs($0.1 - y) > 0.01 } ?? true
            if moved {
                d.lastStick = (x, y)
                let id = ObjectIdentifier(d.device)
                // Raw axes arrive in the upright vertical-grip frame: +y up, +x right.
                notifyMain { $0.backendStick(id, up: y, right: x) }
            }
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
        // Report ID 0x01 goes in the reportID parameter, NOT the buffer
        // (verified live: 0x21 ack + continuous 0x30 stream at 60 Hz).
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
