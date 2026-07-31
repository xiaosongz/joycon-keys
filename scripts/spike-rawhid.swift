#!/usr/bin/env swift
// Spike: do Joy-Con HID devices deliver raw input reports while the
// GameController framework coexists? Run from a terminal that has (or can
// be granted) Input Monitoring. Dumps report ID + first 12 bytes.
import Foundation
import IOKit.hid

// Line-buffer stdout: the run ends via SIGTERM (timeout), which would
// otherwise discard everything still sitting in the block buffer.
setvbuf(stdout, nil, _IOLBF, 0)

let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
print("Input Monitoring access: \(access == kIOHIDAccessTypeGranted ? "granted" : "NOT granted (\(access))")")
if access != kIOHIDAccessTypeGranted { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatchingMultiple(manager, [
    [kIOHIDVendorIDKey: 0x057E, kIOHIDProductIDKey: 0x2006],
    [kIOHIDVendorIDKey: 0x057E, kIOHIDProductIDKey: 0x2007],
] as CFArray)

var buffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
var lastLine: [String: String] = [:]
var counter: UInt8 = 0

let matchCallback: IOHIDDeviceCallback = { _, _, _, device in
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    let open = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    print("matched: \(name) open=\(String(format: "0x%X", open))")
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    buffers[device] = buf
    IOHIDDeviceRegisterInputReportCallback(device, buf, 64, { ctx, _, _, _, reportID, report, length in
        let bytes = (0..<min(length, 12)).map { String(format: "%02X", report[$0]) }.joined(separator: " ")
        let name = ctx.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
        let line = "[\(name)] id=0x\(String(format: "%02X", reportID)) \(bytes)"
        // Only print on change — 0x30 streams at 60 Hz.
        if lastLine[name] != line {
            lastLine[name] = line
            print(line)
        }
    }, Unmanaged.passRetained(name as CFString).toOpaque())
    // Subcommand 0x03 0x30 (standard full report mode), retried every 3 s
    // alternating two buffer conventions — first run showed setReport
    // succeeding (0x0) while the device stayed in 0x3F simple mode:
    //   A: payload without report ID (ID passed only as the reportID param)
    //   B: payload with a leading 0x01 ID byte as well
    let timer = Timer(timeInterval: 3, repeats: true) { _ in
        let body: [UInt8] = [counter, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x03, 0x30]
        counter = (counter &+ 1) & 0x0F
        let convB = counter % 2 == 0
        let packet: [UInt8] = convB ? [0x01] + body : body
        let r = packet.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x01, $0.baseAddress!, $0.count)
        }
        print("mode-set conv\(convB ? "B" : "A") setReport: \(String(format: "0x%X", r))")
    }
    RunLoop.current.add(timer, forMode: .default)
}
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
print("open result: \(String(format: "0x%X", IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))))")
print("Press Joy-Con buttons now. Ctrl-C to quit.")
CFRunLoopRun()
