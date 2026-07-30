import SwiftUI

/// Vector rendering of a vertical Joy-Con, drawn entirely with SwiftUI
/// shapes — no image assets. Buttons highlight while physically pressed
/// (live, from the engine) and are click targets that arm the recorder.
struct JoyConView: View {
    let side: JoyConSide
    let isConnected: Bool
    @EnvironmentObject var engine: ControllerEngine
    @EnvironmentObject var store: MappingStore
    @ObservedObject var recorder: ComboRecorder
    @Binding var highlighted: PadButton?

    // Hardware colors from the Joy-Con SPI flash palette (switchbrew):
    // shells #0AB9E6 / #FF3C28; buttons are TINTED near-black per side
    // (#001E1E on neon blue, #1E0A0A on neon red), not neutral gray.
    static let neonRed = Color(red: 1.0, green: 0.235, blue: 0.157)      // #FF3C28
    static let neonBlue = Color(red: 0.039, green: 0.725, blue: 0.902)   // #0AB9E6
    static let buttonOnBlue = Color(red: 0.0, green: 0.118, blue: 0.118) // #001E1E
    static let buttonOnRed = Color(red: 0.118, green: 0.039, blue: 0.039) // #1E0A0A

    private var shellColor: Color { side == .left ? Self.neonBlue : Self.neonRed }
    private var buttonColor: Color { side == .left ? Self.buttonOnBlue : Self.buttonOnRed }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                body_(w: w, h: h)
                railButtons(w: w, h: h)
                if side == .left {
                    faceL(w: w, h: h)
                } else {
                    faceR(w: w, h: h)
                }
            }
            .opacity(isConnected ? 1.0 : 0.35)
            .saturation(isConnected ? 1.0 : 0.4)
        }
        .aspectRatio(0.385, contentMode: .fit)
    }

    // MARK: shell

    private func body_(w: CGFloat, h: CGFloat) -> some View {
        let big = w * 0.46
        let small = w * 0.10
        let radii = side == .left
            ? RectangleCornerRadii(topLeading: big, bottomLeading: big, bottomTrailing: small, topTrailing: small)
            : RectangleCornerRadii(topLeading: small, bottomLeading: small, bottomTrailing: big, topTrailing: big)
        return UnevenRoundedRectangle(cornerRadii: radii)
            .fill(
                LinearGradient(
                    colors: [shellColor.opacity(0.95), shellColor, shellColor.opacity(0.82)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                UnevenRoundedRectangle(cornerRadii: radii)
                    .strokeBorder(.black.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }

    /// SL/SR on the rail edge (left edge of R, right edge of L).
    private func railButtons(w: CGFloat, h: CGFloat) -> some View {
        let x = side == .left ? w - w * 0.02 : w * 0.02
        // Established empirically: on (R) SR is the upper rail button and SL
        // the lower; mirrored on (L).
        let upper: PadButton = side == .left ? .shoulderLeft : .shoulderRight
        let lower: PadButton = side == .left ? .shoulderRight : .shoulderLeft
        return ZStack {
            railButton(upper, at: CGPoint(x: x, y: h * 0.26), w: w, h: h)
            railButton(lower, at: CGPoint(x: x, y: h * 0.74), w: w, h: h)
        }
    }

    private func railButton(_ id: PadButton, at p: CGPoint, w: CGFloat, h: CGFloat) -> some View {
        Capsule()
            .fill(pressedFill(id, base: Color(white: 0.35)))
            .frame(width: w * 0.045, height: h * 0.13)
            .position(p)
            .contentShape(Capsule())
            .onTapGesture { arm(id) }
    }

    // MARK: faces

    private func faceR(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            plusMinus(.menu, isPlus: true, at: CGPoint(x: w * 0.18, y: h * 0.075), w: w)
            // ABXY diamond: X top, A right, B bottom, Y left.
            face(.buttonX, "X", at: CGPoint(x: w * 0.54, y: h * 0.185), w: w)
            face(.buttonA, "A", at: CGPoint(x: w * 0.78, y: h * 0.275), w: w)
            face(.buttonB, "B", at: CGPoint(x: w * 0.54, y: h * 0.365), w: w)
            face(.buttonY, "Y", at: CGPoint(x: w * 0.30, y: h * 0.275), w: w)
            stick(at: CGPoint(x: w * 0.50, y: h * 0.56), w: w)
            homeButton(at: CGPoint(x: w * 0.30, y: h * 0.76), w: w)
        }
    }

    private func faceL(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            plusMinus(.menu, isPlus: false, at: CGPoint(x: w * 0.82, y: h * 0.075), w: w)
            stick(at: CGPoint(x: w * 0.50, y: h * 0.30), w: w)
            // Direction buttons (reported as A/B/X/Y in the sideways frame).
            face(.buttonX, "▲", at: CGPoint(x: w * 0.46, y: h * 0.475), w: w)
            face(.buttonA, "▶", at: CGPoint(x: w * 0.70, y: h * 0.565), w: w)
            face(.buttonB, "▼", at: CGPoint(x: w * 0.46, y: h * 0.655), w: w)
            face(.buttonY, "◀", at: CGPoint(x: w * 0.22, y: h * 0.565), w: w)
            captureButton(at: CGPoint(x: w * 0.70, y: h * 0.79), w: w)
        }
    }

    private func face(_ id: PadButton, _ label: String, at p: CGPoint, w: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(pressedFill(id, base: buttonColor))
                .frame(width: w * 0.21, height: w * 0.21)
            Text(label)
                .font(.system(size: w * 0.10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
        .position(p)
        .contentShape(Circle())
        .onTapGesture { arm(id) }
    }

    private func stick(at p: CGPoint, w: CGFloat) -> some View {
        let dirs: [PadButton] = [.stickUp, .stickDown, .stickLeft, .stickRight]
        let active = dirs.first { engine.pressed.contains($0) }
        let offset: CGSize = switch active {
        case .stickUp: CGSize(width: 0, height: -w * 0.06)
        case .stickDown: CGSize(width: 0, height: w * 0.06)
        case .stickLeft: CGSize(width: -w * 0.06, height: 0)
        case .stickRight: CGSize(width: w * 0.06, height: 0)
        default: .zero
        }
        return ZStack {
            Circle()  // well
                .fill(Color.black.opacity(0.35))
                .frame(width: w * 0.46, height: w * 0.46)
            Circle()  // cap
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.30), buttonColor],
                        center: .center, startRadius: 1, endRadius: w * 0.18))
                .overlay(Circle().strokeBorder(active != nil ? Color.white.opacity(0.9) : .black.opacity(0.4), lineWidth: active != nil ? 2 : 1))
                .frame(width: w * 0.36, height: w * 0.36)
                .offset(offset)
        }
        .position(p)
        .animation(.easeOut(duration: 0.08), value: offset)
    }

    private func homeButton(at p: CGPoint, w: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(pressedFill(.home, base: buttonColor))
                .overlay(Circle().strokeBorder(Color(white: 0.45), lineWidth: w * 0.012))
                .frame(width: w * 0.14, height: w * 0.14)
            Image(systemName: "house")
                .font(.system(size: w * 0.065, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .position(p)
        .contentShape(Circle())
        .onTapGesture { arm(.home) }
    }

    private func captureButton(at p: CGPoint, w: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: w * 0.03)
                .fill(pressedFill(.capture, base: buttonColor))
                .frame(width: w * 0.13, height: w * 0.13)
            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: w * 0.05, height: w * 0.05)
        }
        .position(p)
        .contentShape(Rectangle())
        .onTapGesture { arm(.capture) }
    }

    private func plusMinus(_ id: PadButton, isPlus: Bool, at p: CGPoint, w: CGFloat) -> some View {
        Image(systemName: isPlus ? "plus" : "minus")
            .font(.system(size: w * 0.085, weight: .black))
            .foregroundStyle(pressedFill(id, base: buttonColor))
            .position(p)
            .contentShape(Circle().scale(2))
            .onTapGesture { arm(id) }
    }

    // MARK: helpers

    private func pressedFill(_ id: PadButton, base: Color) -> Color {
        if engine.pressed.contains(id) { return .white }
        if recorder.recordingButton == id { return Color.accentColor }
        if highlighted == id { return base.opacity(0.75) }
        return base
    }

    private func arm(_ id: PadButton) {
        highlighted = id
        recorder.begin(for: id) { combo in
            store.set(combo.map { .combo($0) } ?? .unassigned, for: id)
        }
    }
}
