import AppKit
import SwiftUI

@main
struct JoyConKeysApp: App {
    @StateObject private var store: MappingStore
    @StateObject private var engine: ControllerEngine

    init() {
        PreviewRender.runIfRequested()
        UserDefaults.standard.register(
            defaults: [AppDefaults.startMinimizedKey: AppDefaults.startMinimizedDefault])
        let store = MappingStore()
        _store = StateObject(wrappedValue: store)
        _engine = StateObject(wrappedValue: ControllerEngine(store: store))
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
        // Scene launch behavior is fixed at construction — the Settings
        // toggle therefore applies from the next start.
        .defaultLaunchBehavior(
            UserDefaults.standard.bool(forKey: AppDefaults.startMinimizedKey)
                ? .suppressed : .presented)
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
        if !engine.accessibilityTrusted {
            Text("Accessibility permission required")
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
