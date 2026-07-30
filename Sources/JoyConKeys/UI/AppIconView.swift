import SwiftUI

/// The app icon: a comic-style right Joy-Con on a dark squircle, rendered
/// headlessly at 1024×1024 via `--render-icon` and packed into AppIcon.icns
/// by scripts/make-icon.sh. Pure vector — regenerate anytime the design
/// language changes.
struct AppIconView: View {
    /// Canvas size; everything below scales off this.
    let size: CGFloat = 1024

    var body: some View {
        let inset = size * 0.098          // Apple's icon grid margin
        let corner = size * 0.180         // macOS squircle
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.19, blue: 0.24),
                                 Color(red: 0.07, green: 0.09, blue: 0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(inset)

            joyCon
                .rotationEffect(.degrees(-8))
                .shadow(color: .black.opacity(0.45), radius: size * 0.02, y: size * 0.015)
        }
        .frame(width: size, height: size)
    }

    private var joyCon: some View {
        let w = size * 0.36
        let h = size * 0.66
        let stroke = size * 0.016         // the comic outline
        let big = w * 0.48
        let small = w * 0.12
        let radii = RectangleCornerRadii(
            topLeading: small, bottomLeading: small,
            bottomTrailing: big, topTrailing: big)
        let outline = Color(red: 0.05, green: 0.05, blue: 0.07)

        return ZStack {
            UnevenRoundedRectangle(cornerRadii: radii)
                .fill(JoyConView.neonBlue)
                .overlay(
                    UnevenRoundedRectangle(cornerRadii: radii)
                        .strokeBorder(outline, lineWidth: stroke))
            // Comic specular highlight along the rounded edge.
            Capsule()
                .fill(.white.opacity(0.45))
                .frame(width: w * 0.085, height: h * 0.16)
                .rotationEffect(.degrees(9))
                .offset(x: w * 0.30, y: -h * 0.37)

            // ABXY diamond (plain dots — letters vanish at 16 px anyway).
            Group {
                dot(at: CGPoint(x: 0.50, y: 0.21), w: w, h: h, outline: outline)  // X
                dot(at: CGPoint(x: 0.74, y: 0.30), w: w, h: h, outline: outline)  // A
                dot(at: CGPoint(x: 0.50, y: 0.39), w: w, h: h, outline: outline)  // B
                dot(at: CGPoint(x: 0.26, y: 0.30), w: w, h: h, outline: outline)  // Y
            }

            // Stick: outlined well + cap with its own comic highlight.
            ZStack {
                Circle()
                    .fill(JoyConView.buttonOnBlue)
                    .overlay(Circle().strokeBorder(outline, lineWidth: stroke * 0.9))
                    .frame(width: w * 0.52, height: w * 0.52)
                Circle()
                    .fill(.white.opacity(0.30))
                    .frame(width: w * 0.13, height: w * 0.13)
                    .offset(x: -w * 0.09, y: -w * 0.09)
            }
            .offset(x: 0, y: h * (0.60 - 0.5))

            // Home button.
            Circle()
                .fill(JoyConView.buttonOnBlue)
                .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: stroke * 0.5))
                .frame(width: w * 0.15, height: w * 0.15)
                .offset(x: -w * 0.20, y: h * (0.80 - 0.5))
        }
        .frame(width: w, height: h)
    }

    private func dot(at unit: CGPoint, w: CGFloat, h: CGFloat, outline: Color) -> some View {
        Circle()
            .fill(JoyConView.buttonOnBlue)
            .overlay(Circle().strokeBorder(outline, lineWidth: size * 0.010))
            .frame(width: w * 0.20, height: w * 0.20)
            .offset(x: w * (unit.x - 0.5), y: h * (unit.y - 0.5))
    }
}
