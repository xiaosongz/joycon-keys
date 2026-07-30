import ServiceManagement
import SwiftUI

/// The ⚙ tab: startup behavior. Mapping-related actions stay with the
/// mappings (Reset lives in MappingList).
struct SettingsPane: View {
    /// Read in JoyConKeysApp at scene construction — window suppression is
    /// decided once per launch, so changes apply on the next start.
    @AppStorage("startMinimized") private var startMinimized = true

    /// SMAppService is the source of truth; this mirrors it for the Toggle.
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    /// A KeepAlive LaunchAgent (deploy.sh / README) already owns startup on
    /// this machine. It also makes SMAppService.mainApp report .enabled
    /// (its BTM record covers the app bundle), so the toggle would both
    /// mislead and race a second instance — disable it instead.
    private var launchAgentInstalled: Bool {
        FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/Library/LaunchAgents/com.xiaosong.joycon-keys.plist")
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Start at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { applyLoginItem() }
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

            Section {
                LabeledContent("Version",
                               value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                Link("Source & issues", destination: URL(string: "https://github.com/xiaosongz/joycon-keys")!)
            }
        }
        .formStyle(.grouped)
        .onAppear { startAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func applyLoginItem() {
        let wantEnabled = startAtLogin
        do {
            if wantEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            // Revert the toggle — the system state didn't change.
            startAtLogin = SMAppService.mainApp.status == .enabled
            loginError = "Couldn't update login item: \(error.localizedDescription)"
            NSLog("[joycon-keys] login item %@ failed: %@",
                  wantEnabled ? "register" : "unregister", String(describing: error))
        }
    }
}
