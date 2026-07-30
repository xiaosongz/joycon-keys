// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JoyConKeys",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "JoyConKeys",
            path: "Sources/JoyConKeys",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
