// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "dB",
    platforms: [
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "dB",
            path: "Sources/dB"
        )
    ]
)
