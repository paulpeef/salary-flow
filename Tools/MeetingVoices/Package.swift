// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingVoices",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "FluidAudio", path: "../../.build/meeting-fluid")],
    targets: [.executableTarget(name: "MeetingVoices", dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio")
    ])]
)
