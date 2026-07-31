import Foundation

/// Every mappable input across both Joy-Con, keyed by the GameController
/// framework's element identity (which is grip-agnostic). Raw values are
/// the persistence keys in mappings.json — never rename.
enum PadButton: String, Codable, CaseIterable, Identifiable {
    case buttonA, buttonB, buttonX, buttonY
    // Single Joy-Con: SL/SR arrive as Left/Right Shoulder.
    // A combined pair: ZL/ZR arrive as Left/Right Trigger instead.
    case shoulderLeft, shoulderRight
    case triggerLeft, triggerRight
    // The big rail buttons L / R. Distinct from ZL/ZR since the raw HID
    // engine (and a combined pair via GameController) can tell them apart;
    // a single Joy-Con through GameController never fires them.
    case bumperLeft, bumperRight
    case home          // Joy-Con (R) only
    case capture       // Joy-Con (L) only (GC exposes it as Button Share)
    case menu          // + on (R), − on (L)
    case options
    case stickUp, stickDown, stickLeft, stickRight

    var id: String { rawValue }

    /// Label as printed on the physical controller, per side.
    func physicalLabel(side: JoyConSide) -> String {
        switch self {
        case .buttonA: return side == .left ? "→" : "A"
        case .buttonB: return side == .left ? "↓" : "B"
        case .buttonX: return side == .left ? "↑" : "X"
        case .buttonY: return side == .left ? "←" : "Y"
        case .shoulderLeft: return "SL"
        case .shoulderRight: return "SR"
        case .triggerLeft: return "ZL"
        case .triggerRight: return "ZR"
        case .bumperLeft: return "L"
        case .bumperRight: return "R"
        case .home: return "Home"
        case .capture: return "Capture"
        // GameController: Button Menu = +, Button Options = −. Which one a
        // single Joy-Con (L) fires for its − is unverified on hardware;
        // both rows are editable so either way the user can rebind it.
        case .menu: return "+"
        case .options: return "−"
        case .stickUp: return "Stick ↑"
        case .stickDown: return "Stick ↓"
        case .stickLeft: return "Stick ←"
        case .stickRight: return "Stick →"
        }
    }

    /// Rows shown in the mapping editor for a given side, in display order.
    /// Only buttons that physically exist on that side appear: SL/SR are on
    /// both rails, but L/ZL live on the left mini and R/ZR on the right.
    static func editorRows(side: JoyConSide) -> [PadButton] {
        var rows: [PadButton] = [
            .buttonX, .buttonB, .buttonY, .buttonA,
            .stickUp, .stickDown, .stickLeft, .stickRight,
            .shoulderLeft, .shoulderRight,
        ]
        switch side {
        case .left: rows += [.bumperLeft, .triggerLeft]
        case .right: rows += [.bumperRight, .triggerRight]
        case .other: rows += [.bumperLeft, .triggerLeft, .bumperRight, .triggerRight]
        }
        rows += [side == .left ? .capture : .home, .menu, .options]
        return rows
    }
}

enum JoyConSide: String, Codable {
    case left, right, other
}
