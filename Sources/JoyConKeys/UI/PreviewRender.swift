import AppKit
import SwiftUI

/// Headless snapshot for QA and README screenshots:
///   JoyConKeys --render-preview /tmp/out   →  out-window.png, out-pair.png
@MainActor
enum PreviewRender {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-preview"), args.count > i + 1 else { return }
        let base = args[i + 1]
        let store = MappingStore()
        let engine = ControllerEngine(store: store)
        let recorder = ComboRecorder()

        let window = ContentView()
            .environmentObject(store)
            .environmentObject(engine)
            .frame(width: 640, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))

        let pair = HStack(spacing: 40) {
            JoyConView(side: .left, isConnected: true, recorder: recorder,
                       highlighted: .constant(nil))
            JoyConView(side: .right, isConnected: true, recorder: recorder,
                       highlighted: .constant(nil))
        }
        .padding(40)
        .frame(height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .environmentObject(store)
        .environmentObject(engine)

        save(window, to: base + "-window.png")
        save(pair, to: base + "-pair.png")
        exit(0)
    }

    private static func save(_ view: some View, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed: \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
