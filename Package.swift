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
    dependencies: [
        // WhisperKit: CoreML/ANE Whisper inference for accented English.
        // Lives in the argmax-oss-swift umbrella as of v1.0.0 (2026-05-01).
        // We pull the `WhisperKit` product specifically — the umbrella also
        // includes TTSKit/SpeakerKit which we don't use yet.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
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
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
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
