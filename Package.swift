// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TapChat",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "TapChat",
            path: "Sources/TapChat",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
