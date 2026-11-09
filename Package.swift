// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TapChat",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath", exact: "1.7.3"),
    ],
    targets: [
        .executableTarget(
            name: "TapChat",
            dependencies: [.product(name: "Sparkle", package: "Sparkle"), .product(name: "SwiftMath", package: "SwiftMath")],
            path: "Sources/TapChat",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                // Sparkle.framework is bundled in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
