import ServiceManagement
import SwiftUI

/// The ⚙ tab: startup behavior and input engine. Mapping-related actions
/// stay with the mappings (Reset lives in MappingList).
struct SettingsPane: View {
    /// Injected by the main Window scene; ContentView hosts this pane.
    @EnvironmentObject var engine: ControllerEngine

    /// Read in JoyConKeysApp at scene construction — window suppression is
    /// decided once per launch, so changes apply on the next start.
    @AppStorage(AppDefaults.startMinimizedKey) private var startMinimized = AppDefaults.startMinimizedDefault

    /// Unlike startMinimized this takes effect immediately: the setter below
    /// asks the engine to re-read it and swap backends on the spot.
    @AppStorage(AppDefaults.useRawHIDKey) private var useRawHID = false

    /// SMAppService is the source of truth; this mirrors it for the Toggle.
    /// Deliberately NOT initialized from SMAppService here: a @State default
    /// expression re-evaluates on every struct init (one blocking BTM daemon
    /// query per Joy-Con input event while this tab is open). onAppear owns
    /// the initial read — the pane sits in an `if` branch, so its state
    /// resets each time the tab is entered.
    @State private var startAtLogin = false
    @State private var loginError: String?

    /// A KeepAlive LaunchAgent (README › Start at login) already owns
    /// startup on this machine. It also makes SMAppService.mainApp report
    /// .enabled (its BTM record covers the app bundle), so the toggle would
    /// both mislead and race a second instance — disable it instead.
    private var launchAgentInstalled: Bool {
        FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/Library/LaunchAgents/com.xiaosong.joycon-keys.plist")
    }

    var body: some View {
        Form {
            Section("Startup") {
                // Action lives in the binding's setter — an .onChange
                // observer would re-fire on the failure-path revert and
                // perform the opposite system call while erasing the error.
                Toggle("Start at login", isOn: Binding(
                    get: { startAtLogin },
                    set: { applyLoginItem(enable: $0) }))
                    .disabled(launchAgentInstalled)
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text(launchAgentInstalled
                     ? "Startup is managed by the installed LaunchAgent (com.xiaosong.joycon-keys) — remove it with launchctl bootout to use a login item instead."
                     : "Registers a standard macOS login item (visible in System Settings › General › Login Items).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Start minimized (menu bar only)", isOn: $startMinimized)
                Text("When off, the mapping editor opens on launch. Applies from the next start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Input engine") {
                // Action lives in the binding's setter for the same reason
                // as "Start at login" above: the permission prompt and the
                // backend swap must run exactly once per user flip.
                Toggle("Always use raw HID", isOn: Binding(
                    get: { useRawHID },
                    set: { enable in
                        useRawHID = enable
                        // Prompting is what makes the app appear in the
                        // Input Monitoring list at all; the grant itself
                        // arrives later, handled by the activation refresh.
                        // IOHIDRequestAccess blocks on the TCC prompt (M-4) —
                        // off MainActor so the toggle's own commit doesn't
                        // hang the UI; the return value is already discarded
                        // and unused here regardless of which queue runs it.
                        if enable && !RawHIDBackend.accessGranted() {
                            DispatchQueue.global(qos: .userInitiated).async {
                                RawHIDBackend.requestAccess()
                            }
                        }
                        engine.applyBackendPreference()
                    }))
                if engine.rawHIDDenied {
                    Text("Raw HID needs Input Monitoring permission — still using GameController.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Open Privacy & Security › Input Monitoring") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                    .font(.caption)
                }
                Text("Reads Joy-Con directly over Bluetooth HID. All four SL/SR buttons work even when macOS combines the pair — no Capture+Home gesture needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version",
                               value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                Link("Source & issues", destination: URL(string: "https://github.com/xiaosongz/joycon-keys")!)
            }
        }
        .formStyle(.grouped)
        .onAppear { syncFromSystem() }
        // The user may flip the login item — or grant Input Monitoring — in
        // System Settings while this pane stays open; refresh whenever the
        // app regains focus. The engine call is what promotes raw HID as
        // soon as the user comes back from granting the permission.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                syncFromSystem()
                engine.applyBackendPreference()
            }
    }

    private func syncFromSystem() {
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLoginItem(enable: Bool) {
        // A login item registers the RUNNING bundle's path with an ad-hoc
        // identity if that's how it was signed — from a build directory
        // that's a booby trap, not a feature.
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            loginError = "Move the app to /Applications first — a login item would point at \(Bundle.main.bundlePath)."
            syncFromSystem()
            return
        }
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't update login item: \(error.localizedDescription)"
            NSLog("[joycon-keys] login item %@ failed: %@",
                  enable ? "register" : "unregister", String(describing: error))
        }
        // One source of truth for the toggle on both paths.
        syncFromSystem()
    }
}

/// UserDefaults keys shared between the app entry point (which must read
/// them before any view exists) and the Settings pane.
enum AppDefaults {
    static let startMinimizedKey = "startMinimized"
    static let startMinimizedDefault = true
    /// Off by default: GameController needs no permission, so a fresh
    /// install works before the user has granted anything.
    static let useRawHIDKey = "useRawHID"
}
