// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Crackstreams",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Crackstreams", targets: ["Crackstreams"])
    ],
    targets: [
        .executableTarget(
            name: "Crackstreams",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CrackstreamsTests",
            dependencies: ["Crackstreams"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
