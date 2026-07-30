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
    static func editorRows(side: JoyConSide) -> [PadButton] {
        [
            .buttonX, .buttonB, .buttonY, .buttonA,
            .stickUp, .stickDown, .stickLeft, .stickRight,
            .shoulderLeft, .shoulderRight,
            // ZL/ZR are the only shoulders a combined pair reports —
            // they must be rebindable even though a single Joy-Con
            // never fires them.
            .triggerLeft, .triggerRight,
            side == .left ? .capture : .home,
            .menu, .options,
        ]
    }
}

enum JoyConSide: String, Codable {
    case left, right, other
}
