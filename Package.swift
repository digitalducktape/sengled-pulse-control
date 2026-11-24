// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SengledPulseControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PulseKit", targets: ["PulseKit"]),
        .executable(name: "pulsectl", targets: ["pulsectl"]),
        .executable(name: "PulseBar", targets: ["PulseBar"]),
    ],
    targets: [
        .target(name: "PulseKit", linkerSettings: [.linkedFramework("IOBluetooth")]),
        .executableTarget(name: "pulsectl", dependencies: ["PulseKit"]),
        .executableTarget(name: "PulseBar", dependencies: ["PulseKit"]),
        .testTarget(name: "PulseKitTests", dependencies: ["PulseKit"]),
    ],
    swiftLanguageModes: [.v5]
)
