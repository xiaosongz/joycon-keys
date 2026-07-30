// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JoyConKeys",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "JoyConKeys",
            path: "Sources/JoyConKeys",
            // Swift 5 mode: GameController + AX C callbacks don't model
            // isolation, and strict concurrency rejects the assumeIsolated
            // bridging this app relies on. Revisit when GC gets Sendable
            // annotations.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
