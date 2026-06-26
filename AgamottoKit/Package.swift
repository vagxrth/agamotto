// swift-tools-version: 6.0
import PackageDescription

let captureFrameworks: [LinkerSetting] = [
    .linkedFramework("ScreenCaptureKit"),
    .linkedFramework("AVFoundation"),
    .linkedFramework("CoreMedia"),
    .linkedFramework("CoreVideo"),
    .linkedFramework("CoreGraphics"),
]

let package = Package(
    name: "Agamotto",
    platforms: [
        // Locked product floor: macOS 14 (Sonoma). ScreenCaptureKit + AVAssetWriter
        // fragmented output + VideoToolbox H.264/HEVC are all mature here.
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgamottoKit", targets: ["AgamottoKit"]),
        .executable(name: "AgamottoSpike", targets: ["AgamottoSpike"]),
        .executable(name: "AgamottoReplay", targets: ["AgamottoReplay"]),
    ],
    targets: [
        // Reusable capture/record engine. Grows into the real app's core in later phases;
        // kept free of any UI so it can drop into an AppKit/SwiftUI app target.
        .target(
            name: "AgamottoKit",
            // Phase 0/1 pragmatism: Swift 5 language mode avoids Swift 6 strict-concurrency
            // friction around the SCStreamOutput delegate + dispatch-queue confinement.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Phase 0 spike: prove SCK -> AVAssetWriter -> playable .mp4 with real permissions.
        .executableTarget(
            name: "AgamottoSpike",
            dependencies: ["AgamottoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: captureFrameworks
        ),
        // Phase 1 demo: the always-on segment ring + "save last N seconds".
        .executableTarget(
            name: "AgamottoReplay",
            dependencies: ["AgamottoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: captureFrameworks
        ),
    ]
)
