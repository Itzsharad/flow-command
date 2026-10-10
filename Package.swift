// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FlowCommand",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Whisper speech recognition that runs on the Mac (accent-accurate)
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "FlowCommand",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/FlowCommand"
        )
    ]
)
