import Foundation

/// One decoded standard-full-mode (0x30) input report from a single physical
/// Joy-Con. Pure byte parsing — no IOKit, fully unit-testable.
struct RawStick: Equatable {
    var x: Int
    var y: Int
}

struct JoyConReport: Equatable {
    var pressed: Set<PadButton>
    var stick: RawStick?

    /// Layout (https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering):
    /// byte 3 right-half buttons, byte 4 shared, byte 5 left-half buttons,
    /// bytes 6-8 left stick, 9-11 right stick (two packed 12-bit axes).
    /// `side` comes from the HID product ID (0x2006 left / 0x2007 right);
    /// a physical Joy-Con only ever sets its own half's bytes.
    static func parseStandard(_ bytes: [UInt8], side: JoyConSide) -> JoyConReport? {
        guard bytes.count >= 12, bytes[0] == 0x30 else { return nil }
        var pressed: Set<PadButton> = []

        let b3 = bytes[3]  // right half
        if b3 & 0x01 != 0 { pressed.insert(.buttonY) }
        if b3 & 0x02 != 0 { pressed.insert(.buttonX) }
        if b3 & 0x04 != 0 { pressed.insert(.buttonB) }
        if b3 & 0x08 != 0 { pressed.insert(.buttonA) }
        if b3 & 0x10 != 0 { pressed.insert(.shoulderRight) }  // SR(R)
        if b3 & 0x20 != 0 { pressed.insert(.shoulderLeft) }   // SL(R)
        // Large rail R and trigger ZR fold into the same action row — R has
        // no PadButton identity of its own (spec §RawHIDBackend).
        if b3 & 0xC0 != 0 { pressed.insert(.triggerRight) }

        let b4 = bytes[4]  // shared
        if b4 & 0x01 != 0 { pressed.insert(.options) }  // −
        if b4 & 0x02 != 0 { pressed.insert(.menu) }     // +
        // 0x04 / 0x08 = stick clicks: ignored, same as the GC engine.
        if b4 & 0x10 != 0 { pressed.insert(.home) }
        if b4 & 0x20 != 0 { pressed.insert(.capture) }

        let b5 = bytes[5]  // left half — arrows mirror face actions by position
        if b5 & 0x01 != 0 { pressed.insert(.buttonB) }  // ▼
        if b5 & 0x02 != 0 { pressed.insert(.buttonX) }  // ▲
        if b5 & 0x04 != 0 { pressed.insert(.buttonA) }  // ▶
        if b5 & 0x08 != 0 { pressed.insert(.buttonY) }  // ◀
        if b5 & 0x10 != 0 { pressed.insert(.shoulderRight) }  // SR(L)
        if b5 & 0x20 != 0 { pressed.insert(.shoulderLeft) }   // SL(L)
        if b5 & 0xC0 != 0 { pressed.insert(.triggerLeft) }    // L / ZL

        let s = side == .left ? Array(bytes[6...8]) : Array(bytes[9...11])
        let stick = RawStick(
            x: Int(s[0]) | (Int(s[1] & 0x0F) << 8),
            y: (Int(s[1]) >> 4) | (Int(s[2]) << 4))

        return JoyConReport(pressed: pressed, stick: stick)
    }
}
