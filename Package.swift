// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FrameBoost",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FrameBoost",
            path: "Sources/FrameBoost",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreVideo"),
            ]
        )
    ]
)
