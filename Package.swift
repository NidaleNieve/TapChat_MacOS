// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuickChat",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "QuickChat",
            path: "Sources/QuickChat",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
