import AppKit
import ApplicationServices
import SwiftUI

@main
struct JoyConKeysApp: App {
    @StateObject private var store: MappingStore
    @StateObject private var engine: ControllerEngine

    init() {
        PreviewRender.runIfRequested()
        let store = MappingStore()
        _store = StateObject(wrappedValue: store)
        _engine = StateObject(wrappedValue: ControllerEngine(store: store))

        // Prompt once if key synthesis would be silently dropped. Log the
        // result either way: with KeepAlive a denied grant otherwise looks
        // identical to a working one (macOS drops synthetic events silently).
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSLog("[joycon-keys] accessibility trusted: %@", trusted ? "yes" : "NO — grant it in System Settings › Privacy & Security › Accessibility")
    }

    var body: some Scene {
        MenuBarExtra("JoyConKeys", systemImage: "gamecontroller") {
            MenuContent(engine: engine)
        }

        Window("JoyConKeys", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(engine)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

private struct MenuContent: View {
    @ObservedObject var engine: ControllerEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if engine.connected.isEmpty {
            Text("No Joy-Con connected")
        } else {
            ForEach(engine.connected) { c in
                Text("\(c.name) connected")
            }
        }
        Divider()
        Button("Open Mapping Editor…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit JoyConKeys") { NSApp.terminate(nil) }
    }
}
