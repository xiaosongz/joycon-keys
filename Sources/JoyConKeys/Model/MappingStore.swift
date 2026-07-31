import Combine
import Foundation

/// Observable source of truth for button→action mappings, persisted as JSON
/// in ~/Library/Application Support/JoyConKeys/mappings.json. The engine
/// reads it on every button press, so edits apply instantly — no restart.
@MainActor
final class MappingStore: ObservableObject {
    @Published var mappings: [PadButton: MappedAction] {
        didSet { save() }
    }

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("JoyConKeys", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mappings.json")
    }()

    /// A value wrapper whose decode never throws — one corrupt entry must
    /// not take down every good mapping in the file.
    private struct LenientAction: Decodable {
        let action: MappedAction?
        init(from decoder: Decoder) { action = try? MappedAction(from: decoder) }
    }

    /// The mapping this tool shipped with — tuned for driving Claude Code
    /// menus and dictation from a vertically held Joy-Con (R).
    static let defaults: [PadButton: MappedAction] = [
        .buttonA: .combo(KeyCombo(keyCode: 36, modifiers: [])),          // Return
        .buttonB: .combo(KeyCombo(keyCode: 53, modifiers: [])),          // Escape
        .buttonX: .combo(KeyCombo(keyCode: 18, modifiers: [])),          // 1
        .buttonY: .combo(KeyCombo(keyCode: 19, modifiers: [])),          // 2
        .shoulderLeft: .doubleControl,                                    // SL = macOS dictation
        .shoulderRight: .combo(KeyCombo(keyCode: 2, modifiers: [.control, .option, .command])), // SR = ⌃⌥⌘D
        .triggerLeft: .doubleControl,
        .triggerRight: .combo(KeyCombo(keyCode: 2, modifiers: [.control, .option, .command])),
        // The big bumpers default to their trigger neighbors' actions, so a
        // combined pair behaves the same as before L/R became distinct.
        .bumperLeft: .doubleControl,
        .bumperRight: .combo(KeyCombo(keyCode: 2, modifiers: [.control, .option, .command])),
        .home: .doubleControl,
        .capture: .doubleControl,
        .menu: .combo(KeyCombo(keyCode: 48, modifiers: [.shift])),       // Shift+Tab
        .options: .combo(KeyCombo(keyCode: 48, modifiers: [.shift])),
        .stickUp: .combo(KeyCombo(keyCode: 126, modifiers: [])),
        .stickDown: .combo(KeyCombo(keyCode: 125, modifiers: [])),
        .stickLeft: .combo(KeyCombo(keyCode: 123, modifiers: [])),
        .stickRight: .combo(KeyCombo(keyCode: 124, modifiers: [])),
    ]

    init() {
        if let data = try? Data(contentsOf: Self.fileURL) {
            if let decoded = try? JSONDecoder().decode([String: LenientAction].self, from: data) {
                var loaded: [PadButton: MappedAction] = [:]
                for (key, lenient) in decoded {
                    if let button = PadButton(rawValue: key), let action = lenient.action {
                        loaded[button] = action
                    }
                }
                // New buttons added after the file was written fall back to defaults.
                mappings = Self.defaults.merging(loaded) { _, saved in saved }
            } else {
                // Unparseable file: preserve it before save() overwrites —
                // silently destroying user mappings is worse than defaults.
                let backup = Self.fileURL.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: Self.fileURL, to: backup)
                NSLog("[joycon-keys] mappings.json unreadable — reset to defaults, original kept at %@", backup.path)
                mappings = Self.defaults
            }
        } else {
            mappings = Self.defaults
        }
        save()  // materialize the file so users can find and inspect it
    }

    func action(for button: PadButton) -> MappedAction {
        mappings[button] ?? .unassigned
    }

    func set(_ action: MappedAction, for button: PadButton) {
        mappings[button] = action
    }

    func resetToDefaults() {
        mappings = Self.defaults
    }

    private func save() {
        let byKey = Dictionary(uniqueKeysWithValues: mappings.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(byKey)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("[joycon-keys] failed to persist mappings: %@", String(describing: error))
        }
    }
}
