// swift-tools-version: 6.0
import PackageDescription

// easystream — the macOS daemon (SPEC.md / EST.md / A11Y_HTTP.md).
// Zero third-party dependencies: only Apple system frameworks.
let package = Package(
    name: "easystream",
    platforms: [.macOS(.v14)],  // ScreenCaptureKit 14+, VideoToolbox 12+
    targets: [
        .executableTarget(
            name: "easystream",
            path: "Sources/a11y",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
