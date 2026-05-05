// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"]),
        .library(name: "MurmurCore", targets: ["MurmurCore"]),
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurCore"],
            path: "Sources/Murmur",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "MurmurCore",
            path: "Sources/MurmurCore",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MurmurCoreTests",
            dependencies: ["MurmurCore"],
            path: "Tests/MurmurCoreTests",
            swiftSettings: swiftSettings
        ),
    ]
)
