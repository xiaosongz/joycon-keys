import AppKit
import SwiftUI

/// Captures one keyboard combo while active. Click a mapping row to arm it;
/// the next non-modifier key press (with whatever modifiers are held) is
/// recorded. Escape cancels. A local NSEvent monitor sees events before any
/// SwiftUI focus handling, so Space/Tab/arrows record cleanly.
@MainActor
final class ComboRecorder: ObservableObject {
    @Published var recordingButton: PadButton?
    @Published var heldModifiers: Modifiers = []

    private var monitor: Any?

    /// Key codes that inherently carry kCGEventFlagMaskSecondaryFn in their
    /// events (arrows, F-keys, nav cluster, forward-delete) — recording one
    /// must NOT persist a phantom .fn modifier, or synthesis would run the
    /// explicit Fn sequence for a combo that never needed it.
    private static let inherentFnKeys: Set<UInt16> = [
        96, 97, 98, 99, 100, 101, 103, 105, 107, 109, 111, 113,  // F-keys
        114, 115, 116, 117, 118, 119, 120, 121, 122,             // nav + F1-F4
        123, 124, 125, 126,                                      // arrows
    ]

    /// onCapture receives the recorded combo, or nil when the user pressed
    /// bare Delete — the "clear this binding" convention.
    func begin(for button: PadButton, onCapture: @escaping (KeyCombo?) -> Void) {
        cancel()
        recordingButton = button
        heldModifiers = []
        // A menu-bar (LSUIElement) app may not own key focus; without it the
        // local monitor never fires and the recorder looks dead.
        NSApp.activate()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            // NSEvent.ModifierFlags and CGEventFlags agree in the
            // 1<<16 … 1<<23 range — a coincidence we rely on here.
            var mods = Modifiers(eventFlags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
            switch event.type {
            case .flagsChanged:
                self.heldModifiers = mods
                return nil
            case .keyDown:
                if event.keyCode == 53 && mods.isEmpty {  // bare Escape cancels
                    self.cancel()
                    return nil
                }
                if event.keyCode == 51 && mods.isEmpty {  // bare Delete clears
                    self.cancel()
                    onCapture(nil)
                    return nil
                }
                if Self.inherentFnKeys.contains(event.keyCode) { mods.remove(.fn) }
                self.cancel()
                onCapture(KeyCombo(keyCode: event.keyCode, modifiers: mods))
                return nil
            default:
                return event
            }
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingButton = nil
        heldModifiers = []
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
