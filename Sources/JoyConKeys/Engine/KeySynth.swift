import CoreGraphics
import Foundation

/// Synthesizes keyboard events via CGEvent. Requires Accessibility permission.
///
/// Hard-won rules (see git history of the CLI version):
/// - Each event carries only the modifier flags still physically held at
///   that instant; a key-up carrying an already-released modifier's flag
///   latches it system-wide.
/// - Fn has no ordinary key events — it must be posted as flagsChanged
///   (vk 63) with the flag set on press and CLEARED on release.
/// - Hotkey listeners are happiest when modifiers arrive as real key events
///   pressed in order and released in reverse, like human fingers.
enum KeySynth {
    struct RepeatToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    /// Keeps each stick-repeat stream to at most one queued/running synthesis.
    /// Timer ticks that arrive while that work is pending are coalesced, and a
    /// released stream is rejected before any queued action starts.
    final class RepeatCoordinator: @unchecked Sendable {
        private struct State {
            var active = true
            var pending = false
        }

        private let lock = NSLock()
        private var states: [UUID: State] = [:]

        func begin() -> RepeatToken {
            lock.lock()
            defer { lock.unlock() }
            let token = RepeatToken(id: UUID())
            states[token.id] = State()
            return token
        }

        func claim(_ token: RepeatToken) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard var state = states[token.id], state.active, !state.pending else { return false }
            state.pending = true
            states[token.id] = state
            return true
        }

        func shouldExecute(_ token: RepeatToken) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return states[token.id]?.active == true
        }

        func finish(_ token: RepeatToken) {
            lock.lock()
            defer { lock.unlock() }
            guard var state = states[token.id] else { return }
            if state.active {
                state.pending = false
                states[token.id] = state
            } else {
                states.removeValue(forKey: token.id)
            }
        }

        func cancel(_ token: RepeatToken) {
            lock.lock()
            defer { lock.unlock() }
            guard var state = states[token.id] else { return }
            if state.pending {
                state.active = false
                states[token.id] = state
            } else {
                states.removeValue(forKey: token.id)
            }
        }
    }

    /// Synthesis sleeps (up to 200 ms for double-Control) run here, off the
    /// main thread — GameController handlers and the stick repeat timer are
    /// main-queue and must not stall behind a usleep. Serial, so overlapping
    /// presses can't interleave their modifier sequences.
    private static let queue = DispatchQueue(label: "joyconkeys.synth", qos: .userInteractive)
    private static let repeatCoordinator = RepeatCoordinator()

    private static let modifierKeys: [(Modifiers, CGKeyCode)] = [
        (.control, 59), (.option, 58), (.shift, 56), (.command, 55),
    ]

    /// Press the combo, hold ~0.1 s, release everything.
    static func post(_ combo: KeyCombo) {
        let src = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = []

        if combo.modifiers.contains(.fn) {
            flags.insert(.maskSecondaryFn)
            if let fnDown = CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: true) {
                fnDown.type = .flagsChanged
                fnDown.flags = flags
                fnDown.post(tap: .cghidEventTap)
            }
            usleep(10_000)
        }
        let held = modifierKeys.filter { combo.modifiers.contains($0.0) }
        for (mod, key) in held {
            flags.insert(mod.eventFlags)
            if let d = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true) {
                d.flags = flags
                d.post(tap: .cghidEventTap)
            }
            usleep(10_000)
        }

        if let d = CGEvent(keyboardEventSource: src, virtualKey: combo.keyCode, keyDown: true) {
            d.flags = flags
            d.post(tap: .cghidEventTap)
        }
        // ~0.1 s hold for combos so hotkey listeners register the chord;
        // plain keys (arrows on auto-repeat) release immediately.
        usleep(combo.modifiers.isEmpty ? 2_000 : 100_000)
        if let u = CGEvent(keyboardEventSource: src, virtualKey: combo.keyCode, keyDown: false) {
            u.flags = flags
            u.post(tap: .cghidEventTap)
        }

        for (mod, key) in held.reversed() {
            flags.remove(mod.eventFlags)
            usleep(10_000)
            if let u = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) {
                u.flags = flags
                u.post(tap: .cghidEventTap)
            }
        }
        if combo.modifiers.contains(.fn) {
            usleep(10_000)
            if let fnUp = CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: false) {
                fnUp.type = .flagsChanged
                fnUp.flags = []
                fnUp.post(tap: .cghidEventTap)
            }
        }
    }

    /// Double-tap Control — triggers the macOS dictation symbolic hotkey.
    static func postDoubleControl() {
        let src = CGEventSource(stateID: .hidSystemState)
        for tap in 0..<2 {
            if tap > 0 { usleep(120_000) }
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 59, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 59, keyDown: false) else { continue }
            down.flags = .maskControl
            up.flags = []
            down.post(tap: .cghidEventTap)
            usleep(40_000)
            up.post(tap: .cghidEventTap)
        }
    }

    static func perform(_ action: MappedAction) {
        queue.async { performNow(action) }
    }

    static func beginRepeat() -> RepeatToken {
        repeatCoordinator.begin()
    }

    static func cancelRepeat(_ token: RepeatToken) {
        repeatCoordinator.cancel(token)
    }

    static func performRepeat(_ action: MappedAction, token: RepeatToken) {
        guard repeatCoordinator.claim(token) else { return }
        queue.async {
            guard repeatCoordinator.shouldExecute(token) else {
                repeatCoordinator.finish(token)
                return
            }
            performNow(action)
            repeatCoordinator.finish(token)
        }
    }

    private static func performNow(_ action: MappedAction) {
        switch action {
        case .combo(let c): post(c)
        case .doubleControl: postDoubleControl()
        case .unassigned: break
        }
    }
}
