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

    func begin(for button: PadButton, onCapture: @escaping (KeyCombo) -> Void) {
        cancel()
        recordingButton = button
        heldModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .flagsChanged:
                self.heldModifiers = Modifiers(eventFlags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
                return nil
            case .keyDown:
                if event.keyCode == 53 && self.heldModifiers.isEmpty {  // bare Escape cancels
                    self.cancel()
                    return nil
                }
                let combo = KeyCombo(
                    keyCode: event.keyCode,
                    modifiers: Modifiers(eventFlags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))))
                self.cancel()
                onCapture(combo)
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
}
