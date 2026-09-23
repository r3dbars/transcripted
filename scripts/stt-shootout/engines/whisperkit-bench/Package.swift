// swift-tools-version: 5.9
// WhisperKit runner for the STT shootout, pinned to the same Argmax
// WhisperKit revision the app builds against (scripts/entrypoints/build-deps.sh).
import PackageDescription

let package = Package(
    name: "whisperkit-bench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            revision: "e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef"
        ),
        // Pinned to WhisperKit v0.18.0's own Package.resolved: newer
        // swift-jinja releases have broken swift-transformers before
        // (see scripts/entrypoints/build-deps.sh).
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.6"),
        .package(url: "https://github.com/huggingface/swift-jinja.git", exact: "2.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "whisperkit-bench",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        ),
    ]
)
