import CoreGraphics
import Foundation

/// Modifier set for a recorded shortcut. Raw values are stable — they are
/// what gets persisted to mappings.json, so never renumber.
struct Modifiers: OptionSet, Codable, Hashable {
    let rawValue: Int

    static let control = Modifiers(rawValue: 1 << 0)
    static let option = Modifiers(rawValue: 1 << 1)
    static let shift = Modifiers(rawValue: 1 << 2)
    static let command = Modifiers(rawValue: 1 << 3)
    static let fn = Modifiers(rawValue: 1 << 4)

    var eventFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.command) { f.insert(.maskCommand) }
        if contains(.fn) { f.insert(.maskSecondaryFn) }
        return f
    }

    init(rawValue: Int) { self.rawValue = rawValue }

    init(eventFlags: CGEventFlags) {
        var m: Modifiers = []
        if eventFlags.contains(.maskControl) { m.insert(.control) }
        if eventFlags.contains(.maskAlternate) { m.insert(.option) }
        if eventFlags.contains(.maskShift) { m.insert(.shift) }
        if eventFlags.contains(.maskCommand) { m.insert(.command) }
        if eventFlags.contains(.maskSecondaryFn) { m.insert(.fn) }
        self = m
    }

    var symbols: String {
        var s = ""
        if contains(.fn) { s += "fn" }
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A keyboard shortcut: one non-modifier key plus modifiers.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: Modifiers

    var display: String {
        modifiers.symbols + (KeyCombo.keyNames[keyCode] ?? "vk\(keyCode)")
    }

    /// Carbon virtual key code → display name (ANSI layout).
    static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋", 76: "⌤", 96: "F5", 97: "F6",
        98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
        107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help",
        115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2",
        121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

/// What a controller button does when pressed.
enum MappedAction: Codable, Hashable {
    /// Press the combo for ~0.1 s with real modifier key events, then
    /// release everything in reverse order.
    case combo(KeyCombo)
    /// Double-tap Control — the macOS dictation shortcut on this machine
    /// (symbolic hotkey 164; not recordable as a plain combo).
    case doubleControl
    case unassigned

    var display: String {
        switch self {
        case .combo(let c): return c.display
        case .doubleControl: return "⌃⌃ (macOS Dictation)"
        case .unassigned: return "—"
        }
    }
}
