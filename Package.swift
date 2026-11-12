// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Crackstreams",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Crackstreams", targets: ["Crackstreams"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Crackstreams",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Scripts/build-app.sh embeds Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "CrackstreamsTests",
            dependencies: ["Crackstreams"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // SwiftPM stages Sparkle.framework in the products directory, not beside
                // the xctest bundle, so the test runner needs this rpath to load it.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../"])
            ]
        )
    ]
)
