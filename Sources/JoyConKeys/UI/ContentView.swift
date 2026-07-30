import SwiftUI

/// Main window: live Joy-Con drawing on the left, mapping editor on the
/// right. Shows whichever Joy-Con is connected; a picker appears when both
/// are. Click a button (on the drawing or in the list), press a combo, and
/// the mapping applies immediately.
struct ContentView: View {
    @EnvironmentObject var store: MappingStore
    @EnvironmentObject var engine: ControllerEngine
    @StateObject private var recorder = ComboRecorder()
    @State private var pickedSide: JoyConSide = .right
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
    private var shownSide: JoyConSide { pickedSide }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
        .frame(minWidth: 580)
        .onAppear { snapToConnected() }
        .onChange(of: connectedSides) { snapToConnected() }
        .onDisappear { recorder.cancel() }
    }

    /// On connect/disconnect, follow the hardware — but never fight an
    /// explicit picker click while the connection set is unchanged.
    private func snapToConnected() {
        if !connectedSides.isEmpty, !connectedSides.contains(pickedSide) {
            pickedSide = connectedSides.first!
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

            Picker("", selection: $pickedSide) {
                Text("Left").tag(JoyConSide.left)
                Text("Right").tag(JoyConSide.right)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
