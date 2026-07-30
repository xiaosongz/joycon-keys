import XCTest
@testable import JoyConKeys

final class StickCalibrationTests: XCTestCase {
    /// Pack three 12-bit pairs into 9 SPI bytes (inverse of decode).
    private func pack(_ pairs: [(Int, Int)]) -> [UInt8] {
        pairs.flatMap { (a, b) -> [UInt8] in
            [UInt8(a & 0xFF), UInt8((a >> 8) | ((b & 0x0F) << 4)), UInt8(b >> 4)]
        }
    }

    func testDecodeLeftLayout() {
        // Left SPI order: (xAboveCenter,yAbove), (centerX,centerY), (xBelow,yBelow)
        let cal = StickCalibration.decode(
            spi: pack([(1200, 1100), (2000, 2100), (900, 950)]), side: .left)!
        XCTAssertEqual(cal, StickCalibration(
            centerX: 2000, centerY: 2100,
            rangeXPlus: 1200, rangeYPlus: 1100, rangeXMinus: 900, rangeYMinus: 950))
    }

    func testDecodeRightLayout() {
        // Right SPI order: (centerX,centerY), (xBelow,yBelow), (xAbove,yAbove)
        let cal = StickCalibration.decode(
            spi: pack([(2000, 2100), (900, 950), (1200, 1100)]), side: .right)!
        XCTAssertEqual(cal, StickCalibration(
            centerX: 2000, centerY: 2100,
            rangeXPlus: 1200, rangeYPlus: 1100, rangeXMinus: 900, rangeYMinus: 950))
    }

    func testDecodeRejectsShortBuffer() {
        XCTAssertNil(StickCalibration.decode(spi: [0, 1, 2], side: .left))
    }

    func testDecodeRejectsOtherSide() {
        XCTAssertNil(StickCalibration.decode(
            spi: pack([(1200, 1100), (2000, 2100), (900, 950)]), side: .other))
    }

    func testNormalizeCenterAndExtremes() {
        let cal = StickCalibration(
            centerX: 2000, centerY: 2000,
            rangeXPlus: 1000, rangeYPlus: 1000, rangeXMinus: 1000, rangeYMinus: 1000)
        XCTAssertEqual(cal.normalize(RawStick(x: 2000, y: 2000)).x, 0, accuracy: 0.001)
        XCTAssertEqual(cal.normalize(RawStick(x: 3000, y: 2000)).x, 1, accuracy: 0.001)
        XCTAssertEqual(cal.normalize(RawStick(x: 1000, y: 2000)).x, -1, accuracy: 0.001)
        XCTAssertEqual(cal.normalize(RawStick(x: 2000, y: 2500)).y, 0.5, accuracy: 0.001)
        // Beyond calibrated range clamps.
        XCTAssertEqual(cal.normalize(RawStick(x: 4095, y: 0)).x, 1, accuracy: 0.001)
        XCTAssertEqual(cal.normalize(RawStick(x: 4095, y: 0)).y, -1, accuracy: 0.001)
    }

    func testNormalizeAsymmetricRanges() {
        let cal = StickCalibration(
            centerX: 2000, centerY: 2000,
            rangeXPlus: 1200, rangeYPlus: 1100, rangeXMinus: 900, rangeYMinus: 950)
        // +x deflection divides by plus range: (2600 - 2000) / 1200 = 0.5
        XCTAssertEqual(cal.normalize(RawStick(x: 2600, y: 2000)).x, 0.5, accuracy: 0.001)
        // -x deflection divides by minus range: (1550 - 2000) / 900 = -0.5
        XCTAssertEqual(cal.normalize(RawStick(x: 1550, y: 2000)).x, -0.5, accuracy: 0.001)
        // +y deflection divides by plus range: (2550 - 2000) / 1100 = 0.5
        XCTAssertEqual(cal.normalize(RawStick(x: 2000, y: 2550)).y, 0.5, accuracy: 0.001)
        // -y deflection divides by minus range: (1525 - 2000) / 950 = -0.5
        XCTAssertEqual(cal.normalize(RawStick(x: 2000, y: 1525)).y, -0.5, accuracy: 0.001)
    }
}
