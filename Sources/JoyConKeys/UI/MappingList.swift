import SwiftUI

/// One row per mappable input: physical label, current mapping, and a
/// click-to-record well. While recording it shows the held modifiers live.
struct MappingList: View {
    let side: JoyConSide
    @EnvironmentObject var store: MappingStore
    @EnvironmentObject var engine: ControllerEngine
    @ObservedObject var recorder: ComboRecorder
    @Binding var highlighted: PadButton?

    var body: some View {
        VStack(spacing: 6) {
            ForEach(PadButton.editorRows(side: side)) { button in
                MappingRow(
                    button: button, side: side, recorder: recorder,
                    isPressed: engine.pressed.contains(button),
                    isHighlighted: highlighted == button
                )
                .onHover { hovering in
                    highlighted = hovering ? button : (highlighted == button ? nil : highlighted)
                }
            }
            HStack {
                Spacer()
                Button("Reset to Defaults") { store.resetToDefaults() }
                    .controlSize(.small)
            }
            .padding(.top, 8)
        }
    }
}

struct MappingRow: View {
    let button: PadButton
    let side: JoyConSide
    @ObservedObject var recorder: ComboRecorder
    let isPressed: Bool
    let isHighlighted: Bool
    @EnvironmentObject var store: MappingStore

    private var isRecording: Bool { recorder.recordingButton == button }

    var body: some View {
        HStack {
            Text(button.physicalLabel(side: side))
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(width: 72, alignment: .leading)

            Spacer()

            Button {
                if isRecording {
                    recorder.cancel()
                } else {
                    recorder.begin(for: button) { combo in
                        store.set(combo.map { .combo($0) } ?? .unassigned, for: button)
                    }
                }
            } label: {
                Text(isRecording
                     ? (recorder.heldModifiers.isEmpty ? "Press keys…" : recorder.heldModifiers.symbols + "…")
                     : store.action(for: button).display)
                    .font(.system(.body, design: .rounded))
                    .frame(minWidth: 130)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isRecording ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(isRecording ? Color.accentColor : .clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .help("Click, then press the key combo. Esc cancels.")

            Menu {
                Button("macOS Dictation (double-Control)") {
                    store.set(.doubleControl, for: button)
                }
                // Bare Escape can't be recorded (it cancels recording).
                Button("Escape") {
                    store.set(.combo(KeyCombo(keyCode: 53, modifiers: [])), for: button)
                }
                Button("Unassigned") {
                    store.set(.unassigned, for: button)
                }
            } label: {
                Image(systemName: "chevron.down.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isPressed ? Color.accentColor.opacity(0.18)
                      : isHighlighted ? Color.primary.opacity(0.05) : .clear))
        .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}
