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

        // Prompt once if key synthesis would be silently dropped.
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !trusted {
            NSLog("[joycon-keys] no Accessibility permission yet — grant it in System Settings")
        }
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
