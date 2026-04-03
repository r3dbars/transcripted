// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "FluidAudioBuild",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9")
    ],
    targets: [
        .target(
            name: "Shim",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources"
        )
    ]
)
