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
        // SR=0x10 SL=0x20 R=0x40 ZR=0x80 — R and ZR both fold into .triggerRight
        let r = JoyConReport.parseStandard(report(btn3: 0xF0), side: .right)!
        XCTAssertEqual(r.pressed, [.shoulderRight, .shoulderLeft, .triggerRight])
    }

    func testLeftArrowsMirrorToFaceActions() {
        // Down=0x01 Up=0x02 Right=0x04 Left=0x08 → B, X, A, Y by position
        let r = JoyConReport.parseStandard(report(btn5: 0x0F), side: .left)!
        XCTAssertEqual(r.pressed, [.buttonB, .buttonX, .buttonA, .buttonY])
    }

    func testLeftRailAndTriggers() {
        // SR(L)=0x10 SL(L)=0x20 L=0x40 ZL=0x80 — L and ZL fold into .triggerLeft
        let r = JoyConReport.parseStandard(report(btn5: 0xF0), side: .left)!
        XCTAssertEqual(r.pressed, [.shoulderRight, .shoulderLeft, .triggerLeft])
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
