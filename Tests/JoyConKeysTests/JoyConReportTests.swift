import XCTest
@testable import JoyConKeys

final class JoyConReportTests: XCTestCase {
    /// 0x30 report skeleton: [id, timer, battery/conn, btn3, btn4, btn5,
    /// L-stick ×3, R-stick ×3]. Zero-filled beyond what a test sets.
    private func report(btn3: UInt8 = 0, btn4: UInt8 = 0, btn5: UInt8 = 0,
                        stick: [UInt8] = [0, 0, 0], right: Bool = true) -> [UInt8] {
        var b: [UInt8] = [0x30, 0x00, 0x8E, btn3, btn4, btn5, 0, 0, 0, 0, 0, 0]
        if right { b[9] = stick[0]; b[10] = stick[1]; b[11] = stick[2] }
        else { b[6] = stick[0]; b[7] = stick[1]; b[8] = stick[2] }
        return b
    }

    func testRejectsNonStandardReport() {
        XCTAssertNil(JoyConReport.parseStandard([0x3F, 0x00, 0x00], side: .right))
        XCTAssertNil(JoyConReport.parseStandard(Array(report().prefix(11)), side: .right))
    }

    func testRightFaceButtons() {
        // Y=0x01 X=0x02 B=0x04 A=0x08
        let r = JoyConReport.parseStandard(report(btn3: 0x0F), side: .right)!
        XCTAssertEqual(r.pressed, [.buttonY, .buttonX, .buttonB, .buttonA])
    }

    func testRightRailAndTriggers() {
        // SR=0x10 SL=0x20 R=0x40 ZR=0x80 — R and ZR are distinct actions
        let r = JoyConReport.parseStandard(report(btn3: 0xF0), side: .right)!
        XCTAssertEqual(r.pressed, [.shoulderRight, .shoulderLeft, .bumperRight, .triggerRight])
    }

    func testLeftArrowsMirrorToFaceActions() {
        // Down=0x01 Up=0x02 Right=0x04 Left=0x08 → B, X, A, Y by position
        let r = JoyConReport.parseStandard(report(btn5: 0x0F), side: .left)!
        XCTAssertEqual(r.pressed, [.buttonB, .buttonX, .buttonA, .buttonY])
    }

    func testLeftRailAndTriggers() {
        // SR(L)=0x10 SL(L)=0x20 L=0x40 ZL=0x80 — L and ZL are distinct actions
        let r = JoyConReport.parseStandard(report(btn5: 0xF0), side: .left)!
        XCTAssertEqual(r.pressed, [.shoulderRight, .shoulderLeft, .bumperLeft, .triggerLeft])
    }

    func testSharedButtons() {
        // Minus=0x01 Plus=0x02 RStick=0x04 LStick=0x08 Home=0x10 Capture=0x20
        // Stick clicks are ignored by design (GameController never exposed them).
        let r = JoyConReport.parseStandard(report(btn4: 0x3F), side: .right)!
        XCTAssertEqual(r.pressed, [.options, .menu, .home, .capture])
    }

    func testStickUnpacking12Bit() {
        // x = b0 | (b1 & 0x0F) << 8 ; y = (b1 >> 4) | b2 << 4
        // bytes [0x34, 0xD2, 0x7A] → x = 0x234, y = 0x7AD
        let r = JoyConReport.parseStandard(
            report(stick: [0x34, 0xD2, 0x7A], right: true), side: .right)!
        XCTAssertEqual(r.stick, RawStick(x: 0x234, y: 0x7AD))
        let l = JoyConReport.parseStandard(
            report(stick: [0x34, 0xD2, 0x7A], right: false), side: .left)!
        XCTAssertEqual(l.stick, RawStick(x: 0x234, y: 0x7AD))
    }
}

final class SPIReadReplyTests: XCTestCase {
    /// 0x21 subcommand-reply skeleton: byte 13 ack, 14 echoed subcommand,
    /// 15-18 little-endian SPI address, 19 length, 20+ payload.
    private func reply(ack: UInt8 = 0x90, subcommand: UInt8 = 0x10,
                       address: UInt32 = 0x603D, length: UInt8? = nil,
                       payload: [UInt8]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        b[0] = 0x21
        b[13] = ack
        b[14] = subcommand
        b[15] = UInt8(address & 0xFF)
        b[16] = UInt8((address >> 8) & 0xFF)
        b[17] = UInt8((address >> 16) & 0xFF)
        b[18] = UInt8((address >> 24) & 0xFF)
        b[19] = length ?? UInt8(payload.count)
        return b + payload
    }

    func testParsesFactoryRead() {
        let r = SPIReadReply.parse(
            reply(address: 0x603D, payload: Array(1...9)))
        XCTAssertEqual(r, SPIReadReply(address: 0x603D, payload: Array(1...9)))
    }

    func testParsesUserReadAddressAndTrailingBytes() {
        // 0x801B + 11 bytes, with the usual 49-byte report tail beyond it.
        var raw = reply(address: 0x801B, payload: [0xA1, 0xB2] + Array(1...9))
        raw += [UInt8](repeating: 0xFF, count: 20)
        let r = SPIReadReply.parse(raw)!
        XCTAssertEqual(r.address, 0x801B)
        XCTAssertEqual(r.payload, [0xA1, 0xB2] + Array(1...9))
    }

    func testRejectsNack() {
        // Bit 7 clear in byte 13 = the Joy-Con refused the read.
        XCTAssertNil(SPIReadReply.parse(reply(ack: 0x00, payload: Array(1...9))))
    }

    func testRejectsOtherSubcommands() {
        // 0x03 = the mode-set ack, which arrives as a 0x21 report too.
        XCTAssertNil(SPIReadReply.parse(reply(subcommand: 0x03, payload: Array(1...9))))
    }

    func testRejectsTruncatedPayload() {
        // Claims 9 bytes, carries 4.
        XCTAssertNil(SPIReadReply.parse(
            reply(length: 9, payload: [1, 2, 3, 4])))
        XCTAssertNil(SPIReadReply.parse(reply(payload: [])))
    }

    func testRejectsNon0x21Report() {
        var raw = reply(payload: Array(1...9))
        raw[0] = 0x30
        XCTAssertNil(SPIReadReply.parse(raw))
    }

    func testFactoryPayloadFeedsStickCalibration() {
        // Composition check: a parsed factory payload decodes as left-side cal.
        let spi: [UInt8] = [0xB0, 0xC4, 0x44, 0xD0, 0x47, 0x83, 0x84, 0x83, 0x38]
        let r = SPIReadReply.parse(reply(address: 0x603D, payload: spi))!
        XCTAssertEqual(StickCalibration.decode(spi: r.payload, side: .left),
                       StickCalibration.decode(spi: spi, side: .left))
        XCTAssertNotNil(StickCalibration.decode(spi: r.payload, side: .left))
    }
}
