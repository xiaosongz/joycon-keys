import XCTest
@testable import JoyConKeys

/// Locks down the hand-transcribed SPI protocol constants driving stick
/// calibration — the riskiest values in the raw-HID backend, previously
/// untested (MINOR-4).
final class RawHIDBackendConstantsTests: XCTestCase {
    func testSpiArgsPacksLittleEndianAddressPlusLength() {
        XCTAssertEqual(RawHIDBackend.spiArgs(0x603D, 9), [0x3D, 0x60, 0x00, 0x00, 9])
    }

    func testCalibrationAddresses() {
        XCTAssertEqual(RawHIDBackend.factoryCalAddress(.left), 0x603D)
        XCTAssertEqual(RawHIDBackend.factoryCalAddress(.right), 0x6046)
        XCTAssertEqual(RawHIDBackend.userCalAddress(.left), 0x8010)
        XCTAssertEqual(RawHIDBackend.userCalAddress(.right), 0x801B)
    }

    func testUserCalibrationMagicRequiresLittleEndianByteOrder() {
        // The 0xB2A1 write marker is stored on the wire as A1 B2 — a
        // byte-order swap here would silently reject every written user
        // calibration block.
        XCTAssertTrue(RawHIDBackend.hasUserCalibrationMagic([0xA1, 0xB2, 0, 0]))
        XCTAssertFalse(RawHIDBackend.hasUserCalibrationMagic([0xB2, 0xA1, 0, 0]))
    }
}
