import AppKit
import SwiftUI

/// Headless snapshot for QA and README screenshots:
///   JoyConKeys --render-preview /tmp/out   →  out-window.png, out-pair.png
///   JoyConKeys --render-icon /tmp/icon.png →  1024×1024 app icon master
@MainActor
enum PreviewRender {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), args.count > i + 1 {
            save(AppIconView(), to: args[i + 1], scale: 1.0)
            exit(0)
        }
        guard let i = args.firstIndex(of: "--render-preview"), args.count > i + 1 else { return }
        let base = args[i + 1]
        // Preview mode must remain hermetic: do not touch the user's mappings,
        // request TCC permissions, or start controller discovery just to
        // render documentation/QA screenshots.
        let previewMappings = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "JoyConKeysPreview-\(ProcessInfo.processInfo.processIdentifier).json")
        let store = MappingStore(fileURL: previewMappings)
        let engine = ControllerEngine(
            store: store, startBackend: false, promptForAccessibility: false)
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
        try? FileManager.default.removeItem(at: previewMappings)
        exit(0)
    }

    private static func save(_ view: some View, to path: String, scale: CGFloat = 2.0) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed: \(path)")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        } catch {
            print("write failed: \(path): \(error)")
        }
    }
}
