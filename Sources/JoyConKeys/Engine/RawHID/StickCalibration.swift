import Foundation

/// Per-axis stick calibration from the Joy-Con's SPI flash. Factory data
/// lives at 0x603D (left) / 0x6046 (right), 9 bytes of three packed 12-bit
/// pairs; user calibration (0x8012 / 0x801D, magic 0xB2A1 two bytes before)
/// uses the same encoding and wins when present.
struct StickCalibration: Equatable {
    var centerX: Int
    var centerY: Int
    var rangeXPlus: Int
    var rangeYPlus: Int
    var rangeXMinus: Int
    var rangeYMinus: Int

    /// Used when SPI reads fail — generous ranges, nominal center.
    static let fallback = StickCalibration(
        centerX: 2048, centerY: 2048,
        rangeXPlus: 1400, rangeYPlus: 1400, rangeXMinus: 1400, rangeYMinus: 1400)

    static func decode(spi bytes: [UInt8], side: JoyConSide) -> StickCalibration? {
        guard bytes.count >= 9 else { return nil }
        guard side != .other else { return nil }
        func pair(_ i: Int) -> (Int, Int) {
            (Int(bytes[i]) | (Int(bytes[i + 1] & 0x0F) << 8),
             (Int(bytes[i + 1]) >> 4) | (Int(bytes[i + 2]) << 4))
        }
        let p0 = pair(0), p1 = pair(3), p2 = pair(6)
        // Same fields, different SPI ordering per side.
        let (above, center, below) = side == .left ? (p0, p1, p2) : (p2, p0, p1)
        return StickCalibration(
            centerX: center.0, centerY: center.1,
            rangeXPlus: above.0, rangeYPlus: above.1,
            rangeXMinus: below.0, rangeYMinus: below.1)
    }

    /// Raw 12-bit → [-1, 1], clamped. Upright (vertical-grip) frame:
    /// +x = right, +y = up — matches how the engine's handleStick wants it.
    func normalize(_ raw: RawStick) -> (x: Float, y: Float) {
        func norm(_ v: Int, _ center: Int, _ plus: Int, _ minus: Int) -> Float {
            let d = v - center
            let r = d >= 0 ? Float(d) / Float(max(plus, 1))
                           : Float(d) / Float(max(minus, 1))
            return min(1, max(-1, r))
        }
        return (norm(raw.x, centerX, rangeXPlus, rangeXMinus),
                norm(raw.y, centerY, rangeYPlus, rangeYMinus))
    }
}
