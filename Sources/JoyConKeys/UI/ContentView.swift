import SwiftUI

/// Main window: live Joy-Con drawing on the left, mapping editor on the
/// right. Shows whichever Joy-Con is connected; a picker appears when both
/// are. Click a button (on the drawing or in the list), press a combo, and
/// the mapping applies immediately.
struct ContentView: View {
    enum Tab: Hashable { case left, right, settings }

    @EnvironmentObject var store: MappingStore
    @EnvironmentObject var engine: ControllerEngine
    @StateObject private var recorder = ComboRecorder()
    @State private var tab: Tab = .right
    @State private var highlighted: PadButton?

    private var connectedSides: [JoyConSide] {
        let sides = engine.connected.map(\.side)
        // A combined "Joy-Con (L/R)" pair counts as both halves connected.
        if sides.contains(.other) { return [.left, .right] }
        return sides
    }

    // The picker always wins — a disconnected side renders dimmed rather
    // than being silently swapped for the connected one (that swap made
    // "Left" show the right Joy-Con whenever the left was charging).
    private var shownSide: JoyConSide { tab == .left ? .left : .right }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tab == .settings {
                SettingsPane()
                    .frame(minHeight: 460)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    JoyConView(
                        side: shownSide,
                        isConnected: connectedSides.contains(shownSide),
                        recorder: recorder,
                        highlighted: $highlighted
                    )
                    .frame(height: 460)

                    MappingList(
                        side: shownSide, recorder: recorder,
                        highlighted: $highlighted
                    )
                    .frame(width: 330)
                }
                .padding(24)
            }
        }
        .frame(minWidth: 580)
        .onAppear {
            snapToConnected()
            // LSUIElement apps don't activate on launch; when the window
            // was opened by "start minimized: off" it would otherwise
            // appear buried behind whatever restored at login.
            NSApp.activate()
        }
        .onChange(of: connectedSides) { snapToConnected() }
        // Leaving the mapping view must disarm the recorder — its NSEvent
        // monitor would otherwise swallow the next keystroke and bind it
        // to a now-invisible button. (No snapToConnected() here: it would
        // bounce an explicit click on a disconnected side straight back.)
        .onChange(of: tab) { recorder.cancel() }
        .onDisappear { recorder.cancel() }
    }

    /// On connect/disconnect, follow the hardware — but never fight an
    /// explicit picker click while the connection set is unchanged, and
    /// never yank the user out of Settings.
    private func snapToConnected() {
        guard tab != .settings, !connectedSides.isEmpty else { return }
        let side: JoyConSide = tab == .left ? .left : .right
        if !connectedSides.contains(side) {
            tab = connectedSides.first! == .left ? .left : .right
        }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(connectedSides.isEmpty ? Color.red : Color.green)
                .frame(width: 9, height: 9)
            Text(
                connectedSides.isEmpty
                    ? "No Joy-Con connected — pair one in System Settings › Bluetooth"
                    : engine.connected.map(\.name).joined(separator: "  ·  ")
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()

            Picker("", selection: $tab) {
                Text("Left").tag(Tab.left)
                Text("Right").tag(Tab.right)
                Image(systemName: "gearshape")
                    .accessibilityLabel("Settings")
                    .tag(Tab.settings)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
