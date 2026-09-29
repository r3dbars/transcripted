// swift-tools-version: 5.9
// Throwaway probe: Nemotron 3 Diarization via FluidAudio 0.17.x, isolated from the app's 0.15.4 deps.
import PackageDescription
let package = Package(
    name: "nemotron-probe",
    platforms: [.macOS("15.0")],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4")],
    targets: [.executableTarget(name: "nemotron-probe", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])]
)
